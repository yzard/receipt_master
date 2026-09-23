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
pub(crate) async fn raw_call(state: &State, body: Value) -> Result<Value, AppError> {
    let _guard = state.lock.acquire().await.expect("inference semaphore");
    let result: Value = state
        .client
        .post(format!(
            "{}/v1/chat/completions",
            state.config.ocr.url.trim_end_matches('/')
        ))
        .header(reqwest::header::AUTHORIZATION, &state.ocr_authorization)
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
pub(crate) async fn image_capacity(state: &State) -> Result<usize, AppError> {
    let result: Value = state
        .client
        .get(format!(
            "{}/capabilities",
            state.config.ocr.url.trim_end_matches('/')
        ))
        .header(reqwest::header::AUTHORIZATION, &state.ocr_authorization)
        .timeout(std::time::Duration::from_secs(5))
        .send()
        .await
        .map_err(AppError::inference)?
        .error_for_status()
        .map_err(AppError::inference)?
        .json()
        .await
        .map_err(AppError::inference)?;
    result["max_images"]
        .as_u64()
        .filter(|n| *n >= 2 && *n <= 256)
        .map(|n| n as usize)
        .ok_or_else(|| {
            AppError::new(
                502,
                "invalid_ocr_capabilities",
                "Invalid OCR image capacity.",
            )
        })
}
/// Decode one complete JSON object; only a whole-response Markdown fence is tolerated.
pub fn decode_content(raw: &Value) -> Result<Value, AppError> {
    if raw["choices"][0]["finish_reason"] != "stop" {
        return Err(structured("Incomplete model output"));
    }
    let content = raw["choices"][0]["message"]["content"]
        .as_str()
        .ok_or_else(|| structured("Missing model content"))?
        .trim();
    let content = if content.starts_with("```") {
        let (header, rest) = content
            .split_once('\n')
            .ok_or_else(|| structured("Invalid JSON fence"))?;
        if !matches!(header.trim(), "```" | "```json") {
            return Err(structured("Invalid JSON fence"));
        }
        rest.strip_suffix("```")
            .ok_or_else(|| structured("Invalid JSON fence"))?
            .trim()
    } else {
        content
    };
    let value: Value =
        serde_json::from_str(content).map_err(|_| structured("Invalid model JSON"))?;
    if !value.is_object() {
        return Err(structured("Model output must be an object"));
    }
    Ok(value)
}
/// Project extra metadata out of the model boundary, without changing recognized field values.
/// Required fields, types, amounts, references and evidence are still strictly validated.
pub fn normalize_output(raw: &Value) -> Result<(Value, Vec<String>), AppError> {
    fn project(value: &mut Value, schema: &Value, path: &str, removed: &mut Vec<String>) {
        if let (Some(object), Some(properties)) =
            (value.as_object_mut(), schema["properties"].as_object())
        {
            object.retain(|key, _| {
                let keep = properties.contains_key(key);
                if !keep {
                    removed.push(format!("{path}/{key}"));
                }
                keep
            });
            for (key, value) in object {
                project(value, &properties[key], &format!("{path}/{key}"), removed);
            }
        } else if let Some(array) = value.as_array_mut() {
            for (i, value) in array.iter_mut().enumerate() {
                project(value, &schema["items"], &format!("{path}/{i}"), removed);
            }
        }
    }
    let mut data = decode_content(raw)?;
    let schema: Value = serde_json::from_str(include_str!("receipt_schema.json")).unwrap();
    let mut removed = Vec::new();
    project(&mut data, &schema, "", &mut removed);
    Ok((data, removed))
}
pub async fn recognize(state: Arc<State>, body: Value) -> Result<Value, AppError> {
    let input = tokio::task::spawn_blocking(move || extract(body, crate::PUBLIC_MODEL_ID))
        .await
        .map_err(|_| AppError::new(500, "internal_error", "Request validation failed."))??;
    if input.images.len() > image_capacity(&state).await? {
        return Err(AppError::invalid(
            "Too many photos; no photos were dropped.",
        ));
    }
    let (mut prompt, profile) = state.prompts.select(input.known_store.as_deref());
    prompt.push('\n');
    prompt.push_str(&state.prompts.receipt.schema_instruction);
    prompt.push('\n');
    prompt.push_str(include_str!("receipt_schema.json"));
    let mut content = vec![
        json!({"type":"text","text":format!("{} {}",state.prompts.receipt.known_store_prefix,input.known_store.as_deref().unwrap_or(&state.prompts.receipt.unknown_store))}),
    ];
    for message in &input.prompts {
        content.push(json!({"type":"text","text":message["content"]}));
    }
    content.extend(
        input
            .images
            .iter()
            .map(|image| json!({"type":"image_url","image_url":{"url":image}})),
    );
    let mut messages = vec![
        json!({"role":"system","content":prompt}),
        json!({"role":"user","content":content}),
    ];
    let mut runs = Vec::new();
    for attempt in 0..=state.config.general.repair_attempts {
        let raw = raw_call(
            &state,
            json!({
                "profile":"receipt","messages":messages
            }),
        )
        .await?;
        let result = normalize_output(&raw).and_then(|(data, removed)| {
            validate_receipt(&data, input.images.len())?;
            if data["lines"].as_array().is_none_or(|v| v.is_empty()) {
                return Err(structured("No receipt items extracted"));
            }
            if input.validator.as_ref().is_some_and(|v| !v.is_valid(&data)) {
                return Err(structured("Receipt does not satisfy the requested schema"));
            }
            Ok((data, removed))
        });
        runs.push(raw);
        match result {
            Ok((mut data, removed)) => {
                if let Some((sum, total)) = arithmetic_difference(&data) {
                    let difference = (sum - total).abs();
                    let note = format!(
                        "明细合计与票面总额相差 {}.{:03} {}，请核对。",
                        difference / 1000,
                        difference % 1000,
                        data["currency"].as_str().unwrap_or("")
                    );
                    data["lines"][0]["review_notes"]
                        .as_array_mut()
                        .unwrap()
                        .push(json!(note));
                }
                let usages = runs.iter().map(|r| r["usage"].clone()).collect::<Vec<_>>();
                return Ok(
                    json!({"id":format!("receipt-{}",uuid::Uuid::new_v4()),"object":"chat.completion","model":crate::PUBLIC_MODEL_ID,
                    "choices":[{"index":0,"message":{"role":"assistant","content":data.to_string()},"finish_reason":"stop"}],
                    "usage":aggregate_usage(&usages),"receipt_parsing":{"version":"structured-v2","profile":profile,"image_count":input.images.len(),"arithmetic_mismatch":arithmetic_difference(&data).is_some(),"removed_fields":removed},"model_runs":runs}),
                );
            }
            Err(error) if attempt < state.config.general.repair_attempts => {
                // Retry the original photos with schema feedback, never fabricate replacement values.
                messages.push(json!({"role":"user","content":format!("{}{}{}",state.prompts.receipt.repair_prefix,error.message,state.prompts.receipt.repair_suffix)}));
            }
            Err(error) => return Err(error),
        }
    }
    unreachable!("bounded inference loop always returns")
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
pub async fn locate_logo(state: Arc<State>, image: String) -> Result<Value, AppError> {
    let (image, header_height) =
        tokio::task::spawn_blocking(move || crate::logos::localization_input(&image))
            .await
            .map_err(crate::db::io_error)??;
    let raw = raw_call(&state,json!({
        "profile":"logo","messages":[{"role":"system","content":state.prompts.logo.locate},{"role":"user","content":[{"type":"image_url","image_url":{"url":image}}]}]
    })).await?;
    let mut data = decode_content(&raw)?;
    if data.get("box").is_none() {
        return Err(structured("Missing logo box"));
    }
    if !data["box"].is_null() {
        let b = data["box"]
            .as_array()
            .filter(|b| b.len() == 4)
            .ok_or_else(|| structured("Invalid logo box"))?;
        if b.iter().any(|v| v.as_u64().is_none_or(|v| v > 1000))
            || b[0].as_f64() >= b[2].as_f64()
            || b[1].as_f64() >= b[3].as_f64()
        {
            return Err(structured("Invalid logo box"));
        }
        data["box"] = json!([
            b[0].as_f64().unwrap() / 1000.0,
            b[1].as_f64().unwrap() / 1000.0 * header_height,
            b[2].as_f64().unwrap() / 1000.0,
            b[3].as_f64().unwrap() / 1000.0 * header_height
        ]);
    }
    Ok(json!({"evidence":data,"usage":raw["usage"],"model_response":raw}))
}
