//! Model-independent OCR preparation. The shared server owns model lifetime.
use crate::{config::Inference, error::AppError};
use base64::{Engine, engine::general_purpose::STANDARD};
use image::{ImageDecoder, ImageFormat, ImageReader, imageops::FilterType};
use serde_json::{Value, json};
use std::io::Cursor;

pub fn prepare(mut body: Value, config: &Inference) -> Result<Value, AppError> {
    let tokens = match body["profile"].as_str() {
        Some("receipt") => config.receipt_output_tokens,
        Some("logo") => config.logo_output_tokens,
        _ => return Err(AppError::invalid("Invalid inference profile.")),
    };
    let messages = body["messages"]
        .as_array_mut()
        .ok_or_else(|| AppError::invalid("Invalid inference messages."))?;
    let count = messages
        .iter()
        .filter_map(|m| m["content"].as_array())
        .flatten()
        .filter(|p| p["type"] == "image_url")
        .count();
    if count == 0 || count > config.max_images {
        return Err(AppError::invalid(
            "Image count outside configured model capacity.",
        ));
    }
    let budget = config.image_pixel_budget / count as u64;
    for message in messages {
        let Some(parts) = message["content"].as_array_mut() else {
            continue;
        };
        for part in parts {
            if part["type"] != "image_url" {
                continue;
            }
            let invalid = || AppError::invalid("Invalid inline image.");
            let url = part["image_url"]["url"].as_str().ok_or_else(invalid)?;
            let (prefix, data) = url.split_once(',').ok_or_else(invalid)?;
            if !matches!(
                prefix,
                "data:image/jpeg;base64" | "data:image/png;base64" | "data:image/webp;base64"
            ) {
                return Err(invalid());
            }
            let bytes = STANDARD.decode(data).map_err(|_| invalid())?;
            let reader = ImageReader::new(Cursor::new(bytes))
                .with_guessed_format()
                .map_err(|_| invalid())?;
            let mut decoder = reader.into_decoder().map_err(|_| invalid())?;
            let orientation = decoder.orientation().map_err(|_| invalid())?;
            let mut photo = image::DynamicImage::from_decoder(decoder).map_err(|_| invalid())?;
            photo.apply_orientation(orientation);
            let pixels = u64::from(photo.width()) * u64::from(photo.height());
            if pixels == 0 {
                return Err(invalid());
            }
            if pixels > budget {
                let scale = (budget as f64 / pixels as f64).sqrt();
                photo = photo.resize_exact(
                    ((photo.width() as f64 * scale) as u32).max(1),
                    ((photo.height() as f64 * scale) as u32).max(1),
                    FilterType::Lanczos3,
                );
            }
            let mut output = Cursor::new(Vec::new());
            image::DynamicImage::ImageRgb8(photo.to_rgb8())
                .write_to(&mut output, ImageFormat::Png)
                .map_err(|_| invalid())?;
            part["image_url"]["url"] = json!(format!(
                "data:image/png;base64,{}",
                STANDARD.encode(output.into_inner())
            ));
        }
    }
    let mut request = json!({
        "model": config.model, "messages": body["messages"], "stream": false,
        "max_tokens": tokens, "temperature": config.temperature, "seed": config.seed,
    });
    if let Some(thinking) = config.thinking {
        request["chat_template_kwargs"] = json!({"enable_thinking": thinking});
    }
    Ok(request)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn config() -> Inference {
        Inference {
            base_url: "http://localhost:8080/v1".into(),
            api_key: "secret".into(),
            model: "shared-vision".into(),
            max_images: 4,
            image_pixel_budget: 800,
            receipt_output_tokens: 1234,
            logo_output_tokens: 456,
            temperature: 0.0,
            seed: 42,
            thinking: Some(true),
        }
    }
    fn request(profile: &str, count: usize) -> Value {
        let mut png = Cursor::new(Vec::new());
        image::DynamicImage::new_rgb8(100, 100)
            .write_to(&mut png, ImageFormat::Png)
            .unwrap();
        let part = json!({"type":"image_url","image_url":{"url":format!("data:image/png;base64,{}", STANDARD.encode(png.into_inner()))}});
        json!({"profile": profile, "messages":[{"role":"user", "content":vec![part; count]}]})
    }
    #[test]
    fn preserves_every_page_with_shared_pixel_budget_and_profile_options() {
        let result = prepare(request("receipt", 2), &config()).unwrap();
        assert_eq!(result["model"], "shared-vision");
        assert_eq!(result["max_tokens"], 1234);
        assert!(result.get("profile").is_none());
        assert!(result.get("api_key").is_none());
        let parts = result["messages"][0]["content"].as_array().unwrap();
        assert_eq!(parts.len(), 2);
        for part in parts {
            let data = part["image_url"]["url"]
                .as_str()
                .unwrap()
                .split_once(',')
                .unwrap()
                .1;
            let image = image::load_from_memory(&STANDARD.decode(data).unwrap()).unwrap();
            assert_eq!((image.width(), image.height()), (20, 20));
        }
        let mut config = config();
        config.thinking = None;
        let result = prepare(request("logo", 1), &config).unwrap();
        assert_eq!(result["max_tokens"], 456);
        assert!(result.get("chat_template_kwargs").is_none());
    }
    #[test]
    fn rejects_invalid_or_excess_images_without_dropping_pages() {
        for count in [0, 5] {
            assert!(prepare(request("receipt", count), &config()).is_err());
        }
        assert!(prepare(request("unknown", 1), &config()).is_err());
        for url in [
            "https://example.test/photo.png",
            "data:image/png;base64,bad",
        ] {
            let mut body = request("receipt", 1);
            body["messages"][0]["content"][0]["image_url"]["url"] = json!(url);
            assert!(prepare(body, &config()).is_err());
        }
    }
}
