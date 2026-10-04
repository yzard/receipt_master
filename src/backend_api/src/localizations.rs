use axum::{Json, response::IntoResponse};
use serde_json::Value;
use std::sync::LazyLock;

/// Public interface resources, shared by Web, Android and iOS. No account data.
pub static CATALOG: LazyLock<Value> = LazyLock::new(|| {
    serde_json::from_str(include_str!("../resources/localizations.json"))
        .expect("bundled localization resource must be valid JSON")
});

pub async fn get() -> impl IntoResponse {
    (
        [("cache-control", "no-store")],
        Json(serde_json::json!({"data": *CATALOG})),
    )
}
