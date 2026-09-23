use serde::Deserialize;
use std::{net::IpAddr, path::PathBuf};

#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Config {
    pub general: General,
    pub ocr: Ocr,
    pub logos: Logos,
}
#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct General {
    pub host: IpAddr,
    pub port: u16,
    pub api_key: String,
    pub apk_path: PathBuf,
    pub data_dir: PathBuf,
    pub timeout_seconds: u64,
    pub job_workers: usize,
    pub repair_attempts: usize,
}
#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Logos {
    pub enabled: bool,
}
#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Ocr {
    pub url: String,
    pub api_key: String,
}
impl Config {
    pub fn parse(text: &str) -> Result<Self, Box<dyn std::error::Error + Send + Sync>> {
        let c: Self = toml::from_str(text)?;
        let url = reqwest::Url::parse(&c.ocr.url)?;
        if !matches!(url.scheme(), "http" | "https")
            || url.host_str().is_none()
            || !url.username().is_empty()
            || url.password().is_some()
            || !c.general.data_dir.is_absolute()
            || c.general.api_key.trim().len() < 24
            || c.ocr.api_key.trim().len() < 24
            || c.ocr.api_key.trim() == c.general.api_key.trim()
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
