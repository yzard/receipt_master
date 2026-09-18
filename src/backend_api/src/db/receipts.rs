use super::*;
use serde::{Deserialize, Serialize};

// Older jobs and stored receipts contain this unconditional, unsupported warning.
const LEGACY_CONFIDENCE_WARNING: &str = "识别置信度低或未知";
fn actionable_warning(warning: &str) -> bool {
    warning != LEGACY_CONFIDENCE_WARNING
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Line {
    pub id: String,
    pub kind: String,
    pub raw_name: String,
    pub tax_code: Option<String>,
    pub sku: Option<String>,
    #[serde(default)]
    pub is_weighed: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub product_name_edit: Option<String>,
    pub category_id: String,
    pub product_id: Option<String>,
    pub discount_target: Option<String>,
    pub quantity_unit: Option<String>,
    pub weight_mg: Option<i64>,
    pub quantity_micros: Option<i64>,
    pub unit_price_scaled: Option<i64>,
    pub amount_minor: Option<i64>,
    pub printed_amount_minor: Option<i64>,
    pub warnings: Vec<String>,
    pub evidence: Vec<Value>,
    #[serde(default)]
    pub display: Value,
}
#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Receipt {
    pub id: String,
    pub store: String,
    #[serde(default)]
    pub recognized_store: String,
    pub branch: String,
    pub address: String,
    pub country: String,
    pub currency: String,
    pub time_source: String,
    pub raw_time: String,
    pub total_source: String,
    pub occurred_at: i64,
    pub created_at: i64,
    pub revision: i64,
    pub total_minor: Option<i64>,
    pub posted: bool,
    pub lines: Vec<Line>,
    #[serde(default)]
    pub summary: Value,
}
impl Store {
    pub fn product(&self, name: &str, weight: Value) -> Result<String> {
        let weight = weight
            .as_i64()
            .map(|w| json!(w as f64 / 1000.0))
            .unwrap_or(Value::Null);
        let rows = self.rows(
            "SELECT product_id FROM product WHERE printed_name_id=? AND weight_g IS ?",
            &[json!(name), weight.clone()],
        )?;
        if let Some(row) = rows.first() {
            return Ok(text(row, "product_id")?.to_string());
        }
        let id = id();
        self.exec(
            "INSERT INTO product VALUES (?,?,?)",
            &[json!(id), json!(name), weight],
        )?;
        Ok(id)
    }
    pub(super) fn printed_name(&self, name: &str) -> Result<String> {
        let name = normalized(name);
        let rows = self.rows(
            "SELECT printed_name_id FROM printed_name WHERE raw_name=?",
            &[json!(name)],
        )?;
        if let Some(row) = rows.first() {
            return Ok(text(row, "printed_name_id")?.to_string());
        }
        let id = id();
        self.exec(
            "INSERT INTO printed_name VALUES (?,?)",
            &[json!(id), json!(name)],
        )?;
        Ok(id)
    }
    fn location(&self, r: &Receipt) -> Result<Option<String>> {
        let name = normalized(&r.store);
        if name.is_empty() {
            return Ok(None);
        }
        let rows = self.rows(
            "SELECT merchant_id FROM merchant WHERE name=? ORDER BY merchant_id",
            &[json!(name)],
        )?;
        let merchant = if let Some(row) = rows.first() {
            text(row, "merchant_id")?.to_string()
        } else {
            let id = id();
            self.exec(
                "INSERT INTO merchant VALUES (?,?)",
                &[json!(id), json!(name)],
            )?;
            id
        };
        let args = [
            json!(merchant),
            json!(r.branch),
            json!(r.address),
            json!(r.country),
        ];
        let rows=self.rows("SELECT location_id FROM store_location WHERE merchant_id=? AND branch_name=? AND address=? AND country_code=?",&args)?;
        if let Some(row) = rows.first() {
            return Ok(Some(text(row, "location_id")?.to_string()));
        }
        let id = id();
        let mut values = vec![json!(id)];
        values.extend(args);
        self.exec("INSERT INTO store_location VALUES (?,?,?,?,?)", &values)?;
        Ok(Some(id))
    }
    pub fn save(&self, mut input: Value, publish: bool) -> Result<Value> {
        for line in input["lines"].as_array_mut().ok_or_else(invalid)? {
            // Already distributed clients omit these fields; preserve existing metadata.
            let old = self.line_sku(&line["id"])?;
            for (key, column) in [("taxCode", "tax_code"), ("sku", "sku")] {
                if line.get(key).is_none() {
                    line[key] = old[column].clone();
                }
            }
            crate::sku::normalize(line)?;
        }
        let missing_printed = input["lines"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|l| l.get("printedAmountMinor").is_none())
            .filter_map(|l| l["id"].as_str().map(str::to_owned))
            .collect::<std::collections::HashSet<_>>();
        let mut r: Receipt = serde_json::from_value(input).map_err(|_| invalid())?;
        for line in &mut r.lines {
            if missing_printed.contains(&line.id) {
                line.printed_amount_minor = self
                    .rows(
                        "SELECT amount_minor FROM line_printed_amount WHERE line_id=?",
                        &[json!(line.id)],
                    )?
                    .first()
                    .and_then(|v| v["amount_minor"].as_i64());
            }
        }
        for line in &mut r.lines {
            if line.kind == "product"
                && line.weight_mg.is_none()
                && let (Some(q), Some(unit)) = (line.quantity_micros, line.quantity_unit.as_deref())
            {
                line.weight_mg = crate::weights::from_quantity(q, unit)?.as_i64();
            }
        }
        if r.country.len() != 2
            || !r.country.bytes().all(|c| c.is_ascii_uppercase())
            || ![
                "recognized",
                "user_entered",
                "estimated_clock",
                "estimated_instant",
            ]
            .contains(&r.time_source.as_str())
            || !["recognized", "user_entered", "user_computed"].contains(&r.total_source.as_str())
            || (publish && r.total_minor.is_none())
        {
            return Err(invalid());
        }
        let digits = self.one(
            "SELECT minor_digits FROM currency WHERE code=?",
            &[json!(r.currency)],
        )?["minor_digits"]
            .as_u64()
            .ok_or_else(invalid)? as u32;
        for l in &mut r.lines {
            if !l.is_weighed {
                l.is_weighed = !self
                    .rows(
                        "SELECT line_id FROM line_weighed WHERE line_id=?",
                        &[json!(l.id)],
                    )?
                    .is_empty();
            }
            let mut checked = serde_json::to_value(&*l).map_err(io_error)?;
            crate::receipt_lines::check_weight_amount(&mut checked, digits, &r.currency);
            l.warnings = serde_json::from_value(checked["warnings"].clone()).map_err(io_error)?;
        }
        let ids = r
            .lines
            .iter()
            .map(|l| l.id.as_str())
            .collect::<std::collections::HashSet<_>>();
        if ids.len() != r.lines.len() {
            return Err(invalid());
        }
        for l in &r.lines {
            if ![
                "product",
                "item_discount",
                "order_discount",
                "tax",
                "tip",
                "deposit",
                "other_adjustment",
            ]
            .contains(&l.kind.as_str())
                || l.weight_mg.is_some_and(|w| w <= 0)
                || l.quantity_micros.is_some_and(|w| w <= 0)
                || (publish && l.amount_minor.is_none())
            {
                return Err(invalid());
            }
            if l.kind == "item_discount"
                && !r
                    .lines
                    .iter()
                    .any(|t| Some(&t.id) == l.discount_target.as_ref() && t.kind == "product")
            {
                return Err(invalid());
            }
        }
        let old = self.rows("SELECT * FROM receipt WHERE receipt_id=?", &[json!(r.id)])?;
        if let Some(old) = old.first() {
            if old["version"] != r.revision {
                return Err(conflict());
            }
            if !old["deleted_at_utc_ms"].is_null() {
                return Err(conflict());
            }
            if old["status"] == "posted" && !publish {
                return Err(invalid());
            }
            r.created_at = number(old, "created_at_utc_ms")?;
        } else {
            if r.revision != 0 {
                return Err(conflict());
            }
            r.created_at = now();
        }
        let prior_names=self.rows("SELECT l.line_id,l.raw_name,COALESCE(c.name,n.name) AS name FROM receipt_line l LEFT JOIN line_product_name_candidate c USING(line_id) LEFT JOIN product p USING(product_id) LEFT JOIN printed_name_product_name m USING(printed_name_id) LEFT JOIN product_name n USING(product_name_id) WHERE l.receipt_id=?", &[json!(r.id)])?;
        for line in &mut r.lines {
            if line.product_name_edit.is_none()
                && let Some(previous) = prior_names
                    .iter()
                    .find(|p| p["line_id"] == line.id && p["raw_name"] != line.raw_name)
            {
                line.product_name_edit = previous["name"].as_str().map(str::to_owned);
            }
        }
        let location = self.location(&r)?;
        r.revision += 1;
        r.posted = publish;
        self.exec("INSERT INTO receipt(receipt_id,location_id,currency_code,country_code,raw_store,raw_branch,raw_address,raw_time_text,occurred_at_utc_ms,time_source,total_minor,total_source,status,version,input_revision,created_at_utc_ms,updated_at_utc_ms) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(receipt_id) DO UPDATE SET location_id=excluded.location_id,currency_code=excluded.currency_code,country_code=excluded.country_code,raw_store=excluded.raw_store,raw_branch=excluded.raw_branch,raw_address=excluded.raw_address,raw_time_text=excluded.raw_time_text,occurred_at_utc_ms=excluded.occurred_at_utc_ms,time_source=excluded.time_source,total_minor=excluded.total_minor,total_source=excluded.total_source,status=excluded.status,version=excluded.version,input_revision=receipt.input_revision+1,updated_at_utc_ms=excluded.updated_at_utc_ms",&[json!(r.id),json!(location),json!(r.currency),json!(r.country),json!(r.store),json!(r.branch),json!(r.address),json!(r.raw_time),json!(r.occurred_at),json!(r.time_source),json!(r.total_minor),json!(r.total_source),json!(if publish{"posted"}else{"draft"}),json!(r.revision),json!(r.revision),json!(r.created_at),json!(now())])?;
        if !r.recognized_store.trim().is_empty() {
            self.exec("INSERT INTO receipt_ocr_store VALUES (?,?) ON CONFLICT(receipt_id) DO UPDATE SET raw_name=excluded.raw_name", &[json!(r.id),json!(r.recognized_store)])?;
        }
        // Snapshot issue states before replacing line relationships, retaining prior review decisions.
        let issues = self.rows(
            "SELECT * FROM review_issue WHERE receipt_id=?",
            &[json!(r.id)],
        )?;
        self.exec("DELETE FROM line_discount WHERE discount_line_id IN (SELECT line_id FROM receipt_line WHERE receipt_id=?)",&[json!(r.id)])?;
        self.exec(
            "DELETE FROM receipt_line WHERE receipt_id=?",
            &[json!(r.id)],
        )?;
        self.exec(
            "DELETE FROM review_issue WHERE receipt_id=?",
            &[json!(r.id)],
        )?;
        let mut name_changed = false;
        for (position, l) in r.lines.iter_mut().enumerate() {
            if l.kind.ends_with("discount") {
                if l.amount_minor.is_some_and(|v| v > 0) {
                    return Err(invalid());
                }
                l.quantity_micros = Some(1_000_000);
                l.quantity_unit = Some("ea".into());
                l.unit_price_scaled = l
                    .amount_minor
                    .map(|a| a.checked_mul(1_000_000).ok_or_else(invalid))
                    .transpose()?;
            }
            if l.quantity_micros.is_none() {
                l.quantity_unit = None;
            } else if l.quantity_unit.as_ref().is_none_or(|s| s.trim().is_empty()) {
                return Err(invalid());
            }
            l.product_id = if publish && l.kind == "product" && !normalized(&l.raw_name).is_empty()
            {
                Some(self.product(&self.printed_name(&l.raw_name)?, json!(l.weight_mg))?)
            } else {
                None
            };
            if publish
                && l.kind == "product"
                && l.product_id.is_some()
                && let Some(name) = &l.product_name_edit
            {
                let product = self.one(
                    "SELECT printed_name_id FROM product WHERE product_id=?",
                    &[json!(l.product_id)],
                )?;
                name_changed |= self.save_product_name(
                    text(&product, "printed_name_id")?,
                    name,
                    &l.category_id,
                )?;
                if l.category_id == UNCATEGORIZED
                    && let Some(mapping) = self.rows("SELECT n.category_id FROM printed_name_product_name m JOIN product_name n USING(product_name_id) WHERE m.printed_name_id=?", &[product["printed_name_id"].clone()])?.first() {
                        l.category_id = text(mapping, "category_id")?.to_owned();
                }
            }
            self.exec(
                "INSERT INTO receipt_line VALUES (?,?,?,?,?,?,?,?,?,?)",
                &[
                    json!(l.id),
                    json!(r.id),
                    json!(position),
                    json!(l.kind),
                    json!(l.raw_name),
                    json!(l.product_id),
                    json!(l.quantity_micros),
                    json!(l.quantity_unit),
                    json!(l.unit_price_scaled),
                    json!(l.amount_minor),
                ],
            )?;
            if !publish
                && l.kind == "product"
                && let Some(name) = &l.product_name_edit
            {
                self.exec(
                    "INSERT INTO line_product_name_candidate VALUES (?,?)",
                    &[json!(l.id), json!(normalized(name))],
                )?;
            }
            self.save_line_sku(
                &l.id,
                location.as_deref(),
                l.sku.as_deref(),
                l.tax_code.as_deref(),
            )?;
            if l.product_id.is_none() && l.kind == "product" && l.weight_mg.is_some() {
                self.exec(
                    "INSERT INTO line_unmatched_weight VALUES (?,?)",
                    &[json!(l.id), json!(l.weight_mg.map(|w| w as f64 / 1000.0))],
                )?;
            }
            if l.kind != "item_discount" {
                self.exec(
                    "INSERT INTO line_category_assignment VALUES (?,?)",
                    &[json!(l.id), json!(l.category_id)],
                )?;
            }
            if let Some(printed) = l.printed_amount_minor {
                self.exec(
                    "INSERT INTO line_printed_amount VALUES (?,?)",
                    &[json!(l.id), json!(printed)],
                )?;
            }
            if l.is_weighed {
                self.exec("INSERT INTO line_weighed VALUES (?)", &[json!(l.id)])?;
            }
            let mut seen_warnings = std::collections::HashSet::new();
            for warning in l
                .warnings
                .iter()
                .filter(|w| actionable_warning(w) && seen_warnings.insert(w.as_str()))
            {
                let old = issues
                    .iter()
                    .find(|i| i["line_id"] == l.id && i["reason_code"] == *warning);
                self.exec(
                    "INSERT INTO review_issue VALUES (?,?,?,?,?,?,?,?,?)",
                    &[
                        old.map_or(json!(id()), |i| i["issue_id"].clone()),
                        json!(r.id),
                        json!(l.id),
                        json!("line"),
                        json!(warning),
                        Value::Null,
                        old.map_or(json!("open"), |i| i["state"].clone()),
                        old.map_or(json!(now()), |i| i["created_at_utc_ms"].clone()),
                        old.map_or(Value::Null, |i| i["resolved_at_utc_ms"].clone()),
                    ],
                )?;
            }
            for e in &l.evidence {
                self.one(
                    "SELECT image_id FROM receipt_image WHERE image_id=? AND receipt_id=?",
                    &[e["imageId"].clone(), json!(r.id)],
                )?;
                self.exec(
                    "INSERT INTO line_image_evidence VALUES (?,?,?,?,?,?,?)",
                    &[
                        json!(id()),
                        json!(l.id),
                        e["imageId"].clone(),
                        e["x0"].clone(),
                        e["y0"].clone(),
                        e["x1"].clone(),
                        e["y1"].clone(),
                    ],
                )?;
            }
        }
        for l in &r.lines {
            if l.kind == "item_discount" {
                self.exec(
                    "INSERT INTO line_discount VALUES (?,?)",
                    &[json!(l.id), json!(l.discount_target)],
                )?;
            }
        }
        // Complete all line changes before collecting names, including removed/renamed rows.
        self.reconcile_catalog()?;
        if name_changed {
            self.exec(
                "UPDATE receipt SET version=version+1,updated_at_utc_ms=? WHERE receipt_id<>?",
                &[json!(now()), json!(r.id)],
            )?;
        }
        // Receipt edits may create products or update the product catalog.
        self.exec(
            "UPDATE catalog_version SET version=version+1 WHERE id=1",
            &[],
        )?;
        self.validate()?;
        self.load(&r.id)
    }
    pub fn load(&self, id: &str) -> Result<Value> {
        let r = self.one("SELECT * FROM receipt WHERE receipt_id=?", &[json!(id)])?;
        let rows=self.rows("SELECT l.*,CAST(ROUND(COALESCE(p.weight_g,w.weight_g)*1000) AS INTEGER) AS weight_mg,ec.category_id,d.target_line_id FROM receipt_line l LEFT JOIN product p ON p.product_id=l.product_id LEFT JOIN line_unmatched_weight w ON w.line_id=l.line_id LEFT JOIN line_effective_category ec ON ec.line_id=l.line_id LEFT JOIN line_discount d ON d.discount_line_id=l.line_id WHERE l.receipt_id=? ORDER BY l.position",&[json!(id)])?;
        let mut lines = vec![];
        for l in rows {
            let metadata = self.line_sku(&l["line_id"])?;
            lines.push(json!({"id":l["line_id"],"kind":l["kind"],"rawName":l["raw_name"],"taxCode":metadata["tax_code"],"sku":metadata["sku"],"isWeighed":!self.rows("SELECT line_id FROM line_weighed WHERE line_id=?",&[l["line_id"].clone()])?.is_empty(),"categoryId":l["category_id"].as_str().unwrap_or(UNCATEGORIZED),"productId":l["product_id"],"productNameEdit":self.rows("SELECT name FROM line_product_name_candidate WHERE line_id=?", &[l["line_id"].clone()])?.first().map(|c|c["name"].clone()).unwrap_or(Value::Null),"discountTarget":l["target_line_id"],"quantityUnit":l["quantity_unit"],"weightMg":l["weight_mg"],"quantityMicros":l["quantity_micros"],"unitPriceScaled":l["unit_price_scaled"],"amountMinor":l["amount_minor"],"printedAmountMinor":self.rows("SELECT amount_minor FROM line_printed_amount WHERE line_id=?",&[l["line_id"].clone()])?.first().map(|v|v["amount_minor"].clone()).unwrap_or(Value::Null),"warnings":self.rows("SELECT reason_code FROM review_issue WHERE line_id=? AND state='open'",&[l["line_id"].clone()])?.iter().filter(|w| actionable_warning(w["reason_code"].as_str().unwrap_or(""))).map(|w|w["reason_code"].clone()).collect::<Vec<_>>(),"evidence":self.rows("SELECT image_id AS imageId,x0,y0,x1,y1 FROM line_image_evidence WHERE line_id=?",&[l["line_id"].clone()])?}));
        }
        crate::sku::inherit_discount_metadata(&mut lines);
        Ok(
            json!({"id":id,"store":r["raw_store"],"recognizedStore":self.rows("SELECT raw_name FROM receipt_ocr_store WHERE receipt_id=?",&[json!(id)])?.first().map(|row|row["raw_name"].clone()).unwrap_or(json!("")),"branch":r["raw_branch"],"address":r["raw_address"],"country":r["country_code"],"currency":r["currency_code"],"timeSource":r["time_source"],"rawTime":r["raw_time_text"],"totalSource":r["total_source"],"occurredAt":r["occurred_at_utc_ms"],"createdAt":r["created_at_utc_ms"],"revision":r["version"],"totalMinor":r["total_minor"],"posted":r["status"]=="posted","lines":lines}),
        )
    }
    pub fn receipt_action(&self, op: &str, v: &Value) -> Result<Value> {
        match op {
            "edit" => self.edit_receipt(v),
            "time_candidates" => crate::calendar::candidates(v),
            "display_line" | "prepare_line" => self.prepare_line(v, op == "prepare_line"),
            "create" | "save" | "confirm" => self.save(v["receipt"].clone(), op == "confirm"),
            "get" => self.load(text(v, "id")?),
            "list" => {
                let deleted = if v["trash"] == true {
                    "IS NOT NULL"
                } else {
                    "IS NULL"
                };
                let sort = v["sort_by"].as_str().unwrap_or("created_at");
                let direction = v["direction"].as_str().unwrap_or("desc");
                let column = match sort {
                    "store" => "raw_store",
                    "created_at" => "created_at_utc_ms",
                    "receipt_time" => "occurred_at_utc_ms",
                    "total" => "total_minor",
                    _ => return Err(invalid()),
                };
                let (order, cmp) = match direction {
                    "asc" => ("ASC", ">"),
                    "desc" => ("DESC", "<"),
                    _ => return Err(invalid()),
                };
                let limit = v["limit"].as_i64().unwrap_or(100).clamp(1, 200);
                let cursor = v
                    .get("cursor")
                    .filter(|c| !c.is_null())
                    .map(|c| {
                        serde_json::from_str::<Value>(c.as_str().ok_or_else(invalid)?)
                            .map_err(|_| invalid())
                    })
                    .transpose()?;
                let (value, id) = if let Some(c) = &cursor {
                    let fields = c.as_array().ok_or_else(invalid)?;
                    let (value, id) =
                        if fields.len() == 2 && sort == "created_at" && direction == "desc" {
                            (&fields[0], &fields[1])
                        } else if fields.len() == 4 && fields[0] == sort && fields[1] == direction {
                            (&fields[2], &fields[3])
                        } else {
                            return Err(invalid());
                        };
                    if !id.is_string()
                        || !(value.is_null()
                            || (sort == "store" && value.is_string())
                            || (sort != "store" && value.is_i64()))
                    {
                        return Err(invalid());
                    }
                    (value.clone(), id.clone())
                } else {
                    (Value::Null, Value::Null)
                };
                let key = format!("r.{column} COLLATE NOCASE");
                let rows = self.rows(&format!("SELECT r.*,rr.difference_minor,(SELECT status FROM recognition_job j WHERE j.receipt_id=r.receipt_id ORDER BY j.created_at_utc_ms DESC,j.rowid DESC LIMIT 1) AS recognition_status,(SELECT COUNT(*) FROM review_issue i WHERE i.receipt_id=r.receipt_id AND i.state='open' AND i.reason_code<>?1) AS issues FROM receipt r JOIN receipt_reconciliation rr ON rr.receipt_id=r.receipt_id WHERE r.deleted_at_utc_ms {deleted} AND (?6 IS NULL OR EXISTS (SELECT 1 FROM receipt_line fl LEFT JOIN line_product_name_candidate fc ON fc.line_id=fl.line_id LEFT JOIN product flp ON flp.product_id=fl.product_id LEFT JOIN printed_name fn ON fn.printed_name_id=COALESCE(flp.printed_name_id,(SELECT printed_name_id FROM printed_name WHERE raw_name=fl.raw_name)) LEFT JOIN printed_name_product_name fm ON fm.printed_name_id=fn.printed_name_id LEFT JOIN product_name fp ON fp.product_name_id=fm.product_name_id WHERE fl.receipt_id=r.receipt_id AND fl.kind='product' AND COALESCE(fc.name,fp.name)=(SELECT name FROM product_name WHERE product_name_id=?6))) AND (?2=0 OR (?3 IS NOT NULL AND (r.{column} IS NULL OR {key}{cmp}?3 OR ({key}=?3 AND r.receipt_id{cmp}?4))) OR (?3 IS NULL AND r.{column} IS NULL AND r.receipt_id{cmp}?4)) ORDER BY (r.{column} IS NULL) ASC,{key} {order},r.receipt_id {order} LIMIT ?5"), &[json!(LEGACY_CONFIDENCE_WARNING),json!(cursor.is_some()),value,id,json!(limit),v["product_name_id"].clone()])?;
                let next = if rows.len() == limit as usize {
                    rows.last().map(|r| {
                        if sort == "created_at" && direction == "desc" {
                            json!([r[column], r["receipt_id"]]).to_string()
                        } else {
                            json!([sort, direction, r[column], r["receipt_id"]]).to_string()
                        }
                    })
                } else {
                    None
                };
                Ok(json!({"items":rows,"next_cursor":next}))
            }
            "check_duplicates" => {
                let r = &v["receipt"];
                Ok(json!(self.rows("SELECT receipt_id,raw_store,occurred_at_utc_ms,total_minor FROM receipt WHERE receipt_id<>? AND deleted_at_utc_ms IS NULL AND currency_code=? AND raw_store=? AND total_minor=? AND ABS(occurred_at_utc_ms-?)<=300000",&[r["id"].clone(),r["currency"].clone(),r["store"].clone(),r["totalMinor"].clone(),r["occurredAt"].clone()])?))
            }
            "trash" | "restore" | "purge" => {
                let id = text(v, "id")?;
                self.check_version(id, number(v, "expected_version")?)?;
                if op == "purge" {
                    self.exec("DELETE FROM line_discount WHERE discount_line_id IN (SELECT line_id FROM receipt_line WHERE receipt_id=?)",&[json!(id)])?;
                    self.exec(
                        "DELETE FROM recognition_job WHERE receipt_id=?",
                        &[json!(id)],
                    )?;
                    self.exec("DELETE FROM receipt WHERE receipt_id=?", &[json!(id)])?;
                } else {
                    self.exec(
                        "UPDATE receipt SET deleted_at_utc_ms=? WHERE receipt_id=?",
                        &[
                            if op == "trash" {
                                json!(now())
                            } else {
                                Value::Null
                            },
                            json!(id),
                        ],
                    )?;
                    self.bump(id)?;
                }
                if op == "restore" {
                    self.restore_receipt_catalog(id)?;
                }
                self.reconcile_catalog()?;
                self.exec(
                    "UPDATE catalog_version SET version=version+1 WHERE id=1",
                    &[],
                )?;
                self.validate()?;
                Ok(Value::Null)
            }
            _ => Err(missing()),
        }
    }
}
