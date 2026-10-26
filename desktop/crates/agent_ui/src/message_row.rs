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
    use super::{user_row_action_visibility, MessageStyle};
    use gpui_kit::Hsla;

    #[test]
    fn user_row_action_visibility_gates_on_busy_editing_and_checkpoint() {
        assert_eq!(user_row_action_visibility(false, false, true), (true, true));
        assert_eq!(
            user_row_action_visibility(false, false, false),
            (true, false)
        );
        assert_eq!(
            user_row_action_visibility(true, false, true),
            (false, false)
        );
        assert_eq!(
            user_row_action_visibility(false, true, true),
            (false, false)
        );
    }

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

/// 行样式调色板（native/ACP 各自从主题构造；共享层不依赖 app theme）。
#[derive(Clone, Debug, PartialEq)]
pub struct RowPalette {
    pub ink: Hsla,
    pub ink_2: Hsla,
    pub ink_3: Hsla,
    pub line: Hsla,
    pub view: Hsla,
    pub card: Hsla,
    pub canvas: Hsla,
    pub accent: Hsla,
    pub danger: Hsla,
    pub line_strong: Hsla,
    pub soft: Hsla,
    pub radius: f32,
    /// tool 卡/重试按钮延续原来的 RADIUS_SMALL。
    pub radius_small: f32,
    pub mono_font: SharedString,
}

/// 工具调用行（展开/收起 + 参数/输出）。
pub struct ToolRowSpec {
    pub row_id: SharedString,
    pub header_id: SharedString,
    pub name: String,
    pub status_label: String,
    pub glyph: &'static str,
    pub status_color: Hsla,
    pub args: Option<String>,
    pub output: Option<String>,
    pub expanded: bool,
    pub style: RowPalette,
    pub on_toggle: ActionCallback,
}

pub fn render_tool_row(spec: ToolRowSpec) -> AnyElement {
    let ToolRowSpec {
        row_id,
        header_id,
        name,
        status_label,
        glyph,
        status_color,
        args,
        output,
        expanded,
        style,
        on_toggle,
    } = spec;
    let body = expanded.then(|| {
        div()
            .flex()
            .flex_col()
            .gap(px(2.0))
            .px(px(8.0))
            .pb(px(4.0))
            .children(args.map(|args| {
                div()
                    .text_size(px(11.0))
                    .text_color(style.ink)
                    .child(format!("参数\n{args}"))
            }))
            .children(output.map(|output| {
                div()
                    .text_size(px(11.0))
                    .text_color(style.ink)
                    .child(format!("输出\n{output}"))
            }))
    });
    div()
        .id(row_id)
        .flex()
        .flex_col()
        .gap(px(2.0))
        .rounded(px(style.radius_small))
        .border_1()
        .border_color(style.line)
        .bg(style.view)
        .child(
            div()
                .id(header_id)
                .flex()
                .flex_row()
                .items_center()
                .gap(px(4.0))
                .px(px(8.0))
                .py(px(3.0))
                .hover(|hovered| hovered.bg(style.soft))
                .child(
                    div()
                        .text_size(px(11.0))
                        .text_color(status_color)
                        .child(glyph),
                )
                .child(
                    div()
                        .font_family(style.mono_font.clone())
                        .text_size(px(11.0))
                        .text_color(style.ink_2)
                        .child(name),
                )
                .child(
                    div()
                        .text_size(px(10.0))
                        .text_color(style.ink_3)
                        .child(status_label),
                )
                .child(div().flex_1())
                .child(
                    div()
                        .text_size(px(10.0))
                        .text_color(style.ink_3)
                        .child(if expanded { "▾" } else { "▸" }),
                )
                .on_click(move |_, _, cx| on_toggle(cx)),
        )
        .children(body)
        .into_any_element()
}

/// status 行（System/Error/Notice 的标签 + 文本）。
pub struct StatusRowSpec {
    pub row_id: SharedString,
    pub label: Option<String>,
    pub label_color: Hsla,
    pub text: String,
    pub style: RowPalette,
}

pub fn render_status_row(spec: StatusRowSpec) -> AnyElement {
    let StatusRowSpec {
        row_id,
        label,
        label_color,
        text,
        style,
    } = spec;
    div()
        .id(row_id)
        .flex()
        .flex_col()
        .gap(px(2.0))
        .children(label.map(|label| {
            div()
                .text_size(px(11.0))
                .text_color(label_color)
                .child(label)
        }))
        .child(div().text_size(px(13.0)).text_color(style.ink).child(text))
        .into_any_element()
}

/// 失败行（错误文本 + 提示 + 重试按钮）。
pub struct ErrorRowSpec {
    pub row_id: SharedString,
    pub retry_id: SharedString,
    pub message: String,
    pub hint: Option<String>,
    pub can_retry: bool,
    pub style: RowPalette,
    pub on_retry: ActionCallback,
}

pub fn render_error_row(spec: ErrorRowSpec) -> AnyElement {
    let ErrorRowSpec {
        row_id,
        retry_id,
        message,
        hint,
        can_retry,
        style,
        on_retry,
    } = spec;
    div()
        .id(row_id)
        .flex()
        .flex_col()
        .gap(px(4.0))
        .p(px(8.0))
        .rounded(px(style.radius))
        .border_1()
        .border_color(style.danger)
        .bg(style.view)
        .child(
            div()
                .text_size(px(11.0))
                .text_color(style.danger)
                .child("请求失败"),
        )
        .child(
            div()
                .text_size(px(12.0))
                .text_color(style.ink)
                .child(message),
        )
        .children(hint.map(|hint| {
            div()
                .text_size(px(11.0))
                .text_color(style.ink_3)
                .child(hint)
        }))
        .children(can_retry.then(|| {
            div()
                .id(retry_id)
                .role(Role::Button)
                .aria_label("重试")
                .mt(px(2.0))
                .px(px(8.0))
                .py(px(3.0))
                .rounded(px(style.radius_small))
                .bg(style.accent)
                .text_color(style.canvas)
                .text_size(px(12.0))
                .hover(|hovered| hovered.opacity(0.9))
                .child("重试")
                .on_click(move |_, _, cx| on_retry(cx))
        }))
        .into_any_element()
}

/// 带 window 的行内动作回调（编辑消息需要 window 聚焦输入框）。
pub type WindowActionCallback = Box<dyn Fn(&mut Window, &mut App) + 'static>;

/// user 行 hover 动作显隐（纯函数，可单测）：(编辑, 恢复检查点)。
pub fn user_row_action_visibility(busy: bool, editing: bool, has_checkpoint: bool) -> (bool, bool) {
    let idle = !busy && !editing;
    (idle, idle && has_checkpoint)
}

/// user 行：卡片 + mention 正文 slot + hover「编辑」/「恢复检查点」。
pub struct UserRowSpec {
    pub row_id: gpui_kit::SharedString,
    pub card_id: gpui_kit::SharedString,
    pub edit_id: gpui_kit::SharedString,
    pub restore_id: gpui_kit::SharedString,
    pub hover_group: gpui_kit::SharedString,
    pub content: AnyElement,
    pub show_edit: bool,
    pub show_restore: bool,
    pub style: RowPalette,
    pub on_edit: WindowActionCallback,
    pub on_restore: WindowActionCallback,
}

pub fn render_user_row(spec: UserRowSpec) -> AnyElement {
    let UserRowSpec {
        row_id,
        card_id,
        edit_id,
        restore_id,
        hover_group,
        content,
        show_edit,
        show_restore,
        style,
        on_edit,
        on_restore,
    } = spec;
    div()
        .id(row_id)
        .flex()
        .flex_col()
        .gap(px(4.0))
        .child(
            div()
                .id(card_id)
                .group(hover_group.clone())
                .relative()
                .w_full()
                .px(px(8.0))
                .py(px(8.0))
                .rounded(px(style.radius))
                .border_1()
                .border_color(style.line)
                .bg(style.view)
                .hover(move |hovered| hovered.border_color(style.line_strong))
                .child(div().pr(px(28.0)).child(content))
                .children(show_edit.then(|| {
                    div()
                        .id(edit_id)
                        .role(Role::Button)
                        .aria_label("编辑消息")
                        .absolute()
                        .top(px(4.0))
                        .right(px(4.0))
                        .px(px(4.0))
                        .py(px(1.0))
                        .rounded(px(style.radius_small))
                        .bg(style.card)
                        .text_size(px(10.0))
                        .text_color(style.ink_3)
                        .invisible()
                        .group_hover(hover_group.clone(), |hidden| hidden.visible())
                        .hover(|hovered| hovered.bg(style.soft))
                        .child("编辑")
                        .on_click(move |_, window, cx| on_edit(window, cx))
                })),
        )
        .children(show_restore.then(|| {
            div()
                .id(restore_id)
                .role(Role::Button)
                .aria_label("恢复检查点")
                .flex()
                .flex_row()
                .items_center()
                .gap(px(3.0))
                .self_end()
                .text_size(px(10.0))
                .text_color(style.ink_3)
                .hover(|hovered| hovered.text_color(style.ink_2))
                .child("⟲ 恢复检查点")
                .on_click(move |_, window, cx| on_restore(window, cx))
        }))
        .into_any_element()
}
