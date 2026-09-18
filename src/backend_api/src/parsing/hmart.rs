use regex::Regex;
use serde_json::{Value, json};
pub fn product(line: &mut Value) {
    let re = Regex::new(r"(?i)^WT\s+(.+)$").unwrap();
    if let Some(c) = re.captures(line["name"].as_str().unwrap()) {
        let name = c[1].to_owned();
        line["name"] = json!(name);
        line["is_weighed"] = json!(true);
    }
}
