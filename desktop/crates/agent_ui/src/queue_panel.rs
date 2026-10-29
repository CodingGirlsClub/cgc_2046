//! 排队消息面板（B4b-b'2：从 native 视图抽出的共享渲染）。

use gpui_kit::*;

use crate::message_actions::ActionCallback;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct QueuePanelStyle {
    pub line: Hsla,
    pub view: Hsla,
    pub ink_2: Hsla,
    pub ink_3: Hsla,
    pub soft: Hsla,
    pub radius: f32,
}

pub struct QueuePanelItem {
    pub preview: String,
    pub remove_id: SharedString,
    pub on_remove: ActionCallback,
}

pub struct QueuePanelSpec {
    pub row_id: SharedString,
    pub header: String,
    pub items: Vec<QueuePanelItem>,
    pub style: QueuePanelStyle,
}

/// 排队消息预览截断（纯函数，可单测）。
pub fn queue_preview(text: &str, max_chars: usize) -> String {
    text.chars().take(max_chars).collect()
}

pub fn render_queue_panel(spec: QueuePanelSpec) -> AnyElement {
    let QueuePanelSpec {
        row_id,
        header,
        items,
        style,
    } = spec;
    div()
        .id(row_id)
        .flex()
        .flex_col()
        .gap(px(2.0))
        .mx(px(8.0))
        .mb(px(4.0))
        .p(px(8.0))
        .rounded(px(style.radius))
        .border_1()
        .border_color(style.line)
        .bg(style.view)
        .child(
            div()
                .text_size(px(10.0))
                .text_color(style.ink_3)
                .child(header),
        )
        .children(items.into_iter().map(|item| {
            div()
                .flex()
                .flex_row()
                .items_center()
                .gap(px(4.0))
                .child(
                    div()
                        .flex_1()
                        .text_size(px(11.0))
                        .text_color(style.ink_2)
                        .child(item.preview),
                )
                .child(
                    div()
                        .id(item.remove_id)
                        .role(Role::Button)
                        .aria_label("取消排队消息")
                        .px(px(4.0))
                        .rounded(px(style.radius))
                        .text_size(px(11.0))
                        .text_color(style.ink_3)
                        .hover(|hovered| hovered.bg(style.soft))
                        .child("×")
                        .on_click(move |_, _, cx| (item.on_remove)(cx)),
                )
        }))
        .into_any_element()
}

#[cfg(test)]
mod tests {
    use super::queue_preview;

    #[test]
    fn preview_truncates_without_panic_on_multibyte() {
        assert_eq!(queue_preview("abcdef", 3), "abc");
        assert_eq!(queue_preview("中文消息", 2), "中文");
        assert_eq!(queue_preview("", 10), "");
    }
}
