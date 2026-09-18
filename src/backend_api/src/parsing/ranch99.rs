//! 99 Ranch prints transaction time below contact details and weights after products.
use super::{generic, layout};
use regex::Regex;
use std::sync::LazyLock;

pub(super) fn transaction_dates(rows: &[layout::Row]) -> Vec<String> {
    static PHONE: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(
            r"(?i)^(?:(?:TEL|PHONE)\s*:?\s*)?(?:\+?1[ .-]?)?\(?\d{3}\)?[ .-]?\d{3}[ .-]?\d{4}$",
        )
        .unwrap()
    });
    static TRANSACTION: LazyLock<Regex> =
        LazyLock::new(|| Regex::new(r"^#\d+\s*-\s*\d+\s+").unwrap());
    let mut dates = Vec::new();
    let mut page = None;
    let mut header = true;
    let mut contact_seen = false;
    for row in rows {
        if page != Some(row.image) {
            page = Some(row.image);
            header = true;
            contact_seen = false;
        }
        let text = row.text.trim();
        if generic::money_at_end(text).is_some() || text.to_uppercase().starts_with("ITEM COUNT") {
            header = false;
        }
        if !header {
            continue;
        }
        contact_seen |= PHONE.is_match(text);
        // A transaction register prefix also identifies the header if OCR missed the phone.
        if (contact_seen || TRANSACTION.is_match(text))
            && let Some(date) = generic::date(text)
            && !dates.contains(&date)
        {
            dates.push(date);
        }
    }
    dates
}
