use regex::Regex;
use serde_json::{Value, json};
pub fn product(line: &mut Value) {
    let re = Regex::new(r"^(\d+)\s+(.+)$").unwrap();
    if let Some(c) = re.captures(line["name"].as_str().unwrap()) {
        let quantity = c[1].to_owned();
        let name = c[2].to_owned();
        line["quantity"] = json!(quantity);
        line["quantity_unit"] = json!("count");
        line["name"] = json!(name);
    }
}
pub fn is_discount(name: &str) -> bool {
    let compact: String = name
        .chars()
        .filter(|c| c.is_alphanumeric())
        .flat_map(char::to_lowercase)
        .collect();
    matches!(compact.as_str(), "qtyspldisc" | "qtypkgdisc")
}
