//! 系统通知的本地去重状态。
//!
//! `id -> cgc://` 的映射同时承担两件事：避免同一通知重复弹，以及用户点击系统
//! 通知时把 tag 还原成目标路由。状态只保存最近 200 条，避免文件无限增长。

use std::collections::BTreeMap;

use serde_json::{json, Value};

const MAX_SEEN: usize = 200;

fn state_file() -> std::path::PathBuf {
    cgc_platform::paths::AppPaths::from_env().notification_state_file()
}

pub fn load_seen() -> BTreeMap<String, String> {
    let Ok(raw) = std::fs::read_to_string(state_file()) else {
        return BTreeMap::new();
    };
    parse_seen(&raw)
}

pub fn save_seen(seen: &BTreeMap<String, String>) {
    let path = state_file();
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let payload = json!({ "seen": seen }).to_string();
    let tmp = path.with_extension("json.tmp");
    if std::fs::write(&tmp, payload).is_ok() {
        let _ = std::fs::rename(tmp, path);
    }
}

/// 首次启动且积压超过 3 条时合并成一条摘要，避免通知中心刷屏。
pub fn should_summarize(first_launch: bool, count: usize) -> bool {
    first_launch && count > 3
}

pub fn remember(seen: &mut BTreeMap<String, String>, id: &str, deep_link: &str) {
    seen.insert(id.to_string(), deep_link.to_string());
    while seen.len() > MAX_SEEN {
        let Some(oldest) = seen.keys().next().cloned() else {
            break;
        };
        seen.remove(&oldest);
    }
}

fn parse_seen(raw: &str) -> BTreeMap<String, String> {
    let Ok(value) = serde_json::from_str::<Value>(raw) else {
        return BTreeMap::new();
    };
    value
        .get("seen")
        .and_then(Value::as_object)
        .map(|map| {
            map.iter()
                .filter_map(|(id, link)| Some((id.clone(), link.as_str()?.to_string())))
                .collect()
        })
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn state_round_trips_and_ignores_bad_entries() {
        let raw = r#"{"seen":{"n1":"cgc://workspace","n2":3,"n3":"cgc://events"}}"#;
        let seen = parse_seen(raw);
        assert_eq!(seen.get("n1").map(String::as_str), Some("cgc://workspace"));
        assert!(!seen.contains_key("n2"));
        assert_eq!(seen.get("n3").map(String::as_str), Some("cgc://events"));
    }

    #[test]
    fn only_large_first_launch_is_summarized() {
        assert!(!should_summarize(false, 10));
        assert!(!should_summarize(true, 3));
        assert!(should_summarize(true, 4));
    }

    #[test]
    fn remember_caps_growth() {
        let mut seen = BTreeMap::new();
        for index in 0..(MAX_SEEN + 5) {
            remember(&mut seen, &format!("n{index:03}"), "cgc://workspace");
        }
        assert_eq!(seen.len(), MAX_SEEN);
        assert!(!seen.contains_key("n000"));
        assert!(seen.contains_key("n204"));
    }
}
