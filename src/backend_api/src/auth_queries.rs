// Central SQLite identity/session statements. Values are always bound.
pub const DATABASE_PRAGMAS: &str = "PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL;";
pub const ADMIN_EXISTS: &str = "SELECT EXISTS(SELECT 1 FROM app_user WHERE user_id='admin')";
pub const INSERT_ADMIN: &str = "INSERT INTO app_user VALUES ('admin','admin',?,1,?,NULL)";
pub const BEGIN_TRANSACTION: &str = "BEGIN IMMEDIATE";
pub const RESET_ADMIN: &str =
    "UPDATE app_user SET password_hash=?,must_change_password=1 WHERE user_id='admin'";
pub const REVOKE_ADMIN: &str = "DELETE FROM auth_session WHERE user_id='admin'";
pub const COMMIT_TRANSACTION: &str = "COMMIT";
pub const GET_PRINCIPAL: &str = "SELECT user_id,username,must_change_password FROM app_user WHERE user_id=? AND deleted_at_utc_ms IS NULL";
pub const LIST_USERS: &str = "SELECT user_id,username,must_change_password FROM app_user WHERE deleted_at_utc_ms IS NULL OR ? ORDER BY created_at_utc_ms,user_id";
pub const PURGE_EXPIRED_SESSIONS: &str = "DELETE FROM auth_session WHERE expires_at_utc_ms<=?";
pub const UPSERT_SESSION: &str = "INSERT INTO auth_session VALUES (?,?,?,?) ON CONFLICT(session_id) DO UPDATE SET refresh_hash=excluded.refresh_hash,expires_at_utc_ms=excluded.expires_at_utc_ms";
pub const PURGE_LOGIN_FAILURES: &str = "DELETE FROM login_failure WHERE at_utc_ms<?";
pub const COUNT_LOGIN_FAILURES: &str = "SELECT SUM(client_ip=?),SUM(username=?) FROM login_failure";
pub const LOGIN_USER: &str =
    "SELECT user_id,password_hash FROM app_user WHERE username=? AND deleted_at_utc_ms IS NULL";
pub const ADMIN_HASH: &str = "SELECT password_hash FROM app_user WHERE user_id='admin'";
pub const INSERT_LOGIN_FAILURE: &str = "INSERT INTO login_failure VALUES (?,?,?)";
pub const CLEAR_LOGIN_FAILURES: &str = "DELETE FROM login_failure WHERE username=? AND client_ip=?";
pub const CHECK_SESSION: &str = "SELECT EXISTS(SELECT 1 FROM auth_session WHERE session_id=? AND user_id=? AND expires_at_utc_ms>?)";
pub const REFRESH_SESSION: &str =
    "SELECT user_id,session_id FROM auth_session WHERE refresh_hash=? AND expires_at_utc_ms>?";
pub const ROLLBACK_TRANSACTION: &str = "ROLLBACK";
pub const USER_HASH: &str =
    "SELECT password_hash FROM app_user WHERE user_id=? AND deleted_at_utc_ms IS NULL";
pub const CHANGE_PASSWORD: &str =
    "UPDATE app_user SET password_hash=?,must_change_password=0 WHERE user_id=?";
pub const REVOKE_USER: &str = "DELETE FROM auth_session WHERE user_id=?";
pub const LOGOUT_REFRESH: &str = "DELETE FROM auth_session WHERE refresh_hash=?";
pub const USERNAME_EXISTS: &str = "SELECT EXISTS(SELECT 1 FROM app_user WHERE username=?)";
pub const INSERT_USER: &str = "INSERT INTO app_user VALUES (?,?,?,1,?,NULL)";
pub const MARK_USER_DELETED: &str = "UPDATE app_user SET deleted_at_utc_ms=? WHERE user_id=?";
pub const IS_USER_DELETED: &str =
    "SELECT EXISTS(SELECT 1 FROM app_user WHERE user_id=? AND deleted_at_utc_ms IS NOT NULL)";
pub const PURGE_USER: &str =
    "DELETE FROM app_user WHERE user_id=? AND deleted_at_utc_ms IS NOT NULL";
pub const DELETED_USERS: &str = "SELECT user_id FROM app_user WHERE deleted_at_utc_ms IS NOT NULL";
pub const LOGOUT_USER_SESSION: &str = "DELETE FROM auth_session WHERE refresh_hash=? AND user_id=?";

pub const CLEAR_ADMIN_FAILURES: &str = "DELETE FROM login_failure WHERE username='admin'";
