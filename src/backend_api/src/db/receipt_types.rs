use super::{receipt_type_queries as q, *};

impl Store {
    pub fn receipt_type_label(&self, kind: &str) -> Result<String> {
        Ok(text(&self.one(q::GET, &[json!(kind)])?, "name")?.to_owned())
    }
    pub fn validate_receipt_type(&self, receipt_type: &str) -> Result<()> {
        self.one(q::GET, &[json!(receipt_type)])?;
        Ok(())
    }
    pub fn store_receipt_type(&self, name: &str) -> Result<String> {
        Ok(self
            .rows(q::MERCHANT_BY_NAME, &[json!(normalized(name))])?
            .first()
            .and_then(|r| r["receipt_type_id"].as_str())
            .unwrap_or(UNCLASSIFIED_RECEIPT_TYPE)
            .to_owned())
    }
    pub fn resolve_receipt_type(
        &self,
        receipt: &str,
        store: &str,
        explicit: Option<&str>,
    ) -> Result<String> {
        if let Some(kind) = explicit {
            self.validate_receipt_type(kind)?;
            return Ok(kind.to_owned());
        }
        if let Some(row) = self.rows(q::GET_RECEIPT, &[json!(receipt)])?.first() {
            return Ok(text(row, "receipt_type_id")?.to_owned());
        }
        self.store_receipt_type(store)
    }
    pub fn line_receipt_type(&self, line: &str) -> Result<String> {
        Ok(self
            .rows(q::GET_LINE, &[json!(line)])?
            .first()
            .and_then(|r| r["receipt_type_id"].as_str())
            .unwrap_or(UNCLASSIFIED_RECEIPT_TYPE)
            .to_owned())
    }
    pub(super) fn receipt_type_action(
        &self,
        component: &str,
        op: &str,
        v: &Value,
    ) -> Result<Value> {
        match (component, op) {
            ("receipt_types", "list") => Ok(json!(self.rows(q::LIST, &[])?)),
            ("merchants", "list") => Ok(json!(self.rows(q::MERCHANTS, &[])?)),
            ("merchants", "classify") => {
                let merchant = text(v, "id")?;
                let kind = text(v, "receipt_type_id")?;
                self.one(q::GET_MERCHANT, &[json!(merchant)])?;
                self.validate_receipt_type(kind)?;
                self.exec(q::SET_MERCHANT, &[json!(merchant), json!(kind)])?;
                Ok(Value::Null)
            }
            ("receipt_types", "save") => {
                let name = catalog_name(text(v, "name")?);
                if name.is_empty() {
                    return Err(invalid());
                }
                if self
                    .rows(q::BY_NAME, &[json!(name)])?
                    .iter()
                    .any(|r| r["receipt_type_id"] != v["id"])
                {
                    return Err(AppError::new(
                        409,
                        "duplicate_receipt_type",
                        "商店类别已存在，请选择已有类别",
                    ));
                }
                if v["id"].is_null() {
                    self.exec(q::INSERT, &[json!(id()), json!(name)])?;
                } else {
                    let row = self.one(q::GET, &[v["id"].clone()])?;
                    if !row["system_key"].is_null() {
                        return Err(invalid());
                    }
                    self.exec(q::RENAME, &[json!(name), v["id"].clone()])?;
                }
                Ok(Value::Null)
            }
            ("receipt_types", "delete") => {
                let row = self.one(q::GET, &[v["id"].clone()])?;
                if !row["system_key"].is_null() {
                    return Err(invalid());
                }
                for sql in q::DETACH {
                    self.exec(sql, &[json!(UNCLASSIFIED_RECEIPT_TYPE), v["id"].clone()])?;
                }
                self.exec(q::DELETE, &[v["id"].clone()])?;
                Ok(Value::Null)
            }
            _ => Err(missing()),
        }
    }
}
