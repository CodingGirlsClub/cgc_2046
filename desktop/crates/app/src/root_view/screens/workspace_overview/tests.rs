//! 概览页失败态（issue #1238）：后台不可达时必须退出「加载中…」并给出重试入口。

use super::render_workspace_overview;
use crate::i18n::{translate, Key, Language};
use crate::root_view::{screens::ScreenContext, RootView};
use cgc_platform::session::{FakeAuthApi, MemoryStore, SessionService};
use cgc_platform::workspace::{
    FakeWorkspaceApi, WorkspaceError, WorkspaceListState, WorkspaceService,
};
use gpui_kit::test::{TestQueryExt, TestWindowExt};
use gpui_kit::{
    div, px, size, AppContext, Bounds, Context, Entity, IntoElement, ParentElement, Render, Role,
    Styled, TestAppContext, Window, WindowBounds, WindowOptions,
};

struct OverviewProbe {
    root: Entity<RootView>,
}

impl Render for OverviewProbe {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let overview = self.root.update(cx, |root, cx| {
            let palette = crate::theme::palette(gpui_kit::component::ThemeMode::Light);
            let mut context = ScreenContext::new(&mut root.state);
            render_workspace_overview(&mut context, Language::En, &palette, cx)
        });
        div().size(px(740.0)).flex().flex_col().child(overview)
    }
}

fn open_overview(cx: &mut TestAppContext) -> (gpui_kit::AnyWindowHandle, Entity<RootView>) {
    cx.update(gpui_kit::init);
    cx.update(|cx| {
        let (handle, probe) = gpui_kit::open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(Bounds::centered(
                    None,
                    size(px(740.), px(520.)),
                    cx,
                ))),
                ..Default::default()
            },
            cx,
            |_, cx| {
                let root = cx.new(|_| {
                    let mut root = RootView::with_session(
                        crate::registration::build_registry().unwrap(),
                        Language::En,
                        crate::theme::ThemePreference::Light,
                        SessionService::new(
                            Box::new(FakeAuthApi::demo()),
                            Box::new(MemoryStore::default()),
                        ),
                    );
                    // 断言只依赖状态机，不真的发请求：换成本地 fake API。
                    root.state.workspaces =
                        WorkspaceService::new(std::sync::Arc::new(FakeWorkspaceApi::demo()));
                    root
                });
                cx.new(|_| OverviewProbe { root })
            },
        )
        .expect("overview probe window");
        let root = probe.read(cx).root.clone();
        (handle, root)
    })
}

#[gpui_kit::test]
fn unreachable_backend_leaves_loading_and_offers_retry(cx: &mut TestAppContext) {
    let (handle, root) = open_overview(cx);
    let error_label = translate(Language::En, Key::AppWorkspaceError);
    let retry_label = translate(Language::En, Key::AppWorkspaceRetry);

    // 1. 加载中：没有失败态，也没有重试入口。
    root.update(cx, |root, cx| {
        root.state.workspaces.begin_load();
        cx.notify();
    });
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        assert!(
            window.try_find_by_label(error_label).is_none(),
            "step 1: loading must not claim failure"
        );
        assert!(
            window.try_find_by_label(retry_label).is_none(),
            "step 1: loading must not offer retry"
        );
    })
    .unwrap();

    // 2. 失败（后台不可达）：渲染失败态 + 重试入口，而不是永远「加载中…」。
    root.update(cx, |root, cx| {
        root.state.workspaces.fail(&WorkspaceError::Transport(
            "http://127.0.0.1:4000/api/graphql: Connection refused".to_string(),
        ));
        cx.notify();
    });
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        let alert = window.find_by_label(error_label);
        assert!(alert.visible(), "step 2: failure state must be visible");
        assert_eq!(
            alert.role(),
            Some(Role::Alert),
            "step 2: announced as alert"
        );
        let retry = window.find_by_label(retry_label);
        assert!(retry.visible(), "step 2: retry entry must be visible");
        // 失败原因必须出现在页面上（不只是 tooltip 里），且可被读屏软件读出。
        let detail = window.find_by_label(
            "transport error: http://127.0.0.1:4000/api/graphql: Connection refused",
        );
        assert!(
            detail.visible(),
            "step 2: failure diagnostic must be rendered, not only in a tooltip"
        );
    })
    .unwrap();

    // 3. 真实点击重试按钮（走 Kit 的点击派发，验证按钮真的接线）：
    //    失败态让位，重新进入加载/已就绪。
    root.update(cx, |_, cx| cx.notify());
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        window.click("workspace-overview-retry", cx);
        window.render_frame(cx);
        assert!(
            window.try_find_by_label(error_label).is_none(),
            "step 3: clicking retry must clear the failure state"
        );
    })
    .unwrap();
    root.update(cx, |root, _| {
        assert!(
            !matches!(root.state.workspaces.state(), WorkspaceListState::Failed(_)),
            "step 3: retry restarts the load, got {:?}",
            root.state.workspaces.state()
        );
    });
}

#[gpui_kit::test]
fn overview_drops_cross_workspace_blocks_and_shows_local_courses(cx: &mut TestAppContext) {
    use cgc_courses::catalog::{CourseCatalogService, FakeCoursesApi};
    use cgc_events::enrollments::MyEnrollmentRow;
    use cgc_events::list::{EventListService, FakeEventsApi};
    use cgc_platform::workspace::OfferingScope;
    use std::sync::Arc;

    let (handle, root) = open_overview(cx);
    root.update(cx, |root, cx| {
        let listed = root.workspaces.fetch(None).expect("demo workspaces");
        root.workspaces.adopt(listed);

        let mut events = EventListService::new(Arc::new(FakeEventsApi::with_seed(3)));
        events.begin_first_load();
        let page = events
            .fetch(None, OfferingScope::Public)
            .expect("events page");
        events.adopt_page(page);
        root.events = events;

        let mut courses = CourseCatalogService::new(Arc::new(FakeCoursesApi::with_seed(3)));
        courses.begin_first_load();
        let page = courses
            .fetch(None, OfferingScope::Public)
            .expect("courses page");
        courses.adopt_page(page);
        root.courses = courses;

        // 跨台报名数据存在，但概览不应再渲染它。
        root.enrollments_rows = vec![MyEnrollmentRow {
            id: "enr-1".into(),
            status: "confirmed".into(),
            target_title: Some("Cross workspace".into()),
            starts_at: None,
            event_id: None,
            course_id: Some("cross-1".into()),
            payment_mode: None,
            check_in_code: None,
        }];
        cx.notify();
    });

    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        let labels = window
            .elements()
            .iter()
            .filter_map(|element| element.label().map(str::to_string))
            .collect::<Vec<_>>();
        assert!(
            labels.iter().any(|label| label == "Upcoming events"),
            "workspace overview keeps the local events block; labels: {labels:?}"
        );
        assert!(
            window.try_find_by_label("Courses").is_some(),
            "workspace overview shows the local courses entry"
        );
        assert!(
            window.try_find_by_label("Continue learning").is_none(),
            "cross-workspace learning block must be removed"
        );
        assert!(
            window.try_find_by_label("My enrollments").is_none(),
            "cross-workspace enrollments block must be removed"
        );
    })
    .unwrap();
}
