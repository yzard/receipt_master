//! Initial catalog bundled in the executable, independent of /data and OCR availability.
use super::*;
use crate::merchant_images::IMAGES;
use std::collections::HashSet;

pub(super) fn seed(store: &Store) -> Result<()> {
    let catalog: Value =
        serde_json::from_str(include_str!("../../resources/merchants/manifest.json"))
            .map_err(io_error)?;
    if catalog["version"] != 2 {
        return Err(invalid());
    }
    let samples = catalog["samples"].as_array().ok_or_else(invalid)?;
    let mut ids = HashSet::new();
    let mut images = HashSet::new();
    for sample in samples {
        let logo = text(sample, "id")?;
        let name = text(sample, "name")?;
        let image = text(sample, "image")?;
        let bytes = IMAGES
            .iter()
            .find(|(path, _)| *path == image)
            .map(|(_, bytes)| *bytes)
            .ok_or_else(invalid)?;
        if uuid::Uuid::parse_str(logo).is_err()
            || !ids.insert(logo)
            || !images.insert(image)
            || normalized(name) != name
            || name.is_empty()
            || media::hash(bytes) != text(sample, "sha256")?
        {
            return Err(invalid());
        }
        let merchant = store.rows(
            "SELECT merchant_id FROM merchant WHERE name=?",
            &[json!(name)],
        )?;
        let merchant = match merchant.first() {
            Some(row) => row["merchant_id"].clone(),
            None => {
                let merchant = json!(id());
                store.exec(
                    "INSERT INTO merchant(merchant_id,name) VALUES (?,?)",
                    &[merchant.clone(), json!(name)],
                )?;
                merchant
            }
        };
        let blob = store.store_blob(bytes, false)?;
        store.exec("INSERT INTO logo_sample(logo_id,blob_id,merchant_id,created_at_utc_ms) VALUES (?,?,?,?)",
            &[json!(logo),json!(blob),merchant,json!(now())])?;
    }
    if samples.len() != IMAGES.len() {
        return Err(invalid());
    }
    Ok(())
}
