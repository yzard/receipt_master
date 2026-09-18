use crate::{State, error::AppError};
use base64::Engine;
use serde_json::{Value, json};
use std::sync::Arc;

pub struct Input {
    pub images: Vec<String>,
    pub known_store: Option<String>,
    pub prompts: Vec<Value>,
    pub format: Option<Value>,
    pub validator: Option<jsonschema::Validator>,
}
fn local_refs(value: &Value) -> bool {
    match value {
        Value::Object(map) => map.iter().all(|(key, value)| {
            (!matches!(key.as_str(), "$ref" | "$dynamicRef")
                || value.as_str().is_some_and(|s| s.starts_with('#')))
                && local_refs(value)
        }),
        Value::Array(a) => a.iter().all(local_refs),
        _ => true,
    }
}
pub fn extract(body: Value, model: &str) -> Result<Input, AppError> {
    if body["model"] != model {
        return Err(AppError::new(
            404,
            "model_not_found",
            "Unknown model; query /v1/models.",
        ));
    }
    if body.get("stream").is_some_and(|v| v != false)
        || body.get("n").is_some_and(|v| v != 1)
        || body
            .get("tools")
            .is_some_and(|v| !v.is_null() && v != &json!([]))
    {
        return Err(AppError::invalid(
            "Only one non-streaming completion without tools is supported.",
        ));
    }
    let messages = body["messages"]
        .as_array()
        .filter(|v| !v.is_empty())
        .ok_or_else(|| AppError::invalid("messages must be a nonempty array."))?;
    let mut images = Vec::new();
    let mut prompts = Vec::new();
    for msg in messages {
        let role = msg["role"]
            .as_str()
            .filter(|r| matches!(*r, "system" | "developer" | "user"))
            .ok_or_else(|| AppError::invalid("Unsupported message role."))?;
        if let Some(text) = msg["content"].as_str() {
            prompts.push(json!({"role":role,"content":text}));
        } else if let Some(parts) = msg["content"].as_array() {
            for part in parts {
                match part["type"].as_str() {
                    Some("text") if part["text"].is_string() => {
                        prompts.push(json!({"role":role,"content":part["text"]}))
                    }
                    Some("image_url") if part["image_url"]["url"].is_string() => {
                        images.push(part["image_url"]["url"].as_str().unwrap().to_owned())
                    }
                    _ => return Err(AppError::invalid("Unsupported message content.")),
                }
            }
        } else {
            return Err(AppError::invalid(
                "Message content must be text or an array.",
            ));
        }
    }
    if images.is_empty() {
        return Err(AppError::new(
            400,
            "invalid_image",
            "Send the photos of one receipt in capture order.",
        ));
    }
    for image in &images {
        let (prefix, data) = image
            .split_once(',')
            .ok_or_else(|| AppError::new(400, "invalid_image", "Inline base64 image required."))?;
        if !matches!(
            prefix,
            "data:image/jpeg;base64" | "data:image/png;base64" | "data:image/webp;base64"
        ) {
            return Err(AppError::new(
                400,
                "invalid_image",
                "Remote images are not fetched; use inline JPEG, PNG or WebP.",
            ));
        }
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(data)
            .map_err(|_| AppError::new(400, "invalid_image", "Invalid base64 image."))?;
        let reader = image::ImageReader::new(std::io::Cursor::new(bytes))
            .with_guessed_format()
            .map_err(|_| AppError::new(400, "invalid_image", "Invalid image."))?;
        if !matches!(
            reader.format(),
            Some(image::ImageFormat::Jpeg | image::ImageFormat::Png | image::ImageFormat::WebP)
        ) {
            return Err(AppError::new(400, "invalid_image", "Invalid image format."));
        }
        reader
            .decode()
            .map_err(|_| AppError::new(400, "invalid_image", "Invalid image data."))?;
    }
    let format = body
        .get("response_format")
        .filter(|v| !v.is_null())
        .cloned();
    let validator = if let Some(f) = &format {
        let schema = &f["json_schema"]["schema"];
        if f["type"] != "json_schema" || !schema.is_object() || !local_refs(schema) {
            return Err(AppError::new(
                400,
                "invalid_schema",
                "A JSON Schema without external references is required.",
            ));
        }
        Some(
            jsonschema::validator_for(schema)
                .map_err(|_| AppError::new(400, "invalid_schema", "Invalid JSON Schema."))?,
        )
    } else {
        None
    };
    let known_store = match body.get("receipt_context") {
        None | Some(Value::Null) => None,
        Some(context) if context.is_object() => match context.get("known_store") {
            None | Some(Value::Null) => None,
            Some(Value::String(store)) => Some(store.clone()),
            _ => {
                return Err(AppError::invalid(
                    "receipt_context.known_store must be text or null.",
                ));
            }
        },
        _ => return Err(AppError::invalid("receipt_context must be an object.")),
    };
    Ok(Input {
        images,
        known_store,
        prompts,
        format,
        validator,
    })
}
async fn raw_call(state: &State, url: &str, body: Value) -> Result<Value, AppError> {
    let result: Value = state
        .client
        .post(format!("{}/v1/ocr/recognize", url.trim_end_matches('/')))
        .json(&body)
        .send()
        .await
        .map_err(AppError::inference)?
        .error_for_status()
        .map_err(AppError::inference)?
        .json()
        .await
        .map_err(|error| {
            tracing::warn!(?error, "Model response JSON decode failed");
            AppError::new(502, "invalid_model_response", "Invalid model response.")
        })?;
    Ok(result)
}
/// Read all photos using both OCR engines; no receipt interpretation happens upstream.
pub async fn read_ocr(state: &State, images: &[String]) -> Result<Value, AppError> {
    let _guard = state.lock.acquire().await.expect("inference semaphore");
    let content: Vec<_> = images
        .iter()
        .map(|image| json!({"type":"image_url","image_url":{"url":image}}))
        .collect();
    let result=raw_call(state,&state.config.ocr.url,json!({"model":state.config.ocr.model,"messages":[{"role":"user","content":content}],"max_tokens":state.config.ocr.output_tokens})).await?;
    let pages = result["pages"]
        .as_array()
        .ok_or_else(|| structured("Missing dual OCR pages"))?;
    if pages.len() != images.len()
        || pages
            .iter()
            .any(|p| !p["unlimited"].is_string() || !p["paddle"]["words"].is_array())
    {
        return Err(structured("Incomplete dual OCR pages"));
    }
    Ok(result)
}
pub async fn recognize(state: Arc<State>, body: Value) -> Result<Value, AppError> {
    recognize_with_ocr(state, body, None).await
}
pub async fn recognize_with_ocr(
    state: Arc<State>,
    body: Value,
    cached: Option<Value>,
) -> Result<Value, AppError> {
    let model = state.config.served_model.clone();
    let input = tokio::task::spawn_blocking(move || extract(body, &model))
        .await
        .map_err(|_| AppError::new(500, "internal_error", "Request validation failed."))??;
    if input.images.len() > state.config.ocr.max_images {
        return Err(AppError::invalid(
            "Too many photos; no photos were dropped.",
        ));
    }
    let raw = match cached {
        Some(raw) => raw,
        None => read_ocr(&state, &input.images).await?,
    };
    let pages = raw["pages"]
        .as_array()
        .ok_or_else(|| structured("Missing OCR pages"))?;
    if pages.len() != input.images.len() {
        return Err(structured("OCR page count mismatch"));
    }
    let data = crate::parsing::parse(pages, input.known_store.as_deref());
    validate_receipt(&data, pages.len())?;
    if data["lines"]
        .as_array()
        .is_none_or(|lines| lines.is_empty())
    {
        return Err(AppError::new(
            502,
            "empty_output",
            "No receipt items could be parsed; review the photos or enter the receipt manually.",
        ));
    }
    if let Some(validator) = input.validator
        && !validator.is_valid(&data)
    {
        return Err(structured("Receipt does not satisfy the requested schema"));
    }
    let content = if input.format.is_some() {
        data.to_string()
    } else {
        pages
            .iter()
            .map(|p| p["unlimited"].as_str().unwrap_or(""))
            .collect::<Vec<_>>()
            .join("\n")
    };
    Ok(
        json!({"id":format!("receipt-{}",uuid::Uuid::new_v4()),"object":"chat.completion","model":state.config.served_model,
        "choices":[{"index":0,"message":{"role":"assistant","content":content},"finish_reason":"stop"}],
        "usage":raw["usage"],"receipt_parsing":{"version":"dual-ocr-v1","profile":crate::parsing::profile(input.known_store.as_deref()),"image_count":pages.len(),"arithmetic_mismatch":arithmetic_difference(&data).is_some()},"ocr":raw}),
    )
}
fn structured(message: &'static str) -> AppError {
    AppError::new(502, "invalid_structured_output", message)
}
pub fn validate_receipt(data: &Value, images: usize) -> Result<(), AppError> {
    let schema: Value = serde_json::from_str(include_str!("receipt_schema.json")).unwrap();
    if !jsonschema::validator_for(&schema).unwrap().is_valid(data) {
        return Err(structured("Receipt schema violation"));
    }
    crate::jobs::fixed(&data["total"], 3).map_err(|_| structured("Invalid total decimal"))?;
    crate::receipt_lines::amounts(data, 3)
        .map_err(|_| structured("Net product amount requires explicit linked item discounts"))?;
    let lines = data["lines"].as_array().unwrap();
    for (i, line) in lines.iter().enumerate() {
        if line["kind"] == "item_discount" {
            let target = line["discount_target_index"]
                .as_u64()
                .ok_or_else(|| structured("Item discount requires a product target"))?
                as usize;
            if target == i || lines.get(target).is_none_or(|v| v["kind"] != "product") {
                return Err(structured("Invalid discount product reference"));
            }
        } else if !line["discount_target_index"].is_null() {
            return Err(structured("Only item discounts may reference a product"));
        }
        for e in line["evidence"].as_array().unwrap() {
            let b = e["box"].as_array().unwrap();
            if e["image_index"].as_u64().unwrap() as usize >= images
                || b[0].as_f64() >= b[2].as_f64()
                || b[1].as_f64() >= b[3].as_f64()
            {
                return Err(structured("Invalid image evidence reference or box"));
            }
        }
        if line["package_weight"].is_null() != line["package_weight_unit"].is_null() {
            return Err(structured(
                "Package weight and unit must both be present or both null",
            ));
        }
        for (key, digits) in [
            ("quantity", 6),
            ("package_weight", 9),
            ("unit_price", 9),
            ("amount", 3),
        ] {
            crate::jobs::fixed(&line[key], digits)
                .map_err(|_| structured("Invalid decimal precision or range"))?;
        }
    }
    Ok(())
}
/// Numeric cross-check only. Unknown amounts do not become invented balancing entries.
pub fn arithmetic_difference(data: &Value) -> Option<(i128, i128)> {
    let total = i128::from(crate::jobs::fixed(&data["total"], 3).ok()?.as_i64()?);
    let lines = data["lines"].as_array()?;
    if lines.is_empty() {
        return None;
    }
    let converted = crate::receipt_lines::amounts(data, 3).ok()?;
    let sum = converted.iter().try_fold(0i128, |sum, (gross, _)| {
        sum.checked_add(i128::from(gross.as_i64()?))
    })?;
    (sum != total).then_some((sum, total))
}
pub fn aggregate_usage(runs: &[Value]) -> Value {
    let mut usage = serde_json::Map::new();
    for key in ["prompt_tokens", "completion_tokens", "total_tokens"] {
        let Some(sum) = runs
            .iter()
            .try_fold(0u64, |sum, r| sum.checked_add(r[key].as_u64()?))
        else {
            return Value::Null;
        };
        usage.insert(key.into(), json!(sum));
    }
    Value::Object(usage)
}

/// Localize only the top store wordmark/logo; identity remains the image alias match.
pub async fn locate_logo(state: Arc<State>, image: String) -> Result<String, AppError> {
    let raw = read_ocr(&state, &[image]).await?;
    Ok(raw["pages"][0]["unlimited"]
        .as_str()
        .ok_or_else(|| structured("Missing OCR layout"))?
        .to_owned())
}
