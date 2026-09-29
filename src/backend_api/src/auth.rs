//! Persistent identities and revocable JWT sessions. Business stores are scoped by identity.
use crate::{State, db, error::AppError};
use argon2::{Argon2, PasswordHash, PasswordHasher, PasswordVerifier, password_hash::SaltString};
use axum::{
    Extension, Json,
    extract::{ConnectInfo, Path, State as AxumState},
    http::{HeaderMap, HeaderValue},
    response::{IntoResponse, Response},
};
use jsonwebtoken::{Algorithm, DecodingKey, EncodingKey, Header, Validation};
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    net::SocketAddr,
    path::{Path as FsPath, PathBuf},
    sync::Arc,
};
#[path = "auth_queries.rs"]
mod queries;

const ACCESS_SECONDS: i64 = 900;
const SESSION_MS: i64 = 30 * 86400 * 1000;
const ADMIN: &str = "admin";

#[derive(Clone, Debug, Serialize)]
pub struct Principal {
    pub user_id: String,
    pub username: String,
    pub is_admin: bool,
    pub must_change_password: bool,
}
#[derive(Serialize, Deserialize)]
struct Claims {
    sub: String,
    sid: String,
    exp: i64,
    iss: String,
    aud: String,
}
fn unauthorized() -> AppError {
    AppError::new(401, "unauthenticated", "登录已失效，请重新登录")
}
fn forbidden() -> AppError {
    AppError::new(403, "forbidden", "只有管理员可以管理用户")
}
fn hash_password(password: &str) -> db::Result<String> {
    let salt = SaltString::encode_b64(uuid::Uuid::new_v4().as_bytes()).map_err(db::io_error)?;
    Argon2::default()
        .hash_password(password.as_bytes(), &salt)
        .map(|v| v.to_string())
        .map_err(db::io_error)
}
fn verify(password: &str, hash: &str) -> bool {
    PasswordHash::new(hash).is_ok_and(|h| {
        Argon2::default()
            .verify_password(password.as_bytes(), &h)
            .is_ok()
    })
}
fn digest(value: &str) -> String {
    format!("{:x}", Sha256::digest(value.as_bytes()))
}
fn password_policy(password: &str) -> db::Result<()> {
    if password.chars().count() < 12 || password.len() > 1024 || password.trim().is_empty() {
        return Err(AppError::invalid("密码至少需要 12 个字符，最多 1024 字节"));
    }
    Ok(())
}
fn username_policy(value: &str) -> db::Result<String> {
    let name = value.trim().to_ascii_lowercase();
    if !(3..=64).contains(&name.len())
        || !name
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || b"._-".contains(&c))
    {
        return Err(AppError::invalid(
            "用户名为 3–64 个英文字母、数字、点、下划线或短横线",
        ));
    }
    Ok(name)
}
pub fn user_root(root: &FsPath, id: &str) -> PathBuf {
    if id == ADMIN {
        root.to_owned()
    } else {
        root.join("users").join(id)
    }
}

pub struct Identities {
    db: Connection,
    root: PathBuf,
}
impl Identities {
    pub fn open(root: &FsPath) -> db::Result<Self> {
        let db = Connection::open(root.join("database/auth.sqlite")).map_err(db::sql_error)?;
        db.busy_timeout(std::time::Duration::from_secs(5))
            .map_err(db::sql_error)?;
        db.execute_batch(queries::DATABASE_PRAGMAS)
            .map_err(db::sql_error)?;
        Ok(Self {
            db,
            root: root.to_owned(),
        })
    }
    pub fn initialize(root: &FsPath, reset: bool) -> db::Result<()> {
        std::fs::create_dir_all(root.join("database")).map_err(db::io_error)?;
        let s = Self::open(root)?;
        s.db.execute_batch(include_str!("auth_schema.sql"))
            .map_err(db::sql_error)?;
        let present: bool =
            s.db.query_row(queries::ADMIN_EXISTS, [], |r| r.get(0))
                .map_err(db::sql_error)?;
        if !present {
            s.db.execute(
                queries::INSERT_ADMIN,
                params![hash_password("admin")?, db::now()],
            )
            .map_err(db::sql_error)?;
        }
        if reset {
            s.db.execute_batch(queries::BEGIN_TRANSACTION)
                .map_err(db::sql_error)?;
            s.db.execute(queries::RESET_ADMIN, [hash_password("admin")?])
                .map_err(db::sql_error)?;
            s.db.execute(queries::REVOKE_ADMIN, [])
                .map_err(db::sql_error)?;
            s.db.execute(queries::CLEAR_ADMIN_FAILURES, [])
                .map_err(db::sql_error)?;
            s.db.execute_batch(queries::COMMIT_TRANSACTION)
                .map_err(db::sql_error)?;
        }
        for u in s.users(false)? {
            crate::db::Store::initialize(&user_root(root, &u.user_id))?;
        }
        Ok(())
    }
    fn principal(&self, id: &str) -> db::Result<Principal> {
        self.db
            .query_row(queries::GET_PRINCIPAL, [id], |r| {
                Ok(Principal {
                    user_id: r.get(0)?,
                    username: r.get(1)?,
                    must_change_password: r.get(2)?,
                    is_admin: id == ADMIN,
                })
            })
            .optional()
            .map_err(db::sql_error)?
            .ok_or_else(unauthorized)
    }
    pub fn users(&self, include_deleted: bool) -> db::Result<Vec<Principal>> {
        let mut stmt = self
            .db
            .prepare(queries::LIST_USERS)
            .map_err(db::sql_error)?;
        let rows = stmt
            .query_map([include_deleted], |r| {
                let id: String = r.get(0)?;
                Ok(Principal {
                    is_admin: id == ADMIN,
                    user_id: id,
                    username: r.get(1)?,
                    must_change_password: r.get(2)?,
                })
            })
            .map_err(db::sql_error)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(db::sql_error)
    }
    fn session(&self, user: &Principal, secret: &str) -> db::Result<Value> {
        self.session_for(user, secret, db::id())
    }
    fn session_for(&self, user: &Principal, secret: &str, sid: String) -> db::Result<Value> {
        self.db
            .execute(queries::PURGE_EXPIRED_SESSIONS, [db::now()])
            .map_err(db::sql_error)?;
        let refresh = format!(
            "{}{}",
            uuid::Uuid::new_v4().simple(),
            uuid::Uuid::new_v4().simple()
        );
        self.db
            .execute(
                queries::UPSERT_SESSION,
                params![sid, user.user_id, digest(&refresh), db::now() + SESSION_MS],
            )
            .map_err(db::sql_error)?;
        let claims = Claims {
            sub: user.user_id.clone(),
            sid,
            exp: chrono::Utc::now().timestamp() + ACCESS_SECONDS,
            iss: "receipt-master".into(),
            aud: "receipt-master-clients".into(),
        };
        let token = jsonwebtoken::encode(
            &Header::new(Algorithm::HS256),
            &claims,
            &EncodingKey::from_secret(secret.as_bytes()),
        )
        .map_err(db::io_error)?;
        Ok(
            json!({"access_token":token,"refresh_token":refresh,"expires_in":ACCESS_SECONDS,"user":user}),
        )
    }
    pub fn login(
        &self,
        username: &str,
        password: &str,
        ip: &str,
        secret: &str,
    ) -> db::Result<Value> {
        let username = username.trim().to_ascii_lowercase();
        let now = db::now();
        self.db
            .execute(queries::PURGE_LOGIN_FAILURES, [now - 900000])
            .map_err(db::sql_error)?;
        let (ip_count, user_count): (i64, i64) = self
            .db
            .query_row(queries::COUNT_LOGIN_FAILURES, params![ip, username], |r| {
                Ok((
                    r.get::<_, Option<i64>>(0)?.unwrap_or(0),
                    r.get::<_, Option<i64>>(1)?.unwrap_or(0),
                ))
            })
            .map_err(db::sql_error)?;
        if ip_count >= 20 || user_count >= 5 {
            return Err(AppError::new(
                429,
                "login_throttled",
                "登录失败次数过多，请 15 分钟后再试",
            ));
        }
        let row: Option<(String, String)> = self
            .db
            .query_row(queries::LOGIN_USER, [&username], |r| {
                Ok((r.get(0)?, r.get(1)?))
            })
            .optional()
            .map_err(db::sql_error)?;
        let fallback: String = self
            .db
            .query_row(queries::ADMIN_HASH, [], |r| r.get(0))
            .map_err(db::sql_error)?;
        let valid = verify(
            password,
            row.as_ref().map(|(_, h)| h.as_str()).unwrap_or(&fallback),
        );
        if !valid || row.is_none() {
            self.db
                .execute(queries::INSERT_LOGIN_FAILURE, params![username, ip, now])
                .map_err(db::sql_error)?;
            return Err(AppError::new(
                401,
                "invalid_credentials",
                "用户名或密码不正确",
            ));
        }
        self.db
            .execute(queries::CLEAR_LOGIN_FAILURES, params![username, ip])
            .map_err(db::sql_error)?;
        self.session(&self.principal(&row.unwrap().0)?, secret)
    }
    pub fn authenticate(&self, token: &str, secret: &str) -> db::Result<Principal> {
        let mut validation = Validation::new(Algorithm::HS256);
        validation.set_issuer(&["receipt-master"]);
        validation.set_audience(&["receipt-master-clients"]);
        validation.leeway = 0;
        let claims = jsonwebtoken::decode::<Claims>(
            token,
            &DecodingKey::from_secret(secret.as_bytes()),
            &validation,
        )
        .map_err(|_| unauthorized())?
        .claims;
        let exists: bool = self
            .db
            .query_row(
                queries::CHECK_SESSION,
                params![claims.sid, claims.sub, db::now()],
                |r| r.get(0),
            )
            .map_err(db::sql_error)?;
        if !exists {
            return Err(unauthorized());
        }
        self.principal(&claims.sub)
    }
    pub fn refresh(&self, token: &str, secret: &str) -> db::Result<Value> {
        self.db
            .execute_batch(queries::BEGIN_TRANSACTION)
            .map_err(db::sql_error)?;
        let result = (|| {
            let id: Option<(String, String)> = self
                .db
                .query_row(
                    queries::REFRESH_SESSION,
                    params![digest(token), db::now()],
                    |r| Ok((r.get(0)?, r.get(1)?)),
                )
                .optional()
                .map_err(db::sql_error)?;
            let (id, sid) = id.ok_or_else(unauthorized)?;
            let user = self.principal(&id)?;
            self.session_for(&user, secret, sid)
        })();
        match result {
            Ok(v) => {
                self.db
                    .execute_batch(queries::COMMIT_TRANSACTION)
                    .map_err(db::sql_error)?;
                Ok(v)
            }
            Err(e) => {
                let _ = self.db.execute_batch(queries::ROLLBACK_TRANSACTION);
                Err(e)
            }
        }
    }
    pub fn change_password(
        &self,
        user: &Principal,
        current: &str,
        password: &str,
        secret: &str,
    ) -> db::Result<Value> {
        password_policy(password)?;
        let old: String = self
            .db
            .query_row(queries::USER_HASH, [&user.user_id], |r| r.get(0))
            .map_err(db::sql_error)?;
        if !verify(current, &old) || verify(password, &old) {
            return Err(AppError::invalid("当前密码不正确，或新密码与当前密码相同"));
        }
        let hash = hash_password(password)?;
        self.db
            .execute_batch(queries::BEGIN_TRANSACTION)
            .map_err(db::sql_error)?;
        self.db
            .execute(queries::CHANGE_PASSWORD, params![hash, user.user_id])
            .map_err(db::sql_error)?;
        self.db
            .execute(queries::REVOKE_USER, [&user.user_id])
            .map_err(db::sql_error)?;
        let result = self.session(&self.principal(&user.user_id)?, secret)?;
        self.db
            .execute_batch(queries::COMMIT_TRANSACTION)
            .map_err(db::sql_error)?;
        Ok(result)
    }
    pub fn logout(&self, token: &str) -> db::Result<()> {
        self.db
            .execute(queries::LOGOUT_REFRESH, [digest(token)])
            .map_err(db::sql_error)?;
        Ok(())
    }
    pub fn create_user(&self, username: &str, password: &str) -> db::Result<Principal> {
        let name = username_policy(username)?;
        password_policy(password)?;
        if name == ADMIN {
            return Err(AppError::invalid("admin 为保留的元用户"));
        }
        let exists: bool = self
            .db
            .query_row(queries::USERNAME_EXISTS, [&name], |r| r.get(0))
            .map_err(db::sql_error)?;
        if exists {
            return Err(AppError::new(409, "username_taken", "用户名已存在"));
        }
        let id = db::id();
        let root = user_root(&self.root, &id);
        crate::db::Store::initialize(&root)?;
        let result = self.db.execute(
            queries::INSERT_USER,
            params![id, name, hash_password(password)?, db::now()],
        );
        if let Err(e) = result {
            let _ = std::fs::remove_dir_all(root);
            return Err(db::sql_error(e));
        }
        self.principal(&id)
    }
    pub fn delete_user(&self, id: &str) -> db::Result<()> {
        if id == ADMIN {
            return Err(AppError::new(
                403,
                "protected_admin",
                "admin 元用户不能删除",
            ));
        }
        self.principal(id).map_err(|error| {
            if error.status == 401 {
                AppError::new(404, "user_not_found", "用户不存在或已删除")
            } else {
                error
            }
        })?;
        self.db
            .execute_batch(queries::BEGIN_TRANSACTION)
            .map_err(db::sql_error)?;
        self.db
            .execute(queries::MARK_USER_DELETED, params![db::now(), id])
            .map_err(db::sql_error)?;
        self.db
            .execute(queries::REVOKE_USER, [id])
            .map_err(db::sql_error)?;
        self.db
            .execute_batch(queries::COMMIT_TRANSACTION)
            .map_err(db::sql_error)?;
        Ok(())
    }
    pub fn purge_user(&self, id: &str) -> db::Result<()> {
        let deleted: bool = self
            .db
            .query_row(queries::IS_USER_DELETED, [id], |r| r.get(0))
            .map_err(db::sql_error)?;
        if !deleted || id == ADMIN {
            return Err(forbidden());
        }
        let path = user_root(&self.root, id);
        if path.exists() {
            std::fs::remove_dir_all(path).map_err(db::io_error)?;
        }
        self.db
            .execute(queries::PURGE_USER, [id])
            .map_err(db::sql_error)?;
        Ok(())
    }
    pub fn purge_deleted(&self) -> db::Result<()> {
        let mut stmt = self
            .db
            .prepare(queries::DELETED_USERS)
            .map_err(db::sql_error)?;
        let ids = stmt
            .query_map([], |r| r.get::<_, String>(0))
            .map_err(db::sql_error)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(db::sql_error)?;
        for id in ids {
            self.purge_user(&id)?;
        }
        Ok(())
    }
}

pub fn cookie(headers: &HeaderMap, name: &str) -> Option<String> {
    headers
        .get("cookie")?
        .to_str()
        .ok()?
        .split(';')
        .find_map(|p| {
            let (k, v) = p.trim().split_once('=')?;
            (k == name).then(|| v.to_owned())
        })
}
fn cookies(mut data: Value, headers: &HeaderMap) -> Response {
    let secure = headers
        .get("origin")
        .and_then(|v| v.to_str().ok())
        .is_some_and(|s| s.starts_with("https://"))
        || headers
            .get("x-forwarded-proto")
            .is_some_and(|v| v == "https");
    let mut values = Vec::new();
    for (key, name, age, path) in [
        ("access_token", "rm_access", ACCESS_SECONDS, "/"),
        (
            "refresh_token",
            "rm_refresh",
            SESSION_MS / 1000,
            "/api/auth",
        ),
    ] {
        if let Some(token) = data[key].as_str() {
            values.push(format!(
                "{name}={token}; Path={path}; HttpOnly; SameSite=Strict; Max-Age={age}{}",
                if secure { "; Secure" } else { "" }
            ));
        }
    }
    if data.get("clear").is_some() {
        values = vec![
            "rm_access=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0".into(),
            "rm_refresh=; Path=/api/auth; HttpOnly; SameSite=Strict; Max-Age=0".into(),
        ];
    }
    // Browser JavaScript never receives the persistent refresh credential.
    if headers
        .get("x-receipt-client")
        .is_none_or(|h| h != "mobile")
    {
        data.as_object_mut().unwrap().remove("refresh_token");
    }
    let mut response = Json(data).into_response();
    response
        .headers_mut()
        .insert("cache-control", HeaderValue::from_static("no-store"));
    for v in values {
        response
            .headers_mut()
            .append("set-cookie", HeaderValue::from_str(&v).unwrap());
    }
    response
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Login {
    username: String,
    password: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Refresh {
    refresh_token: Option<String>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Change {
    current_password: String,
    new_password: String,
}
pub async fn login(
    AxumState(state): AxumState<Arc<State>>,
    ip: Option<Extension<ConnectInfo<SocketAddr>>>,
    headers: HeaderMap,
    Json(body): Json<Login>,
) -> Result<Response, AppError> {
    if body.username.len() > 64 || body.password.len() > 1024 {
        return Err(AppError::invalid("登录字段过长"));
    }
    let ip = ip
        .map(|Extension(ConnectInfo(v))| v.ip().to_string())
        .unwrap_or_else(|| "local".into());
    let permit = state
        .auth_lock
        .clone()
        .acquire_owned()
        .await
        .map_err(db::io_error)?;
    let root = state.identity_dir.clone();
    let secret = state.config.general.jwt_secret.clone();
    let data = tokio::task::spawn_blocking(move || {
        let _permit = permit;
        Identities::open(&root)?.login(&body.username, &body.password, &ip, &secret)
    })
    .await
    .map_err(db::io_error)??;
    Ok(cookies(data, &headers))
}
pub async fn refresh(
    AxumState(state): AxumState<Arc<State>>,
    headers: HeaderMap,
    Json(body): Json<Refresh>,
) -> Result<Response, AppError> {
    let token = body
        .refresh_token
        .or_else(|| cookie(&headers, "rm_refresh"))
        .ok_or_else(unauthorized)?;
    let root = state.identity_dir.clone();
    let secret = state.config.general.jwt_secret.clone();
    let data =
        tokio::task::spawn_blocking(move || Identities::open(&root)?.refresh(&token, &secret))
            .await
            .map_err(db::io_error)??;
    Ok(cookies(data, &headers))
}
pub async fn me(Extension(user): Extension<Principal>) -> Json<Principal> {
    Json(user)
}
pub async fn change(
    AxumState(state): AxumState<Arc<State>>,
    Extension(user): Extension<Principal>,
    headers: HeaderMap,
    Json(body): Json<Change>,
) -> Result<Response, AppError> {
    let permit = state
        .auth_lock
        .clone()
        .acquire_owned()
        .await
        .map_err(db::io_error)?;
    if body.current_password.len() > 1024 {
        return Err(AppError::invalid("登录字段过长"));
    }
    let root = state.identity_dir.clone();
    let secret = state.config.general.jwt_secret.clone();
    let data = tokio::task::spawn_blocking(move || {
        let _permit = permit;
        Identities::open(&root)?.change_password(
            &user,
            &body.current_password,
            &body.new_password,
            &secret,
        )
    })
    .await
    .map_err(db::io_error)??;
    Ok(cookies(data, &headers))
}
pub async fn logout(
    AxumState(state): AxumState<Arc<State>>,
    Extension(user): Extension<Principal>,
    headers: HeaderMap,
    Json(body): Json<Refresh>,
) -> Result<Response, AppError> {
    let root = state.identity_dir.clone();
    let token = body
        .refresh_token
        .or_else(|| cookie(&headers, "rm_refresh"));
    tokio::task::spawn_blocking(move || {
        let s = Identities::open(&root)?;
        if let Some(token) = token {
            s.db.execute(
                queries::LOGOUT_USER_SESSION,
                params![digest(&token), user.user_id],
            )
            .map_err(db::sql_error)?;
        } else {
            s.db.execute(queries::REVOKE_USER, [user.user_id])
                .map_err(db::sql_error)?;
        }
        Ok::<_, AppError>(())
    })
    .await
    .map_err(db::io_error)??;
    Ok(cookies(json!({"clear":true}), &headers))
}
pub async fn list_users(
    AxumState(state): AxumState<Arc<State>>,
    Extension(user): Extension<Principal>,
) -> Result<Json<Value>, AppError> {
    if !user.is_admin {
        return Err(forbidden());
    }
    let root = state.identity_dir.clone();
    Ok(Json(json!(
        tokio::task::spawn_blocking(move || Identities::open(&root)?.users(false))
            .await
            .map_err(db::io_error)??
    )))
}
pub async fn create_user(
    AxumState(state): AxumState<Arc<State>>,
    Extension(user): Extension<Principal>,
    Json(body): Json<Login>,
) -> Result<Json<Principal>, AppError> {
    if !user.is_admin {
        return Err(forbidden());
    }
    let permit = state
        .auth_lock
        .clone()
        .acquire_owned()
        .await
        .map_err(db::io_error)?;
    let root = state.identity_dir.clone();
    let user = tokio::task::spawn_blocking(move || {
        let _permit = permit;
        Identities::open(&root)?.create_user(&body.username, &body.password)
    })
    .await
    .map_err(db::io_error)??;
    state.for_user(&user).await;
    Ok(Json(user))
}
pub async fn delete_user(
    AxumState(state): AxumState<Arc<State>>,
    Extension(user): Extension<Principal>,
    Path(id): Path<String>,
) -> Result<Json<Value>, AppError> {
    if !user.is_admin {
        return Err(forbidden());
    }
    let root = state.identity_dir.clone();
    let copy = id.clone();
    tokio::task::spawn_blocking(move || Identities::open(&root)?.delete_user(&copy))
        .await
        .map_err(db::io_error)??;
    if let Some(scope) = state.users.lock().await.get(&id).cloned() {
        scope
            .deleted
            .store(true, std::sync::atomic::Ordering::SeqCst);
        tokio::spawn(async move {
            while scope
                .active_requests
                .load(std::sync::atomic::Ordering::SeqCst)
                > 0
                || scope
                    .active_job_workers
                    .load(std::sync::atomic::Ordering::SeqCst)
                    > 0
            {
                tokio::time::sleep(std::time::Duration::from_millis(200)).await;
            }
            let _guard = scope.storage_lock.lock().await;
            let root = scope.identity_dir.clone();
            match tokio::task::spawn_blocking(move || Identities::open(&root)?.purge_user(&id))
                .await
            {
                Ok(Ok(())) => {}
                Ok(Err(e)) => tracing::error!(
                    code = e.code,
                    "user data cleanup failed; will retry at restart"
                ),
                Err(e) => tracing::error!(error=%e,"user data cleanup failed"),
            }
        });
    }
    Ok(Json(json!({"deleted":true})))
}
