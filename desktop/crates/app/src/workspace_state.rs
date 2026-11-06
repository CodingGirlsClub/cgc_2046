//! Workspace 级本地状态：Pane Tabs、active tab、Site Tree 展开状态。
//!
//! 只保存导航元数据（path/title/issue id），不保存课程正文、对话或凭证；
//! 文件按 workspace 分桶，避免跨工作台串内容。

use std::collections::BTreeMap;
use std::path::PathBuf;

use serde_json::{json, Value};

#[derive(Clone, Debug, Default, PartialEq)]
pub(crate) struct WorkspaceState {
    pub(crate) workspaces: BTreeMap<String, WorkspaceEntry>,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub(crate) struct WorkspaceEntry {
    pub(crate) tabs: Vec<PersistedTab>,
    pub(crate) active_tab: Option<String>,
    pub(crate) site_tree_events_open: bool,
    pub(crate) site_tree_courses_open: bool,
    pub(crate) site_tree_query: String,
    pub(crate) site_tree_course_open: Option<String>,
    pub(crate) site_tree_scroll_y: f32,
    /// None 表示布局没有工作台覆盖，使用 Panels 偏好；导航仍独立保存。
    pub(crate) layout: Option<PanelLayout>,
}

#[derive(Clone, Debug, PartialEq)]
pub(crate) struct PanelLayout {
    pub(crate) right_panel_width: f32,
    pub(crate) agent_panel_width: f32,
    pub(crate) agent_panel_open: bool,
    pub(crate) right_panel_open: bool,
    pub(crate) right_panel: PersistedRightPanel,
}

/// 右侧 Dock 持久化的 panel 取值（只存导航与课程目录）。
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) enum PersistedRightPanel {
    #[default]
    SiteTree,
    Outline,
}

impl PersistedRightPanel {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::SiteTree => "site_tree",
            Self::Outline => "outline",
        }
    }

    pub(crate) fn from_value(value: Option<&str>) -> Self {
        match value {
            Some("outline") => Self::Outline,
            _ => Self::SiteTree,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct PersistedTab {
    pub(crate) id: String,
    pub(crate) title: String,
    pub(crate) path: String,
    pub(crate) issue_id: Option<String>,
}

fn state_path() -> PathBuf {
    if let Some(path) = std::env::var_os("CGC_WORKSPACE_STATE_FILE") {
        return path.into();
    }
    cgc_platform::paths::AppPaths::from_env().workspace_state_file()
}

fn parse_layout(entry: &Value) -> Option<PanelLayout> {
    let fields = [
        "right_panel_width",
        "agent_panel_width",
        "agent_panel_open",
        "right_panel_open",
        "right_panel",
    ];
    if fields.iter().all(|field| entry.get(field).is_none()) {
        return None;
    }
    Some(PanelLayout {
        right_panel_width: entry
            .get("right_panel_width")
            .and_then(Value::as_f64)
            .map(|width| width as f32)
            .unwrap_or(288.0)
            .clamp(200.0, 480.0),
        agent_panel_width: entry
            .get("agent_panel_width")
            .and_then(Value::as_f64)
            .map(|width| width as f32)
            .unwrap_or(380.0)
            .clamp(240.0, 560.0),
        agent_panel_open: entry
            .get("agent_panel_open")
            .and_then(Value::as_bool)
            .unwrap_or(true),
        right_panel_open: entry
            .get("right_panel_open")
            .and_then(Value::as_bool)
            .unwrap_or(true),
        right_panel: PersistedRightPanel::from_value(
            entry.get("right_panel").and_then(Value::as_str),
        ),
    })
}

pub(crate) fn load() -> WorkspaceState {
    let Ok(raw) = std::fs::read_to_string(state_path()) else {
        return WorkspaceState::default();
    };
    let Ok(value) = serde_json::from_str::<Value>(&raw) else {
        return WorkspaceState::default();
    };
    let Some(workspaces) = value.get("workspaces").and_then(Value::as_object) else {
        return WorkspaceState::default();
    };
    let mut state = WorkspaceState::default();
    for (workspace_id, entry) in workspaces {
        let tabs = entry
            .get("tabs")
            .and_then(Value::as_array)
            .map(|tabs| tabs.iter().filter_map(parse_tab).collect())
            .unwrap_or_default();
        state.workspaces.insert(
            workspace_id.clone(),
            WorkspaceEntry {
                tabs,
                active_tab: entry
                    .get("active_tab")
                    .and_then(Value::as_str)
                    .map(str::to_string),
                site_tree_events_open: entry
                    .get("site_tree_events_open")
                    .and_then(Value::as_bool)
                    .unwrap_or(false),
                site_tree_courses_open: entry
                    .get("site_tree_courses_open")
                    .and_then(Value::as_bool)
                    .unwrap_or(false),
                site_tree_query: entry
                    .get("site_tree_query")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_string(),
                site_tree_course_open: entry
                    .get("site_tree_course_open")
                    .and_then(Value::as_str)
                    .map(str::to_string),
                site_tree_scroll_y: entry
                    .get("site_tree_scroll_y")
                    .and_then(Value::as_f64)
                    .unwrap_or(0.0) as f32,
                layout: parse_layout(entry),
            },
        );
    }
    state
}

pub(crate) fn save(state: &WorkspaceState) {
    let path = state_path();
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let workspaces = state
        .workspaces
        .iter()
        .map(|(workspace_id, entry)| {
            let tabs = entry
                .tabs
                .iter()
                .map(|tab| {
                    json!({
                        "id": tab.id,
                        "title": tab.title,
                        "path": tab.path,
                        "issue_id": tab.issue_id,
                    })
                })
                .collect::<Vec<_>>();
            let mut value = json!({
                "tabs": tabs,
                "active_tab": entry.active_tab,
                "site_tree_events_open": entry.site_tree_events_open,
                "site_tree_courses_open": entry.site_tree_courses_open,
                "site_tree_query": entry.site_tree_query,
                "site_tree_course_open": entry.site_tree_course_open,
                "site_tree_scroll_y": entry.site_tree_scroll_y,
            });
            if let Some(layout) = &entry.layout {
                let fields = value.as_object_mut().expect("workspace entry object");
                fields.insert("right_panel_width".into(), json!(layout.right_panel_width));
                fields.insert("agent_panel_width".into(), json!(layout.agent_panel_width));
                fields.insert("agent_panel_open".into(), json!(layout.agent_panel_open));
                fields.insert("right_panel_open".into(), json!(layout.right_panel_open));
                fields.insert("right_panel".into(), json!(layout.right_panel.as_str()));
            }
            (workspace_id.clone(), value)
        })
        .collect::<serde_json::Map<_, _>>();
    let raw = serde_json::to_string_pretty(&json!({ "workspaces": workspaces }))
        .unwrap_or_else(|_| "{\"workspaces\":{}}".to_string());
    let _ = std::fs::write(path, raw);
}

pub(crate) fn entry(workspace_id: &str) -> Option<WorkspaceEntry> {
    load().workspaces.remove(workspace_id)
}

pub(crate) fn save_entry(workspace_id: &str, entry: WorkspaceEntry) {
    let mut state = load();
    state.workspaces.insert(workspace_id.to_string(), entry);
    save(&state);
}

fn parse_tab(value: &Value) -> Option<PersistedTab> {
    Some(PersistedTab {
        id: value.get("id").and_then(Value::as_str)?.to_string(),
        title: value
            .get("title")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string(),
        path: value.get("path").and_then(Value::as_str)?.to_string(),
        issue_id: value
            .get("issue_id")
            .and_then(Value::as_str)
            .map(str::to_string),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip_keeps_tabs_and_expansion() {
        let dir = std::env::temp_dir().join(format!("cgc-workspace-state-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("mkdir");
        let path = dir.join("workspace_state.json");
        let previous = std::env::var_os("CGC_WORKSPACE_STATE_FILE");
        std::env::set_var("CGC_WORKSPACE_STATE_FILE", &path);
        let entry = WorkspaceEntry {
            tabs: vec![PersistedTab {
                id: "page:/courses".to_string(),
                title: "课程".to_string(),
                path: "/courses".to_string(),
                issue_id: None,
            }],
            active_tab: Some("page:/courses".to_string()),
            site_tree_events_open: false,
            site_tree_courses_open: true,
            site_tree_query: "hitl".to_string(),
            site_tree_course_open: Some("crs-002".to_string()),
            site_tree_scroll_y: 42.0,
            layout: Some(PanelLayout {
                right_panel_width: 320.0,
                agent_panel_width: 360.0,
                agent_panel_open: false,
                right_panel_open: true,
                right_panel: PersistedRightPanel::Outline,
            }),
        };
        save_entry("ws-1", entry.clone());
        assert_eq!(super::entry("ws-1"), Some(entry));
        assert_eq!(super::entry("ws-2"), None);
        if let Some(previous) = previous {
            std::env::set_var("CGC_WORKSPACE_STATE_FILE", previous);
        } else {
            std::env::remove_var("CGC_WORKSPACE_STATE_FILE");
        }
        let _ = std::fs::remove_dir_all(&dir);
    }
}
