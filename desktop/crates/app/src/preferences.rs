//! 桌面端本地偏好：窗口关闭到托盘等非账号级设置。

use std::path::PathBuf;

use serde_json::{json, Value};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Preferences {
    pub close_to_tray: bool,
    pub tray_hint_shown: bool,
    pub native_agent_enabled: bool,
}

impl Default for Preferences {
    fn default() -> Self {
        Self {
            close_to_tray: true,
            tray_hint_shown: false,
            native_agent_enabled: false,
        }
    }
}

fn preferences_file() -> PathBuf {
    cgc_platform::paths::AppPaths::from_env()
        .data_root
        .join("preferences.json")
}

pub fn load() -> Preferences {
    let Ok(raw) = std::fs::read_to_string(preferences_file()) else {
        return Preferences::default();
    };
    let Ok(value) = serde_json::from_str::<Value>(&raw) else {
        return Preferences::default();
    };
    Preferences {
        close_to_tray: value
            .get("closeToTray")
            .and_then(Value::as_bool)
            .unwrap_or(true),
        tray_hint_shown: value
            .get("trayHintShown")
            .and_then(Value::as_bool)
            .unwrap_or(false),
        native_agent_enabled: value
            .get("nativeAgentEnabled")
            .and_then(Value::as_bool)
            .unwrap_or(false),
    }
}

pub fn save(preferences: Preferences) {
    let path = preferences_file();
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let payload = json!({
        "closeToTray": preferences.close_to_tray,
        "trayHintShown": preferences.tray_hint_shown,
        "nativeAgentEnabled": preferences.native_agent_enabled,
    })
    .to_string();
    let tmp = path.with_extension("json.tmp");
    if std::fs::write(&tmp, payload).is_ok() {
        let _ = std::fs::rename(tmp, path);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_keep_app_in_tray() {
        let defaults = Preferences::default();
        assert!(defaults.close_to_tray);
        assert!(!defaults.tray_hint_shown);
        assert!(!defaults.native_agent_enabled);
    }

    #[test]
    fn preferences_round_trip_shape() {
        let value = json!({
            "closeToTray": false,
            "trayHintShown": true,
            "nativeAgentEnabled": true,
        });
        assert_eq!(
            value.get("closeToTray").and_then(Value::as_bool),
            Some(false)
        );
        assert_eq!(
            value.get("trayHintShown").and_then(Value::as_bool),
            Some(true)
        );
        assert_eq!(
            value.get("nativeAgentEnabled").and_then(Value::as_bool),
            Some(true)
        );
    }
}
