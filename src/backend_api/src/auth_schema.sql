CREATE TABLE IF NOT EXISTS app_user (
    user_id TEXT PRIMARY KEY,
    username TEXT NOT NULL UNIQUE COLLATE NOCASE,
    password_hash TEXT NOT NULL,
    must_change_password INTEGER NOT NULL CHECK (must_change_password IN (0, 1)),
    created_at_utc_ms INTEGER NOT NULL,
    deleted_at_utc_ms INTEGER,
    CHECK ((user_id = 'admin' AND username = 'admin' AND deleted_at_utc_ms IS NULL)
        OR (user_id <> 'admin' AND username <> 'admin'))
);
CREATE TRIGGER IF NOT EXISTS protect_admin_delete BEFORE DELETE ON app_user
WHEN OLD.user_id = 'admin' BEGIN
    SELECT RAISE(ABORT, 'admin is permanent');
END;
CREATE TRIGGER IF NOT EXISTS protect_admin_identity BEFORE UPDATE ON app_user
WHEN OLD.user_id = 'admin' AND
    (NEW.user_id <> 'admin' OR NEW.username <> 'admin' OR NEW.deleted_at_utc_ms IS NOT NULL)
BEGIN SELECT RAISE(ABORT, 'admin is permanent'); END;
CREATE TABLE IF NOT EXISTS auth_session (
    session_id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES app_user(user_id) ON DELETE CASCADE,
    refresh_hash TEXT NOT NULL UNIQUE,
    expires_at_utc_ms INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS session_user_idx ON auth_session(user_id);
CREATE TABLE IF NOT EXISTS login_failure (
    username TEXT NOT NULL,
    client_ip TEXT NOT NULL,
    at_utc_ms INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS failure_time_idx ON login_failure(at_utc_ms);
