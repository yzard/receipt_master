use super::*;

impl Store {
    pub fn logo_action(&self, op: &str, v: &Value) -> Result<Value> {
        if op == "list" {
            return Ok(json!(self.rows("SELECT l.logo_id,l.blob_id AS media_id,m.name,r.image_id,r.box_json,r.detection FROM logo_sample l LEFT JOIN merchant m ON m.merchant_id=l.merchant_id LEFT JOIN receipt_logo r ON r.logo_id=l.logo_id LEFT JOIN receipt_image i ON i.image_id=r.image_id WHERE (? IS NULL AND l.merchant_id IS NOT NULL) OR (i.receipt_id=? AND i.deleted_at_utc_ms IS NULL AND i.current_blob_id=r.source_blob_id) ORDER BY l.created_at_utc_ms DESC", &[v["receipt_id"].clone(),v["receipt_id"].clone()])?));
        }
        if self.one("SELECT version FROM catalog_version WHERE id=1", &[])?["version"]
            != v["expected_version"]
        {
            return Err(conflict());
        }
        let logo = text(v, "id")?;
        self.one(
            "SELECT logo_id FROM logo_sample WHERE logo_id=?",
            &[json!(logo)],
        )?;
        match op {
            "save" => {
                let name = normalized(text(v, "name")?);
                if name.is_empty() {
                    return Err(invalid());
                }
                let existing = self.rows(
                    "SELECT merchant_id FROM merchant WHERE name=? ORDER BY merchant_id LIMIT 1",
                    &[json!(name)],
                )?;
                let merchant = match existing.first() {
                    Some(m) => m["merchant_id"].clone(),
                    None => {
                        let mid = json!(id());
                        self.exec(
                            "INSERT INTO merchant VALUES (?,?)",
                            &[mid.clone(), json!(name)],
                        )?;
                        mid
                    }
                };
                self.exec(
                    "UPDATE logo_sample SET merchant_id=? WHERE logo_id=?",
                    &[merchant, json!(logo)],
                )?;
            }
            "delete" => {
                self.exec(
                    "UPDATE logo_sample SET merchant_id=NULL WHERE logo_id=?",
                    &[json!(logo)],
                )?;
            }
            _ => return Err(missing()),
        }
        self.exec(
            "UPDATE catalog_version SET version=version+1 WHERE id=1",
            &[],
        )?;
        Ok(Value::Null)
    }
    pub fn save_logo(
        &self,
        image: &Value,
        crop: &[u8],
        bbox: &Value,
        detection: &str,
    ) -> Result<()> {
        // Deleted, rotated, or replaced photos must never receive stale detections.
        self.one("SELECT image_id FROM receipt_image WHERE image_id=? AND current_blob_id=? AND deleted_at_utc_ms IS NULL", &[image["image_id"].clone(),image["blob_id"].clone()])?;
        if !self
            .rows(
                "SELECT r.logo_id FROM receipt_logo r JOIN logo_sample l ON l.logo_id=r.logo_id JOIN media_blob b ON b.blob_id=l.blob_id WHERE r.image_id=? AND r.source_blob_id=? AND b.content_sha256=?",
                &[image["image_id"].clone(), image["blob_id"].clone(),json!(media::hash(crop))],
            )?
            .is_empty()
        {
            return Ok(());
        }
        // An expanded crop of the same unchanged photo retains its confirmed label.
        // A different source image or disjoint detection must remain unconfirmed.
        let previous = self.rows("SELECT r.box_json,l.merchant_id FROM receipt_logo r JOIN logo_sample l ON l.logo_id=r.logo_id WHERE r.image_id=? AND r.source_blob_id=?", &[image["image_id"].clone(),image["blob_id"].clone()])?;
        let merchant = previous
            .first()
            .and_then(|p| {
                let old: Value = serde_json::from_str(p["box_json"].as_str()?).ok()?;
                let old = old.as_array()?;
                let new = bbox.as_array()?;
                if old.len() != 4 || new.len() != 4 {
                    return None;
                }
                let encloses = [0, 1].iter().all(|&i| {
                    new[i]
                        .as_f64()
                        .zip(old[i].as_f64())
                        .is_some_and(|(n, o)| n <= o + 1e-9)
                }) && [2, 3].iter().all(|&i| {
                    new[i]
                        .as_f64()
                        .zip(old[i].as_f64())
                        .is_some_and(|(n, o)| n + 1e-9 >= o)
                });
                encloses.then(|| p["merchant_id"].clone())
            })
            .unwrap_or(Value::Null);
        let blob = self.store_blob(crop, false)?;
        let logo = id();
        self.exec(
            "INSERT INTO logo_sample VALUES (?,?,?,?)",
            &[json!(logo), json!(blob), merchant, json!(now())],
        )?;
        self.exec("INSERT INTO receipt_logo VALUES (?,?,?,?,?) ON CONFLICT(image_id) DO UPDATE SET source_blob_id=excluded.source_blob_id,logo_id=excluded.logo_id,box_json=excluded.box_json,detection=excluded.detection", &[image["image_id"].clone(),image["blob_id"].clone(),json!(logo),json!(bbox.to_string()),json!(detection)])?;
        Ok(())
    }
    /// Only unchanged receipt crops and explicitly labelled reference crops may match.
    pub fn logo_match_inputs(&self, receipt: &str) -> Result<Value> {
        let candidates=self.rows("SELECT l.logo_id,b.relative_path,b.content_sha256,r.image_id,r.source_blob_id FROM receipt_logo r JOIN receipt_image i USING(image_id) JOIN receipt q USING(receipt_id) JOIN logo_sample l USING(logo_id) JOIN media_blob b ON b.blob_id=l.blob_id WHERE i.receipt_id=? AND q.deleted_at_utc_ms IS NULL AND i.deleted_at_utc_ms IS NULL AND i.current_blob_id=r.source_blob_id ORDER BY i.position", &[json!(receipt)])?;
        let references=self.rows("SELECT l.logo_id,b.relative_path,b.content_sha256,m.name FROM logo_sample l JOIN merchant m USING(merchant_id) JOIN media_blob b ON b.blob_id=l.blob_id ORDER BY l.logo_id", &[])?;
        Ok(
            json!({"candidates":candidates,"references":references,"catalog_version":self.one("SELECT version FROM catalog_version WHERE id=1", &[])?["version"]}),
        )
    }
}
