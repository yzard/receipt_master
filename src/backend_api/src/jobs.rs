use crate::{
    State,
    db::{self, Result, Store, conflict, id, invalid, missing, now, number, text},
    pipeline,
};
use base64::Engine;
use chrono::{LocalResult, TimeZone};
use serde_json::{Value, json};
use std::{
    str::FromStr,
    sync::{Arc, atomic::Ordering},
};
impl Store {
    /// Persist a matched image alias before item inference, using the job snapshot
    /// to reject stale photos and protect edits made while recognition was running.
    pub fn persist_recognition_store(&self, job_id: &str, name: &str) -> Result<()> {
        if name.trim().is_empty() {
            return Ok(());
        }
        let jobs = self.rows(
            "SELECT * FROM recognition_job WHERE job_id=?",
            &[json!(job_id)],
        )?;
        let Some(job) = jobs.first().filter(|j| j["status"] == "running") else {
            return Ok(());
        };
        let receipts = self.rows(
            "SELECT deleted_at_utc_ms FROM receipt WHERE receipt_id=?",
            &[job["receipt_id"].clone()],
        )?;
        if receipts
            .first()
            .is_none_or(|r| !r["deleted_at_utc_ms"].is_null())
        {
            return Ok(());
        }
        let mut current = self.load(text(job, "receipt_id")?)?;
        if !current["store"].as_str().unwrap_or("").trim().is_empty()
            || self
                .merge_recognition_edits(job, &current, &current)?
                .is_none()
        {
            return Ok(());
        }
        current["store"] = json!(name);
        self.save(current, false)?;
        Ok(())
    }

    pub fn finish_recognition(&self, job_id: &str, result: Result<Value>) -> Result<()> {
        let rows = self.rows(
            "SELECT * FROM recognition_job WHERE job_id=?",
            &[json!(job_id)],
        )?;
        let Some(job) = rows.first().filter(|j| j["status"] == "running") else {
            return Ok(());
        };
        match result {
            Ok(candidate) => {
                let mut status = "succeeded";
                let mut error: Option<&str> = None;
                let current = self.load(text(job, "receipt_id")?)?;
                let same_version = current["revision"] == job["receipt_version"];
                let merged = if same_version {
                    Some(candidate.clone())
                } else {
                    self.merge_recognition_edits(job, &current, &candidate)?
                };
                if current["posted"] != true {
                    if let Some(merged) = merged {
                        self.save(merged, false)?;
                        status = "applied";
                    } else {
                        error = Some("stale_input");
                    }
                } else if !same_version {
                    error = Some("stale_input");
                }
                self.exec("UPDATE recognition_job SET status=?,result_json=?,error_code=?,finished_at_utc_ms=? WHERE job_id=?",&[json!(status),json!(json!({"receipt":candidate}).to_string()),json!(error),json!(now()),json!(job_id)])?;
            }
            Err(error) => {
                self.exec("UPDATE recognition_job SET status='failed',error_code=?,finished_at_utc_ms=? WHERE job_id=?",&[json!(error.code),json!(now()),json!(job_id)])?;
            }
        }
        Ok(())
    }
    // Three-way merge against the draft captured when the job was submitted.
    // Header edits are independent of OCR; edits to lines, currency or photos are not.
    fn merge_recognition_edits(
        &self,
        job: &Value,
        current: &Value,
        candidate: &Value,
    ) -> Result<Option<Value>> {
        let settings: Value =
            serde_json::from_str(text(job, "result_json")?).map_err(db::io_error)?;
        let base = &settings["source"];
        if !base.is_object()
            || current["posted"] == true
            || ["lines", "country", "currency"]
                .iter()
                .any(|key| current[key] != base[key])
        {
            return Ok(None);
        }
        let images = self.rows("SELECT (SELECT revision_id FROM image_revision r WHERE r.image_id=i.image_id ORDER BY created_at_utc_ms DESC,rowid DESC LIMIT 1) AS revision_id FROM receipt_image i WHERE receipt_id=? AND deleted_at_utc_ms IS NULL ORDER BY position", &[job["receipt_id"].clone()])?;
        let captured = self.rows(
            "SELECT revision_id FROM job_image WHERE job_id=? ORDER BY position",
            &[job["job_id"].clone()],
        )?;
        if images != captured {
            return Ok(None);
        }
        let mut merged = candidate.clone();
        for group in [
            &["store"][..],
            &["branch"][..],
            &["address"][..],
            &["timeSource", "rawTime", "occurredAt"][..],
            &["totalSource", "totalMinor"][..],
        ] {
            if group.iter().any(|key| current[key] != base[key]) {
                for key in group {
                    merged[key] = current[key].clone();
                }
            }
        }
        merged["revision"] = current["revision"].clone();
        merged["createdAt"] = current["createdAt"].clone();
        Ok(Some(merged))
    }
    pub fn recognition_action(&self, op: &str, v: &Value) -> Result<Value> {
        match op {
            "start" => {
                let receipt = text(v, "receipt_id")?;
                let version = number(v, "expected_version")?;
                let row = self.check_version(receipt, version)?;
                if !row["deleted_at_utc_ms"].is_null() {
                    return Err(conflict());
                }
                let zone = text(v, "zone")?;
                chrono_tz::Tz::from_str(zone).map_err(|_| invalid())?;
                let images=self.rows("SELECT i.image_id,(SELECT revision_id FROM image_revision r WHERE r.image_id=i.image_id ORDER BY created_at_utc_ms DESC,rowid DESC LIMIT 1) AS revision_id FROM receipt_image i WHERE receipt_id=? AND deleted_at_utc_ms IS NULL ORDER BY position",&[json!(receipt)])?;
                if images.is_empty() {
                    return Err(invalid());
                }
                let existing = self.rows("SELECT job_id,status FROM recognition_job WHERE receipt_id=? AND receipt_version=? AND status IN ('queued','running') ORDER BY created_at_utc_ms LIMIT 1", &[json!(receipt),json!(version)])?;
                if let Some(job) = existing.first() {
                    return Ok(job.clone());
                }
                // Reopening and enqueueing share the API transaction; failed submissions
                // never remove a confirmed receipt from reports.
                let version = if row["status"] == "posted" {
                    self.exec("UPDATE receipt SET status='draft',version=version+1,input_revision=input_revision+1,updated_at_utc_ms=? WHERE receipt_id=?", &[json!(now()), json!(receipt)])?;
                    self.reconcile_catalog()?;
                    self.exec(
                        "UPDATE catalog_version SET version=version+1 WHERE id=1",
                        &[],
                    )?;
                    version + 1
                } else {
                    version
                };
                let job = id();
                self.exec("INSERT INTO recognition_job(job_id,receipt_id,receipt_version,status,created_at_utc_ms,result_json) VALUES (?,?,?,'queued',?,?)",&[json!(job),json!(receipt),json!(version),json!(now()),json!(json!({"zone":zone,"pricing":v["pricing"],"source":self.load(receipt)?}).to_string())])?;
                for (i, img) in images.iter().enumerate() {
                    self.exec(
                        "INSERT INTO job_image VALUES (?,?,?)",
                        &[json!(job), json!(i), img["revision_id"].clone()],
                    )?;
                }
                Ok(json!({"job_id":job,"status":"queued"}))
            }
            "get" => {
                let mut job = self.one(
                    "SELECT * FROM recognition_job WHERE job_id=?",
                    &[v["id"].clone()],
                )?;
                if let Some(s) = job["result_json"].as_str() {
                    job["result"] = serde_json::from_str(s).map_err(db::io_error)?;
                }
                Ok(job)
            }
            "list" => Ok(json!(self.rows(
                "SELECT * FROM recognition_job WHERE receipt_id=? ORDER BY created_at_utc_ms DESC",
                &[v["receipt_id"].clone()]
            )?)),
            "runs" => Ok(json!(self.rows(
                "SELECT * FROM recognition_run ORDER BY started_at_utc_ms DESC",
                &[]
            )?)),
            "cancel" => {
                self.exec("UPDATE recognition_job SET status='cancelled',finished_at_utc_ms=? WHERE job_id=? AND status IN ('queued','running')",&[json!(now()),v["id"].clone()])?;
                Ok(Value::Null)
            }
            "apply" => {
                let job = self.one(
                    "SELECT * FROM recognition_job WHERE job_id=?",
                    &[v["id"].clone()],
                )?;
                if job["status"] == "applied" {
                    return self.load(text(&job, "receipt_id")?);
                }
                if job["status"] != "succeeded" {
                    return Err(conflict());
                }
                let receipt = text(&job, "receipt_id")?;
                self.check_version(receipt, number(&job, "receipt_version")?)?;
                let candidate: Value =
                    serde_json::from_str(text(&job, "result_json")?).map_err(db::io_error)?;
                let current = self.load(receipt)?;
                let saved = if current["posted"] == true {
                    candidate["receipt"].clone()
                } else {
                    self.save(candidate["receipt"].clone(), false)?
                };
                if current["posted"] != true {
                    self.exec(
                        "UPDATE recognition_job SET status='applied' WHERE job_id=?",
                        &[v["id"].clone()],
                    )?;
                }
                Ok(saved)
            }
            _ => Err(missing()),
        }
    }
}
struct WorkerSlot(Arc<State>);
impl Drop for WorkerSlot {
    fn drop(&mut self) {
        self.0.active_job_workers.fetch_sub(1, Ordering::SeqCst);
    }
}
pub fn wake(state: Arc<State>) {
    for _ in 0..state.config.job_workers {
        if state
            .active_job_workers
            .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |active| {
                (active < state.config.job_workers).then_some(active + 1)
            })
            .is_err()
        {
            break;
        }
        let slot = WorkerSlot(state.clone());
        tokio::spawn(async move {
            loop {
                match next_job(slot.0.clone()).await {
                    Ok(true) => {}
                    Ok(false) => break,
                    Err(error) => {
                        tracing::error!(code = error.code, "job worker failed");
                        break;
                    }
                }
            }
        });
    }
}
async fn database<T: Send + 'static>(
    state: &State,
    f: impl FnOnce(&Store) -> Result<T> + Send + 'static,
) -> Result<T> {
    let _guard = state.storage_lock.lock().await;
    let root = state.config.data_dir.clone();
    tokio::task::spawn_blocking(move || f(&Store::open(&root)?))
        .await
        .map_err(db::io_error)?
}
async fn next_job(state: Arc<State>) -> Result<bool> {
    let queued = database(&state, |s| {
        Ok(!s
            .rows(
                "SELECT job_id FROM recognition_job WHERE status='queued' LIMIT 1",
                &[],
            )?
            .is_empty())
    })
    .await?;
    if !queued {
        return Ok(false);
    }
    for url in [&state.config.ocr.url] {
        if !state
            .client
            .get(format!("{url}/health"))
            .timeout(std::time::Duration::from_secs(2))
            .send()
            .await
            .is_ok_and(|r| r.status().is_success())
        {
            return Ok(false);
        }
    }
    let job=database(&state,|s|s.transaction(||{let jobs=s.rows("SELECT * FROM recognition_job WHERE status='queued' ORDER BY created_at_utc_ms LIMIT 1",&[])?;if let Some(job)=jobs.first(){s.exec("UPDATE recognition_job SET status='running' WHERE job_id=?",&[job["job_id"].clone()])?;}Ok(jobs.into_iter().next())})).await?;
    let Some(job) = job else { return Ok(false) };
    let job_id = text(&job, "job_id")?.to_owned();
    let result = process(state.clone(), job.clone()).await;
    let job_id2 = job_id.clone();
    let completed = database(&state, move |s| {
        s.transaction(|| s.finish_recognition(&job_id2, result))
    })
    .await;
    if let Err(error) = completed {
        database(&state,move|s|{s.exec("UPDATE recognition_job SET status='failed',error_code=?,finished_at_utc_ms=? WHERE job_id=? AND status='running'",&[json!(error.code),json!(now()),json!(job_id)])?;Ok(())}).await?;
    }
    Ok(true)
}
async fn process(state: Arc<State>, job: Value) -> Result<Value> {
    let receipt = text(&job, "receipt_id")?.to_owned();
    let job_id = text(&job, "job_id")?.to_owned();
    let job_id2 = job_id.clone();
    let (current,images)=database(&state,move|s|Ok((s.load(&receipt)?,s.rows("SELECT b.*,r.image_id FROM job_image j JOIN image_revision r ON r.revision_id=j.revision_id JOIN media_blob b ON b.blob_id=r.blob_id WHERE j.job_id=? ORDER BY j.position",&[json!(job_id2)])?))).await?;
    let settings: Value = serde_json::from_str(text(&job, "result_json")?).map_err(db::io_error)?;
    let mut source = settings.get("source").cloned().unwrap_or(current);
    let mut image_ids = Vec::new();
    let mut content = Vec::new();
    let mut ocr_pages = Vec::new();
    let mut ocr_usage = Vec::new();
    for (index, img) in images.iter().enumerate() {
        let path = db::media::safe_path(&state.config.data_dir, text(img, "relative_path")?)?;
        let bytes = tokio::fs::read(path).await.map_err(db::io_error)?;
        let image = format!(
            "data:{};base64,{}",
            text(img, "mime")?,
            base64::engine::general_purpose::STANDARD.encode(&bytes)
        );
        let raw = pipeline::read_ocr(&state, std::slice::from_ref(&image)).await?;
        ocr_pages.push(raw["pages"][0].clone());
        ocr_usage.push(raw["usage"].clone());
        if index == 0 && state.config.logos.enabled {
            let result = async {
                let layout = raw["pages"][0]["unlimited"]
                    .as_str()
                    .ok_or_else(invalid)?
                    .to_owned();
                crate::logos::capture(state.clone(), img.clone(), bytes, layout).await
            }
            .await;
            if let Err(error) = result {
                tracing::warn!(
                    code = error.code,
                    "logo extraction unavailable; retaining confirmed store"
                );
            }
            if source["store"].as_str().unwrap_or("").trim().is_empty() {
                let matched = crate::logos::match_receipt(
                    state.clone(),
                    text(&job, "receipt_id")?.to_owned(),
                )
                .await?;
                source["store"] = json!(matched["selected"].as_str().unwrap_or(""));
                let name = source["store"].as_str().unwrap_or("").to_owned();
                let jid = job_id.clone();
                database(&state, move |s| {
                    s.transaction(|| {
                        if s.one("SELECT version FROM catalog_version WHERE id=1", &[])?["version"]
                            != matched["catalog_version"]
                        {
                            return Err(db::conflict());
                        }
                        s.persist_recognition_store(&jid, &name)
                    })
                })
                .await?;
            }
        }
        content.push(json!({"type":"image_url","image_url":{"url":image}}));
        image_ids.push(text(img, "image_id")?.to_owned());
    }
    let check = job_id.clone();
    if !database(&state, move |s| {
        Ok(s.one(
            "SELECT status FROM recognition_job WHERE job_id=?",
            &[json!(check)],
        )?["status"]
            == "running")
    })
    .await?
    {
        return Err(conflict());
    }
    content.insert(0,json!({"type":"text","text":format!("Trusted application context (not printed evidence): {}",json!({"known_store":source["store"],"country":source["country"],"currency":source["currency"]}))}));
    let run = id();
    let run_copy = run.clone();
    let receipt = job["receipt_id"].clone();
    let version = job["receipt_version"].clone();
    let model = state.config.served_model.clone();
    database(&state,move|s|{s.exec("INSERT INTO recognition_run(run_id,receipt_id,input_revision,provider,model,status,started_at_utc_ms) VALUES (?,?,?,'local',?,'running',?)",&[json!(run_copy),receipt,version,json!(model),json!(now())])?;Ok(())}).await?;
    let schema: Value =
        serde_json::from_str(include_str!("receipt_schema.json")).map_err(db::io_error)?;
    let response=pipeline::recognize_with_ocr(state.clone(),json!({"model":state.config.served_model,"receipt_context":{"known_store":source["store"]},"messages":[{"role":"user","content":content}],"response_format":{"type":"json_schema","json_schema":{"name":"receipt","strict":true,"schema":schema}}}),Some(json!({"pages":ocr_pages,"usage":pipeline::aggregate_usage(&ocr_usage)}))).await;
    let result = match response {
        Ok(response) => {
            let result: Value = serde_json::from_str(
                response["choices"][0]["message"]["content"]
                    .as_str()
                    .ok_or_else(invalid)?,
            )
            .map_err(db::io_error)?;
            let settings: Value =
                serde_json::from_str(text(&job, "result_json")?).map_err(db::io_error)?;
            let price = &settings["pricing"];
            let cost = match (
                price["input_rate_micros"].as_i64(),
                price["output_rate_micros"].as_i64(),
                response["usage"]["prompt_tokens"].as_i64(),
                response["usage"]["completion_tokens"].as_i64(),
            ) {
                (Some(a), Some(b), Some(c), Some(d)) if c >= 0 && d >= 0 => Some(
                    i64::try_from(
                        (i128::from(a) * i128::from(c)
                            + i128::from(b) * i128::from(d)
                            + 9_999_999_999)
                            / 10_000_000_000,
                    )
                    .map_err(|_| invalid())?,
                ),
                _ => None,
            };
            let path = format!("recognition/{run}.json");
            let bytes = response.to_string().into_bytes();
            database(&state,move|s|{if s.rows("SELECT run_id FROM recognition_run WHERE run_id=?", &[json!(run)])?.is_empty() {return Err(missing());} db::media::atomic_file(&s.root.join(&path),&bytes)?;s.exec("UPDATE recognition_run SET status='succeeded',result_relative_path=?,finished_at_utc_ms=?,estimated_cost_minor=?,cost_currency_code=? WHERE run_id=?",&[json!(path),json!(now()),json!(cost),if cost.is_some(){json!("USD")}else{Value::Null},json!(run)])?;Ok(())}).await?;
            result
        }
        Err(e) => {
            database(&state,move|s|{s.exec("UPDATE recognition_run SET status='failed',error_code='inference_failed',finished_at_utc_ms=? WHERE run_id=?",&[json!(now()),json!(run)])?;Ok(())}).await?;
            return Err(e);
        }
    };
    let zone = text(&settings, "zone")?.to_owned();
    database(&state, move |s| {
        decode_receipt(s, source, result, image_ids, &zone)
    })
    .await
}
pub fn fixed(value: &Value, digits: u32) -> Result<Value> {
    let Some(text) = value.as_str() else {
        return Ok(Value::Null);
    };
    let text = text.trim();
    if text.is_empty() {
        return Ok(Value::Null);
    }
    let negative = text.starts_with('-');
    let unsigned = text.strip_prefix('-').unwrap_or(text);
    let parts = unsigned.split('.').collect::<Vec<_>>();
    if parts.len() > 2
        || parts[0].is_empty()
        || !parts.iter().all(|p| p.bytes().all(|c| c.is_ascii_digit()))
    {
        return Err(invalid());
    }
    let frac = parts.get(1).unwrap_or(&"").trim_end_matches('0');
    if frac.len() > digits as usize {
        return Err(invalid());
    }
    let whole = parts[0].parse::<i128>().map_err(|_| invalid())?;
    let scale = 10i128.pow(digits);
    let decimal = format!("{frac:0<width$}", width = digits as usize)
        .parse::<i128>()
        .unwrap_or(0);
    let n = whole
        .checked_mul(scale)
        .and_then(|v| v.checked_add(decimal))
        .ok_or_else(invalid)?;
    Ok(json!(
        i64::try_from(if negative { -n } else { n }).map_err(|_| invalid())?
    ))
}
/// Parse printed local time without guessing a timezone or dropping printed seconds.
pub fn parse_receipt_time(raw: &str) -> Option<chrono::NaiveDateTime> {
    let normalized = raw
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .to_uppercase();
    for format in [
        "%Y-%m-%d %H:%M:%S%.f",
        "%Y-%m-%d %H:%M",
        "%Y-%m-%dT%H:%M:%S%.f",
        "%Y-%m-%dT%H:%M",
        "%Y-%m-%d %I:%M:%S %p",
        "%Y-%m-%d %I:%M %p",
        "%m/%d/%Y %H:%M:%S",
        "%m/%d/%Y %H:%M",
        "%m/%d/%Y %I:%M:%S %p",
        "%m/%d/%Y %I:%M %p",
        "%m/%d/%y %H:%M:%S",
        "%m/%d/%y %H:%M",
        "%m/%d/%y %I:%M:%S %p",
        "%m/%d/%y %I:%M %p",
    ] {
        if format.starts_with("%m/") {
            let year = normalized.split_whitespace().next()?.split('/').nth(2)?;
            if (format.contains("%Y") && year.len() != 4)
                || (format.contains("%y") && year.len() != 2)
            {
                continue;
            }
        }
        if let Ok(time) = chrono::NaiveDateTime::parse_from_str(&normalized, format) {
            return Some(time);
        }
    }
    None
}

pub fn decode_receipt(
    store: &Store,
    mut r: Value,
    data: Value,
    image_ids: Vec<String>,
    zone: &str,
) -> Result<Value> {
    let tz = chrono_tz::Tz::from_str(zone).map_err(|_| invalid())?;
    r["recognizedStore"] = json!("");
    let mut all;
    pipeline::validate_receipt(&data, image_ids.len())?;
    {
        for (src, dst) in [
            ("branch", "branch"),
            ("address", "address"),
            ("country", "country"),
            ("currency", "currency"),
        ] {
            if let Some(value) = data[src].as_str().filter(|s| !s.trim().is_empty()) {
                r[dst] = json!(value);
            }
        }
        let digits = number(
            &store.one(
                "SELECT minor_digits FROM currency WHERE code=?",
                &[r["currency"].clone()],
            )?,
            "minor_digits",
        )? as u32;

        if !data["total"].is_null() {
            r["totalMinor"] = fixed(&data["total"], digits)?;
            r["totalSource"] = json!("recognized");
        }
        if let Some(raw) = data["local_time"].as_str() {
            r["rawTime"] = json!(raw);
            let clock = if raw.len() == 10 {
                format!(
                    "{} {}",
                    raw,
                    chrono::Utc::now().with_timezone(&tz).format("%H:%M")
                )
            } else {
                raw.into()
            };
            match parse_receipt_time(&clock).map(|n| tz.from_local_datetime(&n)) {
                Some(LocalResult::Single(t)) => {
                    r["occurredAt"] = json!(t.timestamp_millis());
                    r["timeSource"] = json!(if raw.len() == 10 {
                        "estimated_clock"
                    } else {
                        "recognized"
                    });
                }
                _ => r["timeSource"] = json!("estimated_instant"),
            }
        }
        let converted = crate::receipt_lines::amounts(&data, digits)?;
        let mut lines = vec![];
        for (index, m) in data["lines"]
            .as_array()
            .ok_or_else(invalid)?
            .iter()
            .enumerate()
        {
            let mut warnings = m["review_notes"].as_array().cloned().unwrap_or_default();
            let (amount, printed) = converted[index].clone();
            if amount.is_null() {
                warnings.push(json!("缺少金额"));
            }
            let kind = text(m, "kind")?;
            let category = match kind {
                "tax" => 2,
                "tip" => 3,
                "deposit" => 4,
                "order_discount" => 5,
                _ => 1,
            };
            let mut quantity = fixed(&m["quantity"], 6)?;
            if !quantity.is_null() && m["quantity_unit"].as_str().is_none_or(|s| s.is_empty()) {
                quantity = Value::Null;
                warnings.push(json!("数量单位缺失，请补充"));
            }
            let evidence=m["evidence"].as_array().unwrap().iter().map(|e|{
                let b=&e["box"];json!({"imageId":image_ids[e["image_index"].as_u64().unwrap() as usize],"x0":b[0],"y0":b[1],"x1":b[2],"y1":b[3]})
            }).collect::<Vec<_>>();
            lines.push(json!({"id":id(),"kind":kind,"rawName":m["name"],"sku":m["sku"],"taxCode":m["tax_code"],"isWeighed":m["is_weighed"],"productNameEdit":m["product_name"],"categoryId":format!("00000000-0000-4000-8000-{category:012}"),"productId":null,"discountTarget":null,"quantityUnit":m["quantity_unit"],"weightMg":crate::weights::recognized(m)?,"quantityMicros":quantity,"unitPriceScaled":fixed(&m["unit_price"],digits+6)?,"amountMinor":amount,"printedAmountMinor":printed,"warnings":warnings,"evidence":evidence}));
        }
        for i in 0..lines.len() {
            if let Some(target) = data["lines"][i]["discount_target_index"].as_u64() {
                lines[i]["discountTarget"] = lines[target as usize]["id"].clone();
            }
        }
        all = lines;
    }
    for line in &mut all {
        if r["timeSource"]
            .as_str()
            .unwrap_or("")
            .starts_with("estimated")
        {
            line["warnings"]
                .as_array_mut()
                .unwrap()
                .push(json!("消费时间含估计值，请确认"));
        }
        if line["kind"] == "product" {
            let name = line["rawName"].as_str().unwrap_or("");
            // Previously saved product names take precedence over OCR-proposed bilingual names.
            if let Some(existing) = store.rows(
                "SELECT a.name,a.category_id FROM product_name a JOIN printed_name_product_name m USING(product_name_id) JOIN printed_name n USING(printed_name_id) WHERE n.raw_name=?",
                &[json!(db::normalized(name))],
            )?.first() {
                line["productNameEdit"] = existing["name"].clone();
            }
            let name = line["rawName"].as_str().unwrap_or("");
            if let Some(product) = store.rows(
                "SELECT a.category_id FROM printed_name n JOIN printed_name_product_name m USING(printed_name_id) JOIN product_name a USING(product_name_id) WHERE n.raw_name=?",
                &[json!(db::normalized(name))],
            )?.first() {
                line["categoryId"] = product["category_id"].clone();
            }
        }
    }
    crate::sku::inherit_discount_metadata(&mut all);
    r["lines"] = json!(all);
    Ok(r)
}
