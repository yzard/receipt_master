use serde::Deserialize;
use std::{net::IpAddr, path::PathBuf};

#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Config {
    pub general: General,
    pub ocr: Ocr,
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
pub struct Ocr {
    pub url: String,
    pub api_key: String,
}
impl Config {
    pub fn parse(text: &str) -> Result<Self, Box<dyn std::error::Error + Send + Sync>> {
        Self::parse_with_ocr_overrides(text, None, None)
    }

    pub fn parse_with_ocr_overrides(
        text: &str,
        url_override: Option<&str>,
        api_key_override: Option<&str>,
    ) -> Result<Self, Box<dyn std::error::Error + Send + Sync>> {
        let mut c: Self = toml::from_str(text)?;
        if let Some(url) = url_override {
            c.ocr.url = url.to_owned();
        }
        if let Some(api_key) = api_key_override {
            c.ocr.api_key = api_key.to_owned();
        }
        let url = reqwest::Url::parse(&c.ocr.url)?;
        if !matches!(url.scheme(), "http" | "https")
            || url.host_str().is_none()
            || !url.username().is_empty()
            || url.password().is_some()
            || c.general.jwt_secret.trim().len() < 24
            || c.ocr.api_key.trim().len() < 24
            || c.ocr.api_key.trim() == c.general.jwt_secret.trim()
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
