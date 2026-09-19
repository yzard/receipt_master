use receipt_backend_api::{
    db::{self, Store},
    jobs,
};
use serde_json::{Value, json};
fn setup() -> (tempfile::TempDir, Store) {
    let dir = tempfile::tempdir().unwrap();
    Store::initialize(dir.path()).unwrap();
    let s = Store::open(dir.path()).unwrap();
    (dir, s)
}
fn receipt() -> Value {
    json!({"id":db::id(),"store":"Grocery","branch":"Main","address":"Main Street","country":"US","currency":"USD","timeSource":"user_entered","rawTime":"","totalSource":"user_entered","occurredAt":1780000000000i64,"createdAt":1,"revision":0,"totalMinor":950,"posted":false,"lines":[{"id":db::id(),"kind":"product","rawName":"RICE","categoryId":db::UNCATEGORIZED,"productId":null,"discountTarget":null,"quantityUnit":"ea","weightMg":500000,"quantityMicros":1000000,"unitPriceScaled":1000000000,"amountMinor":1000,"warnings":[],"evidence":[]},{"id":db::id(),"kind":"order_discount","rawName":"Coupon","categoryId":"00000000-0000-4000-8000-000000000005","productId":null,"discountTarget":null,"quantityUnit":null,"weightMg":null,"quantityMicros":null,"unitPriceScaled":null,"amountMinor":-50,"warnings":[],"evidence":[]}]})
}
fn save(s: &Store, r: Value) -> Value {
    s.transaction(|| s.save(r, true)).unwrap()
}
fn photo() -> Vec<u8> {
    let mut bytes = std::io::Cursor::new(Vec::new());
    image::DynamicImage::new_rgb8(16, 24)
        .write_to(&mut bytes, image::ImageFormat::Png)
        .unwrap();
    bytes.into_inner()
}
#[test]
fn receipts_persist_and_stale_edits_are_rejected() {
    let (dir, s) = setup();
    let r = save(&s, receipt());
    assert_eq!(r["revision"], 1);
    assert!(r["createdAt"].as_i64().unwrap() > 1);
    let mut changed = r.clone();
    changed["store"] = json!("New store");
    save(&s, changed);
    let error = s.transaction(|| s.save(r.clone(), true)).unwrap_err();
    assert_eq!(error.status.as_u16(), 409);
    drop(s);
    let s = Store::open(dir.path()).unwrap();
    assert_eq!(
        s.load(r["id"].as_str().unwrap()).unwrap()["store"],
        "New store"
    );
}
#[test]
fn invalid_relationship_rolls_back_entire_receipt() {
    let (_dir, s) = setup();
    let mut r = receipt();
    r["lines"][0]["categoryId"] = json!("missing");
    assert!(s.transaction(|| s.save(r, true)).is_err());
    assert!(s.rows("SELECT * FROM receipt", &[]).unwrap().is_empty());
    assert!(s.rows("SELECT * FROM product", &[]).unwrap().is_empty());
}
#[test]
fn names_weights_and_currency_reports() {
    let (_dir, s) = setup();
    let first = save(&s, receipt());
    let mut second = receipt();
    second["lines"][0]["weightMg"] = Value::Null;
    save(&s, second);
    assert_eq!(s.rows("SELECT * FROM product", &[]).unwrap().len(), 2);
    assert!(
        s.rows(
            "SELECT name FROM sqlite_master WHERE name='store_alias'",
            &[]
        )
        .unwrap()
        .is_empty()
    );
    let report = s
        .report_action(
            "summary",
            &json!({"start":0,"end":1900000000000i64,"currency":"USD"}),
        )
        .unwrap();
    assert_eq!(report["net"], 1900);
    assert_eq!(report["entries"].as_array().unwrap().len(), 4);
    let empty = s
        .report_action(
            "summary",
            &json!({"start":0,"end":1900000000000i64,"currency":"JPY"}),
        )
        .unwrap();
    assert_eq!(empty["net"], 0);
    assert!(first["lines"][1]["unitPriceScaled"].as_i64().unwrap() < 0);
}
#[test]
fn categories_reject_cycles_and_preserve_system_nodes() {
    let (_dir, s) = setup();
    let parent = db::id();
    let child = db::id();
    s.exec(
        "INSERT INTO category VALUES (?,NULL,'Parent',NULL)",
        &[json!(parent)],
    )
    .unwrap();
    s.exec(
        "INSERT INTO category VALUES (?,?,'Child',NULL)",
        &[json!(child), json!(parent)],
    )
    .unwrap();
    assert!(
        s.transaction(|| s.catalog_action(
            "categories",
            "save",
            &json!({"id":parent,"name":"Parent","parent":child,"expected_version":0})
        ))
        .is_err()
    );
    assert!(
        s.transaction(|| s.catalog_action(
            "categories",
            "delete",
            &json!({"id":db::UNCATEGORIZED,"target":parent,"expected_version":0})
        ))
        .is_err()
    );
}
#[test]
fn upload_rotation_preserves_original_and_updates_hash() {
    let (dir, s) = setup();
    let r = save(&s, receipt());
    let bytes = photo();
    let uploaded = s
        .transaction(|| {
            s.upload(
                &json!({"receipt_id":r["id"],"expected_version":1,"captured_at_utc_ms":1}),
                &bytes,
            )
        })
        .unwrap();
    let image = uploaded["image_id"].clone();
    s.transaction(|| {
        s.image_action(
            "rotate",
            &json!({"receipt_id":r["id"],"id":image,"expected_version":2}),
        )
    })
    .unwrap();
    let images = s.images(r["id"].as_str().unwrap(), false).unwrap();
    let i = &images[0];
    assert_eq!(i["width_px"], 24);
    assert_ne!(i["current_blob_id"], i["original_blob_id"]);
    let orig = s
        .one(
            "SELECT * FROM media_blob WHERE blob_id=?",
            &[i["original_blob_id"].clone()],
        )
        .unwrap();
    assert_eq!(
        std::fs::read(dir.path().join(orig["relative_path"].as_str().unwrap())).unwrap(),
        bytes
    );
    let current = s
        .one(
            "SELECT * FROM media_blob WHERE blob_id=?",
            &[i["current_blob_id"].clone()],
        )
        .unwrap();
    assert_eq!(
        db::media::hash(
            &std::fs::read(dir.path().join(current["relative_path"].as_str().unwrap())).unwrap()
        ),
        current["content_sha256"].as_str().unwrap()
    );
}
#[test]
fn backup_restore_keeps_database_and_original_photos() {
    let (_dir, s) = setup();
    let mut input = receipt();
    input["lines"][0]["printedAmountMinor"] = json!(950);
    let r = save(&s, input);
    s.transaction(|| {
        s.upload(
            &json!({"receipt_id":r["id"],"expected_version":1}),
            &photo(),
        )
    })
    .unwrap();
    let backup = s.export_action("create_backup", &json!({})).unwrap();
    let prepared = s
        .restore_action(
            "prepare_restore",
            &json!({"bytes_base64":backup["data"]["bytes_base64"]}),
        )
        .unwrap();
    let token = prepared["data"]["token"].as_str().unwrap();
    let restored = Store::open(&s.root.join("staging").join(token)).unwrap();
    assert_eq!(
        restored.load(r["id"].as_str().unwrap()).unwrap()["lines"][0]["printedAmountMinor"],
        950
    );
    assert_eq!(
        restored.load(r["id"].as_str().unwrap()).unwrap()["totalMinor"],
        950
    );
    assert_eq!(
        restored
            .rows("SELECT * FROM receipt_image", &[])
            .unwrap()
            .len(),
        1
    );
}
#[test]
fn restart_preserves_queued_jobs_and_requeues_interrupted_work() {
    let (dir, s) = setup();
    let r = save(&s, receipt());
    s.transaction(|| {
        s.upload(
            &json!({"receipt_id":r["id"],"expected_version":1}),
            &photo(),
        )
    })
    .unwrap();
    let job = s
        .transaction(|| {
            s.recognition_action(
                "start",
                &json!({"receipt_id":r["id"],"expected_version":2,"zone":"America/New_York"}),
            )
        })
        .unwrap();
    drop(s);
    Store::initialize(dir.path()).unwrap();
    let s = Store::open(dir.path()).unwrap();
    let job = s
        .recognition_action("get", &json!({"id":job["job_id"]}))
        .unwrap();
    assert_eq!(job["status"], "queued");
    s.exec(
        "UPDATE recognition_job SET status='running' WHERE job_id=?",
        &[job["job_id"].clone()],
    )
    .unwrap();
    drop(s);
    Store::initialize(dir.path()).unwrap();
    let s = Store::open(dir.path()).unwrap();
    assert_eq!(
        s.recognition_action("get", &json!({"id":job["job_id"]}))
            .unwrap()["status"],
        "queued"
    );
}
#[test]
fn fixed_decimal_never_uses_binary_float() {
    assert_eq!(jobs::fixed(&json!("19.99"), 2).unwrap(), 1999);
    assert_eq!(jobs::fixed(&json!("-0.10"), 2).unwrap(), -10);
    assert!(jobs::fixed(&json!("1.001"), 2).is_err());
    assert!(jobs::fixed(&json!("9223372036854775808"), 0).is_err());
}
#[test]
fn path_traversal_is_rejected() {
    for path in ["../secret", "/etc/passwd", "media/../../secret", "a\\b"] {
        assert!(db::media::safe_path(std::path::Path::new("/data"), path).is_err());
    }
}

#[test]
fn entire_restore_replaces_data_and_reopens_cleanly() {
    let (dir, s) = setup();
    let r = save(&s, receipt());
    let b = s.export_action("create_backup", &json!({})).unwrap();
    let prepared = s
        .restore_action(
            "prepare_restore",
            &json!({"bytes_base64":b["data"]["bytes_base64"]}),
        )
        .unwrap();
    save(&s, receipt());
    s.restore_action(
        "commit_restore",
        &json!({"token":prepared["data"]["token"],"confirm":true}),
    )
    .unwrap();
    drop(s);
    Store::initialize(dir.path()).unwrap();
    let s = Store::open(dir.path()).unwrap();
    assert_eq!(s.rows("SELECT * FROM receipt", &[]).unwrap().len(), 1);
    assert_eq!(
        s.load(r["id"].as_str().unwrap()).unwrap()["totalMinor"],
        950
    );
}

#[test]
fn printed_seconds_and_us_am_pm_survive_utc_conversion() {
    use chrono::TimeZone;
    let (_dir, s) = setup();
    for (raw, hour, second) in [
        ("2026-09-15 19:27:36", 19, 36),
        ("2026-09-15T19:27:36", 19, 36),
        ("09/15/2026 7:27:36 PM", 19, 36),
        ("09/15/26 12:27 AM", 0, 0),
        ("2026-09-15 12:27 PM", 12, 0),
    ] {
        let r = decode_fixture(
            &s,
            receipt(),
            vec![json!({"local_time":raw,"lines":[]})],
            vec![db::id()],
            "America/New_York",
        )
        .unwrap();
        let expected = chrono_tz::America::New_York
            .with_ymd_and_hms(2026, 9, 15, hour, 27, second)
            .unwrap()
            .timestamp_millis();
        assert_eq!(r["occurredAt"], expected, "{raw}");
        assert_eq!(r["timeSource"], "recognized");
        assert_eq!(r["rawTime"], raw);
    }
    assert!(jobs::parse_receipt_time("2026-02-30 19:27:36").is_none());
    assert!(jobs::parse_receipt_time("not a date").is_none());
}

#[test]
fn permanent_delete_drafts_and_posted_receipts_with_active_jobs() {
    let (_dir, s) = setup();
    let builtin_media = s
        .rows("SELECT * FROM media_blob ORDER BY blob_id", &[])
        .unwrap();
    for posted in [false, true] {
        let r = s.transaction(|| s.save(receipt(), posted)).unwrap();
        let id = r["id"].as_str().unwrap();
        s.transaction(|| s.upload(&json!({"receipt_id":id,"expected_version":1}), &photo()))
            .unwrap();
        let job = s
            .transaction(|| {
                s.recognition_action(
                    "start",
                    &json!({"receipt_id":id,"expected_version":2,"zone":"America/New_York"}),
                )
            })
            .unwrap();
        s.exec(
            "UPDATE recognition_job SET status='running' WHERE job_id=?",
            &[job["job_id"].clone()],
        )
        .unwrap();
        // A stale client must still fail without removing the receipt.
        assert!(
            s.transaction(|| s.receipt_action("purge", &json!({"id":id,"expected_version":1})))
                .is_err()
        );
        assert!(s.load(id).is_ok());
        s.transaction(|| {
            s.receipt_action(
                "purge",
                &json!({"id":id,"expected_version":if posted {3}else{2}}),
            )
        })
        .unwrap();
        s.cleanup_media().unwrap();
        assert!(s.load(id).is_err());
        for table in [
            "receipt",
            "receipt_line",
            "receipt_image",
            "image_revision",
            "recognition_job",
            "job_image",
        ] {
            assert!(
                s.rows(&format!("SELECT * FROM {table}"), &[])
                    .unwrap()
                    .is_empty(),
                "{table}"
            );
        }
        assert_eq!(
            s.rows("SELECT * FROM media_blob ORDER BY blob_id", &[])
                .unwrap(),
            builtin_media
        );
        assert!(s.rows("PRAGMA foreign_key_check", &[]).unwrap().is_empty());
    }
}

#[test]
fn recognized_mass_is_converted_and_persisted_as_grams() {
    let (_dir, s) = setup();
    let mut line =
        json!({"kind":"product","package_weight":null,"quantity":"1.86","quantity_unit":"lbs"});
    assert_eq!(
        receipt_backend_api::weights::recognized(&line).unwrap(),
        843682
    );
    line["package_weight"] = json!("843.6818082");
    line["package_weight_unit"] = json!("g");
    assert_eq!(
        receipt_backend_api::weights::recognized(&line).unwrap(),
        843682
    );
    line["package_weight"] = Value::Null;
    line["quantity_unit"] = json!("fl oz");
    assert!(
        receipt_backend_api::weights::recognized(&line)
            .unwrap()
            .is_null()
    );
    let mut r = receipt();
    r["lines"][0]["weightMg"] = Value::Null;
    r["lines"][0]["quantityMicros"] = json!(1860000);
    r["lines"][0]["quantityUnit"] = json!("lb");
    let saved = save(&s, r);
    assert_eq!(saved["lines"][0]["weightMg"], 843682);
    assert_eq!(
        s.one("SELECT weight_g FROM product", &[]).unwrap()["weight_g"],
        json!(843.682)
    );
    let version = s
        .one("SELECT version FROM catalog_version WHERE id=1", &[])
        .unwrap()["version"]
        .clone();
    s.transaction(|| {
        s.catalog_action(
            "config",
            "save_weight_unit",
            &json!({"weight_unit":"lb","expected_version":version}),
        )
    })
    .unwrap();
    assert_eq!(
        s.one("SELECT weight_unit FROM app_preferences WHERE id=1", &[])
            .unwrap()["weight_unit"],
        "lb"
    );
    assert_eq!(
        s.load(saved["id"].as_str().unwrap()).unwrap()["lines"][0]["weightMg"],
        843682
    );
}

#[test]
fn backend_owns_weight_display_and_edit_roundtrip() {
    let (_dir, s) = setup();
    let mut line = receipt()["lines"][0].clone();
    line["weightMg"] = json!(843682);
    line["quantityMicros"] = json!(1860000);
    line["quantityUnit"] = json!("lb");
    let rendered = s
        .prepare_line(&json!({"line":line,"currency":"USD"}), false)
        .unwrap();
    assert_eq!(rendered["display"]["weightText"], "0.84");
    assert_eq!(rendered["display"]["quantityUnit"], "kg");
    assert_eq!(rendered["display"]["quantityText"], "0.84");
    let mut price_fields = rendered["display"].clone();
    price_fields["priceText"] = json!("2.50");
    let repriced = s
        .prepare_line(
            &json!({"line":rendered,"currency":"USD","fields":price_fields}),
            true,
        )
        .unwrap();
    assert_eq!(repriced["quantityMicros"], 1860000);
    assert_eq!(repriced["weightMg"], 843682);
    assert_eq!(repriced["quantityUnit"], "lb");
    let untouched = s
        .prepare_line(
            &json!({"line":rendered,"currency":"USD","fields":rendered["display"]}),
            true,
        )
        .unwrap();
    assert_eq!(untouched["weightMg"], 843682);
    assert_eq!(untouched["quantityMicros"], 1860000);
    assert_eq!(untouched["quantityUnit"], "lb");
    let mut fields = rendered["display"].clone();
    fields["weightText"] = json!("1.25");
    let changed = s
        .prepare_line(
            &json!({"line":rendered,"currency":"USD","fields":fields}),
            true,
        )
        .unwrap();
    assert_eq!(changed["weightMg"], 1250000);
    fields["weightUnit"] = json!("lb");
    assert!(
        s.prepare_line(
            &json!({"line":rendered,"currency":"USD","fields":fields}),
            true
        )
        .is_err()
    );
}

#[test]
fn server_calendar_handles_dst_and_device_timezone() {
    use chrono::TimeZone;
    for (month, day, hours) in [(3, 8, 23), (11, 1, 25)] {
        let anchor = chrono::Utc
            .with_ymd_and_hms(2026, month, day, 17, 0, 0)
            .unwrap()
            .timestamp_millis();
        let r = receipt_backend_api::calendar::range(
            &json!({"anchor":anchor,"zone":"America/New_York","period":"day","period_offset":0}),
        )
        .unwrap();
        assert_eq!(
            (r["end"].as_i64().unwrap() - r["start"].as_i64().unwrap()) / 3600000,
            hours
        );
    }
    let gaps = receipt_backend_api::calendar::candidates(
        &json!({"text":"2026-03-08 02:30","zone":"America/New_York"}),
    )
    .unwrap();
    assert!(gaps.as_array().unwrap().is_empty());
    let folds = receipt_backend_api::calendar::candidates(
        &json!({"text":"2026-11-01 01:30","zone":"America/New_York"}),
    )
    .unwrap();
    assert_eq!(folds.as_array().unwrap().len(), 2);
    let anchor = chrono::Utc
        .with_ymd_and_hms(2026, 9, 1, 1, 0, 0)
        .unwrap()
        .timestamp_millis();
    for (zone, expected) in [
        ("America/New_York", "2026-08-01"),
        ("Asia/Tokyo", "2026-09-01"),
    ] {
        let r = receipt_backend_api::calendar::range(
            &json!({"anchor":anchor,"zone":zone,"period":"month","period_offset":0}),
        )
        .unwrap();
        assert!(r["label"].as_str().unwrap().starts_with(expected));
    }
}
#[test]
fn server_edits_preserve_sums_and_reject_lossy_currency_changes() {
    let (_dir, s) = setup();
    let mut r = receipt();
    r["lines"].as_array_mut().unwrap().pop();
    r["totalMinor"] = json!(1000);
    let selected = json!([r["lines"][0]["id"]]);
    let split = s
        .edit_receipt(
            &json!({"receipt":r,"action":"split","selected":selected,"amount_text":"3.25"}),
        )
        .unwrap();
    assert_eq!(split["lines"][0]["amountMinor"], 325);
    assert_eq!(split["lines"][1]["amountMinor"], 675);
    assert_eq!(split["summary"]["knownTotal"], 1000);
    let ids = split["lines"]
        .as_array()
        .unwrap()
        .iter()
        .map(|l| l["id"].clone())
        .collect::<Vec<_>>();
    let merged = s
        .edit_receipt(&json!({"receipt":split,"action":"merge","selected":ids}))
        .unwrap();
    assert_eq!(merged["lines"].as_array().unwrap().len(), 1);
    assert_eq!(merged["lines"][0]["amountMinor"], 1000);
    let yen = s
        .edit_receipt(&json!({"receipt":merged,"action":"currency","currency":"JPY"}))
        .unwrap();
    assert_eq!(yen["totalMinor"], 10);
    assert_eq!(yen["lines"][0]["amountMinor"], 10);
    r["totalMinor"] = json!(1001);
    assert!(
        s.edit_receipt(&json!({"receipt":r,"action":"currency","currency":"JPY"}))
            .is_err()
    );
}

#[test]
fn server_budget_is_a_notice_and_yaml_prices_are_snapshotted() {
    let (_dir, s) = setup();
    let r = save(&s, receipt());
    let mut config = receipt_backend_api::config::Config::parse(include_str!(
        "../../playground/backend_api/config.yaml"
    ))
    .unwrap();
    config.pricing.input_usd_per_million_tokens = Some("1.25".into());
    config.pricing.output_usd_per_million_tokens = Some("5".into());
    assert_eq!(
        config.pricing.snapshot().unwrap()["input_rate_micros"],
        1250000
    );
    config.budget.monthly_usd = Some("1.00".into());
    assert!(config.budget.notice(&s).unwrap().is_none());
    s.exec("INSERT INTO recognition_run(run_id,receipt_id,input_revision,provider,model,status,started_at_utc_ms,estimated_cost_minor,cost_currency_code) VALUES (?,?,1,'local','test','succeeded',?,80,'USD')",&[json!(db::id()),r["id"].clone(),json!(db::now())]).unwrap();
    assert!(config.budget.notice(&s).unwrap().is_some());
    s.transaction(|| {
        s.upload(
            &json!({"receipt_id":r["id"],"expected_version":1}),
            &photo(),
        )
    })
    .unwrap();
    let job=s.transaction(||s.recognition_action("start",&json!({"receipt_id":r["id"],"expected_version":2,"zone":"America/New_York","pricing":config.pricing.snapshot().unwrap()}))).unwrap();
    assert_eq!(job["status"], "queued");
}

#[test]
fn unavailable_confidence_is_not_an_item_warning() {
    let (_dir, s) = setup();
    let source = save(&s, receipt());
    let line = |amount: Value| json!({"name":"APPLE","product_name":null,"kind":"product","package_weight":null,"quantity":"1","quantity_unit":null,"unit_price":null,"amount":amount,"confidence":null,"discount_target_index":null,"box":[0,0,0,0]});
    let mut good = line(json!("1.00"));
    good["quantity_unit"] = json!("ea");
    let r = decode_fixture(
        &s,
        source,
        vec![json!({"lines":[good,line(Value::Null)]})],
        vec!["image1".into()],
        "America/New_York",
    )
    .unwrap();
    assert_eq!(r["lines"][0]["warnings"], json!([]));
    assert_eq!(
        r["lines"][1]["warnings"],
        json!(["缺少金额", "数量单位缺失，请补充"])
    );
}

#[test]
fn legacy_confidence_warning_is_filtered_without_losing_real_issues() {
    let (_dir, s) = setup();
    let mut r = receipt();
    r["lines"][0]["warnings"] = json!(["识别置信度低或未知", "缺少金额"]);
    let r = save(&s, r);
    assert_eq!(r["lines"][0]["warnings"], json!(["缺少金额"]));
    let before = s.receipt_action("list", &json!({})).unwrap();
    // Simulate a receipt persisted by the previous backend or restored from an old backup.
    s.exec(
        "INSERT INTO review_issue VALUES (?,?,?,?,?,?,?,?,?)",
        &[
            json!(db::id()),
            r["id"].clone(),
            r["lines"][0]["id"].clone(),
            json!("line"),
            json!("识别置信度低或未知"),
            Value::Null,
            json!("open"),
            json!(db::now()),
            Value::Null,
        ],
    )
    .unwrap();
    assert_eq!(s.receipt_action("list", &json!({})).unwrap(), before);
    let loaded = s.load(r["id"].as_str().unwrap()).unwrap();
    assert_eq!(loaded["lines"][0]["warnings"], json!(["缺少金额"]));
    let saved = save(&s, loaded);
    assert_eq!(saved["lines"][0]["warnings"], json!(["缺少金额"]));
    assert_eq!(
        s.rows(
            "SELECT issue_id FROM review_issue WHERE reason_code=?",
            &[json!("识别置信度低或未知")]
        )
        .unwrap()
        .len(),
        0
    );
}

#[test]
fn weight_presentation_rounds_only_kg_and_pounds_to_two_places() {
    use receipt_backend_api::weights::{label, quantity_text};
    assert_eq!(label(843682, "kg"), "0.84 kg");
    assert_eq!(label(1000000, "kg"), "1.00 kg");
    assert_eq!(label(453592, "lb"), "1.00 lb");
    assert_eq!(quantity_text(1995000, "lbs"), "2.00");
    assert_eq!(quantity_text(-1995000, "lb"), "-2.00");
    assert_eq!(quantity_text(0, "kg"), "0.00");
    assert_eq!(label(123456, "g"), "123.456 g");
    assert_eq!(quantity_text(1234567, "ea"), "1.234567");
    let (_dir, s) = setup();
    let mut r = receipt();
    r["lines"][0]["weightMg"] = json!(843682);
    r["lines"][0]["quantityMicros"] = json!(1860000);
    r["lines"][0]["quantityUnit"] = json!("lb");
    save(&s, r);
    let report = s
        .report_action(
            "summary",
            &json!({"currency":"USD","start":1770000000000i64,"end":1790000000000i64}),
        )
        .unwrap();
    let mass_group = report["groups"]
        .as_array()
        .unwrap()
        .iter()
        .find(|g| g["quantities"]["kg"].is_number())
        .unwrap();
    assert_eq!(mass_group["quantity_labels"], json!(["0.84 kg"]));
    assert_eq!(mass_group["quantities"]["kg"], 843682);
}

#[test]
fn receipt_list_uses_creation_time_descending_with_stable_pagination() {
    let (_dir, s) = setup();
    let mut ids = Vec::new();
    for n in 1..=3 {
        let mut r = receipt();
        r["id"] = json!(format!("00000000-0000-4000-9000-{n:012}"));
        r["occurredAt"] = json!(1780000000000i64 - n * 1000);
        let r = save(&s, r);
        let time = if n == 1 { 100 } else { 200 };
        s.exec(
            "UPDATE receipt SET created_at_utc_ms=? WHERE receipt_id=?",
            &[json!(time), r["id"].clone()],
        )
        .unwrap();
        ids.push(r["id"].clone());
    }
    let first = s.receipt_action("list", &json!({"limit":1})).unwrap();
    assert_eq!(first["items"][0]["receipt_id"], ids[2]);
    // Editing a receipt's transaction date does not move its recording time.
    let mut oldest = s.load(ids[0].as_str().unwrap()).unwrap();
    oldest["occurredAt"] = json!(1880000000000i64);
    save(&s, oldest);
    let second = s
        .receipt_action("list", &json!({"limit":1,"cursor":first["next_cursor"]}))
        .unwrap();
    assert_eq!(second["items"][0]["receipt_id"], ids[1]);
    // A cursor is independent of whether its corresponding row still exists.
    let current = s.load(ids[1].as_str().unwrap()).unwrap();
    s.transaction(|| {
        s.receipt_action(
            "purge",
            &json!({"id":ids[1],"expected_version":current["revision"]}),
        )
    })
    .unwrap();
    let third = s
        .receipt_action("list", &json!({"limit":1,"cursor":second["next_cursor"]}))
        .unwrap();
    assert_eq!(third["items"][0]["receipt_id"], ids[0]);
    let end = s
        .receipt_action("list", &json!({"limit":1,"cursor":third["next_cursor"]}))
        .unwrap();
    assert!(end["items"].as_array().unwrap().is_empty());
    assert!(end["next_cursor"].is_null());
    assert!(
        s.receipt_action("list", &json!({"cursor":"bad cursor"}))
            .is_err()
    );
}

#[test]
fn weighed_amount_check_rounds_to_cents_and_clears_stale_warnings() {
    let (_dir, s) = setup();
    let mut r = receipt();
    r["lines"].as_array_mut().unwrap().truncate(1);
    let l = &mut r["lines"][0];
    l["rawName"] = json!("ENVY APPLE");
    l["isWeighed"] = json!(true);
    l["quantityMicros"] = json!(2810000);
    l["quantityUnit"] = json!("lb");
    l["unitPriceScaled"] = json!(299000000);
    l["amountMinor"] = json!(840);
    let mut saved = save(&s, r);
    assert_eq!(saved["lines"][0]["rawName"], "ENVY APPLE");
    assert_eq!(saved["lines"][0]["isWeighed"], true);
    assert_eq!(saved["lines"][0]["warnings"], json!([]));
    saved["lines"][0]["amountMinor"] = json!(850);
    saved = save(&s, saved);
    let warning = saved["lines"][0]["warnings"][0].as_str().unwrap();
    assert!(
        warning.contains("计算 USD 8.40")
            && warning.contains("票面 USD 8.50")
            && warning.contains("差额 USD +0.10"),
        "{warning}"
    );
    saved["lines"][0]["amountMinor"] = json!(840);
    saved = save(&s, saved);
    assert_eq!(saved["lines"][0]["warnings"], json!([]));
    saved["lines"][0]["unitPriceScaled"] = Value::Null;
    saved = save(&s, saved);
    assert!(
        saved["lines"][0]["warnings"][0]
            .as_str()
            .unwrap()
            .starts_with("称重信息缺失：")
    );
    assert_eq!(saved["lines"][0]["isWeighed"], true);
}

#[test]
fn queued_jobs_are_deduplicated_and_completion_never_overwrites_edits_or_deletions() {
    let (_dir, s) = setup();
    let r = s.transaction(|| s.save(receipt(), false)).unwrap();
    s.transaction(|| {
        s.upload(
            &json!({"receipt_id":r["id"],"expected_version":1}),
            &photo(),
        )
    })
    .unwrap();
    let input = json!({"receipt_id":r["id"],"expected_version":2,"zone":"America/New_York"});
    let job = s
        .transaction(|| s.recognition_action("start", &input))
        .unwrap();
    let again = s
        .transaction(|| s.recognition_action("start", &input))
        .unwrap();
    assert_eq!(job["job_id"], again["job_id"]);
    let candidate = s.load(r["id"].as_str().unwrap()).unwrap();
    s.exec(
        "UPDATE recognition_job SET status='running' WHERE job_id=?",
        &[job["job_id"].clone()],
    )
    .unwrap();
    let mut edited = candidate.clone();
    edited["store"] = json!("User edited while OCR was running");
    save(&s, edited);
    s.transaction(|| s.finish_recognition(job["job_id"].as_str().unwrap(), Ok(candidate.clone())))
        .unwrap();
    assert_eq!(
        s.load(r["id"].as_str().unwrap()).unwrap()["store"],
        "User edited while OCR was running"
    );
    let result = s
        .recognition_action("get", &json!({"id":job["job_id"]}))
        .unwrap();
    assert_eq!(result["error_code"], "stale_input");
    let r = s.load(r["id"].as_str().unwrap()).unwrap();
    s.transaction(|| {
        s.receipt_action(
            "purge",
            &json!({"id":r["id"],"expected_version":r["revision"]}),
        )
    })
    .unwrap();
    s.transaction(|| s.finish_recognition(job["job_id"].as_str().unwrap(), Ok(candidate)))
        .unwrap();
    assert!(s.rows("SELECT * FROM receipt", &[]).unwrap().is_empty());
}

#[test]
fn receipt_sorting_pages_every_column_in_both_directions_and_keeps_unknown_amount_last() {
    let (_dir, s) = setup();
    for (n, store, amount) in [
        (1, "Zulu", Some(300)),
        (2, "Alpha", Some(-50)),
        (3, "Beta", Some(300)),
        (4, "Beta", None),
    ] {
        let mut r = receipt();
        r["id"] = json!(format!("00000000-0000-4000-9000-{n:012}"));
        r["store"] = json!(store);
        r["totalMinor"] = json!(amount);
        r["occurredAt"] = json!(n * 1000);
        let saved = s.transaction(|| s.save(r, false)).unwrap();
        s.exec(
            "UPDATE receipt SET created_at_utc_ms=? WHERE receipt_id=?",
            &[json!(5000 - n * 1000), saved["id"].clone()],
        )
        .unwrap();
    }
    for (sort, asc, desc) in [
        ("store", vec![2, 3, 4, 1], vec![1, 4, 3, 2]),
        ("created_at", vec![4, 3, 2, 1], vec![1, 2, 3, 4]),
        ("receipt_time", vec![1, 2, 3, 4], vec![4, 3, 2, 1]),
        ("total", vec![2, 1, 3, 4], vec![3, 1, 2, 4]),
    ] {
        for (direction, expected) in [("asc", asc), ("desc", desc)] {
            let mut cursor = Value::Null;
            let mut actual = vec![];
            for _ in 0..6 {
                let page = s
                    .receipt_action(
                        "list",
                        &json!({"sort_by":sort,"direction":direction,"limit":1,"cursor":cursor}),
                    )
                    .unwrap();
                for row in page["items"].as_array().unwrap() {
                    actual.push(
                        row["receipt_id"]
                            .as_str()
                            .unwrap()
                            .rsplit('-')
                            .next()
                            .unwrap()
                            .parse::<i32>()
                            .unwrap(),
                    );
                }
                cursor = page["next_cursor"].clone();
                if cursor.is_null() {
                    break;
                }
            }
            assert_eq!(actual, expected, "{sort} {direction}");
        }
    }
    assert!(
        s.receipt_action("list", &json!({"sort_by":"raw SQL"}))
            .is_err()
    );
    assert!(
        s.receipt_action("list", &json!({"direction":"invalid"}))
            .is_err()
    );
    let first = s
        .receipt_action(
            "list",
            &json!({"sort_by":"store","direction":"asc","limit":1}),
        )
        .unwrap();
    assert!(
        s.receipt_action(
            "list",
            &json!({"sort_by":"total","direction":"asc","cursor":first["next_cursor"]})
        )
        .is_err()
    );
}

#[test]
fn logo_samples_match_only_confirmed_images_and_survive_receipt_deletion() {
    let (dir, s) = setup();
    let r = save(&s, receipt());
    let uploaded = s
        .transaction(|| {
            s.upload(
                &json!({"receipt_id":r["id"],"expected_version":r["revision"]}),
                &photo(),
            )
        })
        .unwrap();
    let img=s.one("SELECT b.*,i.image_id FROM receipt_image i JOIN media_blob b ON b.blob_id=i.current_blob_id WHERE i.image_id=?",&[uploaded["image_id"].clone()]).unwrap();
    s.transaction(|| s.save_logo(&img, &photo(), &json!([0, 0, 1, 0.2]), "ocr_header"))
        .unwrap();
    let rid = r["id"].as_str().unwrap();
    let before = s.logo_match_inputs(rid).unwrap();
    let id = before["candidates"][0]["logo_id"].clone();
    assert!(
        !before["references"]
            .as_array()
            .unwrap()
            .iter()
            .any(|x| x["logo_id"] == id)
    );
    s.transaction(|| {
        s.logo_action(
            "save",
            &json!({"id":id,"name":"SkyFood","expected_version":before["catalog_version"]}),
        )
    })
    .unwrap();
    let after = s.logo_match_inputs(rid).unwrap();
    assert!(
        after["references"]
            .as_array()
            .unwrap()
            .iter()
            .any(|x| x["logo_id"] == id && x["name"] == "SkyFood")
    );
    s.transaction(|| {
        s.receipt_action(
            "purge",
            &json!({"id":rid,"expected_version":uploaded["receipt"]["revision"]}),
        )
    })
    .unwrap();
    s.cleanup_media().unwrap();
    let after = s.logo_match_inputs(rid).unwrap();
    assert!(after["candidates"].as_array().unwrap().is_empty());
    assert!(
        after["references"]
            .as_array()
            .unwrap()
            .iter()
            .any(|x| x["logo_id"] == id)
    );
    s.transaction(|| {
        s.logo_action(
            "delete",
            &json!({"id":id,"expected_version":after["catalog_version"]}),
        )
    })
    .unwrap();
    assert!(
        !s.logo_match_inputs(rid).unwrap()["references"]
            .as_array()
            .unwrap()
            .iter()
            .any(|x| x["logo_id"] == id)
    );
    drop(s);
    Store::initialize(dir.path()).unwrap();
}

#[test]
fn logo_reference_ids_are_strict_and_unknown_is_explicit() {
    use receipt_backend_api::logos::matched_reference;
    let refs = vec![json!({"logo_id":"trusted","name":"Target"})];
    assert_eq!(
        matched_reference(&json!({"reference_id":"r01"}), &refs).unwrap(),
        Some(refs[0].clone())
    );
    assert_eq!(
        matched_reference(&json!({"reference_id":null}), &refs).unwrap(),
        None
    );
    for bad in [
        json!({}),
        json!({"reference_id":"Target"}),
        json!({"reference_id":"r02"}),
        json!({"reference_id":"r00"}),
        json!({"reference_id":1}),
        json!({"reference_id":"r01","name":"fake"}),
    ] {
        assert!(matched_reference(&bad, &refs).is_err());
    }
}

#[test]
fn different_merchant_votes_are_unknown_even_across_batches() {
    use receipt_backend_api::logos::selected_merchant;
    assert_eq!(selected_merchant(&[]), None);
    assert_eq!(
        selected_merchant(&[json!({"name":"Target"}), json!({"name":"Target"})]),
        Some("Target".into())
    );
    assert_eq!(
        selected_merchant(&[json!({"name":"skyFOODS"}), json!({"name":"Hualian"})]),
        None
    );
}

#[test]
fn logo_crop_uses_visual_box_not_model_store_text() {
    let bytes = photo();
    let a =
        receipt_backend_api::logos::crop(&bytes, r#"{"box":[0.2,0.05,0.8,0.15],"name":"WRONG"}"#)
            .unwrap();
    let b =
        receipt_backend_api::logos::crop(&bytes, r#"{"box":[0.2,0.05,0.8,0.15],"name":"OTHER"}"#)
            .unwrap();
    assert_eq!(a.0, b.0);
    assert_eq!(a.2, "vision_logo");
    assert_eq!(
        receipt_backend_api::logos::crop(&bytes, r#"{"box":null}"#)
            .unwrap()
            .2,
        "header_candidate"
    );
    for evidence in [
        r#"{"box":[0.8,0.2,0.1,0.3]}"#,
        r#"{"box":[-1,0,1,1]}"#,
        r#"{"box":[0,0,1]}"#,
        "invalid",
    ] {
        assert!(receipt_backend_api::logos::crop(&bytes, evidence).is_err());
    }
    assert!(receipt_backend_api::logos::crop(b"invalid", r#"{"box":null}"#).is_err());
}

#[test]
fn logo_crop_respects_camera_exif_orientation() {
    use image::ImageEncoder;
    let img = image::RgbImage::from_pixel(100, 200, image::Rgb([255, 255, 255]));
    let mut bytes = Vec::new();
    let mut encoder = image::codecs::jpeg::JpegEncoder::new(&mut bytes);
    encoder
        .set_exif_metadata(vec![
            0x49, 0x49, 42, 0, 8, 0, 0, 0, 1, 0, 0x12, 1, 3, 0, 1, 0, 0, 0, 6, 0, 0, 0, 0, 0, 0, 0,
        ])
        .unwrap();
    encoder.encode_image(&img).unwrap();
    use base64::Engine;
    let url = format!(
        "data:image/jpeg;base64,{}",
        base64::engine::general_purpose::STANDARD.encode(&bytes)
    );
    let (header, height) = receipt_backend_api::logos::localization_input(&url).unwrap();
    assert_eq!(height, 0.30);
    let header = base64::engine::general_purpose::STANDARD
        .decode(header.split_once(',').unwrap().1)
        .unwrap();
    let header = image::load_from_memory(&header).unwrap();
    assert_eq!((header.width(), header.height()), (200, 30));
    let (result, _, _) =
        receipt_backend_api::logos::crop(&bytes, r#"{"box":[0.2,0.05,0.8,0.15]}"#).unwrap();
    let crop = image::load_from_memory(&result).unwrap();
    assert!(crop.width() as f64 / crop.height() as f64 > 8.0);
}

#[test]
fn current_schema_initializes_once_and_rejects_old_versions_without_upgrade() {
    let (dir, s) = setup();
    assert_eq!(
        s.one("PRAGMA user_version", &[]).unwrap()["user_version"],
        15
    );
    assert!(s.rows("SELECT * FROM receipt", &[]).unwrap().is_empty());
    assert!(!s.rows("SELECT * FROM logo_sample", &[]).unwrap().is_empty());
    let before = s
        .rows("SELECT * FROM category ORDER BY category_id", &[])
        .unwrap();
    drop(s);
    Store::initialize(dir.path()).unwrap();
    let s = Store::open(dir.path()).unwrap();
    assert_eq!(
        s.rows("SELECT * FROM category ORDER BY category_id", &[])
            .unwrap(),
        before
    );
    s.db.execute_batch("PRAGMA user_version=6;").unwrap();
    drop(s);
    assert!(Store::initialize(dir.path()).is_err());
    let s = Store::open(dir.path()).unwrap();
    assert_eq!(
        s.one("PRAGMA user_version", &[]).unwrap()["user_version"],
        6
    );
}

#[test]
fn running_ocr_merges_header_edits_but_protects_lines_currency_and_photos() {
    for edit in ["header", "lines", "currency", "photo"] {
        let (_dir, s) = setup();
        let mut initial = receipt();
        initial["lines"] = json!([]);
        let r = s.transaction(|| s.save(initial, false)).unwrap();
        let rid = r["id"].as_str().unwrap();
        s.transaction(|| s.upload(&json!({"receipt_id":rid,"expected_version":1}), &photo()))
            .unwrap();
        let job = s
            .transaction(|| {
                s.recognition_action(
                    "start",
                    &json!({"receipt_id":rid,"expected_version":2,"zone":"America/New_York"}),
                )
            })
            .unwrap();
        s.exec(
            "UPDATE recognition_job SET status='running' WHERE job_id=?",
            &[job["job_id"].clone()],
        )
        .unwrap();
        let mut candidate = s.load(rid).unwrap();
        candidate["lines"] = receipt()["lines"].clone();
        candidate["store"] = json!("Model store");
        candidate["branch"] = json!("Detected branch");
        let mut current = s.load(rid).unwrap();
        match edit {
            "header" => {
                current["store"] = json!("My logo alias");
                current["occurredAt"] = json!(1781000000000i64);
            }
            "lines" => {
                current["lines"] = receipt()["lines"].clone();
            }
            "currency" => {
                current["currency"] = json!("CAD");
            }
            "photo" => {}
            _ => unreachable!(),
        }
        let edited = if edit == "photo" {
            s.transaction(|| s.upload(&json!({"receipt_id":rid,"expected_version":2}), &photo()))
                .unwrap();
            s.load(rid).unwrap()
        } else {
            s.transaction(|| s.save(current, false)).unwrap()
        };
        s.transaction(|| s.finish_recognition(job["job_id"].as_str().unwrap(), Ok(candidate)))
            .unwrap();
        let result = s
            .recognition_action("get", &json!({"id":job["job_id"]}))
            .unwrap();
        let saved = s.load(rid).unwrap();
        if edit == "header" {
            assert_eq!(result["status"], "applied");
            assert_eq!(saved["store"], "My logo alias");
            assert_eq!(saved["occurredAt"], edited["occurredAt"]);
            assert_eq!(saved["branch"], "Detected branch");
            assert_eq!(saved["lines"].as_array().unwrap().len(), 2);
            // An editor still holding the pre-completion draft cannot erase the results.
            assert!(s.transaction(|| s.save(edited, false)).is_err());
        } else {
            assert_eq!(result["error_code"], "stale_input");
            assert_eq!(saved, edited);
        }
    }
}

#[test]
fn sku_catalog_is_merchant_scoped_optional_and_preserved_by_old_clients() {
    let (_dir, s) = setup();
    let mut records = vec![];
    for merchant in ["Costco", "Costco", "Other grocery", ""] {
        let mut r = receipt();
        r["store"] = json!(merchant);
        r["lines"][0]["rawName"] = json!("E 002338 WHITE PEACH");
        {
            r["lines"][0]["rawName"] = json!("WHITE PEACH");
            r["lines"][0]["sku"] = json!("002338");
            r["lines"][0]["taxCode"] = json!("E");
        }
        let saved = s.transaction(|| s.save(r, false)).unwrap();
        assert_eq!(saved["lines"][0]["rawName"], "WHITE PEACH");
        assert_eq!(saved["lines"][0]["rawName"], "WHITE PEACH");
        assert_eq!(saved["lines"][0]["sku"], "002338");
        assert_eq!(saved["lines"][0]["taxCode"], "E");
        records.push(saved);
    }
    assert_eq!(s.rows("SELECT * FROM sku", &[]).unwrap().len(), 2);
    assert_eq!(s.rows("SELECT * FROM line_sku", &[]).unwrap().len(), 3);
    assert_eq!(
        s.rows("SELECT * FROM line_unmatched_sku", &[])
            .unwrap()
            .len(),
        1
    );
    let mut unknown = records.pop().unwrap();
    unknown["store"] = json!("Costco");
    s.transaction(|| s.save(unknown, false)).unwrap();
    assert!(
        s.rows("SELECT * FROM line_unmatched_sku", &[])
            .unwrap()
            .is_empty()
    );
    assert_eq!(s.rows("SELECT * FROM sku", &[]).unwrap().len(), 2);
    let mut old_client = records[0].clone();
    old_client["lines"][0]
        .as_object_mut()
        .unwrap()
        .remove("sku");
    old_client["lines"][0]
        .as_object_mut()
        .unwrap()
        .remove("taxCode");
    let mut edited = s.transaction(|| s.save(old_client, false)).unwrap();
    assert_eq!(edited["lines"][0]["sku"], "002338");
    edited["lines"][0]["taxCode"] = json!("AB");
    assert!(s.transaction(|| s.save(edited.clone(), false)).is_err());
    edited["lines"][0]["taxCode"] = Value::Null;
    edited["lines"][0]["sku"] = Value::Null;
    let saved = s.transaction(|| s.save(edited, false)).unwrap();
    assert!(saved["lines"][0]["sku"].is_null());
    assert!(saved["lines"][0]["taxCode"].is_null());
    assert!(s.rows("PRAGMA foreign_key_check", &[]).unwrap().is_empty());
}

#[test]
fn duplicate_ocr_warnings_can_be_saved_repeatedly_and_confirmed() {
    let (_dir, s) = setup();
    let mut r = receipt();
    r["lines"][0]["warnings"] = json!(["双模型中文需核对", "双模型中文需核对"]);
    let saved = s.transaction(|| s.save(r, false)).unwrap();
    let issue = s
        .one(
            "SELECT * FROM review_issue WHERE line_id=?",
            &[saved["lines"][0]["id"].clone()],
        )
        .unwrap();
    // Reproduce a persisted draft from the old recognizer with duplicate warning rows.
    s.exec("INSERT INTO review_issue SELECT ?,receipt_id,line_id,field_key,reason_code,confidence,state,created_at_utc_ms,resolved_at_utc_ms FROM review_issue WHERE issue_id=?", &[json!(db::id()),issue["issue_id"].clone()]).unwrap();
    let loaded = s.load(saved["id"].as_str().unwrap()).unwrap();
    assert_eq!(loaded["lines"][0]["warnings"].as_array().unwrap().len(), 2);
    let draft = s.transaction(|| s.save(loaded, false)).unwrap();
    assert_eq!(draft["lines"][0]["warnings"], json!(["双模型中文需核对"]));
    let posted = s.transaction(|| s.save(draft, true)).unwrap();
    assert_eq!(posted["posted"], true);
    let rows = s
        .rows(
            "SELECT * FROM review_issue WHERE line_id=?",
            &[posted["lines"][0]["id"].clone()],
        )
        .unwrap();
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0]["issue_id"], issue["issue_id"]);
}

#[test]
fn logo_crop_preserves_full_wordmark_box_with_small_padding() {
    let (_, bbox, detection) =
        receipt_backend_api::logos::crop(&photo(), r#"{"box":[0.286,0.027,0.732,0.125]}"#).unwrap();
    assert_eq!(detection, "vision_logo");
    for (i, expected) in [0.274, 0.019, 0.744, 0.133].iter().enumerate() {
        assert!((bbox[i].as_f64().unwrap() - expected).abs() < 1e-9);
    }
}

#[test]
fn expanded_logo_crop_keeps_confirmed_alias_but_disjoint_crop_does_not() {
    let (_dir, s) = setup();
    let r = s.transaction(|| s.save(receipt(), false)).unwrap();
    let upload = s
        .transaction(|| {
            s.upload(
                &json!({"receipt_id":r["id"],"expected_version":1}),
                &photo(),
            )
        })
        .unwrap();
    let img = s.one("SELECT b.*,i.image_id FROM receipt_image i JOIN media_blob b ON b.blob_id=i.current_blob_id WHERE i.image_id=?", &[upload["image_id"].clone()]).unwrap();
    s.transaction(|| s.save_logo(&img, &photo(), &json!([0.2, 0.02, 0.8, 0.1]), "ocr_header"))
        .unwrap();
    let logo = s
        .logo_action("list", &json!({"receipt_id":r["id"]}))
        .unwrap()[0]["logo_id"]
        .clone();
    let version = s
        .one("SELECT version FROM catalog_version WHERE id=1", &[])
        .unwrap()["version"]
        .clone();
    s.transaction(|| {
        s.logo_action(
            "save",
            &json!({"id":logo,"name":"Costco","expected_version":version}),
        )
    })
    .unwrap();
    for (width, bbox, expected) in [
        (18, json!([0.2, 0.02, 0.8, 0.14]), json!("Costco")),
        (20, json!([0.2, 0.2, 0.8, 0.3]), Value::Null),
    ] {
        let mut crop = std::io::Cursor::new(Vec::new());
        image::DynamicImage::new_rgb8(width, 24)
            .write_to(&mut crop, image::ImageFormat::Png)
            .unwrap();
        s.transaction(|| s.save_logo(&img, crop.get_ref(), &bbox, "ocr_header_merged"))
            .unwrap();
        let listed = s
            .logo_action("list", &json!({"receipt_id":r["id"]}))
            .unwrap();
        assert_eq!(listed[0]["name"], expected);
    }
}

#[test]
fn early_logo_store_save_preserves_edits_and_rejects_stale_jobs() {
    for edit in [
        "none",
        "header",
        "store",
        "lines",
        "photo",
        "posted",
        "deleted",
        "cancelled",
    ] {
        let (_dir, s) = setup();
        let mut initial = receipt();
        initial["store"] = json!("");
        initial["lines"] = json!([]);
        let r = s.transaction(|| s.save(initial, false)).unwrap();
        let rid = r["id"].as_str().unwrap();
        s.transaction(|| s.upload(&json!({"receipt_id":rid,"expected_version":1}), &photo()))
            .unwrap();
        let job = s
            .transaction(|| {
                s.recognition_action(
                    "start",
                    &json!({"receipt_id":rid,"expected_version":2,"zone":"America/New_York"}),
                )
            })
            .unwrap();
        let jid = job["job_id"].as_str().unwrap();
        s.exec(
            "UPDATE recognition_job SET status='running' WHERE job_id=?",
            &[json!(jid)],
        )
        .unwrap();
        let mut current = s.load(rid).unwrap();
        match edit {
            "header" => {
                current["branch"] = json!("My branch");
                current["occurredAt"] = json!(1781000000000i64);
            }
            "store" => current["store"] = json!("My store"),
            "posted" => {
                current["store"] = json!("Confirmed store");
                current["lines"] = receipt()["lines"].clone();
            }
            "lines" => current["lines"] = receipt()["lines"].clone(),
            "photo" => {
                s.transaction(|| {
                    s.upload(&json!({"receipt_id":rid,"expected_version":2}), &photo())
                })
                .unwrap();
            }
            "deleted" => {
                s.exec(
                    "UPDATE receipt SET deleted_at_utc_ms=1 WHERE receipt_id=?",
                    &[json!(rid)],
                )
                .unwrap();
            }
            "cancelled" => {
                s.transaction(|| s.recognition_action("cancel", &json!({"id":jid})))
                    .unwrap();
            }
            _ => {}
        }
        if ["header", "store", "lines", "posted"].contains(&edit) {
            s.transaction(|| s.save(current, edit == "posted"))
                .unwrap_or_else(|e| panic!("{edit}: {e:?}"));
        }
        let before = s.load(rid).unwrap();
        s.transaction(|| s.persist_recognition_store(jid, "Costco"))
            .unwrap();
        let after = s.load(rid).unwrap();
        if ["none", "header"].contains(&edit) {
            assert_eq!(after["store"], "Costco");
            for field in ["branch", "occurredAt", "lines", "totalMinor"] {
                assert_eq!(after[field], before[field]);
            }
            assert_eq!(
                after["revision"].as_i64().unwrap(),
                before["revision"].as_i64().unwrap() + 1
            );
            s.transaction(|| s.persist_recognition_store(jid, "Costco"))
                .unwrap();
            assert_eq!(s.load(rid).unwrap(), after);
            assert!(s.transaction(|| s.save(before, false)).is_err());
        } else {
            assert_eq!(after, before, "{edit}");
        }
    }
}

#[test]
fn costco_discount_metadata_follows_its_product_without_duplicate_storage() {
    let (_dir, s) = setup();
    let mut r = receipt();
    r["store"] = json!("Costco");
    r["lines"][0]["sku"] = json!("001121864");
    r["lines"][0]["taxCode"] = json!("A");
    r["lines"][1]["kind"] = json!("item_discount");
    r["lines"][1]["discountTarget"] = r["lines"][0]["id"].clone();
    r["lines"][1]["sku"] = json!("wrong");
    r["lines"][1]["taxCode"] = json!("B");
    let saved = s.transaction(|| s.save(r, false)).unwrap();
    assert_eq!(saved["lines"][1]["sku"], "001121864");
    assert_eq!(saved["lines"][1]["taxCode"], "A");
    let mut loaded = s.load(saved["id"].as_str().unwrap()).unwrap();
    assert_eq!(loaded["lines"][1]["sku"], "001121864");
    assert_eq!(s.rows("SELECT * FROM line_sku", &[]).unwrap().len(), 1);
    assert_eq!(s.rows("SELECT * FROM line_tax_code", &[]).unwrap().len(), 1);
    loaded["lines"][0]["sku"] = json!("NEW-SKU");
    loaded["lines"][0]["taxCode"] = Value::Null;
    let changed = s.transaction(|| s.save(loaded, false)).unwrap();
    assert_eq!(changed["lines"][1]["sku"], "NEW-SKU");
    assert!(changed["lines"][1]["taxCode"].is_null());
    let mut edited = changed.clone();
    let mut other = edited["lines"][0].clone();
    other["id"] = json!(db::id());
    other["sku"] = json!("OTHER");
    other["taxCode"] = json!("E");
    edited["lines"].as_array_mut().unwrap().push(other.clone());
    edited["lines"][1]["discountTarget"] = other["id"].clone();
    let preview = s
        .edit_receipt(&json!({"receipt":edited,"action":"preview"}))
        .unwrap();
    assert_eq!(preview["lines"][1]["sku"], "OTHER");
    assert_eq!(preview["lines"][1]["taxCode"], "E");
    let mut saved = s.transaction(|| s.save(preview, false)).unwrap();
    assert_eq!(saved["lines"][1]["sku"], "OTHER");
    saved["store"] = json!("Other market");
    let saved = s.transaction(|| s.save(saved, false)).unwrap();
    assert_eq!(saved["lines"][1]["sku"], "OTHER");
    assert_eq!(saved["lines"][1]["taxCode"], "E");
}

// Small legacy fixture adapter, only in tests: the production model must emit every field.
fn decode_fixture(
    s: &Store,
    r: Value,
    parts: Vec<Value>,
    images: Vec<String>,
    zone: &str,
) -> db::Result<Value> {
    assert_eq!(parts.len(), 1);
    jobs::decode_receipt(s, r, vision_fixture(parts[0].clone()), images, zone)
}
fn vision_fixture(mut data: Value) -> Value {
    let schema: Value = serde_json::from_str(include_str!("receipt_schema.json")).unwrap();
    for key in schema["properties"].as_object().unwrap().keys() {
        if data.get(key).is_none() {
            data[key] = Value::Null;
        }
    }
    for line in data["lines"].as_array_mut().unwrap() {
        line.as_object_mut().unwrap().remove("box");
        line.as_object_mut().unwrap().remove("weight_g");
        line.as_object_mut().unwrap().remove("printed_amount");
        line["amount_basis"] = json!("gross");
        for key in schema["properties"]["lines"]["items"]["properties"]
            .as_object()
            .unwrap()
            .keys()
        {
            if line.get(key).is_none() {
                line[key] = Value::Null;
            }
        }
        line["evidence"] = json!([]);
        line["review_notes"] = json!([]);
        line["is_weighed"] = json!(false);
    }
    data
}
#[test]
fn vision_contract_keeps_explicit_fields_duplicates_and_cross_photo_evidence() {
    let (_dir, s) = setup();
    let mut data = vision_fixture(
        json!({"lines":[{"name":"WHITE PEACH","product_name":"白桃","kind":"product","sku":"002338","tax_code":null,"amount":"8.40","quantity":"2.81","quantity_unit":"lb","unit_price":"2.99"},{"name":"WHITE PEACH","kind":"product","sku":"002338","tax_code":"E","amount":"8.40"},{"name":"WHITE PEACH","kind":"item_discount","amount":"-1.00","discount_target_index":0}]}),
    );
    data["lines"][0]["is_weighed"] = json!(true);
    data["lines"][0]["evidence"] = json!([{"image_index":0,"box":[0.1,0.8,0.9,0.9]},{"image_index":1,"box":[0.1,0.1,0.9,0.2]}]);
    let r = jobs::decode_receipt(
        &s,
        receipt(),
        data.clone(),
        vec!["first".into(), "second".into()],
        "America/New_York",
    )
    .unwrap();
    assert_eq!(r["lines"].as_array().unwrap().len(), 3);
    assert_eq!(r["lines"][0]["weightMg"], 1274595);
    assert_eq!(r["lines"][0]["rawName"], "WHITE PEACH");
    assert_eq!(r["lines"][2]["sku"], "002338");
    assert_eq!(r["lines"][2]["productNameEdit"], "白桃");
    assert_eq!(r["lines"][0]["evidence"][1]["imageId"], "second");
    data["lines"][2]["discount_target_index"] = json!(2);
    assert!(receipt_backend_api::pipeline::validate_receipt(&data, 2).is_err());
    data["lines"][2]["discount_target_index"] = json!(0);
    assert!(receipt_backend_api::pipeline::validate_receipt(&data, 1).is_err());
    data["store"] = json!("OCR invented store");
    assert!(receipt_backend_api::pipeline::validate_receipt(&data, 2).is_err());
}
#[test]
fn save_does_not_interpret_names_as_sku_or_weight_markers() {
    let (_dir, s) = setup();
    let mut r = receipt();
    r["store"] = json!("Costco");
    r["lines"][0]["rawName"] = json!("E 2338 WHITE PEACH");
    let saved = s.transaction(|| s.save(r, false)).unwrap();
    assert_eq!(saved["lines"][0]["rawName"], "E 2338 WHITE PEACH");
    assert!(saved["lines"][0]["sku"].is_null());
}

#[test]
fn arithmetic_validation_reports_mismatch_without_reclassifying_or_changing_rows() {
    use receipt_backend_api::pipeline::arithmetic_difference;
    let data = json!({"total":"6.00","lines":[{"name":"APPLE","amount":"6.00"},{"name":"TOTAL","kind":"product","amount":"6.00"}]});
    assert_eq!(arithmetic_difference(&data), Some((12000, 6000)));
    assert_eq!(data["lines"][1]["kind"], "product");
    assert_eq!(
        arithmetic_difference(&json!({"total":"6.00","lines":[{"amount":"6.00"},{"amount":null}]})),
        None
    );
    assert_eq!(
        arithmetic_difference(
            &json!({"total":"-6.00","lines":[{"amount":"-5.50"},{"amount":"-0.50"}]})
        ),
        None
    );
}

#[test]
fn explicit_net_basis_is_converted_arithmetically_without_interpreting_discount_labels() {
    let mut data = json!({"total":"2.59","lines":[{"kind":"product","name":"TOFU","amount":"2.59","amount_basis":"net_including_item_discounts"},{"kind":"item_discount","name":"ANY LABEL","amount":"-0.61","discount_target_index":0,"amount_basis":"gross"}]});
    let amounts = receipt_backend_api::receipt_lines::amounts(&data, 2).unwrap();
    assert_eq!(
        amounts,
        vec![(json!(320), json!(259)), (json!(-61), Value::Null)]
    );
    assert!(receipt_backend_api::pipeline::arithmetic_difference(&data).is_none());
    data["lines"][0]["amount_basis"] = json!("gross");
    assert_eq!(
        receipt_backend_api::receipt_lines::amounts(&data, 2).unwrap()[0],
        (json!(259), Value::Null)
    );
    assert_eq!(
        receipt_backend_api::pipeline::arithmetic_difference(&data),
        Some((1980, 2590))
    );
    data["lines"][0]["amount_basis"] = json!("net_including_item_discounts");
    data["lines"][1]["amount"] = Value::Null;
    assert_eq!(
        receipt_backend_api::receipt_lines::amounts(&data, 2).unwrap()[0],
        (Value::Null, json!(259))
    );
}
#[test]
fn raw_package_units_are_converted_by_backend_and_scale_weight_has_priority() {
    let mut line = json!({"kind":"product","package_weight":"16","package_weight_unit":"oz","quantity":null,"quantity_unit":null});
    assert_eq!(
        receipt_backend_api::weights::recognized(&line).unwrap(),
        453592
    );
    line["quantity"] = json!("0.41");
    line["quantity_unit"] = json!("lb");
    assert_eq!(
        receipt_backend_api::weights::recognized(&line).unwrap(),
        185973
    );
}

#[test]
fn fresh_database_bundles_labelled_logo_images_without_ocr_or_prior_receipts() {
    let (_dir, s) = setup();
    let catalog: Value = serde_json::from_str(include_str!(
        "../../src/backend_api/resources/merchants/manifest.json"
    ))
    .unwrap();
    assert!(s.rows("SELECT * FROM receipt", &[]).unwrap().is_empty());
    assert_eq!(
        s.logo_action("list", &json!({}))
            .unwrap()
            .as_array()
            .unwrap()
            .len(),
        catalog["samples"].as_array().unwrap().len()
    );
    let mut draft = receipt();
    draft["store"] = json!("");
    draft["lines"] = json!([]);
    let r = s.transaction(|| s.save(draft, false)).unwrap();
    let uploaded = s
        .transaction(|| {
            s.upload(
                &json!({"receipt_id":r["id"],"expected_version":1}),
                &photo(),
            )
        })
        .unwrap();
    let image=s.one("SELECT b.*,i.image_id FROM receipt_image i JOIN media_blob b ON b.blob_id=i.current_blob_id WHERE i.image_id=?",&[uploaded["image_id"].clone()]).unwrap();
    for sample in catalog["samples"].as_array().unwrap() {
        let bytes = std::fs::read(
            std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("resources/merchants")
                .join(sample["image"].as_str().unwrap()),
        )
        .unwrap();
        // Each bundled reference remains an image resource with a validated store label.
        s.transaction(|| s.save_logo(&image, &bytes, &json!([0.1, 0.02, 0.9, 0.2]), "ocr_header"))
            .unwrap();
        let inputs = s.logo_match_inputs(r["id"].as_str().unwrap()).unwrap();
        assert_eq!(inputs["candidates"].as_array().unwrap().len(), 1);
        assert!(
            inputs["references"]
                .as_array()
                .unwrap()
                .iter()
                .any(|r| r["name"] == sample["name"] && r["content_sha256"] == sample["sha256"])
        );
    }
}

#[test]
fn bundled_catalog_is_initial_data_and_never_overwrites_user_changes_on_restart() {
    let (dir, s) = setup();
    let samples = s.logo_action("list", &json!({})).unwrap();
    let version = || {
        s.one("SELECT version FROM catalog_version WHERE id=1", &[])
            .unwrap()["version"]
            .clone()
    };
    s.transaction(||s.logo_action("save",&json!({"id":samples[0]["logo_id"],"name":"My store alias","expected_version":version()}))).unwrap();
    s.transaction(|| {
        s.logo_action(
            "delete",
            &json!({"id":samples[1]["logo_id"],"expected_version":version()}),
        )
    })
    .unwrap();
    s.cleanup_media().unwrap();
    let before = s.logo_action("list", &json!({})).unwrap();
    let blobs = s
        .rows("SELECT * FROM media_blob ORDER BY blob_id", &[])
        .unwrap();
    drop(s);
    Store::initialize(dir.path()).unwrap();
    let s = Store::open(dir.path()).unwrap();
    assert_eq!(s.logo_action("list", &json!({})).unwrap(), before);
    assert_eq!(
        s.rows("SELECT * FROM media_blob ORDER BY blob_id", &[])
            .unwrap(),
        blobs
    );
    assert!(
        before
            .as_array()
            .unwrap()
            .iter()
            .any(|r| r["name"] == "My store alias")
    );
}

#[test]
fn posted_recognition_reopens_atomically_and_failure_preserves_confirmation() {
    let (_dir, s) = setup();
    let r = save(&s, receipt());
    let id = r["id"].as_str().unwrap();
    assert!(
        s.transaction(|| s.recognition_action(
            "start",
            &json!({"receipt_id":id,"expected_version":1,"zone":"UTC"})
        ))
        .is_err()
    );
    assert_eq!(s.load(id).unwrap()["posted"], true);
    s.transaction(|| s.upload(&json!({"receipt_id":id,"expected_version":1}), &photo()))
        .unwrap();
    let before = s.load(id).unwrap();
    s.exec("CREATE TRIGGER fail_enqueue BEFORE INSERT ON recognition_job BEGIN SELECT RAISE(ABORT, 'injected failure'); END", &[]).unwrap();
    assert!(
        s.transaction(|| s.recognition_action(
            "start",
            &json!({"receipt_id":id,"expected_version":before["revision"],"zone":"UTC"})
        ))
        .is_err()
    );
    assert_eq!(s.load(id).unwrap()["posted"], true);
    assert_eq!(s.load(id).unwrap()["revision"], before["revision"]);
    s.exec("DROP TRIGGER fail_enqueue", &[]).unwrap();

    let job = s
        .transaction(|| {
            s.recognition_action(
                "start",
                &json!({"receipt_id":id,"expected_version":before["revision"],"zone":"UTC"}),
            )
        })
        .unwrap();
    let reopened = s.load(id).unwrap();
    assert_eq!(reopened["posted"], false);
    assert_eq!(reopened["createdAt"], before["createdAt"]);
    assert_eq!(
        reopened["revision"].as_i64().unwrap(),
        before["revision"].as_i64().unwrap() + 1
    );
    assert_eq!(
        s.report_action(
            "summary",
            &json!({"start":0,"end":1900000000000i64,"currency":"USD"})
        )
        .unwrap()["net"],
        0
    );
    let stored = s
        .one(
            "SELECT receipt_version,result_json FROM recognition_job WHERE job_id=?",
            &[job["job_id"].clone()],
        )
        .unwrap();
    assert_eq!(stored["receipt_version"], reopened["revision"]);
    let source: Value = serde_json::from_str(stored["result_json"].as_str().unwrap()).unwrap();
    assert_eq!(source["source"]["posted"], false);
    assert!(
        s.transaction(|| s.recognition_action(
            "start",
            &json!({"receipt_id":id,"expected_version":before["revision"],"zone":"UTC"})
        ))
        .is_err()
    );
}

#[test]
fn product_name_groups_across_names_and_weights_and_can_be_cleared() {
    let (_dir, s) = setup();
    let first = save(&s, receipt());
    let mut second = receipt();
    second["store"] = json!("Another grocery");
    second["lines"][0]["rawName"] = json!("Other rice");
    second["lines"][0]["weightMg"] = json!(1000000);
    save(&s, second);
    let mut draft = receipt();
    draft["lines"][0]["rawName"] = json!("UNNAMED OCR PRODUCT");
    s.transaction(|| s.save(draft, false)).unwrap();
    let products = s.catalog_action("products", "list", &json!({})).unwrap();
    assert_eq!(products.as_array().unwrap().len(), 2);
    assert!(
        !products
            .as_array()
            .unwrap()
            .iter()
            .any(|p| p["raw_name"] == "UNNAMED OCR PRODUCT")
    );
    let rice: Vec<_> = products
        .as_array()
        .unwrap()
        .iter()
        .filter(|p| p["raw_name"] != "UNNAMED OCR PRODUCT")
        .collect();
    for p in &rice {
        let version = s
            .one("SELECT version FROM catalog_version WHERE id=1", &[])
            .unwrap()["version"]
            .clone();
        s.transaction(|| {
            s.catalog_action(
                "printed_names",
                "set_product_name",
                &json!({"id":p["printed_name_id"],"name":"Rice","expected_version":version}),
            )
        })
        .unwrap();
    }
    let mut displayed = s.load(first["id"].as_str().unwrap()).unwrap();
    s.display_data(&mut displayed, 2, "USD").unwrap();
    assert_eq!(displayed["lines"][0]["display"]["productName"], "Rice");
    assert_eq!(
        s.catalog_action("product_names", "list", &json!({}))
            .unwrap()[0]["name"],
        json!("Rice")
    );
    let query = json!({"start":0,"end":1900000000000i64,"currency":"USD"});
    let report = s.report_action("summary", &query).unwrap();
    let group = report["groups"]
        .as_array()
        .unwrap()
        .iter()
        .find(|g| g["key"] == "product:Rice")
        .unwrap();
    assert_eq!(group["amount"], 2000, "{report:#}");
    assert_eq!(group["line_ids"].as_array().unwrap().len(), 2);
    assert_eq!(
        s.load(first["id"].as_str().unwrap()).unwrap()["lines"][0]["rawName"],
        "RICE"
    );
    s.transaction(|| {
        s.catalog_action(
            "printed_names",
            "set_product_name",
            &json!({"id":rice[0]["printed_name_id"],"name":"","expected_version":s.one("SELECT version FROM catalog_version WHERE id=1", &[]).unwrap()["version"]}),
        )
    })
    .unwrap();
    let report = s.report_action("summary", &query).unwrap();
    assert_eq!(
        report["groups"]
            .as_array()
            .unwrap()
            .iter()
            .find(|g| g["key"] == "product:Rice")
            .unwrap()["amount"],
        1000
    );
    assert_eq!(
        report["groups"]
            .as_array()
            .unwrap()
            .iter()
            .find(|g| g["key"] == format!("product:{}", rice[0]["raw_name"].as_str().unwrap()))
            .unwrap()["amount"],
        1000
    );
}

#[test]
fn receipt_product_name_edits_preview_and_commit_atomically_without_renaming_product() {
    let (_dir, s) = setup();
    let first = save(&s, receipt());
    let other = save(&s, receipt());
    let mut edited = s.load(first["id"].as_str().unwrap()).unwrap();
    edited["lines"][0]["productNameEdit"] = json!("大米");
    s.display_data(&mut edited, 2, "USD").unwrap();
    assert_eq!(edited["lines"][0]["display"]["productName"], "大米");
    assert!(
        s.rows("SELECT * FROM product_name", &[])
            .unwrap()
            .is_empty()
    );
    let mut invalid = edited.clone();
    invalid["lines"][0]["categoryId"] = json!("missing-category");
    assert!(s.transaction(|| s.save(invalid, true)).is_err());
    assert!(
        s.rows("SELECT * FROM product_name", &[])
            .unwrap()
            .is_empty()
    );
    assert!(
        s.catalog_action("product_names", "list", &json!({}))
            .unwrap()
            .as_array()
            .unwrap()
            .is_empty()
    );
    let saved = save(&s, edited);
    assert_eq!(saved["lines"][0]["rawName"], "RICE");
    assert!(saved["lines"][0]["productNameEdit"].is_null());
    let mut displayed = saved.clone();
    s.display_data(&mut displayed, 2, "USD").unwrap();
    assert_eq!(displayed["lines"][0]["display"]["productName"], "大米");
    assert!(s.transaction(|| s.save(other, true)).is_err());
    let mut cleared = saved;
    cleared["lines"][0]["productNameEdit"] = json!("");
    save(&s, cleared);
    assert!(
        s.rows("SELECT * FROM printed_name_product_name", &[])
            .unwrap()
            .is_empty()
    );
    assert_eq!(
        s.catalog_action("product_names", "list", &json!({}))
            .unwrap(),
        json!([])
    );
}

#[test]
fn recognized_printed_name_reuses_saved_product_name_before_ocr_suggestion() {
    let (_dir, s) = setup();
    let mut original = receipt();
    original["lines"][0]["productNameEdit"] = json!("大米");
    let saved = save(&s, original);
    let recognized = jobs::decode_receipt(&s, saved, vision_fixture(json!({"lines":[{"name":"RICE","product_name":"OCR alternative","kind":"product","amount":"10.00"}]})),vec!["image".into()],"UTC").unwrap();
    assert_eq!(recognized["lines"][0]["rawName"], "RICE");
    assert_eq!(recognized["lines"][0]["productNameEdit"], "大米");
}

#[test]
fn name_and_category_tags_delete_links_but_preserve_receipts_and_images() {
    let (_dir, s) = setup();
    let mut r = receipt();
    r["lines"][0]["productNameEdit"] = json!("Rice");
    let saved = save(&s, r);
    s.transaction(||s.upload(&json!({"receipt_id":saved["id"],"expected_version":saved["revision"],"captured_at_utc_ms":1}),&photo())).unwrap();
    let mut second = receipt();
    second["lines"][0]["rawName"] = json!("OTHER RICE");
    second["lines"][0]["productNameEdit"] = json!("Rice");
    save(&s, second);
    let version = || {
        s.one("SELECT version FROM catalog_version WHERE id=1", &[])
            .unwrap()["version"]
            .clone()
    };
    let name = s
        .catalog_action("product_names", "list", &json!({}))
        .unwrap()[0]
        .clone();
    assert_eq!(
        s.catalog_action("printed_names", "list", &json!({}))
            .unwrap()
            .as_array()
            .unwrap()
            .len(),
        2
    );
    s.transaction(||s.catalog_action("product_names","classify",&json!({"id":name["product_name_id"],"category_name":"Grains","expected_version":version()}))).unwrap();
    let category = s
        .one("SELECT category_id FROM category WHERE name='Grains'", &[])
        .unwrap()["category_id"]
        .clone();
    let child = db::id();
    s.exec(
        "INSERT INTO category VALUES (?,?,'Child',NULL)",
        &[json!(child), category.clone()],
    )
    .unwrap();
    assert_eq!(
        s.one(
            "SELECT COUNT(*) AS n FROM line_category_assignment WHERE category_id=?",
            std::slice::from_ref(&category)
        )
        .unwrap()["n"],
        2
    );
    s.transaction(|| {
        s.catalog_action(
            "categories",
            "delete",
            &json!({"id":category,"expected_version":version()}),
        )
    })
    .unwrap();
    assert_eq!(
        s.one("SELECT category_id FROM product_name", &[]).unwrap()["category_id"],
        db::UNCATEGORIZED
    );
    assert!(
        s.one(
            "SELECT parent_id FROM category WHERE category_id=?",
            &[json!(child)]
        )
        .unwrap()["parent_id"]
            .is_null()
    );
    assert_eq!(
        s.one(
            "SELECT COUNT(*) AS n FROM line_category_assignment WHERE category_id=?",
            &[json!(db::UNCATEGORIZED)]
        )
        .unwrap()["n"],
        2
    );
    s.transaction(|| {
        s.catalog_action(
            "product_names",
            "delete",
            &json!({"id":name["product_name_id"],"expected_version":version()}),
        )
    })
    .unwrap();
    assert!(
        s.rows("SELECT * FROM product_name", &[])
            .unwrap()
            .is_empty()
    );
    assert!(
        s.rows("SELECT * FROM printed_name_product_name", &[])
            .unwrap()
            .is_empty()
    );
    assert_eq!(s.rows("SELECT * FROM receipt", &[]).unwrap().len(), 2);
    assert_eq!(s.rows("SELECT * FROM receipt_line", &[]).unwrap().len(), 4);
    assert_eq!(
        s.images(saved["id"].as_str().unwrap(), false)
            .unwrap()
            .as_array()
            .unwrap()
            .len(),
        1
    );
    let report = s
        .report_action(
            "summary",
            &json!({"start":0,"end":1900000000000i64,"currency":"USD"}),
        )
        .unwrap();
    assert!(
        report["groups"]
            .as_array()
            .unwrap()
            .iter()
            .any(|g| g["key"] == "product:OTHER RICE")
    );
    assert!(s.rows("PRAGMA foreign_key_check", &[]).unwrap().is_empty());
}

#[test]
fn food_type_presets_are_unique_and_deleted_types_stay_deleted() {
    let (dir, s) = setup();
    for name in [
        "坚果",
        "豆类及其制品",
        "保健品",
        "鸡蛋",
        "大米及其制品",
        "小麦及其制品",
        "粗粮",
        "冰激凌",
        "酱料",
        "零食",
    ] {
        let rows = s
            .rows("SELECT * FROM category WHERE name=?", &[json!(name)])
            .unwrap();
        assert_eq!(rows.len(), 1, "{name}");
        assert!(rows[0]["system_key"].is_null());
    }
    let nuts = s
        .one("SELECT category_id FROM category WHERE name='坚果'", &[])
        .unwrap();
    s.transaction(|| {
        s.catalog_action(
            "categories",
            "delete",
            &json!({"id":nuts["category_id"],"expected_version":0}),
        )
    })
    .unwrap();
    drop(s);
    Store::initialize(dir.path()).unwrap();
    let s = Store::open(dir.path()).unwrap();
    assert!(
        s.rows("SELECT * FROM category WHERE name='坚果'", &[])
            .unwrap()
            .is_empty()
    );
}

#[test]
fn replacing_product_names_prunes_only_the_final_mapping_and_rolls_back_on_failure() {
    let (_dir, s) = setup();
    let mut first = receipt();
    first["lines"][0]["productNameEdit"] = json!("Rice");
    let first = save(&s, first);
    let mut second = receipt();
    second["lines"][0]["rawName"] = json!("OTHER RICE");
    second["lines"][0]["productNameEdit"] = json!("Rice");
    let second = save(&s, second);
    let printed = s
        .one(
            "SELECT printed_name_id FROM printed_name WHERE raw_name='RICE'",
            &[],
        )
        .unwrap();
    let version = s
        .one("SELECT version FROM catalog_version WHERE id=1", &[])
        .unwrap()["version"]
        .clone();
    s.transaction(||s.catalog_action("printed_names","set_product_name",&json!({"id":printed["printed_name_id"],"name":"Brown rice","expected_version":version}))).unwrap();
    assert_eq!(
        s.rows("SELECT * FROM product_name WHERE name='Rice'", &[])
            .unwrap()
            .len(),
        1
    );
    let mut edit = s.load(second["id"].as_str().unwrap()).unwrap();
    edit["lines"][0]["productNameEdit"] = json!("Brown rice");
    let mut invalid = edit.clone();
    invalid["lines"][0]["categoryId"] = json!("missing");
    assert!(s.transaction(|| s.save(invalid, true)).is_err());
    assert_eq!(
        s.rows("SELECT * FROM product_name WHERE name='Rice'", &[])
            .unwrap()
            .len(),
        1
    );
    save(&s, edit);
    assert!(
        s.rows("SELECT * FROM product_name WHERE name='Rice'", &[])
            .unwrap()
            .is_empty()
    );
    assert_eq!(s.rows("SELECT * FROM product_name", &[]).unwrap().len(), 1);
    assert_eq!(
        s.rows("SELECT * FROM printed_name_product_name", &[])
            .unwrap()
            .len(),
        2
    );
    assert_eq!(
        s.load(first["id"].as_str().unwrap()).unwrap()["lines"][0]["rawName"],
        "RICE"
    );
    assert_eq!(s.rows("SELECT * FROM receipt", &[]).unwrap().len(), 2);
}

#[test]
fn swapping_names_within_one_receipt_preserves_their_ids_and_categories() {
    let (_dir, s) = setup();
    let mut r = receipt();
    r["lines"][0]["productNameEdit"] = json!("Rice");
    let mut other = r["lines"][0].clone();
    other["id"] = json!(db::id());
    other["rawName"] = json!("BEANS");
    other["productNameEdit"] = json!("Beans");
    r["lines"].as_array_mut().unwrap().push(other);
    r["totalMinor"] = json!(1950);
    let mut saved = save(&s, r);
    let category = s
        .one(
            "SELECT category_id FROM category WHERE name='豆类及其制品'",
            &[],
        )
        .unwrap()["category_id"]
        .clone();
    s.exec(
        "UPDATE product_name SET category_id=? WHERE name='Beans'",
        &[category],
    )
    .unwrap();
    let before = s
        .rows(
            "SELECT product_name_id,name,category_id FROM product_name ORDER BY name",
            &[],
        )
        .unwrap();
    saved["lines"][0]["productNameEdit"] = json!("Beans");
    saved["lines"][2]["productNameEdit"] = json!("Rice");
    save(&s, saved);
    assert_eq!(
        s.rows(
            "SELECT product_name_id,name,category_id FROM product_name ORDER BY name",
            &[]
        )
        .unwrap(),
        before
    );
}

#[test]
fn reports_and_receipt_reads_use_current_name_category_over_historical_assignment() {
    let (_dir, s) = setup();
    let mut input = receipt();
    input["lines"][0]["productNameEdit"] = json!("Rice");
    input["lines"][1]["kind"] = json!("item_discount");
    input["lines"][1]["discountTarget"] = input["lines"][0]["id"].clone();
    let saved = save(&s, input);
    let category = s
        .one(
            "SELECT category_id FROM category WHERE name='大米及其制品'",
            &[],
        )
        .unwrap()["category_id"]
        .clone();
    // Reproduce historical data: the dictionary is classified, old line snapshots are not.
    s.exec(
        "UPDATE product_name SET category_id=? WHERE name='Rice'",
        std::slice::from_ref(&category),
    )
    .unwrap();
    let loaded = s.load(saved["id"].as_str().unwrap()).unwrap();
    assert_eq!(loaded["lines"][0]["categoryId"], category);
    assert_eq!(loaded["lines"][1]["categoryId"], category);
    let query = json!({"start":0,"end":1900000000000i64,"currency":"USD","category":category});
    let report = s.report_action("summary", &query).unwrap();
    assert_eq!(report["net"], 950);
    assert_eq!(report["entries"].as_array().unwrap().len(), 2);
    let mut unclassified = query.clone();
    unclassified["category"] = json!(db::UNCATEGORIZED);
    assert_eq!(s.report_action("summary", &unclassified).unwrap()["net"], 0);
    // A later receipt save cannot reintroduce an old category snapshot into reports.
    let mut edited = loaded;
    edited["lines"][0]["categoryId"] = json!(db::UNCATEGORIZED);
    save(&s, edited);
    assert_eq!(s.report_action("summary", &query).unwrap()["net"], 950);
    // Deleting the dictionary category returns both product and discount to uncategorized.
    let version = s
        .one("SELECT version FROM catalog_version WHERE id=1", &[])
        .unwrap()["version"]
        .clone();
    s.transaction(|| {
        s.catalog_action(
            "categories",
            "delete",
            &json!({"id":category,"expected_version":version}),
        )
    })
    .unwrap();
    assert_eq!(
        s.report_action("summary", &unclassified).unwrap()["net"],
        950
    );
}

#[test]
fn drafts_preserve_proposals_without_learning_until_confirmation() {
    let (dir, s) = setup();
    let mut input = receipt();
    input["lines"][0]["productNameEdit"] = json!("Draft rice");
    let draft = s.transaction(|| s.save(input, false)).unwrap();
    assert!(draft["lines"][0]["productId"].is_null());
    assert_eq!(draft["lines"][0]["productNameEdit"], "Draft rice");
    assert_eq!(draft["lines"][0]["weightMg"], 500000);
    for table in ["product", "printed_name", "product_name"] {
        assert!(
            s.rows(&format!("SELECT * FROM {table}"), &[])
                .unwrap()
                .is_empty()
        );
    }
    drop(s);
    let s = Store::open(dir.path()).unwrap();
    let loaded = s.load(draft["id"].as_str().unwrap()).unwrap();
    assert_eq!(loaded["lines"][0]["productNameEdit"], "Draft rice");
    let mut invalid = loaded.clone();
    invalid["lines"][0]["amountMinor"] = Value::Null;
    assert!(s.transaction(|| s.save(invalid, true)).is_err());
    assert!(
        s.rows("SELECT * FROM product_name", &[])
            .unwrap()
            .is_empty()
    );
    let posted = save(&s, loaded);
    assert!(!posted["lines"][0]["productId"].is_null());
    assert!(posted["lines"][0]["productNameEdit"].is_null());
    assert!(
        s.rows("SELECT * FROM line_product_name_candidate", &[])
            .unwrap()
            .is_empty()
    );
    assert_eq!(s.rows("SELECT * FROM product_name", &[]).unwrap().len(), 1);
    let mut another = receipt();
    another["lines"][0]["productNameEdit"] = json!("Wrong OCR name");
    let wrong = s.transaction(|| s.save(another, false)).unwrap();
    assert_eq!(
        s.one("SELECT name FROM product_name", &[]).unwrap()["name"],
        "Draft rice"
    );
    s.transaction(|| {
        s.receipt_action(
            "purge",
            &json!({"id":wrong["id"],"expected_version":wrong["revision"]}),
        )
    })
    .unwrap();
    assert_eq!(
        s.one("SELECT name FROM product_name", &[]).unwrap()["name"],
        "Draft rice"
    );
    let lookup = s.transaction(|| s.save(receipt(), false)).unwrap();
    let mut shown = lookup.clone();
    s.display_data(&mut shown, 2, "USD").unwrap();
    assert_eq!(shown["lines"][0]["display"]["productName"], "Draft rice");
    s.validate().unwrap();
}

#[test]
fn confirmed_catalog_collects_renamed_removed_and_deleted_items_but_keeps_shared_names() {
    let (_dir, s) = setup();
    let mut first = receipt();
    first["lines"][0]["productNameEdit"] = json!("Rice");
    let first = save(&s, first);
    let second = save(&s, receipt());
    let mut edit = s.load(first["id"].as_str().unwrap()).unwrap();
    edit["lines"][0]["rawName"] = json!("CORRECT RICE");
    let changed = save(&s, edit);
    assert_eq!(s.rows("SELECT * FROM printed_name", &[]).unwrap().len(), 2);
    let second = s.load(second["id"].as_str().unwrap()).unwrap();
    s.transaction(|| {
        s.receipt_action(
            "purge",
            &json!({"id":second["id"],"expected_version":second["revision"]}),
        )
    })
    .unwrap();
    assert_eq!(
        s.one("SELECT raw_name FROM printed_name", &[]).unwrap()["raw_name"],
        "CORRECT RICE"
    );
    assert_eq!(
        s.one("SELECT name FROM product_name", &[]).unwrap()["name"],
        "Rice"
    );
    let mut edit = s.load(changed["id"].as_str().unwrap()).unwrap();
    edit["lines"] = json!([]);
    edit["totalMinor"] = json!(0);
    save(&s, edit);
    for table in ["product", "printed_name", "product_name"] {
        assert!(
            s.rows(&format!("SELECT * FROM {table}"), &[])
                .unwrap()
                .is_empty()
        );
    }
    s.validate().unwrap();
}

#[test]
fn trash_restore_and_reopen_keep_local_values_without_polluting_catalog() {
    let (_dir, s) = setup();
    let mut input = receipt();
    input["lines"][0]["productNameEdit"] = json!("Rice");
    let posted = save(&s, input);
    let rid = posted["id"].as_str().unwrap();
    s.transaction(|| {
        s.upload(
            &json!({"receipt_id":rid,"expected_version":posted["revision"],"captured_at_utc_ms":1}),
            &photo(),
        )
    })
    .unwrap();
    let revision = s.load(rid).unwrap()["revision"].clone();
    s.transaction(|| s.receipt_action("trash", &json!({"id":rid,"expected_version":revision})))
        .unwrap();
    assert!(
        s.rows("SELECT * FROM printed_name", &[])
            .unwrap()
            .is_empty()
    );
    let trash = s.load(rid).unwrap();
    assert_eq!(trash["lines"][0]["productNameEdit"], "Rice");
    assert_eq!(trash["lines"][0]["weightMg"], 500000);
    s.transaction(|| {
        s.receipt_action(
            "restore",
            &json!({"id":rid,"expected_version":trash["revision"]}),
        )
    })
    .unwrap();
    let restored = s.load(rid).unwrap();
    assert_eq!(restored["posted"], true);
    assert_eq!(s.rows("SELECT * FROM printed_name", &[]).unwrap().len(), 1);
    s.transaction(|| {
        s.recognition_action(
            "start",
            &json!({"receipt_id":rid,"expected_version":restored["revision"],"zone":"UTC"}),
        )
    })
    .unwrap();
    assert_eq!(s.load(rid).unwrap()["posted"], false);
    assert!(
        s.rows("SELECT * FROM printed_name", &[])
            .unwrap()
            .is_empty()
    );
    assert_eq!(s.load(rid).unwrap()["lines"][0]["productNameEdit"], "Rice");
    assert_eq!(s.images(rid, false).unwrap().as_array().unwrap().len(), 1);
    s.validate().unwrap();
}

#[test]
fn product_name_receipts_filter_is_unique_paginated_and_tracks_current_mappings() {
    let (_dir, s) = setup();
    let mut r = receipt();
    r["lines"][0]["productNameEdit"] = json!("Rice");
    r["lines"][0]["rawName"] = json!("  RICE  ");
    let saved = save(&s, r);
    let name = s
        .rows("SELECT product_name_id FROM product_name", &[])
        .unwrap()[0]["product_name_id"]
        .clone();
    let mut draft = receipt();
    draft["lines"][0]["rawName"] = json!("New draft spelling");
    draft["lines"][0]["productNameEdit"] = json!("Rice");
    s.transaction(|| s.save(draft, false)).unwrap();
    let mut unrelated = receipt();
    unrelated["lines"][0]["rawName"] = json!("Milk");
    save(&s, unrelated);
    let first = s
        .receipt_action("list", &json!({"product_name_id":name,"limit":1}))
        .unwrap();
    let second = s
        .receipt_action(
            "list",
            &json!({"product_name_id":name,"limit":1,"cursor":first["next_cursor"]}),
        )
        .unwrap();
    assert_eq!(first["items"].as_array().unwrap().len(), 1);
    assert_eq!(second["items"].as_array().unwrap().len(), 1);
    assert_ne!(
        first["items"][0]["receipt_id"],
        second["items"][0]["receipt_id"]
    );
    let current = s.load(saved["id"].as_str().unwrap()).unwrap();
    let mut changed = current;
    changed["lines"][0]["productNameEdit"] = json!("Other rice");
    save(&s, changed);
    assert!(
        s.receipt_action("list", &json!({"product_name_id":name}))
            .unwrap()["items"]
            .as_array()
            .unwrap()
            .is_empty()
    );
}
