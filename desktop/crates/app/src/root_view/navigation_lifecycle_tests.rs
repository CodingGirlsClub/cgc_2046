use super::RootView;
use crate::{i18n::Language, theme::ThemePreference, workspace_state};
use cgc_courses::catalog::{CoursesApi, FakeCoursesApi};
use cgc_platform::workspace::WorkspaceSummary;
use gpui_kit::test::TestWindowExt;
use gpui_kit::{px, size, AppContext, Bounds, Entity, TestAppContext, WindowBounds, WindowOptions};

pub(super) fn root_window(
    cx: &mut TestAppContext,
    path: &str,
) -> (gpui_kit::AnyWindowHandle, Entity<RootView>) {
    cx.update(gpui_kit::init);
    cx.update(|cx| {
        gpui_kit::open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(Bounds::centered(
                    None,
                    size(px(1280.), px(900.)),
                    cx,
                ))),
                ..Default::default()
            },
            cx,
            |_, cx| {
                cx.new(|_| {
                    let session = crate::root_view::demo_signed_in();
                    let mut root = RootView::with_session_from(
                        crate::registration::build_registry().unwrap(),
                        Language::Zh,
                        ThemePreference::Light,
                        session,
                        path,
                    );
                    root.session_checked = true;
                    root.workspaces_started = true;
                    root.native_chat_mode = false;
                    root.agent_panel_open = false;
                    root.right_panel_open = true;
                    root.right_panel = crate::root_view::state::RightPanel::SiteTree;
                    root.workspaces.adopt(vec![
                        WorkspaceSummary {
                            id: "ws-alpha".into(),
                            slug: "alpha".into(),
                            name: "Alpha".into(),
                            my_role_names: vec![],
                            member_count: None,
                            can_access: true,
                        },
                        WorkspaceSummary {
                            id: "ws-beta".into(),
                            slug: "beta".into(),
                            name: "Beta".into(),
                            my_role_names: vec![],
                            member_count: None,
                            can_access: true,
                        },
                    ]);
                    let mut detail = FakeCoursesApi::with_seed(2)
                        .get_course(None, "crs-001")
                        .unwrap();
                    detail.workspace_id = Some("ws-beta".into());
                    root.course_detail.adopt(detail);
                    root
                })
            },
        )
        .expect("full RootView window")
    })
}

#[gpui_kit::test]
fn tree_search_keeps_keyboard_focus_through_full_root_render(cx: &mut TestAppContext) {
    let _files = super::workspace_layout_tests::LayoutFiles::new();
    for path in [
        "/courses/crs-001",
        "/w/alpha/courses/crs-001",
        "/courses/crs-001/learn",
    ] {
        let (window, root) = root_window(cx, path);
        cx.update_window(window, |_, window, cx| {
            window.render_frame(cx);
            window.click("site-tree-search", cx);
        })
        .unwrap();
        cx.update_window(window, |_, window, cx| {
            window.render_frame(cx);
            window.input("课程 2", cx);
        })
        .unwrap();
        cx.update_window(window, |_, window, cx| {
            window.render_frame(cx);
            assert_eq!(
                root.read(cx).site_tree_query,
                "课程 2",
                "search lost focus on {path}"
            );
        })
        .unwrap();
    }
}

#[gpui_kit::test]
fn cross_workspace_issue_survives_full_root_render_and_workspace_restore(cx: &mut TestAppContext) {
    let _files = super::workspace_layout_tests::LayoutFiles::new();
    let (window, root) = root_window(cx, "/courses/crs-001/learn");
    root.update(cx, |root, cx| {
        root.open_page_tab("/learning", "My learning", cx);
        root.open_page_tab("/courses/crs-001/learn", "Public learning", cx);
        let mut detail = FakeCoursesApi::with_seed(2)
            .get_course(None, "crs-001")
            .unwrap();
        detail.workspace_id = Some("ws-beta".into());
        root.course_detail.adopt(detail);
        root.open_issue_tab("crs-001", "issue-target", "Target issue", cx);
    });
    cx.update_window(window, |_, window, cx| {
        window.render_frame(cx);
        assert_eq!(root.read(cx).workspaces.current_id(), Some("ws-beta"));
        assert_eq!(
            root.read(cx).active_issue_tab(),
            Some(("crs-001", "issue-target"))
        );
    })
    .unwrap();
    let alpha = workspace_state::entry("ws-alpha").expect("source workspace saved");
    assert_eq!(
        alpha.active_tab.as_deref(),
        Some("page:/courses/crs-001/learn")
    );
    assert!(alpha
        .tabs
        .iter()
        .all(|tab| crate::routing::issue_of(&tab.path).is_none()));
    let beta = workspace_state::entry("ws-beta").expect("target workspace saved");
    assert!(beta
        .tabs
        .iter()
        .any(|tab| crate::routing::issue_of(&tab.path) == Some("issue-target")));
    root.update(cx, |root, cx| root.switch_workspace("ws-alpha", cx));
    cx.update_window(window, |_, window, cx| window.render_frame(cx))
        .unwrap();
    root.update(cx, |root, cx| root.switch_workspace("ws-beta", cx));
    cx.update_window(window, |_, window, cx| {
        window.render_frame(cx);
        assert_eq!(
            root.read(cx).active_issue_tab(),
            Some(("crs-001", "issue-target"))
        );
    })
    .unwrap();
}

#[gpui_kit::test]
fn cross_workspace_open_goes_through_tab_lifecycle(cx: &mut TestAppContext) {
    let _files = super::workspace_layout_tests::LayoutFiles::new();
    // 「在工作区中打开」入口：公开课程页没有 slug，开课台是 beta；源台是 adopt 后的 alpha。
    let (window, root) = root_window(cx, "/courses/crs-001");
    root.update(cx, |root, _| {
        root.state.tabs.push(super::state::PaneTab::page(
            "/w/alpha/courses",
            "Alpha courses",
        ));
        root.active_tab = Some("page:/w/alpha/courses".into());
    });
    cx.update_window(window, |_, window, cx| {
        window.render_frame(cx);
        window.click("course-open-workspace", cx);
    })
    .unwrap();
    root.update(cx, |root, _| {
        assert_eq!(
            root.workspaces.current_id(),
            Some("ws-beta"),
            "跨台打开必须切到目标台"
        );
        assert!(
            root.state
                .tabs
                .iter()
                .any(|tab| tab.path == "/w/beta/courses/crs-001"),
            "跨台打开必须插入目标台 tab，而不是只导航"
        );
        assert_eq!(
            root.active_tab.as_deref(),
            Some("page:/w/beta/courses/crs-001"),
            "目标 tab 必须被激活"
        );
    });
    let alpha = workspace_state::entry("ws-alpha").expect("源台状态已落盘");
    assert!(
        alpha.tabs.iter().any(|tab| tab.path == "/w/alpha/courses"),
        "切台前必须先持久化源台"
    );
    let beta = workspace_state::entry("ws-beta").expect("目标台状态已落盘");
    assert!(
        beta.tabs
            .iter()
            .any(|tab| tab.path == "/w/beta/courses/crs-001"),
        "目标 tab 必须持久化到目标台"
    );
}

#[gpui_kit::test]
fn restored_search_loads_event_results_while_the_center_shows_courses(cx: &mut TestAppContext) {
    let _files = super::workspace_layout_tests::LayoutFiles::new();
    let (window, root) = root_window(cx, "/w/alpha/courses");
    workspace_state::save_entry(
        "ws-alpha",
        workspace_state::WorkspaceEntry {
            site_tree_query: "场次 1".into(),
            ..Default::default()
        },
    );
    root.update(cx, |root, cx| {
        root.restore_workspace_state(cx, true);
        root.right_panel_open = true;
    });
    cx.update_window(window, |_, window, cx| window.render_frame(cx))
        .unwrap();
    cx.run_until_parked();
    cx.update_window(window, |_, window, cx| {
        window.render_frame(cx);
        assert_eq!(
            root.read(cx)
                .nav_events
                .items()
                .iter()
                .find(|event| event.title == "场次 1")
                .map(|event| event.id.as_str()),
            Some("evt-000"),
            "restored query must populate the Site Tree event cache"
        );
        assert_eq!(
            root.read(cx).current().map(|route| route.id),
            Some("courses.catalog")
        );
    })
    .unwrap();
}

#[gpui_kit::test]
fn active_learning_course_takes_priority_over_an_old_expanded_tree_course(cx: &mut TestAppContext) {
    let _files = super::workspace_layout_tests::LayoutFiles::new();
    let (window, root) = root_window(cx, "/w/alpha/courses/crs-002/learn");
    root.update(cx, |root, cx| {
        let api = std::sync::Arc::new(FakeCoursesApi::with_seed(3));
        root.courses = cgc_courses::catalog::CourseCatalogService::new(api.clone());
        root.course_detail = cgc_courses::catalog::CourseDetailService::new(api.clone());
        root.content = cgc_courses::content::CourseContentService::new(api);
        root.site_tree_course_open = Some("crs-000".into());
        root.course_enrollments
            .insert("crs-000".into(), Some("confirmed".into()));
        root.start_course_detail_load(cx, "crs-002".into());
    });
    cx.run_until_parked();
    cx.update_window(window, |_, window, cx| window.render_frame(cx))
        .unwrap();
    cx.run_until_parked();
    root.update(cx, |root, _| {
        assert_eq!(
            root.content
                .content()
                .map(|content| content.course_id.as_str()),
            Some("crs-002")
        );
    });
}

/// ADR-0029 §7:pending action 的目标(course/issue)与当前页面分离即清除,
/// 防止切 tab/换 issue 后发送指向旧课程的动作(错误课程提交风险)。
#[gpui_kit::test]
fn pending_agent_call_clears_when_navigation_leaves_target(cx: &mut TestAppContext) {
    let _files = super::workspace_layout_tests::LayoutFiles::new();
    let (window, root) = root_window(cx, "/w/alpha/courses/crs-001/learn?issue=issue-1");
    let call = crate::agent_call::AgentCall::from_action(
        &cgc_courses::content::AgentActionSpec {
            id: "a-hint".into(),
            label: "Hint".into(),
            intent: cgc_courses::content::AgentIntent::Hint,
            primary: false,
        },
        crate::agent_call::LearningTarget::Objective {
            course_id: "crs-001".into(),
            revision: None,
            issue_id: "issue-1".into(),
            objective_id: "obj-1".into(),
        },
    );
    root.update(cx, |root, _| {
        let tab = crate::root_view::state::PaneTab::page(
            "/w/alpha/courses/crs-001/learn?issue=issue-1",
            "Card",
        );
        root.state.active_tab = Some(tab.id.clone());
        root.state.tabs.push(tab);
        root.state.chat.pending_agent_call = Some(crate::agent_call::PendingAgentCall::new(
            call,
            "Hint",
            "hint prompt",
        ));
    });
    cx.update_window(window, |_, window, cx| {
        window.render_frame(cx);
        assert!(
            root.read(cx).chat.pending_agent_call.is_some(),
            "pending must survive a same-page render"
        );
        root.update(cx, |root, cx| {
            root.navigate("/w/alpha/courses/crs-001/learn?issue=issue-2")
        });
        window.render_frame(cx);
        assert!(
            root.read(cx).chat.pending_agent_call.is_none(),
            "switching to another issue must clear the pending action"
        );
    })
    .unwrap();
}

/// 无课程上下文的页面(目录/列表)同样与 issue 级 pending 分离。
#[gpui_kit::test]
fn pending_agent_call_clears_when_leaving_course_pages(cx: &mut TestAppContext) {
    let _files = super::workspace_layout_tests::LayoutFiles::new();
    let (window, root) = root_window(cx, "/w/alpha/courses/crs-001/learn?issue=issue-1");
    let call = crate::agent_call::AgentCall::from_action(
        &cgc_courses::content::AgentActionSpec {
            id: "a-hint".into(),
            label: "Hint".into(),
            intent: cgc_courses::content::AgentIntent::Hint,
            primary: false,
        },
        crate::agent_call::LearningTarget::Issue {
            course_id: "crs-001".into(),
            revision: None,
            issue_id: "issue-1".into(),
        },
    );
    root.update(cx, |root, _| {
        let tab = crate::root_view::state::PaneTab::page(
            "/w/alpha/courses/crs-001/learn?issue=issue-1",
            "Card",
        );
        root.state.active_tab = Some(tab.id.clone());
        root.state.tabs.push(tab);
        root.state.chat.pending_agent_call = Some(crate::agent_call::PendingAgentCall::new(
            call,
            "Hint",
            "hint prompt",
        ));
    });
    cx.update_window(window, |_, window, cx| {
        window.render_frame(cx);
        assert!(root.read(cx).chat.pending_agent_call.is_some());
        root.update(cx, |root, cx| root.navigate("/w/alpha/courses"));
        window.render_frame(cx);
        assert!(
            root.read(cx).chat.pending_agent_call.is_none(),
            "leaving course pages must clear the issue-level pending action"
        );
    })
    .unwrap();
}
