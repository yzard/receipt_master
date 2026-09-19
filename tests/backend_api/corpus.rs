//! Offline domain regression and opt-in image inference evaluation are deliberately separate.
use base64::Engine;
use chrono::{NaiveDateTime, TimeZone};
use receipt_backend_api::{
    db::{self, Store},
    jobs,
};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    fs,
    path::PathBuf,
    time::{Duration, Instant},
};
use unicode_normalization::UnicodeNormalization;

fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../tests/backend_api/corpus")
}
fn read(path: &str) -> Value {
    let mut data = serde_json::from_slice(&fs::read(root().join(path)).unwrap()).unwrap();
    // Translate archived model/client field spellings without rewriting historical captures.
    fn archived_names(value: &mut Value) {
        match value {
            Value::Object(map) => {
                for (old, new) in [
                    ("standard_name", "product_name"),
                    ("product_alias", "product_name"),
                    ("productAliasEdit", "productNameEdit"),
                    ("standardName", "productNameEdit"),
                    (
                        "standard_name_visible_fragments",
                        "product_name_visible_fragments",
                    ),
                ] {
                    if let Some(value) = map.remove(old) {
                        map.entry(new).or_insert(value);
                    }
                }
                for value in map.values_mut() {
                    archived_names(value);
                }
            }
            Value::Array(values) => {
                for value in values {
                    archived_names(value);
                }
            }
            _ => {}
        }
    }
    archived_names(&mut data);
    data
}
fn cases() -> Vec<Value> {
    read("index.json")["cases"].as_array().unwrap().clone()
}
fn merge(input: Value) -> Value {
    let dir = tempfile::tempdir().unwrap();
    Store::initialize(dir.path()).unwrap();
    let store = Store::open(dir.path()).unwrap();
    let receipt = json!({"id":db::id(),"currency":"USD","store":"","branch":"","address":"","country":"US","timeSource":"estimated_instant","occurredAt":0,"createdAt":0,"lines":[]});
    jobs::decode_receipt(
        &store,
        receipt,
        input,
        vec!["corpus-photo".into()],
        "America/New_York",
    )
    .unwrap()
}
// Only typography and the separate SKU column are ignored. Chinese characters, package
// sizes, product suffixes, and refund signs are not fuzzily corrected by the scorer.
fn name(value: &str) -> String {
    let sku = regex::Regex::new(r"^(?:E\s*)?\d+\s+(\p{L})").unwrap();
    sku.replace(value.trim(), "$1")
        .nfkc()
        .filter(|c| !c.is_whitespace())
        .flat_map(char::to_uppercase)
        .collect()
}
fn name_ok(actual: &str, expected: &Value) -> bool {
    let a = name(actual);
    let e = name(expected["name"].as_str().unwrap());
    if let Some(parts) = expected["visible_name_fragments"].as_array() {
        let parts: Vec<String> = parts.iter().map(|p| name(p.as_str().unwrap())).collect();
        a.starts_with(&parts[0]) && a.ends_with(parts.last().unwrap())
    } else {
        a == e
    }
}
fn differences(actual: &Value, expected: &Value) -> Vec<String> {
    let mut errors = Vec::new();
    if actual["totalMinor"] != expected["total_minor"] {
        errors.push(format!(
            "total: {} != {}",
            actual["totalMinor"], expected["total_minor"]
        ));
    }
    // Store names are evaluated by logo image matching, never text OCR.
    if expected["skip_time"] != true {
        let utc = if let Some(ms) = expected["occurred_at_utc_ms"].as_i64() {
            ms
        } else {
            let local = NaiveDateTime::parse_from_str(
                expected["local_time"].as_str().unwrap(),
                "%Y-%m-%d %H:%M:%S",
            )
            .unwrap();
            chrono_tz::America::New_York
                .from_local_datetime(&local)
                .single()
                .unwrap()
                .timestamp_millis()
        };
        if actual["occurredAt"] != utc || actual["timeSource"] != "recognized" {
            errors.push(format!(
                "time: {} != {utc} (UTC milliseconds)",
                actual["occurredAt"]
            ));
        }
    }
    if expected.get("currency").is_some() && actual["currency"] != expected["currency"] {
        errors.push(format!(
            "currency: {} != {}",
            actual["currency"], expected["currency"]
        ));
    }
    let lines = actual["lines"].as_array().unwrap();
    let wanted = expected["lines"].as_array().unwrap();
    if lines.len() != wanted.len() {
        errors.push(format!("line_count: {} != {}", lines.len(), wanted.len()));
    }
    let mut used = vec![false; lines.len()];
    let mut matches = vec![None; wanted.len()];
    for (i, e) in wanted.iter().enumerate() {
        let best = lines
            .iter()
            .enumerate()
            .filter(|(j, _)| !used[*j])
            .max_by_key(|(_, a)| {
                let metadata_matches = [
                    ("weightMg", "weight_mg"),
                    ("quantityMicros", "quantity_micros"),
                    ("unitPriceScaled", "unit_price_scaled"),
                    ("sku", "sku"),
                    ("taxCode", "tax_code"),
                    ("quantityUnit", "quantity_unit"),
                ]
                .iter()
                .all(|(src, dst)| e[*dst].is_null() || a[*src] == e[*dst]);
                32 * i32::from(
                    metadata_matches
                        && name_ok(a["rawName"].as_str().unwrap_or(""), e)
                        && a["kind"] == e["kind"]
                        && a["amountMinor"] == e["amount_minor"],
                ) + 8 * i32::from(name_ok(a["rawName"].as_str().unwrap_or(""), e))
                    + 4 * i32::from(a["kind"] == e["kind"])
                    + 2 * i32::from(a["amountMinor"] == e["amount_minor"])
                    + i32::from(a["printedAmountMinor"] == e["printed_amount_minor"])
            });
        let Some((j, a)) = best else {
            errors.push(format!("line[{i}]: missing {}", e["name"]));
            continue;
        };
        used[j] = true;
        matches[i] = Some(j);
        if !name_ok(a["rawName"].as_str().unwrap_or(""), e) {
            errors.push(format!("line[{i}].name: {} != {}", a["rawName"], e["name"]));
        }
        for (src, dst) in [
            ("kind", "kind"),
            ("amountMinor", "amount_minor"),
            ("weightMg", "weight_mg"),
            ("quantityMicros", "quantity_micros"),
            ("unitPriceScaled", "unit_price_scaled"),
            ("printedAmountMinor", "printed_amount_minor"),
        ] {
            if matches!(dst, "quantity_micros" | "unit_price_scaled") && e[dst].is_null() {
                continue; // Unit-price inference on an unweighed item is optional, not an OCR error.
            }
            if expected["skip_unknown_optional"] == true
                && e[dst].is_null()
                && dst != "amount_minor"
            {
                continue;
            }
            if a[src] != e[dst] {
                errors.push(format!("line[{i}].{dst}: {} != {}", a[src], e[dst]));
            }
        }
        for (src, dst) in [
            ("sku", "sku"),
            ("taxCode", "tax_code"),
            ("quantityUnit", "quantity_unit"),
        ] {
            if !e[dst].is_null() && a[src] != e[dst] {
                errors.push(format!("line[{i}].{dst}: {} != {}", a[src], e[dst]));
            }
        }
        if let Some(cn) = e["product_name"].as_str() {
            let constraint =
                json!({"name":cn,"visible_name_fragments":e["product_name_visible_fragments"]});
            if !name_ok(a["productNameEdit"].as_str().unwrap_or(""), &constraint) {
                errors.push(format!(
                    "line[{i}].chinese: {} != {cn}",
                    a["productNameEdit"]
                ));
            }
        }
    }
    for (i, e) in wanted.iter().enumerate() {
        if let Some(target) = e["discount_target_index"].as_u64()
            && let (Some(row), Some(parent)) = (matches[i], matches[target as usize])
            && lines[row]["discountTarget"] != lines[parent]["id"]
        {
            errors.push(format!("line[{i}].discount_target: wrong product"));
        }
    }
    errors
}
// Confirmed user data is the answer; user aliases/categories are not visual facts.
fn confirmed_gold(r: &Value) -> Value {
    let lines = r["lines"].as_array().unwrap();
    json!({"expected":{
        "store":r["store"],"currency":r["currency"],"total_minor":r["totalMinor"],
        "occurred_at_utc_ms":r["occurredAt"],
        "skip_time":!matches!(r["timeSource"].as_str(),Some("recognized"|"user_entered")),
        "skip_unknown_optional":true,
        "lines":lines.iter().map(|l|json!({
            "name":l["rawName"],"kind":l["kind"],"amount_minor":l["amountMinor"],
            "printed_amount_minor":l["printedAmountMinor"],"weight_mg":l["weightMg"],
            "quantity_micros":l["quantityMicros"],"unit_price_scaled":l["unitPriceScaled"],
            "sku":l["sku"],"tax_code":l["taxCode"],"quantity_unit":l["quantityUnit"],
            "discount_target_index":if l["discountTarget"].is_null(){None}else{lines.iter().position(|p|p["id"]==l["discountTarget"])}
        })).collect::<Vec<_>>()}})
}
fn decode_confirmed(input: Value, case: &Value) -> db::Result<Value> {
    let dir = tempfile::tempdir().unwrap();
    Store::initialize(dir.path())?;
    let store = Store::open(dir.path())?;
    let r = &case["expected"];
    // Do not seed any answer amounts, names, line associations or transaction times.
    let source = json!({"id":db::id(),"store":r["store"],"country":r["country"],"currency":r["currency"],"timeSource":"unresolved","occurredAt":0,"createdAt":0,"totalMinor":null,"branch":"","address":"","lines":[]});
    jobs::decode_receipt(
        &store,
        source,
        input,
        case["images"]
            .as_array()
            .unwrap()
            .iter()
            .map(|i| i["image_id"].as_str().unwrap().to_owned())
            .collect(),
        case["zone"].as_str().unwrap(),
    )
}
#[test]
fn confirmed_receipt_scoring_uses_saved_values_not_user_aliases_or_unknown_fields() {
    let gold = read("expected/5e4547ea.json");
    let dto = merge(gold["input"].clone());
    let confirmed = confirmed_gold(&dto);
    let mut prediction = dto.clone();
    prediction["lines"][0]["productNameEdit"] = json!("custom user alias");
    assert!(differences(&prediction, &confirmed["expected"]).is_empty());
    prediction["lines"][1]["amountMinor"] = json!(1);
    prediction["occurredAt"] = json!(0);
    assert_eq!(differences(&prediction, &confirmed["expected"]).len(), 2);
    let mut duplicate = dto.clone();
    duplicate["lines"] = json!([dto["lines"][0].clone(), dto["lines"][0].clone()]);
    duplicate["lines"][0]["sku"] = json!("111");
    duplicate["lines"][1]["sku"] = json!("222");
    let mut reordered = duplicate.clone();
    reordered["lines"].as_array_mut().unwrap().reverse();
    assert!(differences(&reordered, &confirmed_gold(&duplicate)["expected"]).is_empty());
    let mut with_sku = dto.clone();
    with_sku["lines"][0]["sku"] = json!("123");
    assert!(
        differences(&dto, &confirmed_gold(&with_sku)["expected"])
            .iter()
            .any(|e| e.contains("sku"))
    );
}

fn domain_case(id: &str) {
    let gold = read(&format!("expected/{id}.json"));
    let result = merge(gold["input"].clone());
    let errors = differences(&result, &gold["expected"]);
    assert!(errors.is_empty(), "{id}: {errors:#?}");
    assert_eq!(
        result["lines"]
            .as_array()
            .unwrap()
            .iter()
            .map(|l| l["amountMinor"].as_i64().unwrap())
            .sum::<i64>(),
        gold["expected"]["total_minor"].as_i64().unwrap()
    );
}
macro_rules! case {
    ($name:ident,$id:literal) => {
        #[test]
        fn $name() {
            domain_case($id);
        }
    };
}
case!(costco_prescanned_purchase_not_card_balance, "391b3273");
case!(skyfoods_cash_payment_and_change, "b38d62dd");
case!(skyfoods_two_bundles_not_two_pounds, "6fe7d01a");
case!(
    skyfoods_milk_soy_sauce_and_duplicate_discounted_tofu,
    "e1be8ec6"
);
case!(skyfoods_peanut_package_discount, "00710190");
case!(costco_two_ocean_mist_discounts_and_tax, "00c86447");
case!(costco_footer_august_date, "b92bd0ff");
case!(costco_pistachio_full_name, "f7cc0090");
case!(costco_pen_obscured_names_have_explicit_masks, "efe47023");
case!(costco_membership_refund_and_negative_tax, "bbbfe093");
case!(costco_product_refund, "e8698610");
case!(skyfoods_chinese_duplicate_tofu_and_discounts, "a730a1be");
case!(skyfoods_actual_weights_not_package_weight, "2f083787");
case!(hmart_fage_full_name_and_weight_annotation, "5e4547ea");
case!(hmart_evening_clock, "3270f3c9");
case!(costco_walnuts_and_steelhead, "2718947f");
case!(skyfoods_tips_is_product_name_not_tip, "f3bca374");

#[test]
fn corpus_photos_are_immutable_and_annotations_are_schema_valid() {
    let validator = jsonschema::validator_for(
        &serde_json::from_str(include_str!(
            "../../src/backend_api/src/receipt_schema.json"
        ))
        .unwrap(),
    )
    .unwrap();
    let cases = cases();
    assert_eq!(cases.len(), 17);
    for c in cases {
        let gold = read(c["expected"].as_str().unwrap());
        assert!(validator.is_valid(&gold["input"]), "{}", c["id"]);
        for image in c["images"].as_array().unwrap() {
            let bytes = fs::read(root().join(image["path"].as_str().unwrap())).unwrap();
            assert_eq!(
                format!("{:x}", Sha256::digest(&bytes)),
                image["sha256"].as_str().unwrap()
            );
            assert!(
                image::ImageReader::new(std::io::Cursor::new(&bytes))
                    .with_guessed_format()
                    .unwrap()
                    .into_dimensions()
                    .is_ok()
            );
        }
    }
}
#[test]
fn scorer_rejects_each_reported_error_even_when_total_is_correct() {
    for (id, field, replacement, expected_error) in [
        ("5e4547ea", "name", json!("FAGE"), "name"),
        (
            "a730a1be",
            "product_name",
            json!("廣廣鄉 鼓香朝天椒"),
            "chinese",
        ),
        ("e8698610", "amount", json!("16.99"), "amount_minor"),
        ("2f083787", "quantity", json!("1"), "weight_mg"),
        ("2f083787", "unit_price", json!("9.99"), "unit_price_scaled"),
        ("efe47023", "name", json!("PASTURE"), "name"),
    ] {
        let gold = read(&format!("expected/{id}.json"));
        let mut input = gold["input"].clone();
        input["lines"][0][field] = replacement;
        assert!(
            differences(&merge(input), &gold["expected"])
                .iter()
                .any(|e| e.contains(expected_error))
        );
    }
    assert_eq!(name("0000385338 / 1121864"), name("0000385338/1121864"));
    assert_eq!(name("545345 KS PISTACHIO"), name("KS PISTACHIO"));
    let gold = read("expected/3270f3c9.json");
    let mut input = gold["input"].clone();
    input["local_time"] = json!("2026-09-13 08:45:00");
    assert!(
        differences(&merge(input), &gold["expected"])
            .iter()
            .any(|e| e.starts_with("time:"))
    );
    for id in ["a730a1be", "f3bca374"] {
        let gold = read(&format!("expected/{id}.json"));
        let mut input = gold["input"].clone();
        if id == "a730a1be" {
            input["lines"].as_array_mut().unwrap().remove(4);
        } else {
            let mut tip = input["lines"][0].clone();
            tip["kind"] = json!("tip");
            tip["name"] = json!("TIPS");
            input["lines"].as_array_mut().unwrap().push(tip);
        }
        assert!(
            differences(&merge(input), &gold["expected"])
                .iter()
                .any(|e| e.starts_with("line_count:"))
        );
    }
}
#[test]
fn captured_failures_are_not_promoted_to_ground_truth() {
    // Historical outputs have an obsolete contract and must never be accepted as a new vision result.
    for id in ["f3bca374", "a730a1be"] {
        assert!(
            receipt_backend_api::pipeline::validate_receipt(
                &read(&format!("captured/{id}.json")),
                1
            )
            .is_err()
        );
    }
}

#[test]
fn confirmed_snapshot_covers_all_24_saved_receipts_with_intact_photos() {
    let snapshot = read("confirmed/2026-09-17/snapshot.json");
    let cases = snapshot["cases"].as_array().unwrap();
    assert_eq!(cases.len(), 24);
    let mut ids = std::collections::HashSet::new();
    for c in cases {
        assert!(ids.insert(c["id"].as_str().unwrap()));
        assert_eq!(c["expected"]["posted"], true);
        // Archived snapshots retain the old client-only flag; current DTOs omit it.
        let mut expected = c["expected"].clone();
        for line in expected["lines"].as_array_mut().unwrap() {
            line.as_object_mut().unwrap().remove("rememberAlias");
        }
        let r: receipt_backend_api::db::receipts::Receipt =
            serde_json::from_value(expected).unwrap();
        assert_eq!(r.id, c["id"].as_str().unwrap());
        for l in &r.lines {
            if let Some(target) = &l.discount_target {
                assert!(
                    r.lines
                        .iter()
                        .any(|p| &p.id == target && p.kind == "product")
                );
            }
        }
        assert!(!c["images"].as_array().unwrap().is_empty());
        for i in c["images"].as_array().unwrap() {
            let bytes = fs::read(
                root()
                    .join("confirmed/2026-09-17")
                    .join(i["path"].as_str().unwrap()),
            )
            .unwrap();
            assert_eq!(
                format!("{:x}", Sha256::digest(&bytes)),
                i["sha256"].as_str().unwrap()
            );
        }
    }
}

/// Opt-in integration benchmark: no receipt writes and no learned aliases. Fails on any
/// mismatch, but writes every case/result before failing. Normal builds remain GPU-independent.
#[tokio::test]
#[ignore = "requires a running local OCR service; see corpus/README.md"]
async fn live_image_benchmark() {
    let base = std::env::var("RECEIPT_BENCH_URL").expect("set RECEIPT_BENCH_URL");
    let parsed = reqwest::Url::parse(&base).unwrap();
    assert!(
        matches!(parsed.host_str(), Some("localhost" | "127.0.0.1" | "[::1]")),
        "Benchmark is restricted to localhost; do not send private originals to a new provider implicitly."
    );
    let key = fs::read_to_string(
        std::env::var("RECEIPT_BENCH_KEY_FILE").expect("set RECEIPT_BENCH_KEY_FILE"),
    )
    .unwrap();
    let output =
        PathBuf::from(std::env::var("RECEIPT_BENCH_OUTPUT").expect("set RECEIPT_BENCH_OUTPUT"));
    let client = reqwest::Client::builder()
        .no_proxy()
        .timeout(Duration::from_secs(600))
        .build()
        .unwrap();
    let models: Value = client
        .get(format!("{base}/v1/models"))
        .bearer_auth(key.trim())
        .send()
        .await
        .unwrap()
        .error_for_status()
        .unwrap()
        .json()
        .await
        .unwrap();
    let model = &models["data"][0]["id"];
    let schema: Value = serde_json::from_str(include_str!(
        "../../src/backend_api/src/receipt_schema.json"
    ))
    .unwrap();
    let snapshot_path = std::env::var("RECEIPT_BENCH_SNAPSHOT")
        .ok()
        .map(PathBuf::from);
    let snapshot = snapshot_path
        .as_ref()
        .map(|p| serde_json::from_slice::<Value>(&fs::read(p).unwrap()).unwrap());
    let image_root = snapshot_path
        .as_ref()
        .map(|p| p.parent().unwrap().to_path_buf())
        .unwrap_or_else(root);
    let selected = snapshot
        .as_ref()
        .map(|s| s["cases"].as_array().unwrap().clone())
        .unwrap_or_else(cases);
    let is_confirmed = snapshot.is_some();
    let mut reports = Vec::new();
    let slots = std::sync::Arc::new(tokio::sync::Semaphore::new(2));
    let mut tasks = tokio::task::JoinSet::new();
    for c in selected {
        let image_root = image_root.clone();
        let client = client.clone();
        let key = key.clone();
        let base = base.clone();
        let model = model.clone();
        let schema = schema.clone();
        let slots = slots.clone();
        tasks.spawn(async move {
        let _slot=slots.acquire().await.unwrap();

        let started = Instant::now();
        // Simulate an already confirmed logo alias; never pass merchandise answers.
        let annotation = if is_confirmed {confirmed_gold(&c["expected"])}else{read(c["expected"].as_str().unwrap())};
        let known_store = annotation["expected"]["store"].as_str().unwrap();
        let mut content = vec![
            json!({"type":"text","text":format!("Trusted application context: {}",json!({"known_store":known_store,"country":"US","currency":"USD"}))}),
        ];
        for image in c["images"].as_array().unwrap() {
            let bytes = fs::read(image_root.join(image["path"].as_str().unwrap())).unwrap();
            assert_eq!(format!("{:x}",Sha256::digest(&bytes)),image["sha256"].as_str().unwrap());
            content.push(json!({"type":"image_url","image_url":{"url":format!("data:{};base64,{}",image["mime"].as_str().unwrap_or("image/jpeg"),base64::engine::general_purpose::STANDARD.encode(bytes))}}));
        }
        let request = json!({"model":model,"receipt_context":{"known_store":known_store},"messages":[{"role":"user","content":content}],"response_format":{"type":"json_schema","json_schema":{"name":"receipt","strict":true,"schema":schema}}});
        let result = async {
            let response = client
                .post(format!("{base}/v1/chat/completions"))
                .bearer_auth(key.trim())
                .json(&request)
                .send()
                .await.map_err(|e| e.to_string())?;
            let status = response.status();
            let text = response.text().await.map_err(|e| e.to_string())?;
            if !status.is_success() {
                return Err(format!("HTTP {status}: {text}"));
            }
            serde_json::from_str::<Value>(&text).map_err(|e| e.to_string())
        }
        .await;
        let report = match result {
            Ok(response) => match response["choices"][0]["message"]["content"]
                .as_str()
                .and_then(|s| serde_json::from_str::<Value>(s).ok())
            {
                Some(prediction) => {
                    let gold = annotation;
                    let evaluated = std::panic::catch_unwind(|| if is_confirmed {decode_confirmed(prediction.clone(),&c).unwrap()}else{merge(prediction.clone())});
                    let errors = match evaluated {
                        Ok(dto) => differences(&dto, &gold["expected"]),
                        Err(_) => {
                            vec!["Prediction could not be normalized into a receipt".to_owned()]
                        }
                    };
                    json!({"id":c["id"],"prediction":prediction,"errors":errors,"parsing":response["receipt_parsing"],"ocr":response["ocr"],"usage":response["usage"]})
                }
                None => {
                    json!({"id":c["id"],"errors":["Invalid completion JSON"],"response":response})
                }
            },
            Err(error) => json!({"id":c["id"],"errors":[error.to_string()]}),
        };
        let mut report = report;
        report["duration_ms"] = json!(started.elapsed().as_millis());
        report["images"] = c["images"].clone();
        report
        });
    }
    while let Some(report) = tasks.join_next().await {
        let report = report.unwrap();
        eprintln!(
            "{}: {} mismatches",
            report["id"],
            report["errors"].as_array().unwrap().len()
        );
        reports.push(report);
        fs::create_dir_all(output.parent().unwrap()).unwrap();
        fs::write(&output,serde_json::to_vec_pretty(&json!({"model":model,"evaluated_at":chrono::Utc::now().to_rfc3339(),"scope":if is_confirmed {"All posted receipt snapshot; saved raw names, amounts, relationships and known numeric metadata; user aliases/categories excluded"}else{"Qwen3-VL image to JSON + validation; no text reconstruction"},"snapshot":snapshot_path,"cases":reports})).unwrap()).unwrap();
    }
    let failed = reports
        .iter()
        .filter(|r| !r["errors"].as_array().unwrap().is_empty())
        .count();
    assert_eq!(
        failed,
        0,
        "{failed}/{} receipts differ from manual annotations; report: {}",
        reports.len(),
        output.display()
    );
}

/// Re-score archived model responses without spending GPU time or changing the predictions.
#[test]
#[ignore = "requires a saved prediction report; see corpus/README.md"]
fn saved_predictions_benchmark() {
    let path =
        PathBuf::from(std::env::var("RECEIPT_BENCH_OUTPUT").expect("set RECEIPT_BENCH_OUTPUT"));
    let mut report: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
    let mut failed = 0;
    let snapshot = std::env::var("RECEIPT_BENCH_SNAPSHOT")
        .ok()
        .map(|p| serde_json::from_slice::<Value>(&fs::read(p).unwrap()).unwrap());
    let is_confirmed = snapshot.is_some();
    let selected = snapshot
        .as_ref()
        .map(|s| s["cases"].as_array().unwrap().clone())
        .unwrap_or_else(cases);
    let rows = report["cases"].as_array_mut().unwrap();
    assert_eq!(rows.len(), selected.len(), "Incomplete benchmark report");
    for c in selected {
        let row = rows
            .iter_mut()
            .find(|r| r["id"] == c["id"])
            .expect("Missing receipt");
        assert_eq!(
            row["images"], c["images"],
            "Prediction belongs to different source images"
        );
        if row["prediction"].is_object() {
            let gold = if is_confirmed {
                confirmed_gold(&c["expected"])
            } else {
                read(c["expected"].as_str().unwrap())
            };
            let actual = if is_confirmed {
                decode_confirmed(row["prediction"].clone(), &c)
            } else {
                Ok(merge(row["prediction"].clone()))
            };
            row["errors"] = match actual {
                Ok(dto) => json!(differences(&dto, &gold["expected"])),
                Err(_) => json!(["Prediction could not be normalized into a receipt"]),
            };
        }
        if !row["errors"].as_array().unwrap().is_empty() {
            failed += 1;
        }
    }
    report["scored_at"] = json!(chrono::Utc::now().to_rfc3339());
    fs::write(&path, serde_json::to_vec_pretty(&report).unwrap()).unwrap();
    assert_eq!(
        failed,
        0,
        "{failed} receipts differ from manual annotations; report: {}",
        path.display()
    );
}

/// Offline ablation: each engine uses the same parser and corrected gold, without
/// changing the production requirement that every request runs both OCR models.
fn score_prediction(prediction: Value, case: &Value) -> Value {
    let mut result = json!({"id":case["id"],"images":case["images"],"prediction":prediction});
    let valid = receipt_backend_api::pipeline::validate_receipt(
        &prediction,
        case["images"].as_array().unwrap().len(),
    )
    .is_ok()
        && prediction["lines"]
            .as_array()
            .is_some_and(|lines| !lines.is_empty());
    match valid.then(|| decode_confirmed(prediction, case)) {
        Some(Ok(dto)) => {
            result["normalized"] = dto.clone();
            result["errors"] = json!(differences(
                &dto,
                &confirmed_gold(&case["expected"])["expected"]
            ));
            result["valid"] = json!(true);
        }
        _ => {
            result["errors"] = json!(["Prediction could not be normalized into a receipt"]);
            result["valid"] = json!(false);
        }
    }
    result
}

/// Compare a candidate and cached OCR using identical current parsing/normalization and gold.
#[test]
#[ignore = "requires an immutable snapshot and complete local predictions"]
fn candidate_comparison_benchmark() {
    let snapshot: Value = serde_json::from_slice(
        &fs::read(std::env::var("RECEIPT_BENCH_SNAPSHOT").unwrap()).unwrap(),
    )
    .unwrap();
    let source: Value =
        serde_json::from_slice(&fs::read(std::env::var("RECEIPT_BENCH_SOURCE").unwrap()).unwrap())
            .unwrap();
    let mode = std::env::var("RECEIPT_BENCH_ENGINE").unwrap();
    assert_eq!(mode, "candidate");
    let cases = snapshot["cases"].as_array().unwrap();
    assert_eq!(cases.len(), source["cases"].as_array().unwrap().len());
    let mut results = Vec::new();
    for case in cases {
        let row = source["cases"]
            .as_array()
            .unwrap()
            .iter()
            .find(|r| r["id"] == case["id"])
            .unwrap();
        assert_eq!(row["images"], case["images"]);
        let prediction = row["prediction"].clone();
        let mut result = score_prediction(prediction, case);
        result["duration_ms"] = row["duration_ms"].clone();
        result["failure"] = row["failure"].clone();
        results.push(result);
    }
    fs::write(
        std::env::var("RECEIPT_BENCH_OUTPUT").unwrap(),
        serde_json::to_vec_pretty(&json!({"engine":mode,"cases":results})).unwrap(),
    )
    .unwrap();
}
