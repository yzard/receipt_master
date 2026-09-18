use crate::{
    db::{Result, Store, id, invalid, text},
    jobs::fixed,
};
use serde_json::{Value, json};

impl Store {
    pub fn edit_receipt(&self, input: &Value) -> Result<Value> {
        let mut r = input["receipt"].clone();
        serde_json::from_value::<crate::db::receipts::Receipt>(r.clone()).map_err(|_| invalid())?;
        let digits = self.one(
            "SELECT minor_digits FROM currency WHERE code=?",
            &[r["currency"].clone()],
        )?["minor_digits"]
            .as_u64()
            .ok_or_else(invalid)? as u32;
        if input["total_text"].is_string() {
            r["totalMinor"] = fixed(&input["total_text"], digits)?;
        }
        match text(input, "action")? {
            "preview" => {}
            "currency" => {
                let next = self.one(
                    "SELECT minor_digits FROM currency WHERE code=?",
                    &[input["currency"].clone()],
                )?["minor_digits"]
                    .as_u64()
                    .ok_or_else(invalid)? as u32;
                fn convert(v: &mut Value, old: u32, new: u32) -> Result<()> {
                    if let Some(n) = v.as_i64() {
                        let result = if new >= old {
                            i128::from(n) * 10i128.pow(new - old)
                        } else {
                            let divisor = 10i128.pow(old - new);
                            if i128::from(n) % divisor != 0 {
                                return Err(invalid());
                            }
                            i128::from(n) / divisor
                        };
                        *v = json!(i64::try_from(result).map_err(|_| invalid())?);
                    }
                    Ok(())
                }
                convert(&mut r["totalMinor"], digits, next)?;
                for l in r["lines"].as_array_mut().ok_or_else(invalid)? {
                    convert(&mut l["amountMinor"], digits, next)?;
                    convert(&mut l["printedAmountMinor"], digits, next)?;
                    convert(&mut l["unitPriceScaled"], digits, next)?;
                }
                r["currency"] = input["currency"].clone();
            }
            "split" | "merge" => {
                let ids = input["selected"].as_array().ok_or_else(invalid)?;
                let lines = r["lines"].as_array_mut().ok_or_else(invalid)?;
                let indexes = lines
                    .iter()
                    .enumerate()
                    .filter(|(_, l)| ids.contains(&l["id"]))
                    .map(|(i, _)| i)
                    .collect::<Vec<_>>();
                if indexes.len() != ids.len()
                    || indexes.is_empty()
                    || indexes.iter().any(|&i| {
                        lines[i]["kind"] != "product" || lines[i]["amountMinor"].as_i64().is_none()
                    })
                {
                    return Err(invalid());
                }
                let first = indexes[0];
                if input["action"] == "split" {
                    if indexes.len() != 1 {
                        return Err(invalid());
                    }
                    let amount = fixed(&input["amount_text"], digits)?
                        .as_i64()
                        .ok_or_else(invalid)?;
                    let remainder = lines[first]["amountMinor"]
                        .as_i64()
                        .unwrap()
                        .checked_sub(amount)
                        .ok_or_else(invalid)?;
                    let mut other = lines[first].clone();
                    other["id"] = json!(id());
                    other["amountMinor"] = json!(remainder);
                    lines[first]["amountMinor"] = json!(amount);
                    for line in [&mut lines[first], &mut other] {
                        for key in [
                            "quantityMicros",
                            "quantityUnit",
                            "unitPriceScaled",
                            "printedAmountMinor",
                        ] {
                            line[key] = Value::Null;
                        }
                        line["warnings"]
                            .as_array_mut()
                            .ok_or_else(invalid)?
                            .push(json!("拆分后的商品、规格和数量需要确认"));
                    }
                    lines.insert(first + 1, other);
                } else {
                    if indexes.len() < 2 {
                        return Err(invalid());
                    }
                    let amount = indexes.iter().try_fold(0i64, |sum, &i| {
                        sum.checked_add(lines[i]["amountMinor"].as_i64().unwrap())
                            .ok_or_else(invalid)
                    })?;
                    let name = indexes
                        .iter()
                        .map(|&i| lines[i]["rawName"].as_str().unwrap_or(""))
                        .collect::<Vec<_>>()
                        .join(" / ");
                    let evidence = indexes
                        .iter()
                        .flat_map(|&i| lines[i]["evidence"].as_array().cloned().unwrap_or_default())
                        .collect::<Vec<_>>();
                    let keep = lines[first]["id"].clone();
                    lines[first]["amountMinor"] = json!(amount);
                    lines[first]["rawName"] = json!(name);
                    lines[first]["productNameEdit"] = Value::Null;
                    lines[first]["evidence"] = json!(evidence);
                    for key in [
                        "printedAmountMinor",
                        "sku",
                        "taxCode",
                        "productId",
                        "weightMg",
                        "quantityMicros",
                        "quantityUnit",
                        "unitPriceScaled",
                    ] {
                        lines[first][key] = Value::Null;
                    }
                    lines[first]["warnings"]
                        .as_array_mut()
                        .ok_or_else(invalid)?
                        .push(json!("合并后的商品身份与数量需要重新确认"));
                    for line in lines.iter_mut() {
                        if ids.contains(&line["discountTarget"]) {
                            line["discountTarget"] = keep.clone();
                        }
                    }
                    lines.retain(|line| !ids.contains(&line["id"]) || line["id"] == keep);
                }
            }
            "total_from_lines" => {
                let total = r["lines"].as_array().ok_or_else(invalid)?.iter().try_fold(
                    0i64,
                    |sum, l| {
                        sum.checked_add(l["amountMinor"].as_i64().ok_or_else(invalid)?)
                            .ok_or_else(invalid)
                    },
                )?;
                r["totalMinor"] = json!(total);
                r["totalSource"] = json!("user_computed");
            }
            _ => return Err(invalid()),
        }
        let currency = text(&r, "currency")?.to_owned();
        crate::sku::inherit_discount_metadata(r["lines"].as_array_mut().ok_or_else(invalid)?);
        self.display_data(&mut r, digits, &currency)?;
        Ok(r)
    }
}
