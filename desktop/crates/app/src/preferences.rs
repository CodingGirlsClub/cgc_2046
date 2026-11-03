//! 桌面端本地偏好：窗口关闭到托盘等非账号级设置。

use std::path::PathBuf;

use serde_json::{json, Value};

use crate::approval_rules::ToolPermissionSettings;

/// 面板停靠侧（Zed 的 Dock Left / Dock Right）。
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum PanelSide {
    #[default]
    Left,
    Right,
}

impl PanelSide {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Left => "left",
            Self::Right => "right",
        }
    }

    pub fn from_value(value: Option<&str>) -> Self {
        match value {
            Some("right") => Self::Right,
            _ => Self::Left,
        }
    }
}

/// 面板宽度默认值的可调范围；设置页 number field 与 preferences 解析共用。
pub const AGENT_PANEL_WIDTH_RANGE: std::ops::RangeInclusive<f64> = 240.0..=560.0;
pub const DOCK_WIDTH_RANGE: std::ops::RangeInclusive<f64> = 200.0..=480.0;

fn clamp_width(value: f64, range: std::ops::RangeInclusive<f64>, fallback: f64) -> f64 {
    if value.is_finite() && range.contains(&value) {
        value
    } else {
        fallback
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Preferences {
    pub close_to_tray: bool,
    pub tray_hint_shown: bool,
    pub native_agent_enabled: bool,
    /// Stage 3.2b：settings 级审批规则（`toolPermissions`），缺省 = 全部询问。
    pub tool_permissions: ToolPermissionSettings,
    /// Stage 3.3：历史侧栏开关状态（重启后恢复；Zed threads_sidebar 语义）。
    pub history_sidebar_open: bool,
    /// 输入光标闪烁策略（映射到 Kit `Theme::cursor_blink`）。
    pub cursor_blink: CursorBlinkPreference,
    /// Panels → Agent Panel：默认宽度（px）。仅新工作台使用；已有记录优先。
    pub agent_panel_width: f64,
    /// Panels → Dock：默认宽度（px）。仅新工作台使用；已有记录优先。
    pub dock_width: f64,
    /// Panels → Agent Panel：停靠侧。
    pub agent_panel_side: PanelSide,
    /// Panels → Dock：停靠侧。
    pub dock_side: PanelSide,
    /// Window & Layout → Status Bar：是否显示历史对话按钮。
    pub status_bar_history_button: bool,
    /// Panels → Agent Panel：状态栏是否显示 Agent 按钮。
    pub agent_panel_button: bool,
    /// Panels → Dock：新工作台首次打开时是否展开右侧 Dock。
    pub dock_starts_open: bool,
    /// Panels → Dock：状态栏是否显示导航按钮。
    pub dock_navigation_button: bool,
    /// Panels → Dock：状态栏是否显示课程目录按钮。
    pub dock_outline_button: bool,
    /// Panels → Dock：站点树是否显示未报名课程。
    pub dock_show_unenrolled: bool,
    /// Window & Layout → Title Bar：是否显示品牌名。
    pub title_bar_brand: bool,
    /// Window & Layout → Title Bar：是否显示面包屑。
    pub title_bar_breadcrumb: bool,
    /// Window & Layout → Title Bar：是否显示通知按钮。
    pub title_bar_notifications: bool,
}

/// 输入光标闪烁策略。默认跟随 Kit 的 500ms 闪烁。
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum CursorBlinkPreference {
    #[default]
    Blinking,
    /// 常亮：不启动闪烁计时器。
    Steady,
}

impl CursorBlinkPreference {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Blinking => "blinking",
            Self::Steady => "steady",
        }
    }

    /// 解析 JSON / 设置项值；未知值回退默认（闪烁）。
    pub fn from_value(value: Option<&str>) -> Self {
        match value {
            Some("steady") => Self::Steady,
            _ => Self::Blinking,
        }
    }
}

impl Default for Preferences {
    fn default() -> Self {
        Self {
            close_to_tray: true,
            tray_hint_shown: false,
            native_agent_enabled: true,
            tool_permissions: ToolPermissionSettings::default(),
            history_sidebar_open: false,
            cursor_blink: CursorBlinkPreference::default(),
            agent_panel_width: 380.0,
            dock_width: 288.0,
            agent_panel_side: PanelSide::Left,
            dock_side: PanelSide::Right,
            status_bar_history_button: true,
            agent_panel_button: true,
            dock_starts_open: true,
            dock_navigation_button: true,
            dock_outline_button: true,
            dock_show_unenrolled: true,
            title_bar_brand: true,
            title_bar_breadcrumb: true,
            title_bar_notifications: true,
        }
    }
}

fn bool_field(value: &Value, key: &str, fallback: bool) -> bool {
    value.get(key).and_then(Value::as_bool).unwrap_or(fallback)
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
        cursor_blink: CursorBlinkPreference::from_value(
            value.get("cursorBlink").and_then(Value::as_str),
        ),
        agent_panel_width: clamp_width(
            value
                .get("agentPanelWidth")
                .and_then(Value::as_f64)
                .unwrap_or(380.0),
            AGENT_PANEL_WIDTH_RANGE,
            380.0,
        ),
        dock_width: clamp_width(
            value
                .get("dockWidth")
                .and_then(Value::as_f64)
                .unwrap_or(288.0),
            DOCK_WIDTH_RANGE,
            288.0,
        ),
        agent_panel_side: PanelSide::from_value(
            value.get("agentPanelSide").and_then(Value::as_str),
        ),
        dock_side: match value.get("dockSide").and_then(Value::as_str) {
            Some("left") => PanelSide::Left,
            _ => PanelSide::Right,
        },
        status_bar_history_button: bool_field(value, "statusBarHistoryButton", true),
        agent_panel_button: bool_field(value, "agentPanelButton", true),
        dock_starts_open: bool_field(value, "dockStartsOpen", true),
        dock_navigation_button: bool_field(value, "dockNavigationButton", true),
        dock_outline_button: bool_field(value, "dockOutlineButton", true),
        dock_show_unenrolled: bool_field(value, "dockShowUnenrolled", true),
        title_bar_brand: bool_field(value, "titleBarBrand", true),
        title_bar_breadcrumb: bool_field(value, "titleBarBreadcrumb", true),
        title_bar_notifications: bool_field(value, "titleBarNotifications", true),
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
        "cursorBlink": preferences.cursor_blink.as_str(),
        "agentPanelWidth": preferences.agent_panel_width,
        "dockWidth": preferences.dock_width,
        "agentPanelSide": preferences.agent_panel_side.as_str(),
        "dockSide": preferences.dock_side.as_str(),
        "statusBarHistoryButton": preferences.status_bar_history_button,
        "agentPanelButton": preferences.agent_panel_button,
        "dockStartsOpen": preferences.dock_starts_open,
        "dockNavigationButton": preferences.dock_navigation_button,
        "dockOutlineButton": preferences.dock_outline_button,
        "dockShowUnenrolled": preferences.dock_show_unenrolled,
        "titleBarBrand": preferences.title_bar_brand,
        "titleBarBreadcrumb": preferences.title_bar_breadcrumb,
        "titleBarNotifications": preferences.title_bar_notifications,
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
    fn cursor_blink_preference_parses_and_defaults_to_blinking() {
        assert_eq!(
            CursorBlinkPreference::default(),
            CursorBlinkPreference::Blinking
        );
        assert_eq!(
            CursorBlinkPreference::from_value(Some("steady")),
            CursorBlinkPreference::Steady
        );
        assert_eq!(
            CursorBlinkPreference::from_value(Some("blinking")),
            CursorBlinkPreference::Blinking
        );
        for unknown in [Some("nonsense"), None] {
            assert_eq!(
                CursorBlinkPreference::from_value(unknown),
                CursorBlinkPreference::Blinking,
                "未知/缺失值必须回退闪烁"
            );
        }
    }

    #[test]
    fn new_preferences_parse_and_old_files_stay_compatible() {
        let empty = parse(&json!({}));
        assert_eq!(empty.cursor_blink, CursorBlinkPreference::Blinking);

        let configured = parse(&json!({
            "cursorBlink": "steady",
            // 旧文件可能残留已移除的 iconOverlay 字段，解析必须忽略它。
            "iconOverlay": true,
        }));
        assert_eq!(configured.cursor_blink, CursorBlinkPreference::Steady);
    }

    #[test]
    fn display_preferences_default_and_parse() {
        let defaults = Preferences::default();
        assert_eq!(defaults.agent_panel_width, 380.0);
        assert_eq!(defaults.dock_width, 288.0);
        assert!(defaults.agent_panel_button);
        assert_eq!(defaults.agent_panel_side, PanelSide::Left);
        assert_eq!(defaults.dock_side, PanelSide::Right);
        assert!(defaults.status_bar_history_button);
        assert!(defaults.dock_starts_open);
        assert!(defaults.dock_navigation_button);
        assert!(defaults.dock_outline_button);
        assert!(defaults.dock_show_unenrolled);
        assert!(defaults.title_bar_brand);
        assert!(defaults.title_bar_breadcrumb);
        assert!(defaults.title_bar_notifications);

        let configured = parse(&json!({
            "agentPanelWidth": 420,
            "dockWidth": 320,
            "agentPanelButton": false,
            "statusBarHistoryButton": false,
            "agentPanelSide": "right",
            "dockSide": "left",
            "dockStartsOpen": false,
            "dockNavigationButton": false,
            "dockOutlineButton": false,
            "dockShowUnenrolled": false,
            "titleBarBrand": false,
            "titleBarBreadcrumb": false,
            "titleBarNotifications": false,
        }));
        assert_eq!(configured.agent_panel_width, 420.0);
        assert_eq!(configured.dock_width, 320.0);
        assert!(!configured.agent_panel_button);
        assert!(!configured.status_bar_history_button);
        assert_eq!(configured.agent_panel_side, PanelSide::Right);
        assert_eq!(configured.dock_side, PanelSide::Left);
        assert!(!configured.dock_starts_open);
        assert!(!configured.dock_navigation_button);
        assert!(!configured.dock_outline_button);
        assert!(!configured.dock_show_unenrolled);
        assert!(!configured.title_bar_brand);
    }

    #[test]
    fn out_of_range_widths_fall_back_to_defaults() {
        let preferences = parse(&json!({
            "agentPanelWidth": 10,
            "dockWidth": 9999,
        }));
        assert_eq!(preferences.agent_panel_width, 380.0);
        assert_eq!(preferences.dock_width, 288.0);
    }
}
