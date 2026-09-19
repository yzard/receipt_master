//! Operator-owned prompt routing. Merchant identity comes only from the Logo catalog.
use serde::Deserialize;
use std::collections::HashSet;

#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct General {
    pub prompt: String,
}
#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Merchant {
    pub name: String,
    #[serde(default)]
    pub aliases: Vec<String>,
    pub prompt: String,
}
#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Prompts {
    pub general: Vec<General>,
    #[serde(default)]
    pub store: Vec<Merchant>,
}
fn key(value: &str) -> String {
    value
        .chars()
        .filter(|c| c.is_alphanumeric())
        .flat_map(char::to_lowercase)
        .collect()
}
impl Prompts {
    pub fn parse(text: &str) -> Result<Self, Box<dyn std::error::Error + Send + Sync>> {
        let config: Self = toml::from_str(text)?;
        if config.general.is_empty() || config.general.iter().any(|p| p.prompt.trim().is_empty()) {
            return Err("At least one nonempty general prompt is required".into());
        }
        let mut names = HashSet::new();
        for store in &config.store {
            if store.prompt.trim().is_empty() {
                return Err("Empty store prompt".into());
            }
            let mut own = HashSet::new();
            for name in std::iter::once(&store.name).chain(store.aliases.iter()) {
                let normalized = key(name);
                if normalized.is_empty() {
                    return Err("Empty store name or alias".into());
                }
                // Punctuation/case variants of the same merchant may normalize identically.
                if own.insert(normalized.clone()) && !names.insert(normalized) {
                    return Err("Store names/aliases must not overlap across prompts".into());
                }
            }
        }
        Ok(config)
    }
    pub fn select(&self, merchant: Option<&str>) -> (String, String) {
        let selected = merchant.and_then(|name| {
            self.store.iter().find(|s| {
                std::iter::once(&s.name)
                    .chain(s.aliases.iter())
                    .any(|n| key(n) == key(name))
            })
        });
        let mut text = self
            .general
            .iter()
            .map(|p| p.prompt.as_str())
            .collect::<Vec<_>>()
            .join("\n\n");
        if let Some(store) = selected {
            text.push_str("\n\n");
            text.push_str(&store.prompt);
        }
        (
            text,
            selected
                .map(|s| s.name.clone())
                .unwrap_or_else(|| "general".into()),
        )
    }
}
