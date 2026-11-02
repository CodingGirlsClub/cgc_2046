use super::NativeAgentView;
use crate::i18n::Language;
use crate::native_runtime::NativeRuntimeHandle;
use cgc_agent_core::{SelectedModel, Thread};
use cgc_agent_provider::{FakeProvider, Model, ModelId, ModelLimits, ProviderId};
use gpui_kit::component::input::TextareaState;
use gpui_kit::test::{TestQueryExt, TestSupportExt, TestWindowExt};
use gpui_kit::{
    div, px, size, App, AppContext, Bounds, Context, Entity, InteractiveElement, IntoElement,
    ParentElement, Render, Styled, TestAppContext, Window, WindowBounds, WindowOptions,
};
use std::sync::Arc;

struct NativeComposerProbe {
    view: Entity<NativeAgentView>,
}

impl NativeComposerProbe {
    fn new(window: &mut Window, cx: &mut App) -> Self {
        let model = Model::new(
            ProviderId::new("fake"),
            "Test provider",
            "test-model",
            "Test model",
            ModelLimits::new(8_000, 1_000),
        );
        let runtime = NativeRuntimeHandle::spawn(
            Thread::new(
                "editor-test",
                SelectedModel::new(ProviderId::new("fake"), ModelId::new("test-model")),
            ),
            None,
            crate::native_runtime::NativeRuntimeConfig {
                provider: Arc::new(FakeProvider::new(
                    ProviderId::new("fake"),
                    "Test provider",
                    vec![model.clone()],
                )),
                model,
                registry: Arc::new(cgc_agent_tools::ToolRegistry::new()),
                context: cgc_agent_tools::ToolContext::new(std::env::temp_dir()),
                context_size: 8_000,
                auto_approve: false,
            },
            None,
        );
        futures::executor::block_on(runtime.inspect()).unwrap();
        let view = cx.new(|cx| {
            NativeAgentView::new(
                window,
                cx,
                runtime,
                crate::page_context::PageContextState::default(),
                Language::En,
                None,
            )
        });
        Self { view }
    }

    fn input(&self, cx: &App) -> Entity<TextareaState> {
        self.view.read(cx).input.clone()
    }
}

impl Render for NativeComposerProbe {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let composer = self.view.update(cx, |view, cx| {
            let draft = view.composer_draft(cx);
            view.render_composer(&draft, window, cx)
        });
        div()
            .id("native-composer-probe")
            .test_support()
            .size_full()
            .flex()
            .flex_col()
            .justify_end()
            .child(composer)
    }
}

#[gpui_kit::test]
fn native_composer_uses_shared_editor_growth_and_preserves_draft(cx: &mut TestAppContext) {
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
            |window, cx| cx.new(|cx| NativeComposerProbe::new(window, cx)),
        )
        .unwrap()
    });
    cx.update_window(handle, |_, window, cx| {
        let input = probe.read(cx).input(cx);
        crate::composer_context::ui_tests::assert_shared_editor_growth(&input, window, cx);
        let send = window.find_by_label("发送");
        assert_eq!(send.bounds().size, size(px(24.0), px(24.0)));
        input.update(cx, |state, cx| state.set_value("/clear", window, cx));
        probe.update(cx, |_, cx| cx.notify());
        window.render_frame(cx);
        let menu = window.find("native-slash-popup");
        let editor = &window.find_all_by_role(gpui_kit::Role::MultilineTextInput)[0];
        assert!(menu.visible());
        assert!(menu.bounds().bottom() <= editor.bounds().top());
    })
    .unwrap();
    for (width, height) in [(260.0, 500.0), (380.0, 340.0), (260.0, 340.0)] {
        cx.simulate_window_resize(handle, size(px(width), px(height)));
        cx.update_window(handle, |_, window, cx| {
            let input = probe.read(cx).input(cx);
            input.update(cx, |state, cx| state.set_value("", window, cx));
            probe.update(cx, |_, cx| cx.notify());
            crate::composer_context::ui_tests::assert_shared_editor_growth(&input, window, cx);
            assert!(window.find_by_label("发送").visible());
        })
        .unwrap();
    }
}
