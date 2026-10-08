//! Private inference evidence, separate from public errors and container logs.
use crate::{db, error::AppError};
use serde_json::{Value, json};

pub struct RecognitionTrace {
    run_id: String,
    receipt_id: Option<String>,
    job_id: Option<String>,
    profile: String,
    image_count: usize,
    started_at: i64,
    attempts: Vec<Value>,
    failure: Option<Value>,
}

impl RecognitionTrace {
    pub fn new(run_id: String, receipt_id: Option<String>, job_id: Option<String>) -> Self {
        Self {
            run_id,
            receipt_id,
            job_id,
            profile: String::new(),
            image_count: 0,
            started_at: db::now(),
            attempts: Vec::new(),
            failure: None,
        }
    }

    pub fn configure(&mut self, profile: &str, image_count: usize) {
        self.profile = profile.into();
        self.image_count = image_count;
    }
    pub fn span(&self) -> tracing::Span {
        tracing::info_span!("receipt_recognition",run_id=%self.run_id,
            receipt_id=?self.receipt_id,job_id=?self.job_id)
    }

    pub fn record(&mut self, raw: Option<&Value>, error: Option<&AppError>, elapsed_ms: u128) {
        let attempt = self.attempts.len() + 1;
        let finish = raw.and_then(|r| r["choices"][0]["finish_reason"].as_str());
        let details = raw.map(details).unwrap_or(Value::Null);
        let usage = raw.map(|r| r["usage"].clone()).unwrap_or(Value::Null);
        let paths = details["schema_errors"]
            .as_array()
            .map(|errors| {
                errors
                    .iter()
                    .map(|e| e["instance_path"].clone())
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        if let Some(error) = error {
            // Never log prompts, model text, images, request headers or credentials.
            tracing::warn!(
                run_id = %self.run_id, receipt_id = ?self.receipt_id, job_id = ?self.job_id,
                profile = %self.profile, image_count = self.image_count, attempt,
                code = error.code, reason = error.message,
                finish_reason = %finish.unwrap_or("missing").chars().take(64).collect::<String>(),
                output_truncated = finish == Some("length"),
                prompt_tokens = ?usage["prompt_tokens"].as_u64(),
                completion_tokens = ?usage["completion_tokens"].as_u64(),
                reasoning_tokens = ?usage["completion_tokens_details"]["reasoning_tokens"].as_u64(),
                validation_paths = %json!(paths),
                json_line = ?details["line"].as_u64(), json_column = ?details["column"].as_u64(),
                elapsed_ms,
                "receipt inference attempt failed"
            );
        }
        self.attempts.push(json!({
            "attempt":attempt, "elapsed_ms":elapsed_ms,
            "finish_reason":finish, "output_truncated":finish==Some("length"),
            "usage":usage, "validation":details,
            "error":error.map(|e|json!({"code":e.code,"reason":e.message})),
            "response":raw
        }));
    }

    pub fn fail(&mut self, error: &AppError) {
        self.failure = Some(json!({"code":error.code,"reason":error.message}));
        tracing::error!(run_id=%self.run_id, receipt_id=?self.receipt_id, job_id=?self.job_id,
            profile=%self.profile, image_count=self.image_count, attempts=self.attempts.len(),
            code=error.code, reason=error.message, "receipt extraction failed");
    }

    pub fn document(&self) -> Value {
        json!({"schema_version":1,"run_id":self.run_id,"receipt_id":self.receipt_id,
            "job_id":self.job_id,"profile":self.profile,"image_count":self.image_count,
            "started_at_utc_ms":self.started_at,"finished_at_utc_ms":db::now(),
            "error":self.failure,"attempts":self.attempts})
    }
}

fn details(raw: &Value) -> Value {
    let Some(content) = raw["choices"][0]["message"]["content"].as_str() else {
        return Value::Null;
    };
    let content = content.trim();
    let content = content
        .strip_prefix("```json\n")
        .or_else(|| content.strip_prefix("```\n"))
        .and_then(|s| s.strip_suffix("```"))
        .map(str::trim)
        .unwrap_or(content);
    let data = match serde_json::from_str::<Value>(content) {
        Ok(data) => data,
        Err(error) => {
            return json!({"json_error":error.to_string(),"line":error.line(),"column":error.column()});
        }
    };
    let data = crate::pipeline::normalize_output(raw)
        .map(|(data, _)| data)
        .unwrap_or(data);
    let schema: Value = serde_json::from_str(include_str!("receipt_schema.json")).unwrap();
    let validator = jsonschema::validator_for(&schema).unwrap();
    json!({"schema_errors":validator.iter_errors(&data).take(16).map(|e|json!({
        "instance_path":e.instance_path().as_str(), "schema_path":e.schema_path().as_str(),
        "reason":e.to_string().chars().take(512).collect::<String>()
    })).collect::<Vec<_>>()})
}
