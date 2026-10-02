pub const LIST: &str =
    "SELECT * FROM receipt_type ORDER BY system_key IS NULL, name, receipt_type_id";
pub const GET: &str = "SELECT * FROM receipt_type WHERE receipt_type_id=?1";
pub const BY_NAME: &str = "SELECT * FROM receipt_type WHERE name=?1 COLLATE NOCASE";
pub const INSERT: &str = "INSERT INTO receipt_type VALUES (?1,?2,NULL)";
pub const RENAME: &str = "UPDATE receipt_type SET name=?1 WHERE receipt_type_id=?2";
pub const DELETE: &str = "DELETE FROM receipt_type WHERE receipt_type_id=?1";
pub const MERCHANTS: &str = "SELECT m.*, COALESCE(t.receipt_type_id,'10000000-0000-4000-8000-000000000001') AS receipt_type_id FROM merchant m LEFT JOIN merchant_receipt_type t USING(merchant_id) WHERE EXISTS (SELECT 1 FROM logo_sample l JOIN media_blob b ON b.blob_id=l.blob_id WHERE l.merchant_id=m.merchant_id) ORDER BY m.name,m.merchant_id";
pub const MERCHANT_BY_NAME: &str = "SELECT t.receipt_type_id FROM merchant m JOIN merchant_receipt_type t USING(merchant_id) WHERE m.name=?1 COLLATE NOCASE ORDER BY m.merchant_id LIMIT 1";
pub const GET_MERCHANT: &str = "SELECT merchant_id FROM merchant WHERE merchant_id=?1";
pub const SET_MERCHANT: &str = "INSERT INTO merchant_receipt_type VALUES (?1,?2) ON CONFLICT(merchant_id) DO UPDATE SET receipt_type_id=excluded.receipt_type_id";
pub const GET_RECEIPT: &str =
    "SELECT receipt_type_id FROM receipt_type_assignment WHERE receipt_id=?1";
pub const SET_RECEIPT: &str = "INSERT INTO receipt_type_assignment VALUES (?1,?2) ON CONFLICT(receipt_id) DO UPDATE SET receipt_type_id=excluded.receipt_type_id";
pub const GET_LINE: &str =
    "SELECT receipt_type_id FROM line_effective_receipt_type WHERE line_id=?1";
pub const SET_LINE: &str = "INSERT INTO line_receipt_type_assignment VALUES (?1,?2)";
pub const DETACH: [&str; 3] = [
    "UPDATE merchant_receipt_type SET receipt_type_id=?1 WHERE receipt_type_id=?2",
    "UPDATE receipt_type_assignment SET receipt_type_id=?1 WHERE receipt_type_id=?2",
    "UPDATE line_receipt_type_assignment SET receipt_type_id=?1 WHERE receipt_type_id=?2",
];
pub const TOTALS: &str = "
SELECT r.receipt_id, r.total_minor, rr.difference_minor, r.currency_code, r.occurred_at_utc_ms
     , COALESCE(t.receipt_type_id,'10000000-0000-4000-8000-000000000001') AS receipt_type_id
  FROM receipt r JOIN receipt_reconciliation rr USING(receipt_id)
  LEFT JOIN receipt_type_assignment t USING(receipt_id)
 WHERE r.status='posted' AND r.deleted_at_utc_ms IS NULL
   AND r.occurred_at_utc_ms>=?1 AND r.occurred_at_utc_ms<?2";
pub const LINE_TOTALS: &str = "
SELECT l.receipt_id, l.amount_minor, r.currency_code, r.occurred_at_utc_ms
  FROM receipt_line l JOIN receipt r USING(receipt_id)
 WHERE r.status='posted' AND r.deleted_at_utc_ms IS NULL
   AND r.occurred_at_utc_ms>=?1 AND r.occurred_at_utc_ms<?2";

pub const REPORT_ENTRIES: &str = "SELECT l.*,r.currency_code,r.occurred_at_utc_ms,r.raw_store,COALESCE(a.name,(SELECT raw_name FROM receipt_line WHERE line_id=d.target_line_id)) AS product_name,CAST(ROUND(COALESCE(p.weight_g,w.weight_g)*1000) AS INTEGER) AS weight_mg,ec.category_id,c.name AS category_name,et.receipt_type_id,rt.name AS receipt_type_name,d.target_line_id FROM receipt_line l JOIN receipt r ON r.receipt_id=l.receipt_id JOIN line_effective_category ec ON ec.line_id=l.line_id JOIN category c ON c.category_id=ec.category_id JOIN line_effective_receipt_type et ON et.line_id=l.line_id JOIN receipt_type rt ON rt.receipt_type_id=et.receipt_type_id LEFT JOIN line_discount d ON d.discount_line_id=l.line_id LEFT JOIN product p ON p.product_id=COALESCE(l.product_id,(SELECT product_id FROM receipt_line WHERE line_id=d.target_line_id)) LEFT JOIN printed_name n ON n.printed_name_id=p.printed_name_id LEFT JOIN printed_name_product_name m ON m.printed_name_id=n.printed_name_id LEFT JOIN product_name a ON a.product_name_id=m.product_name_id LEFT JOIN line_unmatched_weight w ON w.line_id=l.line_id";
