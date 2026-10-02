pub const UNUSED: &str = include_str!("unused_merchants.sql");
pub const DELETE_UNUSED: [&str; 4] = [
    "DELETE FROM sku WHERE merchant_id=?1",
    "DELETE FROM store_location WHERE merchant_id=?1",
    "DELETE FROM merchant_alias WHERE merchant_id=?1",
    "DELETE FROM merchant WHERE merchant_id=?1",
];
