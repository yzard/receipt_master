use crate::db::{Result, invalid, number, text};
use chrono::{Datelike, Days, Months, NaiveDate, TimeZone};
use serde_json::{Value, json};
pub fn candidates(input: &Value) -> Result<Value> {
    let zone = text(input, "zone")?
        .parse::<chrono_tz::Tz>()
        .map_err(|_| invalid())?;
    let wall = crate::jobs::parse_receipt_time(text(input, "text")?).ok_or_else(invalid)?;
    let times = match zone.from_local_datetime(&wall) {
        chrono::LocalResult::Single(t) => vec![t.timestamp_millis()],
        chrono::LocalResult::Ambiguous(a, b) => vec![a.timestamp_millis(), b.timestamp_millis()],
        chrono::LocalResult::None => vec![],
    };
    Ok(json!(times))
}
pub fn range(input: &Value) -> Result<Value> {
    let zone = text(input, "zone")?
        .parse::<chrono_tz::Tz>()
        .map_err(|_| invalid())?;
    let anchor = chrono::DateTime::from_timestamp_millis(number(input, "anchor")?)
        .ok_or_else(invalid)?
        .with_timezone(&zone);
    let offset = number(input, "period_offset")?;
    if !(-10000..=10000).contains(&offset) {
        return Err(invalid());
    }
    let period = text(input, "period")?;
    let local = anchor.date_naive();
    let (base, step, days) = match period {
        "day" => (local, 1, true),
        "week" => (
            local
                .checked_sub_days(Days::new(u64::from(local.weekday().num_days_from_monday())))
                .ok_or_else(invalid)?,
            7,
            true,
        ),
        "month" => (
            NaiveDate::from_ymd_opt(local.year(), local.month(), 1).unwrap(),
            1,
            false,
        ),
        "quarter" => (
            NaiveDate::from_ymd_opt(local.year(), (local.month() - 1) / 3 * 3 + 1, 1).unwrap(),
            3,
            false,
        ),
        "year" => (
            NaiveDate::from_ymd_opt(local.year(), 1, 1).unwrap(),
            12,
            false,
        ),
        _ => return Err(invalid()),
    };
    let at = |offset: i64| -> Result<chrono::DateTime<chrono_tz::Tz>> {
        let n = offset * step;
        let day = if days {
            if n >= 0 {
                base.checked_add_days(Days::new(n as u64))
            } else {
                base.checked_sub_days(Days::new(n.unsigned_abs()))
            }
        } else if n >= 0 {
            base.checked_add_months(Months::new(n as u32))
        } else {
            base.checked_sub_months(Months::new(n.unsigned_abs() as u32))
        }
        .ok_or_else(invalid)?;
        zone.from_local_datetime(&day.and_hms_opt(0, 0, 0).unwrap())
            .earliest()
            .ok_or_else(invalid)
    };
    let start = at(offset)?;
    let end = at(offset + 1)?;
    let previous = at(offset - 1)?;
    Ok(
        json!({"start":start.timestamp_millis(),"end":end.timestamp_millis(),"previous_start":previous.timestamp_millis(),"label":format!("{} — {}",start.format("%Y-%m-%d"),(end-chrono::Duration::milliseconds(1)).format("%Y-%m-%d")),"unfinished":end>anchor}),
    )
}
