//! 标题栏账户菜单的 headless 回归：Kit `Button` + `dropdown_menu` 的
//! 打开 / Esc 关闭 / 点项执行并关闭。
//!
//! 只在 `CGC_UI_TESTS=1` + `--features gpui-kit/test-support` 下编译。
//! 注意不要 `use super::*`（会让 `#[gpui_kit::test]` 的属性宏递归，rustc SIGBUS）。

use super::RootView;
use crate::i18n::{translate, Key, Language};
use crate::root_view::screens::ScreenContext;
use crate::theme::{self, ThemePreference};
use cgc_platform::session::{FakeAuthApi, MemoryStore, SessionService, SignedInSession};
use cgc_platform::workspace::WorkspaceSummary;
use gpui_kit::test::{TestQueryExt, TestWindowExt};
use gpui_kit::{
    div, px, size, AnyWindowHandle, AppContext, Bounds, Context, Entity, IntoElement, Modifiers,
    ParentElement, Render, Role, Styled, TestAppContext, VisualTestContext, Window, WindowBounds,
    WindowOptions,
};

struct AccountProbe {
    root: Entity<RootView>,
}

impl Render for AccountProbe {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let button = self.root.update(cx, |root, cx| {
            let palette = theme::palette_from_theme(cx);
            let language = root.language;
            root.render_account_menu_button(
                &palette,
                "demo@example.com",
                translate(language, Key::AppAuthSignedInAs),
                translate(language, Key::AppAuthSignOut),
                translate(language, Key::AppAccountMenu),
                cx,
            )
        });
        div()
            .size_full()
            .flex()
            .justify_end()
            .items_start()
            .p(px(8.0))
            .child(button)
    }
}

fn signed_in_root() -> RootView {
    let mut session = SessionService::new(
        Box::new(FakeAuthApi::demo()),
        Box::new(MemoryStore::default()),
    );
    session
        .adopt_signed_in(SignedInSession {
            token: "test-token".to_string(),
            user_id: "00000000-0000-0000-0000-000000000001".to_string(),
            email: Some("demo@example.com".to_string()),
            is_platform_admin: false,
        })
        .expect("fake session should persist in memory store");
    RootView::with_session(
        crate::registration::build_registry().unwrap(),
        Language::En,
        ThemePreference::Light,
        session,
    )
}

#[gpui_kit::test]
fn account_menu_opens_escapes_and_signs_out(cx: &mut TestAppContext) {
    check_account_menu(cx);
}

fn check_account_menu(cx: &mut TestAppContext) {
    cx.update(gpui_kit::init);
    let (handle, probe) = cx.update(|cx| {
        gpui_kit::open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(Bounds::centered(
                    None,
                    size(px(420.), px(220.)),
                    cx,
                ))),
                ..Default::default()
            },
            cx,
            |_, cx| {
                let root = cx.new(|_| signed_in_root());
                cx.new(|_| AccountProbe { root })
            },
        )
        .unwrap()
    });

    let sign_out = translate(Language::En, Key::AppAuthSignOut);
    let mut vcx = VisualTestContext::from_window(handle, cx);

    let menu_state = |vcx: &mut VisualTestContext| -> (bool, usize) {
        vcx.update(|window, cx| {
            window.render_frame(cx);
            let visible = window
                .try_find_by_label(sign_out)
                .is_some_and(|element| element.visible());
            (
                visible,
                window.find_all_by_role(gpui_kit::Role::MenuItem).len(),
            )
        })
    };

    let (visible, _) = menu_state(&mut vcx);
    assert!(!visible, "菜单初始应关闭");
    assert!(
        vcx.update(|window, _| window.find("account-toggle").visible()),
        "账户触发器应渲染"
    );

    vcx.update(|window, cx| window.click("account-toggle", cx));
    let (visible, items) = menu_state(&mut vcx);
    assert!(visible, "点击账户触发器后菜单应打开");
    assert!(items >= 2, "菜单应至少包含设置与登出两项，实际 {items}");

    vcx.simulate_keystrokes("escape");
    let (visible, _) = menu_state(&mut vcx);
    assert!(!visible, "Esc 后菜单应关闭");

    vcx.update(|window, cx| window.click("account-toggle", cx));
    let sign_out_center = vcx.update(|window, cx| {
        window.render_frame(cx);
        window.find_by_label(sign_out).bounds().center()
    });
    vcx.simulate_click(sign_out_center, Modifiers::default());
    let (visible, _) = menu_state(&mut vcx);
    assert!(!visible, "点项后菜单应关闭");

    let signed_in = cx.update(|cx| probe.read(cx).root.read(cx).is_signed_in());
    assert!(!signed_in, "点击登出项后应退出登录");
}

struct BreadcrumbProbe {
    root: Entity<RootView>,
}

impl Render for BreadcrumbProbe {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let bar = self.root.update(cx, |root, cx| {
            let palette = theme::palette_from_theme(cx);
            let language = root.language;
            root.render_breadcrumb_bar(language, &palette, cx)
        });
        div().w_full().flex().items_center().p(px(8.0)).child(bar)
    }
}

fn open_breadcrumb_probe(cx: &mut TestAppContext) -> (AnyWindowHandle, Entity<BreadcrumbProbe>) {
    cx.update(|cx| {
        gpui_kit::open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(Bounds::centered(
                    None,
                    size(px(520.), px(200.)),
                    cx,
                ))),
                ..Default::default()
            },
            cx,
            |_, cx| {
                let root = cx.new(|_| signed_in_root());
                cx.new(|_| BreadcrumbProbe { root })
            },
        )
        .unwrap()
    })
}

#[gpui_kit::test]
fn breadcrumb_menu_opens_navigates_and_closes(cx: &mut TestAppContext) {
    check_breadcrumb_menu(cx);
}

fn check_breadcrumb_menu(cx: &mut TestAppContext) {
    cx.update(gpui_kit::init);
    let (handle, probe) = open_breadcrumb_probe(cx);
    let mut vcx = VisualTestContext::from_window(handle, cx);

    let section = translate(Language::En, Key::AppBreadcrumbSections).to_string();
    let participations = translate(Language::En, Key::EventsParticipationsTitle).to_string();

    assert!(
        vcx.update(|window, cx| {
            window.render_frame(cx);
            window.find("breadcrumb-section").visible()
        }),
        "面包屑触发器应渲染"
    );
    assert!(
        vcx.update(|window, _| window.try_find_by_label(&participations).is_none()),
        "菜单未打开时不应出现路由项"
    );

    vcx.update(|window, cx| window.click("breadcrumb-section", cx));
    assert!(
        vcx.update(|window, cx| {
            window.render_frame(cx);
            window.find_by_label(&participations).visible()
        }),
        "点击后应出现路由项（section={section}）"
    );

    vcx.simulate_keystrokes("escape");
    assert!(
        vcx.update(|window, cx| {
            window.render_frame(cx);
            window
                .try_find_by_label(&participations)
                .is_none_or(|element| !element.visible())
        }),
        "Esc 后菜单应关闭"
    );

    vcx.update(|window, cx| window.click("breadcrumb-section", cx));
    let row_center = vcx.update(|window, cx| {
        window.render_frame(cx);
        window.find_by_label(&participations).bounds().center()
    });
    vcx.simulate_click(row_center, Modifiers::default());
    vcx.update(|window, cx| window.render_frame(cx));
    let route = cx.update(|cx| probe.read(cx).root.read(cx).current().map(|route| route.id));
    assert_eq!(route, Some("events.participations"));
}

#[gpui_kit::test]
fn workspace_menu_opens_and_closes(cx: &mut TestAppContext) {
    check_workspace_menu(cx);
}

fn check_workspace_menu(cx: &mut TestAppContext) {
    cx.update(gpui_kit::init);
    let (handle, probe) = open_breadcrumb_probe(cx);

    // 加载中（Idle）触发器禁用：菜单内容在打开时缓存，加载中打开会停在“加载中”。
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        assert_eq!(
            window.find("workspace-menu-toggle").disabled(),
            Some(true),
            "工作台加载中应禁用下拉触发器"
        );
    })
    .unwrap();

    // 造出 Ready 状态后再开菜单。
    cx.update_window(handle, |_, window, cx| {
        let root = probe.read(cx).root.clone();
        root.update(cx, |root, _| {
            root.workspaces.adopt(vec![WorkspaceSummary {
                id: "ws-test".to_string(),
                slug: "ws-test".to_string(),
                name: "Demo Workspace".to_string(),
                my_role_names: vec!["owner".to_string()],
                member_count: Some(1),
                can_access: true,
            }]);
        });
        window.render_frame(cx);
        assert_ne!(
            window.find("workspace-menu-toggle").disabled(),
            Some(true),
            "加载完成后触发器应可用"
        );
        window.click("workspace-menu-toggle", cx);
        window.render_frame(cx);
        // 行是 PopupMenuItem::element（无可访问名），用 MenuItem role 判开合：
        // 标题行 + 工作台行至少两条。
        assert!(
            window.find_all_by_role(Role::MenuItem).len() >= 2,
            "菜单打开后应至少有两个 MenuItem"
        );
    })
    .unwrap();

    let mut vcx = VisualTestContext::from_window(handle, cx);
    vcx.simulate_keystrokes("escape");
    assert!(
        vcx.update(|window, cx| {
            window.render_frame(cx);
            window.find_all_by_role(Role::MenuItem).is_empty()
        }),
        "Esc 后工作台菜单应关闭"
    );
}

struct AgentHeaderProbe {
    root: Entity<RootView>,
}

impl Render for AgentHeaderProbe {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let header = self.root.update(cx, |root, cx| {
            let palette = theme::palette_from_theme(cx);
            let language = root.language;
            let mut context = ScreenContext::new(&mut root.state);
            crate::root_view::screens::render_agent_panel_header(
                &mut context,
                language,
                &palette,
                cx,
            )
        });
        div().w_full().child(header)
    }
}

#[gpui_kit::test]
fn agent_header_title_edits_and_new_menu_opens(cx: &mut TestAppContext) {
    check_agent_header(cx);
}

fn check_agent_header(cx: &mut TestAppContext) {
    cx.update(gpui_kit::init);
    let (handle, probe) = cx.update(|cx| {
        gpui_kit::open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(Bounds::centered(
                    None,
                    size(px(640.), px(200.)),
                    cx,
                ))),
                ..Default::default()
            },
            cx,
            |_, cx| {
                let root = cx.new(|_| signed_in_root());
                cx.new(|_| AgentHeaderProbe { root })
            },
        )
        .unwrap()
    });

    // 标题是普通 div（不进 observation），直接驱动状态机验证编辑/取消。
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        root_start_edit(&probe, window, cx);
    })
    .unwrap();
    assert!(
        cx.update(|cx| probe.read(cx).root.read(cx).agent_panel_editing_title),
        "start_edit 后应进入编辑态"
    );
    cx.update_window(handle, |_, window, cx| {
        let escape = gpui_kit::Keystroke::parse("escape").expect("valid escape");
        let root = probe.read(cx).root.clone();
        let cancelled = root.update(cx, |root, cx| {
            root.handle_title_edit_escape(&escape, window, cx)
        });
        assert!(cancelled, "Esc 应被标题编辑拦截");
    })
    .unwrap();
    assert!(
        !cx.update(|cx| probe.read(cx).root.read(cx).agent_panel_editing_title),
        "Esc 后应退出编辑态"
    );

    // 切到 ACP 分支（探针里没有 NativeAgentView，native 分支不写盘），
    // 让「未改动不写 override」的断言真的可被破坏。
    cx.update_window(handle, |_, _, cx| {
        let root = probe.read(cx).root.clone();
        root.update(cx, |root, _| root.native_chat_mode = false);
    })
    .unwrap();

    cx.update_window(handle, |_, window, cx| {
        root_start_edit(&probe, window, cx);
        let root = probe.read(cx).root.clone();
        root.update(cx, |root, cx| {
            root.commit_agent_panel_title(window, cx);
        });
    })
    .unwrap();
    let unchanged = cx.update(|cx| probe.read(cx).root.read(cx).chat.title_override.is_none());
    assert!(unchanged, "未改动时不应写 title_override");

    // 正例：真的改了标题，必须写入 override（证明上面不是空断言）。
    cx.update_window(handle, |_, window, cx| {
        root_start_edit(&probe, window, cx);
        let root = probe.read(cx).root.clone();
        let input = root
            .read(cx)
            .agent_panel_title_input
            .clone()
            .expect("title input");
        input.update(cx, |state, cx| state.set_value("Renamed", window, cx));
        root.update(cx, |root, cx| {
            root.commit_agent_panel_title(window, cx);
        });
    })
    .unwrap();
    let renamed = cx.update(|cx| probe.read(cx).root.read(cx).chat.title_override.clone());
    assert_eq!(renamed.as_deref(), Some("Renamed"), "改动后应写入 override");

    let mut vcx = VisualTestContext::from_window(handle, cx);
    // `agent-panel-new` 仍是 Popover（registry 异步加载需要每次渲染重建行）；
    // 其内容行没有 observation 钩子，这里只断言触发器在位。
    assert!(
        vcx.update(|window, cx| {
            window.render_frame(cx);
            window.find("agent-panel-new-trigger").visible()
        }),
        "＋ 触发器应渲染"
    );
}

fn root_start_edit(probe: &Entity<AgentHeaderProbe>, window: &mut Window, cx: &mut gpui_kit::App) {
    let root = probe.read(cx).root.clone();
    root.update(cx, |root, cx| {
        root.start_edit_agent_panel_title(window, cx);
    });
}

struct HistoryHeaderProbe {
    root: Entity<RootView>,
}

impl Render for HistoryHeaderProbe {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.root.update(cx, |root, cx| {
            root.render_history_sidebar(crate::preferences::PanelSide::Left, window, cx)
        })
    }
}

#[gpui_kit::test]
fn history_tabs_switch_and_close_is_a_button(cx: &mut TestAppContext) {
    check_history_tabs(cx);
}

fn check_history_tabs(cx: &mut TestAppContext) {
    cx.update(gpui_kit::init);
    let (handle, probe) = cx.update(|cx| {
        gpui_kit::open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(Bounds::centered(
                    None,
                    size(px(520.), px(420.)),
                    cx,
                ))),
                ..Default::default()
            },
            cx,
            |_, cx| {
                let root = cx.new(|_| signed_in_root());
                root.update(cx, |root, _| {
                    root.history_sidebar = Some(Default::default());
                });
                cx.new(|_| HistoryHeaderProbe { root })
            },
        )
        .unwrap()
    });

    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        window.click("history-tab-archive", cx);
        window.render_frame(cx);
    })
    .unwrap();
    let tab = cx.update(|cx| {
        probe
            .read(cx)
            .root
            .read(cx)
            .history_sidebar
            .as_ref()
            .map(|sidebar| sidebar.tab)
    });
    assert_eq!(
        tab,
        Some(crate::root_view::history_sidebar::HistoryTab::Archive)
    );
}

struct BellProbe {
    root: Entity<RootView>,
}

impl Render for BellProbe {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let bell = self.root.update(cx, |root, cx| {
            let palette = theme::palette_from_theme(cx);
            let language = root.language;
            root.render_notifications_bell(language, &palette, cx)
        });
        div().child(bell)
    }
}

#[gpui_kit::test]
fn notifications_bell_is_kit_button_and_opens_panel(cx: &mut TestAppContext) {
    check_bell(cx);
}

fn check_bell(cx: &mut TestAppContext) {
    cx.update(gpui_kit::init);
    let (handle, probe) = cx.update(|cx| {
        gpui_kit::open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(Bounds::centered(
                    None,
                    size(px(320.), px(120.)),
                    cx,
                ))),
                ..Default::default()
            },
            cx,
            |_, cx| {
                let root = cx.new(|_| signed_in_root());
                cx.new(|_| BellProbe { root })
            },
        )
        .unwrap()
    });

    let mut vcx = VisualTestContext::from_window(handle, cx);
    assert!(
        vcx.update(|window, cx| {
            window.render_frame(cx);
            let bell = window.find("notifications-toggle");
            bell.role() == Some(Role::Button) && bell.visible()
        }),
        "铃铛应是可见的 Kit Button"
    );
    vcx.update(|window, cx| window.click("notifications-toggle", cx));
    let opened = cx.update(|cx| {
        let root = probe.read(cx).root.read(cx);
        root.right_panel_open
            && root.right_panel == crate::root_view::state::RightPanel::Notifications
    });
    assert!(opened, "点击铃铛应打开通知面板");
}
