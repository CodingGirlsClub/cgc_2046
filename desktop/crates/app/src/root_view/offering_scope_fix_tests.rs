//! G 段阶段一回归：R1 加载闸门（公开路由不绑 epoch + 丢弃必须复位）。
//!
//! UI 用例必须串行跑（`--test-threads=1`）：`LayoutFiles` 改的是进程级环境变量。

use super::RootView;
use cgc_courses::catalog::{CourseCatalogService, FakeCoursesApi};
use cgc_platform::session::{FakeAuthApi, MemoryStore, SessionService};
use cgc_platform::workspace::WorkspaceSummary;
use gpui_kit::test::TestWindowExt;
use gpui_kit::{
    div, px, size, AppContext, Bounds, Context, Entity, IntoElement, ParentElement, Render, Styled,
    TestAppContext, Window, WindowBounds, WindowOptions,
};
use std::sync::Arc;

fn workspace(id: &str, slug: &str) -> WorkspaceSummary {
    WorkspaceSummary {
        id: id.into(),
        slug: slug.into(),
        name: slug.into(),
        my_role_names: Vec::new(),
        member_count: None,
        can_access: true,
    }
}

fn workspaces() -> Vec<WorkspaceSummary> {
    vec![workspace("ws-alpha", "alpha"), workspace("ws-beta", "beta")]
}

/// 构造只带会话、不带窗口的根视图（R1 断言只看状态机，不需要渲染）。
fn root_at(cx: &mut TestAppContext, path: &'static str) -> Entity<RootView> {
    cx.update(gpui_kit::init);
    cx.update(|cx| {
        cx.new(|_| {
            RootView::with_session_from(
                crate::registration::build_registry().expect("registry"),
                crate::i18n::Language::Zh,
                crate::theme::ThemePreference::Light,
                SessionService::new(
                    Box::new(FakeAuthApi::demo()),
                    Box::new(MemoryStore::default()),
                ),
                path,
            )
        })
    })
}

#[gpui_kit::test]
fn public_detail_survives_workspace_epoch_bump(cx: &mut TestAppContext) {
    let _files = super::workspace_layout_tests::LayoutFiles::new();
    let root = root_at(cx, "/courses/crs-000");
    root.update(cx, |root, _| {
        root.workspaces.adopt(workspaces());
        assert_eq!(
            root.current.as_ref().map(|route| route.route.id),
            Some("courses.public_detail"),
            "夹具必须落在公开详情路由上"
        );
    });
    root.update(cx, |root, cx| {
        // 冷启动顺序：详情先发，工作区列表后到（`adopt` 会递增 epoch）。
        root.start_course_detail_load(cx, "crs-000".into());
        root.workspaces.adopt(workspaces());
    });
    cx.run_until_parked();
    root.read_with(cx, |root, _| {
        assert_eq!(
            root.course_detail.state(),
            &cgc_courses::catalog::CoursesListState::Ready,
            "公开详情与工作区无关，工作区列表后到不得把在途响应判过期"
        );
        assert!(
            root.course_detail.detail().is_some(),
            "公开详情必须真正落地，而不是停在加载态"
        );
    });
}

#[gpui_kit::test]
fn workspace_detail_dropped_by_epoch_resets_the_gate(cx: &mut TestAppContext) {
    let _files = super::workspace_layout_tests::LayoutFiles::new();
    let root = root_at(cx, "/w/alpha/courses/crs-000");
    root.update(cx, |root, _| {
        root.workspaces.adopt(workspaces());
        assert_eq!(
            root.current.as_ref().map(|route| route.route.id),
            Some("courses.detail"),
            "夹具必须落在工作区详情路由上"
        );
    });
    root.update(cx, |root, cx| {
        root.start_course_detail_load(cx, "crs-000".into());
        // 工作区列表重取：epoch 前移，在途详情响应因越界被丢弃。
        root.workspaces.adopt(workspaces());
    });
    cx.run_until_parked();
    root.read_with(cx, |root, _| {
        assert_eq!(
            root.course_detail.state(),
            &cgc_courses::catalog::CoursesListState::Idle,
            "丢弃越界响应后必须复位状态机，否则闸门永久停在 Loading"
        );
        assert!(
            !root.course_detail_started,
            "丢弃后必须清 started：render 闸门要求 `!started && Idle` 才会重发"
        );
    });
}

#[gpui_kit::test]
fn public_response_arriving_after_workspace_switch_is_dropped(cx: &mut TestAppContext) {
    let _files = super::workspace_layout_tests::LayoutFiles::new();
    let root = root_at(cx, "/courses");
    root.update(cx, |root, _| {
        root.workspaces.adopt(workspaces());
        assert_eq!(
            root.current.as_ref().map(|route| route.route.id),
            Some("courses.public_list"),
            "夹具必须落在公开目录路由上"
        );
        root.courses = CourseCatalogService::new(Arc::new(FakeCoursesApi::with_seed(23)));
    });
    root.update(cx, |root, cx| {
        // 公开面请求先发（稍后才返回的成功响应）。
        root.start_courses_load(cx, true);
    });
    root.update(cx, |root, cx| {
        // 切到工作区目录后再发一次；新请求换成不可达 API，这样「有数据但状态失败」
        // 只可能来自迟到的公开响应。
        root.courses = CourseCatalogService::new(Arc::new(FakeCoursesApi::failing()));
        root.navigate("/w/alpha/courses");
        root.start_courses_load(cx, true);
    });
    cx.run_until_parked();
    root.read_with(cx, |root, _| {
        assert!(
            root.courses.items().is_empty(),
            "迟到的公开列表不得写进工作区列表缓存（串台）"
        );
        assert!(
            matches!(
                root.courses.state(),
                cgc_courses::catalog::CoursesListState::Failed(_)
            ),
            "工作区请求失败必须如实反映，不能被迟到的公开响应顶成 Ready"
        );
    });
}

fn course_owned_by_beta() -> cgc_courses::catalog::CourseDetail {
    cgc_courses::catalog::CourseDetail {
        id: "crs-000".into(),
        title: "Course B".into(),
        description: None,
        status: "open".into(),
        visibility: "public".into(),
        workspace_id: Some("ws-beta".into()),
        pricing_enabled: false,
        enrollment_policy: "open".into(),
        available_price_tiers: Vec::new(),
        enrollment_status: None,
        revision_number: Some(1),
    }
}

#[gpui_kit::test]
fn cross_workspace_open_lands_in_target_workspace_tab(cx: &mut TestAppContext) {
    let _files = super::workspace_layout_tests::LayoutFiles::new();
    let root = root_at(cx, "/w/alpha/courses");
    root.update(cx, |root, cx| {
        root.workspaces.adopt(workspaces());
        root.open_page_tab("/w/alpha/courses", "Alpha courses", cx);
        // 屏幕侧改造后统一走 open_page_tab：先存源台，再切台恢复，最后插入目标 tab。
        root.open_page_tab("/w/beta/courses/crs-001/learn", "Beta learning", cx);
    });
    let beta = crate::workspace_state::entry("ws-beta").expect("目标台必须有持久化桶");
    let beta_paths: Vec<_> = beta.tabs.iter().map(|tab| tab.path.clone()).collect();
    assert!(
        beta_paths.contains(&"/w/beta/courses/crs-001/learn".to_string()),
        "目标台必须拿到新 tab，实际 {beta_paths:?}"
    );
    let alpha = crate::workspace_state::entry("ws-alpha").expect("源台桶必须被保存");
    let alpha_paths: Vec<_> = alpha.tabs.iter().map(|tab| tab.path.clone()).collect();
    assert!(
        alpha_paths.iter().all(|path| !path.contains("/w/beta/")),
        "源台 tab 桶不得混入目标台路径，实际 {alpha_paths:?}"
    );
}

#[gpui_kit::test]
fn cross_workspace_canonicalize_keeps_the_source_tab_bucket(cx: &mut TestAppContext) {
    let _files = super::workspace_layout_tests::LayoutFiles::new();
    let root = root_at(cx, "/w/alpha/courses/crs-000/learn");
    root.update(cx, |root, _| {
        root.workspaces.adopt(workspaces());
        let tab = crate::root_view::state::PaneTab::page(
            "/w/alpha/courses/crs-000/learn",
            "Alpha learning",
        );
        root.active_tab = Some(tab.id.clone());
        root.tabs.push(tab);
        root.canonicalize_course_route(&course_owned_by_beta());
    });
    let alpha = crate::workspace_state::entry("ws-alpha").expect("源台桶必须被保存");
    let alpha_paths: Vec<_> = alpha.tabs.iter().map(|tab| tab.path.clone()).collect();
    assert_eq!(
        alpha_paths,
        vec!["/w/alpha/courses/crs-000/learn".to_string()],
        "纠偏只改路由：源台 tab 必须保留自己的路径，不得被改写成目标台地址"
    );
    root.read_with(cx, |root, _| {
        assert_eq!(
            root.current
                .as_ref()
                .and_then(|route| route.params.get("slug"))
                .map(String::as_str),
            Some("beta"),
            "纠偏后路由必须落在课程所属工作台"
        );
    });
}

struct RootProbe {
    root: Entity<RootView>,
}

impl Render for RootProbe {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div().size_full().child(self.root.clone())
    }
}

fn root_window_at(
    cx: &mut TestAppContext,
    path: &'static str,
) -> (gpui_kit::AnyWindowHandle, Entity<RootView>) {
    cx.update(gpui_kit::init);
    cx.update(|cx| {
        let (handle, probe) = gpui_kit::open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(Bounds::centered(
                    None,
                    size(px(960.0), px(720.0)),
                    cx,
                ))),
                ..Default::default()
            },
            cx,
            |_, cx| {
                let root = cx.new(|_| {
                    let mut session = SessionService::new(
                        Box::new(FakeAuthApi::demo()),
                        Box::new(MemoryStore::default()),
                    );
                    session
                        .sign_in("demo@example.com", "demo")
                        .expect("fake login");
                    let mut root = RootView::with_session_from(
                        crate::registration::build_registry().expect("registry"),
                        crate::i18n::Language::Zh,
                        crate::theme::ThemePreference::Light,
                        session,
                        path,
                    );
                    // 不自动跑会话校验/工作区拉取：夹具自己控制状态。
                    root.session_checked = true;
                    root.workspaces_started = true;
                    root
                });
                cx.new(|_| RootProbe { root: root.clone() })
            },
        )
        .expect("root probe window");
        let root = probe.read(cx).root.clone();
        (handle, root)
    })
}

fn public_course_confirmed() -> cgc_courses::catalog::CourseDetail {
    cgc_courses::catalog::CourseDetail {
        id: "crs-000".into(),
        title: "Free course".into(),
        description: None,
        status: "open".into(),
        visibility: "public".into(),
        workspace_id: None,
        pricing_enabled: false,
        enrollment_policy: "open".into(),
        available_price_tiers: Vec::new(),
        enrollment_status: Some("confirmed".into()),
        revision_number: Some(1),
    }
}

#[gpui_kit::test]
fn enter_starts_learning_from_public_course_detail(cx: &mut TestAppContext) {
    let _files = super::workspace_layout_tests::LayoutFiles::new();
    let (handle, root) = root_window_at(cx, "/courses/crs-000");
    root.update(cx, |root, _| {
        root.workspaces.adopt(workspaces());
        root.adopt_course_detail(public_course_confirmed());
        assert_eq!(
            root.current.as_ref().map(|route| route.route.id),
            Some("courses.public_detail"),
            "夹具必须落在公开详情路由上"
        );
    });
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        window.press("enter", cx);
    })
    .unwrap();
    root.read_with(cx, |root, _| {
        assert_eq!(
            root.current.as_ref().map(|route| route.route.id),
            Some("courses.public_learning"),
            "公开详情页展示「开始学习」提示，Enter 必须真的进入学习页"
        );
        assert!(
            root.tabs
                .iter()
                .any(|tab| tab.path == "/courses/crs-000/learn"),
            "进入学习必须落一个 tab（navigate 不插 tab）"
        );
    });
}

#[gpui_kit::test]
fn approval_shortcut_works_on_public_learning(cx: &mut TestAppContext) {
    let _files = super::workspace_layout_tests::LayoutFiles::new();
    let (handle, root) = root_window_at(cx, "/courses/crs-000/learn");
    root.update(cx, |root, _| {
        root.workspaces.adopt(workspaces());
        assert_eq!(
            root.current.as_ref().map(|route| route.route.id),
            Some("courses.public_learning"),
            "夹具必须落在公开学习页路由上"
        );
        // 审批卡在公开学习页同样存在；这里只观察快捷键是否被分发到处理器。
        root.chat.session.thread.pending_permission =
            Some(cgc_agent_ui::conversation::PermissionRequest {
                request_id: "perm-1".into(),
                title: "允许运行命令？".into(),
                tool: Some("run_command".into()),
                tool_call_id: None,
                args: None,
                options: Vec::new(),
            });
    });
    cx.update_window(handle, |_, window, cx| {
        window.press("ctrl-shift-y", cx);
    })
    .unwrap();
    root.read_with(cx, |root, _| {
        assert!(
            root.chat.session.thread.pending_permission.is_none(),
            "公开学习页必须响应既有审批快捷键（Ctrl+Shift+Y）"
        );
    });
}
