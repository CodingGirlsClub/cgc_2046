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

#[derive(Clone, Debug, PartialEq)]
pub(crate) struct WorkspaceEntry {
    pub(crate) tabs: Vec<PersistedTab>,
    pub(crate) active_tab: Option<String>,
    pub(crate) site_tree_events_open: bool,
    pub(crate) site_tree_courses_open: bool,
    pub(crate) site_tree_query: String,
    pub(crate) right_panel_width: f32,
}

impl Default for WorkspaceEntry {
    fn default() -> Self {
        Self {
            tabs: Vec::new(),
            active_tab: None,
            site_tree_events_open: true,
            site_tree_courses_open: true,
            site_tree_query: String::new(),
            right_panel_width: 288.0,
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
                    .unwrap_or(true),
                site_tree_courses_open: entry
                    .get("site_tree_courses_open")
                    .and_then(Value::as_bool)
                    .unwrap_or(true),
                site_tree_query: entry
                    .get("site_tree_query")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_string(),
                right_panel_width: entry
                    .get("right_panel_width")
                    .and_then(Value::as_f64)
                    .map(|width| width as f32)
                    .unwrap_or(288.0)
                    .clamp(240.0, 420.0),
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
            (
                workspace_id.clone(),
                json!({
                    "tabs": tabs,
                    "active_tab": entry.active_tab,
                    "site_tree_events_open": entry.site_tree_events_open,
                    "site_tree_courses_open": entry.site_tree_courses_open,
                    "site_tree_query": entry.site_tree_query,
                    "right_panel_width": entry.right_panel_width,
                }),
            )
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
            right_panel_width: 320.0,
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
