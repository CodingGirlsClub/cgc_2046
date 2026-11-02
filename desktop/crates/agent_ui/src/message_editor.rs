use gpui_kit::component::input::{
    InlineTokenClickEvent, InlineTokenContext, Textarea, TextareaState,
};
use gpui_kit::InteractiveElement as _;
use gpui_kit::*;

#[derive(IntoElement)]
pub struct MessageEditor {
    state: Entity<TextareaState>,
    input: Textarea,
    placeholder: SharedString,
    placeholder_color: Hsla,
}

impl MessageEditor {
    pub fn new_state(window: &mut Window, cx: &mut Context<TextareaState>) -> TextareaState {
        TextareaState::new(window, cx).auto_grow(4, 8)
    }

    pub fn new(
        state: &Entity<TextareaState>,
        placeholder: impl Into<SharedString>,
        placeholder_color: Hsla,
    ) -> Self {
        let placeholder = placeholder.into();
        Self {
            state: state.clone(),
            input: Textarea::new(state)
                .appearance(false)
                .bordered(false)
                .w_full()
                .aria_label(placeholder.clone()),
            placeholder,
            placeholder_color,
        }
    }

    pub fn token<R: IntoElement>(
        mut self,
        render: impl Fn(&InlineTokenContext, &mut Window, &mut App) -> R + 'static,
    ) -> Self {
        self.input = self.input.token(render);
        self
    }

    pub fn on_token_click(
        mut self,
        listener: impl Fn(&InlineTokenClickEvent, &mut Window, &mut App) + 'static,
    ) -> Self {
        self.input = self.input.on_token_click(listener);
        self
    }
}

impl RenderOnce for MessageEditor {
    fn render(self, _: &mut Window, cx: &mut App) -> impl IntoElement {
        let state = self.state.read(cx);
        let is_empty = state.text().len() == 0;
        let focus = state.focus_handle(cx);
        div()
            .id(("message-editor", self.state.entity_id()))
            .relative()
            .w_full()
            .min_w(px(0.0))
            .child(self.input)
            .children(is_empty.then(|| {
                // Textarea 的默认 placeholder 不做软换行；overlay 对齐其内部文字留白。
                div()
                    .id(("message-editor-placeholder", self.state.entity_id()))
                    .absolute()
                    .top(px(8.0))
                    .left(px(10.0))
                    .right(px(10.0))
                    .text_size(rems(0.875))
                    .line_height(rems(1.25))
                    .text_color(self.placeholder_color)
                    .child(self.placeholder)
                    .on_click(move |_, window, cx| window.focus(&focus, cx))
            }))
    }
}
