use axum::{
    Json, Router,
    body::{Body, to_bytes},
    http::Request,
    routing::{get, post},
};
use receipt_backend_api::{State, application, config::Config};
use serde_json::{Value, json};
use std::sync::{Arc, Mutex};
use tower::ServiceExt;
const KEY: &str = "synthetic-test-key-not-a-real-secret";
fn schema() -> Value {
    serde_json::from_str(include_str!("receipt_schema.json")).unwrap()
}
fn body() -> Value {
    use base64::Engine;
    let mut bytes = std::io::Cursor::new(Vec::new());
    image::DynamicImage::new_rgb8(16, 16)
        .write_to(&mut bytes, image::ImageFormat::Png)
        .unwrap();
    json!({"model":"test-vision","store":false,"messages":[{"role":"user","content":[{"type":"image_url","image_url":{"url":format!("data:image/png;base64,{}",base64::engine::general_purpose::STANDARD.encode(bytes.into_inner()))}}]}],"response_format":{"type":"json_schema","json_schema":{"name":"receipt","strict":true,"schema":schema()}}})
}
#[derive(Default)]
struct Mock {
    calls: Vec<Value>,
    events: Vec<String>,
    bad_json: bool,
    finish: bool,
    arithmetic_failures: usize,
    fail: bool,
    logo_id: Option<String>,
    logo_delay_ms: u64,
    delay_ms: u64,
}
struct Fixture {
    app: Router,
    mock: Arc<Mutex<Mock>>,
    dir: tempfile::TempDir,
    task: tokio::task::JoinHandle<()>,
}
impl Drop for Fixture {
    fn drop(&mut self) {
        self.task.abort();
    }
}
async fn fixture() -> Fixture {
    let mock = Arc::new(Mutex::new(Mock::default()));
    let m = mock.clone();
    let h = mock.clone();
    let engine=Router::new().route("/health",get(move||{let h=h.clone();async move{if h.lock().unwrap().fail{axum::http::StatusCode::SERVICE_UNAVAILABLE}else{axum::http::StatusCode::OK}}})).route("/v1/ocr/recognize",post(move|Json(v):Json<Value>|{let m=m.clone();async move{
 let (response, delay) = {
 let mut m=m.lock().unwrap();m.calls.push(v.clone());m.events.push("ocr".into());
 let count=v["messages"][0]["content"].as_array().unwrap().len();
 let total=if m.arithmetic_failures>0 {"6.50"}else{"5.50"};
 let text=format!("<|det|>title [50,20,950,150]<|/det|>LOGO\n<|det|>text [50,200,950,500]<|/det|>MILK 3.00\nMILK 3.00\nCOUPON -0.50\nTOTAL {total}");
 let pages:Vec<_>=(0..count).map(|_|json!({"unlimited":text,"paddle":{"words":[]}})).collect();
 ((if m.fail || m.finish {axum::http::StatusCode::SERVICE_UNAVAILABLE}else{axum::http::StatusCode::OK},Json(if m.bad_json {json!({})}else{json!({"pages":pages,"usage":{"prompt_tokens":10,"completion_tokens":20,"total_tokens":30}})})),m.delay_ms)
 };
 tokio::time::sleep(std::time::Duration::from_millis(delay)).await;
 response
 }}));
    let logo_mock = mock.clone();
    let engine = engine.route("/v1/logo/match",post(move |Json(v):Json<Value>| {
        let logo_mock=logo_mock.clone();
        async move {
            let (scores,delay)={
                let mut m=logo_mock.lock().unwrap();
                m.events.push("logo".into());
                let scores=v["references"].as_array().unwrap().iter().map(|r|json!({"id":r["id"],"score":if r["id"].as_str()==m.logo_id.as_deref(){0.95}else{0.01},"evidence":1.0})).collect::<Vec<_>>();
                (scores,m.logo_delay_ms)
            };
            tokio::time::sleep(std::time::Duration::from_millis(delay)).await;
            Json(json!({"model":receipt_backend_api::logos::MATCH_MODEL,"scores":scores}))
        }
    }));
    let engine = engine.layer(axum::extract::DefaultBodyLimit::max(80 * 1024 * 1024));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let task = tokio::spawn(async move {
        axum::serve(listener, engine).await.unwrap();
    });
    let dir = tempfile::tempdir().unwrap();
    let mut c = Config::parse(include_str!("../../playground/backend_api/config.yaml")).unwrap();
    c.ocr.url = format!("http://127.0.0.1:{port}");
    c.ocr.model = "ocr".into();
    c.served_model = "test-vision".into();
    c.apk_path = dir.path().join("receipt_master.apk");
    c.data_dir = dir.path().join("data");
    receipt_backend_api::db::Store::initialize(&c.data_dir).unwrap();
    Fixture {
        app: application(State::new(c, KEY).unwrap()),
        mock,
        dir,
        task,
    }
}
async fn request(
    f: &Fixture,
    method: &str,
    path: &str,
    body: Option<Value>,
    auth: bool,
) -> (u16, Value) {
    let mut b = Request::builder()
        .method(method)
        .uri(path)
        .header("content-type", "application/json");
    if auth {
        b = b.header("authorization", format!("Bearer {KEY}"));
    }
    let response = f
        .app
        .clone()
        .oneshot(
            b.body(Body::from(body.map(|v| v.to_string()).unwrap_or_default()))
                .unwrap(),
        )
        .await
        .unwrap();
    let status = response.status().as_u16();
    let bytes = to_bytes(response.into_body(), usize::MAX).await.unwrap();
    (status, serde_json::from_slice(&bytes).unwrap())
}
#[tokio::test]
async fn mobile_round_trip() {
    let f = fixture().await;
    let (status, v) = request(&f, "POST", "/v1/chat/completions", Some(body()), true).await;
    assert_eq!(status, 200, "{v}");
    let parsed: Value =
        serde_json::from_str(v["choices"][0]["message"]["content"].as_str().unwrap()).unwrap();
    assert_eq!(
        parsed["lines"]
            .as_array()
            .unwrap()
            .iter()
            .map(|l| l["amount"].as_str().unwrap())
            .collect::<Vec<_>>(),
        vec!["3.00", "3.00", "-0.50"]
    );
    assert_eq!(v["usage"]["total_tokens"], 30);
    let calls = &f.mock.lock().unwrap().calls;
    assert_eq!(calls.len(), 1);
    assert!(calls[0]["response_format"].is_null());
    assert!(
        calls[0]["messages"]
            .to_string()
            .contains("data:image/png;base64,")
    );
}
#[tokio::test]
async fn store_alias_routes_only_its_parser() {
    let f = fixture().await;
    for (store, profile) in [
        (Value::Null, "generic"),
        (json!("Unknown Market"), "generic"),
        (json!("Not Costco"), "generic"),
        (json!(" COSTCO Wholesale "), "costco"),
        (json!("skyFOODS"), "skyfoods"),
        (json!("Sky Foods"), "skyfoods"),
        (json!("H-Mart"), "hmart"),
    ] {
        let mut b = body();
        b["receipt_context"] = json!({"known_store":store});
        // Mentioning a merchant in unstructured text must not switch profiles.
        b["messages"][0]["content"]
            .as_array_mut()
            .unwrap()
            .push(json!({"type":"text","text":"Costco SkyFoods H Mart"}));
        let (status, result) = request(&f, "POST", "/v1/chat/completions", Some(b), true).await;
        assert_eq!(status, 200, "{result}");
        assert_eq!(result["receipt_parsing"]["profile"], profile);
        assert!(f.mock.lock().unwrap().calls.last().unwrap()["response_format"].is_null());
    }
    for context in [json!("Costco"), json!({"known_store":42})] {
        let mut b = body();
        b["receipt_context"] = context;
        assert_eq!(
            request(&f, "POST", "/v1/chat/completions", Some(b), true)
                .await
                .0,
            400
        );
    }
}

#[tokio::test]
async fn invalid_requests_never_run_inference() {
    let f = fixture().await;
    assert_eq!(
        request(&f, "POST", "/v1/chat/completions", Some(body()), false)
            .await
            .0,
        401
    );
    for change in 0..6 {
        let mut b = body();
        match change {
            0 => b["model"] = json!("other"),
            1 => b["stream"] = json!(true),
            2 => {
                b["messages"][0]["content"][0]["image_url"]["url"] =
                    json!("http://169.254.169.254/a")
            }
            3 => {
                b["messages"][0]["content"][0]["image_url"]["url"] =
                    json!("data:image/jpeg;base64,aaaa")
            }
            4 => {
                b["response_format"]["json_schema"]["schema"] =
                    json!({"$ref":"https://example.com/schema"})
            }
            _ => {
                let part = b["messages"][0]["content"][0].clone();
                b["messages"][0]["content"] = json!(vec![part; 17]);
            }
        }
        assert!(
            [400, 404].contains(
                &request(&f, "POST", "/v1/chat/completions", Some(b), true)
                    .await
                    .0
            )
        );
    }
    assert!(f.mock.lock().unwrap().calls.is_empty());
}
#[tokio::test]
async fn inference_failures_and_readiness() {
    let f = fixture().await;
    assert_eq!(request(&f, "GET", "/health", None, false).await.0, 200);
    f.mock.lock().unwrap().finish = true;
    let (s, v) = request(&f, "POST", "/v1/chat/completions", Some(body()), true).await;
    assert_eq!(s, 502);
    assert_eq!(v["error"]["code"], "inference_error");
    assert_eq!(f.mock.lock().unwrap().calls.len(), 1);
    {
        let mut m = f.mock.lock().unwrap();
        m.finish = false;
        m.bad_json = true;
    }
    assert_eq!(
        request(&f, "POST", "/v1/chat/completions", Some(body()), true)
            .await
            .0,
        502
    );
    f.mock.lock().unwrap().fail = true;
    assert_eq!(request(&f, "GET", "/health", None, false).await.0, 200);
    assert_eq!(
        request(&f, "GET", "/api/v1/recognition/readiness", None, true)
            .await
            .0,
        503
    );
    assert_eq!(
        request(&f, "POST", "/v1/chat/completions", Some(body()), true)
            .await
            .0,
        502
    );
}
#[tokio::test]
async fn raw_ocr() {
    let f = fixture().await;
    let mut b = body();
    b.as_object_mut().unwrap().remove("response_format");
    assert_eq!(
        request(&f, "POST", "/v1/chat/completions", Some(b), true)
            .await
            .0,
        200
    );
    assert_eq!(f.mock.lock().unwrap().calls.len(), 1);
}
#[tokio::test]
async fn public_apk_download_and_auth() {
    let f = fixture().await;
    std::fs::write(
        f.dir.path().join("receipt_master.apk"),
        b"synthetic-apk-content",
    )
    .unwrap();
    for (method, range, status, expected) in [
        ("GET", None, 200, &b"synthetic-apk-content"[..]),
        ("HEAD", None, 200, &b""[..]),
        ("GET", Some("bytes=0-8"), 206, &b"synthetic"[..]),
    ] {
        let mut req = Request::builder().method(method).uri("/receipt_master.apk");
        if let Some(range) = range {
            req = req.header("range", range);
        }
        let r = f
            .app
            .clone()
            .oneshot(req.body(Body::empty()).unwrap())
            .await
            .unwrap();
        assert_eq!(r.status().as_u16(), status);
        assert_eq!(
            r.headers()["content-type"],
            "application/vnd.android.package-archive"
        );
        assert_eq!(r.headers()["cache-control"], "no-store");
        assert_eq!(
            &to_bytes(r.into_body(), usize::MAX).await.unwrap()[..],
            expected
        );
    }
    assert_eq!(request(&f, "GET", "/v1/models", None, false).await.0, 401);
    assert_eq!(request(&f, "GET", "/v1/models", None, true).await.0, 200);
    std::fs::remove_file(f.dir.path().join("receipt_master.apk")).unwrap();
    assert_eq!(
        request(&f, "GET", "/receipt_master.apk", None, false)
            .await
            .0,
        404
    );
}
#[test]
fn config_validation() {
    let text = include_str!("../../playground/backend_api/config.yaml");
    assert!(Config::parse(text).is_ok());
    assert!(Config::parse("").is_err());
    assert!(Config::parse(&text.replace("max_images: 16", "max_images: 0")).is_err());
}

#[test]
fn schema_property_order_is_preserved_for_generation() {
    // This is part of the inference input: name before kind gives the model context
    // to classify a row and avoids reordering existing client schemas during migration.
    let schema: Value=serde_json::from_str(r#"{"properties":{"name":{"type":"string"},"kind":{"type":"string"},"amount":{"type":"string"}}}"#).unwrap();
    let round_trip: Value = serde_json::from_str(&serde_json::to_string(&schema).unwrap()).unwrap();
    assert_eq!(
        round_trip["properties"]
            .as_object()
            .unwrap()
            .keys()
            .map(String::as_str)
            .collect::<Vec<_>>(),
        vec!["name", "kind", "amount"]
    );
}

#[tokio::test]
async fn update_manifest_and_immutable_download_are_public_and_scoped() {
    let f = fixture().await;
    std::fs::write(
        f.dir.path().join("android-update.json"),
        r#"{"schema_version":1}"#,
    )
    .unwrap();
    assert_eq!(
        request(&f, "GET", "/android-update.json", None, false)
            .await
            .0,
        200
    );
    std::fs::create_dir(f.dir.path().join("updates")).unwrap();
    let name = format!("{}.apk", "a".repeat(64));
    std::fs::write(f.dir.path().join("updates").join(&name), b"immutable-apk").unwrap();
    let response = f
        .app
        .clone()
        .oneshot(
            Request::builder()
                .uri(format!("/updates/{name}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), 200);
    assert_eq!(
        &to_bytes(response.into_body(), usize::MAX).await.unwrap()[..],
        b"immutable-apk"
    );
    assert_eq!(
        request(&f, "GET", "/updates/secrets.json", None, false)
            .await
            .0,
        404
    );
    assert_eq!(request(&f, "GET", "/v1/models", None, false).await.0, 401);
}

fn domain_receipt() -> Value {
    json!({"id":uuid::Uuid::new_v4().to_string(),"store":"API TEST","branch":"","address":"","country":"US","currency":"USD","timeSource":"user_entered","rawTime":"","totalSource":"user_entered","occurredAt":1780000000000i64,"createdAt":1,"revision":0,"totalMinor":550,"posted":false,"lines":[]})
}
#[tokio::test]
async fn data_api_auth_idempotency_and_conflict() {
    let f = fixture().await;
    let r = domain_receipt();
    let body = json!({"request_key":"create-1","input":{"receipt":r}});
    assert_eq!(
        request(
            &f,
            "POST",
            "/api/v1/receipts/save",
            Some(body.clone()),
            false
        )
        .await
        .0,
        401
    );
    let (status, created) = request(
        &f,
        "POST",
        "/api/v1/receipts/save",
        Some(body.clone()),
        true,
    )
    .await;
    assert_eq!(status, 200, "{created}");
    assert_eq!(
        request(
            &f,
            "POST",
            "/api/v1/receipts/save",
            Some(body.clone()),
            true
        )
        .await
        .1,
        created
    );
    let mut stale = body.clone();
    stale["request_key"] = json!("stale");
    assert_eq!(
        request(&f, "POST", "/api/v1/receipts/save", Some(stale), true)
            .await
            .0,
        409
    );
    let mut wrong = body;
    wrong["input"]["receipt"]["store"] = json!("Different");
    assert_eq!(
        request(&f, "POST", "/api/v1/receipts/save", Some(wrong), true)
            .await
            .0,
        409
    );
    let list = request(
        &f,
        "POST",
        "/api/v1/receipts/list",
        Some(json!({"request_key":null,"input":{"trash":false}})),
        true,
    )
    .await
    .1;
    assert_eq!(list["data"]["items"].as_array().unwrap().len(), 1);
    assert_eq!(
        request(&f, "GET", "/api/v1/media/not-present", None, false)
            .await
            .0,
        401
    );
}
#[tokio::test]
async fn persistent_job_auto_applies_without_client_polling_or_apply() {
    let f = fixture().await;
    let s = receipt_backend_api::db::Store::open(&f.dir.path().join("data")).unwrap();
    let r = s.transaction(|| s.save(domain_receipt(), false)).unwrap();
    let mut image = std::io::Cursor::new(Vec::new());
    image::DynamicImage::new_rgb8(30, 50)
        .write_to(&mut image, image::ImageFormat::Png)
        .unwrap();
    s.transaction(|| {
        s.upload(
            &json!({"receipt_id":r["id"],"expected_version":1}),
            image.get_ref(),
        )
    })
    .unwrap();
    s.transaction(|| {
        s.upload(
            &json!({"receipt_id":r["id"],"expected_version":2}),
            image.get_ref(),
        )
    })
    .unwrap();
    drop(s);
    let (status,started)=request(&f,"POST","/api/v1/recognition/start",Some(json!({"request_key":"job-1","input":{"receipt_id":r["id"],"expected_version":3,"zone":"America/New_York"}})),true).await;
    assert_eq!(status, 200, "{started}");
    let job_id = started["data"]["job_id"].clone();
    let mut done = false;
    for _ in 0..100 {
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        let job = request(
            &f,
            "POST",
            "/api/v1/recognition/get",
            Some(json!({"input":{"id":job_id}})),
            true,
        )
        .await
        .1;
        if job["data"]["status"] == "applied" {
            done = true;
            break;
        }
        assert_ne!(job["data"]["status"], "failed", "{job}");
    }
    assert!(done);
    assert_eq!(
        f.mock
            .lock()
            .unwrap()
            .calls
            .iter()
            .filter(|v| v["model"] == "ocr")
            .count(),
        2
    );
    let s = receipt_backend_api::db::Store::open(&f.dir.path().join("data")).unwrap();
    let mut current = s.load(r["id"].as_str().unwrap()).unwrap();
    assert_eq!(current["lines"].as_array().unwrap().len(), 3);
    assert_eq!(
        s.rows(
            "SELECT image_id FROM receipt_image WHERE receipt_id=?",
            &[r["id"].clone()]
        )
        .unwrap()
        .len(),
        2
    );
    assert_eq!(
        s.rows(
            "SELECT run_id FROM recognition_run WHERE receipt_id=? AND status='succeeded'",
            &[r["id"].clone()]
        )
        .unwrap()
        .len(),
        1
    );
    current["store"] = json!("User edit after recognition");
    s.transaction(|| s.save(current, false)).unwrap();
    drop(s);
    assert_eq!(
        request(
            &f,
            "POST",
            "/api/v1/recognition/apply",
            Some(json!({"request_key":"apply-1","input":{"id":job_id}})),
            true
        )
        .await
        .0,
        200
    );
    let s = receipt_backend_api::db::Store::open(&f.dir.path().join("data")).unwrap();
    assert_eq!(
        s.load(r["id"].as_str().unwrap()).unwrap()["store"],
        "User edit after recognition"
    );
}

#[tokio::test]
async fn clients_cannot_configure_ocr_or_pricing() {
    let f = fixture().await;
    let (status, reply) = request(
        &f,
        "POST",
        "/api/v1/config/get",
        Some(json!({"input":{}})),
        true,
    )
    .await;
    assert_eq!(status, 200);
    assert_eq!(reply["data"], json!({"weight_unit":"kg"}));
    for (component, input) in [
        (
            "config",
            json!({"expected_version":0,"input_rate_micros":0,"output_rate_micros":0}),
        ),
        ("budgets", json!({"expected_version":0,"amount":1})),
    ] {
        let (status, _) = request(
            &f,
            "POST",
            &format!("/api/v1/{component}/save"),
            Some(json!({"request_key":uuid::Uuid::new_v4().to_string(),"input":input})),
            true,
        )
        .await;
        assert_eq!(status, 404);
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn two_jobs_are_queued_serially_and_receipt_queries_remain_responsive() {
    let f = fixture().await;
    f.mock.lock().unwrap().delay_ms = 1000;
    let s = receipt_backend_api::db::Store::open(&f.dir.path().join("data")).unwrap();
    let mut photo = std::io::Cursor::new(Vec::new());
    image::DynamicImage::new_rgb8(30, 50)
        .write_to(&mut photo, image::ImageFormat::Png)
        .unwrap();
    let mut receipts = vec![];
    for _ in 0..2 {
        let mut input = domain_receipt();
        input["id"] = json!(uuid::Uuid::new_v4().to_string());
        let r = s.transaction(|| s.save(input, false)).unwrap();
        s.transaction(|| {
            s.upload(
                &json!({"receipt_id":r["id"],"expected_version":1}),
                photo.get_ref(),
            )
        })
        .unwrap();
        receipts.push(r["id"].clone());
    }
    drop(s);
    for (i, id) in receipts.iter().enumerate() {
        if i > 0 {
            tokio::time::sleep(std::time::Duration::from_millis(200)).await;
        }
        let result = tokio::time::timeout(std::time::Duration::from_millis(500), request(&f,"POST","/api/v1/recognition/start",Some(json!({"request_key":format!("parallel-{i}"),"input":{"receipt_id":id,"expected_version":2,"zone":"UTC"}})),true)).await.unwrap();
        assert_eq!(result.0, 200);
    }
    assert_eq!(
        f.mock.lock().unwrap().calls.len(),
        1,
        "Only the first job may enter OCR"
    );
    let store = receipt_backend_api::db::Store::open(&f.dir.path().join("data")).unwrap();
    let queued = store
        .rows(
            "SELECT status FROM recognition_job ORDER BY created_at_utc_ms",
            &[],
        )
        .unwrap();
    assert_eq!(
        queued
            .iter()
            .map(|j| j["status"].as_str().unwrap())
            .collect::<Vec<_>>(),
        vec!["running", "queued"]
    );
    drop(store);
    let result = tokio::time::timeout(
        std::time::Duration::from_millis(500),
        request(
            &f,
            "POST",
            "/api/v1/receipts/get",
            Some(json!({"input":{"id":receipts[0]}})),
            true,
        ),
    )
    .await
    .unwrap();
    assert_eq!(result.0, 200);
    tokio::time::timeout(std::time::Duration::from_secs(5), async {
        loop {
            let store = receipt_backend_api::db::Store::open(&f.dir.path().join("data")).unwrap();
            let remaining = store
                .rows(
                    "SELECT job_id FROM recognition_job WHERE status IN ('queued','running')",
                    &[],
                )
                .unwrap();
            if remaining.is_empty() {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }
    })
    .await
    .expect("Both queued jobs must finish");
    assert_eq!(f.mock.lock().unwrap().calls.len(), 2);
}

#[tokio::test]
async fn receipt_photos_and_logo_crops_are_downloadable_but_unreferenced_media_are_not() {
    let f = fixture().await;
    let s = receipt_backend_api::db::Store::open(&f.dir.path().join("data")).unwrap();
    let r = s.transaction(|| s.save(domain_receipt(), false)).unwrap();
    let mut png = std::io::Cursor::new(Vec::new());
    image::DynamicImage::new_rgb8(30, 50)
        .write_to(&mut png, image::ImageFormat::Png)
        .unwrap();
    let upload = s
        .transaction(|| {
            s.upload(
                &json!({"receipt_id":r["id"],"expected_version":1}),
                png.get_ref(),
            )
        })
        .unwrap();
    let img=s.one("SELECT b.*,i.image_id FROM receipt_image i JOIN media_blob b ON b.blob_id=i.current_blob_id WHERE i.image_id=?",&[upload["image_id"].clone()]).unwrap();
    s.transaction(|| s.save_logo(&img, png.get_ref(), &json!([0, 0, 1, 0.2]), "ocr_header"))
        .unwrap();
    let logo = s
        .logo_action("list", &json!({"receipt_id":r["id"]}))
        .unwrap()[0]["media_id"]
        .as_str()
        .unwrap()
        .to_owned();
    let orphan = s
        .transaction(|| s.store_blob(png.get_ref(), false))
        .unwrap();
    for (id, auth, status) in [
        (img["blob_id"].as_str().unwrap(), true, 200),
        (logo.as_str(), true, 200),
        (orphan.as_str(), true, 404),
        (img["blob_id"].as_str().unwrap(), false, 401),
    ] {
        let mut request = Request::builder().uri(format!("/api/v1/media/{id}"));
        if auth {
            request = request.header("authorization", format!("Bearer {KEY}"));
        }
        let response = f
            .app
            .clone()
            .oneshot(request.body(Body::empty()).unwrap())
            .await
            .unwrap();
        let got = response.status().as_u16();
        let bytes = to_bytes(response.into_body(), usize::MAX).await.unwrap();
        assert_eq!(got, status, "{id}: {}", String::from_utf8_lossy(&bytes));
        if status == 200 {
            assert_eq!(bytes.as_ref(), png.get_ref());
        }
    }
}

#[tokio::test]
async fn all_photos_reach_dual_ocr_and_incomplete_pages_fail() {
    let f = fixture().await;
    let mut b = body();
    let photo = b["messages"][0]["content"][0].clone();
    b["messages"][0]["content"]
        .as_array_mut()
        .unwrap()
        .push(photo);
    let (status, result) = request(&f, "POST", "/v1/chat/completions", Some(b.clone()), true).await;
    assert_eq!(status, 200, "{result}");
    assert_eq!(result["receipt_parsing"]["image_count"], 2);
    assert_eq!(
        f.mock.lock().unwrap().calls[0]["messages"][0]["content"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
    f.mock.lock().unwrap().bad_json = true;
    assert_eq!(
        request(&f, "POST", "/v1/chat/completions", Some(b), true)
            .await
            .0,
        502
    );
}

#[tokio::test]
async fn logo_alias_is_resolved_before_the_single_multiphoto_extraction() {
    let f = fixture().await;
    let s = receipt_backend_api::db::Store::open(&f.dir.path().join("data")).unwrap();
    let mut draft = domain_receipt();
    draft["store"] = json!("");
    draft["lines"] = json!([]);
    let r = s.transaction(|| s.save(draft, false)).unwrap();
    let mut png = std::io::Cursor::new(Vec::new());
    image::DynamicImage::new_rgb8(100, 300)
        .write_to(&mut png, image::ImageFormat::Png)
        .unwrap();
    let upload = s
        .transaction(|| {
            s.upload(
                &json!({"receipt_id":r["id"],"expected_version":1}),
                png.get_ref(),
            )
        })
        .unwrap();
    let img=s.one("SELECT b.*,i.image_id FROM receipt_image i JOIN media_blob b ON b.blob_id=i.current_blob_id WHERE i.image_id=?",&[upload["image_id"].clone()]).unwrap();
    s.transaction(|| s.save_logo(&img, png.get_ref(), &json!([0., 0., 1., 0.2]), "ocr_header"))
        .unwrap();
    let logo = s
        .logo_action("list", &json!({"receipt_id":r["id"]}))
        .unwrap()[0]["logo_id"]
        .clone();
    f.mock.lock().unwrap().logo_id = Some(logo.as_str().unwrap().to_owned());
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
    s.transaction(|| {
        s.upload(
            &json!({"receipt_id":r["id"],"expected_version":2}),
            png.get_ref(),
        )
    })
    .unwrap();
    drop(s);
    let (status,started)=request(&f,"POST","/api/v1/recognition/start",Some(json!({"request_key":"logo-job","input":{"receipt_id":r["id"],"expected_version":3,"zone":"America/New_York"}})),true).await;
    assert_eq!(status, 200, "{started}");
    let mut done = false;
    for _ in 0..200 {
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        let s = receipt_backend_api::db::Store::open(&f.dir.path().join("data")).unwrap();
        let job = s
            .recognition_action("get", &json!({"id":started["data"]["job_id"]}))
            .unwrap();
        assert_ne!(job["status"], "failed", "{job}");
        if job["status"] == "applied" {
            assert_eq!(
                s.load(r["id"].as_str().unwrap()).unwrap()["store"],
                "Costco"
            );
            done = true;
            break;
        }
    }
    assert!(done);
    let m = f.mock.lock().unwrap();
    assert_eq!(m.events, vec!["ocr", "logo", "logo", "ocr"]);
    assert_eq!(m.calls.len(), 2); // Each photo read once, shared with logo localization.
}

#[tokio::test]
async fn arithmetic_mismatch_is_flagged_without_invented_items_or_model_retries() {
    let f = fixture().await;
    f.mock.lock().unwrap().arithmetic_failures = 1;
    let (status, result) = request(&f, "POST", "/v1/chat/completions", Some(body()), true).await;
    assert_eq!(status, 200, "{result}");
    let data: Value =
        serde_json::from_str(result["choices"][0]["message"]["content"].as_str().unwrap()).unwrap();
    assert_eq!(data["lines"].as_array().unwrap().len(), 3);
    assert_eq!(result["receipt_parsing"]["arithmetic_mismatch"], true);
    assert!(
        data["lines"][0]["review_notes"]
            .to_string()
            .contains("相差")
    );
    assert_eq!(f.mock.lock().unwrap().calls.len(), 1);
}

#[tokio::test]
async fn logo_match_rejects_reference_changes_during_inference() {
    let f = fixture().await;
    let s = receipt_backend_api::db::Store::open(&f.dir.path().join("data")).unwrap();
    let r = s.transaction(|| s.save(domain_receipt(), false)).unwrap();
    let mut png = std::io::Cursor::new(Vec::new());
    image::DynamicImage::new_rgb8(32, 64)
        .write_to(&mut png, image::ImageFormat::Png)
        .unwrap();
    let uploaded = s
        .transaction(|| {
            s.upload(
                &json!({"receipt_id":r["id"],"expected_version":1}),
                png.get_ref(),
            )
        })
        .unwrap();
    let img=s.one("SELECT b.*,i.image_id FROM receipt_image i JOIN media_blob b ON b.blob_id=i.current_blob_id WHERE i.image_id=?",&[uploaded["image_id"].clone()]).unwrap();
    s.transaction(|| s.save_logo(&img, png.get_ref(), &json!([0, 0, 1, 0.2]), "header"))
        .unwrap();
    f.mock.lock().unwrap().logo_delay_ms = 100;
    let matching = request(
        &f,
        "POST",
        "/api/v1/logos/match",
        Some(json!({"input":{"receipt_id":r["id"]}})),
        true,
    );
    let change = async {
        for _ in 0..100 {
            if f.mock.lock().unwrap().events.contains(&"logo".to_owned()) {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
        assert!(f.mock.lock().unwrap().events.contains(&"logo".to_owned()));
        let inputs = s.logo_match_inputs(r["id"].as_str().unwrap()).unwrap();
        s.transaction(||s.logo_action("delete",&json!({"id":inputs["references"][0]["logo_id"],"expected_version":inputs["catalog_version"]}))).unwrap();
    };
    let ((status, _), _) = tokio::join!(matching, change);
    assert_eq!(status, 409);
}
