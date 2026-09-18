//! Printed tax markers and merchant-scoped SKU identities, independent of product names.
use crate::db::{Result, Store, id, invalid};
use serde_json::{Value, json};

pub fn normalize(line: &mut Value) -> Result<()> {
    if line["kind"] != "product" {
        line["taxCode"] = Value::Null;
        line["sku"] = Value::Null;
        return Ok(());
    }
    for key in ["taxCode", "sku"] {
        if line[key].is_null() {
            line[key] = Value::Null;
            continue;
        }
        let value = line[key].as_str().ok_or_else(invalid)?.trim();
        if key == "taxCode" && value.chars().count() > 1 {
            return Err(invalid());
        }
        line[key] = if value.is_empty() {
            Value::Null
        } else {
            json!(value)
        };
    }
    Ok(())
}

const LOAD: &str = "SELECT t.tax_code,COALESCE(s.code,u.code) AS sku FROM receipt_line l LEFT JOIN line_tax_code t ON t.line_id=l.line_id LEFT JOIN line_sku ls ON ls.line_id=l.line_id LEFT JOIN sku s ON s.sku_id=ls.sku_id LEFT JOIN line_unmatched_sku u ON u.line_id=l.line_id WHERE l.line_id=?";
const MERCHANT: &str = "SELECT merchant_id FROM store_location WHERE location_id=?";
const INSERT_SKU: &str = "INSERT INTO sku(sku_id,merchant_id,code) VALUES (?,?,?) ON CONFLICT(merchant_id,code) DO NOTHING";
const ASSIGN_SKU: &str =
    "INSERT INTO line_sku(line_id,sku_id) SELECT ?,sku_id FROM sku WHERE merchant_id=? AND code=?";
const UNMATCHED: &str = "INSERT INTO line_unmatched_sku(line_id,code) VALUES (?,?)";
const TAX: &str = "INSERT INTO line_tax_code(line_id,tax_code) VALUES (?,?)";
impl Store {
    pub fn line_sku(&self, line_id: &Value) -> Result<Value> {
        Ok(self
            .rows(LOAD, std::slice::from_ref(line_id))?
            .into_iter()
            .next()
            .unwrap_or(Value::Null))
    }
    pub fn save_line_sku(
        &self,
        line_id: &str,
        location: Option<&str>,
        sku: Option<&str>,
        tax: Option<&str>,
    ) -> Result<()> {
        if let Some(tax) = tax {
            self.exec(TAX, &[json!(line_id), json!(tax)])?;
        }
        if let Some(code) = sku {
            if let Some(location) = location {
                let merchant = self.one(MERCHANT, &[json!(location)])?["merchant_id"].clone();
                self.exec(INSERT_SKU, &[json!(id()), merchant.clone(), json!(code)])?;
                self.exec(ASSIGN_SKU, &[json!(line_id), merchant, json!(code)])?;
            } else {
                self.exec(UNMATCHED, &[json!(line_id), json!(code)])?;
            }
        }
        Ok(())
    }
}

/// Project metadata through an explicit product relationship; no label interpretation.
pub fn inherit_discount_metadata(lines: &mut [Value]) {
    let products = lines
        .iter()
        .filter(|l| l["kind"] == "product")
        .filter_map(|l| Some((l["id"].as_str()?.to_owned(), l.clone())))
        .collect::<std::collections::HashMap<_, _>>();
    for line in lines.iter_mut().filter(|l| l["kind"] == "item_discount") {
        if let Some(product) = line["discountTarget"]
            .as_str()
            .and_then(|id| products.get(id))
        {
            for key in ["sku", "taxCode", "productNameEdit", "categoryId"] {
                line[key] = product[key].clone();
            }
        }
    }
}
