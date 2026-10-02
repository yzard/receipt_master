use super::*;
impl Store {
    pub fn report_action(&self, op: &str, v: &Value) -> Result<Value> {
        if op == "range" {
            return crate::calendar::range(v);
        }
        if op == "trend" {
            return self.trend_action(v);
        }
        if !["summary", "details"].contains(&op) {
            return Err(missing());
        }
        self.report_data(v, false)
    }

    // Trend categories include every ancestor; ordinary summaries retain their
    // non-overlapping grouping for the breakdown totals.
    fn report_data(&self, v: &Value, full_category_tree: bool) -> Result<Value> {
        let start = number(v, "start")?;
        let end = number(v, "end")?;
        if start >= end {
            return Err(invalid());
        }
        if !v["receipt_type"].is_null() {
            self.validate_receipt_type(text(v, "receipt_type")?)?;
        }
        let currency = self.report_currency()?;
        let zone = super::exchange::report_zone(v)?;
        let filter = "r.status='posted' AND r.deleted_at_utc_ms IS NULL AND r.occurred_at_utc_ms>=? AND r.occurred_at_utc_ms<?";
        let args = vec![json!(start), json!(end)];
        let totals = self.rows(receipt_type_queries::TOTALS, &args)?;
        let mut line_totals = std::collections::BTreeMap::<String, i64>::new();
        for row in self.rows(receipt_type_queries::LINE_TOTALS, &args)? {
            let date = super::exchange::rate_date(number(&row, "occurred_at_utc_ms")?, zone)?;
            let amount = self.converted_amount(
                number(&row, "amount_minor")?,
                text(&row, "currency_code")?,
                &currency,
                &date,
            )?;
            let sum = line_totals
                .entry(text(&row, "receipt_id")?.to_owned())
                .or_default();
            *sum = sum.checked_add(amount).ok_or_else(invalid)?;
        }
        let mut residuals = std::collections::BTreeMap::<String, i64>::new();
        let mut all_net = 0i64;
        let mut all_difference = 0i64;
        for row in &totals {
            let source = text(row, "currency_code")?;
            let at = number(row, "occurred_at_utc_ms")?;
            let date = super::exchange::rate_date(at, zone)?;
            let converted =
                self.converted_amount(number(row, "total_minor")?, source, &currency, &date)?;
            all_net = all_net.checked_add(converted).ok_or_else(invalid)?;
            let residual = converted
                .checked_sub(*line_totals.get(text(row, "receipt_id")?).unwrap_or(&0))
                .ok_or_else(invalid)?;
            let sum = residuals
                .entry(text(row, "receipt_type_id")?.to_owned())
                .or_default();
            *sum = sum.checked_add(residual).ok_or_else(invalid)?;
            all_difference = all_difference
                .checked_add(self.converted_amount(
                    number(row, "difference_minor")?,
                    source,
                    &currency,
                    &date,
                )?)
                .ok_or_else(invalid)?;
        }
        let mut query = format!("{} WHERE {filter}", receipt_type_queries::REPORT_ENTRIES);
        let mut args = args;
        if !v["category"].is_null() {
            query.push_str(" AND ec.category_id IN (WITH RECURSIVE t(id) AS (SELECT category_id FROM category WHERE category_id=? UNION ALL SELECT c.category_id FROM category c JOIN t ON c.parent_id=t.id) SELECT id FROM t)");
            args.push(v["category"].clone());
        }
        if !v["receipt_type"].is_null() {
            query.push_str(" AND et.receipt_type_id=?");
            args.push(v["receipt_type"].clone());
        }
        query.push_str(" ORDER BY r.occurred_at_utc_ms DESC,l.position,l.line_id");
        let mut entries = self.rows(&query, &args)?;
        for row in &mut entries {
            let source = text(row, "currency_code")?.to_owned();
            let at = number(row, "occurred_at_utc_ms")?;
            let original = number(row, "amount_minor")?;
            row["original_amount_minor"] = json!(original);
            let date = super::exchange::rate_date(at, zone)?;
            row["amount_minor"] =
                json!(self.converted_amount(original, &source, &currency, &date)?);
        }
        let converted_line_total = entries.iter().try_fold(0i64, |sum, row| {
            sum.checked_add(number(row, "amount_minor")?)
                .ok_or_else(invalid)
        })?;
        let rounding_adjustment = if v["category"].is_null() && v["receipt_type"].is_null() {
            all_net
                .checked_sub(all_difference)
                .and_then(|sum| sum.checked_sub(converted_line_total))
                .ok_or_else(invalid)?
        } else {
            0
        };
        let net = if v["category"].is_null() && v["receipt_type"].is_null() {
            json!(all_net)
        } else {
            json!(entries.iter().try_fold(0i64, |sum, r| {
                sum.checked_add(r["amount_minor"].as_i64().unwrap_or(0))
                    .ok_or_else(invalid)
            })?)
        };
        let net = if v["category"].is_null() && !v["receipt_type"].is_null() {
            json!(
                number(&json!({"net":net}), "net")?
                    .checked_add(*residuals.get(text(v, "receipt_type")?).unwrap_or(&0))
                    .ok_or_else(invalid)?
            )
        } else {
            net
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
            let direct = categories
                .iter()
                .find(|c| c["category_id"] == row["category_id"])
                .ok_or_else(invalid)?;
            let mut node = direct;
            let mut category_nodes = vec![direct];
            while !node["parent_id"].is_null()
                && (full_category_tree
                    || v["category"].is_null()
                    || (node["parent_id"] != v["category"] && node["category_id"] != v["category"]))
            {
                node = categories
                    .iter()
                    .find(|c| c["category_id"] == node["parent_id"])
                    .ok_or_else(invalid)?;
                category_nodes.push(node);
            }
            if !full_category_tree {
                category_nodes = vec![node];
            }
            let category_key = format!(
                "category:{}",
                text(
                    if full_category_tree { direct } else { node },
                    "category_id"
                )?
            );
            let mut group_keys = category_nodes
                .iter()
                .map(|c| {
                    Ok((
                        "category",
                        format!("category:{}", text(c, "category_id")?),
                        text(c, "name")?.to_owned(),
                    ))
                })
                .collect::<Result<Vec<_>>>()?;
            group_keys.push((
                "receipt_type",
                format!("receipt_type:{}", text(row, "receipt_type_id")?),
                text(row, "receipt_type_name")?.to_owned(),
            ));
            // Taxes and receipt-wide adjustments are category curves, not products.
            if matches!(row["kind"].as_str(), Some("product" | "item_discount")) {
                let name = row["product_name"]
                    .as_str()
                    .unwrap_or_else(|| row["raw_name"].as_str().unwrap_or("未命名商品"));
                group_keys.push(("product", format!("product:{name}"), name.to_owned()));
            }
            for (grouping, key, label) in group_keys {
                let entry=groups.entry(key.clone()).or_insert_with(||json!({"key":key,"group":grouping,"label":label,"amount":0,"line_ids":[],"quantities":{},"category_keys":[],"has_activity":false}));
                if grouping == "product"
                    && !entry["category_keys"]
                        .as_array()
                        .unwrap()
                        .contains(&json!(category_key))
                {
                    entry["category_keys"]
                        .as_array_mut()
                        .unwrap()
                        .push(json!(category_key));
                }
                entry["has_activity"] = json!(entry["has_activity"] == true || amount != 0);
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
        // Allocate only receipt-level reconciliation and FX rounding to its
        // receipt default. Do not invent or distribute product amounts.
        if v["category"].is_null() {
            for (kind, residual) in residuals {
                if residual == 0 || (!v["receipt_type"].is_null() && v["receipt_type"] != kind) {
                    continue;
                }
                let row = self.one(receipt_type_queries::GET, &[json!(kind)])?;
                let key = format!("receipt_type:{kind}");
                let entry=groups.entry(key.clone()).or_insert_with(||json!({"key":key,"group":"receipt_type","label":row["name"],"amount":0,"line_ids":[],"quantities":{},"category_keys":[],"has_activity":false}));
                entry["amount"] = json!(
                    number(entry, "amount")?
                        .checked_add(residual)
                        .ok_or_else(invalid)?
                );
                entry["reconciliation"] = json!(residual);
                entry["has_activity"] = json!(true);
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
            json!({"currency":currency,"net":net,"difference":if v["category"].is_null() && v["receipt_type"].is_null(){json!(all_difference)}else{Value::Null},"rounding_adjustment":if v["category"].is_null() && v["receipt_type"].is_null(){json!(rounding_adjustment)}else{Value::Null},"entries":entries.into_iter().skip(offset).take(limit).collect::<Vec<_>>(),"next_offset":if offset.saturating_add(limit)<total{Some(offset+limit)}else{None},"groups":groups,"spend":spend,"discounts":discounts,"refunds":refunds,"start":start,"end":end}),
        )
    }

    fn trend_action(&self, input: &Value) -> Result<Value> {
        let mut points = crate::calendar::trend_ranges(input)?;
        let currency = self.report_currency()?;
        let mut series = std::collections::BTreeMap::<String, Value>::new();
        let count = points.len();
        // The selector is a catalogue, not just the categories with spending in
        // this window. Keep empty categories and children as independent curves.
        for category in self.rows(catalog_queries::CATEGORIES_CONTAINING, &[json!("%")])? {
            let key = format!("category:{}", text(&category, "category_id")?);
            series.insert(
                key.clone(),
                json!({
                    "key": key,
                    "label": category["name"],
                    "group": "category",
                    "path": category["path"],
                    "depth": category["depth"],
                    "category_keys": [],
                    "has_activity": false,
                    "values": vec![0i64; count],
                }),
            );
        }
        for kind in self.rows(receipt_type_queries::LIST, &[])? {
            let key = format!("receipt_type:{}", text(&kind, "receipt_type_id")?);
            series.insert(key.clone(), json!({"key":key,"label":kind["name"],"group":"receipt_type","category_keys":[],"has_activity":false,"values":vec![0i64;count]}));
        }
        for (index, point) in points.iter_mut().enumerate() {
            let summary = self.report_data(
                &json!({
                    "start": point["start"],
                    "end": point["end"],
                    "zone": input["zone"],
                    "category": input["category"],
                    "receipt_type": input["receipt_type"],
                    "limit": 1,
                }),
                true,
            )?;
            point["net"] = summary["net"].clone();
            point["spend"] = summary["spend"].clone();
            for group in summary["groups"].as_array().ok_or_else(invalid)? {
                let key = text(group, "key")?.to_owned();
                let line = series.entry(key.clone()).or_insert_with(|| {
                    json!({
                        "key": key,
                        "label": group["label"],
                        "group": group["group"],
                        "category_keys": [],
                        "has_activity": false,
                        "values": vec![0i64; count],
                    })
                });
                for category in group["category_keys"].as_array().ok_or_else(invalid)? {
                    if !line["category_keys"].as_array().unwrap().contains(category) {
                        line["category_keys"]
                            .as_array_mut()
                            .unwrap()
                            .push(category.clone());
                    }
                }
                line["values"][index] = group["amount"].clone();
                line["has_activity"] =
                    json!(line["has_activity"] == true || group["has_activity"] == true);
            }
        }
        let mut series = series.into_values().collect::<Vec<_>>();
        series.sort_by(|a, b| {
            (
                a["group"].as_str(),
                a["path"].as_str().or(a["label"].as_str()),
                a["key"].as_str(),
            )
                .cmp(&(
                    b["group"].as_str(),
                    b["path"].as_str().or(b["label"].as_str()),
                    b["key"].as_str(),
                ))
        });
        Ok(json!({
            "currency": currency,
            "period": input["period"],
            "window": input["window"],
            "points": points,
            "series": series,
        }))
    }
}
