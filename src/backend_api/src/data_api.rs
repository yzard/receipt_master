use crate::{
    State,
    db::{self, Store},
    error::AppError,
};
use axum::{
    Json,
    body::Body,
    extract::{Path, Request, State as AxumState},
    response::{IntoResponse, Response},
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::sync::Arc;
use tower::ServiceExt;
use tower_http::services::ServeFile;
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Operation {
    pub request_key: Option<String>,
    pub input: Value,
}
pub async fn execute(
    AxumState(state): AxumState<Arc<State>>,
    Path((component, operation)): Path<(String, String)>,
    Json(body): Json<Operation>,
) -> Result<Json<Value>, AppError> {
    if component == "logos" && operation == "match" {
        let result =
            crate::logos::match_receipt(state, db::text(&body.input, "receipt_id")?.to_owned())
                .await?;
        return Ok(Json(
            json!({"catalog_version":result["catalog_version"],"data":result}),
        ));
    }
    if component == "logos" && operation == "extract" {
        return Ok(Json(
            crate::logos::extract_existing(state, db::text(&body.input, "receipt_id")?.to_owned())
                .await?,
        ));
    }
    let _guard = state.storage_lock.lock().await;
    let root = state.data_dir.clone();
    let reply=tokio::task::spawn_blocking(move||{
  let store=Store::open(&root)?;
  let read=matches!(operation.as_str(),"get"|"list"|"runs"|"suggest"|"summary"|"details"|"check_duplicates"|"edit"|"display_line"|"prepare_line"|"time_candidates"|"range");
  if component=="config"&&operation=="get" {return Ok(json!({"data":store.one("SELECT weight_unit FROM app_preferences WHERE id=1",&[])?,"catalog_version":store.one("SELECT version FROM catalog_version WHERE id=1",&[])?["version"]}));}
  if component=="exports"{return store.export_action(&operation,&body.input);}
  if component=="maintenance"{return store.restore_action(&operation,&body.input);}
  let result=store.transaction(||{
   let request_hash=db::media::hash(serde_json::to_string(&json!([component,operation,body.input])).map_err(db::io_error)?.as_bytes());
   if !read {let key=body.request_key.as_ref().ok_or_else(db::invalid)?;if key.is_empty(){return Err(db::invalid());}
if let Some(previous)=store.rows("SELECT * FROM idempotency_record WHERE request_key=?",&[json!(key)])?.first(){if previous["request_hash"]!=request_hash{return Err(db::conflict());}return serde_json::from_str(db::text(previous,"response_json")?).map_err(db::io_error);}}
   let mut data=match component.as_str(){"receipts"=>store.receipt_action(&operation,&body.input)?,"categories"|"products"|"printed_names"|"product_names"|"config"=>store.catalog_action(&component,&operation,&body.input)?,"logos"=>store.logo_action(&operation,&body.input)?,"images"=>store.image_action(&operation,&body.input)?,"reports"=>store.report_action(&operation,&body.input)?,"recognition"=>store.recognition_action(&operation,&body.input)?,_=>return Err(db::missing())};
   store.display_data(&mut data,2,body.input["currency"].as_str().unwrap_or("USD"))?;
   let result=json!({"data":data,"catalog_version":store.one("SELECT version FROM catalog_version WHERE id=1",&[])?["version"]});
   if !read {store.exec("INSERT INTO idempotency_record VALUES (?,?,?,?)",&[json!(body.request_key),json!(request_hash),json!(result.to_string()),json!(db::now())])?;}Ok(result)
  })?;
  if component=="receipts"&&operation=="purge" { store.cleanup_media()?; }
  Ok(result)
 }).await.map_err(db::io_error)??;
    // Jobs are persisted first; processing is owned by the server and survives client disconnects.
    crate::jobs::wake(state.clone());
    Ok(Json(reply))
}
pub async fn media(
    AxumState(state): AxumState<Arc<State>>,
    Path(id): Path<String>,
    req: Request,
) -> Result<Response, AppError> {
    let root = state.data_dir.clone();
    let (path,mime)=tokio::task::spawn_blocking(move||{let s=Store::open(&root)?;let blob=s.one("SELECT b.* FROM media_blob b WHERE b.blob_id=? AND (EXISTS (SELECT 1 FROM receipt_image i WHERE i.original_blob_id=b.blob_id OR i.current_blob_id=b.blob_id) OR EXISTS (SELECT 1 FROM image_revision r WHERE r.blob_id=b.blob_id) OR EXISTS (SELECT 1 FROM logo_sample l WHERE l.blob_id=b.blob_id))",&[json!(id)])?;Ok::<_,AppError>((db::media::safe_path(&root,db::text(&blob,"relative_path")?)?,db::text(&blob,"mime")?.to_owned()))}).await.map_err(db::io_error)??;
    let mut response = ServeFile::new(path)
        .oneshot(req)
        .await
        .expect("infallible")
        .map(Body::new)
        .into_response();
    response
        .headers_mut()
        .insert("cache-control", "private, no-store".parse().unwrap());
    response
        .headers_mut()
        .insert("content-type", mime.parse().map_err(db::io_error)?);
    Ok(response)
}
pub async fn upload(
    AxumState(state): AxumState<Arc<State>>,
    mut form: axum::extract::Multipart,
) -> Result<Json<Value>, AppError> {
    use tokio::io::AsyncWriteExt;
    let staging = state.data_dir.join("staging");
    let temporary = tokio::task::spawn_blocking(move || tempfile::NamedTempFile::new_in(staging))
        .await
        .map_err(db::io_error)?
        .map_err(db::io_error)?;
    let mut file = tokio::fs::File::from_std(temporary.reopen().map_err(db::io_error)?);
    let mut metadata = None;
    let mut photo_received = false;
    while let Some(mut field) = form.next_field().await.map_err(|_| db::invalid())? {
        match field.name() {
            Some("metadata") if metadata.is_none() => {
                metadata = Some(
                    serde_json::from_str::<Operation>(
                        &field.text().await.map_err(|_| db::invalid())?,
                    )
                    .map_err(|_| db::invalid())?,
                );
            }
            Some("photo") if !photo_received => {
                photo_received = true;
                while let Some(chunk) = field.chunk().await.map_err(|_| db::invalid())? {
                    file.write_all(&chunk).await.map_err(db::io_error)?;
                }
                file.sync_all().await.map_err(db::io_error)?;
            }
            _ => return Err(db::invalid()),
        }
    }
    drop(file);
    if !photo_received {
        return Err(db::invalid());
    }
    let body = metadata.ok_or_else(db::invalid)?;
    let key = body.request_key.ok_or_else(db::invalid)?;
    let _guard = state.storage_lock.lock().await;
    let root = state.data_dir.clone();
    let data = tokio::task::spawn_blocking(move || {
        let bytes = std::fs::read(temporary.path()).map_err(db::io_error)?;
        let s = Store::open(&root)?;
        s.transaction(|| {
            let hash = db::media::hash(&[body.input.to_string().as_bytes(), &bytes].concat());
            if let Some(row) = s
                .rows(
                    "SELECT * FROM idempotency_record WHERE request_key=?",
                    &[json!(key)],
                )?
                .first()
            {
                if row["request_hash"] != hash {
                    return Err(db::conflict());
                }
                return serde_json::from_str(db::text(row, "response_json")?).map_err(db::io_error);
            }
            let data = s.upload(&body.input, &bytes)?;
            s.exec(
                "INSERT INTO idempotency_record VALUES (?,?,?,?)",
                &[
                    json!(key),
                    json!(hash),
                    json!(data.to_string()),
                    json!(db::now()),
                ],
            )?;
            Ok(data)
        })
    })
    .await
    .map_err(db::io_error)??;
    Ok(Json(json!({"data":data})))
}
