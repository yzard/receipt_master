use serde::Deserialize;
use std::{net::IpAddr, path::PathBuf};

#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Config {
    pub general: General,
    pub inference: Inference,
}
#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct General {
    pub host: IpAddr,
    pub port: u16,
    pub jwt_secret: String,
    pub web_path: PathBuf,
    pub apk_path: PathBuf,
    pub timeout_seconds: u64,
    pub job_workers: usize,
    pub repair_attempts: usize,
}
#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Inference {
    pub base_url: String,
    pub api_key: String,
    pub model: String,
    pub max_images: usize,
    pub image_pixel_budget: u64,
    pub receipt_output_tokens: u32,
    pub logo_output_tokens: u32,
    pub temperature: f64,
    pub seed: i64,
    pub thinking: Option<bool>,
}
impl Config {
    pub fn parse(text: &str) -> Result<Self, Box<dyn std::error::Error + Send + Sync>> {
        let c: Self = toml::from_str(text)?;
        let url = reqwest::Url::parse(&c.inference.base_url)?;
        if !matches!(url.scheme(), "http" | "https")
            || url.host_str().is_none()
            || !url.username().is_empty()
            || url.password().is_some()
            || c.general.jwt_secret.trim().len() < 24
            || c.inference.api_key.trim().is_empty()
            || c.inference.api_key.trim() == c.general.jwt_secret.trim()
            || url.query().is_some()
            || url.fragment().is_some()
            || c.inference.api_key.contains(['\r', '\n'])
            || c.inference.model.trim().is_empty()
            || !(2..=256).contains(&c.inference.max_images)
            || c.inference.image_pixel_budget < c.inference.max_images as u64
            || c.inference.image_pixel_budget > 100_000_000
            || c.inference.receipt_output_tokens == 0
            || c.inference.logo_output_tokens == 0
            || !c.inference.temperature.is_finite()
            || !(0.0..=2.0).contains(&c.inference.temperature)
            || c.general.port == 0
            || !(1..=8).contains(&c.general.job_workers)
            || c.general.timeout_seconds == 0
            || c.general.repair_attempts > 2
        {
            return Err("Invalid backend API configuration".into());
        }
        Ok(c)
    }
}
