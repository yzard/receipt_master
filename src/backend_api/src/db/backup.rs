use super::media::{atomic_file, hash, safe_path};
use super::*;
use base64::Engine;
use std::io::{Read, Write};
impl Store {
    pub fn export_action(&self, op: &str, v: &Value) -> Result<Value> {
        match op {
            "latest_backup" => {
                let mut files = std::fs::read_dir(self.root.join("backups"))
                    .map_err(io_error)?
                    .collect::<std::result::Result<Vec<_>, _>>()
                    .map_err(io_error)?;
                files.retain(|f| f.path().extension().is_some_and(|e| e == "receiptbackup"));
                files.sort_by_key(|f| f.metadata().and_then(|m| m.modified()).ok());
                let file = files.last().ok_or_else(missing)?;
                let bytes = std::fs::read(file.path()).map_err(io_error)?;
                Ok(
                    json!({"data":{"bytes_base64":base64::engine::general_purpose::STANDARD.encode(bytes)}}),
                )
            }
            "create_backup" => {
                let backup_id = id();
                let stage = self.root.join("staging").join(&backup_id);
                std::fs::create_dir(&stage).map_err(io_error)?;
                let snapshot = stage.join("receipts.sqlite");
                self.db.backup("main", &snapshot, None).map_err(sql_error)?;
                let snap = Connection::open(&snapshot).map_err(sql_error)?;
                let mut files = vec![(
                    "database/receipts.sqlite".to_string(),
                    std::fs::read(&snapshot).map_err(io_error)?,
                )];
                let mut stmt=snap.prepare("SELECT relative_path FROM media_blob UNION SELECT result_relative_path FROM recognition_run WHERE result_relative_path IS NOT NULL").map_err(sql_error)?;
                for path in stmt
                    .query_map([], |r| r.get::<_, String>(0))
                    .map_err(sql_error)?
                {
                    let path = path.map_err(sql_error)?;
                    files.push((
                        path.clone(),
                        std::fs::read(safe_path(&self.root, &path)?).map_err(io_error)?,
                    ));
                }
                let manifest = json!({"format":2,"created_at_utc_ms":now(),"files":files.iter().map(|(name,bytes)|json!({"path":name,"bytes":bytes.len(),"sha256":hash(bytes)})).collect::<Vec<_>>()});
                let mut zip = zip::ZipWriter::new(std::io::Cursor::new(Vec::new()));
                let options = zip::write::SimpleFileOptions::default()
                    .compression_method(zip::CompressionMethod::Deflated);
                for (name, bytes) in files {
                    zip.start_file(name, options).map_err(io_error)?;
                    zip.write_all(&bytes).map_err(io_error)?;
                }
                zip.start_file("manifest.json", options).map_err(io_error)?;
                zip.write_all(manifest.to_string().as_bytes())
                    .map_err(io_error)?;
                let bytes = zip.finish().map_err(io_error)?.into_inner();
                atomic_file(
                    &self.root.join(format!("backups/{backup_id}.receiptbackup")),
                    &bytes,
                )?;
                std::fs::remove_dir_all(stage).map_err(io_error)?;
                Ok(
                    json!({"data":{"id":backup_id,"bytes_base64":base64::engine::general_purpose::STANDARD.encode(bytes)}}),
                )
            }
            "csv" => {
                let zone: text_type::Zone = text(v, "zone")?.parse().map_err(|_| invalid())?;
                let rows=self.rows("SELECT r.receipt_id,l.line_id,r.occurred_at_utc_ms,r.currency_code,l.raw_name,a.name AS product_name,CAST(ROUND(COALESCE(p.weight_g,w.weight_g)*1000) AS INTEGER) AS weight_mg,l.quantity_micros,l.quantity_unit,c.name AS category,l.kind,l.amount_minor FROM receipt_line l JOIN receipt r ON r.receipt_id=l.receipt_id LEFT JOIN product p ON p.product_id=l.product_id LEFT JOIN printed_name_product_name m ON m.printed_name_id=p.printed_name_id LEFT JOIN product_name a ON a.product_name_id=m.product_name_id LEFT JOIN line_unmatched_weight w ON w.line_id=l.line_id JOIN line_effective_category ec ON ec.line_id=l.line_id JOIN category c ON c.category_id=ec.category_id WHERE r.status='posted' AND r.deleted_at_utc_ms IS NULL ORDER BY r.occurred_at_utc_ms,l.position",&[])?;
                let mut out = String::from(
                    "\u{feff}receipt_id,line_id,time_utc,time_display,display_timezone,currency,raw_name,product_name,weight_g,quantity,unit,category,kind,amount\r\n",
                );
                for r in rows {
                    let utc =
                        chrono::DateTime::from_timestamp_millis(number(&r, "occurred_at_utc_ms")?)
                            .ok_or_else(invalid)?;
                    let digits = number(
                        &self.one(
                            "SELECT minor_digits FROM currency WHERE code=?",
                            &[r["currency_code"].clone()],
                        )?,
                        "minor_digits",
                    )?;
                    let values = [
                        r["receipt_id"].clone(),
                        r["line_id"].clone(),
                        json!(utc.to_rfc3339()),
                        json!(
                            utc.with_timezone(&zone)
                                .format("%Y-%m-%d %H:%M")
                                .to_string()
                        ),
                        json!(zone.to_string()),
                        r["currency_code"].clone(),
                        r["raw_name"].clone(),
                        r["product_name"].clone(),
                        json!(fixed(&r["weight_mg"], 3)),
                        json!(fixed(&r["quantity_micros"], 6)),
                        r["quantity_unit"].clone(),
                        r["category"].clone(),
                        r["kind"].clone(),
                        json!(fixed(&r["amount_minor"], digits as u32)),
                    ];
                    out.push_str(
                        &values
                            .iter()
                            .enumerate()
                            .map(|(i, v)| {
                                let mut s = v.as_str().unwrap_or("").to_string();
                                if ![8, 9, 13].contains(&i)
                                    && s.trim_start().starts_with(['=', '+', '-', '@', '\t', '\r'])
                                {
                                    s.insert(0, '\'');
                                }
                                format!("\"{}\"", s.replace('"', "\"\""))
                            })
                            .collect::<Vec<_>>()
                            .join(","),
                    );
                    out.push_str("\r\n");
                }
                Ok(json!({"data":out}))
            }
            _ => Err(missing()),
        }
    }
    pub fn restore_action(&self, op: &str, v: &Value) -> Result<Value> {
        match op {
            "prepare_restore" => {
                let bytes = base64::engine::general_purpose::STANDARD
                    .decode(text(v, "bytes_base64")?)
                    .map_err(|_| invalid())?;
                let token = id();
                let dir = self.root.join("staging").join(&token);
                std::fs::create_dir(&dir).map_err(io_error)?;
                let mut archive =
                    zip::ZipArchive::new(std::io::Cursor::new(bytes)).map_err(|_| invalid())?;
                let mut names = std::collections::HashSet::new();
                for i in 0..archive.len() {
                    let mut file = archive.by_index(i).map_err(|_| invalid())?;
                    let name = file.name().to_owned();
                    if file.is_dir() || file.is_symlink() || !names.insert(name.clone()) {
                        return Err(invalid());
                    }
                    let path = safe_path(&dir, &name)?;
                    std::fs::create_dir_all(path.parent().ok_or_else(invalid)?)
                        .map_err(io_error)?;
                    let mut bytes = Vec::new();
                    file.read_to_end(&mut bytes).map_err(io_error)?;
                    atomic_file(&path, &bytes)?;
                }
                let manifest: Value = serde_json::from_slice(
                    &std::fs::read(dir.join("manifest.json")).map_err(io_error)?,
                )
                .map_err(|_| invalid())?;
                if manifest["format"] != 2 {
                    return Err(invalid());
                }
                let files = manifest["files"].as_array().ok_or_else(invalid)?;
                if files.len() + 1 != names.len() {
                    return Err(invalid());
                }
                for f in files {
                    let path = text(f, "path")?;
                    if path != "database/receipts.sqlite"
                        && !path.starts_with("media/")
                        && !path.starts_with("recognition/")
                    {
                        return Err(invalid());
                    }
                    let bytes = std::fs::read(safe_path(&dir, path)?).map_err(io_error)?;
                    if json!(bytes.len()) != f["bytes"] || json!(hash(&bytes)) != f["sha256"] {
                        return Err(invalid());
                    }
                }
                for folder in ["media", "recognition"] {
                    std::fs::create_dir_all(dir.join(folder)).map_err(io_error)?;
                }
                let restored = Store::open(&dir)?;
                let signature = "SELECT type,name,tbl_name,sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type,name";
                if self.rows(signature, &[])? != restored.rows(signature, &[])? {
                    return Err(invalid());
                }
                restored.validate()?;
                let integrity = restored.one("PRAGMA integrity_check", &[])?;
                if integrity["integrity_check"] != "ok"
                    || restored.one("PRAGMA user_version", &[])?["user_version"] != 15
                {
                    return Err(invalid());
                }
                for r in restored.rows("SELECT relative_path FROM media_blob UNION SELECT result_relative_path AS relative_path FROM recognition_run WHERE result_relative_path IS NOT NULL",&[])?{if !safe_path(&dir,text(&r,"relative_path")?)?.is_file(){return Err(invalid());}}
                restored
                    .db
                    .execute_batch("PRAGMA wal_checkpoint(TRUNCATE)")
                    .map_err(sql_error)?;
                Ok(json!({"data":{"token":token}}))
            }
            "commit_restore" => {
                if v["confirm"] != true {
                    return Err(invalid());
                }
                if !self
                    .rows(
                        "SELECT job_id FROM recognition_job WHERE status IN ('running','queued')",
                        &[],
                    )?
                    .is_empty()
                {
                    return Err(conflict());
                }
                let token = text(v, "token")?;
                uuid::Uuid::parse_str(token).map_err(|_| invalid())?;
                let stage = self.root.join("staging").join(token);
                if !stage.join("database/receipts.sqlite").is_file() {
                    return Err(missing());
                }
                self.export_action("create_backup", &json!({}))?;
                self.db
                    .execute_batch("PRAGMA wal_checkpoint(TRUNCATE)")
                    .map_err(sql_error)?;
                // Persist a roll-forward journal. Startup completes it before opening the database.
                atomic_file(
                    &self.root.join("restore.json"),
                    json!({"token":token}).to_string().as_bytes(),
                )?;
                finish_restore(&self.root)?;
                Ok(json!({"data":"后端备份已恢复"}))
            }
            _ => Err(missing()),
        }
    }
}
mod text_type {
    pub type Zone = chrono_tz::Tz;
}
fn fixed(v: &Value, digits: u32) -> String {
    let Some(n) = v.as_i64() else {
        return String::new();
    };
    let n = i128::from(n);
    let scale = 10i128.pow(digits);
    if digits == 0 {
        return n.to_string();
    }
    format!(
        "{}{}.{:0width$}",
        if n < 0 { "-" } else { "" },
        n.abs() / scale,
        n.abs() % scale,
        width = digits as usize
    )
}
pub fn finish_restore(root: &Path) -> Result<()> {
    let journal = root.join("restore.json");
    if !journal.exists() {
        return Ok(());
    }
    let v: Value =
        serde_json::from_slice(&std::fs::read(&journal).map_err(io_error)?).map_err(io_error)?;
    let token = text(&v, "token")?;
    uuid::Uuid::parse_str(token).map_err(|_| invalid())?;
    let stage = root.join("staging").join(token);
    for folder in ["database", "media", "recognition"] {
        let from = stage.join(folder);
        if !from.exists() {
            continue;
        }
        let target = root.join(folder);
        let old = root.join(format!("staging/previous-{token}-{folder}"));
        if target.exists() && !old.exists() {
            std::fs::rename(&target, &old).map_err(io_error)?;
        }
        std::fs::rename(from, target).map_err(io_error)?;
    }
    std::fs::remove_file(journal).map_err(io_error)?;
    Ok(())
}
