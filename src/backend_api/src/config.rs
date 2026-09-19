use serde::Deserialize;
use std::{net::IpAddr, path::PathBuf};

#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Config {
    pub host: IpAddr,
    pub port: u16,
    pub served_model: String,
    pub api_key_file: PathBuf,
    pub apk_path: PathBuf,
    pub data_dir: PathBuf,
    pub timeout_seconds: u64,
    pub job_workers: usize,
    pub ocr: Ocr,
    pub logos: Logos,
    pub pricing: Pricing,
    pub budget: Budget,
}
#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Logos {
    pub enabled: bool,
    pub prompt: String,
}
#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Ocr {
    pub url: String,
    pub model: String,
    pub output_tokens: u32,
    pub max_images: usize,
    pub thinking: bool,
    pub prompts_file: PathBuf,
    pub repair_attempts: usize,
}
#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Pricing {
    pub input_usd_per_million_tokens: Option<String>,
    pub output_usd_per_million_tokens: Option<String>,
}
#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Budget {
    pub monthly_usd: Option<String>,
    pub alert_percent: u8,
    pub timezone: String,
}
impl Pricing {
    pub fn snapshot(&self) -> Result<serde_json::Value, crate::error::AppError> {
        use serde_json::json;
        let input = crate::jobs::fixed(&json!(self.input_usd_per_million_tokens), 6)?;
        let output = crate::jobs::fixed(&json!(self.output_usd_per_million_tokens), 6)?;
        if input.is_null() != output.is_null()
            || input.as_i64().is_some_and(|v| v < 0)
            || output.as_i64().is_some_and(|v| v < 0)
        {
            return Err(crate::db::invalid());
        }
        Ok(json!({"input_rate_micros":input,"output_rate_micros":output}))
    }
}
impl Config {
    pub fn parse(text: &str) -> Result<Self, Box<dyn std::error::Error + Send + Sync>> {
        let c: Self = serde_yaml_ng::from_str(text)?;
        if c.logos.prompt.trim().is_empty() || c.ocr.max_images < 2 {
            return Err("Logo matching requires a prompt and at least two images".into());
        }
        c.pricing
            .snapshot()
            .map_err(|_| "Invalid pricing configuration")?;
        let monthly = crate::jobs::fixed(&serde_json::json!(c.budget.monthly_usd), 2)
            .map_err(|_| "Invalid budget")?;
        if monthly.as_i64().is_some_and(|v| v <= 0) || !(1..=100).contains(&c.budget.alert_percent)
        {
            return Err("Invalid budget".into());
        }
        c.budget.timezone.parse::<chrono_tz::Tz>()?;
        let url = reqwest::Url::parse(&c.ocr.url)?;
        if !matches!(url.scheme(), "http" | "https")
            || url.host_str().is_none()
            || !url.username().is_empty()
            || url.password().is_some()
            || !c.data_dir.is_absolute()
            || c.port == 0
            || !(1..=8).contains(&c.job_workers)
            || c.timeout_seconds == 0
            || c.served_model.is_empty()
            || c.ocr.model.is_empty()
            || c.ocr.max_images == 0
            || c.ocr.output_tokens == 0
            || c.ocr.prompts_file.as_os_str().is_empty()
            || c.ocr.repair_attempts > 2
        {
            return Err("Invalid backend API configuration".into());
        }
        Ok(c)
    }
}
impl Budget {
    pub fn notice(&self, store: &crate::db::Store) -> crate::db::Result<Option<String>> {
        use chrono::{Datelike, TimeZone};
        use serde_json::json;
        let Some(limit) = crate::jobs::fixed(&json!(self.monthly_usd), 2)?.as_i64() else {
            return Ok(None);
        };
        let zone = self
            .timezone
            .parse::<chrono_tz::Tz>()
            .map_err(|_| crate::db::invalid())?;
        let now = chrono::Utc::now().with_timezone(&zone);
        let start = zone
            .with_ymd_and_hms(now.year(), now.month(), 1, 0, 0, 0)
            .earliest()
            .ok_or_else(crate::db::invalid)?
            .timestamp_millis();
        let (year, month) = if now.month() == 12 {
            (now.year() + 1, 1)
        } else {
            (now.year(), now.month() + 1)
        };
        let end = zone
            .with_ymd_and_hms(year, month, 1, 0, 0, 0)
            .earliest()
            .ok_or_else(crate::db::invalid)?
            .timestamp_millis();
        let row=store.one("SELECT COALESCE(SUM(estimated_cost_minor),0) AS known FROM recognition_run WHERE cost_currency_code='USD' AND started_at_utc_ms>=? AND started_at_utc_ms<?",&[json!(start),json!(end)])?;
        let known = crate::db::number(&row, "known")?;
        Ok(
            (i128::from(known) * 100 >= i128::from(limit) * i128::from(self.alert_percent))
                .then(|| "识别费用已达到服务器设置的提醒预算，仍可继续识别。".into()),
        )
    }
}
