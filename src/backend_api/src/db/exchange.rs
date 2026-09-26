use super::*;

impl Store {
    pub fn missing_exchange_rates(
        &self,
        start: i64,
        end: i64,
        zone: chrono_tz::Tz,
    ) -> Result<Vec<Value>> {
        let target = self.report_currency()?;
        let receipts = self.rows("SELECT DISTINCT currency_code,occurred_at_utc_ms FROM receipt WHERE status='posted' AND deleted_at_utc_ms IS NULL AND currency_code<>? AND occurred_at_utc_ms>=? AND occurred_at_utc_ms<?", &[json!(target),json!(start),json!(end)])?;
        let mut missing = std::collections::BTreeSet::new();
        for receipt in receipts {
            let source = text(&receipt, "currency_code")?;
            let date = rate_date(number(&receipt, "occurred_at_utc_ms")?, zone)?;
            let existing = self.rows("SELECT 1 FROM exchange_rate WHERE source_code=? AND target_code=? AND requested_date=?", &[json!(source),json!(target),json!(date)])?;
            if existing.is_empty() {
                missing.insert((source.to_owned(), date));
            }
        }
        Ok(missing.into_iter().map(|(source,requested_date)| json!({"source":source,"target":target,"requested_date":requested_date})).collect())
    }

    pub fn report_currency(&self) -> Result<String> {
        Ok(text(
            &self.one(
                "SELECT currency_code FROM report_preferences WHERE id=1",
                &[],
            )?,
            "currency_code",
        )?
        .to_owned())
    }

    pub fn converted_amount(
        &self,
        amount: i64,
        source: &str,
        target: &str,
        date: &str,
    ) -> Result<i64> {
        if source == target {
            return Ok(amount);
        }
        let row = self.one(
            "SELECT s.minor_digits AS source_digits,t.minor_digits AS target_digits,x.rate_scaled FROM currency s CROSS JOIN currency t LEFT JOIN exchange_rate x ON x.source_code=s.code AND x.target_code=t.code AND x.requested_date=? WHERE s.code=? AND t.code=?",
            &[json!(date), json!(source), json!(target)],
        )?;
        let rate = row["rate_scaled"].as_i64().ok_or_else(|| {
            AppError::new(
                503,
                "exchange_rate_unavailable",
                "缺少交易日汇率，请联网重试",
            )
        })?;
        let source_scale = 10i128.pow(number(&row, "source_digits")? as u32);
        let target_scale = 10i128.pow(number(&row, "target_digits")? as u32);
        let numerator = i128::from(amount) * i128::from(rate) * target_scale;
        let denominator = source_scale * 1_000_000_000;
        let rounded = (numerator.abs() + denominator / 2) / denominator * numerator.signum();
        i64::try_from(rounded).map_err(|_| invalid())
    }
}

pub fn report_zone(v: &Value) -> Result<chrono_tz::Tz> {
    v["zone"]
        .as_str()
        .unwrap_or("UTC")
        .parse()
        .map_err(|_| invalid())
}

pub fn rate_date(at: i64, zone: chrono_tz::Tz) -> Result<String> {
    Ok(chrono::DateTime::from_timestamp_millis(at)
        .ok_or_else(invalid)?
        .with_timezone(&zone)
        .date_naive()
        .to_string())
}
