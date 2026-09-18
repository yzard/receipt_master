use crate::{
    db::{Result, invalid},
    jobs::fixed,
};
use serde_json::{Value, json};

/// Nanograms per printed mass unit. Integer arithmetic preserves exact lb/oz factors.
pub fn factor(unit: &str) -> Option<i128> {
    match unit.trim().to_ascii_lowercase().as_str() {
        "g" | "gram" | "grams" => Some(1_000_000_000),
        "kg" | "kgs" | "kilogram" | "kilograms" => Some(1_000_000_000_000),
        "lb" | "lbs" | "pound" | "pounds" => Some(453_592_370_000),
        "oz" | "ounce" | "ounces" => Some(28_349_523_125),
        _ => None,
    }
}
pub fn from_quantity(quantity_micros: i64, unit: &str) -> Result<Value> {
    let Some(factor) = factor(unit) else {
        return Ok(Value::Null);
    };
    if quantity_micros <= 0 {
        return Ok(Value::Null);
    }
    let mg = (i128::from(quantity_micros) * factor + 500_000_000_000) / 1_000_000_000_000;
    Ok(json!(i64::try_from(mg).map_err(|_| invalid())?))
}
pub fn recognized(line: &Value) -> Result<Value> {
    if line["kind"] != "product" {
        return Ok(Value::Null);
    }
    if let (Some(q), Some(unit)) = (
        fixed(&line["quantity"], 6)?.as_i64(),
        line["quantity_unit"].as_str(),
    ) && factor(unit).is_some()
    {
        return from_quantity(q, unit);
    }
    match (
        fixed(&line["package_weight"], 9)?.as_i64(),
        line["package_weight_unit"].as_str().and_then(factor),
    ) {
        (Some(n), Some(factor)) if n > 0 => Ok(json!(
            i64::try_from((i128::from(n) * factor + 500_000_000_000_000) / 1_000_000_000_000_000)
                .map_err(|_| invalid())?
        )),
        _ => Ok(Value::Null),
    }
}
/// Presentation only: kg/lb use two decimal places; canonical quantities stay exact.
pub fn quantity_text(micros: i64, unit: &str) -> String {
    format_quantity(i128::from(micros), unit)
}
fn format_quantity(n: i128, unit: &str) -> String {
    if matches!(factor(unit), Some(1_000_000_000_000 | 453_592_370_000)) {
        let cents = (n.abs() + 5_000) / 10_000;
        format!(
            "{}{}.{:02}",
            if n < 0 && cents != 0 { "-" } else { "" },
            cents / 100,
            cents % 100
        )
    } else {
        format!(
            "{}{}.{:06}",
            if n < 0 { "-" } else { "" },
            n.abs() / 1_000_000,
            n.abs() % 1_000_000
        )
        .trim_end_matches('0')
        .trim_end_matches('.')
        .to_string()
    }
}
fn display_quantity(value: &Value, unit: &str) -> String {
    value
        .as_i64()
        .map(|q| quantity_text(q, unit))
        .unwrap_or_default()
}
pub fn label(mg: i64, unit: &str) -> String {
    let n = i128::from(mg) * 1_000_000_000_000;
    let divisor = factor(unit).unwrap_or(1_000_000_000);
    let micros = (n.abs() + divisor / 2) / divisor * n.signum();
    format!("{} {unit}", format_quantity(micros, unit))
}

fn decimal(value: &Value, digits: u32) -> String {
    let Some(n) = value.as_i64() else {
        return String::new();
    };
    let scale = 10i128.pow(digits);
    let n = i128::from(n);
    let text = format!(
        "{}{}.{:0width$}",
        if n < 0 { "-" } else { "" },
        n.abs() / scale,
        n.abs() % scale,
        width = digits as usize
    );
    text.trim_end_matches('0').trim_end_matches('.').to_string()
}
fn ratio(value: &Value, numerator: i128, denominator: i128) -> Result<Value> {
    let Some(n) = value.as_i64() else {
        return Ok(Value::Null);
    };
    let n = i128::from(n) * numerator;
    Ok(json!(
        i64::try_from((n.abs() + denominator / 2) / denominator * n.signum())
            .map_err(|_| invalid())?
    ))
}
fn entered(text: &Value, digits: u32) -> Result<Value> {
    if text.as_str().is_some_and(|s| s.trim().is_empty()) {
        return Ok(Value::Null);
    }
    fixed(text, digits)
}
impl crate::db::Store {
    pub fn display_data(&self, value: &mut Value, digits: u32, currency: &str) -> Result<()> {
        let preference = self.one("SELECT weight_unit FROM app_preferences WHERE id=1", &[])?;
        let unit = crate::db::text(&preference, "weight_unit")?;
        self.display_with_unit(value, digits, unit, currency)
    }
    fn display_with_unit(
        &self,
        value: &mut Value,
        digits: u32,
        unit: &str,
        currency: &str,
    ) -> Result<()> {
        let currency = value["currency"].as_str().unwrap_or(currency).to_owned();
        let digits = if let Some(currency) = value["currency"].as_str() {
            self.one(
                "SELECT minor_digits FROM currency WHERE code=?",
                &[json!(currency)],
            )?["minor_digits"]
                .as_u64()
                .ok_or_else(invalid)? as u32
        } else {
            digits
        };
        if let Some(lines) = value.get("lines").and_then(Value::as_array) {
            let total = lines.iter().try_fold(0i64, |sum, l| {
                sum.checked_add(l["amountMinor"].as_i64().unwrap_or(0))
                    .ok_or_else(invalid)
            })?;
            let difference = value["totalMinor"]
                .as_i64()
                .map(|n| n.checked_sub(total).ok_or_else(invalid))
                .transpose()?;
            value["summary"] = json!({"knownTotal":total,"difference":difference});
        }
        if value.get("rawName").is_some() && value.get("weightMg").is_some() {
            crate::receipt_lines::check_weight_amount(value, digits, &currency);
            let mut weight = value["weightMg"].clone();
            if weight.is_null()
                && value["kind"] == "product"
                && let (Some(q), Some(source)) = (
                    value["quantityMicros"].as_i64(),
                    value["quantityUnit"].as_str(),
                )
            {
                weight = from_quantity(q, source)?;
            }
            let mut quantity = value["quantityMicros"].clone();
            let mut price = value["unitPriceScaled"].clone();
            let mut quantity_unit = value["quantityUnit"].as_str().unwrap_or("").to_owned();
            if let Some(source) = factor(&quantity_unit) {
                quantity = ratio(&quantity, source, factor(unit).unwrap())?;
                price = ratio(&price, factor(unit).unwrap(), source)?;
                quantity_unit = unit.into();
            }
            let weight_text = display_quantity(
                &ratio(&weight, 1_000_000_000_000, factor(unit).unwrap())?,
                unit,
            );
            let name = value["rawName"].as_str().unwrap_or("");
            let product_name = self.rows(
                "SELECT a.name,a.category_id FROM product_name a JOIN printed_name_product_name m USING(product_name_id) JOIN printed_name n USING(printed_name_id) WHERE n.raw_name=?",
                &[json!(crate::db::normalized(name))],
            )?.first().map(|row| row["name"].clone()).unwrap_or(Value::Null);
            let product_name = if value["kind"] == "product" {
                value["productNameEdit"]
                    .as_str()
                    .map(|v| json!(crate::db::normalized(v)))
                    .unwrap_or(product_name)
            } else {
                product_name
            };
            value["display"] = json!({"productName":product_name,"weightText":weight_text,"weightUnit":unit,"weightLabel":if weight_text.is_empty(){String::new()}else{format!("{weight_text} {unit}")},"quantityText":display_quantity(&quantity,&quantity_unit),"quantityUnit":quantity_unit,"priceText":decimal(&price,digits+6),"amountText":decimal(&value["amountMinor"],digits),"pricingNote":if value["printedAmountMinor"].is_number(){format!("原票面净额 {currency} {}；优惠已拆分",crate::receipt_lines::money(i128::from(value["printedAmountMinor"].as_i64().unwrap()),digits))}else{String::new()}});
            return Ok(());
        }
        if let Some(weight) = value.get("weight_mg") {
            value["weight_label"] = json!(
                weight
                    .as_i64()
                    .map(|w| label(w, unit))
                    .unwrap_or_else(|| "重量未知".into())
            );
            value["weight_text"] = json!(display_quantity(
                &ratio(
                    &value["weight_mg"],
                    1_000_000_000_000,
                    factor(unit).unwrap()
                )?,
                unit
            ));
        }
        match value {
            Value::Object(map) => {
                for item in map.values_mut() {
                    if item.is_object() || item.is_array() {
                        self.display_with_unit(item, digits, unit, &currency)?;
                    }
                }
            }
            Value::Array(array) => {
                for item in array {
                    self.display_with_unit(item, digits, unit, &currency)?;
                }
            }
            _ => {}
        }
        Ok(())
    }
    pub fn prepare_line(&self, input: &Value, apply: bool) -> Result<Value> {
        let mut line = input["line"].clone();
        crate::sku::normalize(&mut line)?;
        // Validate the DTO, then compute display and conversions only on the server.
        serde_json::from_value::<crate::db::receipts::Line>(line.clone()).map_err(|_| invalid())?;
        let digits = self.one(
            "SELECT minor_digits FROM currency WHERE code=?",
            &[input["currency"].clone()],
        )?["minor_digits"]
            .as_u64()
            .ok_or_else(invalid)? as u32;
        self.display_data(&mut line, digits, crate::db::text(input, "currency")?)?;
        if apply {
            let fields = &input["fields"];
            if fields["weightUnit"] != line["display"]["weightUnit"] {
                return Err(crate::db::conflict());
            }
            if fields["weightText"] != line["display"]["weightText"] {
                let q = entered(&fields["weightText"], 6)?;
                line["weightMg"] = ratio(
                    &q,
                    factor(crate::db::text(fields, "weightUnit")?).ok_or_else(invalid)?,
                    1_000_000_000_000,
                )?;
            }
            let unit_changed = fields["quantityUnit"] != line["display"]["quantityUnit"];
            let display_unit = line["display"]["quantityUnit"].as_str().unwrap_or("");
            let source_unit = line["quantityUnit"].as_str().unwrap_or("");
            let conversion = factor(display_unit).zip(factor(source_unit));
            if unit_changed || fields["quantityText"] != line["display"]["quantityText"] {
                let mut quantity = entered(&fields["quantityText"], 6)?;
                if !unit_changed && let Some((display, source)) = conversion {
                    quantity = ratio(&quantity, display, source)?;
                }
                line["quantityMicros"] = quantity;
            }
            if unit_changed || fields["priceText"] != line["display"]["priceText"] {
                let mut price = entered(&fields["priceText"], digits + 6)?;
                if !unit_changed && let Some((display, source)) = conversion {
                    price = ratio(&price, source, display)?;
                }
                line["unitPriceScaled"] = price;
            }
            if line["quantityMicros"].is_null() {
                line["quantityUnit"] = Value::Null;
            } else if unit_changed {
                line["quantityUnit"] = fields["quantityUnit"].clone();
            }
            line["amountMinor"] = entered(&fields["amountText"], digits)?;
            self.display_data(&mut line, digits, crate::db::text(input, "currency")?)?;
        }
        Ok(line)
    }
}
