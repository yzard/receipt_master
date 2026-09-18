pub mod calendar;
pub mod config;
pub mod data_api;
pub mod db;
pub mod editing;
pub mod error;
pub mod jobs;
pub mod logos;
mod merchant_images;
pub mod parsing;
pub mod pipeline;
pub mod receipt_lines;
pub mod sku;
pub mod weights;

use axum::{
    Json, Router,
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
use std::{
    sync::Arc,
    time::{Duration, Instant},
};
use subtle::ConstantTimeEq;
use tower::ServiceExt;
use tower_http::services::ServeFile;

pub struct State {
    pub config: Config,
    pub client: reqwest::Client,
    pub lock: tokio::sync::Semaphore,
    pub storage_lock: tokio::sync::Mutex<()>,
    pub active_job_workers: std::sync::atomic::AtomicUsize,
    authorization: Vec<u8>,
}
impl State {
    pub fn new(
        config: Config,
        key: &str,
    ) -> Result<Arc<Self>, Box<dyn std::error::Error + Send + Sync>> {
        if key.trim().len() < 24 {
            return Err("API key must have at least 24 characters".into());
        }
        let client = reqwest::Client::builder()
            .no_proxy()
            .timeout(Duration::from_secs(config.timeout_seconds))
            .build()?;
        let job_workers = config.job_workers;
        Ok(Arc::new(Self {
            config,
            client,
            lock: tokio::sync::Semaphore::new(job_workers),
            storage_lock: tokio::sync::Mutex::new(()),
            active_job_workers: std::sync::atomic::AtomicUsize::new(0),
            authorization: format!("Bearer {}", key.trim()).into_bytes(),
        }))
    }
}
async fn auth(AxumState(state): AxumState<Arc<State>>, req: Request, next: Next) -> Response {
    if !matches!(
        req.uri().path(),
        "/health" | "/receipt_master.apk" | "/android-update.json"
    ) && !req.uri().path().starts_with("/updates/")
        && !bool::from(
            req.headers()
                .get("authorization")
                .map(|v| v.as_bytes())
                .unwrap_or(&[])
                .ct_eq(&state.authorization),
        )
    {
        return AppError::new(401, "invalid_api_key", "Invalid API key.").into_response();
    }
    next.run(req).await
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
    let root = state.config.data_dir.clone();
    tokio::task::spawn_blocking(move || db::Store::open(&root).map(|_| ()))
        .await
        .map_err(db::io_error)??;
    Ok(Json(json!({"status":"ready"})))
}
async fn models(AxumState(state): AxumState<Arc<State>>) -> Json<Value> {
    Json(
        json!({"object":"list","data":[{"id":state.config.served_model,"object":"model","created":0,"owned_by":"local"}]}),
    )
}
async fn completions(
    AxumState(state): AxumState<Arc<State>>,
    body: Result<Json<Value>, JsonRejection>,
) -> Result<Json<Value>, AppError> {
    let Json(body) = body.map_err(|_| AppError::invalid("Invalid JSON request body."))?;
    pipeline::recognize(state, body).await.map(Json)
}
async fn apk(AxumState(state): AxumState<Arc<State>>, req: Request) -> Response {
    let file = ServeFile::new(&state.config.apk_path);
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
    let path = state.config.apk_path.with_file_name("android-update.json");
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
    let path = state.config.apk_path.with_file_name("updates").join(name);
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
        .route("/health", get(health))
        .route("/api/v1/{component}/{operation}", post(data_api::execute))
        .route("/api/v1/media/{id}", get(data_api::media))
        .route("/api/v1/images/upload", post(data_api::upload))
        .route("/api/v1/recognition/readiness", get(model_health))
        .route("/v1/models", get(models))
        .route("/v1/chat/completions", post(completions))
        .route("/receipt_master.apk", get(apk))
        .route("/android-update.json", get(update_manifest))
        .route("/updates/{name}", get(update_apk))
        .layer(DefaultBodyLimit::disable())
        .layer(middleware::from_fn_with_state(state.clone(), auth))
        .layer(middleware::from_fn(log_request))
        .with_state(state)
}
