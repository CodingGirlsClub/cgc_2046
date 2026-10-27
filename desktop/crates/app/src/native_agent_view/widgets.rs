//! 渲染小组件与样式适配（B4b 结构拆分第八片：从视图模块移出，行为不变）。
//!
//! 子模块可访问父模块私有字段。

use super::*;

/// 滚动是否已经在底部（GPUI 的 offset.y 越往下越负，max_offset 为正）。
/// 2px 容差避免亚像素/取整导致的“差一点点”抖动。
/// 用户消息正文：普通文本 + mention chip（与 composer 的 chip 对齐）。
pub(crate) fn render_user_message_body(text: &str, palette: &theme::Palette) -> AnyElement {
    let palette = *palette;
    let segments = mention::display_segments(text);
    div()
        .flex()
        .flex_row()
        .flex_wrap()
        .items_center()
        .gap(px(2.0))
        .children(segments.into_iter().enumerate().map(|(index, segment)| {
            match segment {
                mention::DisplaySegment::Text(text) => div()
                    .text_size(px(13.0))
                    .text_color(palette.ink)
                    .child(text)
                    .into_any_element(),
                mention::DisplaySegment::Mention {
                    label,
                    kind,
                    target,
                } => {
                    let icon = match kind {
                        mention::MentionKind::Skill => gpui_kit::assets::IconName::Sparkle,
                        mention::MentionKind::File => gpui_kit::assets::IconName::FileText,
                    };
                    let chip = div()
                        .flex()
                        .flex_row()
                        .items_center()
                        .gap(px(2.0))
                        .px(px(4.0))
                        .py(px(1.0))
                        .rounded(px(RADIUS_SMALL))
                        .border_1()
                        .border_color(palette.line)
                        .bg(palette.soft)
                        .child(Icon::new(icon).xsmall().text_color(palette.ink_3))
                        .child(
                            div()
                                .text_size(px(12.0))
                                .text_color(palette.ink_2)
                                .child(label),
                        );
                    HoverCard::new(SharedString::from(format!("native-mention-chip-{index}")))
                        .anchor(Anchor::TopCenter)
                        .open_delay(std::time::Duration::from_millis(200))
                        .trigger(chip)
                        .content(move |_, _, _| {
                            div()
                                .p(px(4.0))
                                .rounded(px(RADIUS_SMALL))
                                .border_1()
                                .border_color(palette.line)
                                .bg(palette.card)
                                .text_size(px(11.0))
                                .text_color(palette.ink_2)
                                .child(target.clone())
                                .into_any_element()
                        })
                        .into_any_element()
                }
            }
        }))
        .into_any_element()
}

pub(crate) fn tool_status_label(status: ViewToolStatus) -> &'static str {
    match status {
        ViewToolStatus::Running => "运行中…",
        ViewToolStatus::Ok => "完成",
        ViewToolStatus::Failed => "失败",
    }
}

/// 工具调用卡片：标题显示状态/名称，展开后展示 raw 参数与 raw 输出。
/// P8：工具卡状态 → (glyph, 文案)，纯函数可单测。
pub(crate) fn tool_row_status_parts(status: ViewToolStatus) -> (&'static str, &'static str) {
    match status {
        ViewToolStatus::Running => ("◐", tool_status_label(status)),
        ViewToolStatus::Ok => ("✓", tool_status_label(status)),
        ViewToolStatus::Failed => ("✗", tool_status_label(status)),
    }
}

pub(crate) fn render_tool_card(
    tool: &ViewTool,
    expanded: bool,
    palette: &theme::Palette,
    on_toggle: impl Fn(&mut App) + 'static,
) -> AnyElement {
    let (glyph, status_label) = tool_row_status_parts(tool.status);
    let args = if tool.args.is_null() || !expanded {
        None
    } else {
        Some(serde_json::to_string_pretty(&tool.args).unwrap_or_else(|_| tool.args.to_string()))
    };
    let content = tool.content.clone().unwrap_or_default();
    let output = expanded.then(|| {
        if content.is_empty() {
            if matches!(tool.status, ViewToolStatus::Running) {
                "（等待输出…）".to_string()
            } else {
                String::new()
            }
        } else {
            content
        }
    });
    let status_color = match tool.status {
        ViewToolStatus::Running => palette.accent,
        ViewToolStatus::Ok => palette.ink_3,
        ViewToolStatus::Failed => palette.danger,
    };
    render_tool_row(ToolRowSpec {
        row_id: SharedString::from("native-tool-card"),
        header_id: SharedString::from("native-tool-card-header"),
        name: tool.name.clone(),
        status_label: status_label.to_string(),
        glyph,
        status_color,
        args,
        output: output.filter(|text| !text.is_empty()),
        expanded,
        style: native_row_palette(palette),
        on_toggle: Box::new(move |cx: &mut App| on_toggle(cx)),
    })
}

/// B3c：native `SubagentCard` → 共享 `agent_ui::subagent_row` 的 adapter。
/// 只映射数据，不重排行顺序（顺序由 `message_row_kinds` 决定）。
pub(crate) fn render_subagent_row(card: &SubagentCard, palette: &theme::Palette) -> AnyElement {
    cgc_agent_ui::subagent_row::render_subagent_row(cgc_agent_ui::subagent_row::SubagentRowSpec {
        task: card.task.clone(),
        text: card.text.clone(),
        finished: card.finished,
        style: cgc_agent_ui::subagent_row::SubagentRowStyle {
            view: palette.view,
            ink_2: palette.ink_2,
            ink_3: palette.ink_3,
            radius: RADIUS_SMALL,
        },
    })
}

pub(crate) fn role_label(role: ViewRole) -> &'static str {
    match role {
        ViewRole::User => "you",
        ViewRole::Assistant => "agent",
        ViewRole::Thinking => "thinking",
        ViewRole::Tool => "tool",
        ViewRole::System => "system",
        ViewRole::Error => "error",
    }
}

/// 把 native 的本地 `ViewRow` 映射到共享消息流（`agent_ui::message_flow`）。
pub(crate) fn message_menu_payloads(
    role: ViewRole,
    text: &str,
    agent_response: Option<String>,
) -> MenuPayloads {
    let plain = match role {
        ViewRole::Assistant => markdown_to_plain(text),
        ViewRole::User => mention::display_text(text),
        _ => text.to_string(),
    };
    MenuPayloads {
        plain,
        markdown: text.to_string(),
        agent_response,
    }
}

/// native 主题 → 共享消息行样式。
pub(crate) fn native_composer_style(
    palette: theme::Palette,
) -> cgc_agent_ui::composer::ComposerStyle {
    cgc_agent_ui::composer::ComposerStyle {
        view: palette.view,
        line: palette.line,
        accent: palette.accent,
        danger: palette.danger,
        canvas: palette.canvas,
        radius: RADIUS_MEDIUM,
        padding: 4.0,
        gap: 1.0,
    }
}

/// P8：native 主题 → 共享 message_row 的行调色板（共享层不依赖 app theme）。
pub(crate) fn native_row_palette(palette: &theme::Palette) -> RowPalette {
    RowPalette {
        ink: palette.ink,
        ink_2: palette.ink_2,
        ink_3: palette.ink_3,
        line: palette.line,
        line_strong: palette.line_strong,
        view: palette.view,
        card: palette.card,
        canvas: palette.canvas,
        accent: palette.accent,
        danger: palette.danger,
        soft: palette.soft,
        radius: RADIUS_MEDIUM,
        radius_small: RADIUS_SMALL,
        mono_font: theme::FONT_MONO.into(),
    }
}

pub(crate) fn native_message_style(palette: theme::Palette) -> MessageStyle {
    MessageStyle {
        ink_2: palette.ink_2,
        ink_3: palette.ink_3,
        line: palette.line,
        radius: RADIUS_MEDIUM,
    }
}

/// native 主题 → 共享 picker 样式。
pub(crate) fn native_picker_style(palette: theme::Palette) -> PickerStyle {
    PickerStyle {
        accent: palette.accent,
        ink_2: palette.ink_2,
        ink_3: palette.ink_3,
        soft: palette.soft,
        card: palette.card,
        radius: RADIUS_MEDIUM,
    }
}

/// native 主题 → 共享 slash 菜单样式（选中 = soft 背景 + accent 文本）。
pub(crate) fn native_command_menu_style(palette: theme::Palette) -> CommandMenuStyle {
    CommandMenuStyle {
        card: palette.card,
        line: palette.line,
        soft: palette.soft,
        accent: palette.accent,
        canvas: palette.canvas,
        ink: palette.ink,
        ink_2: palette.ink_2,
        ink_3: palette.ink_3,
        selected_bg: palette.soft,
        selected_text: palette.accent,
        radius: RADIUS_SMALL,
        padding: 0.0,
    }
}

/// P9：native → 共享 `message_actions::ActionBarSpec` 的 id 组装（纯函数，可单测）。
pub(crate) fn native_action_bar_ids(
    prefix: &str,
) -> (SharedString, SharedString, SharedString, SharedString) {
    (
        SharedString::from(format!("{prefix}-row")),
        SharedString::from(format!("{prefix}-copy")),
        SharedString::from(format!("{prefix}-user")),
        SharedString::from(format!("{prefix}-top")),
    )
}

/// P9：native → 共享 action bar spec（纯组装；回调由调用方注入）。
pub(crate) fn native_action_bar_spec(
    prefix: &str,
    style: ActionStyle,
    glyphs: ActionGlyphs,
    callbacks: ActionCallbacks,
) -> ActionBarSpec {
    let (row_id, copy_id, user_id, top_id) = native_action_bar_ids(prefix);
    ActionBarSpec {
        row_id,
        copy_id,
        user_id,
        top_id,
        glyphs,
        style,
        callbacks,
    }
}

pub(crate) fn native_action_glyphs() -> ActionGlyphs {
    ActionGlyphs {
        copy: ActionGlyph::Named(gpui_kit::assets::IconName::Copy),
        user: ActionGlyph::Named(gpui_kit::assets::IconName::User),
        top: ActionGlyph::Named(gpui_kit::assets::IconName::ArrowUp),
    }
}

pub(crate) fn native_action_style(palette: theme::Palette) -> ActionStyle {
    ActionStyle {
        icon_color: palette.ink_3,
        hover_bg: palette.soft,
        button_size: 22.0,
        radius: RADIUS_SMALL,
        gap: 4.0,
    }
}

/// native 的消息右键菜单：滚动回调注入到共享菜单渲染。
pub(crate) fn render_native_message_menu(
    menu: PopupMenu,
    view: WeakEntity<NativeAgentView>,
    payloads: Arc<MenuPayloads>,
) -> PopupMenu {
    let top_view = view.clone();
    let bottom_view = view;
    render_message_menu(
        menu,
        (*payloads).clone(),
        Box::new(move |cx| {
            let _ = top_view.update(cx, |this, cx| this.scroll_messages_to_top(cx));
        }),
        Box::new(move |cx| {
            let _ = bottom_view.update(cx, |this, cx| this.scroll_messages_to_bottom(cx));
        }),
    )
}
