use super::*;
use sha2::{Digest, Sha256};
use std::io::Write;
pub fn hash(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}
pub fn safe_path(root: &Path, relative: &str) -> Result<PathBuf> {
    if relative.is_empty()
        || relative.contains('\\')
        || Path::new(relative)
            .components()
            .any(|c| !matches!(c, std::path::Component::Normal(_)))
    {
        return Err(invalid());
    }
    Ok(root.join(relative))
}
pub fn atomic_file(path: &Path, bytes: &[u8]) -> Result<()> {
    let tmp = path.with_extension(format!("{}.tmp", id()));
    let mut file = std::fs::File::create(&tmp).map_err(io_error)?;
    file.write_all(bytes).map_err(io_error)?;
    file.sync_all().map_err(io_error)?;
    std::fs::rename(&tmp, path).map_err(io_error)?;
    std::fs::File::open(path.parent().ok_or_else(invalid)?)
        .and_then(|f| f.sync_all())
        .map_err(io_error)?;
    Ok(())
}
impl Store {
    pub fn store_blob(&self, bytes: &[u8], original: bool) -> Result<String> {
        let format = image::guess_format(bytes).map_err(|_| invalid())?;
        let (extension, mime) = match format {
            image::ImageFormat::Jpeg => ("jpg", "image/jpeg"),
            image::ImageFormat::Png => ("png", "image/png"),
            image::ImageFormat::WebP => ("webp", "image/webp"),
            _ => return Err(invalid()),
        };
        let decoded = image::load_from_memory(bytes).map_err(|_| invalid())?;
        let id = id();
        let path = format!(
            "media/{}/{id}.{extension}",
            if original { "originals" } else { "derived" }
        );
        atomic_file(&self.root.join(&path), bytes)?;
        self.exec(
            "INSERT INTO media_blob VALUES (?,?,?,?,?,?,?,?)",
            &[
                json!(id),
                json!(path),
                json!(hash(bytes)),
                json!(bytes.len()),
                json!(mime),
                json!(decoded.width()),
                json!(decoded.height()),
                json!(now()),
            ],
        )?;
        Ok(id)
    }
    pub fn upload(&self, v: &Value, bytes: &[u8]) -> Result<Value> {
        let receipt = text(v, "receipt_id")?;
        let r = self.check_version(receipt, number(v, "expected_version")?)?;
        if !r["deleted_at_utc_ms"].is_null() {
            return Err(conflict());
        }
        let blob = self.store_blob(bytes, true)?;
        let image_id = id();
        let position = self.one(
            "SELECT COALESCE(MAX(position),-1)+1 AS n FROM receipt_image WHERE receipt_id=?",
            &[json!(receipt)],
        )?;
        self.exec("INSERT INTO receipt_image(image_id,receipt_id,position,original_blob_id,current_blob_id,captured_at_utc_ms,imported_at_utc_ms) VALUES (?,?,?,?,?,?,?)",&[json!(image_id),json!(receipt),position["n"].clone(),json!(blob),json!(blob),v["captured_at_utc_ms"].clone(),json!(now())])?;
        self.exec(
            "INSERT INTO image_revision VALUES (?,?,?,?,?)",
            &[
                json!(id()),
                json!(image_id),
                json!(blob),
                json!(0),
                json!(now()),
            ],
        )?;
        self.bump(receipt)?;
        Ok(json!({"image_id":image_id,"receipt":self.load(receipt)?}))
    }
    pub fn images(&self, receipt: &str, deleted: bool) -> Result<Value> {
        Ok(json!(self.rows("SELECT i.*,b.content_sha256,b.width_px,b.height_px,b.byte_length,b.mime,b.blob_id AS media_id FROM receipt_image i JOIN media_blob b ON b.blob_id=i.current_blob_id WHERE i.receipt_id=? AND (? OR i.deleted_at_utc_ms IS NULL) ORDER BY i.position",&[json!(receipt),json!(deleted)])?))
    }
    pub fn image_action(&self, op: &str, v: &Value) -> Result<Value> {
        let receipt = text(v, "receipt_id")?;
        if op == "list" {
            return self.images(receipt, v["include_deleted"] == true);
        }
        self.check_version(receipt, number(v, "expected_version")?)?;
        match op {
            "reorder" => {
                let ids = v["ids"].as_array().ok_or_else(invalid)?;
                let current=self.rows("SELECT image_id FROM receipt_image WHERE receipt_id=? AND deleted_at_utc_ms IS NULL",&[json!(receipt)])?;
                if ids.len() != current.len()
                    || ids.iter().collect::<std::collections::HashSet<_>>().len() != ids.len()
                    || current.iter().any(|r| !ids.contains(&r["image_id"]))
                {
                    return Err(conflict());
                }
                let max = self.one(
                    "SELECT COALESCE(MAX(position),0)+1 AS n FROM receipt_image WHERE receipt_id=?",
                    &[json!(receipt)],
                )?;
                let offset = number(&max, "n")?;
                self.exec(
                    "UPDATE receipt_image SET position=position+? WHERE receipt_id=?",
                    &[json!(offset), json!(receipt)],
                )?;
                for (i, id) in ids.iter().enumerate() {
                    self.exec(
                        "UPDATE receipt_image SET position=? WHERE image_id=?",
                        &[json!(i), id.clone()],
                    )?;
                }
            }
            "remove" | "restore" => {
                self.one(
                    "SELECT image_id FROM receipt_image WHERE receipt_id=? AND image_id=?",
                    &[json!(receipt), v["id"].clone()],
                )?;
                self.exec(
                    "UPDATE receipt_image SET deleted_at_utc_ms=? WHERE image_id=?",
                    &[
                        if op == "remove" {
                            json!(now())
                        } else {
                            Value::Null
                        },
                        v["id"].clone(),
                    ],
                )?;
            }
            "rotate" => {
                let row=self.one("SELECT b.* FROM receipt_image i JOIN media_blob b ON b.blob_id=i.current_blob_id WHERE i.receipt_id=? AND i.image_id=? AND i.deleted_at_utc_ms IS NULL",&[json!(receipt),v["id"].clone()])?;
                let bytes = std::fs::read(safe_path(&self.root, text(&row, "relative_path")?)?)
                    .map_err(io_error)?;
                let rotated = image::load_from_memory(&bytes)
                    .map_err(|_| invalid())?
                    .rotate90();
                let mut output = std::io::Cursor::new(Vec::new());
                rotated
                    .write_to(&mut output, image::ImageFormat::Png)
                    .map_err(io_error)?;
                let blob = self.store_blob(output.get_ref(), false)?;
                self.exec(
                    "UPDATE receipt_image SET current_blob_id=? WHERE image_id=?",
                    &[json!(blob), v["id"].clone()],
                )?;
                self.exec(
                    "INSERT INTO image_revision VALUES (?,?,?,?,?)",
                    &[
                        json!(id()),
                        v["id"].clone(),
                        json!(blob),
                        json!(1),
                        json!(now()),
                    ],
                )?;
                self.exec(
                    "UPDATE line_image_evidence SET x0=1-y1,y0=x0,x1=1-y0,y1=x1 WHERE image_id=?",
                    &[v["id"].clone()],
                )?;
            }
            _ => return Err(missing()),
        }
        self.bump(receipt)?;
        self.load(receipt)
    }
}

impl Store {
    pub fn cleanup_media(&self) -> Result<()> {
        self.exec("DELETE FROM logo_sample WHERE merchant_id IS NULL AND NOT EXISTS(SELECT 1 FROM receipt_logo r WHERE r.logo_id=logo_sample.logo_id)", &[])?;
        let unused=self.rows("SELECT * FROM media_blob b WHERE NOT EXISTS(SELECT 1 FROM receipt_image i WHERE i.original_blob_id=b.blob_id OR i.current_blob_id=b.blob_id) AND NOT EXISTS(SELECT 1 FROM image_revision r WHERE r.blob_id=b.blob_id) AND NOT EXISTS(SELECT 1 FROM logo_sample l WHERE l.blob_id=b.blob_id) AND NOT EXISTS(SELECT 1 FROM receipt_logo l WHERE l.source_blob_id=b.blob_id)",&[])?;
        for b in unused {
            self.exec(
                "DELETE FROM media_blob WHERE blob_id=?",
                &[b["blob_id"].clone()],
            )?;
            let path = safe_path(&self.root, text(&b, "relative_path")?)?;
            if path.exists() {
                std::fs::remove_file(path).map_err(io_error)?;
            }
        }
        let results = self.rows("SELECT result_relative_path FROM recognition_run WHERE result_relative_path IS NOT NULL", &[])?;
        let results: std::collections::HashSet<_> = results
            .iter()
            .filter_map(|r| r["result_relative_path"].as_str())
            .collect();
        for entry in std::fs::read_dir(self.root.join("recognition")).map_err(io_error)? {
            let entry = entry.map_err(io_error)?;
            let path = format!("recognition/{}", entry.file_name().to_string_lossy());
            if entry.file_type().map_err(io_error)?.is_file() && !results.contains(path.as_str()) {
                std::fs::remove_file(entry.path()).map_err(io_error)?;
            }
        }
        // Files abandoned before a DB commit are safe to collect after a grace period.
        let paths = self
            .rows("SELECT relative_path FROM media_blob", &[])?
            .iter()
            .filter_map(|r| r["relative_path"].as_str().map(str::to_owned))
            .collect::<std::collections::HashSet<_>>();
        for folder in ["media/originals", "media/derived"] {
            for item in std::fs::read_dir(self.root.join(folder)).map_err(io_error)? {
                let item = item.map_err(io_error)?;
                let name = format!("{folder}/{}", item.file_name().to_string_lossy());
                let metadata = item.metadata().map_err(io_error)?;
                if metadata.is_file()
                    && !paths.contains(&name)
                    && metadata
                        .modified()
                        .map_err(io_error)?
                        .elapsed()
                        .is_ok_and(|age| age.as_secs() > 86400)
                {
                    std::fs::remove_file(item.path()).map_err(io_error)?;
                }
            }
        }
        Ok(())
    }
}
