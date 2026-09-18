use crate::error::AppError;
use rusqlite::{
    Connection, params_from_iter,
    types::{Value as SqlValue, ValueRef},
};
use serde_json::{Value, json};
use std::{
    path::{Path, PathBuf},
    time::Duration,
};
use unicode_normalization::UnicodeNormalization;
pub mod backup;
pub mod catalog;
pub mod logos;
pub mod media;
mod merchant_resources;
pub mod receipts;
pub mod reports;
pub type Result<T> = std::result::Result<T, AppError>;
pub const UNCATEGORIZED: &str = "00000000-0000-4000-8000-000000000001";
pub fn now() -> i64 {
    chrono::Utc::now().timestamp_millis()
}
pub fn id() -> String {
    uuid::Uuid::new_v4().to_string()
}
pub fn normalized(s: &str) -> String {
    s.split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .nfc()
        .collect()
}
pub fn io_error(e: impl std::fmt::Display) -> AppError {
    tracing::error!(error=%e,"storage failure");
    AppError::new(500, "storage_error", "数据存储失败，请重试")
}
pub fn sql_error(e: rusqlite::Error) -> AppError {
    if matches!(&e,rusqlite::Error::SqliteFailure(x,_) if x.code==rusqlite::ErrorCode::ConstraintViolation)
    {
        AppError::new(422, "constraint_violation", "数据关系或字段不符合约束")
    } else {
        io_error(e)
    }
}
pub fn conflict() -> AppError {
    AppError::new(409, "version_conflict", "数据已被更新，请重新加载后编辑")
}
pub fn missing() -> AppError {
    AppError::new(404, "not_found", "记录不存在")
}
pub fn invalid() -> AppError {
    AppError::invalid("请求字段或数据关系无效")
}
pub fn text<'a>(v: &'a Value, key: &str) -> Result<&'a str> {
    v[key].as_str().ok_or_else(invalid)
}
pub fn number(v: &Value, key: &str) -> Result<i64> {
    v[key].as_i64().ok_or_else(invalid)
}
pub fn sql(v: &Value) -> SqlValue {
    match v {
        Value::String(s) => SqlValue::Text(s.clone()),
        Value::Number(n) => n
            .as_i64()
            .map(SqlValue::Integer)
            .unwrap_or_else(|| SqlValue::Real(n.as_f64().unwrap_or(0.))),
        Value::Bool(b) => SqlValue::Integer(i64::from(*b)),
        _ => SqlValue::Null,
    }
}
pub struct Store {
    pub db: Connection,
    pub root: PathBuf,
}
impl Store {
    pub fn initialize(root: &Path) -> Result<()> {
        backup::finish_restore(root)?;
        for dir in [
            "database",
            "media/originals",
            "media/derived",
            "recognition",
            "staging",
            "backups",
        ] {
            std::fs::create_dir_all(root.join(dir)).map_err(io_error)?;
        }
        let s = Self::open(root)?;
        let version: i64 =
            s.db.query_row("PRAGMA user_version", [], |r| r.get(0))
                .map_err(sql_error)?;
        if version == 0 {
            s.db.execute_batch("BEGIN IMMEDIATE").map_err(sql_error)?;
            s.db.execute_batch(include_str!("../../schema.sql"))
                .map_err(sql_error)?;
            for (code, digits) in [
                ("USD", 2),
                ("CNY", 2),
                ("EUR", 2),
                ("GBP", 2),
                ("JPY", 0),
                ("CAD", 2),
                ("AUD", 2),
                ("KRW", 0),
                ("CHF", 2),
                ("HKD", 2),
                ("TWD", 2),
                ("SGD", 2),
                ("INR", 2),
                ("KWD", 3),
                ("BHD", 3),
            ] {
                s.exec(
                    "INSERT INTO currency VALUES (?,?)",
                    &[json!(code), json!(digits)],
                )?;
            }
            for (i, key, label) in [
                (1, "uncategorized", "未分类"),
                (2, "tax", "税费"),
                (3, "tip", "小费"),
                (4, "deposit", "押金"),
                (5, "order_discount", "整单优惠"),
            ] {
                s.exec(
                    "INSERT INTO category VALUES (?,NULL,?,?)",
                    &[
                        json!(format!("00000000-0000-4000-8000-{i:012}")),
                        json!(label),
                        json!(key),
                    ],
                )?;
            }
            for label in [
                "杂货",
                "电器",
                "电子产品",
                "水果",
                "蔬菜",
                "畜禽肉",
                "水产品",
                "调料",
                "日用品",
                "家具",
                "保健品",
                "奶制品",
                "饮料",
                "坚果",
                "豆类及其制品",
                "鸡蛋",
                "大米及其制品",
                "小麦及其制品",
                "粗粮",
                "冰激凌",
                "酱料",
                "零食",
            ] {
                s.exec(
                    "INSERT INTO category VALUES (?,NULL,?,NULL)",
                    &[json!(id()), json!(label)],
                )?;
            }
            merchant_resources::seed(&s)?;
            s.db.execute_batch("COMMIT").map_err(sql_error)?;
        } else if version != 15 {
            return Err(AppError::new(
                503,
                "schema_version",
                "数据库结构不匹配，请使用当前表结构创建空库",
            ));
        }
        s.exec("UPDATE recognition_job SET status='queued',error_code=NULL,finished_at_utc_ms=NULL WHERE status='running'",&[])?;
        s.exec("UPDATE recognition_run SET status='unknown',error_code='interrupted',finished_at_utc_ms=? WHERE status IN ('queued','running')",&[json!(now())])?;
        s.cleanup_media()?;
        Ok(())
    }
    pub fn open(root: &Path) -> Result<Self> {
        let db = Connection::open(root.join("database/receipts.sqlite")).map_err(sql_error)?;
        db.busy_timeout(Duration::from_secs(5)).map_err(sql_error)?;
        db.execute_batch("PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL;")
            .map_err(sql_error)?;
        Ok(Self {
            db,
            root: root.to_owned(),
        })
    }
    pub fn exec(&self, q: &str, args: &[Value]) -> Result<usize> {
        self.db
            .execute(q, params_from_iter(args.iter().map(sql)))
            .map_err(sql_error)
    }
    pub fn rows(&self, q: &str, args: &[Value]) -> Result<Vec<Value>> {
        let mut stmt = self.db.prepare(q).map_err(sql_error)?;
        let names = stmt
            .column_names()
            .iter()
            .map(|s| s.to_string())
            .collect::<Vec<_>>();
        let rows = stmt
            .query_map(params_from_iter(args.iter().map(sql)), |row| {
                let mut obj = serde_json::Map::new();
                for (i, name) in names.iter().enumerate() {
                    obj.insert(
                        name.clone(),
                        match row.get_ref(i)? {
                            ValueRef::Null => Value::Null,
                            ValueRef::Integer(n) => json!(n),
                            ValueRef::Real(n) => json!(n),
                            ValueRef::Text(t) => json!(String::from_utf8_lossy(t)),
                            ValueRef::Blob(_) => Value::Null,
                        },
                    );
                }
                Ok(Value::Object(obj))
            })
            .map_err(sql_error)?;
        rows.collect::<std::result::Result<Vec<_>, _>>()
            .map_err(sql_error)
    }
    pub fn one(&self, q: &str, args: &[Value]) -> Result<Value> {
        self.rows(q, args)?.into_iter().next().ok_or_else(missing)
    }
    pub fn transaction<T>(&self, f: impl FnOnce() -> Result<T>) -> Result<T> {
        self.db
            .execute_batch("BEGIN IMMEDIATE")
            .map_err(sql_error)?;
        match f() {
            Ok(v) => {
                self.db.execute_batch("COMMIT").map_err(sql_error)?;
                Ok(v)
            }
            Err(e) => {
                let _ = self.db.execute_batch("ROLLBACK");
                Err(e)
            }
        }
    }
    pub fn check_version(&self, id: &str, version: i64) -> Result<Value> {
        let r = self.one("SELECT * FROM receipt WHERE receipt_id=?", &[json!(id)])?;
        if r["version"] != version {
            return Err(conflict());
        }
        Ok(r)
    }
    pub fn bump(&self, id: &str) -> Result<()> {
        self.exec("UPDATE receipt SET version=version+1,input_revision=input_revision+1,updated_at_utc_ms=? WHERE receipt_id=?",&[json!(now()),json!(id)])?;
        Ok(())
    }
    pub fn validate(&self) -> Result<()> {
        if !self.rows("PRAGMA foreign_key_check", &[])?.is_empty() {
            return Err(invalid());
        }
        let q = "SELECT l.line_id FROM receipt_line l JOIN receipt r ON r.receipt_id=l.receipt_id LEFT JOIN line_category_assignment a ON a.line_id=l.line_id LEFT JOIN line_discount d ON d.discount_line_id=l.line_id LEFT JOIN receipt_line t ON t.line_id=d.target_line_id WHERE (l.kind='item_discount' AND (a.line_id IS NOT NULL OR t.line_id IS NULL OR t.kind<>'product' OR t.receipt_id<>l.receipt_id)) OR (l.kind<>'item_discount' AND (a.line_id IS NULL OR d.discount_line_id IS NOT NULL)) OR (r.status='posted' AND l.amount_minor IS NULL)";
        if !self.rows(q, &[])?.is_empty() {
            return Err(invalid());
        }
        for row in self.rows("SELECT l.raw_name,n.raw_name AS catalog_raw_name FROM receipt_line l JOIN product p USING(product_id) JOIN printed_name n USING(printed_name_id)", &[])? {
            if normalized(text(&row,"raw_name")?) != text(&row,"catalog_raw_name")? {
                return Err(invalid());
            }
        }
        // The catalogue is exactly the live confirmed product set; drafts/trash are local.
        for query in [
            "SELECT 1 FROM product p WHERE NOT EXISTS (SELECT 1 FROM receipt_line l JOIN receipt r USING(receipt_id) WHERE l.product_id=p.product_id AND r.status='posted' AND r.deleted_at_utc_ms IS NULL) LIMIT 1",
            "SELECT 1 FROM printed_name n WHERE NOT EXISTS (SELECT 1 FROM product p WHERE p.printed_name_id=n.printed_name_id) LIMIT 1",
            "SELECT 1 FROM product_name n WHERE NOT EXISTS (SELECT 1 FROM printed_name_product_name m WHERE m.product_name_id=n.product_name_id) LIMIT 1",
            "SELECT 1 FROM receipt_line l JOIN receipt r USING(receipt_id) WHERE l.product_id IS NOT NULL AND (r.status<>'posted' OR r.deleted_at_utc_ms IS NOT NULL) LIMIT 1",
            "SELECT 1 FROM receipt_line l JOIN receipt r USING(receipt_id) WHERE l.kind='product' AND length(trim(l.raw_name))>0 AND l.product_id IS NULL AND r.status='posted' AND r.deleted_at_utc_ms IS NULL LIMIT 1",
            "SELECT 1 FROM line_product_name_candidate c JOIN receipt_line l USING(line_id) JOIN receipt r USING(receipt_id) WHERE l.kind<>'product' OR (r.status='posted' AND r.deleted_at_utc_ms IS NULL) LIMIT 1",
        ] {
            if !self.rows(query, &[])?.is_empty() {
                return Err(invalid());
            }
        }
        Ok(())
    }
}
