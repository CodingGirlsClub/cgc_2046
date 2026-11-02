use super::panel::render_chat_panel;
use crate::conversation_session::ConnectionPhase;
use crate::i18n::Language;
use crate::root_view::{screens::ScreenContext, RootView};
use cgc_platform::session::{FakeAuthApi, MemoryStore, SessionService};
use gpui_kit::test::{TestQueryExt, TestSupportExt, TestWindowExt};
use gpui_kit::{
    div, px, size, AppContext, Bounds, Context, Entity, InteractiveElement, IntoElement,
    ParentElement, Render, Styled, TestAppContext, Window, WindowBounds, WindowOptions,
};

struct AcpComposerProbe {
    root: Entity<RootView>,
}

impl Render for AcpComposerProbe {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let panel = self.root.update(cx, |root, cx| {
            let palette = crate::theme::palette(gpui_kit::component::ThemeMode::Light);
            render_chat_panel(
                &mut ScreenContext::new(&mut root.state),
                Language::En,
                &palette,
                cx,
            )
        });
        div()
            .id("acp-composer-probe")
            .test_support()
            .size_full()
            .child(panel)
    }
}

#[gpui_kit::test]
fn acp_composer_uses_shared_editor_growth_and_preserves_draft(cx: &mut TestAppContext) {
    cx.update(gpui_kit::init);
    let (handle, probe) = cx.update(|cx| {
        gpui_kit::open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(Bounds {
                    origin: Default::default(),
                    size: size(px(360.0), px(500.0)),
                })),
                ..Default::default()
            },
            cx,
            |window, cx| {
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
                    root.state.chat.agent = "codex".into();
                    root.state.chat.session.phase = ConnectionPhase::Ready;
                    root
                });
                root.update(cx, |root, cx| root.initialize_chat_input(window, cx));
                cx.new(|_| AcpComposerProbe { root })
            },
        )
        .unwrap()
    });
    cx.update_window(handle, |_, window, cx| {
        let root = probe.read(cx).root.clone();
        let input = root.read(cx).chat_input.clone().unwrap();
        crate::composer_context::ui_tests::assert_shared_editor_growth(&input, window, cx);
        let send = window.find_by_label("Send");
        assert_eq!(send.bounds().size, size(px(24.0), px(24.0)));
        root.update(cx, |root, cx| {
            root.state.chat.input = "/test".into();
            root.state.chat.session.commands = vec![cgc_platform::acp::connection::CommandView {
                name: "test".into(),
                description: "Test command".into(),
                requires_argument: false,
            }];
            cx.notify();
        });
        input.update(cx, |state, cx| state.set_value("/test", window, cx));
        window.render_frame(cx);
        let menu = window.find("chat-slash-popup");
        let editor = &window.find_all_by_role(gpui_kit::Role::MultilineTextInput)[0];
        assert!(menu.visible());
        assert!(menu.bounds().bottom() <= editor.bounds().top());
    })
    .unwrap();
    for (width, height) in [(260.0, 500.0), (380.0, 340.0), (260.0, 340.0)] {
        cx.simulate_window_resize(handle, size(px(width), px(height)));
        cx.update_window(handle, |_, window, cx| {
            let root = probe.read(cx).root.clone();
            root.update(cx, |root, cx| {
                root.state.chat.input.clear();
                cx.notify();
            });
            let input = root.read(cx).chat_input.clone().unwrap();
            input.update(cx, |state, cx| state.set_value("", window, cx));
            crate::composer_context::ui_tests::assert_shared_editor_growth(&input, window, cx);
            assert!(window.find_by_label("Send").visible());
        })
        .unwrap();
    }
}
