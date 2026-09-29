use axum::{
    Router,
    body::{Body, to_bytes},
    http::Request,
};
use receipt_backend_api::{State, application, auth::Identities, config::Config, db};
use serde_json::{Value, json};
use tower::ServiceExt;
const SECRET: &str = "synthetic-test-signing-key-not-real-secret";
const PASS: &str = "admin-password-changed-123";
fn setup() -> (tempfile::TempDir, Router) {
    let root = tempfile::tempdir().unwrap();
    Identities::initialize(root.path(), false).unwrap();
    std::fs::write(
        root.path().join("prompt.toml"),
        include_str!("../../docker/defaults/prompt.toml"),
    )
    .unwrap();
    let template = include_str!("../../docker/defaults/backend_api.toml")
        .replacen(
            "jwt_secret = \"\"",
            &format!("jwt_secret = \"{SECRET}\""),
            1,
        )
        .replacen(
            "api_key = \"\"",
            "api_key = \"synthetic-ocr-service-key-for-tests\"",
            1,
        );
    let app =
        application(State::new(Config::parse(&template).unwrap(), root.path().to_owned()).unwrap());
    (root, app)
}
async fn call(
    app: &Router,
    method: &str,
    path: &str,
    body: Value,
    token: Option<&str>,
) -> (u16, Value) {
    let mut req = Request::builder()
        .method(method)
        .uri(path)
        .header("content-type", "application/json")
        .header("x-receipt-client", "mobile");
    if let Some(t) = token {
        req = req.header("authorization", format!("Bearer {t}"));
    }
    let response = app
        .clone()
        .oneshot(req.body(Body::from(body.to_string())).unwrap())
        .await
        .unwrap();
    let status = response.status().as_u16();
    let data = to_bytes(response.into_body(), 100_000_000).await.unwrap();
    (status, serde_json::from_slice(&data).unwrap())
}
async fn login(app: &Router, name: &str, pass: &str) -> Value {
    let (status, session) = call(
        app,
        "POST",
        "/api/auth/login",
        json!({"username":name,"password":pass}),
        None,
    )
    .await;
    assert_eq!(status, 200, "{session}");
    session
}
async fn change(app: &Router, session: &Value, old: &str, new: &str) -> Value {
    let (status, changed) = call(
        app,
        "POST",
        "/api/auth/change-password",
        json!({"current_password":old,"new_password":new}),
        session["access_token"].as_str(),
    )
    .await;
    assert_eq!(status, 200, "{changed}");
    changed
}
async fn admin(app: &Router) -> Value {
    change(app, &login(app, "admin", "admin").await, "admin", PASS).await
}
async fn op(
    app: &Router,
    session: &Value,
    component: &str,
    operation: &str,
    input: Value,
) -> (u16, Value) {
    call(
        app,
        "POST",
        &format!("/api/v1/{component}/{operation}"),
        json!({"request_key":db::id(),"input":input}),
        session["access_token"].as_str(),
    )
    .await
}
#[tokio::test]
async fn admin_bootstrap_change_reset_and_database_protection() {
    let (root, app) = setup();
    assert!(root.path().join("database/auth.sqlite").is_file());
    assert!(root.path().join("database/receipts.sqlite").is_file());
    assert!(!root.path().join("auth.sqlite").exists());
    let s = login(&app, "admin", "admin").await;
    assert_eq!(s["user"]["must_change_password"], true);
    for path in [
        "/receipt_master.apk",
        "/android-update.json",
        "/updates/test.apk",
    ] {
        assert_eq!(call(&app, "GET", path, json!({}), None).await.0, 401);
        assert_eq!(
            call(&app, "GET", path, json!({}), s["access_token"].as_str())
                .await
                .0,
            403
        );
    }
    assert_eq!(op(&app, &s, "receipts", "list", json!({})).await.0, 403);
    assert_eq!(
        call(
            &app,
            "POST",
            "/api/auth/change-password",
            json!({"current_password":"admin","new_password":"short"}),
            s["access_token"].as_str()
        )
        .await
        .0,
        400
    );
    let s = change(&app, &s, "admin", PASS).await;
    assert_eq!(op(&app, &s, "receipts", "list", json!({})).await.0, 200);
    assert_eq!(
        call(
            &app,
            "DELETE",
            "/api/auth/users/admin",
            json!({}),
            s["access_token"].as_str()
        )
        .await
        .0,
        403
    );
    assert_eq!(
        call(
            &app,
            "DELETE",
            "/api/auth/users/missing",
            json!({}),
            s["access_token"].as_str()
        )
        .await
        .0,
        404
    );
    assert_eq!(
        call(
            &app,
            "GET",
            "/api/auth/me",
            json!({}),
            s["access_token"].as_str()
        )
        .await
        .0,
        200
    );
    let conn = rusqlite::Connection::open(root.path().join("database/auth.sqlite")).unwrap();
    assert!(
        conn.execute("DELETE FROM app_user WHERE user_id='admin'", [])
            .is_err()
    );
    assert!(
        conn.execute(
            "UPDATE app_user SET username='other' WHERE user_id='admin'",
            []
        )
        .is_err()
    );
    let hash: String = conn
        .query_row(
            "SELECT password_hash FROM app_user WHERE user_id='admin'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert!(hash.starts_with("$argon2id$"));
    assert!(!hash.contains(PASS));
    // Operator recovery must also remove failed-password lockout for admin.
    for _ in 0..5 {
        conn.execute(
            "INSERT INTO login_failure VALUES ('admin','local',?)",
            [db::now()],
        )
        .unwrap();
    }
    Identities::initialize(root.path(), true).unwrap();
    assert_eq!(
        call(
            &app,
            "GET",
            "/api/auth/me",
            json!({}),
            s["access_token"].as_str()
        )
        .await
        .0,
        401
    );
    assert_eq!(
        login(&app, "admin", "admin").await["user"]["must_change_password"],
        true
    );
}
#[tokio::test]
async fn user_permissions_isolation_and_revocation() {
    let (_root, app) = setup();
    let a = admin(&app).await;
    let (status, user) = call(
        &app,
        "POST",
        "/api/auth/users",
        json!({"username":"alice","password":"temporary-alice-123"}),
        a["access_token"].as_str(),
    )
    .await;
    assert_eq!(status, 200);
    let b = change(
        &app,
        &login(&app, "alice", "temporary-alice-123").await,
        "temporary-alice-123",
        "alice-password-changed-123",
    )
    .await;
    assert_eq!(
        call(
            &app,
            "POST",
            "/api/auth/users",
            json!({"username":"bob","password":"temporary-bob-123"}),
            b["access_token"].as_str()
        )
        .await
        .0,
        403
    );
    assert_eq!(
        call(
            &app,
            "GET",
            "/api/auth/users",
            json!({}),
            b["access_token"].as_str()
        )
        .await
        .0,
        403
    );
    let id = db::id();
    let r = json!({"id":id,"store":"Only admin","branch":"","address":"","country":"US","currency":"USD","timeSource":"user_entered","rawTime":"","totalSource":"user_entered","occurredAt":1780000000000i64,"createdAt":1,"revision":0,"totalMinor":100,"posted":false,"lines":[]});
    assert_eq!(
        op(&app, &a, "receipts", "create", json!({"receipt":r}))
            .await
            .0,
        200
    );
    assert_eq!(
        op(&app, &b, "receipts", "get", json!({"id":id})).await.0,
        404
    );
    assert_eq!(
        op(&app, &b, "receipts", "list", json!({})).await.1["data"]["items"]
            .as_array()
            .unwrap()
            .len(),
        0
    );
    assert_eq!(
        op(
            &app,
            &a,
            "config",
            "save_weight_unit",
            json!({"weight_unit":"lb","expected_version":1})
        )
        .await
        .0,
        200
    );
    assert_eq!(
        op(&app, &b, "config", "get", json!({})).await.1["data"]["weight_unit"],
        "kg"
    );
    let (status, new) = call(
        &app,
        "POST",
        "/api/auth/refresh",
        json!({"refresh_token":b["refresh_token"]}),
        None,
    )
    .await;
    assert_eq!(status, 200);
    assert_eq!(
        call(
            &app,
            "POST",
            "/api/auth/refresh",
            json!({"refresh_token":b["refresh_token"]}),
            None
        )
        .await
        .0,
        401
    );
    assert_eq!(
        call(
            &app,
            "GET",
            "/api/auth/me",
            json!({}),
            b["access_token"].as_str()
        )
        .await
        .0,
        200
    );
    assert_eq!(
        call(
            &app,
            "DELETE",
            &format!("/api/auth/users/{}", user["user_id"].as_str().unwrap()),
            json!({}),
            a["access_token"].as_str()
        )
        .await
        .0,
        200
    );
    assert_eq!(
        call(
            &app,
            "GET",
            "/api/auth/me",
            json!({}),
            new["access_token"].as_str()
        )
        .await
        .0,
        401
    );
    assert_eq!(
        call(
            &app,
            "POST",
            "/api/auth/refresh",
            json!({"refresh_token":new["refresh_token"]}),
            None
        )
        .await
        .0,
        401
    );
    assert_eq!(
        op(&app, &a, "receipts", "get", json!({"id":id})).await.0,
        200
    );
}
#[tokio::test]
async fn expired_invalid_jwt_logout_login_throttle_and_browser_csrf() {
    let (_root, app) = setup();
    let a = admin(&app).await;
    for token in ["bad", SECRET] {
        assert_eq!(
            call(&app, "GET", "/api/auth/me", json!({}), Some(token))
                .await
                .0,
            401
        );
    }
    let expired=jsonwebtoken::encode(&jsonwebtoken::Header::new(jsonwebtoken::Algorithm::HS256),&json!({"sub":"admin","sid":"invalid","exp":1,"iss":"receipt-master","aud":"receipt-master-clients"}),&jsonwebtoken::EncodingKey::from_secret(SECRET.as_bytes())).unwrap();
    assert_eq!(
        call(&app, "GET", "/api/auth/me", json!({}), Some(&expired))
            .await
            .0,
        401
    );
    let req = Request::builder()
        .method("POST")
        .uri("/api/auth/login")
        .header("content-type", "application/json")
        .header("host", "receipts.test")
        .header("origin", "https://evil.test")
        .body(Body::from(
            json!({"username":"admin","password":PASS}).to_string(),
        ))
        .unwrap();
    assert_eq!(
        app.clone().oneshot(req).await.unwrap().status().as_u16(),
        403
    );
    assert_eq!(
        call(
            &app,
            "POST",
            "/api/auth/logout",
            json!({"refresh_token":a["refresh_token"]}),
            a["access_token"].as_str()
        )
        .await
        .0,
        200
    );
    assert_eq!(
        call(
            &app,
            "GET",
            "/api/auth/me",
            json!({}),
            a["access_token"].as_str()
        )
        .await
        .0,
        401
    );
    for _ in 0..5 {
        assert_eq!(
            call(
                &app,
                "POST",
                "/api/auth/login",
                json!({"username":"admin","password":"wrong"}),
                None
            )
            .await
            .0,
            401
        );
    }
    assert_eq!(
        call(
            &app,
            "POST",
            "/api/auth/login",
            json!({"username":"admin","password":PASS}),
            None
        )
        .await
        .0,
        429
    );
}

#[tokio::test]
async fn media_jobs_catalog_backups_and_restart_obey_user_scope() {
    use base64::Engine;
    let (root, app) = setup();
    let a = admin(&app).await;
    let identities = Identities::open(root.path()).unwrap();
    let user = identities
        .create_user("scoped", "temporary-scoped-123")
        .unwrap();
    let b = change(
        &app,
        &login(&app, "scoped", "temporary-scoped-123").await,
        "temporary-scoped-123",
        "scoped-new-password-123",
    )
    .await;
    let r = json!({"id":db::id(),"store":"Private shop","branch":"","address":"","country":"US","currency":"USD","timeSource":"user_entered","rawTime":"","totalSource":"user_entered","occurredAt":1780000000000i64,"createdAt":1,"revision":0,"totalMinor":100,"posted":false,"lines":[]});
    let store = db::Store::open(root.path()).unwrap();
    let saved = store.transaction(|| store.save(r.clone(), false)).unwrap();
    let mut photo = std::io::Cursor::new(Vec::new());
    image::DynamicImage::new_rgb8(30, 50)
        .write_to(&mut photo, image::ImageFormat::Png)
        .unwrap();
    let uploaded = store
        .transaction(|| {
            store.upload(
                &json!({"receipt_id":saved["id"],"expected_version":saved["revision"]}),
                photo.get_ref(),
            )
        })
        .unwrap();
    let media = store
        .one(
            "SELECT current_blob_id FROM receipt_image WHERE image_id=?",
            &[uploaded["image_id"].clone()],
        )
        .unwrap()["current_blob_id"]
        .as_str()
        .unwrap()
        .to_owned();
    for (session, status) in [(&a, 200), (&b, 404)] {
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .uri(format!("/api/v1/media/{media}"))
                    .header(
                        "authorization",
                        format!("Bearer {}", session["access_token"].as_str().unwrap()),
                    )
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status().as_u16(), status);
    }
    let (status, backup) = op(&app, &a, "exports", "create_backup", json!({})).await;
    assert_eq!(status, 200);
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(backup["data"]["bytes_base64"].as_str().unwrap())
        .unwrap();
    let mut zip = zip::ZipArchive::new(std::io::Cursor::new(bytes)).unwrap();
    for path in [
        "database/auth.sqlite",
        "database/auth.sqlite-wal",
        "database/auth.sqlite-shm",
    ] {
        assert!(zip.by_name(path).is_err());
    }
    assert!(
        zip.by_name(&format!("users/{}/database/receipts.sqlite", user.user_id))
            .is_err()
    );
    // A restore token is bound to the authenticated tenant's staging directory.
    let (status, prepare) = op(
        &app,
        &a,
        "maintenance",
        "prepare_restore",
        json!({"bytes_base64":backup["data"]["bytes_base64"]}),
    )
    .await;
    assert_eq!(status, 200);
    assert_eq!(
        op(
            &app,
            &b,
            "maintenance",
            "commit_restore",
            json!({"token":prepare["data"]["token"],"confirm":true})
        )
        .await
        .0,
        404
    );
    assert_eq!(
        op(
            &app,
            &a,
            "maintenance",
            "commit_restore",
            json!({"token":prepare["data"]["token"],"confirm":true})
        )
        .await
        .0,
        200
    );
    assert_eq!(
        call(
            &app,
            "GET",
            "/api/auth/me",
            json!({}),
            b["access_token"].as_str()
        )
        .await
        .0,
        200
    );
    // Restore and then enqueue a job without waking it, to inspect cross-tenant ownership.
    let store = db::Store::open(root.path()).unwrap();
    let current = store.load(r["id"].as_str().unwrap()).unwrap();
    let job = store
        .transaction(|| {
            store.recognition_action(
                "start",
                &json!({"receipt_id":r["id"],"expected_version":current["revision"],"zone":"UTC"}),
            )
        })
        .unwrap();
    assert_eq!(
        op(&app, &b, "recognition", "get", json!({"id":job["job_id"]}))
            .await
            .0,
        404
    );
    let tenant = db::Store::open(&receipt_backend_api::auth::user_root(
        root.path(),
        &user.user_id,
    ))
    .unwrap();
    assert_eq!(
        tenant.receipt_action("list", &json!({})).unwrap()["items"]
            .as_array()
            .unwrap()
            .len(),
        0
    );
    assert!(
        tenant
            .recognition_action("get", &json!({"id":job["job_id"]}))
            .is_err()
    );
    // Identity and refresh credentials survive server initialization without RESET.
    Identities::initialize(root.path(), false).unwrap();
    let refreshed = Identities::open(root.path())
        .unwrap()
        .refresh(b["refresh_token"].as_str().unwrap(), SECRET)
        .unwrap();
    assert_eq!(refreshed["user"]["user_id"], user.user_id);
    // Deleted tenant cleanup is retryable after restart, preserves admin data, and permits username reuse.
    identities.delete_user(&user.user_id).unwrap();
    identities.purge_deleted().unwrap();
    assert!(!receipt_backend_api::auth::user_root(root.path(), &user.user_id).exists());
    let recreated = identities
        .create_user("scoped", "temporary-scoped-456")
        .unwrap();
    assert_ne!(recreated.user_id, user.user_id);
    assert!(
        db::Store::open(root.path())
            .unwrap()
            .load(r["id"].as_str().unwrap())
            .is_ok()
    );
}

#[tokio::test]
async fn browser_cookie_contract_is_secure_and_does_not_expose_refresh_token() {
    let (_root, app) = setup();
    let response = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/auth/login")
                .header("host", "receipts.test")
                .header("origin", "https://receipts.test")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({"username":"admin","password":"admin"}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status().as_u16(), 200);
    let cookies = response
        .headers()
        .get_all("set-cookie")
        .iter()
        .map(|v| v.to_str().unwrap().to_owned())
        .collect::<Vec<_>>();
    assert_eq!(cookies.len(), 2);
    assert!(
        cookies.iter().all(|c| c.contains("HttpOnly")
            && c.contains("SameSite=Strict")
            && c.contains("Secure"))
    );
    let body: Value =
        serde_json::from_slice(&to_bytes(response.into_body(), 100000).await.unwrap()).unwrap();
    assert!(body["refresh_token"].is_null());
    let cookie = cookies
        .iter()
        .map(|s| s.split(';').next().unwrap())
        .collect::<Vec<_>>()
        .join("; ");
    let response = app
        .oneshot(
            Request::builder()
                .uri("/api/auth/me")
                .header("cookie", cookie)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status().as_u16(), 200);
}
