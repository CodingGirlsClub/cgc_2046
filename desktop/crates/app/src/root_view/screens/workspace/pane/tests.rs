use super::{render_pane_notices, render_pane_tabs};

use crate::root_view::{screens::ScreenContext, state::PaneTab, RootView};
use cgc_platform::mcp::credential::McpError;
use cgc_platform::session::{FakeAuthApi, MemoryStore, SessionService};
use gpui_kit::test::{TestQueryExt, TestWindowExt};
use gpui_kit::{
    div, px, size, AppContext, Bounds, Context, Entity, IntoElement, ParentElement, Render, Styled,
    TestAppContext, Window, WindowBounds, WindowOptions,
};

struct PaneProbe {
    root: Entity<RootView>,
    width: f32,
}

impl Render for PaneProbe {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let (tabs, notices) = self.root.update(cx, |root, cx| {
            let palette = crate::theme::palette(gpui_kit::component::ThemeMode::Light);
            let mut context = ScreenContext::new(&mut root.state);
            (
                render_pane_tabs(&mut context, &palette, cx),
                render_pane_notices(&mut context, &palette, cx),
            )
        });
        div()
            .w(px(self.width))
            .flex()
            .flex_col()
            .child(tabs)
            .child(notices)
    }
}

#[gpui_kit::test]
fn authorization_failure_and_long_notices_keep_restored_tabs_visible(cx: &mut TestAppContext) {
    cx.update(gpui_kit::init);
    let (handle, probe) = cx.update(|cx| {
        gpui_kit::open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(Bounds::centered(
                    None,
                    size(px(740.), px(360.)),
                    cx,
                ))),
                ..Default::default()
            },
            cx,
            |_, cx| {
                let root = cx.new(|_| {
                    let mut root = RootView::with_session(
                        crate::registration::build_registry().unwrap(),
                        crate::i18n::Language::En,
                        crate::theme::ThemePreference::Light,
                        SessionService::new(
                            Box::new(FakeAuthApi::demo()),
                            Box::new(MemoryStore::default()),
                        ),
                    );
                    root.state.tabs.push(PaneTab::issue(
                        "course-test",
                        "unit-test",
                        "Temperature and measurement",
                    ));
                    root.state.active_tab = Some(root.state.tabs[0].id.clone());
                    root
                });
                cx.new(|_| PaneProbe { root, width: 740. })
            },
        )
        .unwrap()
    });
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        let normal = window.find_by_label("Temperature and measurement");
        assert!(normal.visible());
        let root = probe.read(cx).root.clone();
        root.update(cx, |root, cx| {
            root.state.pane_notice = Some("Platform tools unavailable: domain mcp_token_limit_reached: active connection token limit reached (10; active = unrevoked and not idle-expired); revoke an unused token first".repeat(3));
            root.state.agent_authorization_error = Some(McpError::Domain {
                code: "mcp_token_limit_reached".into(), message: "Active connection token limit reached".into(),
            });
            cx.notify();
        });
        for width in [740., 320.] {
            probe.update(cx, |probe, cx| { probe.width = width; cx.notify(); });
            window.render_frame(cx);
            let tab = window.find_by_label("Temperature and measurement");
            assert!(tab.visible(), "Restored course tab must stay visible at {width}px");
            assert_eq!(tab.bounds().size.width, normal.bounds().size.width);
            let retry = window.find_by_label("Retry");
            assert!(retry.visible());
            assert!(retry.bounds().origin.y >= tab.bounds().bottom());
            assert!(retry.bounds().right() <= px(width));
        }
        root.update(cx, |root, _| {
            assert_eq!(root.state.tabs.len(), 1);
            assert_eq!(root.state.active_tab.as_deref(), Some("issue:course-test:unit-test"));

        });
        println!("Actual TabBar: restored tab visible at 740/320px; authorization retry and long notices occupy separate rows");
    }).unwrap();
}
