//! 双栈共用的消息行渲染（Stage 1d 起步）。
//!
//! 目前覆盖差异最小的两类行：assistant（标签可选 + Markdown + 操作栏 slot）与
//! thinking（折叠头 + Markdown 正文）。user/tool/permission 行的能力差异大，
//! 暂留各自视图，等能力位收敛后再抽。
//!
//! 两栈只提供数据、样式与回调，渲染/间距/id 规则在这里统一。

use gpui_kit::component::{Icon, Sizable};
use gpui_kit::InteractiveElement as _;
use gpui_kit::StatefulInteractiveElement as _;
use gpui_kit::*;

use crate::markdown_view::markdown_text_view;
use crate::message_actions::ActionCallback;

/// 消息行样式（各栈从自己的主题 palette 构造，`agent_ui` 不依赖 app 主题）。
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct MessageStyle {
    pub ink_2: Hsla,
    pub ink_3: Hsla,
    pub line: Hsla,
    pub radius: f32,
}

/// assistant 行：可选标签（ACP 展示 agent 名）+ Markdown + 操作栏 slot。
pub struct AssistantRowSpec {
    pub row_id: SharedString,
    pub markdown_id: SharedString,
    pub markdown: String,
    /// `Some(agent_label)` 时在正文上方渲染一行小标签（ACP 用；native 不展示）。
    pub label: Option<String>,
    pub style: MessageStyle,
    /// 由调用方用 `message_actions::render_action_bar` 构造，避免本模块感知 gating。
    pub actions: Option<AnyElement>,
}

pub fn render_assistant_row(spec: AssistantRowSpec) -> AnyElement {
    let AssistantRowSpec {
        row_id,
        markdown_id,
        markdown,
        label,
        style,
        actions,
    } = spec;
    let mut column = div().id(row_id).flex().flex_col().gap(px(2.0));
    if let Some(label) = label {
        column = column.child(
            div()
                .text_size(px(11.0))
                .text_color(style.ink_3)
                .child(label),
        );
    }
    column = column.child(markdown_text_view(markdown_id, &markdown));
    if let Some(actions) = actions {
        column = column.child(actions);
    }
    column.into_any_element()
}

/// thinking 行：折叠头（chevron + "Thinking"）+ 展开后的 Markdown 正文。
pub struct ThinkingRowSpec {
    pub row_id: SharedString,
    pub toggle_id: SharedString,
    pub markdown_id: SharedString,
    pub markdown: String,
    pub expanded: bool,
    pub style: MessageStyle,
    pub on_toggle: ActionCallback,
}

pub fn render_thinking_row(spec: ThinkingRowSpec) -> AnyElement {
    let ThinkingRowSpec {
        row_id,
        toggle_id,
        markdown_id,
        markdown,
        expanded,
        style,
        on_toggle,
    } = spec;
    let chevron = if expanded {
        gpui_kit::assets::IconName::ChevronDown
    } else {
        gpui_kit::assets::IconName::ChevronRight
    };
    let mut column = div().id(row_id).flex().flex_col().gap(px(2.0)).child(
        div()
            .id(toggle_id)
            .flex()
            .flex_row()
            .items_center()
            .gap(px(3.0))
            .text_size(px(11.0))
            .text_color(style.ink_3)
            .hover(|hovered| hovered.text_color(style.ink_2))
            .child(Icon::new(chevron).small())
            .child("Thinking")
            .on_click(move |_, _, cx| on_toggle(cx)),
    );
    if expanded {
        column = column.child(
            div()
                .pl(px(8.0))
                .border_l_1()
                .border_color(style.line)
                .text_size(px(12.0))
                .text_color(style.ink_2)
                .child(markdown_text_view(markdown_id, &markdown)),
        );
    }
    column.into_any_element()
}

#[cfg(test)]
mod tests {
    // 渲染是纯 GPUI 组合，行为断言在 message_flow / message_actions；这里只钉住
    // 样式结构可复制（Clone/Copy）与常量不漂移。
    use super::MessageStyle;
    use gpui_kit::Hsla;

    #[test]
    fn message_style_is_copy() {
        let style = MessageStyle {
            ink_2: Hsla::default(),
            ink_3: Hsla::default(),
            line: Hsla::default(),
            radius: 6.0,
        };
        let copied = style;
        assert_eq!(copied.radius, 6.0);
    }
}
