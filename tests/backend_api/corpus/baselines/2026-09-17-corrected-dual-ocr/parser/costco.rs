use regex::Regex;
use serde_json::{Value, json};

pub fn product(line: &mut Value) {
    let name = line["name"].as_str().unwrap();
    let re = Regex::new(r"^(?:([A-Za-z])\s+)?(\d{3,})\s+(.+)$").unwrap();
    if let Some(c) = re.captures(name) {
        let sku = c[2].to_owned();
        let name = c[3].to_owned();
        let tax = c.get(1).map(|v| v.as_str().to_owned());
        line["sku"] = json!(sku);
        line["name"] = json!(name);
        if let Some(tax) = tax {
            line["tax_code"] = json!(tax);
        }
    }
    let deposit =
        Regex::new(r"(?i)^(?:([A-Z])\s+)?((?:NY\s+)?BOTTLE\s+(?:DE|DEP|DEPOSIT))$").unwrap();
    if let Some(c) = deposit.captures(line["name"].as_str().unwrap()) {
        let name = c[2].to_owned();
        let tax = c.get(1).map(|m| m.as_str().to_owned());
        line["kind"] = json!("deposit");
        line["name"] = json!(name);
        if let Some(tax) = tax {
            line["tax_code"] = json!(tax);
        }
    }
    if line["name"]
        .as_str()
        .unwrap()
        .to_uppercase()
        .contains("EXC GS DOWN")
    {
        line["kind"] = json!("other_adjustment");
    }
}
pub fn discount_target(name: &str, lines: &[Value]) -> Option<usize> {
    let re = Regex::new(r"(?:^|\s)/\s*(\d{3,})\b").unwrap();
    if let Some(c) = re.captures(name) {
        return lines
            .iter()
            .rposition(|l| l["kind"] == "product" && l["sku"].as_str() == Some(&c[1]));
    }
    if Regex::new(r"^\d+\s*/\s*[A-Za-z]").unwrap().is_match(name) {
        return lines.iter().rposition(|l| l["kind"] == "product");
    }
    None
}

/// A damaged decimal separator in the final price column, never the coupon SKU column.
pub fn damaged_price(text: &str) -> Option<String> {
    let re = Regex::new(r"^((?:[A-Za-z]\s+)?\d{3,}\s+.*[A-Za-z]\s+)(\d+)/(\d{2})(\s*[A-Za-z]?)$")
        .unwrap();
    let c = re.captures(text)?;
    Some(format!("{}{}.{}{}", &c[1], &c[2], &c[3], &c[4]))
}

/// A subtotal with damaged lettering is accepted only after a pre-scan end marker,
/// before tax, and when its value equals all preceding merchandise/discount/deposit rows.
pub fn subtotal(amount: &str, lines: &[Value]) -> bool {
    if lines.is_empty() || lines.iter().any(|l| l["kind"] == "tax") {
        return false;
    }
    let sum = lines.iter().try_fold(0i128, |sum, l| {
        Some(sum + i128::from(crate::jobs::fixed(&l["amount"], 3).ok()?.as_i64()?))
    });
    sum.zip(
        crate::jobs::fixed(&json!(amount), 3)
            .ok()
            .and_then(|v| v.as_i64()),
    )
    .is_some_and(|(sum, total)| sum == i128::from(total))
}
