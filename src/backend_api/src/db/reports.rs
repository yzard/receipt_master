use super::*;
impl Store {
    pub fn report_action(&self, op: &str, v: &Value) -> Result<Value> {
        if op == "range" {
            return crate::calendar::range(v);
        }
        if !["summary", "details"].contains(&op) {
            return Err(missing());
        }
        let start = number(v, "start")?;
        let end = number(v, "end")?;
        if start >= end {
            return Err(invalid());
        }
        let currency = text(v, "currency")?;
        let filter = "r.status='posted' AND r.deleted_at_utc_ms IS NULL AND r.currency_code=? AND r.occurred_at_utc_ms>=? AND r.occurred_at_utc_ms<?";
        let args = vec![json!(currency), json!(start), json!(end)];
        let all=self.one(&format!("SELECT COALESCE(SUM(r.total_minor),0) AS net,COALESCE(SUM(rr.difference_minor),0) AS difference FROM receipt r JOIN receipt_reconciliation rr ON rr.receipt_id=r.receipt_id WHERE {filter}"),&args)?;
        let mut query = format!(
            "SELECT l.*,r.currency_code,r.occurred_at_utc_ms,r.raw_store,a.name AS product_name,CAST(ROUND(COALESCE(p.weight_g,w.weight_g)*1000) AS INTEGER) AS weight_mg,ec.category_id,c.name AS category_name,d.target_line_id FROM receipt_line l JOIN receipt r ON r.receipt_id=l.receipt_id JOIN line_effective_category ec ON ec.line_id=l.line_id JOIN category c ON c.category_id=ec.category_id LEFT JOIN line_discount d ON d.discount_line_id=l.line_id LEFT JOIN product p ON p.product_id=COALESCE(l.product_id,(SELECT product_id FROM receipt_line WHERE line_id=d.target_line_id)) LEFT JOIN printed_name n ON n.printed_name_id=p.printed_name_id LEFT JOIN printed_name_product_name m ON m.printed_name_id=n.printed_name_id LEFT JOIN product_name a ON a.product_name_id=m.product_name_id LEFT JOIN line_unmatched_weight w ON w.line_id=l.line_id WHERE {filter}"
        );
        let mut args = args;
        if !v["category"].is_null() {
            query.push_str(" AND ec.category_id IN (WITH RECURSIVE t(id) AS (SELECT category_id FROM category WHERE category_id=? UNION ALL SELECT c.category_id FROM category c JOIN t ON c.parent_id=t.id) SELECT id FROM t)");
            args.push(v["category"].clone());
        }
        query.push_str(" ORDER BY r.occurred_at_utc_ms DESC,l.position,l.line_id");
        let entries = self.rows(&query, &args)?;
        let net = if v["category"].is_null() {
            all["net"].clone()
        } else {
            json!(entries.iter().try_fold(0i64, |sum, r| {
                sum.checked_add(r["amount_minor"].as_i64().unwrap_or(0))
                    .ok_or_else(invalid)
            })?)
        };
        let preference = self.one("SELECT weight_unit FROM app_preferences WHERE id=1", &[])?;
        let unit = text(&preference, "weight_unit")?;
        let categories = self.rows("SELECT * FROM category", &[])?;
        let mut groups = std::collections::BTreeMap::<String, Value>::new();
        let mut spend = 0i64;
        let mut discounts = 0i64;
        let mut refunds = 0i64;
        for row in &entries {
            let amount = number(row, "amount_minor")?;
            if amount > 0 {
                spend = spend.checked_add(amount).ok_or_else(invalid)?;
            }
            if text(row, "kind")?.ends_with("discount") {
                discounts = discounts.checked_add(amount).ok_or_else(invalid)?;
            }
            if row["kind"] == "product" && amount < 0 {
                refunds = refunds.checked_add(amount).ok_or_else(invalid)?;
            }
            for grouping in ["category", "product"] {
                let (key, label) = if grouping == "category" {
                    let mut node = categories
                        .iter()
                        .find(|c| c["category_id"] == row["category_id"])
                        .ok_or_else(invalid)?;
                    while !node["parent_id"].is_null()
                        && (v["category"].is_null()
                            || (node["parent_id"] != v["category"]
                                && node["category_id"] != v["category"]))
                    {
                        node = categories
                            .iter()
                            .find(|c| c["category_id"] == node["parent_id"])
                            .ok_or_else(invalid)?;
                    }
                    (
                        format!("category:{}", text(node, "category_id")?),
                        text(node, "name")?.to_owned(),
                    )
                } else {
                    let name = row["product_name"]
                        .as_str()
                        .unwrap_or_else(|| row["raw_name"].as_str().unwrap_or("未命名商品"));
                    (format!("product:{name}"), name.to_owned())
                };
                let entry=groups.entry(key.clone()).or_insert_with(||json!({"key":key,"group":grouping,"label":label,"amount":0,"line_ids":[],"quantities":{}}));
                entry["amount"] = json!(
                    number(entry, "amount")?
                        .checked_add(amount)
                        .ok_or_else(invalid)?
                );
                entry["line_ids"]
                    .as_array_mut()
                    .unwrap()
                    .push(row["line_id"].clone());
                if row["kind"] == "product"
                    && let (Some(q), Some(source_unit)) = (
                        row["quantity_micros"].as_i64(),
                        row["quantity_unit"].as_str(),
                    )
                {
                    let (q, unit) = if let Some(source) = crate::weights::factor(source_unit) {
                        let target = crate::weights::factor(unit).ok_or_else(invalid)?;
                        let n = i128::from(q) * source;
                        let converted = (n.abs() + target / 2) / target * n.signum();
                        (i64::try_from(converted).map_err(|_| invalid())?, unit)
                    } else {
                        (q, source_unit)
                    };
                    let previous = entry["quantities"][unit].as_i64().unwrap_or(0);
                    entry["quantities"][unit] = json!(previous.checked_add(q).ok_or_else(invalid)?);
                }
            }
        }
        let mut groups = groups.into_values().collect::<Vec<_>>();
        for group in &mut groups {
            group["quantity_labels"] = json!(
                group["quantities"]
                    .as_object()
                    .unwrap()
                    .iter()
                    .map(|(unit, q)| {
                        format!(
                            "{} {unit}",
                            crate::weights::quantity_text(q.as_i64().unwrap(), unit)
                        )
                    })
                    .collect::<Vec<_>>()
            );
        }
        groups.sort_by_key(|g| std::cmp::Reverse(g["amount"].as_i64().unwrap_or(0)));
        let offset = v["offset"].as_u64().unwrap_or(0) as usize;
        let limit = v["limit"].as_u64().unwrap_or(200).clamp(1, 500) as usize;
        let total = entries.len();
        Ok(
            json!({"net":net,"difference":if v["category"].is_null(){all["difference"].clone()}else{Value::Null},"entries":entries.into_iter().skip(offset).take(limit).collect::<Vec<_>>(),"next_offset":if offset.saturating_add(limit)<total{Some(offset+limit)}else{None},"groups":groups,"spend":spend,"discounts":discounts,"refunds":refunds,"start":start,"end":end}),
        )
    }
}
