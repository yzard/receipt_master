pub mod auth;
pub mod calendar;
pub mod config;
pub mod data_api;
pub mod db;
pub mod editing;
pub mod error;
pub mod exchange;
pub mod jobs;
pub mod localizations;
pub mod logos;
mod merchant_images;
pub mod pipeline;
pub mod prompts;
pub mod receipt_lines;
pub mod sku;
pub mod weights;

pub const PUBLIC_MODEL_ID: &str = "receipt-master";

use axum::{
    Extension, Json, Router,
    body::Body,
    extract::{
        DefaultBodyLimit, Path as RoutePath, Request, State as AxumState, rejection::JsonRejection,
    },
    http::{HeaderValue, StatusCode},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::{get, post},
};
use config::Config;
use error::AppError;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::{
    path::PathBuf,
    sync::Arc,
    time::{Duration, Instant},
};
use tower::ServiceExt;
use tower_http::services::{ServeDir, ServeFile};

pub struct State {
    pub config: Config,
    pub data_dir: PathBuf,
    pub prompts: prompts::Prompts,
    pub client: reqwest::Client,
    pub lock: Arc<tokio::sync::Semaphore>,
    pub auth_lock: Arc<tokio::sync::Semaphore>,
    pub storage_lock: Arc<tokio::sync::Mutex<()>>,
    pub identity_dir: PathBuf,
    pub users: tokio::sync::Mutex<HashMap<String, Arc<State>>>,
    pub deleted: std::sync::atomic::AtomicBool,
    pub active_requests: std::sync::atomic::AtomicUsize,
    pub active_job_workers: std::sync::atomic::AtomicUsize,
    pub(crate) ocr_authorization: String,
}
impl State {
    pub fn new(
        config: Config,
        data_dir: PathBuf,
    ) -> Result<Arc<Self>, Box<dyn std::error::Error + Send + Sync>> {
        let client = reqwest::Client::builder()
            .no_proxy()
            .timeout(Duration::from_secs(config.general.timeout_seconds))
            .build()?;
        let job_workers = config.general.job_workers;
        let ocr_authorization = format!("Bearer {}", config.ocr.api_key.trim());
        let prompts =
            prompts::Prompts::parse(&std::fs::read_to_string(data_dir.join("prompt.toml"))?)?;
        Ok(Arc::new(Self {
            config,
            identity_dir: data_dir.clone(),
            data_dir,
            prompts,
            client,
            lock: Arc::new(tokio::sync::Semaphore::new(job_workers)),
            auth_lock: Arc::new(tokio::sync::Semaphore::new(4)),
            storage_lock: Arc::new(tokio::sync::Mutex::new(())),
            users: tokio::sync::Mutex::new(HashMap::new()),
            deleted: std::sync::atomic::AtomicBool::new(false),
            active_requests: std::sync::atomic::AtomicUsize::new(0),
            active_job_workers: std::sync::atomic::AtomicUsize::new(0),
            ocr_authorization,
        }))
    }
}
impl State {
    pub async fn for_user(self: &Arc<Self>, user: &auth::Principal) -> Arc<Self> {
        if user.is_admin {
            return self.clone();
        }
        let mut users = self.users.lock().await;
        users
            .entry(user.user_id.clone())
            .or_insert_with(|| {
                Arc::new(Self {
                    config: self.config.clone(),
                    data_dir: auth::user_root(&self.identity_dir, &user.user_id),
                    identity_dir: self.identity_dir.clone(),
                    prompts: self.prompts.clone(),
                    client: self.client.clone(),
                    lock: self.lock.clone(),
                    auth_lock: self.auth_lock.clone(),
                    storage_lock: self.storage_lock.clone(),
                    active_requests: std::sync::atomic::AtomicUsize::new(0),
                    active_job_workers: std::sync::atomic::AtomicUsize::new(0),
                    deleted: std::sync::atomic::AtomicBool::new(false),
                    users: tokio::sync::Mutex::new(HashMap::new()),
                    ocr_authorization: self.ocr_authorization.clone(),
                })
            })
            .clone()
    }
}
struct ScopedRequest(Arc<State>);
impl Drop for ScopedRequest {
    fn drop(&mut self) {
        self.0
            .active_requests
            .fetch_sub(1, std::sync::atomic::Ordering::SeqCst);
    }
}
async fn authenticate(
    AxumState(state): AxumState<Arc<State>>,
    mut req: Request,
    next: Next,
) -> Response {
    let path = req.uri().path().to_owned();
    // Same-origin JSON requests prevent cookie-authenticated cross-site writes. No permissive CORS.
    if let Some(origin) = req.headers().get("origin") {
        let valid = origin
            .to_str()
            .ok()
            .and_then(|o| reqwest::Url::parse(o).ok())
            .is_some_and(|o| {
                let host = o.host_str().unwrap_or("");
                let authority = if let Some(port) = o.port() {
                    format!("{host}:{port}")
                } else {
                    host.to_owned()
                };
                req.headers()
                    .get("host")
                    .and_then(|h| h.to_str().ok())
                    .is_some_and(|h| h == authority)
            });
        if !valid {
            return AppError::new(403, "invalid_origin", "请求来源不符合服务地址").into_response();
        }
    }
    let android_asset = path == "/receipt_master.apk"
        || path == "/android-update.json"
        || path.starts_with("/updates/");
    if path == "/health"
        || matches!(
            path.as_str(),
            "/api/auth/login" | "/api/auth/refresh" | "/api/v1/localizations/get"
        )
        || (!path.starts_with("/api/") && !path.starts_with("/v1/") && !android_asset)
    {
        return next.run(req).await;
    }
    let token = req
        .headers()
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .and_then(|s| s.strip_prefix("Bearer "))
        .map(str::to_owned)
        .or_else(|| auth::cookie(req.headers(), "rm_access"));
    let Some(token) = token else {
        return AppError::new(401, "unauthenticated", "请先登录").into_response();
    };
    let root = state.identity_dir.clone();
    let secret = state.config.general.jwt_secret.clone();
    let user = match tokio::task::spawn_blocking(move || {
        auth::Identities::open(&root)?.authenticate(&token, &secret)
    })
    .await
    {
        Ok(Ok(u)) => u,
        Ok(Err(e)) => return e.into_response(),
        Err(e) => return db::io_error(e).into_response(),
    };
    if user.must_change_password
        && !matches!(
            path.as_str(),
            "/api/auth/me" | "/api/auth/change-password" | "/api/auth/logout"
        )
    {
        return AppError::new(403, "password_change_required", "首次登录必须修改密码")
            .into_response();
    }
    let scope = state.for_user(&user).await;
    scope
        .active_requests
        .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
    let _request = ScopedRequest(scope.clone());
    if scope.deleted.load(std::sync::atomic::Ordering::SeqCst) {
        return AppError::new(401, "unauthenticated", "账户已删除").into_response();
    }
    req.extensions_mut().insert(scope);
    req.extensions_mut().insert(user);
    let mut response = next.run(req).await;
    response.headers_mut().insert(
        "cache-control",
        HeaderValue::from_static("private, no-store"),
    );
    response
}
async fn web(AxumState(state): AxumState<Arc<State>>, req: Request) -> Response {
    if req.uri().path().starts_with("/api/") || req.uri().path().starts_with("/v1/") {
        return db::missing().into_response();
    }
    let mut response = ServeDir::new(&state.config.general.web_path)
        .not_found_service(ServeFile::new(
            state.config.general.web_path.join("index.html"),
        ))
        .oneshot(req)
        .await
        .expect("ServeDir is infallible")
        .map(Body::new);
    response.headers_mut().insert(
        "x-content-type-options",
        HeaderValue::from_static("nosniff"),
    );
    response.headers_mut().insert("content-security-policy",HeaderValue::from_static("default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' blob: data:; connect-src 'self'; object-src 'none'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'"));
    response
        .headers_mut()
        .insert("cache-control", HeaderValue::from_static("no-cache"));
    response
}
async fn log_request(req: Request, next: Next) -> Response {
    let method = req.method().clone();
    let path = req.uri().path().to_owned();
    let start = Instant::now();
    let response = next.run(req).await;
    tracing::info!(%method,%path,status=response.status().as_u16(),duration_ms=start.elapsed().as_millis(),"request");
    response
}
async fn model_health(AxumState(state): AxumState<Arc<State>>) -> Response {
    for url in [&state.config.ocr.url] {
        if !state
            .client
            .get(format!("{}/health", url.trim_end_matches('/')))
            .timeout(Duration::from_secs(2))
            .send()
            .await
            .is_ok_and(|r| r.status().is_success())
        {
            return (
                StatusCode::SERVICE_UNAVAILABLE,
                Json(json!({"status":"loading"})),
            )
                .into_response();
        }
    }
    Json(json!({"status":"ready"})).into_response()
}
async fn health(AxumState(state): AxumState<Arc<State>>) -> Result<Json<Value>, AppError> {
    let root = state.data_dir.clone();
    tokio::task::spawn_blocking(move || db::Store::open(&root).map(|_| ()))
        .await
        .map_err(db::io_error)??;
    Ok(Json(json!({"status":"ready"})))
}
async fn models(AxumState(_state): AxumState<Arc<State>>) -> Json<Value> {
    Json(
        json!({"object":"list","data":[{"id":PUBLIC_MODEL_ID,"object":"model","created":0,"owned_by":"local"}]}),
    )
}
async fn completions(
    Extension(state): Extension<Arc<State>>,
    body: Result<Json<Value>, JsonRejection>,
) -> Result<Json<Value>, AppError> {
    let Json(body) = body.map_err(|_| AppError::invalid("Invalid JSON request body."))?;
    pipeline::recognize(state, body).await.map(Json)
}
async fn apk(AxumState(state): AxumState<Arc<State>>, req: Request) -> Response {
    let file = ServeFile::new(&state.config.general.apk_path);
    let mut response = file
        .oneshot(req)
        .await
        .expect("ServeFile is infallible")
        .map(Body::new);
    if response.status() == StatusCode::NOT_FOUND {
        return AppError::new(
            404,
            "apk_not_found",
            "APK is not available; build it first.",
        )
        .into_response();
    }
    response.headers_mut().insert(
        "content-type",
        HeaderValue::from_static("application/vnd.android.package-archive"),
    );
    response.headers_mut().insert(
        "content-disposition",
        HeaderValue::from_static("attachment; filename=\"receipt_master.apk\""),
    );
    response
        .headers_mut()
        .insert("cache-control", HeaderValue::from_static("no-store"));
    response
}
async fn update_manifest(AxumState(state): AxumState<Arc<State>>, req: Request) -> Response {
    let path = state
        .config
        .general
        .apk_path
        .with_file_name("android-update.json");
    serve_update_file(path, req).await
}
async fn update_apk(
    AxumState(state): AxumState<Arc<State>>,
    RoutePath(name): RoutePath<String>,
    req: Request,
) -> Response {
    let valid = name.strip_suffix(".apk").is_some_and(|hash| {
        hash.len() == 64
            && hash
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    });
    if !valid {
        return AppError::new(404, "update_not_found", "Update not found.").into_response();
    }
    let path = state
        .config
        .general
        .apk_path
        .with_file_name("updates")
        .join(name);
    serve_update_file(path, req).await
}
async fn serve_update_file(path: std::path::PathBuf, req: Request) -> Response {
    let mut response = ServeFile::new(path)
        .oneshot(req)
        .await
        .expect("ServeFile is infallible")
        .map(Body::new);
    response
        .headers_mut()
        .insert("cache-control", HeaderValue::from_static("no-store"));
    response
}

pub fn application(state: Arc<State>) -> Router {
    Router::new()
        .route(
            "/api/auth/login",
            post(auth::login).layer(DefaultBodyLimit::max(16 * 1024)),
        )
        .route(
            "/api/auth/refresh",
            post(auth::refresh).layer(DefaultBodyLimit::max(16 * 1024)),
        )
        .route("/api/auth/me", get(auth::me))
        .route(
            "/api/auth/change-password",
            post(auth::change).layer(DefaultBodyLimit::max(16 * 1024)),
        )
        .route("/api/auth/logout", post(auth::logout))
        .route(
            "/api/auth/users",
            get(auth::list_users).post(auth::create_user),
        )
        .route(
            "/api/auth/users/{id}",
            axum::routing::delete(auth::delete_user),
        )
        .fallback(web)
        .route("/health", get(health))
        .route("/api/v1/localizations/get", post(localizations::get))
        .route("/api/v1/{component}/{operation}", post(data_api::execute))
        .route("/api/v1/media/{id}", get(data_api::media))
        .route("/api/v1/images/upload", post(data_api::upload))
        .route(
            "/api/v1/maintenance/prepare_restore",
            post(data_api::prepare_restore).layer(DefaultBodyLimit::disable()),
        )
        .route("/api/v1/recognition/readiness", get(model_health))
        .route("/v1/models", get(models))
        .route("/v1/chat/completions", post(completions))
        .route("/receipt_master.apk", get(apk))
        .route("/android-update.json", get(update_manifest))
        .route("/updates/{name}", get(update_apk))
        .layer(DefaultBodyLimit::max(80 * 1024 * 1024))
        .layer(middleware::from_fn_with_state(state.clone(), authenticate))
        .layer(middleware::from_fn(log_request))
        .with_state(state)
}
