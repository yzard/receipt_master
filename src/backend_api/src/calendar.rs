use crate::{
    date_time::{LocalDateTime, LocalInstants, YEARS_PER_CYCLE, time_zone},
    db::{Result, invalid, number, text},
};
use jiff::{Span, tz::TimeZone};
use serde_json::{Value, json};

pub fn candidates(input: &Value) -> Result<Value> {
    let zone = time_zone(text(input, "zone")?)?;
    let wall = crate::jobs::parse_receipt_time(text(input, "text")?).ok_or_else(invalid)?;
    let times = match wall.instants(&zone) {
        LocalInstants::Single(at) => vec![at],
        LocalInstants::Fold(earlier, later) => vec![earlier, later],
        LocalInstants::Gap => vec![],
    };
    Ok(json!(times))
}

pub fn range(input: &Value) -> Result<Value> {
    let zone = time_zone(text(input, "zone")?)?;
    range_in_zone(input, &zone)
}

fn range_in_zone(input: &Value, zone: &TimeZone) -> Result<Value> {
    let anchor = number(input, "anchor")?;
    let local = LocalDateTime::from_utc_millis(anchor, zone)?;
    let offset = number(input, "period_offset")?;
    if !(-10000..=10000).contains(&offset) {
        return Err(invalid());
    }
    let period = text(input, "period")?;
    let date = local.checked_date()?;
    let (base, step, days) = match period {
        "day" => (date, 1, true),
        "week" => (
            date.checked_sub(Span::new().days(date.weekday().to_monday_zero_offset()))
                .map_err(|_| invalid())?,
            7,
            true,
        ),
        "month" => (date.first_of_month(), 1, false),
        "quarter" => (
            date.with()
                .month((date.month() - 1) / 3 * 3 + 1)
                .day(1)
                .build()
                .map_err(|_| invalid())?,
            3,
            false,
        ),
        "year" => (date.first_of_year(), 12, false),
        _ => return Err(invalid()),
    };
    let at = |offset: i64| -> Result<i64> {
        let n = offset * step;
        let mut year_shift = local.year_shift;
        let span = if days {
            Span::new().days(n)
        } else {
            // Keep large period offsets within Jiff's civil range.
            let months_per_cycle = i64::from(YEARS_PER_CYCLE) * 12;
            year_shift += (n / months_per_cycle) as i32 * YEARS_PER_CYCLE;
            Span::new().months(n % months_per_cycle)
        };
        let day = base.checked_add(span).map_err(|_| invalid())?;
        let midnight = LocalDateTime {
            civil: day.at(0, 0, 0, 0),
            year_shift,
            leap_second: false,
        };
        match midnight.instants(zone) {
            LocalInstants::Single(at) | LocalInstants::Fold(at, _) => Ok(at),
            LocalInstants::Gap => Err(invalid()),
        }
    };
    let start = at(offset)?;
    let end = at(offset + 1)?;
    let previous = at(offset - 1)?;
    let first = LocalDateTime::from_utc_millis(start, zone)?.date_text();
    let last = LocalDateTime::from_utc_millis(end - 1, zone)?.date_text();
    Ok(json!({
        "start": start,
        "end": end,
        "previous_start": previous,
        "label": format!("{first} — {last}"),
        "unfinished": end > anchor,
    }))
}

/// A chart window contains consecutive calendar periods in the display timezone.
pub fn trend_ranges(input: &Value) -> Result<Vec<Value>> {
    let period = text(input, "period")?;
    let count: i64 = match period {
        "day" => 14,
        "week" | "month" => 12,
        "quarter" => 8,
        "year" => 6,
        _ => return Err(invalid()),
    };
    let window = number(input, "window")?;
    if !(-100..=0).contains(&window) {
        return Err(invalid());
    }
    let zone = time_zone(text(input, "zone")?)?;
    let mut points = Vec::with_capacity(count as usize);
    for index in 0..count {
        let offset = window * count - count + 1 + index;
        let mut request = input.clone();
        request["period_offset"] = json!(offset);
        let mut bounds = range_in_zone(&request, &zone)?;
        let start = LocalDateTime::from_utc_millis(number(&bounds, "start")?, &zone)?;
        let tick = match period {
            "day" | "week" => start.civil.strftime("%m/%d").to_string(),
            // A projected year differs from the actual year by a multiple of 400.
            "month" => start.civil.strftime("%y/%m").to_string(),
            "quarter" => format!(
                "{} Q{}",
                start.year_text(),
                (start.civil.month() - 1) / 3 + 1
            ),
            "year" => start.year_text(),
            _ => unreachable!(),
        };
        bounds["offset"] = json!(offset);
        bounds["tick"] = json!(tick);
        points.push(bounds);
    }
    Ok(points)
}
