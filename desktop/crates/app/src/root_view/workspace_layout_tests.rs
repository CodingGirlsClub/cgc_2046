//! 回归穿过真实重置入口、导航保存与磁盘重载；UI 测试按项目约定串行运行。

use super::RootView;
use crate::i18n::Language;
use crate::preferences;
use crate::settings_window::SettingsWindowView;
use crate::theme::ThemePreference;
use crate::workspace_state::{
    self, PanelLayout, PersistedRightPanel, PersistedTab, WorkspaceEntry,
};
use cgc_platform::session::{FakeAuthApi, MemoryStore, SessionService};
use cgc_platform::workspace::WorkspaceSummary;
use gpui_kit::test::TestWindowExt;
use gpui_kit::{
    px, size, AppContext, Bounds, Entity, Modifiers, TestAppContext, VisualTestContext,
    WindowBounds, WindowOptions,
};
use std::ffi::OsString;
use std::path::PathBuf;
use std::sync::{atomic::AtomicBool, Arc};

struct LayoutFiles {
    directory: PathBuf,
    previous: Vec<(&'static str, Option<OsString>)>,
}

impl LayoutFiles {
    fn new() -> Self {
        let directory =
            std::env::temp_dir().join(format!("cgc-layout-regression-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&directory).expect("isolated data directory");
        let previous = ["CGC_DATA_DIR", "CGC_WORKSPACE_STATE_FILE"]
            .into_iter()
            .map(|key| (key, std::env::var_os(key)))
            .collect();
        std::env::set_var("CGC_DATA_DIR", &directory);
        std::env::set_var(
            "CGC_WORKSPACE_STATE_FILE",
            directory.join("workspace_state.json"),
        );
        preferences::update(|prefs| prefs.dock_starts_open = false);
        Self {
            directory,
            previous,
        }
    }
}

impl Drop for LayoutFiles {
    fn drop(&mut self) {
        for (key, previous) in &self.previous {
            if let Some(value) = previous {
                std::env::set_var(key, value);
            } else {
                std::env::remove_var(key);
            }
        }
        let _ = std::fs::remove_dir_all(&self.directory);
    }
}

fn saved_workspace() -> WorkspaceEntry {
    WorkspaceEntry {
        tabs: vec![
            PersistedTab {
                id: "page:/courses".into(),
                title: "Courses".into(),
                path: "/courses".into(),
                issue_id: None,
            },
            PersistedTab {
                id: "page:/events".into(),
                title: "Events".into(),
                path: "/events".into(),
                issue_id: None,
            },
        ],
        active_tab: Some("page:/courses".into()),
        site_tree_courses_open: true,
        site_tree_query: "learning".into(),
        layout: Some(PanelLayout {
            agent_panel_width: 500.0,
            right_panel_width: 400.0,
            agent_panel_open: false,
            right_panel_open: false,
            right_panel: PersistedRightPanel::Outline,
        }),
        ..Default::default()
    }
}

fn restored_root(cx: &mut TestAppContext) -> Entity<RootView> {
    let root = cx.update(|cx| {
        cx.new(|_| {
            let mut root = RootView::with_session(
                crate::registration::build_registry().expect("routes"),
                Language::En,
                ThemePreference::Light,
                SessionService::new(
                    Box::new(FakeAuthApi::demo()),
                    Box::new(MemoryStore::default()),
                ),
            );
            root.workspaces.adopt(vec![WorkspaceSummary {
                id: "layout-current".into(),
                slug: "layout-current".into(),
                name: "Layout regression".into(),
                my_role_names: Vec::new(),
                member_count: Some(1),
                can_access: true,
            }]);
            root
        })
    });
    root.update(cx, |root, cx| root.restore_workspace_state(cx));
    root
}

#[gpui_kit::test]
fn workspace_layout_reset_inherits_defaults_after_navigation_and_reload(cx: &mut TestAppContext) {
    let _files = LayoutFiles::new();
    let saved = saved_workspace();
    let other = WorkspaceEntry {
        layout: Some(PanelLayout {
            agent_panel_width: 520.0,
            right_panel_width: 416.0,
            agent_panel_open: true,
            right_panel_open: true,
            right_panel: PersistedRightPanel::SiteTree,
        }),
        ..Default::default()
    };
    workspace_state::save_entry("layout-current", saved.clone());
    workspace_state::save_entry("layout-other", other.clone());
    let root = restored_root(cx);
    root.update(cx, |root, cx| {
        assert!(root.reset_workspace_layout(cx));
        root.activate_tab("page:/events", cx);
    });

    preferences::update(|prefs| {
        prefs.agent_panel_width = 420.0;
        prefs.dock_width = 336.0;
        prefs.dock_starts_open = true;
    });
    root.update(cx, |root, cx| {
        root.apply_default_panel_widths(cx);
        root.apply_display_snapshot(cx);
        assert!(root.right_panel_open, "默认展开修改应作用于继承布局");
        assert_eq!(
            root.agent_panel_width, 420.0,
            "重置后应继续跟随 Panels 默认宽度"
        );
        assert_eq!(root.right_panel_width, 336.0);
    });
    let reloaded = restored_root(cx);
    reloaded.update(cx, |root, _| {
        assert_eq!(root.agent_panel_width, 420.0, "重载应使用新的默认宽度");
        assert_eq!(root.right_panel_width, 336.0);
        assert!(root.right_panel_open);
        assert_eq!(root.active_tab.as_deref(), Some("page:/events"));
        assert_eq!(root.current().map(|route| route.id), Some("events.list"));
        assert_eq!(
            root.tabs
                .iter()
                .map(|tab| tab.id.as_str())
                .collect::<Vec<_>>(),
            vec!["page:/courses", "page:/events"]
        );
        assert!(root.site_tree_courses_open);
        assert_eq!(root.site_tree_query, "learning");
    });
    reloaded.update(cx, |root, cx| {
        root.toggle_right_panel(super::super::state::RightPanel::Outline, cx);
    });
    preferences::update(|prefs| {
        prefs.agent_panel_width = 460.0;
        prefs.dock_starts_open = false;
    });
    reloaded.update(cx, |root, cx| {
        root.apply_default_panel_widths(cx);
        root.apply_display_snapshot(cx);
        assert_eq!(
            root.agent_panel_width, 420.0,
            "显式调整后保留工作台布局覆盖"
        );
        assert!(root.right_panel_open);
    });
    let customized = restored_root(cx);
    customized.update(cx, |root, _| {
        assert_eq!(root.agent_panel_width, 420.0);
        assert_eq!(root.right_panel, super::super::state::RightPanel::Outline);
        assert!(root.right_panel_open);
    });
    assert_eq!(workspace_state::entry("layout-other"), Some(other));
}

#[gpui_kit::test]
fn workspace_layout_reset_preserves_pending_scroll_after_reload(cx: &mut TestAppContext) {
    let _files = LayoutFiles::new();
    workspace_state::save_entry(
        "layout-current",
        WorkspaceEntry {
            site_tree_scroll_y: -180.0,
            ..saved_workspace()
        },
    );
    let root = restored_root(cx);
    root.update(cx, |root, cx| {
        assert_eq!(root.site_tree_scroll_restore, Some(-180.0));
        assert_eq!(root.site_tree_scroll.offset().y.as_f32(), 0.0);
        assert!(root.reset_workspace_layout(cx));
        assert!(
            !root.right_panel_open,
            "Dock 关闭时不会应用待恢复的滚动位置"
        );
    });
    let reloaded = restored_root(cx);
    reloaded.update(cx, |root, _| {
        assert_eq!(
            root.site_tree_scroll_restore,
            Some(-180.0),
            "布局重置不能丢失导航滚动记忆"
        );
    });
}

#[gpui_kit::test]
fn workspace_layout_reset_can_be_confirmed_with_tab_enter_and_space(cx: &mut TestAppContext) {
    let _files = LayoutFiles::new();
    workspace_state::save_entry("layout-current", saved_workspace());
    cx.update(gpui_kit::init);
    let root = restored_root(cx);
    let root_weak = root.downgrade();
    let (handle, _settings) = cx.update(|cx| {
        gpui_kit::open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(Bounds::centered(
                    None,
                    size(px(620.0), px(900.0)),
                    cx,
                ))),
                ..Default::default()
            },
            cx,
            |_, cx| {
                cx.new(|cx| {
                    SettingsWindowView::new(
                        Language::En,
                        None,
                        "layout-user".into(),
                        Some("Layout regression".into()),
                        String::new(),
                        Arc::new(FakeAuthApi::demo()),
                        Arc::new(AtomicBool::new(false)),
                        None,
                        root_weak,
                        cx,
                    )
                })
            },
        )
        .expect("settings window")
    });
    let panels_center = cx
        .update_window(handle, |_, window, cx| {
            window.render_frame(cx);
            // Kit 的设置侧栏按页面索引生成菜单 ID，Panels 是已观察到的 0-3。
            window
                .within("settings-sidebar")
                .find("0-3")
                .bounds()
                .center()
        })
        .unwrap();
    let mut visual = VisualTestContext::from_window(handle, cx);
    visual.simulate_click(panels_center, Modifiers::default());
    let workspace_group_center = visual.update(|window, cx| {
        window.render_frame(cx);
        window
            .within("settings-sidebar")
            .find("0-3-2")
            .bounds()
            .center()
    });
    visual.simulate_click(workspace_group_center, Modifiers::default());
    let mut reached_reset = false;
    // 遍历设置页当前有限的 Tab 顺序，避免把鼠标点击当成键盘可达性。
    for _ in 0..32 {
        reached_reset = visual.update(|window, cx| {
            window.render_frame(cx);
            let button = window.find("settings-reset-workspace-layout");
            assert!(button.visible(), "必须挂载实际重置控件");
            button.focused() == Some(true)
        });
        if reached_reset {
            break;
        }
        visual.update(|window, cx| window.press("tab", cx));
    }
    assert!(reached_reset, "Tab 必须能够聚焦重置按钮");
    // Button 在 KeyUp 激活；Kit press 发送完整按下/抬起事件。
    visual.update(|window, cx| window.press("enter", cx));
    visual.update(|_, cx| {
        root.update(cx, |root, _| {
            assert_eq!(
                root.agent_panel_width, 500.0,
                "首次激活仅确认，不能执行重置"
            );
        })
    });
    visual.update(|window, cx| window.press("space", cx));
    visual.update(|_, cx| {
        root.update(cx, |root, _| {
            assert_eq!(
                root.agent_panel_width, 380.0,
                "第二次激活应套用 Panels 默认值"
            );
            assert_eq!(root.active_tab.as_deref(), Some("page:/courses"));
        })
    });
    assert!(workspace_state::entry("layout-current")
        .unwrap()
        .layout
        .is_none());
}

#[gpui_kit::test]
fn workspace_layout_reset_keyboard_works_through_production_settings_entry(
    cx: &mut TestAppContext,
) {
    let _files = LayoutFiles::new();
    workspace_state::save_entry("layout-current", saved_workspace());
    cx.update(gpui_kit::init);
    let root = restored_root(cx);
    root.update(cx, |root, cx| {
        root.session
            .sign_in("demo@example.com", "demo")
            .expect("fake login");
        root.open_settings_window(cx);
        root.open_settings_window(cx);
    });
    let handle = cx.update(|cx| {
        let windows = cx.windows();
        assert_eq!(windows.len(), 1, "再次打开设置应激活已有窗口");
        windows[0]
    });
    let panels_center = cx
        .update_window(handle, |_, window, cx| {
            window.render_frame(cx);
            window
                .within("settings-sidebar")
                .find("0-3")
                .bounds()
                .center()
        })
        .unwrap();
    let mut visual = VisualTestContext::from_window(handle, cx);
    visual.simulate_click(panels_center, Modifiers::default());
    let workspace_group_center = visual.update(|window, cx| {
        window.render_frame(cx);
        window
            .within("settings-sidebar")
            .find("0-3-2")
            .bounds()
            .center()
    });
    visual.simulate_click(workspace_group_center, Modifiers::default());
    let mut reached_reset = false;
    for _ in 0..32 {
        reached_reset = visual.update(|window, cx| {
            window.render_frame(cx);
            let button = window.find("settings-reset-workspace-layout");
            assert!(button.visible(), "必须挂载真实窗口的重置控件");
            button.focused() == Some(true)
        });
        if reached_reset {
            break;
        }
        visual.update(|window, cx| window.press("tab", cx));
    }
    assert!(reached_reset, "真实 Settings 窗口必须支持 Tab 聚焦重置按钮");
    visual.update(|window, cx| {
        window.press("shift-tab", cx);
        window.render_frame(cx);
        assert_eq!(
            window.find("settings-reset-workspace-layout").focused(),
            Some(false)
        );
        window.press("tab", cx);
        window.render_frame(cx);
        assert_eq!(
            window.find("settings-reset-workspace-layout").focused(),
            Some(true)
        );
        window.press("enter", cx);
    });
    visual.update(|_, cx| {
        root.update(cx, |root, _| {
            assert_eq!(root.agent_panel_width, 500.0, "首次激活只进入确认状态");
        })
    });
    visual.update(|window, cx| window.press("space", cx));
    visual.update(|_, cx| {
        root.update(cx, |root, _| {
            assert_eq!(
                root.agent_panel_width, 380.0,
                "键盘确认应重置真实工作台布局"
            );
            assert_eq!(root.active_tab.as_deref(), Some("page:/courses"));
        })
    });
    assert!(workspace_state::entry("layout-current")
        .unwrap()
        .layout
        .is_none());
}
