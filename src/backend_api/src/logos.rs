//! Logo candidates are visual evidence, never a new alias until the user labels one.
use crate::{
    State,
    db::{self, Result, Store, invalid},
};
use base64::Engine;
use image::{GenericImageView, ImageDecoder};
use serde_json::{Value, json};
use std::{
    io::Cursor,
    sync::{Arc, LazyLock},
};
static HEADER: LazyLock<regex::Regex> = LazyLock::new(|| {
    regex::Regex::new(
        r"(?i)<\|det\|>(title|header|figure|image|logo|text)\s*\[(\d+),\s*(\d+),\s*(\d+),\s*(\d+)\]",
    )
    .unwrap()
});

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
    let mut regions = HEADER
        .captures_iter(evidence)
        .filter_map(|c| {
            let b = [2, 3, 4, 5].map(|i| c[i].parse::<f64>().unwrap_or(0.) / 1000.);
            (b[1] < 0.25
                && b[3] <= 0.35
                && b[2] > b[0] + 0.08
                && b[3] > b[1] + 0.01
                && b.iter().all(|v| (0.0..=1.0).contains(v)))
            .then(|| (c[1].to_ascii_lowercase(), b))
        })
        .collect::<Vec<_>>();
    regions.sort_by(|a, b| a.1[1].total_cmp(&b.1[1]).then(a.1[0].total_cmp(&b.1[0])));
    if let Some((_, first)) = regions.first() {
        let mut bounds = *first;
        let anchor_height = first[3] - first[1];
        let mut merged = false;
        for (kind, next) in regions.iter().skip(1) {
            // Body text such as branch/address/phone must not expand the wordmark.
            if kind == "text" {
                continue;
            }
            let overlap = (bounds[2].min(next[2]) - bounds[0].max(next[0])).max(0.);
            let narrow_width = (bounds[2] - bounds[0]).min(next[2] - next[0]);
            let gap = (next[1] - bounds[3]).max(0.);
            let height = next[3].max(bounds[3]) - bounds[1];
            if overlap >= narrow_width * 0.5
                && gap <= (anchor_height * 0.2).min(0.012)
                && next[3] - next[1] >= anchor_height * 0.22
                && height <= (anchor_height * 2.5).min(0.18)
            {
                bounds = [
                    bounds[0].min(next[0]),
                    bounds[1],
                    bounds[2].max(next[2]),
                    bounds[3].max(next[3]),
                ];
                merged = true;
            }
        }
        bbox = [
            (bounds[0] - 0.012).max(0.),
            (bounds[1] - 0.008).max(0.),
            (bounds[2] + 0.012).min(1.),
            (bounds[3] + 0.008).min(1.),
        ];
        detection = if merged {
            "ocr_header_merged"
        } else {
            "ocr_header"
        };
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
    capture(state.clone(), image, bytes, evidence).await?;
    let root = state.config.data_dir.clone();
    tokio::task::spawn_blocking(move||{
        let s=Store::open(&root)?;
        Ok(json!({"data":s.logo_action("list",&json!({"receipt_id":receipt}))?,"catalog_version":s.one("SELECT version FROM catalog_version WHERE id=1",&[])?["version"]}))
    }).await.map_err(db::io_error)?
}

pub const MATCH_MODEL: &str = "superpoint-lightglue-foreground-v1";

/// This score describes verified foreground correspondence, never a probability.
pub fn select_match(
    scores: &[Value],
    threshold: f64,
    margin: f64,
    evidence: f64,
) -> Result<Option<String>> {
    let mut by_name = std::collections::HashMap::<String, f64>::new();
    for row in scores {
        let score = row["score"]
            .as_f64()
            .filter(|n| n.is_finite() && (0.0..=1.0).contains(n))
            .ok_or_else(invalid)?;
        let support = row["evidence"]
            .as_f64()
            .filter(|n| n.is_finite() && (0.0..=1.0).contains(n))
            .ok_or_else(invalid)?;
        if support >= evidence {
            let name = db::text(row, "name")?.to_owned();
            by_name
                .entry(name)
                .and_modify(|v| *v = v.max(score))
                .or_insert(score);
        }
    }
    let mut ranked = by_name.into_iter().collect::<Vec<_>>();
    ranked.sort_by(|a, b| b.1.total_cmp(&a.1).then(a.0.cmp(&b.0)));
    Ok(ranked
        .first()
        .filter(|(_, score)| {
            *score >= threshold
                && ranked
                    .get(1)
                    .is_none_or(|(_, second)| score - second >= margin && score > second)
        })
        .map(|(name, _)| name.clone()))
}

pub async fn match_receipt(state: Arc<State>, receipt: String) -> Result<Value> {
    let root = state.config.data_dir.clone();
    let rid = receipt.clone();
    let snapshot = tokio::task::spawn_blocking(move || Store::open(&root)?.logo_match_inputs(&rid))
        .await
        .map_err(db::io_error)??;
    let references = snapshot["references"].as_array().ok_or_else(invalid)?;
    let mut scores = Vec::new();
    for query in snapshot["candidates"].as_array().ok_or_else(invalid)? {
        let bytes = tokio::fs::read(db::media::safe_path(
            &state.config.data_dir,
            db::text(query, "relative_path")?,
        )?)
        .await
        .map_err(db::io_error)?;
        let encoded = base64::engine::general_purpose::STANDARD.encode(bytes);
        // Bound transport and OCR working memory; every registered sample is considered.
        for chunk in references.chunks(8) {
            let mut samples = Vec::new();
            for reference in chunk {
                let bytes = tokio::fs::read(db::media::safe_path(
                    &state.config.data_dir,
                    db::text(reference, "relative_path")?,
                )?)
                .await
                .map_err(db::io_error)?;
                samples.push(json!({"id":reference["logo_id"],"image":base64::engine::general_purpose::STANDARD.encode(bytes)}));
            }
            let response = state
                .client
                .post(format!(
                    "{}/v1/logo/match",
                    state.config.ocr.url.trim_end_matches('/')
                ))
                .json(&json!({"image":encoded,"references":samples}))
                .send()
                .await
                .map_err(db::io_error)?
                .error_for_status()
                .map_err(db::io_error)?
                .json::<Value>()
                .await
                .map_err(db::io_error)?;
            if response["model"] != MATCH_MODEL {
                return Err(invalid());
            }
            let matches = response["scores"]
                .as_array()
                .filter(|v| v.len() == chunk.len())
                .ok_or_else(invalid)?;
            let mut seen = std::collections::HashSet::new();
            for result in matches {
                let id = db::text(result, "id")?;
                let reference = chunk
                    .iter()
                    .find(|r| r["logo_id"] == id)
                    .ok_or_else(invalid)?;
                if !seen.insert(id) {
                    return Err(invalid());
                }
                let mut row = result.clone();
                row["name"] = reference["name"].clone();
                row["query_id"] = query["logo_id"].clone();
                scores.push(row);
            }
        }
    }
    // A renamed/deleted alias or rotated/deleted photograph invalidates the in-flight result.
    let root = state.config.data_dir.clone();
    let current =
        tokio::task::spawn_blocking(move || Store::open(&root)?.logo_match_inputs(&receipt))
            .await
            .map_err(db::io_error)??;
    if current != snapshot {
        return Err(db::conflict());
    }
    let config = &state.config.logos;
    let selected = select_match(
        &scores,
        config.identity_threshold,
        config.margin,
        config.minimum_evidence,
    )?;
    scores.sort_by(|a, b| {
        b["score"]
            .as_f64()
            .unwrap()
            .total_cmp(&a["score"].as_f64().unwrap())
    });
    Ok(
        json!({"model":MATCH_MODEL,"selected":selected,"scores":scores,"catalog_version":snapshot["catalog_version"]}),
    )
}
