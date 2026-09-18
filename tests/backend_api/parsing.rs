use image::ImageDecoder;
use receipt_backend_api::{parsing, pipeline};
use serde_json::{Value, json};
fn parse(text: &str, store: &str) -> Value {
    let data = parsing::parse(
        &[json!({"unlimited":text,"paddle":{"words":[]}})],
        Some(store),
    );
    pipeline::validate_receipt(&data, 1).unwrap();
    data
}
#[test]
fn costco_tax_sku_coupons_and_reward_summary() {
    let d = parse(
        "E 2338 WHITE PEACH 11.99\n2338 WHITE PEACH 11.99\n000123 / 2338 2.00-\nSUB TOTAL 21.98\nTAX 1.00\n**** TOTAL 22.98\nExecutive Reward 5.00\nSUB TOTAL 16.98\nTAX 1.00\nTOTAL 17.98",
        "Costco",
    );
    let l = d["lines"].as_array().unwrap();
    assert_eq!(l.len(), 4);
    assert_eq!(d["total"], "22.98");
    assert_eq!(l[0]["name"], "WHITE PEACH");
    assert_eq!(l[0]["tax_code"], "E");
    assert_eq!(l[1]["sku"], "2338");
    assert!(l[1]["tax_code"].is_null());
    assert_eq!(l[2]["discount_target_index"], 1);
    assert_eq!(l[2]["sku"], "2338");
    assert_eq!(l[2]["amount"], "-2.00");
    assert!(pipeline::arithmetic_difference(&d).is_none());
    let d = parse("E 2338 WHITE PEACH 11.99\n123 / 2338 2.00-", "Costco");
    assert_eq!(d["lines"][1]["tax_code"], "E");
}
#[test]
fn bilingual_net_discounts_and_weight_are_not_extra_products() {
    let d = parse(include_str!("fixtures/counted_bilingual.txt"), "SkyFoods");
    let l = d["lines"].as_array().unwrap();
    assert_eq!(l.len(), 9, "{d:#}");
    assert_eq!(l[0]["product_name"], "廣廣鄉 鼓香朝天椒");
    assert_eq!(l[1]["quantity"], "0.57");
    assert_eq!(l[1]["quantity_unit"], "lb");
    assert_eq!(l[4]["name"], l[3]["name"]);
    assert_eq!(l[4]["amount"], "-0.99");
    assert_eq!(l[4]["discount_target_index"], 3);
    assert_eq!(l[3]["amount_basis"], "net_including_item_discounts");
    assert!(pipeline::arithmetic_difference(&d).is_none(), "{d:#}");
}
#[test]
fn hmart_name_weight_arithmetic_and_whole_tip_label() {
    let d = parse(
        "WT FAGE TOTAL 2% GREE 8.40\n2.81 lb @ 2.99 /lb\nBOK CHOY TIPS 3.00\nTIPS 1.00\nGRATUITIES 0.50\nTOTAL 12.90",
        "H Mart",
    );
    assert_eq!(d["lines"].as_array().unwrap().len(), 4);
    assert_eq!(d["lines"][0]["name"], "FAGE TOTAL 2% GREE");
    assert_eq!(d["lines"][0]["quantity"], "2.81");
    assert!(d["lines"][0]["review_notes"].as_array().unwrap().is_empty());
    assert_eq!(d["lines"][1]["kind"], "product");
    assert_eq!(d["lines"][2]["kind"], "tip");
    let bad = parse("WT FAGE TOTAL 2% GREE 9.40\n2.81 lb @ 2.99 /lb", "H Mart");
    assert!(bad["lines"][0]["review_notes"].to_string().contains("8.40"));
}
#[test]
fn refund_and_footer_policy_are_distinct() {
    let d = parse(include_str!("fixtures/product_refund_ocr.txt"), "Costco");
    assert_eq!(d["total"], "-16.99");
    assert_eq!(d["lines"][0]["amount"], "-16.99");
    let d = parse(
        "E 2338 WHITE PEACH 11.99\nTOTAL 11.99\nRETURN POLICY 30 DAYS",
        "Costco",
    );
    assert_eq!(d["total"], "11.99");
}
#[test]
fn unknown_store_does_not_inherit_costco_sku_rules() {
    let d = parse("2338 WHITE PEACH 11.99\nTOTAL 11.99", "Not Costco");
    assert_eq!(d["lines"][0]["name"], "2338 WHITE PEACH");
    assert!(d["lines"][0]["sku"].is_null());
    assert!(d["store"].is_null());
}
#[test]
fn multiphoto_overlap_preserves_real_repetitions() {
    let pages = [
        json!({"unlimited":"E 1 MILK 3.00\nE 1 MILK 3.00\nAPPLE 1.00\nPEAR 2.00","paddle":{"words":[]}}),
        json!({"unlimited":"APPLE 1.00\nPEAR 2.00\nBANANA 1.00\nTOTAL 10.00","paddle":{"words":[]}}),
    ];
    let d = parsing::parse(&pages, Some("Costco"));
    assert_eq!(d["lines"].as_array().unwrap().len(), 5, "{d:#}");
    pipeline::validate_receipt(&d, 2).unwrap();
}
#[test]
fn all_saved_dual_ocr_pages_have_valid_nonempty_store_parses() {
    let root =
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/backend_api/corpus");
    let index: Value =
        serde_json::from_slice(&std::fs::read(root.join("index.json")).unwrap()).unwrap();
    for c in index["cases"].as_array().unwrap() {
        let id = c["id"].as_str().unwrap();
        let path = root.join(format!(
            "baselines/2026-09-16-comparison/unlimited/{id}.json"
        ));
        if !path.exists() {
            continue;
        }
        let u: Value = serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap();
        let p: Value = serde_json::from_slice(
            &std::fs::read(root.join(format!("baselines/2026-09-16-comparison/ppocrv6/{id}.json")))
                .unwrap(),
        )
        .unwrap();
        let expected: Value = serde_json::from_slice(
            &std::fs::read(root.join(c["expected"].as_str().unwrap())).unwrap(),
        )
        .unwrap();
        let mut decoder =
            image::ImageReader::open(root.join(c["images"][0]["path"].as_str().unwrap()))
                .unwrap()
                .into_decoder()
                .unwrap();
        let (width, height) = decoder.dimensions();
        let orientation = decoder.orientation().unwrap().to_exif();
        let image = if matches!(orientation, 5..=8) {
            (height, width)
        } else {
            (width, height)
        };
        let words:Vec<_>=p["raw"]["rec_texts"].as_array().unwrap().iter().enumerate().map(|(i,text)| {
            let poly=p["raw"]["rec_polys"][i].as_array().unwrap();
            let xs:Vec<_>=poly.iter().map(|v|v[0].as_f64().unwrap()/f64::from(image.0)).collect();
            let ys:Vec<_>=poly.iter().map(|v|v[1].as_f64().unwrap()/f64::from(image.1)).collect();
            json!({"text":text,"confidence":p["raw"]["rec_scores"][i],"box":[xs.iter().copied().fold(1.,f64::min),ys.iter().copied().fold(1.,f64::min),xs.iter().copied().fold(0.,f64::max),ys.iter().copied().fold(0.,f64::max)]})
        }).collect();
        let data = parsing::parse(
            &[json!({"unlimited":u["text"],"paddle":{"words":words}})],
            expected["expected"]["store"].as_str(),
        );
        pipeline::validate_receipt(&data, 1).unwrap_or_else(|e| panic!("{id}: {e:?}"));
        assert!(
            !data["lines"].as_array().unwrap().is_empty(),
            "{id}: {data:#}"
        );
        assert_eq!(
            data["lines"].as_array().unwrap().len(),
            expected["input"]["lines"].as_array().unwrap().len(),
            "{id}: {data:#}"
        );
        assert_eq!(data["total"], expected["input"]["total"], "{id}");
        if id == "5e4547ea" {
            assert_eq!(data["lines"][0]["name"], "FAGE TOTAL 2% GREE");
            assert!(data["lines"][0]["quantity"].is_null());
            assert_eq!(data["lines"][1]["quantity"], "2.81");
            assert_eq!(data["lines"][1]["unit_price"], "2.99");
        }
        if id == "6fe7d01a" {
            assert_eq!(data["lines"][2]["quantity"], "2");
            assert_eq!(data["lines"][2]["quantity_unit"], "count");
            assert_eq!(data["lines"][2]["unit_price"], "1.29");
        }
        if id == "a730a1be" {
            assert_eq!(data["lines"][0]["product_name"], "壇壇鄉豉香朝天椒");
            assert_eq!(data["lines"][4]["discount_target_index"], 3);
            assert_eq!(data["lines"][6]["discount_target_index"], 5);
        }

        println!(
            "rows: {}",
            data["lines"]
                .as_array()
                .unwrap()
                .iter()
                .map(|l| format!("{}:{}", l["name"], l["amount"]))
                .collect::<Vec<_>>()
                .join(", ")
        );
        println!(
            "{id} {}: {} rows vs {} expected, total {} vs {}",
            expected["expected"]["store"],
            data["lines"].as_array().unwrap().len(),
            expected["input"]["lines"].as_array().unwrap().len(),
            data["total"],
            expected["input"]["total"]
        );
    }
}

#[test]
fn costco_prescanned_stars_sku_descriptive_coupon_deposit_and_damaged_subtotal() {
    let raw: Value =
        serde_json::from_str(include_str!("corpus/regressions/e6c62f11.json")).unwrap();
    let d = parse(
        raw["receipt_ocr_evidence"]["primary"].as_str().unwrap(),
        "Costco",
    );
    let lines = d["lines"].as_array().unwrap();
    assert_eq!(lines.len(), 13, "{d:#}");
    assert_eq!(lines[0]["name"], "*BOUNTYADV*");
    assert_eq!(lines[0]["sku"], "1919329");
    assert_eq!(lines[1]["sku"], "2048748");
    assert_eq!(lines[2]["sku"], "2048748");
    assert_eq!(lines[2]["tax_code"], "A");
    assert_eq!(lines[8]["discount_target_index"], 7);
    assert_eq!(lines[8]["sku"], "3610583");
    assert!(!lines[8]["review_notes"].as_array().unwrap().is_empty());
    assert_eq!(lines[11]["kind"], "deposit");
    assert_eq!(d["total"], "154.92");
    assert!(pipeline::arithmetic_difference(&d).is_none(), "{d:#}");
}

#[test]
fn chinese_names_use_paddle_even_when_price_is_on_the_same_row() {
    for (unlimited, paddle) in [("青采 3.00", "青菜 3.00"), ("青采 3.00", "青菜 4.00")] {
        let d = parsing::parse(
            &[
                json!({"unlimited":format!("<|det|>text [100,200,900,250]<|/det|>{unlimited}"), "paddle":{"words":[{"text":paddle,"confidence":0.98,"box":[0.1,0.2,0.9,0.25]}]}}),
            ],
            Some("SkyFoods"),
        );
        assert_eq!(d["lines"][0]["name"], "青菜");
        assert_eq!(
            d["lines"][0]["amount"],
            if paddle.ends_with("4.00") {
                "4.00"
            } else {
                "3.00"
            }
        );
        assert!(d["lines"][0]["review_notes"].to_string().contains("PP-OCR"));
    }
}

#[test]
fn ranch_header_time_and_following_weight_are_store_specific() {
    let text = "37-11 Main St\nFlushing,NY\n7185718899\n#1607-002 8/17/2026 16:08:07 Jing Xu\nAPPLE $7.92 F\n2.65 lb @ $2.99/lb\nPEAR $1.00 F\nTOTAL $8.92\nItem count 2\n08/17/2026 16:08:04";
    for store in ["99 Ranch", "99 Ranch Market", "99Ranch"] {
        let d = parse(text, store);
        assert_eq!(parsing::profile(Some(store)), "ranch99");
        assert_eq!(d["local_time"], "2026-08-17T16:08:07");
        assert_eq!(d["lines"].as_array().unwrap().len(), 2);
        assert_eq!(d["lines"][0]["quantity"], "2.65");
        assert_eq!(d["lines"][0]["quantity_unit"], "lb");
        assert_eq!(d["lines"][0]["unit_price"], "2.99");
        assert!(d["lines"][1]["quantity"].is_null());
    }
    assert!(parse(text, "Unknown")["local_time"].is_null());
    let bad = parse(&text.replace("APPLE $7.92", "APPLE $8.92"), "99 Ranch");
    assert!(bad["lines"][0]["review_notes"].to_string().contains("7.92"));
}

#[test]
fn ranch_missing_header_never_uses_footer_or_forward_weight() {
    let d = parse(
        "2.65 lb @ $2.99/lb\nAPPLE $7.92 F\nTOTAL $7.92\nItem count 1\n08/17/2026 16:08:04\n1.00 lb @ $1.00/lb",
        "99 Ranch",
    );
    assert!(d["local_time"].is_null());
    assert!(d["lines"][0]["quantity"].is_null());
}

#[test]
fn ranch_multiphoto_header_and_weight_continuation() {
    let pages = [
        json!({"unlimited":"7185718899\n08/17/2026 16:08:07\nAPPLE $7.92 F","paddle":{"words":[]}}),
        json!({"unlimited":"2.65 lb @ $2.99/lb\nTOTAL $7.92\nItem count 1\n08/17/2026 16:08:04","paddle":{"words":[]}}),
    ];
    let d = parsing::parse(&pages, Some("99 Ranch"));
    pipeline::validate_receipt(&d, 2).unwrap();
    assert_eq!(d["local_time"], "2026-08-17T16:08:07");
    assert_eq!(d["lines"][0]["quantity"], "2.65");
}

#[test]
fn ranch_saved_dual_outputs_use_header_time_and_real_weights() {
    let report: Value = serde_json::from_str(include_str!(
        "corpus/baselines/2026-09-17-corrected-dual-ocr/report.json"
    ))
    .unwrap();
    for (prefix, time) in [
        ("2f97fc50", "2026-07-29T18:37:41"),
        ("1b072114", "2026-08-17T16:08:07"),
    ] {
        let c = report["cases"]
            .as_array()
            .unwrap()
            .iter()
            .find(|c| c["id"].as_str().unwrap().starts_with(prefix))
            .unwrap();
        let d = parsing::parse(c["ocr"]["pages"].as_array().unwrap(), Some("99 Ranch"));
        pipeline::validate_receipt(&d, 1).unwrap();
        assert_eq!(d["local_time"], time);
        if prefix == "1b072114" {
            for (name, quantity, price) in [
                ("RED ONION", "0.78", "1.69"),
                ("LONG HOT PEPPER", "0.63", "1.99"),
                ("ENVY APPLE", "2.53", "2.99"),
                ("CHIVES", "0.69", "2.99"),
            ] {
                let line = d["lines"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .find(|l| l["name"] == name)
                    .unwrap();
                assert_eq!(line["quantity"], quantity);
                assert_eq!(line["unit_price"], price);
                assert_eq!(line["quantity_unit"], "lb");
            }
        }
    }
}

#[test]
fn hualian_product_blocks_keep_multilingual_continuations_and_weights() {
    let d = parse(
        "HUALIAN\n  2.65 lb @ $2.99/lb\nAPPLE $7.92\n苹果\n红富士\nMILK $3.00\nWhole milk\nLait entier\n  pack detail 2.00\nTOTAL $10.92\nTHANK YOU\nfooter text",
        "Hualian",
    );
    let lines = d["lines"].as_array().unwrap();
    assert_eq!(lines.len(), 2, "{d:#}");
    assert_eq!(lines[0]["name"], "APPLE");
    assert_eq!(lines[0]["product_name"], "苹果 红富士");
    assert_eq!(lines[0]["quantity"], "2.65");
    assert_eq!(lines[0]["unit_price"], "2.99");
    assert_eq!(lines[1]["name"], "MILK");
    assert_eq!(
        lines[1]["product_name"],
        "Whole milk Lait entier pack detail 2.00"
    );
    assert_eq!(d["total"], "10.92");
}

#[test]
fn hualian_geometry_indentation_and_paddle_chinese_survive_layout_fusion() {
    let pages = [
        json!({"unlimited":"<|det|>text [150,75,700,95]<|/det|>2.65 lb @ $2.99/lb\n<|det|>text [100,100,900,120]<|/det|>APPLE 7.92\n<|det|>text [100,125,400,145]<|/det|>wrong name\n<|det|>text [150,150,800,170]<|/det|>detail 2.00\n<|det|>text [100,200,900,220]<|/det|>MILK 3.00\n<|det|>text [150,225,900,245]<|/det|>TOTAL 10.92","paddle":{"words":[{"text":"苹果","confidence":0.99,"box":[0.1,0.125,0.4,0.145]}]}}),
    ];
    let d = parsing::parse(&pages, Some("Hualian"));
    pipeline::validate_receipt(&d, 1).unwrap();
    assert_eq!(d["lines"].as_array().unwrap().len(), 2, "{d:#}");
    assert_eq!(d["lines"][0]["product_name"], "苹果 detail 2.00");
    assert_eq!(d["lines"][0]["quantity"], "2.65");
    assert_eq!(d["total"], "10.92");
}

#[test]
fn hualian_multiphoto_continuations_and_other_store_isolation() {
    let pages = [
        json!({"unlimited":"APPLE 3.00\n苹果\n  2.65 lb @ $2.99/lb","paddle":{"words":[]}}),
        json!({"unlimited":"MILK 7.92\nWhole milk\nTOTAL 10.92","paddle":{"words":[]}}),
    ];
    let d = parsing::parse(&pages, Some("Hualian"));
    assert_eq!(d["lines"].as_array().unwrap().len(), 2);
    assert_eq!(d["lines"][0]["product_name"], "苹果");
    assert!(d["lines"][0]["quantity"].is_null());
    assert_eq!(d["lines"][1]["quantity"], "2.65");
    let other = parse("MILK 3.00\nWhole milk\nTOTAL 3.00", "Unknown");
    assert!(other["lines"][0]["product_name"].is_null());
    let bad = parse("  2.65 lb @ $2.99/lb\nAPPLE 8.92\nTOTAL 8.92", "Hualian");
    assert!(bad["lines"][0]["review_notes"].to_string().contains("7.92"));
}

#[test]
fn hualian_saved_dual_ocr_preserves_latin_and_chinese_product_names() {
    let fixture: Value =
        serde_json::from_str(include_str!("fixtures/hualian_fe3a7e41_ocr.json")).unwrap();
    let d = parsing::parse(fixture["pages"].as_array().unwrap(), Some("Hualian"));
    pipeline::validate_receipt(&d, 1).unwrap();
    let lines = d["lines"].as_array().unwrap();
    assert_eq!(lines.len(), 7, "{d:#}");
    assert_eq!(lines[0]["name"], "FAGE GREEK STRAINED YOGURT");
    assert_eq!(lines[0]["product_name"], "2% MILK FAT");
    assert_eq!(lines[4]["product_name"], "OZBLU BLUEBERRIES BLUETS");
    assert_eq!(lines[5]["product_name"], "高麗菜");
    for i in [1, 2, 3, 5] {
        assert!(
            !lines[i]["review_notes"]
                .to_string()
                .contains("中文采用 PP-OCR")
        );
    }
    assert_eq!(lines[6]["kind"], "tax");
    assert_eq!(d["total"], "27.25");
    for (i, q, price) in [
        (2, "0.50", "3.99"),
        (3, "0.76", "4.49"),
        (5, "2.69", "0.69"),
    ] {
        assert_eq!(lines[i]["quantity"], q);
        assert_eq!(lines[i]["unit_price"], price);
        assert!(
            !lines[i]["review_notes"]
                .to_string()
                .contains("重量 × 单价应为")
        );
    }
    for i in [0, 1, 4] {
        assert!(lines[i]["quantity"].is_null());
    }
}

#[test]
fn hualian_dangling_weight_does_not_change_previous_product_or_cross_totals() {
    let d = parse(
        "MILK 3.00\nWhole milk\n  2.65 lb @ $2.99/lb\nTOTAL 3.00\n  1.00 lb @ $1.00/lb",
        "Hualian",
    );
    assert_eq!(d["lines"].as_array().unwrap().len(), 1);
    assert!(d["lines"][0]["quantity"].is_null());
    assert_eq!(d["lines"][0]["product_name"], "Whole milk");
}

#[test]
fn traditional_paddle_disagreements_are_silent_for_every_store_but_simplified_are_not() {
    for store in [
        "Hualian", "99 Ranch", "SkyFoods", "H Mart", "Costco", "Unknown",
    ] {
        for (paddle, warning) in [
            ("高麗菜 3.00", false),
            ("恒順香醋六年陳 3.00", false),
            ("恒顺香醋六年陈 3.00", true),
            ("高丽菜 3.00", true),
            ("華联菜 3.00", true),
            ("青菜 3.00", true),
        ] {
            let d = parsing::parse(
                &[
                    json!({"unlimited":"<|det|>text [100,200,900,250]<|/det|>wrong 3.00","paddle":{"words":[{"text":paddle,"confidence":0.98,"box":[0.1,0.2,0.9,0.25]}]}}),
                ],
                Some(store),
            );
            assert_eq!(d["lines"][0]["name"], paddle.trim_end_matches(" 3.00"));
            assert_eq!(
                d["lines"][0]["review_notes"]
                    .to_string()
                    .contains("文字不一致"),
                warning,
                "{store} {paddle}: {d:#}"
            );
        }
    }
}

#[test]
fn traditional_common_characters_use_page_context_and_keep_other_warnings() {
    let page = |name: &str, amount: &str, confidence: f64| json!({"unlimited":"<|det|>text [100,50,400,80]<|/det|>header\n<|det|>text [100,200,900,250]<|/det|>wrong 3.00","paddle":{"words":[{"text":"華聯超市","confidence":0.99,"box":[0.1,0.05,0.4,0.08]},{"text":format!("{name} {amount}"),"confidence":confidence,"box":[0.1,0.2,0.9,0.25]}]}});
    let d = parsing::parse(&[page("韭菜", "3.00", 0.98)], Some("Hualian"));
    assert!(
        !d["lines"][0]["review_notes"]
            .to_string()
            .contains("文字不一致")
    );
    let d = parsing::parse(&[page("高丽菜", "3.00", 0.98)], Some("Hualian"));
    assert!(
        d["lines"][0]["review_notes"]
            .to_string()
            .contains("文字不一致")
    );
    let d = parsing::parse(&[page("高麗菜", "4.00", 0.5)], Some("Hualian"));
    let notes = d["lines"][0]["review_notes"].to_string();
    assert!(!notes.contains("文字不一致"));
    assert!(notes.contains("金额不一致") && notes.contains("置信度低"));
}

#[test]
fn chinese_continuation_disagreement_policy_reaches_every_product() {
    for store in [
        "Hualian", "99 Ranch", "SkyFoods", "H Mart", "Costco", "Unknown",
    ] {
        for (paddle, warning) in [("高麗菜", false), ("高丽菜", true)] {
            let d = parsing::parse(
                &[
                    json!({"unlimited":"<|det|>text [100,100,900,150]<|/det|>CABBAGE 3.00\n<|det|>text [100,200,600,250]<|/det|>高菜","paddle":{"words":[{"text":paddle,"confidence":0.98,"box":[0.1,0.2,0.6,0.25]}]}}),
                ],
                Some(store),
            );
            assert_eq!(d["lines"][0]["product_name"], paddle);
            assert_eq!(
                d["lines"][0]["review_notes"]
                    .to_string()
                    .contains("文字不一致"),
                warning,
                "{store}: {d:#}"
            );
        }
    }
}

#[test]
fn costco_c00860de_splits_glued_sku_without_losing_org() {
    let pages: Vec<Value> =
        serde_json::from_str(include_str!("fixtures/costco_c00860de_ocr.json")).unwrap();
    let d = parsing::parse(&pages, Some("Costco"));
    pipeline::validate_receipt(&d, 1).unwrap();
    assert_eq!(d["lines"][0]["sku"], "1062201");
    assert_eq!(d["lines"][0]["name"], "ORG EDAMAME");
    assert_eq!(d["lines"][0]["amount"], "14.99");
    assert_eq!(d["total"], "100.19");
    assert_eq!(d["lines"].as_array().unwrap().len(), 9);
    assert!(pipeline::arithmetic_difference(&d).is_none());
    for (text, sku, name, tax) in [
        ("1062201ORG EDAMAME", "1062201", "ORG EDAMAME", None),
        ("E 1062201ORG EDAMAME", "1062201", "ORG EDAMAME", Some("E")),
        ("E 2338 WHITE PEACH", "2338", "WHITE PEACH", Some("E")),
        ("2338 WHITE PEACH", "2338", "WHITE PEACH", None),
        ("123456 3M TAPE", "123456", "3M TAPE", None),
    ] {
        let d = parse(
            &format!("{text} 14.99\n123 / {sku} 2.00-\nTOTAL 12.99"),
            "Costco",
        );
        assert_eq!(d["lines"][0]["sku"], sku);
        assert_eq!(d["lines"][0]["name"], name);
        assert_eq!(d["lines"][0]["tax_code"].as_str(), tax);
        assert_eq!(d["lines"][1]["sku"], sku);
        assert_eq!(d["lines"][1]["discount_target_index"], 0);
    }
    let generic = parse("1062201ORG EDAMAME 14.99\nTOTAL 14.99", "Unknown Market");
    assert!(generic["lines"][0]["sku"].is_null());
    assert_eq!(generic["lines"][0]["name"], "1062201ORG EDAMAME");
}

#[test]
fn skyfoods_indented_weight_and_promotion_blocks_real_receipt() {
    let pages: Vec<Value> =
        serde_json::from_str(include_str!("corpus/regressions/834a4c6e.json")).unwrap();
    let d = parsing::parse(&pages, Some("skyFOODS"));
    pipeline::validate_receipt(&d, 1).unwrap();
    let lines = d["lines"].as_array().unwrap();
    assert_eq!(lines.len(), 11, "{d:#}");
    assert_eq!(d["total"], "56.48");
    for (index, name, amount, quantity) in [
        (1, "TAIWAN CABBAGE (1POUNDS)", "2.58", "3.80"),
        (2, "BROWN POTATO (1POUNDS)", "1.11", "1.12"),
        (3, "LONG HOT PEPPER (1POUNDS)", "2.87", "0.96"),
        (4, "OREO COOKIES MATCHA FLAGS FLAVOR-L", "9.98", "2"),
    ] {
        assert_eq!(lines[index]["name"], name, "{d:#}");
        assert_eq!(lines[index]["amount"], amount);
        assert_eq!(lines[index]["quantity"], quantity);
    }
    assert_eq!(lines[1]["product_name"], "台灣高麗菜（1磅）");
    assert_eq!(lines[2]["product_name"], "黃土豆（1磅）");
    assert!(pipeline::arithmetic_difference(&d).is_none(), "{d:#}");
}

#[test]
fn costco_recovers_damaged_price_from_second_ocr_without_deduplicating_rugs() {
    let pages: Vec<Value> =
        serde_json::from_str(include_str!("corpus/regressions/57bb2995.json")).unwrap();
    let d = parsing::parse(&pages, Some("Costco"));
    pipeline::validate_receipt(&d, 1).unwrap();
    let lines = d["lines"].as_array().unwrap();
    assert_eq!(lines.len(), 7, "{d:#}");
    assert_eq!(lines[0]["sku"], "1881581");
    assert_eq!(lines[1]["sku"], "1881581");
    assert_eq!(lines[0]["amount"], "19.99");
    assert_eq!(d["total"], "186.11");
    assert!(d["local_time"].is_null()); // Conflicting OCR dates still require review.
    assert!(pipeline::arithmetic_difference(&d).is_none(), "{d:#}");
}

#[test]
fn skyfoods_indented_blocks_do_not_steal_previous_weight_or_cross_photos() {
    let d = parse(
        "1 APPLE 1.00\n  苹果\n2.00 lb @ $3.00/lb $6.00 F\n  PEARS\n  梨\n2 @ 1/$4.00 $8.00 F\n  COOKIES\n  饼干\nTOTAL 15.00",
        "SkyFoods",
    );
    assert_eq!(d["lines"].as_array().unwrap().len(), 3);
    assert_eq!(d["lines"][0]["quantity"], "1");
    assert_eq!(d["lines"][1]["name"], "PEARS");
    assert_eq!(d["lines"][1]["product_name"], "梨");
    assert_eq!(d["lines"][1]["unit_price"], "3.00");
    assert_eq!(d["lines"][2]["name"], "COOKIES");
    assert_eq!(d["lines"][2]["quantity"], "2");
    assert!(pipeline::arithmetic_difference(&d).is_none());
    let pages = [
        json!({"unlimited":"2.00 lb @ $3.00/lb $6.00 F"}),
        json!({"unlimited":"  PEARS\n1 MILK 4.00"}),
    ];
    let d = parsing::parse(&pages, Some("SkyFoods"));
    assert_ne!(d["lines"][0]["name"], "PEARS");
}
