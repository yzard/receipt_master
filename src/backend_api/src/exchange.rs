use crate::{
    State,
    db::{self, Store},
    error::AppError,
};
use serde_json::{Value, json};
use std::sync::Arc;

/// Fetch only missing daily rates. The database keeps the exact rate used by each report.
pub async fn ensure_rates(state: &Arc<State>, input: &Value) -> Result<(), AppError> {
    let start = db::number(input, "start")?;
    let end = db::number(input, "end")?;
    if start >= end {
        return Err(db::invalid());
    }
    let zone = db::exchange::report_zone(input)?;
    let root = state.data_dir.clone();
    let missing = tokio::task::spawn_blocking(move || {
        Store::open(&root)?.missing_exchange_rates(start, end, zone)
    })
    .await
    .map_err(db::io_error)??;
    if missing.is_empty() {
        return Ok(());
    }
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(12))
        .build()
        .map_err(db::io_error)?;
    for item in missing {
        let source = db::text(&item, "source")?;
        let target = db::text(&item, "target")?;
        let requested = db::text(&item, "requested_date")?;
        let url = format!("https://api.frankfurter.dev/v2/rate/{source}/{target}");
        let response = client
            .get(url)
            .query(&[("date", requested)])
            .header(reqwest::header::USER_AGENT, "receipt-master/1.0")
            .send()
            .await
            .map_err(|_| unavailable(source, target, requested))?;
        if !response.status().is_success() {
            return Err(unavailable(source, target, requested));
        }
        let rate: Value = response
            .json()
            .await
            .map_err(|_| unavailable(source, target, requested))?;
        if rate["base"] != source || rate["quote"] != target {
            return Err(unavailable(source, target, requested));
        }
        let observed = rate["date"]
            .as_str()
            .ok_or_else(|| unavailable(source, target, requested))?;
        let scaled = rate["rate"]
            .as_f64()
            .filter(|n| n.is_finite() && *n > 0.0 && *n < 1_000_000.0)
            .map(|n| (n * 1_000_000_000.0).round() as i64)
            .ok_or_else(|| unavailable(source, target, requested))?;
        let root = state.data_dir.clone();
        let source = source.to_owned();
        let target = target.to_owned();
        let requested = requested.to_owned();
        let observed = observed.to_owned();
        tokio::task::spawn_blocking(move || {
            Store::open(&root)?.exec(
                "INSERT OR IGNORE INTO exchange_rate VALUES (?,?,?,?,?,?,?)",
                &[
                    json!(source),
                    json!(target),
                    json!(requested),
                    json!(observed),
                    json!(scaled),
                    json!("Frankfurter v2"),
                    json!(db::now()),
                ],
            )?;
            Ok::<(), AppError>(())
        })
        .await
        .map_err(db::io_error)??;
    }
    Ok(())
}

pub async fn ensure_trend_rates(state: &Arc<State>, input: &Value) -> Result<(), AppError> {
    let ranges = crate::calendar::trend_ranges(input)?;
    let bounds = json!({
        "start": ranges.first().ok_or_else(db::invalid)?["start"],
        "end": ranges.last().ok_or_else(db::invalid)?["end"],
        "zone": input["zone"],
    });
    ensure_rates(state, &bounds).await
}

fn unavailable(source: &str, target: &str, date: &str) -> AppError {
    tracing::warn!(%source,%target,%date,"exchange rate unavailable");
    AppError::new(
        503,
        "exchange_rate_unavailable",
        "无法获取交易日汇率，请联网重试",
    )
}
