use axum::{
    Json,
    http::StatusCode,
    response::{IntoResponse, Response},
};
use serde_json::json;

#[derive(Debug)]
pub struct AppError {
    pub status: StatusCode,
    pub code: &'static str,
    pub message: &'static str,
}
impl AppError {
    pub fn new(status: u16, code: &'static str, message: &'static str) -> Self {
        Self {
            status: StatusCode::from_u16(status).expect("constant status"),
            code,
            message,
        }
    }
    pub fn invalid(message: &'static str) -> Self {
        Self::new(400, "invalid_request", message)
    }
    pub fn inference(error: reqwest::Error) -> Self {
        if error.is_timeout() {
            Self::new(504, "inference_timeout", "Local inference timed out.")
        } else {
            Self::new(
                502,
                "inference_error",
                "Local model service is unavailable or rejected the request.",
            )
        }
    }
}
impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        (
            self.status,
            Json(
                json!({"error":{"message":self.message,"code":self.code,"param":null,
            "type":if self.status.is_client_error(){"invalid_request_error"}else{"server_error"}}}),
            ),
        )
            .into_response()
    }
}
