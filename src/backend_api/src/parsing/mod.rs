//! Store-specific deterministic interpretation; OCR service only supplies text and geometry.
mod chinese;
mod costco;
mod generic;
mod hmart;
mod hualian;
use generic::{attach_weight, date, has_chinese, label, line, money_at_end, summary, weighted};
mod layout;
mod ranch99;
mod skyfoods;
use regex::Regex;
use serde_json::{Value, json};

pub fn profile(store: Option<&str>) -> &'static str {
    let normalized: String = store
        .unwrap_or("")
        .chars()
        .filter(|c| c.is_alphanumeric())
        .flat_map(char::to_lowercase)
        .collect();
    match normalized.as_str() {
        "costco" | "costcowholesale" => "costco",
        "skyfood" | "skyfoods" => "skyfoods",
        "hmart" => "hmart",
        "hualian" | "hualiansupermarket" | "华联" | "華聯" => "hualian",
        "99ranch" | "99ranchmarket" => "ranch99",
        _ => "generic",
    }
}
pub fn parse(pages: &[Value], store: Option<&str>) -> Value {
    let profile = profile(store);
    let mut rows: Vec<layout::Row> = Vec::new();
    for (index, page) in pages.iter().enumerate() {
        let next = layout::rows(page, index);
        // Only collapse a consecutive suffix/prefix across photos, never repetitions in a photo.
        let signature = |s: &str| {
            s.chars()
                .filter(|c| !c.is_whitespace())
                .flat_map(char::to_uppercase)
                .collect::<String>()
        };
        let prefix = next
            .iter()
            .position(|r| money_at_end(&r.text).is_some())
            .unwrap_or(0);
        let mut skip = 0;
        for start in [0, prefix] {
            if let Some(n) = (2..=rows.len().min(next.len() - start)).rev().find(|&n| {
                rows[rows.len() - n..]
                    .iter()
                    .zip(&next[start..start + n])
                    .all(|(a, b)| signature(&a.text) == signature(&b.text))
            }) {
                skip = skip.max(start + n);
            }
        }
        rows.extend(next.into_iter().skip(skip));
    }
    if profile == "skyfoods" {
        rows = skyfoods::blocks(rows);
    }
    if profile == "costco" {
        for row in &mut rows {
            if let Some(text) = costco::damaged_price(&row.text) {
                row.text = text;
                row.notes
                    .push("票面价格的小数点识别为斜线，已按价格列解释，请核对。".into());
            }
        }
    }
    let mut data = json!({"store":null,"branch":null,"address":null,"country":null,"currency":null,"local_time":null,"total":null,"lines":[]});
    generic::header(&rows, &mut data);
    let mut lines: Vec<Value> = Vec::new();
    let mut last_product: Option<usize> = None;
    let mut product_row: Option<&layout::Row> = None;
    let mut pending_weight = None;
    let refund = rows.iter().any(|r| {
        Regex::new(
            r"(?i)^(?:REFUND(?:\s*/\s*MEMBERSHIP)?|RETURN|MERCHANDISE RETURN|MEMBERSHIP\s*/?\s*REFUND)$",
        )
        .unwrap()
        .is_match(r.text.trim())
    });
    let mut closed = false;
    let mut prescan_ended = false;
    let mut dates = if profile == "ranch99" {
        ranch99::transaction_dates(&rows)
    } else {
        Vec::new()
    };
    let promotion = Regex::new(r"^\d+\s*(?:@|0)?\s*\d+\s*/").unwrap();
    let taxes = Regex::new(r"(?i)^(?:SALES\s+)?TAX(?:\s*\d+)?$").unwrap();
    let counted = Regex::new(r"(?i)^(\d+)\s*@\s*\$?(\d+\.\d{2})\s*(?:each|ea)?$").unwrap();
    let coupons = Regex::new(r"(?i)COUPON|DISCOUNT|^\d+\s*/\s*\d+$").unwrap();
    for (row_index, row) in rows.iter().enumerate() {
        let text = row.text.trim();
        if profile == "costco"
            && text.to_uppercase().contains("END OF")
            && text.to_uppercase().contains("SCANNED")
        {
            prescan_ended = true;
            continue;
        }
        if let Some(d) = date(text) {
            if profile != "ranch99" && !dates.contains(&d) {
                dates.push(d);
            }
            continue;
        }
        if let Some(w) = weighted(text) {
            if profile == "hualian" {
                if !closed {
                    pending_weight = Some(w);
                }
            } else if profile == "ranch99" {
                generic::attach_previous_weight(w, &mut lines, last_product, closed);
            } else if profile == "hmart"
                && rows
                    .get(row_index + 1)
                    .is_some_and(|r| r.text.trim_start().to_uppercase().starts_with("WT "))
            {
                pending_weight = Some(w);
            } else if let Some(index) = last_product {
                attach_weight(&mut lines[index], w.0, w.1, w.2);
            } else {
                pending_weight = Some(w);
            }
            continue;
        }
        // Promotion quantity and unit price are not additional merchandise.
        if (profile == "skyfoods" || text.contains('@')) && promotion.is_match(text) {
            continue;
        }
        if let Some(c) = counted.captures(text) {
            if let Some(index) = last_product {
                lines[index]["quantity"] = json!(&c[1]);
                lines[index]["quantity_unit"] = json!("count");
                lines[index]["unit_price"] = json!(&c[2]);
            }
            continue;
        }
        if profile == "hualian"
            && !(pending_weight.is_some() && money_at_end(text).is_some())
            && !closed
            && let (Some(index), Some(anchor)) = (last_product, product_row)
            && hualian::continuation(row, anchor, &mut lines[index])
        {
            continue;
        }
        let Some((name, amount, tax)) = money_at_end(text) else {
            if has_chinese(text)
                && !closed
                && let Some(index) = last_product
            {
                lines[index]["product_name"] = json!(text);
                generic::continuation_evidence(&mut lines[index], row);
            }
            continue;
        };
        let name_label = label(&name);
        if matches!(
            name_label.as_str(),
            "TOTAL" | "GRAND TOTAL" | "TOTAL DUE" | "REFUND TOTAL" | "BALANCE"
        ) {
            if data["total"].is_null() {
                data["total"] = json!(amount);
            }
            pending_weight = None;
            closed = true;
            continue;
        }
        if name_label.is_empty() || summary(&name) {
            if profile == "hualian" {
                pending_weight = None;
            }
            continue;
        }
        if profile == "costco"
            && prescan_ended
            && !taxes.is_match(&name_label)
            && costco::subtotal(&amount, &lines)
        {
            continue;
        }
        let tax_line = taxes.is_match(&name_label);
        let tip = matches!(
            name_label.as_str(),
            "TIP" | "TIPS" | "GRATUITY" | "GRATUITIES"
        );
        if closed && !tip {
            continue;
        }
        let kind = if tax_line {
            "tax"
        } else if tip {
            "tip"
        } else if name_label == "DEPOSIT" || name_label == "BOTTLE DEPOSIT" {
            "deposit"
        } else {
            "product"
        };
        if profile == "hualian" && kind != "product" {
            pending_weight = None;
        }
        let mut item = line(row, name.clone(), amount, tax, kind);
        if kind == "product" {
            let target = match profile {
                "costco" => costco::discount_target(&name, &lines),
                "skyfoods" if skyfoods::is_discount(&name) => last_product,
                _ => None,
            };
            let coupon = skyfoods::is_discount(&name) || coupons.is_match(&name);
            if let Some(target) = target {
                if profile == "costco"
                    && name
                        .split('/')
                        .nth(1)
                        .is_some_and(|s| s.trim().starts_with(char::is_alphabetic))
                {
                    item["review_notes"]
                        .as_array_mut()
                        .unwrap()
                        .push(json!("优惠未打印目标 SKU，按相邻商品关联，请核对。"));
                }
                item["kind"] = json!("item_discount");
                item["discount_target_index"] = json!(target);
                for field in ["name", "product_name", "sku", "tax_code"] {
                    item[field] = lines[target][field].clone();
                }
                if profile == "skyfoods" && skyfoods::is_discount(&name) {
                    lines[target]["amount_basis"] = json!("net_including_item_discounts");
                }
            } else if coupon {
                item["kind"] = json!("order_discount");
                if skyfoods::is_discount(&name) {
                    item["review_notes"]
                        .as_array_mut()
                        .unwrap()
                        .push(json!("未找到商品优惠对应的上一项，请核对。"));
                }
            } else {
                match profile {
                    "costco" => costco::product(&mut item),
                    "skyfoods" => skyfoods::product(&mut item),
                    "hmart" => hmart::product(&mut item),
                    _ => {}
                }
                generic::package(&mut item);
                if item["kind"] == "product" {
                    last_product = Some(lines.len());
                    product_row = Some(row);
                }
                if let Some((q, u, p)) = pending_weight.take() {
                    attach_weight(&mut item, q, u, p);
                }
                if profile == "generic" {
                    item["review_notes"]
                        .as_array_mut()
                        .unwrap()
                        .push(json!("使用通用收据规则，请核对商品字段。"));
                }
            }
        }
        if item["name"].as_str().unwrap().is_empty() {
            continue;
        }
        lines.push(item);
    }
    if let Some(d) = dates.first() {
        data["local_time"] = json!(d);
    }
    if dates.len() > 1 {
        data["local_time"] = Value::Null;
        for l in &mut lines {
            l["review_notes"]
                .as_array_mut()
                .unwrap()
                .push(json!("收据存在不同时间，需确认交易时间。"));
        }
    }
    if refund {
        for l in &mut lines {
            if matches!(
                l["kind"].as_str(),
                Some("product" | "tax" | "other_adjustment")
            ) {
                let amount = l["amount"].as_str().unwrap();
                if !amount.starts_with('-') && amount.parse::<f64>().is_ok_and(|v| v > 0.0) {
                    l["amount"] = json!(format!("-{amount}"));
                }
            }
        }
        if let Some(total) = data["total"].as_str()
            && !total.starts_with('-')
        {
            data["total"] = json!(format!("-{total}"));
        }
    }
    data["lines"] = json!(lines);
    if let Some((sum, total)) = crate::pipeline::arithmetic_difference(&data) {
        let note = format!(
            "明细合计 {}，票面总额 {}，相差 {}；请核对，系统未补造费用。",
            crate::receipt_lines::money(sum, 3),
            crate::receipt_lines::money(total, 3),
            crate::receipt_lines::money(total - sum, 3)
        );
        for l in data["lines"].as_array_mut().unwrap() {
            l["review_notes"].as_array_mut().unwrap().push(json!(note));
        }
    }
    data
}
