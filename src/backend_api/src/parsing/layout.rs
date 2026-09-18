use regex::Regex;
use serde_json::Value;

#[derive(Clone, Debug)]
pub struct Row {
    pub text: String,
    pub leading_spaces: usize,
    pub image: usize,
    pub box_: [f64; 4],
    pub confidence: Option<f64>,
    pub notes: Vec<String>,
}
fn clean(s: &str) -> String {
    s.replace("&amp;", "&")
        .replace("&nbsp;", " ")
        .replace("&#39;", "'")
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}
fn paddle(page: &Value, image: usize) -> Vec<Row> {
    let mut words: Vec<Row> = page["paddle"]["words"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|w| {
            let b = w["box"].as_array()?;
            if b.len() != 4 {
                return None;
            }
            let box_ = [
                b[0].as_f64()?,
                b[1].as_f64()?,
                b[2].as_f64()?,
                b[3].as_f64()?,
            ];
            if box_
                .iter()
                .any(|n| !n.is_finite() || !(0.0..=1.0).contains(n))
                || box_[0] >= box_[2]
                || box_[1] >= box_[3]
            {
                return None;
            }
            Some(Row {
                text: clean(w["text"].as_str()?),
                leading_spaces: 0,
                image,
                box_,
                confidence: w["confidence"].as_f64().filter(|v| (0.0..=1.0).contains(v)),
                notes: vec![],
            })
        })
        .collect();
    words.sort_by(|a, b| a.box_[1].total_cmp(&b.box_[1]));
    let mut groups: Vec<Vec<Row>> = Vec::new();
    for word in words {
        let center = (word.box_[1] + word.box_[3]) / 2.0;
        let group = groups.iter_mut().rev().take(4).find(|g| {
            let r = &g[0];
            let difference = (center - (r.box_[1] + r.box_[3]) / 2.0).abs();
            difference < (word.box_[3] - word.box_[1]).min(r.box_[3] - r.box_[1]) * 0.6
        });
        if let Some(g) = group {
            g.push(word);
        } else {
            groups.push(vec![word]);
        }
    }
    groups
        .into_iter()
        .map(|mut g| {
            g.sort_by(|a, b| a.box_[0].total_cmp(&b.box_[0]));
            let mut row = g[0].clone();
            row.text = g
                .iter()
                .map(|r| r.text.as_str())
                .collect::<Vec<_>>()
                .join(" ");
            for r in &g[1..] {
                row.box_[0] = row.box_[0].min(r.box_[0]);
                row.box_[1] = row.box_[1].min(r.box_[1]);
                row.box_[2] = row.box_[2].max(r.box_[2]);
                row.box_[3] = row.box_[3].max(r.box_[3]);
                row.confidence = row.confidence.zip(r.confidence).map(|(a, b)| a.min(b));
            }
            row
        })
        .collect()
}
pub fn rows(page: &Value, image: usize) -> Vec<Row> {
    let text = page["unlimited"].as_str().unwrap_or("");
    let pattern =
        Regex::new(r"<\|det\|>\w+\s*\[\s*(\d+),\s*(\d+),\s*(\d+),\s*(\d+)\s*\]<\|/det\|>").unwrap();
    let markers: Vec<_> = pattern.captures_iter(text).collect();
    let pp = paddle(page, image);
    let page_is_traditional = super::chinese::traditional(
        &pp.iter()
            .map(|r| r.text.as_str())
            .collect::<Vec<_>>()
            .join(" "),
        false,
    );
    let tags = Regex::new(r"<[^>]*>").unwrap();
    let tr = Regex::new(r"(?is)<tr[^>]*>(.*?)</tr>").unwrap();
    let mut result = Vec::new();
    for (i, c) in markers.iter().enumerate() {
        let raw = &text[c.get(0).unwrap().end()
            ..markers
                .get(i + 1)
                .map(|c| c.get(0).unwrap().start())
                .unwrap_or(text.len())];
        let b = [1, 2, 3, 4].map(|j| c[j].parse::<f64>().unwrap() / 1000.0);
        if b[0] >= b[2] || b[1] >= b[3] || b.iter().any(|v| !(0.0..=1.0).contains(v)) {
            continue;
        }
        let table: Vec<_> = tr.captures_iter(raw).collect();
        if !table.is_empty() {
            for (n, t) in table.iter().enumerate() {
                let h = (b[3] - b[1]) / table.len() as f64;
                result.push(Row {
                    text: clean(&tags.replace_all(&t[1], " ")),
                    leading_spaces: 0,
                    image,
                    box_: [b[0], b[1] + n as f64 * h, b[2], b[1] + (n + 1) as f64 * h],
                    confidence: None,
                    notes: vec![],
                });
            }
        } else {
            for line in raw.lines().filter(|l| !l.trim().is_empty()) {
                result.push(Row {
                    text: clean(line),
                    leading_spaces: indentation(line),
                    image,
                    box_: b,
                    confidence: None,
                    notes: vec![],
                });
            }
        }
    }
    if result.is_empty() {
        if !pp.is_empty() {
            return pp;
        }
        // Plain OCR fixtures and upstream text without layout have no invented boxes.
        return text
            .lines()
            .filter(|l| !l.trim().is_empty())
            .map(|text| Row {
                text: clean(text),
                leading_spaces: indentation(text),
                image,
                box_: [0.0; 4],
                confidence: None,
                notes: vec![],
            })
            .collect();
    }
    // Unlimited may emit name and price as separate regions on the same physical row.
    result.sort_by(|a, b| a.box_[1].total_cmp(&b.box_[1]));
    let mut joined: Vec<Row> = Vec::new();
    for row in result {
        let cy = (row.box_[1] + row.box_[3]) / 2.0;
        let target = joined.iter_mut().rev().take(4).find(|r| {
            ((r.box_[1] + r.box_[3]) / 2.0 - cy).abs()
                < (row.box_[3] - row.box_[1]).min(r.box_[3] - r.box_[1]) * 0.6
                && (row.box_[0] >= r.box_[2] - 0.003 || r.box_[0] >= row.box_[2] - 0.003)
        });
        if let Some(r) = target {
            r.text = if row.box_[0] < r.box_[0] {
                format!("{} {}", row.text, r.text)
            } else {
                format!("{} {}", r.text, row.text)
            };
            r.box_ = [
                r.box_[0].min(row.box_[0]),
                r.box_[1].min(row.box_[1]),
                r.box_[2].max(row.box_[2]),
                r.box_[3].max(row.box_[3]),
            ];
            r.confidence = r.confidence.zip(row.confidence).map(|(a, b)| a.min(b));
        } else {
            joined.push(row);
        }
    }
    let mut result = joined;
    let price_tail = Regex::new(r"\s+\$?\d[\d.,\s]*[A-Za-z]?$").unwrap();
    for row in &mut result {
        let cy = (row.box_[1] + row.box_[3]) / 2.0;
        let matched = pp
            .iter()
            .filter(|r| {
                ((r.box_[1] + r.box_[3]) / 2.0 - cy).abs()
                    < (row.box_[3] - row.box_[1]).min(r.box_[3] - r.box_[1]) * 0.65
            })
            .min_by(|a, b| {
                ((a.box_[1] + a.box_[3]) / 2.0 - cy)
                    .abs()
                    .total_cmp(&((b.box_[1] + b.box_[3]) / 2.0 - cy).abs())
            });
        if let Some(other) = matched {
            let normalize = |s: &str| {
                s.chars()
                    .filter(|c| c.is_alphanumeric())
                    .flat_map(char::to_uppercase)
                    .collect::<String>()
            };
            let a = normalize(&row.text);
            let b = normalize(&other.text);
            if a == b {
                row.confidence = other.confidence;
                if super::has_chinese(&other.text) && !super::summary(&row.text) {
                    row.text = other.text.clone();
                }
            } else if super::has_chinese(&other.text)
                && super::weighted(&row.text).is_none()
                && !super::summary(&row.text)
            {
                let original_text = row.text.clone();
                // Sloping price columns can be grouped with the preceding Chinese
                // translation by Paddle. A translation cannot acquire that amount.
                row.text = if super::money_at_end(&original_text).is_none() {
                    super::money_at_end(&other.text)
                        .map_or_else(|| other.text.clone(), |(name, _, _)| name)
                } else {
                    other.text.clone()
                };
                row.confidence = other.confidence;
                if !super::chinese::traditional(&other.text, page_is_traditional) {
                    row.notes
                        .push("两种 OCR 的文字不一致，中文采用 PP-OCR，请核对照片。".into());
                } else if let (Some((_, original, _)), Some((_, chosen, _))) = (
                    super::money_at_end(&original_text),
                    super::money_at_end(&other.text),
                ) && original != chosen
                {
                    row.notes
                        .push("两种 OCR 的金额不一致，已采用 PP-OCR 金额，请核对照片。".into());
                }
            } else {
                if super::money_at_end(&row.text).is_none()
                    && let Some((name, _, _)) = super::money_at_end(&other.text)
                    && normalize(&price_tail.replace(&row.text, "")) == normalize(&name)
                    && other.confidence.is_some_and(|v| v >= 0.9)
                {
                    row.text = other.text.clone();
                    row.confidence = other.confidence;
                }
                if let (Some((an, am, _)), Some((bn, bm, _))) = (
                    super::money_at_end(&row.text),
                    super::money_at_end(&other.text),
                ) && am == bm
                    && is_subsequence(&normalize(&an), &normalize(&bn))
                    && bn.len() > an.len()
                    && !bn.ends_with(" S")
                    && !bn
                        .split_whitespace()
                        .next()
                        .is_some_and(|w| w.len() > 1 && w.len() <= 4 && w.chars().all(|c| c == 'E'))
                {
                    row.text = other.text.clone();
                }
                row.notes.push("两种 OCR 的文字不一致，请核对照片。".into());
            }
        }
    }
    // Add missed rows only when their vertical range is absent from Unlimited's layout.
    for row in pp {
        let cy = (row.box_[1] + row.box_[3]) / 2.0;
        if !result
            .iter()
            .any(|r| cy >= r.box_[1] - 0.003 && cy <= r.box_[3] + 0.003)
        {
            result.push(row);
        }
    }
    result.sort_by(|a, b| a.box_[1].total_cmp(&b.box_[1]));
    result
}

fn is_subsequence(short: &str, long: &str) -> bool {
    let mut remaining = long.chars();
    short.chars().all(|c| remaining.any(|d| c == d))
}

fn indentation(text: &str) -> usize {
    text.chars()
        .take_while(|c| c.is_whitespace())
        .map(|c| if c == '\t' { 4 } else { 1 })
        .sum()
}
