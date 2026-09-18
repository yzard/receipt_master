use super::layout;
use regex::Regex;
use serde_json::{Value, json};
use std::sync::LazyLock;

pub(super) fn has_chinese(s: &str) -> bool {
    s.chars().any(|c| ('\u{3400}'..='\u{9fff}').contains(&c))
}
static MONEY: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"^(.*?)\s*([-−]?\s*[$]?\s*[-−]?\s*\d[\d,]*\.\d{2,3}\s*-?)\s*([A-Za-z])?\s*$")
        .unwrap()
});
pub(super) fn money_at_end(text: &str) -> Option<(String, String, Option<String>)> {
    let c = MONEY.captures(text)?;
    let raw = c[2].replace(['$', ',', ' ', '−'], "");
    let negative = c[2].contains(['-', '−']);
    let magnitude = raw.trim_matches('-');
    Some((
        c[1].trim().trim_end_matches([' ', '$']).to_owned(),
        format!("{}{magnitude}", if negative { "-" } else { "" }),
        c.get(3).map(|v| v.as_str().to_owned()),
    ))
}
pub(super) fn label(s: &str) -> String {
    s.trim_matches(|c: char| !c.is_alphanumeric())
        .to_uppercase()
}
pub(super) fn line(
    row: &layout::Row,
    name: String,
    amount: String,
    tax: Option<String>,
    kind: &str,
) -> Value {
    let evidence = if row.box_[0] < row.box_[2] {
        json!([{"image_index":row.image,"box":row.box_}])
    } else {
        json!([])
    };
    let mut notes = row.notes.clone();
    if row.confidence.is_some_and(|c| c < 0.85) {
        notes.push("OCR 字符置信度低，请核对照片。".into());
    }
    json!({"name":name,"product_name":null,"kind":kind,"quantity":null,"quantity_unit":null,
    "unit_price":null,"amount":amount,"confidence":row.confidence,"discount_target_index":null,
    "review_notes":notes,"sku":null,"tax_code":tax,"is_weighed":false,"evidence":evidence,
    "package_weight":null,"package_weight_unit":null,"amount_basis":"gross"})
}
pub(super) fn date(text: &str) -> Option<String> {
    static DATE: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r"(?i)\b(\d{1,2})[/-](\d{1,2})[/-](\d{2,4})\s+(\d{1,2}):(\d{2})(?::(\d{2}))?\s*(AM|PM)?\b").unwrap()
    });
    let c = DATE.captures(text)?;
    let mut year = c[3].parse::<i32>().ok()?;
    if year < 100 {
        year += 2000;
    }
    let day = chrono::NaiveDate::from_ymd_opt(year, c[1].parse().ok()?, c[2].parse().ok()?)?;
    let mut hour = c[4].parse::<u32>().ok()?;
    if let Some(period) = c.get(7) {
        if hour == 12 {
            hour = 0;
        }
        if period.as_str().eq_ignore_ascii_case("pm") {
            hour += 12;
        }
    }
    Some(
        day.and_hms_opt(
            hour,
            c[5].parse().ok()?,
            c.get(6).map_or("0", |m| m.as_str()).parse().ok()?,
        )?
        .format("%Y-%m-%dT%H:%M:%S")
        .to_string(),
    )
}
pub(super) fn summary(name: &str) -> bool {
    static SUMMARY: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r"(?i)^(?:SUB\s*TOTAL|TOTAL\b|TAX\s*TOTAL|TOTAL TAX|AMOUNT\b|BALANCE\b|CHANGE\b|CASH\b|CREDIT\b|DEBIT\b|VISA\b|MASTERCARD\b|AMEX\b|COSTCO VISA\b|PAYMENT\b|TENDER\b|SAVINGS\b|INSTANT SAVINGS\b|EXECUTIVE REWARD\b|YOU SAVED\b|ITEMS SOLD\b|APPROVED\b|AUTH\b|AID\b|SEQ\b|OP#|PS#|FP MEMBER|MEMBER\b|CASHIER\b|STATION\b|RETURN POLICY|[A-Z]\s*\d+(?:\.\d+)?%\s*TAX)").unwrap()
    });
    SUMMARY.is_match(&label(name))
}
pub(super) fn weighted(text: &str) -> Option<(String, String, String)> {
    static WEIGHT: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r"(?i)(\d+(?:\.\d+)?)\s*(lb[s]?|1b|kg|oz|g)\s*@\s*\$?\s*(\d+(?:\.\d+)?)\s*/?\s*(?:lb[s]?|1b|kg|oz|g)\b").unwrap()
    });
    let c = WEIGHT.captures(text)?;
    let unit = match c[2].to_lowercase().as_str() {
        "lbs" | "1b" => "lb".to_owned(),
        v => v.to_owned(),
    };
    Some((c[1].to_owned(), unit, c[3].to_owned()))
}
pub(super) fn attach_weight(line: &mut Value, q: String, unit: String, price: String) {
    line["quantity"] = json!(q);
    line["quantity_unit"] = json!(unit);
    line["unit_price"] = json!(price);
    line["is_weighed"] = json!(true);
    line["package_weight"] = Value::Null;
    line["package_weight_unit"] = Value::Null;
    let numeric = |key: &str, digits| {
        crate::jobs::fixed(&line[key], digits)
            .ok()
            .and_then(|v| v.as_i64())
    };
    if let (Some(q), Some(p), Some(amount)) = (
        numeric("quantity", 6),
        numeric("unit_price", 6),
        numeric("amount", 2),
    ) {
        let expected = (i128::from(q) * i128::from(p) + 5_000_000_000) / 10_000_000_000;
        if (expected - i128::from(amount).abs()).abs() > 1 {
            let note = format!(
                "重量 × 单价应为 {}，票面金额为 {}，请核对。",
                crate::receipt_lines::money(expected, 2),
                line["amount"].as_str().unwrap()
            );
            line["review_notes"]
                .as_array_mut()
                .unwrap()
                .push(json!(note));
        }
    }
}

pub(super) fn header(rows: &[layout::Row], data: &mut Value) {
    let street = Regex::new(
        r"(?i)^\d[\d-]*\s+.+\b(?:BLVD|STREET|ST|AVENUE|AVE|ROAD|RD|WAY|DRIVE|DR|LANE|LN)\.?$",
    )
    .unwrap();
    let city = Regex::new(r"(?i)^.+,\s*[A-Z]{2}\.?\s+\d{5}(?:-\d{4})?$").unwrap();
    let branch = Regex::new(r"^.+\s+#\d+$").unwrap();
    let mut address = Vec::new();
    for row in rows.iter().take_while(|r| money_at_end(&r.text).is_none()) {
        if street.is_match(&row.text) {
            address.push(row.text.clone());
        }
        if city.is_match(&row.text) {
            address.push(row.text.clone());
            data["country"] = json!("US");
            data["currency"] = json!("USD");
        }
        if branch.is_match(&row.text) {
            data["branch"] = json!(row.text);
        }
    }
    if !address.is_empty() {
        data["address"] = json!(address.join(", "));
    }
}
pub(super) fn package(line: &mut Value) {
    static PACKAGE: LazyLock<Regex> =
        LazyLock::new(|| Regex::new(r"(?i)\b(\d+(?:\.\d+)?)\s*(KG|G|OZ|LBS?)\b").unwrap());
    if let Some(c) = PACKAGE.captures(line["name"].as_str().unwrap()) {
        let weight = c[1].to_owned();
        let unit = c[2].to_lowercase();
        line["package_weight"] = json!(weight);
        line["package_weight_unit"] = json!(if unit == "lbs" { "lb" } else { &unit });
    }
}

pub(super) fn attach_previous_weight(
    weight: (String, String, String),
    lines: &mut [Value],
    previous: Option<usize>,
    closed: bool,
) {
    // A detached continuation is never applied forward to the next product.
    if !closed && let Some(index) = previous {
        attach_weight(&mut lines[index], weight.0, weight.1, weight.2);
    }
}

// Carry continuation-row evidence and warnings into the owning product.
pub(super) fn continuation_evidence(item: &mut Value, row: &layout::Row) {
    if row.box_[0] < row.box_[2] {
        item["evidence"]
            .as_array_mut()
            .unwrap()
            .push(json!({"image_index":row.image,"box":row.box_}));
    }
    item["review_notes"]
        .as_array_mut()
        .unwrap()
        .extend(row.notes.iter().map(|n| json!(n)));
    if row.confidence.is_some_and(|c| c < 0.85) {
        item["review_notes"]
            .as_array_mut()
            .unwrap()
            .push(json!("商品名称续行 OCR 字符置信度低，请核对照片。"));
    }
}
