//! Translate the same extraction contract into a model's native request template.
//! No model answers or merchandise heuristics are introduced here.
use crate::{config::VisionProtocol, error::AppError};
use serde_json::{Value, json};

fn template(schema: &Value, key: &str) -> Result<Value, AppError> {
    if let Some(values) = schema["enum"].as_array() {
        return Ok(Value::Array(
            values.iter().filter(|v| !v.is_null()).cloned().collect(),
        ));
    }
    let kind = schema["type"].as_str().or_else(|| {
        schema["type"]
            .as_array()?
            .iter()
            .filter_map(Value::as_str)
            .find(|s| *s != "null")
    });
    Ok(match kind {
        Some("object") => Value::Object(
            schema["properties"]
                .as_object()
                .ok_or_else(|| {
                    AppError::invalid("Extraction template requires object properties.")
                })?
                .iter()
                .map(|(k, v)| Ok((k.clone(), template(v, k)?)))
                .collect::<Result<_, AppError>>()?,
        ),
        Some("array") => json!([template(&schema["items"], key)?]),
        Some("null") => Value::Null,
        Some("string") => json!(
            if matches!(key, "name" | "sku" | "tax_code" | "address" | "branch") {
                "verbatim-string"
            } else {
                "string"
            }
        ),
        Some("number" | "integer" | "boolean") => json!(kind.unwrap()),
        _ => {
            return Err(AppError::invalid(
                "Unsupported extraction template schema type.",
            ));
        }
    })
}

pub fn adapt(request: &mut Value, protocol: VisionProtocol) -> Result<(), AppError> {
    if protocol == VisionProtocol::Chat {
        return Ok(());
    }
    let schema = &request["response_format"]["json_schema"]["schema"];
    if !schema.is_object() {
        return Err(AppError::invalid(
            "NuExtract requires an explicit JSON schema.",
        ));
    }
    let output_template = template(schema, "")?.to_string();
    let mut instructions = Vec::new();
    let mut images = Vec::new();
    let mut previous = None;
    for message in request["messages"].as_array().unwrap() {
        if message["role"] == "assistant" {
            previous = message["content"].as_str().map(str::to_owned);
        } else if let Some(text) = message["content"].as_str() {
            instructions.push(text.to_owned());
        } else if let Some(parts) = message["content"].as_array() {
            for part in parts {
                if part["type"] == "image_url" {
                    images.push(part.clone());
                } else if let Some(text) = part["text"].as_str() {
                    instructions.push(text.to_owned());
                }
            }
        }
    }
    let instructions = instructions.join("\n");
    let mut kwargs = json!({"template":output_template});
    match protocol {
        VisionProtocol::Nuextract3 => {
            kwargs["instructions"] = json!(instructions);
            kwargs["enable_thinking"] = json!(false);
            if let Some(previous) = previous {
                kwargs["previous_output"] = json!(previous);
            }
            request["messages"] = json!([{"role":"user","content":images}]);
        }
        VisionProtocol::Nuextract2 => {
            // The pinned v2 template drops images when text shares their message,
            // and renders only the first image per message. Preserve each photo.
            let mut messages = vec![json!({"role":"system","content":instructions})];
            for image in images {
                messages.push(json!({"role":"user","content":[image]}));
            }
            if let Some(previous) = previous {
                messages[0]["content"] = json!(format!(
                    "{}\nPrevious invalid output to correct:\n{}",
                    messages[0]["content"].as_str().unwrap(),
                    previous
                ));
            }
            request["messages"] = json!(messages);
        }
        VisionProtocol::Chat => unreachable!(),
    }
    request["chat_template_kwargs"] = kwargs;
    Ok(())
}
