//! 桌面端本地偏好：窗口关闭到托盘等非账号级设置。

use std::path::PathBuf;

use serde_json::{json, Value};

use crate::approval_rules::ToolPermissionSettings;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Preferences {
    pub close_to_tray: bool,
    pub tray_hint_shown: bool,
    pub native_agent_enabled: bool,
    /// Stage 3.2b：settings 级审批规则（`toolPermissions`），缺省 = 全部询问。
    pub tool_permissions: ToolPermissionSettings,
    /// Stage 3.3：历史侧栏开关状态（重启后恢复；Zed threads_sidebar 语义）。
    pub history_sidebar_open: bool,
}

impl Default for Preferences {
    fn default() -> Self {
        Self {
            close_to_tray: true,
            tray_hint_shown: false,
            native_agent_enabled: true,
            tool_permissions: ToolPermissionSettings::default(),
            history_sidebar_open: false,
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
    parse(&value)
}

/// 从已解析的 JSON 读写偏好；旧文件缺字段全部按默认（向后兼容，无需迁移）。
fn parse(value: &Value) -> Preferences {
    let tool_permissions = value
        .get("toolPermissions")
        .cloned()
        .and_then(|raw| serde_json::from_value::<ToolPermissionSettings>(raw).ok())
        .unwrap_or_default();
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
            .unwrap_or(true),
        tool_permissions,
        history_sidebar_open: value
            .get("historySidebarOpen")
            .and_then(Value::as_bool)
            .unwrap_or(false),
    }
}

/// 只改历史侧栏开关并落盘（其它字段保持当前值）。
pub fn save_history_sidebar_open(open: bool) {
    let mut preferences = load();
    if preferences.history_sidebar_open == open {
        return;
    }
    preferences.history_sidebar_open = open;
    save(preferences);
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
        "historySidebarOpen": preferences.history_sidebar_open,
        "toolPermissions": serde_json::to_value(&preferences.tool_permissions)
            .unwrap_or(Value::Null),
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
        assert!(defaults.native_agent_enabled, "3.5b：默认开启");
    }

    #[test]
    fn history_sidebar_open_defaults_false_and_parses() {
        assert!(!Preferences::default().history_sidebar_open);
        assert!(!parse(&json!({"closeToTray": true})).history_sidebar_open);
        assert!(parse(&json!({"historySidebarOpen": true})).history_sidebar_open);
    }

    #[test]
    fn missing_tool_permissions_keeps_old_preferences_compatible() {
        let preferences = parse(&json!({
            "closeToTray": false,
            "trayHintShown": true,
            "nativeAgentEnabled": true,
        }));
        assert!(!preferences.close_to_tray);
        assert_eq!(
            preferences.tool_permissions,
            crate::approval_rules::ToolPermissionSettings::default(),
            "旧 preferences.json 无 toolPermissions 时默认全部询问"
        );
    }

    #[test]
    fn tool_permissions_are_parsed_from_preferences_json() {
        let preferences = parse(&json!({
            "toolPermissions": {
                "default": "deny",
                "tools": {
                    "run_command": {
                        "alwaysAllow": ["^ls"],
                        "alwaysDeny": ["rm -rf"],
                        "alwaysConfirm": ["git push"]
                    }
                }
            }
        }));
        assert_eq!(
            preferences.tool_permissions.default,
            crate::approval_rules::ToolPermissionDefault::Deny
        );
        let rules = preferences
            .tool_permissions
            .tools
            .get("run_command")
            .expect("run_command rules");
        assert_eq!(rules.always_allow, vec!["^ls".to_string()]);
        assert_eq!(rules.always_deny, vec!["rm -rf".to_string()]);
        assert_eq!(rules.always_confirm, vec!["git push".to_string()]);
    }

    #[test]
    fn malformed_tool_permissions_fall_back_to_defaults() {
        // 类型错误（不是对象）→ 整块规则回默认；未知 default 值 → ask。
        assert_eq!(
            parse(&json!({"toolPermissions": 3})).tool_permissions,
            crate::approval_rules::ToolPermissionSettings::default()
        );
        let preferences = parse(&json!({
            "toolPermissions": {"default": "not-a-policy"}
        }));
        assert_eq!(
            preferences.tool_permissions.default,
            crate::approval_rules::ToolPermissionDefault::Ask
        );
    }

    #[test]
    fn tool_permissions_round_trip_serialization() {
        use crate::approval_rules::{ToolPermissionDefault, ToolRuleSet};
        let mut preferences = Preferences::default();
        preferences.tool_permissions.default = ToolPermissionDefault::Allow;
        preferences.tool_permissions.tools.insert(
            "run_command".to_string(),
            ToolRuleSet {
                always_allow: vec!["^ls".to_string()],
                always_deny: vec!["rm -rf".to_string()],
                always_confirm: vec!["git push".to_string()],
            },
        );
        let serialized = serde_json::to_value(&preferences.tool_permissions).expect("serialize");
        assert_eq!(
            serialized.get("default").and_then(Value::as_str),
            Some("allow"),
            "写回 preferences.json 的 default 用小写枚举值"
        );
        assert!(serialized
            .get("tools")
            .and_then(|tools| tools.get("run_command"))
            .and_then(|rules| rules.get("alwaysAllow"))
            .is_some());
        let parsed = parse(&json!({ "toolPermissions": serialized }));
        assert_eq!(parsed.tool_permissions, preferences.tool_permissions);
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
