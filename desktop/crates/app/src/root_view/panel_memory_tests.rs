//! P0 防回归：`PanelMemory` 与 `persist_workspace_state` 的两条规则。
//!
//! - 通知面板是临时入口：打开/收起都不能改写 dock 记忆，也不能落盘；
//! - 导航进入学习页时，记忆同步到 Outline（右栏开着的前提下）。
//!
//! 只在 `CGC_UI_TESTS=1` + `--features gpui-kit/test-support` 下编译，
//! 见 `desktop/README.md` 的「授权回归验证」。这里不打开窗口：只驱动状态机。

use super::RootView;
use crate::i18n::Language;
use crate::root_view::state::{PanelMemory, RightPanel};
use crate::theme::ThemePreference;
use crate::workspace_state::{self, PersistedRightPanel};
use cgc_platform::session::{FakeAuthApi, MemoryStore, SessionService};
use cgc_platform::workspace::{FakeWorkspaceApi, WorkspaceService};
use gpui_kit::{AppContext, Entity, TestAppContext};
use std::ffi::OsString;
use std::path::PathBuf;
use std::sync::Arc;

/// 把 workspace 状态文件隔离到临时目录，测试结束恢复环境。
struct StateFileGuard {
    dir: PathBuf,
    previous: Option<OsString>,
}

impl StateFileGuard {
    fn new(label: &str) -> Self {
        let dir =
            std::env::temp_dir().join(format!("cgc-panel-memory-{label}-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("mkdir state dir");
        let previous = std::env::var_os("CGC_WORKSPACE_STATE_FILE");
        std::env::set_var("CGC_WORKSPACE_STATE_FILE", dir.join("workspace_state.json"));
        Self { dir, previous }
    }
}

impl Drop for StateFileGuard {
    fn drop(&mut self) {
        match &self.previous {
            Some(previous) => std::env::set_var("CGC_WORKSPACE_STATE_FILE", previous),
            None => std::env::remove_var("CGC_WORKSPACE_STATE_FILE"),
        }
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

/// 构造一个已选中工作台的 RootView（不渲染，不联网）。
fn open_root(cx: &mut TestAppContext) -> (Entity<RootView>, String) {
    let mut workspaces = WorkspaceService::new(Arc::new(FakeWorkspaceApi::demo()));
    let listed = workspaces.fetch(None).expect("demo workspace list");
    workspaces.adopt(listed);
    let workspace_id = workspaces
        .current_id()
        .expect("demo 工作台应可选中")
        .to_string();
    let root = cx.update(|cx| {
        cx.new(|_| {
            let mut root = RootView::with_session(
                crate::registration::build_registry().expect("route registry"),
                Language::En,
                ThemePreference::Light,
                SessionService::new(
                    Box::new(FakeAuthApi::demo()),
                    Box::new(MemoryStore::default()),
                ),
            );
            root.workspaces = workspaces;
            root
        })
    });
    (root, workspace_id)
}

#[gpui_kit::test]
fn notification_panel_does_not_touch_dock_memory_or_state_file(cx: &mut TestAppContext) {
    let _state_file = StateFileGuard::new("notifications");
    let (root, workspace_id) = open_root(cx);

    root.update(cx, |root, cx| {
        root.right_panel = RightPanel::SiteTree;
        root.right_panel_open = false;
        root.panel_memory = PanelMemory {
            panel: RightPanel::SiteTree,
            open: true,
        };

        root.toggle_right_panel(RightPanel::Notifications, cx);

        assert_eq!(
            root.right_panel,
            RightPanel::Notifications,
            "点击通知图标应打开通知面板"
        );
        assert!(root.right_panel_open, "通知面板应处于展开状态");
        assert_eq!(
            root.panel_memory,
            PanelMemory {
                panel: RightPanel::SiteTree,
                open: true
            },
            "打开通知面板不得改写 dock 记忆"
        );
        assert!(
            workspace_state::entry(&workspace_id).is_none(),
            "打开通知面板不得写入 workspace 状态文件"
        );

        root.toggle_right_panel(RightPanel::Notifications, cx);

        assert!(!root.right_panel_open, "再次点击通知图标应收起通知面板");
        assert_eq!(
            root.panel_memory,
            PanelMemory {
                panel: RightPanel::SiteTree,
                open: true
            },
            "收起通知面板不得改写 dock 记忆"
        );
        assert!(
            workspace_state::entry(&workspace_id).is_none(),
            "收起通知面板不得写入 workspace 状态文件"
        );
    });
}

/// 正控制：普通面板切换必须落盘，否则上面「不写入」的断言可能是空转。
#[gpui_kit::test]
fn normal_panel_toggle_persists_dock_memory(cx: &mut TestAppContext) {
    let _state_file = StateFileGuard::new("persist");
    let (root, workspace_id) = open_root(cx);

    root.update(cx, |root, cx| {
        root.right_panel = RightPanel::SiteTree;
        root.right_panel_open = false;
        root.panel_memory = PanelMemory {
            panel: RightPanel::SiteTree,
            open: false,
        };

        root.toggle_right_panel(RightPanel::Outline, cx);

        assert_eq!(
            root.panel_memory,
            PanelMemory {
                panel: RightPanel::Outline,
                open: true
            },
            "切换普通面板应同步 dock 记忆"
        );
        let saved = workspace_state::entry(&workspace_id).expect("切换普通面板必须落盘");
        let layout = saved.layout.expect("普通面板切换必须保存布局覆盖");
        assert_eq!(layout.right_panel, PersistedRightPanel::Outline);
        assert!(layout.right_panel_open);
    });
}

#[gpui_kit::test]
fn learning_navigation_syncs_dock_memory_to_outline(cx: &mut TestAppContext) {
    let _state_file = StateFileGuard::new("navigate");
    let (root, _workspace_id) = open_root(cx);

    root.update(cx, |root, _cx| {
        root.right_panel = RightPanel::SiteTree;
        root.right_panel_open = true;
        root.panel_memory = PanelMemory {
            panel: RightPanel::SiteTree,
            open: true,
        };

        root.navigate("/w/2046/courses/crs-test/learn");

        assert_eq!(
            root.right_panel,
            RightPanel::Outline,
            "进入学习页时右栏应切到 Outline"
        );
        assert_eq!(
            root.panel_memory,
            PanelMemory {
                panel: RightPanel::Outline,
                open: true
            },
            "进入学习页时 dock 记忆必须同步到 Outline"
        );
    });
}
