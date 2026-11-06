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

    // 3. 重试：失败态立即让位给加载态。
    root.update(cx, |root, cx| {
        root.retry_workspace_load(cx);
        assert!(
            matches!(root.state.workspaces.state(), WorkspaceListState::Loading),
            "step 3: retry restarts the load, got {:?}",
            root.state.workspaces.state()
        );
    });
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        assert!(
            window.try_find_by_label(error_label).is_none(),
            "step 3: retry must clear the failure state"
        );
    })
    .unwrap();
}
