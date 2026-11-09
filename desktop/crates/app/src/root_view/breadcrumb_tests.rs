//! 面包屑只显示位置，不再承担导航职责。

use super::RootView;
use crate::i18n::Language;
use crate::theme::ThemePreference;
use cgc_platform::session::{FakeAuthApi, MemoryStore, SessionService};
use cgc_platform::workspace::{FakeWorkspaceApi, WorkspaceService};
use gpui_kit::test::{TestQueryExt, TestWindowExt};
use gpui_kit::{
    div, px, size, AppContext, Bounds, Context, Entity, IntoElement, ParentElement, Render, Styled,
    TestAppContext, Window, WindowBounds, WindowOptions,
};

struct BreadcrumbProbe {
    root: Entity<RootView>,
}

impl Render for BreadcrumbProbe {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let bar = self.root.update(cx, |root, cx| {
            let palette = crate::theme::palette(gpui_kit::component::ThemeMode::Light);
            root.render_breadcrumb_bar(Language::En, &palette, cx)
        });
        div().size(px(740.0)).flex().flex_col().child(bar)
    }
}

fn open_breadcrumb(cx: &mut TestAppContext) -> (gpui_kit::AnyWindowHandle, Entity<RootView>) {
    cx.update(gpui_kit::init);
    cx.update(|cx| {
        let (handle, probe) = gpui_kit::open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(Bounds::centered(
                    None,
                    size(px(740.), px(120.)),
                    cx,
                ))),
                ..Default::default()
            },
            cx,
            |_, cx| {
                let root = cx.new(|_| {
                    let mut root = RootView::with_session_from(
                        crate::registration::build_registry().unwrap(),
                        Language::En,
                        ThemePreference::Light,
                        SessionService::new(
                            Box::new(FakeAuthApi::demo()),
                            Box::new(MemoryStore::default()),
                        ),
                        "/learning",
                    );
                    let mut workspaces =
                        WorkspaceService::new(std::sync::Arc::new(FakeWorkspaceApi::demo()));
                    let listed = workspaces.fetch(None).expect("demo workspaces");
                    workspaces.adopt(listed);
                    root.state.workspaces = workspaces;
                    root
                });
                cx.new(|_| BreadcrumbProbe { root })
            },
        )
        .expect("breadcrumb probe window");
        let root = probe.read(cx).root.clone();
        (handle, root)
    })
}

#[gpui_kit::test]
fn breadcrumb_is_a_position_not_a_navigator(cx: &mut TestAppContext) {
    let (handle, _root) = open_breadcrumb(cx);
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        let paths = window
            .elements()
            .iter()
            .map(|element| format!("{:?}", element.path()))
            .collect::<Vec<_>>();
        assert!(
            !paths.iter().any(|path| path.contains("breadcrumb-section")),
            "breadcrumb must not own a section menu: {paths:?}"
        );
    })
    .unwrap();
}
