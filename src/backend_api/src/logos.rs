//! Logo candidates are visual evidence, never a new alias until the user labels one.
use crate::{
    State,
    db::{self, Result, Store, invalid},
};
use base64::Engine;
use image::{GenericImageView, ImageDecoder};
use serde_json::{Value, json};
use std::{io::Cursor, sync::Arc};
/// Give the locator a focused, upright header; return its height in full-image coordinates.
pub fn localization_input(data_url: &str) -> Result<(String, f64)> {
    let (_, encoded) = data_url.split_once(',').ok_or_else(invalid)?;
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(encoded)
        .map_err(|_| invalid())?;
    let mut decoder = image::ImageReader::new(Cursor::new(bytes))
        .with_guessed_format()
        .map_err(db::io_error)?
        .into_decoder()
        .map_err(|_| invalid())?;
    let orientation = decoder.orientation().map_err(db::io_error)?;
    let mut img = image::DynamicImage::from_decoder(decoder).map_err(|_| invalid())?;
    img.apply_orientation(orientation);
    let height = ((img.height() as f64 * 0.30).ceil() as u32).max(1);
    let mut header = img.crop_imm(0, 0, img.width(), height);
    if header.width() > 1600 || header.height() > 1600 {
        header = header.resize(1600, 1600, image::imageops::FilterType::Lanczos3);
    }
    let mut out = Cursor::new(Vec::new());
    header
        .write_to(&mut out, image::ImageFormat::Png)
        .map_err(db::io_error)?;
    Ok((
        format!(
            "data:image/png;base64,{}",
            base64::engine::general_purpose::STANDARD.encode(out.into_inner())
        ),
        height as f64 / img.height() as f64,
    ))
}

pub fn crop(bytes: &[u8], evidence: &str) -> Result<(Vec<u8>, Value, String)> {
    let mut decoder = image::ImageReader::new(Cursor::new(bytes))
        .with_guessed_format()
        .map_err(db::io_error)?
        .into_decoder()
        .map_err(|_| invalid())?;
    let orientation = decoder.orientation().map_err(db::io_error)?;
    let mut img = image::DynamicImage::from_decoder(decoder).map_err(|_| invalid())?;
    img.apply_orientation(orientation);
    let (w, h) = img.dimensions();
    let mut bbox = [0.05, 0.0, 0.95, 0.22];
    let mut detection = "header_candidate";
    {
        let value: Value = serde_json::from_str(evidence).map_err(|_| invalid())?;
        if !value["box"].is_null() {
            let b = value["box"]
                .as_array()
                .filter(|b| b.len() == 4)
                .ok_or_else(invalid)?;
            let mut bounds = [0.0; 4];
            for (i, v) in b.iter().enumerate() {
                bounds[i] = v
                    .as_f64()
                    .filter(|v| (0.0..=1.0).contains(v))
                    .ok_or_else(invalid)?;
            }
            if bounds[0] >= bounds[2] || bounds[1] >= bounds[3] {
                return Err(invalid());
            }
            bbox = [
                (bounds[0] - 0.012).max(0.0),
                (bounds[1] - 0.008).max(0.0),
                (bounds[2] + 0.012).min(1.0),
                (bounds[3] + 0.008).min(1.0),
            ];
            detection = "vision_logo";
        }
    }
    let x = (bbox[0] * w as f64) as u32;
    let y = (bbox[1] * h as f64) as u32;
    let cw = ((bbox[2] * w as f64) as u32).saturating_sub(x).max(1);
    let ch = ((bbox[3] * h as f64) as u32).saturating_sub(y).max(1);
    let cropped =
        img.crop_imm(x, y, cw, ch)
            .resize(2048, 2048, image::imageops::FilterType::Lanczos3);
    let mut out = Cursor::new(Vec::new());
    cropped
        .write_to(&mut out, image::ImageFormat::Png)
        .map_err(db::io_error)?;
    Ok((out.into_inner(), json!(bbox), detection.to_string()))
}
pub async fn capture(
    state: Arc<State>,
    image: Value,
    bytes: Vec<u8>,
    evidence: String,
) -> Result<()> {
    let (crop, bbox, detection) = tokio::task::spawn_blocking(move || crop(&bytes, &evidence))
        .await
        .map_err(db::io_error)??;
    let _lock = state.storage_lock.lock().await;
    let root = state.config.data_dir.clone();
    tokio::task::spawn_blocking(move || {
        let s = Store::open(&root)?;
        s.transaction(|| s.save_logo(&image, &crop, &bbox, &detection))
    })
    .await
    .map_err(db::io_error)?
}

/// Extract a candidate for an existing receipt without rerunning item recognition.
pub async fn extract_existing(state: Arc<State>, receipt: String) -> Result<Value> {
    let root = state.config.data_dir.clone();
    let receipt2 = receipt.clone();
    let (image, bytes) = {
        let _lock = state.storage_lock.lock().await;
        tokio::task::spawn_blocking(move||{
            let s=Store::open(&root)?;
            let img=s.one("SELECT b.*,i.image_id FROM receipt_image i JOIN media_blob b ON b.blob_id=i.current_blob_id JOIN receipt r ON r.receipt_id=i.receipt_id WHERE i.receipt_id=? AND i.deleted_at_utc_ms IS NULL AND r.deleted_at_utc_ms IS NULL ORDER BY i.position LIMIT 1",&[json!(receipt2)])?;
            let bytes=std::fs::read(db::media::safe_path(&root,db::text(&img,"relative_path")?)?).map_err(db::io_error)?;
            Ok::<_,crate::error::AppError>((img,bytes))
        }).await.map_err(db::io_error)??
    };
    let image_url = format!(
        "data:{};base64,{}",
        db::text(&image, "mime")?,
        base64::engine::general_purpose::STANDARD.encode(&bytes)
    );
    let evidence = crate::pipeline::locate_logo(state.clone(), image_url).await?;
    capture(
        state.clone(),
        image,
        bytes,
        evidence["evidence"].to_string(),
    )
    .await?;
    let root = state.config.data_dir.clone();
    tokio::task::spawn_blocking(move||{
        let s=Store::open(&root)?;
        Ok(json!({"data":s.logo_action("list",&json!({"receipt_id":receipt}))?,"catalog_version":s.one("SELECT version FROM catalog_version WHERE id=1",&[])?["version"]}))
    }).await.map_err(db::io_error)?
}

/// Only IDs from this request may become a merchant identity; never accept generated names.
pub fn matched_reference(data: &Value, references: &[Value]) -> Result<Option<Value>> {
    let object = data
        .as_object()
        .filter(|o| o.len() == 1 && o.contains_key("reference_id"))
        .ok_or_else(invalid)?;
    if object["reference_id"].is_null() {
        return Ok(None);
    }
    let id = object["reference_id"].as_str().ok_or_else(invalid)?;
    let index = id
        .strip_prefix('r')
        .and_then(|s| s.parse::<usize>().ok())
        .filter(|i| *i > 0)
        .ok_or_else(invalid)?;
    if format!("r{index:02}") != id {
        return Err(invalid());
    }
    references
        .get(index - 1)
        .cloned()
        .map(Some)
        .ok_or_else(invalid)
}

fn matching_image(bytes: &[u8]) -> Result<String> {
    let mut img = image::load_from_memory(bytes).map_err(db::io_error)?;
    if img.width() > 768 || img.height() > 768 {
        img = img.resize(768, 768, image::imageops::FilterType::Lanczos3);
    }
    let mut out = Cursor::new(Vec::new());
    img.write_to(&mut out, image::ImageFormat::Png)
        .map_err(db::io_error)?;
    Ok(format!(
        "data:image/png;base64,{}",
        base64::engine::general_purpose::STANDARD.encode(out.into_inner())
    ))
}

/// Conflicting identities across batches or photographs must never win by ordering.
pub fn selected_merchant(matches: &[Value]) -> Option<String> {
    let names = matches
        .iter()
        .filter_map(|v| v["name"].as_str())
        .collect::<std::collections::BTreeSet<_>>();
    if names.len() == 1 {
        names.first().map(|s| (*s).to_owned())
    } else {
        None
    }
}

pub async fn match_receipt(state: Arc<State>, receipt: String) -> Result<Value> {
    let root = state.config.data_dir.clone();
    let rid = receipt.clone();
    let snapshot = tokio::task::spawn_blocking(move || Store::open(&root)?.logo_match_inputs(&rid))
        .await
        .map_err(db::io_error)??;
    let references = snapshot["references"].as_array().ok_or_else(invalid)?;
    let mut matches = Vec::new();
    let mut runs = Vec::new();
    let batch_size = (state.config.ocr.max_images - 1).min(15);
    for query in snapshot["candidates"].as_array().ok_or_else(invalid)? {
        for chunk in references.chunks(batch_size) {
            let root = state.config.data_dir.clone();
            let query = query.clone();
            let samples = chunk.to_vec();
            let query_id = query["logo_id"].clone();
            let content = tokio::task::spawn_blocking(move || {
                let mut parts = Vec::new();
                for (index, sample) in std::iter::once(&query).chain(samples.iter()).enumerate() {
                    let label = if index == 0 {
                        "QUERY image:".to_owned()
                    } else {
                        format!("REFERENCE r{index:02}:")
                    };
                    let bytes = std::fs::read(db::media::safe_path(
                        &root,
                        db::text(sample, "relative_path")?,
                    )?)
                    .map_err(db::io_error)?;
                    parts.push(json!({"type":"text","text":label}));
                    parts.push(
                        json!({"type":"image_url","image_url":{"url":matching_image(&bytes)?}}),
                    );
                }
                Ok::<_, crate::error::AppError>(parts)
            })
            .await
            .map_err(db::io_error)??;
            let raw = crate::pipeline::raw_call(&state, &state.config.ocr.url, json!({
                "model":state.config.ocr.model,
                "messages":[{"role":"system","content":state.config.logos.prompt},{"role":"user","content":content}],
                "temperature":0,"seed":42,"max_tokens":4096,"response_format":{"type":"text"},
                "chat_template_kwargs":{"enable_thinking":state.config.ocr.thinking}
            })).await?;
            let decoded = crate::pipeline::decode_content(&raw)?;
            if let Some(reference) = matched_reference(&decoded, chunk)? {
                matches.push(json!({"query_id":query_id,"reference_id":reference["logo_id"],"name":reference["name"]}));
            }
            runs.push(json!({"query_id":query_id,"reference_ids":chunk.iter().map(|v|v["logo_id"].clone()).collect::<Vec<_>>(),"response":raw}));
        }
    }
    let root = state.config.data_dir.clone();
    let current =
        tokio::task::spawn_blocking(move || Store::open(&root)?.logo_match_inputs(&receipt))
            .await
            .map_err(db::io_error)??;
    if current != snapshot {
        return Err(db::conflict());
    }
    // Every batch is considered; conflicting merchant identities remain unknown.
    let selected = selected_merchant(&matches);
    let usage = crate::pipeline::aggregate_usage(
        &runs
            .iter()
            .map(|r| r["response"]["usage"].clone())
            .collect::<Vec<_>>(),
    );
    Ok(
        json!({"model":state.config.ocr.model,"selected":selected,"matches":matches,"inference":runs,"usage":usage,"catalog_version":snapshot["catalog_version"]}),
    )
}
