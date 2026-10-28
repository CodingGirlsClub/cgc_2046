//! 双栈共用的消息行渲染（Stage 1d 起步）。
//!
//! 目前覆盖差异最小的两类行：assistant（标签可选 + Markdown + 操作栏 slot）与
//! thinking（折叠头 + Markdown 正文）。user/tool/permission 行的能力差异大，
//! 暂留各自视图，等能力位收敛后再抽。
//!
//! 两栈只提供数据、样式与回调，渲染/间距/id 规则在这里统一。

use std::rc::Rc;

use gpui_kit::component::input::{Textarea, TextareaState};
use gpui_kit::component::tooltip::Tooltip;
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
    pub restore_id: gpui_kit::SharedString,
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
        restore_id,
        content,
        show_edit,
        show_restore,
        style,
        on_edit,
        on_restore,
    } = spec;
    let on_edit = Rc::new(on_edit);
    let content_edit = on_edit.clone();
    let mut content_wrapper = div()
        .id(SharedString::from(format!("{card_id}-content")))
        .w_full()
        .pr(px(28.0))
        .child(content);
    if show_edit {
        // 对齐 Zed：点消息气泡本身即可进入行内编辑，不要求先点右上角按钮。
        content_wrapper = content_wrapper.on_click(move |_, window, cx| content_edit(window, cx));
    }
    div()
        .id(row_id)
        .flex()
        .flex_col()
        .gap(px(4.0))
        .child(
            div()
                .id(card_id)
                .relative()
                .w_full()
                .px(px(8.0))
                .py(px(8.0))
                .rounded(px(style.radius))
                .border_1()
                .border_color(style.line)
                .bg(style.view)
                .hover(move |hovered| hovered.border_color(style.line_strong))
                .child(content_wrapper),
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

/// 编辑态行（user 消息编辑/重发）。
pub struct UserEditRowSpec {
    pub input: Entity<TextareaState>,
    pub cancel_id: SharedString,
    pub resend_id: SharedString,
    pub confirm_cancel_id: SharedString,
    pub confirm_resend_id: SharedString,
    pub pending_confirm: bool,
    pub style: RowPalette,
    pub on_cancel: ActionCallback,
    pub on_resend: ActionCallback,
    pub on_confirm_cancel: ActionCallback,
    pub on_confirm_resend: ActionCallback,
}

/// 编辑态行：输入框 + 取消/重发；无检查点时二次确认面板（纯函数可单测）。
pub fn user_edit_confirm_visible(
    pending_confirm_for_message: Option<usize>,
    message_index: usize,
) -> bool {
    pending_confirm_for_message == Some(message_index)
}

pub fn render_user_edit_row(spec: UserEditRowSpec) -> AnyElement {
    let UserEditRowSpec {
        input,
        cancel_id,
        resend_id,
        confirm_cancel_id,
        confirm_resend_id,
        pending_confirm,
        style,
        on_cancel,
        on_resend,
        on_confirm_cancel,
        on_confirm_resend,
    } = spec;
    let on_cancel = Rc::new(on_cancel);
    let on_resend = Rc::new(on_resend);
    let cancel = on_cancel.clone();
    let cancel_key = on_cancel.clone();
    let resend = on_resend.clone();
    div()
        .flex()
        .flex_col()
        .gap(px(4.0))
        .child(
            div()
                .relative()
                .w_full()
                .rounded(px(style.radius))
                .border_1()
                .border_color(style.line_strong)
                .bg(style.view)
                .px(px(8.0))
                .py(px(6.0))
                .on_key_down(move |event: &KeyDownEvent, _, cx| {
                    if event.keystroke.key == "escape" {
                        cancel_key(cx);
                        cx.stop_propagation();
                    }
                })
                .child(
                    div().pr(px(40.0)).child(
                        Textarea::new(&input)
                            .appearance(false)
                            .bordered(false)
                            .w_full(),
                    ),
                )
                .child(
                    // 对齐 Zed：编辑态右上角悬浮 X（取消）/ ↵（重发）。
                    div()
                        .absolute()
                        .top(px(2.0))
                        .right(px(4.0))
                        .flex()
                        .flex_row()
                        .items_center()
                        .gap(px(2.0))
                        .px(px(2.0))
                        .py(px(1.0))
                        .rounded(px(6.0))
                        .border_1()
                        .border_color(style.line)
                        .bg(style.card)
                        .child(
                            div()
                                .id(cancel_id)
                                .role(Role::Button)
                                .aria_label("取消编辑")
                                .flex()
                                .items_center()
                                .justify_center()
                                .size(px(16.0))
                                .rounded(px(4.0))
                                .text_color(style.danger)
                                .hover(|hovered| hovered.bg(style.soft))
                                .tooltip(|window, cx| {
                                    Tooltip::new("取消编辑（Esc）").build(window, cx)
                                })
                                .child(Icon::new(gpui_kit::assets::IconName::X).xsmall())
                                .on_click(move |_, _, cx| cancel(cx)),
                        )
                        .child(
                            div()
                                .id(resend_id)
                                .role(Role::Button)
                                .aria_label("从这里重发")
                                .flex()
                                .items_center()
                                .justify_center()
                                .size(px(16.0))
                                .rounded(px(4.0))
                                .text_color(style.accent)
                                .hover(|hovered| hovered.bg(style.soft))
                                .tooltip(|window, cx| {
                                    Tooltip::new("从这里重发（Enter）").build(window, cx)
                                })
                                .child(
                                    Icon::new(gpui_kit::assets::IconName::CornerDownLeft).xsmall(),
                                )
                                .on_click(move |_, _, cx| resend(cx)),
                        ),
                ),
        )
        .children(pending_confirm.then(|| {
            div()
                .flex()
                .flex_col()
                .gap(px(4.0))
                .p(px(8.0))
                .rounded(px(style.radius_small))
                .border_1()
                .border_color(style.danger)
                .bg(style.view)
                .child(
                    div()
                        .text_size(px(11.0))
                        .text_color(style.danger)
                        .child("没有可用检查点"),
                )
                .child(
                    div()
                        .text_size(px(11.0))
                        .text_color(style.ink_2)
                        .child("继续只会回滚对话，无法回滚工作区文件。"),
                )
                .child(
                    div()
                        .flex()
                        .flex_row()
                        .justify_end()
                        .gap(px(4.0))
                        .child(
                            div()
                                .id(confirm_cancel_id)
                                .role(Role::Button)
                                .aria_label("取消重发")
                                .px(px(4.0))
                                .py(px(2.0))
                                .rounded(px(style.radius_small))
                                .text_size(px(11.0))
                                .text_color(style.ink_2)
                                .hover(|hovered| hovered.bg(style.soft))
                                .child("取消")
                                .on_click(move |_, _, cx| on_confirm_cancel(cx)),
                        )
                        .child(
                            div()
                                .id(confirm_resend_id)
                                .role(Role::Button)
                                .aria_label("仍然重发")
                                .px(px(8.0))
                                .py(px(2.0))
                                .rounded(px(style.radius_small))
                                .bg(style.danger)
                                .text_color(style.canvas)
                                .text_size(px(11.0))
                                .child("仍然重发")
                                .on_click(move |_, _, cx| on_confirm_resend(cx)),
                        ),
                )
        }))
        .into_any_element()
}

#[cfg(test)]
mod user_edit_tests {
    use super::user_edit_confirm_visible;

    #[test]
    fn confirm_panel_only_for_matching_message() {
        assert!(user_edit_confirm_visible(Some(3), 3));
        assert!(!user_edit_confirm_visible(Some(3), 4));
        assert!(!user_edit_confirm_visible(None, 4));
    }
}
