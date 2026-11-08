//! Workspace 级本地状态：Pane Tabs、active tab、Site Tree 展开状态。
//!
//! 只保存导航元数据（path/title/issue id），不保存课程正文、对话或凭证；
//! 文件按 workspace 分桶，避免跨工作台串内容。

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};

use serde_json::{json, Value};

#[derive(Clone, Debug, Default, PartialEq)]
pub(crate) struct WorkspaceState {
    /// 最近一次使用的工作区 slug；`/` 的落点与启动恢复用它。
    pub(crate) last_workspace: Option<String>,
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
    pub(crate) title: String,
    /// 完整地址；`?issue=` 也在其中，tab 身份由它派生。
    pub(crate) path: String,
}

/// 进程内 workspace id → slug 映射：工作区列表加载后登记，供旧版状态文件迁移路径。
fn workspace_slugs() -> &'static Mutex<BTreeMap<String, String>> {
    static SLUGS: OnceLock<Mutex<BTreeMap<String, String>>> = OnceLock::new();
    SLUGS.get_or_init(|| Mutex::new(BTreeMap::new()))
}

/// 登记工作区 id 与 slug 的对应关系；重复登记覆盖旧值（slug 可变，id 稳定）。
pub(crate) fn remember_workspace_slugs<'a>(
    workspaces: impl IntoIterator<Item = (&'a str, &'a str)>,
) {
    let mut slugs = workspace_slugs()
        .lock()
        .unwrap_or_else(|poison| poison.into_inner());
    for (id, slug) in workspaces {
        slugs.insert(id.to_string(), slug.to_string());
    }
}

fn known_workspace_slug(workspace_id: &str) -> Option<String> {
    workspace_slugs()
        .lock()
        .unwrap_or_else(|poison| poison.into_inner())
        .get(workspace_id)
        .cloned()
}

/// 旧版文件没有 `workspace_slug` 字段；测试夹具里 bucket 键也可能直接是 slug。
fn looks_like_uuid(value: &str) -> bool {
    let bytes = value.as_bytes();
    bytes.len() == 36
        && bytes[8] == b'-'
        && bytes[13] == b'-'
        && bytes[18] == b'-'
        && bytes[23] == b'-'
        && bytes
            .iter()
            .enumerate()
            .all(|(index, byte)| matches!(index, 8 | 13 | 18 | 23) || byte.is_ascii_hexdigit())
}

fn bucket_workspace_slug(workspace_id: &str, entry: &Value) -> Option<String> {
    entry
        .get("workspace_slug")
        .and_then(Value::as_str)
        .map(str::to_string)
        .or_else(|| known_workspace_slug(workspace_id))
        .or_else(|| {
            (!looks_like_uuid(workspace_id) && crate::routing::is_safe_slug(workspace_id))
                .then(|| workspace_id.to_string())
        })
}

/// 旧版工作区 tab 的路径补 `/w/<slug>`：只迁六条工作区路由的形状，站点级 tab 原样保留。
fn migrate_legacy_workspace_path(path: &str, slug: &str) -> String {
    let (base, query) = match path.split_once('?') {
        Some((base, query)) => (base, Some(query)),
        None => (path, None),
    };
    if crate::routing::workspace_slug(base).is_some() {
        return path.to_string();
    }
    let suffix = match base {
        "/workspace" => "",
        "/courses" | "/events" => base,
        _ => {
            let segments = base
                .trim_matches('/')
                .split('/')
                .filter(|segment| !segment.is_empty())
                .collect::<Vec<_>>();
            match segments.as_slice() {
                ["courses", id] | ["events", id] if !id.is_empty() => base,
                ["courses", id, "learn"] if !id.is_empty() => base,
                _ => return path.to_string(),
            }
        }
    };
    let migrated = crate::routing::workspace_path(slug, suffix);
    match query {
        Some(query) => format!("{migrated}?{query}"),
        None => migrated,
    }
}

/// 读取一个 tab，并把旧版 `issue_id` 字段升级成地址里的 `?issue=`；
/// 旧版工作区 sheet 的 tab 还需要补工作区前缀。
fn parse_tab(
    value: &Value,
    workspace_slug: Option<&str>,
    migrate_legacy_workspace_paths: bool,
) -> Option<PersistedTab> {
    let path = value.get("path")?.as_str()?;
    let path = match value.get("issue_id").and_then(Value::as_str) {
        Some(issue) if !path.contains('?') => {
            crate::routing::path_with_issue(path, issue).unwrap_or_else(|| path.to_string())
        }
        _ => path.to_string(),
    };
    let path = match (migrate_legacy_workspace_paths, workspace_slug) {
        (true, Some(slug)) => migrate_legacy_workspace_path(&path, slug),
        _ => path,
    };
    Some(PersistedTab {
        title: value
            .get("title")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string(),
        path,
    })
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
    let mut state = WorkspaceState {
        last_workspace: value
            .get("last_workspace")
            .and_then(Value::as_str)
            .map(str::to_string),
        ..WorkspaceState::default()
    };
    let Some(workspaces) = value.get("workspaces").and_then(Value::as_object) else {
        return state;
    };
    // `last_workspace` 是路由分层（/w/:slug）时引入的字段；缺它说明整个文件是旧版。
    let migrate_legacy_workspace_paths = value.get("last_workspace").is_none();
    for (workspace_id, entry) in workspaces {
        let workspace_slug = bucket_workspace_slug(workspace_id, entry);
        let mut tabs = Vec::new();
        // 旧文件用 `issue:course:card` 这类内存 id；恢复时映射到地址派生 id。
        let mut id_map = BTreeMap::new();
        if let Some(raw_tabs) = entry.get("tabs").and_then(Value::as_array) {
            for raw in raw_tabs {
                let Some(tab) =
                    parse_tab(raw, workspace_slug.as_deref(), migrate_legacy_workspace_paths)
                else {
                    continue;
                };
                if let Some(old_id) = raw.get("id").and_then(Value::as_str) {
                    id_map.insert(old_id.to_string(), format!("page:{}", tab.path));
                }
                tabs.push(tab);
            }
        }
        let active_tab = entry
            .get("active_tab")
            .and_then(Value::as_str)
            .map(|id| id_map.get(id).cloned().unwrap_or_else(|| id.to_string()));
        state.workspaces.insert(
            workspace_id.clone(),
            WorkspaceEntry {
                tabs,
                active_tab,
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
                        "id": format!("page:{}", tab.path),
                        "title": tab.title,
                        "path": tab.path,
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
            if let Some(slug) = known_workspace_slug(workspace_id) {
                value
                    .as_object_mut()
                    .expect("workspace entry object")
                    .insert("workspace_slug".into(), json!(slug));
            }
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
    let raw = serde_json::to_string_pretty(&json!({
        "last_workspace": state.last_workspace,
        "workspaces": workspaces,
    }))
    .unwrap_or_else(|_| "{\"workspaces\":{}}".to_string());
    let _ = std::fs::write(path, raw);
}

pub(crate) fn entry(workspace_id: &str) -> Option<WorkspaceEntry> {
    load().workspaces.remove(workspace_id)
}

/// 最近使用的工作区 slug。
pub(crate) fn last_workspace() -> Option<String> {
    load().last_workspace
}

/// 记录最近使用的工作区；已相同则不重写文件。
pub(crate) fn set_last_workspace(slug: &str) {
    let mut state = load();
    if state.last_workspace.as_deref() == Some(slug) {
        return;
    }
    state.last_workspace = Some(slug.to_string());
    save(&state);
}

pub(crate) fn save_entry(workspace_id: &str, entry: WorkspaceEntry) {
    let mut state = load();
    state.workspaces.insert(workspace_id.to_string(), entry);
    save(&state);
}

/// 测试用的进程级环境锁：`CGC_WORKSPACE_STATE_FILE` 是进程级 env，凡是临时改写它的
/// 用例（本模块 + `root_view` 的隔离 guard）都必须持同一把锁，否则 CI 的裸
/// `cargo test --workspace`（并行）会互相覆盖，把隔离写成假的。
///
/// 同线程可重入：`root_view` 的 `view()` 会把 guard 存进 thread_local 直到线程退出，
/// 同一线程再显式申请时不能再 lock（`std::sync::Mutex` 不可重入），因此用 thread-local
/// 标记判断本线程是否已持锁，嵌套申请只返回空壳 guard。
#[cfg(test)]
pub(crate) mod test_env_lock {
    use std::cell::Cell;
    use std::sync::{Mutex, MutexGuard};

    static LOCK: Mutex<()> = Mutex::new(());

    thread_local! {
        static HELD_BY_CURRENT_THREAD: Cell<bool> = const { Cell::new(false) };
    }

    pub(crate) struct Guard {
        /// 只有最外层申请才真正持锁；嵌套申请为 `None`。
        lock: Option<MutexGuard<'static, ()>>,
    }

    impl Guard {
        /// 测试断言用：本 guard 是否真的持有进程锁（而非同线程嵌套的空壳）。
        pub(crate) fn holds_process_lock(&self) -> bool {
            self.lock.is_some()
        }
    }

    pub(crate) fn acquire() -> Guard {
        let nested = HELD_BY_CURRENT_THREAD.with(|held| held.replace(true));
        let lock = if nested {
            None
        } else {
            Some(LOCK.lock().unwrap_or_else(|poison| poison.into_inner()))
        };
        Guard { lock }
    }

    impl Drop for Guard {
        fn drop(&mut self) {
            if self.lock.take().is_some() {
                HELD_BY_CURRENT_THREAD.with(|held| held.set(false));
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 两个用例都会改写进程级 `CGC_WORKSPACE_STATE_FILE`，必须与 `root_view` 的隔离
    /// guard 共用同一把锁（并行运行也不互相覆盖）。
    use super::test_env_lock;

    #[test]
    fn roundtrip_keeps_tabs_and_expansion() {
        let _env = test_env_lock::acquire();
        let dir = std::env::temp_dir().join(format!("cgc-workspace-state-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("mkdir");
        let path = dir.join("workspace_state.json");
        let previous = std::env::var_os("CGC_WORKSPACE_STATE_FILE");
        std::env::set_var("CGC_WORKSPACE_STATE_FILE", &path);
        let entry = WorkspaceEntry {
            tabs: vec![PersistedTab {
                title: "课程".to_string(),
                path: "/courses".to_string(),
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
        set_last_workspace("2046");
        assert_eq!(last_workspace().as_deref(), Some("2046"));
        save_entry("ws-2", WorkspaceEntry::default());
        assert_eq!(
            last_workspace().as_deref(),
            Some("2046"),
            "saving another workspace entry must not drop the last workspace"
        );
        if let Some(previous) = previous {
            std::env::set_var("CGC_WORKSPACE_STATE_FILE", previous);
        } else {
            std::env::remove_var("CGC_WORKSPACE_STATE_FILE");
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn legacy_issue_tabs_migrate_into_their_address() {
        let _env = test_env_lock::acquire();
        let dir = std::env::temp_dir().join(format!("cgc-workspace-legacy-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("mkdir");
        let path = dir.join("workspace_state.json");
        std::fs::write(
            &path,
            r#"{"last_workspace":"2046","workspaces":{"ws-1":{
                "tabs":[
                  {"id":"page:/w/2046/courses","title":"课程","path":"/w/2046/courses","issue_id":null},
                  {"id":"issue:course-a:unit-a","title":"First task","path":"/w/2046/courses/course-a/learn","issue_id":"unit-a"}
                ],
                "active_tab":"issue:course-a:unit-a"
            }}}"#,
        )
        .expect("write legacy state");
        let previous = std::env::var_os("CGC_WORKSPACE_STATE_FILE");
        std::env::set_var("CGC_WORKSPACE_STATE_FILE", &path);

        let entry = super::entry("ws-1").expect("workspace entry");
        assert_eq!(entry.tabs.len(), 2);
        assert_eq!(
            entry.tabs[1].path,
            "/w/2046/courses/course-a/learn?issue=unit-a"
        );
        assert_eq!(
            entry.active_tab.as_deref(),
            Some("page:/w/2046/courses/course-a/learn?issue=unit-a"),
            "the legacy in-memory id must map onto the migrated address"
        );

        if let Some(previous) = previous {
            std::env::set_var("CGC_WORKSPACE_STATE_FILE", previous);
        } else {
            std::env::remove_var("CGC_WORKSPACE_STATE_FILE");
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn legacy_workspace_bucket_rewrites_paths_to_workspace_slug() {
        let _env = test_env_lock::acquire();
        let dir = std::env::temp_dir().join(format!(
            "cgc-workspace-legacy-bucket-{}",
            std::process::id()
        ));
        std::fs::create_dir_all(&dir).expect("mkdir");
        let path = dir.join("workspace_state.json");
        std::fs::write(
            &path,
            r#"{"workspaces":{"03a460fb-fcdb-471d-90d8-8ded19e157dc":{
                "tabs":[
                  {"id":"page:/courses","title":"课程","path":"/courses","issue_id":null},
                  {"id":"page:/events","title":"活动","path":"/events","issue_id":null},
                  {"id":"page:/agents","title":"Agents","path":"/agents","issue_id":null},
                  {"id":"issue:course-a:unit-a","title":"First task","path":"/courses/course-a/learn","issue_id":"unit-a"}
                ],
                "active_tab":"issue:course-a:unit-a"
            }}}"#,
        )
        .expect("write legacy state");
        // 旧版持久化只存 workspace id；运行时会先登记工作区列表再恢复 tab。
        remember_workspace_slugs([("03a460fb-fcdb-471d-90d8-8ded19e157dc", "2046")]);
        let previous = std::env::var_os("CGC_WORKSPACE_STATE_FILE");
        std::env::set_var("CGC_WORKSPACE_STATE_FILE", &path);

        let entry = super::entry("03a460fb-fcdb-471d-90d8-8ded19e157dc").expect("workspace entry");
        assert_eq!(entry.tabs.len(), 4);
        assert_eq!(entry.tabs[0].path, "/w/2046/courses");
        assert_eq!(entry.tabs[1].path, "/w/2046/events");
        assert_eq!(
            entry.tabs[2].path, "/agents",
            "站点级 tab 不能被误加上工作区前缀"
        );
        assert_eq!(
            entry.tabs[3].path,
            "/w/2046/courses/course-a/learn?issue=unit-a"
        );
        assert_eq!(
            entry.active_tab.as_deref(),
            Some("page:/w/2046/courses/course-a/learn?issue=unit-a"),
            "active id 必须同步映射到迁移后的地址"
        );

        if let Some(previous) = previous {
            std::env::set_var("CGC_WORKSPACE_STATE_FILE", previous);
        } else {
            std::env::remove_var("CGC_WORKSPACE_STATE_FILE");
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_env_lock_serializes_threads() {
        use std::sync::mpsc;
        use std::time::Duration;

        let guard = test_env_lock::acquire();
        let (tx, rx) = mpsc::channel();
        let handle = std::thread::spawn(move || {
            let _guard = test_env_lock::acquire();
            tx.send(()).expect("child should acquire after release");
        });
        assert!(
            rx.recv_timeout(Duration::from_millis(100)).is_err(),
            "子线程在主线程释放锁前不应拿到锁"
        );
        drop(guard);
        rx.recv_timeout(Duration::from_secs(2))
            .expect("子线程应在主线程释放锁后拿到锁");
        handle.join().expect("join child thread");
    }
}
