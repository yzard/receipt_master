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

/// Weighted/multi-buy blocks put the amount on the unindented first row,
/// then the English name and Chinese translation on indented continuation rows.
pub fn blocks(rows: Vec<super::layout::Row>) -> Vec<super::layout::Row> {
    let promotion = Regex::new(r"^(\d+)\s*@\s*1/\$(\d+\.\d{2})$").unwrap();
    let mut output = Vec::new();
    let mut index = 0;
    while index < rows.len() {
        let row = &rows[index];
        if let Some((head, amount, tax)) = super::money_at_end(&row.text)
            && let Some(name) = rows.get(index + 1)
            && row.image == name.image
            && (name.leading_spaces > row.leading_spaces
                || (name.box_[0] - row.box_[0] > 0.008
                    && name.box_[1] >= row.box_[1]
                    && name.box_[1] - row.box_[3] < 0.03))
            && super::money_at_end(&name.text).is_none()
            && !super::summary(&name.text)
            && !super::has_chinese(&name.text)
        {
            let weight = super::weighted(&head);
            let count = promotion.captures(&head);
            if weight.is_some() || count.is_some() {
                let mut item = row.clone();
                item.text = format!("{} {} {}", name.text, amount, tax.unwrap_or_default());
                item.box_[3] = name.box_[3].max(item.box_[3]);
                item.notes.extend(name.notes.clone());
                output.push(item);
                let mut detail = row.clone();
                detail.text = if let Some(c) = count {
                    format!("{} @ ${} each", &c[1], &c[2])
                } else {
                    head
                };
                output.push(detail);
                index += 2;
                continue;
            }
        }
        output.push(row.clone());
        index += 1;
    }
    output
}
