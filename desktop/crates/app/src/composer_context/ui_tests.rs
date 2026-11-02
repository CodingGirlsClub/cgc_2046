use super::{ComposerContext, AUTO_PAGE_TOKEN};
use crate::i18n::Language;
use crate::page_context::{ConversationScope, PageBody, PageContext, PageContextState};
use cgc_agent_ui::message_editor::MessageEditor;
use gpui_kit::component::input::TextareaState;
use gpui_kit::test::{TestQueryExt, TestSupportExt, TestWindowExt};
use gpui_kit::{
    div, px, size, AppContext, Bounds, Context, Entity, InteractiveElement, IntoElement,
    ParentElement, Render, Styled, TestAppContext, Window, WindowBounds, WindowOptions,
};

struct ComposerProbe {
    input: Entity<TextareaState>,
    composer: ComposerContext,
    page: PageContextState,
    scope: ConversationScope,
    language: Language,
    width: f32,
}

impl Render for ComposerProbe {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.composer
            .ensure_auto(&self.input, self.page.visible().as_ref(), window, cx);
        let labels = self.composer.labels();
        let page = self.page.clone();
        let scope = self.scope.clone();
        let language = self.language;
        let palette = crate::theme::palette(gpui_kit::component::ThemeMode::Light);
        div()
            .id("reference-composer")
            .test_support()
            .w(px(self.width))
            .h(px(150.))
            .child(
                MessageEditor::new(&self.input, "Message the agent", palette.ink_3).token(
                    move |context, _, _| {
                        crate::mention_chip::render_resolved_chip(
                            context,
                            palette,
                            std::path::Path::new("."),
                            labels.label(
                                context.token().id(),
                                page.chip_context(&scope).as_ref(),
                                language,
                            ),
                        )
                    },
                ),
            )
    }
}

pub(crate) fn assert_shared_editor_growth(
    input: &Entity<TextareaState>,
    window: &mut Window,
    cx: &mut gpui_kit::App,
) {
    let height = |window: &Window| {
        let editors = window.find_all_by_role(gpui_kit::Role::MultilineTextInput);
        assert_eq!(
            editors.len(),
            1,
            "The actual composer must contain one editor"
        );
        let editor = &editors[0];
        assert!(editor.visible());
        editor.bounds().size.height
    };
    window.render_frame(cx);
    let empty = height(window);
    let line_height = input.read(cx).line_height().unwrap();
    assert_eq!(
        empty,
        line_height * 4.0 + px(16.0),
        "Four lines plus editor padding"
    );
    input.update(cx, |state, cx| state.focus(window, cx));
    let paragraph = "A long paragraph without newline characters. ".repeat(20);
    window.input(&paragraph, cx);
    window.render_frame(cx);
    let wrapped = height(window);
    assert!(wrapped > empty, "Soft wrapping must grow the editor");
    assert_eq!(
        wrapped,
        line_height * 8.0 + px(16.0),
        "Eight lines plus editor padding"
    );
    assert_eq!(input.read(cx).value().as_str(), paragraph);
    let additional = "Additional text. ".repeat(50);
    window.input(&additional, cx);
    window.render_frame(cx);
    assert_eq!(
        height(window),
        wrapped,
        "Long content must scroll internally"
    );
    assert_eq!(
        input.read(cx).value().as_str(),
        format!("{paragraph}{additional}")
    );
    assert!(
        input.read(cx).scroll_offset().y < px(0.0),
        "The viewport follows the caret"
    );
    let geometry = input.read(cx).prepaint_caret_geometry().unwrap();
    let caret_top = geometry.cursor_bounds().top() + geometry.scroll_offset().y;
    assert!(caret_top >= geometry.input_bounds().top());
    assert!(caret_top + geometry.cursor_bounds().size.height <= geometry.input_bounds().bottom());
    let content = input.read(cx).content();
    input.update(cx, |state, cx| {
        state.set_selected_range(0..content.text().len(), cx)
    });
    window.press("backspace", cx);
    window.render_frame(cx);
    assert_eq!(
        height(window),
        empty,
        "Deleting restores the compact height"
    );
    assert!(input.read(cx).value().is_empty());
    println!(
        "Actual composer editor: empty={empty:?}, wrapped={wrapped:?}, restored={:?}",
        height(window)
    );
}

fn page(id: &str) -> PageContext {
    PageContext {
        workspace_id: Some("workspace-1".into()),
        tab_id: format!("tab-{id}"),
        route: format!("/courses/{id}/learn"),
        title: format!("Course {id}: a long title that must leave the reference status visible"),
        version: "v1".into(),
        body: PageBody::Ready(format!("Task for {id}").into()),
        course: None,
    }
}

#[gpui_kit::test]
fn real_textarea_reference_status_redraws_without_changing_the_draft(cx: &mut TestAppContext) {
    cx.update(gpui_kit::init);
    for agent in ["native", "codex"] {
        let (handle, view) = cx.update(|cx| {
            gpui_kit::open_window(
                WindowOptions {
                    window_bounds: Some(WindowBounds::Windowed(Bounds::centered(
                        None,
                        size(px(680.), px(300.)),
                        cx,
                    ))),
                    ..Default::default()
                },
                cx,
                |window, cx| {
                    let input = cx.new(|cx| MessageEditor::new_state(window, cx));
                    let state = PageContextState::default();
                    state.set_current(Some(page("A")));
                    cx.new(|_| ComposerProbe {
                        input,
                        composer: ComposerContext::default(),
                        page: state,
                        scope: ConversationScope::new("test-session", agent),
                        language: Language::Zh,
                        width: 420.,
                    })
                },
            )
            .unwrap()
        });
        cx.update_window(handle, |_, window, cx| {
            window.render_frame(cx);
            let input = view.read(cx).input.clone();
            input.update(cx, |state, cx| {
                state.focus(window, cx);
                state.insert("what is the task?", window, cx);
            });
            window.render_frame(cx);
            let original = input.read(cx).content();
            let selection = input.read(cx).selected_range();
            assert_eq!(original.tokens()[0].token().id().as_ref(), AUTO_PAGE_TOKEN);
            assert!(window.find_by_label("待引用").visible());
            view.update(cx, |view, cx| {
                let (_, frozen) = view
                    .page
                    .freeze(view.scope.clone(), "first question".into());
                view.page.mark_sent(&view.scope, &frozen);
                cx.notify();
            });
            window.render_frame(cx);
            assert!(window.find_by_label("已引用").visible());
            for width in [260., 420., 640.] {
                view.update(cx, |view, cx| {
                    view.width = width;
                    cx.notify();
                });
                window.render_frame(cx);
                let status = window.find_by_label("已引用");
                assert!(status.visible());
                assert!(status.bounds().right() <= px(width));
                assert_eq!(input.read(cx).content(), original);
                assert_eq!(input.read(cx).selected_range(), selection);
            }
            view.update(cx, |view, cx| {
                view.page.set_current(Some(page("B")));
                cx.notify();
            });
            window.render_frame(cx);
            assert!(window.find_by_label("待引用").visible());
            view.update(cx, |view, cx| {
                view.page.set_current(Some(page("A")));
                view.page.invalidate_loaded(&view.scope);
                cx.notify();
            });
            window.render_frame(cx);
            assert!(window.find_by_label("待更新").visible());
            view.update(cx, |view, cx| {
                view.language = Language::En;
                cx.notify();
            });
            window.render_frame(cx);
            assert!(window.find_by_label("Update pending").visible());
            assert_eq!(input.read(cx).content(), original);
            assert_eq!(input.read(cx).selected_range(), selection);
            input.update(cx, |state, cx| {
                state.set_selected_range(original.tokens()[0].range(), cx);
            });
            window.press("backspace", cx);
            window.render_frame(cx);
            assert!(input.read(cx).tokens().is_empty());
            window.press(
                if cfg!(target_os = "macos") {
                    "cmd-z"
                } else {
                    "ctrl-z"
                },
                cx,
            );
            assert_eq!(input.read(cx).content(), original);
        })
        .unwrap();
    }
}
