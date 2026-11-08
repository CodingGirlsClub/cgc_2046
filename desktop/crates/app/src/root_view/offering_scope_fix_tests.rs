//! G 段阶段一回归：R1 加载闸门（公开路由不绑 epoch + 丢弃必须复位）。
//!
//! UI 用例必须串行跑（`--test-threads=1`）：`LayoutFiles` 改的是进程级环境变量。

use super::RootView;
use cgc_platform::session::{FakeAuthApi, MemoryStore, SessionService};
use cgc_platform::workspace::WorkspaceSummary;
use gpui_kit::{AppContext, Entity, TestAppContext};

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
