//! Arithmetic checks only; receipt interpretation belongs to the visual model.
use crate::weights;
use serde_json::{Value, json};

pub(crate) fn money(amount: i128, digits: u32) -> String {
    let scale = 10i128.pow(digits);
    let sign = if amount < 0 { "-" } else { "" };
    if digits == 0 {
        return format!("{sign}{}", amount.abs());
    }
    format!(
        "{sign}{}.{:0width$}",
        amount.abs() / scale,
        amount.abs() % scale,
        width = digits as usize
    )
}

/// Recalculate derived warnings after every read/edit; never change the printed amount.
pub fn check_weight_amount(line: &mut Value, digits: u32, currency: &str) {
    let mut warnings = line["warnings"].as_array().cloned().unwrap_or_default();
    warnings.retain(|w| {
        !w.as_str()
            .is_some_and(|s| s.starts_with("称重金额不符：") || s.starts_with("称重信息缺失："))
    });
    let wt = line["isWeighed"] == true;
    let mass = line["quantityUnit"]
        .as_str()
        .and_then(weights::factor)
        .is_some();
    if line["kind"] == "product" && (wt || mass) {
        match (
            line["quantityMicros"].as_i64(),
            line["unitPriceScaled"].as_i64(),
            line["amountMinor"].as_i64(),
        ) {
            (Some(q), Some(price), Some(amount)) if mass && q > 0 => {
                let product = i128::from(q) * i128::from(price);
                let expected =
                    (product.abs() + 500_000_000_000) / 1_000_000_000_000 * product.signum();
                let delta = i128::from(amount) - expected;
                if delta != 0 {
                    warnings.push(json!(format!("称重金额不符：计算 {currency} {}，票面 {currency} {}，差额 {currency} {}{}（票面−计算）",money(expected,digits),money(i128::from(amount),digits),if delta>0 {"+"} else {""},money(delta,digits))));
                }
            }
            _ => warnings.push(json!(
                "称重信息缺失：缺少有效重量、重量单位、单价或票面金额，无法核验"
            )),
        }
    }
    line["warnings"] = json!(warnings);
}

/// Convert explicitly identified net prices to gross prices through linked discounts.
/// The visual model decides amount_basis; no text/merchant inference occurs here.
pub fn amounts(data: &Value, digits: u32) -> crate::db::Result<Vec<(Value, Value)>> {
    let lines = data["lines"].as_array().ok_or_else(crate::db::invalid)?;
    let raw = lines
        .iter()
        .map(|l| crate::jobs::fixed(&l["amount"], digits))
        .collect::<crate::db::Result<Vec<_>>>()?;
    let mut output = Vec::with_capacity(lines.len());
    for (i, line) in lines.iter().enumerate() {
        if line["amount_basis"] != "net_including_item_discounts" {
            output.push((raw[i].clone(), Value::Null));
            continue;
        }
        let targets = lines
            .iter()
            .enumerate()
            .filter(|(_, l)| {
                l["kind"] == "item_discount"
                    && l["discount_target_index"].as_u64() == Some(i as u64)
            })
            .map(|(j, _)| j)
            .collect::<Vec<_>>();
        if line["kind"] != "product" || targets.is_empty() {
            return Err(crate::db::invalid());
        }
        let discount = targets.iter().try_fold(0i128, |sum, j| {
            sum.checked_add(i128::from(raw[*j].as_i64()?))
        });
        let gross = match (raw[i].as_i64(), discount) {
            (Some(net), Some(discount)) => {
                json!(i64::try_from(i128::from(net) - discount).map_err(|_| crate::db::invalid())?)
            }
            _ => Value::Null,
        };
        output.push((gross, raw[i].clone()));
    }
    Ok(output)
}
