//! Native 与 ACP 共用的 active tab 上下文 chip。

use gpui_kit::InteractiveElement as _;
use gpui_kit::*;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ContextChipStyle {
    pub background: Hsla,
    pub foreground: Hsla,
    pub hover: Hsla,
    pub radius: f32,
    pub text_size: f32,
    pub gap: f32,
    pub padding_x: f32,
    pub padding_y: f32,
}

pub struct ContextChipSpec {
    pub id: SharedString,
    pub dismiss_id: SharedString,
    pub title: String,
    pub state_label: String,
    pub style: ContextChipStyle,
    pub on_dismiss: crate::composer::ComposerAction,
}

pub fn context_chip_label(title: &str, state_label: &str) -> String {
    format!("上下文：{title} · {state_label}")
}

pub fn render_context_chip(spec: ContextChipSpec) -> AnyElement {
    let ContextChipSpec {
        id,
        dismiss_id,
        title,
        state_label,
        style,
        on_dismiss,
    } = spec;
    div()
        .id(id)
        .flex()
        .flex_row()
        .items_center()
        .gap(px(style.gap))
        .px(px(style.padding_x))
        .py(px(style.padding_y))
        .rounded(px(style.radius))
        .bg(style.background)
        .text_size(px(style.text_size))
        .text_color(style.foreground)
        .child(context_chip_label(&title, &state_label))
        .child(
            div()
                .id(dismiss_id)
                .role(Role::Button)
                .aria_label("移除当前页面上下文")
                .px(px(4.0))
                .rounded(px(style.radius))
                .hover(|hover_style| hover_style.bg(style.hover))
                .tooltip(|window, cx| {
                    gpui_kit::component::tooltip::Tooltip::new(
                        "停止后续自动附加，不会清除已发送内容",
                    )
                    .build(window, cx)
                })
                .child("×")
                .on_click(move |_, window, cx| on_dismiss(window, cx)),
        )
        .into_any_element()
}

#[cfg(test)]
mod tests {
    #[test]
    fn chip_label_names_page_and_load_state() {
        assert_eq!(
            super::context_chip_label("Reading Rust", "已在上下文中"),
            "上下文：Reading Rust · 已在上下文中"
        );
    }
}
