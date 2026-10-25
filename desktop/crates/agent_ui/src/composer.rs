//! 双栈共用的 composer 骨架（Stage 2e）。
//!
//! 只共享与视图模型无关的部分：输入卡容器（圆角/边框/focus 高亮/背景）、
//! footer 行（左侧控件 slot + 右侧发送/停止按钮）。两栈把 textarea/fallback、
//! footer 控件（picker/附件/usage）与发送/停止回调作为 slot 注入；原生差异
//! （queue/steer、审批模式、图片）留在各自 adapter。

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
    pub padding: f32,
    pub gap: f32,
}

/// 发送/停止回调（需要 window 聚焦输入框等）。
pub type ComposerAction = Box<dyn Fn(&mut Window, &mut App) + 'static>;

pub struct ComposerSpec {
    pub card_id: SharedString,
    pub focused: bool,
    pub streaming: bool,
    pub style: ComposerStyle,
    /// 输入区（Textarea 或 fallback 的自定义输入行）。
    pub input: AnyElement,
    /// footer 左侧控件（附件、picker、usage…）。
    pub footer: Vec<AnyElement>,
    /// 发送按钮内容（图标或文字）。
    pub send_glyph: AnyElement,
    pub stop_glyph: AnyElement,
    pub send_aria: SharedString,
    pub stop_aria: SharedString,
    pub on_send: ComposerAction,
    pub on_stop: ComposerAction,
}

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
        .gap(px(style.gap))
        .p(px(style.padding))
        .rounded(px(style.radius))
        .border_1()
        .border_color(if focused { style.accent } else { style.line })
        .bg(style.view)
}

/// 渲染 composer 卡片（输入区 + footer + 发送/停止）。
pub fn render_composer(spec: ComposerSpec) -> AnyElement {
    let ComposerSpec {
        card_id,
        focused,
        streaming,
        style,
        input,
        footer,
        send_glyph,
        stop_glyph,
        send_aria,
        stop_aria,
        on_send,
        on_stop,
    } = spec;
    let button_bg = if streaming {
        style.danger
    } else {
        style.accent
    };
    div()
        .id(card_id)
        .flex()
        .flex_col()
        .gap(px(style.gap))
        .p(px(style.padding))
        .rounded(px(style.radius))
        .border_1()
        .border_color(if focused { style.accent } else { style.line })
        .bg(style.view)
        .child(input)
        .child(
            div()
                .flex()
                .flex_row()
                .flex_wrap()
                .items_center()
                .gap(px(style.gap))
                .w_full()
                .min_w(px(0.0))
                .children(footer)
                .child(
                    div()
                        .id("composer-send")
                        .role(Role::Button)
                        .aria_label(if streaming {
                            stop_aria.clone()
                        } else {
                            send_aria.clone()
                        })
                        .size(px(24.0))
                        .rounded(px(style.radius))
                        .flex()
                        .items_center()
                        .justify_center()
                        .ml_auto()
                        .bg(button_bg)
                        .text_color(style.canvas)
                        .child(if streaming { stop_glyph } else { send_glyph })
                        .on_click(move |_, window, cx| {
                            if streaming {
                                on_stop(window, cx);
                            } else {
                                on_send(window, cx);
                            }
                        }),
                ),
        )
        .into_any_element()
}

/// 发送/停止按钮（两栈共用外观与交互语义）。
pub struct SendButtonSpec {
    pub id: SharedString,
    pub streaming: bool,
    pub aria: SharedString,
    pub tooltip: SharedString,
    pub glyph: AnyElement,
    pub bg: Hsla,
    pub fg: Hsla,
    pub radius: f32,
    pub padding_x: f32,
    pub padding_y: f32,
    pub text_size: f32,
    pub on_click: ComposerAction,
}

pub fn render_send_button(spec: SendButtonSpec) -> AnyElement {
    let SendButtonSpec {
        id,
        streaming,
        aria,
        tooltip,
        glyph,
        bg,
        fg,
        radius,
        padding_x,
        padding_y,
        text_size,
        on_click,
    } = spec;
    let _ = streaming;
    div()
        .id(id)
        .role(Role::Button)
        .aria_label(aria)
        .px(px(padding_x))
        .py(px(padding_y))
        .rounded(px(radius))
        .bg(bg)
        .text_color(fg)
        .text_size(px(text_size))
        .flex()
        .items_center()
        .justify_center()
        .child(glyph)
        .tooltip(move |window, cx| {
            gpui_kit::component::tooltip::Tooltip::new(tooltip.clone()).build(window, cx)
        })
        .on_click(move |_, window, cx| on_click(window, cx))
        .into_any_element()
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
            padding: 4.0,
            gap: 4.0,
        };
        let copied = style;
        assert_eq!(copied.radius, 6.0);
        assert_eq!(copied.padding, 4.0);
    }
}
