//! Script detection only; never convert the OCR text or normalize product names.
use std::{collections::HashSet, sync::LazyLock};

fn distinct_keys(dictionary: &str) -> HashSet<char> {
    dictionary
        .lines()
        .filter_map(|line| {
            let (key, values) = line.split_once('\t')?;
            let mut chars = key.chars();
            let ch = chars.next()?;
            if chars.next().is_some() || values.split_whitespace().any(|v| v == key) {
                return None;
            }
            Some(ch)
        })
        .collect()
}
static FORMS: LazyLock<(HashSet<char>, HashSet<char>)> = LazyLock::new(|| {
    let traditional = distinct_keys(include_str!("../../resources/chinese/TSCharacters.txt"));
    let simplified = distinct_keys(include_str!("../../resources/chinese/STCharacters.txt"));
    (
        traditional.difference(&simplified).copied().collect(),
        simplified.difference(&traditional).copied().collect(),
    )
});

pub(super) fn traditional(text: &str, page_is_traditional: bool) -> bool {
    let traditional = text.chars().filter(|c| FORMS.0.contains(c)).count();
    let simplified = text.chars().filter(|c| FORMS.1.contains(c)).count();
    traditional > simplified || (traditional == 0 && simplified == 0 && page_is_traditional)
}
