use gpui_kit::component::button::{Button, ButtonCustomVariant, ButtonVariants as _};
use gpui_kit::component::{Icon, Sizable, Size};
use gpui_kit::InteractiveElement as _;
use gpui_kit::*;

/// composer 主题样式（由各栈从自己的 palette 构造）。
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ComposerStyle {
    pub view: Hsla,
    pub line: Hsla,
    pub accent: Hsla,
    pub danger: Hsla,
    pub canvas: Hsla,
    pub radius: f32,
}

/// 发送/停止回调（需要 window 聚焦输入框等）。
pub type ComposerAction = Box<dyn Fn(&mut Window, &mut App) + 'static>;

/// composer 输入卡容器（两栈共用：圆角/focus 边框/背景/padding）。
///
/// 返回 `Div`，调用方继续 `.child(...)` 链式添加输入区与 footer，便于渐进迁移。
pub fn composer_card(
    id: impl Into<SharedString>,
    focused: bool,
    style: ComposerStyle,
) -> gpui_kit::Stateful<gpui_kit::Div> {
    div()
        .id(id.into())
        .flex()
        .flex_col()
        .gap(px(4.0))
        .p(px(4.0))
        .rounded(px(style.radius))
        .border_1()
        .border_color(if focused { style.accent } else { style.line })
        .bg(style.view)
}

/// composer footer 行容器（左控件 + 右侧发送/停止，允许换行）。
pub fn composer_footer() -> gpui_kit::Div {
    div()
        .flex()
        .flex_row()
        .flex_wrap()
        .items_center()
        .gap(px(4.0))
        .w_full()
        .min_w(px(0.0))
}

/// 发送/停止按钮（两栈共用外观与交互语义）。
pub struct SendButtonSpec {
    pub id: SharedString,
    pub aria: SharedString,
    pub tooltip: SharedString,
    pub glyph: Icon,
    pub bg: Hsla,
    pub fg: Hsla,
    pub radius: f32,
    pub ml_auto: bool,
    pub on_click: ComposerAction,
}

/// 发送/停止按钮：Kit `Button` 的 icon-only 形态（24px），配色走 custom
/// 变体以保持两栈现有的 accent/danger/soft 语义。
///
/// 注意：`!model_ready` 目前由调用方在 `on_click` 里提前返回，这里不设
/// `disabled`（kit 的 disabled 会替换配色）；保持现状的观感，语义留待单独收敛。
pub fn render_send_button(spec: SendButtonSpec, cx: &App) -> AnyElement {
    let SendButtonSpec {
        id,
        aria,
        tooltip,
        glyph,
        bg,
        fg,
        radius,
        ml_auto,
        on_click,
    } = spec;
    let custom = ButtonCustomVariant::new(cx)
        .color(bg)
        .foreground(fg)
        .hover(bg)
        .active(bg);
    let mut button = Button::new(id)
        .icon(glyph)
        .custom(custom)
        .with_size(Size::Size(px(24.0)))
        .rounded(px(radius))
        .accessibility_label(aria)
        .tooltip(tooltip)
        .on_click(move |_, window, cx| on_click(window, cx));
    if ml_auto {
        button = button.ml_auto();
    }
    button.into_any_element()
}

#[cfg(test)]
mod tests {
    use super::ComposerStyle;
    use gpui_kit::Hsla;

    #[test]
    fn style_is_copy_and_radius_round_trips() {
        let style = ComposerStyle {
            view: Hsla::default(),
            line: Hsla::default(),
            accent: Hsla::default(),
            danger: Hsla::default(),
            canvas: Hsla::default(),
            radius: 6.0,
        };
        let copied = style;
        assert_eq!(copied.radius, 6.0);
    }
}
