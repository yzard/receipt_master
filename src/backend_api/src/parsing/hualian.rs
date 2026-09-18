//! A priced root row starts a product; following text and indented rows belong to it.
use super::{generic, layout::Row};
use serde_json::{Value, json};

pub(super) fn continuation(row: &Row, anchor: &Row, item: &mut Value) -> bool {
    let text = row.text.trim();
    let price = generic::money_at_end(text);
    let label = generic::label(price.as_ref().map_or(text, |(name, _, _)| name.as_str()));
    // Totals/payment/tax boundaries take precedence over visual indentation.
    if generic::summary(text)
        || label.starts_with("TAX")
        || matches!(label.as_str(), "TIP" | "TIPS" | "GRATUITY" | "GRATUITIES")
        || label.starts_with("ITEM COUNT")
        || label.starts_with("THANK YOU")
    {
        return false;
    }
    let indented = row.leading_spaces >= anchor.leading_spaces + 2
        || (row.image == anchor.image
            && anchor.box_[0] < anchor.box_[2]
            && row.box_[0] > anchor.box_[0] + (anchor.box_[3] - anchor.box_[1]).max(0.01) * 0.6);
    if price.is_some() && !indented {
        return false;
    }
    let name = item["product_name"].as_str().unwrap_or("");
    item["product_name"] = json!(if name.is_empty() {
        text.to_owned()
    } else {
        format!("{name} {text}")
    });
    generic::continuation_evidence(item, row);
    true
}
