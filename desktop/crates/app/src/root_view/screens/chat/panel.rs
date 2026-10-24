use super::super::super::*;
use super::super::ScreenContext;
use cgc_platform::acp::connection::ConfigOptionCategory;
use gpui_kit::component::button::{Button, ButtonVariants};
use gpui_kit::component::input::{Input, Textarea};
use gpui_kit::component::popover::Popover;
use gpui_kit::component::scroll::ScrollableElement as _;

pub(in crate::root_view) fn render_chat_panel(
    ctx: &mut ScreenContext<'_>,
    language: Language,
    palette: &theme::Palette,
    cx: &mut Context<RootView>,
) -> AnyElement {
    let phase = ctx.chat.phase.clone();
    let messages = ctx.chat.messages.clone();
    let input = ctx.chat.input.clone();
    let agent_label = if ctx.chat.agent.trim().is_empty() {
        ctx.chat
            .selected_agent
            .clone()
            .unwrap_or_else(|| "Agent".to_string())
    } else {
        ctx.chat.agent.clone()
    };
    if !ctx.native_chat_mode && matches!(phase, ChatPhase::Idle) && !ctx.chat.auto_start_queued {
        ctx.chat.auto_start_queued = true;
        let root = cx.entity().downgrade();
        cx.defer(move |cx| {
            let _ = root.update(cx, |this, cx| this.start_chat(cx));
        });
    }
    let body: AnyElement = match &phase {
        ChatPhase::Idle => div()
            .flex()
            .flex_row()
            .items_center()
            .gap(space(2))
            .child(
                div()
                    .text_size(px(12.0))
                    .text_color(palette.ink_3)
                    .child(translate(language, Key::AgentChatChatStarting)),
            )
            .into_any_element(),
        ChatPhase::Starting => div()
            .text_size(px(12.0))
            .text_color(palette.ink_3)
            .child(translate(language, Key::AgentChatChatStarting))
            .into_any_element(),
        ChatPhase::Failed(message) => {
            let guidance = ctx.chat.guidance.clone().map(|guidance| {
                let detected_rows = guidance
                    .detected
                    .iter()
                    .map(|(name, status)| {
                        div()
                            .text_size(px(11.0))
                            .text_color(palette.ink_2)
                            .child(format!("{name}：{status}"))
                            .into_any_element()
                    })
                    .collect::<Vec<_>>();
                let node_ready = guidance
                    .node_found
                    .as_deref()
                    .is_some_and(version_at_least_24);
                let install = (!node_ready).then(|| {
                    div()
                        .id("chat-install-node")
                        .px(space(2))
                        .py(px(4.0))
                        .rounded(px(RADIUS_MEDIUM))
                        .bg(palette.accent)
                        .text_color(palette.canvas)
                        .child(translate(language, Key::AgentChatChatInstallNode))
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.install_node_runtime(cx);
                        }))
                        .into_any_element()
                });
                div()
                    .flex()
                    .flex_col()
                    .gap(space(1))
                    .child(
                        div()
                            .text_size(px(12.0))
                            .text_color(palette.ink_2)
                            .child(translate(language, Key::AgentChatChatAgentGuidance)),
                    )
                    .children(detected_rows)
                    .child(
                        div()
                            .text_size(px(11.0))
                            .text_color(palette.ink_3)
                            .child(format!(
                                "Node runtime: {} (required 24.x)",
                                guidance
                                    .node_found
                                    .clone()
                                    .unwrap_or_else(|| "missing".to_string())
                            )),
                    )
                    .children(install)
                    .child(
                        div()
                            .text_size(px(11.0))
                            .text_color(palette.ink_3)
                            .child(translate(language, Key::AgentChatChatLoginHint)),
                    )
                    .into_any_element()
            });
            div()
                .flex()
                .flex_col()
                .gap(space(1))
                .child(
                    div()
                        .text_size(px(12.0))
                        .text_color(palette.danger)
                        .child(format!(
                            "{}：{message}",
                            translate(language, Key::AgentChatChatFailed)
                        )),
                )
                .children(guidance)
                .children(message.contains("mcp_token_limit_reached").then(|| {
                    div()
                        .id("chat-revoke-old-tokens")
                        .px(space(2))
                        .py(px(4.0))
                        .rounded(px(RADIUS_MEDIUM))
                        .bg(palette.accent)
                        .text_color(palette.canvas)
                        .text_size(px(11.0))
                        .child("撤销旧学习凭证并重试")
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.revoke_stale_learning_tokens(cx);
                        }))
                }))
                .child(
                    div()
                        .id("chat-retry")
                        .role(Role::Button)
                        .aria_label(translate(language, Key::AgentChatChatRetry))
                        .role(Role::Button)
                        .aria_label(translate(language, Key::AgentChatChatRetry))
                        .role(Role::Button)
                        .aria_label(translate(language, Key::AgentChatChatRetry))
                        .px(space(2))
                        .py(px(5.0))
                        .rounded(px(RADIUS_MEDIUM))
                        .bg(palette.accent)
                        .text_color(palette.canvas)
                        .child(translate(language, Key::AgentChatChatRetry))
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.chat.phase = ChatPhase::Idle;
                            this.start_chat(cx);
                        })),
                )
                .into_any_element()
        }
        ChatPhase::Ready | ChatPhase::Streaming => {
            let last_assistant = messages
                .iter()
                .rposition(|entry| matches!(entry, ChatEntry::Assistant(_)));
            let mut rows = Vec::with_capacity(messages.len());
            for (index, entry) in messages.iter().enumerate() {
                let row = match entry {
                    ChatEntry::User(text) => div()
                        .id(SharedString::from(format!("chat-user-{index}")))
                        .flex()
                        .flex_col()
                        .gap(px(2.0))
                        .p(space(2))
                        .rounded(px(RADIUS_MEDIUM))
                        .border_1()
                        .border_color(palette.line)
                        .bg(palette.soft)
                        .child(
                            div()
                                .text_size(px(10.0))
                                .text_color(palette.ink_3)
                                .child("你"),
                        )
                        .child(
                            div()
                                .text_size(px(13.0))
                                .text_color(palette.ink)
                                .child(text.clone()),
                        )
                        .into_any_element(),
                    ChatEntry::Assistant(text) => div()
                        .id(SharedString::from(format!("chat-assistant-{index}")))
                        .flex()
                        .flex_col()
                        .gap(px(2.0))
                        .child(
                            div()
                                .text_size(px(11.0))
                                .text_color(palette.ink_3)
                                .child(agent_label.clone()),
                        )
                        .child(
                            TextView::markdown(
                                format!("chat-markdown-{index}"),
                                sanitize_markdown(text),
                            )
                            .into_any_element(),
                        )
                        .into_any_element(),
                    ChatEntry::Thinking { text, expanded } => {
                        let expanded = *expanded;
                        div()
                            .id(SharedString::from(format!("chat-thinking-{index}")))
                            .flex()
                            .flex_col()
                            .gap(px(2.0))
                            .child(
                                div()
                                    .id(SharedString::from(format!("chat-thinking-toggle-{index}")))
                                    .flex()
                                    .flex_row()
                                    .items_center()
                                    .gap(px(4.0))
                                    .text_size(px(11.0))
                                    .text_color(palette.ink_3)
                                    .child(
                                        Icon::default()
                                            .path(if expanded {
                                                AssetIcon::ChevronDown.path()
                                            } else {
                                                AssetIcon::ChevronRight.path()
                                            })
                                            .small(),
                                    )
                                    .child("Thinking")
                                    .on_click(cx.listener(move |this, _, _, cx| {
                                        this.toggle_chat_thinking(index, cx);
                                    })),
                            )
                            .children(expanded.then(|| {
                                div()
                                    .pl(space(2))
                                    .border_l_1()
                                    .border_color(palette.line)
                                    .text_size(px(12.0))
                                    .text_color(palette.ink_2)
                                    .child(TextView::markdown(
                                        format!("chat-thinking-markdown-{index}"),
                                        sanitize_markdown(text),
                                    ))
                                    .into_any_element()
                            }))
                            .into_any_element()
                    }
                    ChatEntry::Tool { title, kind } => div()
                        .flex()
                        .flex_row()
                        .items_center()
                        .gap(space(1))
                        .px(space(1))
                        .py(px(3.0))
                        .rounded(px(RADIUS_SMALL))
                        .border_1()
                        .border_color(palette.line)
                        .text_size(px(12.0))
                        .text_color(palette.ink_2)
                        .child("🔧")
                        .child(title.clone())
                        .child(
                            div()
                                .text_size(px(10.0))
                                .text_color(palette.ink_3)
                                .child(kind.clone()),
                        )
                        .into_any_element(),
                    ChatEntry::Permission {
                        request_id,
                        title,
                        resolved,
                    } => {
                        let status = match resolved {
                            Some(true) => "已允许",
                            Some(false) => "已拒绝",
                            None => "等待你的决定",
                        };
                        let buttons: Vec<AnyElement> = if resolved.is_none() {
                            vec![
                                div()
                                    .id(format!("perm-allow-{request_id}"))
                                    .role(Role::Button)
                                    .aria_label("允许")
                                    .px(space(1))
                                    .py(px(3.0))
                                    .rounded(px(RADIUS_SMALL))
                                    .bg(palette.accent)
                                    .text_color(palette.canvas)
                                    .child("允许")
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.respond_chat_permission(true, cx);
                                    }))
                                    .into_any_element(),
                                div()
                                    .id(format!("perm-deny-{request_id}"))
                                    .role(Role::Button)
                                    .aria_label("拒绝")
                                    .px(space(1))
                                    .py(px(3.0))
                                    .rounded(px(RADIUS_SMALL))
                                    .bg(palette.soft)
                                    .text_color(palette.ink_2)
                                    .child("拒绝")
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.respond_chat_permission(false, cx);
                                    }))
                                    .into_any_element(),
                            ]
                        } else {
                            Vec::new()
                        };
                        div()
                            .flex()
                            .flex_col()
                            .gap(space(1))
                            .p(space(1))
                            .rounded(px(RADIUS_SMALL))
                            .border_1()
                            .border_color(palette.line_strong)
                            .text_size(px(12.0))
                            .text_color(palette.ink)
                            .child(format!("需要你的同意 · {title}"))
                            .child(
                                div()
                                    .text_size(px(10.0))
                                    .text_color(palette.ink_3)
                                    .child(status),
                            )
                            .child(
                                div()
                                    .text_size(px(10.0))
                                    .text_color(palette.ink_3)
                                    .child("Ctrl+Shift+Y 允许 · Ctrl+Shift+N 拒绝"),
                            )
                            .children(buttons)
                            .into_any_element()
                    }
                };
                rows.push(row);
                if phase == ChatPhase::Ready && Some(index) == last_assistant {
                    rows.push(
                        div()
                            .id(SharedString::from(format!("chat-controls-{index}")))
                            .flex()
                            .flex_row()
                            .items_center()
                            .justify_end()
                            .gap(px(2.0))
                            .pr(space(1))
                            .opacity(0.4)
                            .hover(|style| style.opacity(1.0))
                            .child(
                                div()
                                    .id(SharedString::from(format!("chat-copy-{index}")))
                                    .role(Role::Button)
                                    .aria_label("Copy This Agent Response")
                                    .size(px(22.0))
                                    .rounded(px(RADIUS_SMALL))
                                    .flex()
                                    .items_center()
                                    .justify_center()
                                    .hover(|style| style.bg(palette.soft))
                                    .child(Icon::default().path(AssetIcon::Copy.path()).small())
                                    .tooltip(|window, cx| {
                                        Tooltip::new("Copy This Agent Response").build(window, cx)
                                    })
                                    .on_click(cx.listener(move |this, _, _, cx| {
                                        this.copy_chat_response(index, cx);
                                    })),
                            )
                            .child(
                                div()
                                    .id(SharedString::from(format!("chat-scroll-user-{index}")))
                                    .role(Role::Button)
                                    .aria_label("Scroll to User Message")
                                    .size(px(22.0))
                                    .rounded(px(RADIUS_SMALL))
                                    .flex()
                                    .items_center()
                                    .justify_center()
                                    .hover(|style| style.bg(palette.soft))
                                    .child(
                                        Icon::default()
                                            .path(AssetIcon::UserRoundArrowLeft.path())
                                            .small(),
                                    )
                                    .tooltip(|window, cx| {
                                        Tooltip::new("Scroll to User Message").build(window, cx)
                                    })
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.scroll_chat_to_last_user(cx);
                                    })),
                            )
                            .child(
                                div()
                                    .id(SharedString::from(format!("chat-scroll-top-{index}")))
                                    .role(Role::Button)
                                    .aria_label("Scroll to Top")
                                    .size(px(22.0))
                                    .rounded(px(RADIUS_SMALL))
                                    .flex()
                                    .items_center()
                                    .justify_center()
                                    .hover(|style| style.bg(palette.soft))
                                    .child(Icon::default().path(AssetIcon::ArrowUp.path()).small())
                                    .tooltip(|window, cx| {
                                        Tooltip::new("Scroll to Top").build(window, cx)
                                    })
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.scroll_chat_to_top(cx);
                                    })),
                            )
                            .into_any_element(),
                    );
                }
            }
            let streaming = phase == ChatPhase::Streaming;
            let status = if streaming {
                translate(language, Key::AgentChatChatThinking).to_string()
            } else {
                String::new()
            };
            div()
                .flex_1()
                .min_h(px(0.0))
                .flex()
                .flex_col()
                .gap(space(2))
                .child(
                    div()
                        .id("chat-messages")
                        .flex_1()
                        .min_h(px(120.0))
                        .overflow_y_scroll()
                        .flex()
                        .flex_col()
                        .gap(space(2))
                        .children(rows),
                )
                .children((!status.is_empty()).then(|| {
                    div()
                        .text_size(px(11.0))
                        .text_color(palette.ink_3)
                        .child(status)
                        .into_any_element()
                }))
                .child({
                    let slash_candidates = slash_candidates(&ctx.chat.commands, &input);
                    let selected_slash = ctx
                        .chat
                        .slash_selection
                        .min(slash_candidates.len().saturating_sub(1));
                    let slash_rows = (slash_query(&input).is_some()
                        && !ctx.chat.slash_dismissed
                        && !slash_candidates.is_empty())
                    .then(|| {
                        let mut rows: Vec<AnyElement> = Vec::new();
                        let mut last_group = None;
                        for (index, candidate) in slash_candidates.iter().enumerate() {
                            if last_group != Some(candidate.group) {
                                last_group = Some(candidate.group);
                                rows.push(
                                    div()
                                        .px(space(1))
                                        .pt(px(4.0))
                                        .pb(px(2.0))
                                        .text_size(px(9.0))
                                        .text_color(palette.ink_3)
                                        .child(candidate.group)
                                        .into_any_element(),
                                );
                            }
                            let command = &ctx.chat.commands[candidate.command_index];
                            let name = command.name.clone();
                            let insert = format!("/{} ", command.name);
                            let active = index == selected_slash;
                            rows.push(
                                div()
                                    .id(SharedString::from(format!("chat-slash-{name}")))
                                    .flex()
                                    .flex_row()
                                    .items_center()
                                    .gap(space(2))
                                    .h(px(24.0))
                                    .px(space(1))
                                    .rounded(px(RADIUS_SMALL))
                                    .text_size(px(11.0))
                                    .text_color(if active { palette.canvas } else { palette.ink })
                                    .bg(if active { palette.accent } else { palette.card })
                                    .hover(|style| {
                                        style.bg(if active { palette.accent } else { palette.soft })
                                    })
                                    .child(
                                        div()
                                            .w(px(170.0))
                                            .flex_shrink_0()
                                            .truncate()
                                            .child(format!("/{name}")),
                                    )
                                    .child(
                                        div()
                                            .flex_1()
                                            .min_w(px(0.0))
                                            .truncate()
                                            .text_size(px(10.0))
                                            .text_color(if active {
                                                palette.canvas
                                            } else {
                                                palette.ink_3
                                            })
                                            .child(command.description.clone()),
                                    )
                                    .on_click(cx.listener(move |this, _, window, cx| {
                                        this.set_chat_input_text(insert.clone(), window, cx);
                                    }))
                                    .into_any_element(),
                            );
                        }
                        div()
                            .id("chat-slash-menu")
                            .flex()
                            .flex_col()
                            .gap(px(1.0))
                            .p(space(1))
                            .rounded(px(RADIUS_MEDIUM))
                            .border_1()
                            .border_color(palette.line_strong)
                            .bg(palette.card)
                            .occlude()
                            .max_h(px(280.0))
                            .overflow_y_scroll()
                            .children(rows)
                            .into_any_element()
                    });
                    let config_query = ctx.chat.config_search.to_lowercase();
                    let config_search_input = ctx.chat.config_search_input.clone();
                    let config_scroll = ctx.chat.config_scroll.clone();
                    let config_pickers = ctx
                        .chat
                        .configs
                        .iter()
                        .enumerate()
                        .map(|(index, config)| {
                            let root = cx.entity().downgrade();
                            let palette = *palette;
                            let name = config.name.clone();
                            let current = config.current.clone();
                            let selected_value = config.current.clone();
                            let searchable = config.category == ConfigOptionCategory::Model;
                            let query = if searchable {
                                config_query.as_str()
                            } else {
                                ""
                            };
                            let options = config
                                .values
                                .iter()
                                .filter(|(_, label)| {
                                    query.is_empty() || label.to_lowercase().contains(query)
                                })
                                .cloned()
                                .collect::<Vec<_>>();
                            let content_root = root.clone();
                            let open_root = root.clone();
                            let content_search_input = if searchable {
                                config_search_input.clone()
                            } else {
                                None
                            };
                            let content_scroll = config_scroll.clone();
                            Popover::new(SharedString::from(format!("chat-config-popover-{index}")))
                                .trigger(
                                    Button::new(SharedString::from(format!(
                                        "chat-config-trigger-{index}"
                                    )))
                                    .label(current)
                                    .xsmall()
                                    .ghost()
                                    .max_w(px(180.0))
                                    .tooltip(name),
                                )
                                .content(move |_, _, cx| {
                                    let dismiss = cx.entity().downgrade();
                                    let search_input = content_search_input.clone();
                                    let scroll = content_scroll.clone();
                                    let rows = options.iter().map(|(value, label)| {
                                        let value = value.clone();
                                        let label = label.clone();
                                        let selected = value == selected_value;
                                        let row_root = content_root.clone();
                                        let row_dismiss = dismiss.clone();
                                        div()
                                            .id(SharedString::from(format!(
                                                "chat-config-{index}-{value}"
                                            )))
                                            .flex()
                                            .flex_row()
                                            .items_center()
                                            .justify_between()
                                            .gap(space(2))
                                            .px(space(1))
                                            .py(px(3.0))
                                            .rounded(px(RADIUS_SMALL))
                                            .text_size(px(11.0))
                                            .text_color(if selected {
                                                palette.accent
                                            } else {
                                                palette.ink_2
                                            })
                                            .hover(|style| style.bg(palette.soft))
                                            .child(label)
                                            .children(selected.then_some("✓"))
                                            .on_click(move |_, window, cx| {
                                                let _ = row_root.update(cx, |this, cx| {
                                                    this.set_chat_config(index, value.clone(), cx);
                                                });
                                                let _ = row_dismiss.update(cx, |state, cx| {
                                                    state.dismiss(window, cx)
                                                });
                                            })
                                            .into_any_element()
                                    });
                                    let list = div()
                                        .id(SharedString::from(format!("chat-config-list-{index}")))
                                        .flex()
                                        .flex_col()
                                        .gap(px(1.0))
                                        .max_h(px(244.0))
                                        .track_scroll(&scroll)
                                        .overflow_y_scroll()
                                        .occlude()
                                        .children(rows);
                                    let list = list.vertical_scrollbar(&scroll);
                                    div()
                                        .id(SharedString::from(format!(
                                            "chat-config-options-{index}"
                                        )))
                                        .flex()
                                        .flex_col()
                                        .w(px(260.0))
                                        .max_h(px(280.0))
                                        .occlude()
                                        .children(search_input.map(|input| {
                                            div()
                                                .px(space(1))
                                                .pb(space(1))
                                                .mb(space(1))
                                                .border_b_1()
                                                .border_color(palette.line)
                                                .child(
                                                    Input::new(&input)
                                                        .small()
                                                        .appearance(false)
                                                        .w_full(),
                                                )
                                                .into_any_element()
                                        }))
                                        .child(list)
                                })
                                .on_open_change(move |open, window, cx| {
                                    if *open && searchable {
                                        let _ = open_root.update(cx, |this, cx| {
                                            this.reset_config_search(window, cx);
                                        });
                                    }
                                })
                                .flex_none()
                        })
                        .collect::<Vec<_>>();
                    let placeholder = match language {
                        Language::Zh => {
                            format!("给 {agent_label} 发消息… @ 引用上下文，/ 查看命令")
                        }
                        Language::En => {
                            format!("Message {agent_label} — @ to include context, / for commands")
                        }
                    };
                    div()
                        .relative()
                        .flex()
                        .flex_col()
                        .gap(space(1))
                        .child(
                            div()
                                .id("chat-composer")
                                .flex()
                                .flex_col()
                                .gap(space(1))
                                .p(space(1))
                                .rounded(px(RADIUS_MEDIUM))
                                .border_1()
                                .border_color(if ctx.chat.focused {
                                    palette.accent
                                } else {
                                    palette.line
                                })
                                .bg(palette.view)
                                .child(match ctx.chat_input.clone() {
                                    Some(state) => Textarea::new(&state)
                                        .appearance(false)
                                        .bordered(false)
                                        .aria_label(translate(
                                            language,
                                            Key::AgentChatChatInputHint,
                                        ))
                                        .h(px(38.0))
                                        .w_full()
                                        .into_any_element(),
                                    None => div()
                                        .id("chat-input")
                                        .role(Role::TextInput)
                                        .aria_label(translate(
                                            language,
                                            Key::AgentChatChatInputHint,
                                        ))
                                        .min_h(px(38.0))
                                        .px(space(1))
                                        .py(px(3.0))
                                        .text_size(px(13.0))
                                        .text_color(if input.is_empty() {
                                            palette.ink_3
                                        } else {
                                            palette.ink
                                        })
                                        .child(if input.is_empty() {
                                            placeholder
                                        } else {
                                            input.clone()
                                        })
                                        .into_any_element(),
                                })
                                .child(
                                    div()
                                        .flex()
                                        .flex_row()
                                        .flex_wrap()
                                        .items_center()
                                        .gap(space(1))
                                        .w_full()
                                        .min_w(px(0.0))
                                        .child(
                                            div()
                                                .id("chat-add-context")
                                                .size(px(24.0))
                                                .rounded(px(RADIUS_SMALL))
                                                .flex()
                                                .items_center()
                                                .justify_center()
                                                .text_color(palette.ink_3)
                                                .hover(|style| style.bg(palette.soft))
                                                .child(
                                                    Icon::default()
                                                        .path(AssetIcon::Paperclip.path())
                                                        .small(),
                                                )
                                                .on_click(cx.listener(|this, _, window, cx| {
                                                    let current = this.chat.input.clone();
                                                    this.set_chat_input_text(
                                                        format!("{current}@"),
                                                        window,
                                                        cx,
                                                    );
                                                })),
                                        )
                                        .children(config_pickers)
                                        .child(
                                            div()
                                                .id(if streaming {
                                                    "chat-stop"
                                                } else {
                                                    "chat-send"
                                                })
                                                .role(Role::Button)
                                                .aria_label(if streaming {
                                                    "Stop Generation"
                                                } else {
                                                    translate(language, Key::AgentChatChatSend)
                                                })
                                                .size(px(24.0))
                                                .rounded(px(RADIUS_SMALL))
                                                .flex()
                                                .items_center()
                                                .justify_center()
                                                .ml_auto()
                                                .bg(if streaming {
                                                    palette.danger
                                                } else {
                                                    palette.accent
                                                })
                                                .text_color(palette.canvas)
                                                .child(
                                                    Icon::default()
                                                        .path(if streaming {
                                                            AssetIcon::Square.path()
                                                        } else {
                                                            AssetIcon::ArrowUp.path()
                                                        })
                                                        .small(),
                                                )
                                                .tooltip(move |window, cx| {
                                                    let label = if streaming {
                                                        "Stop Generation"
                                                    } else {
                                                        translate(language, Key::AgentChatChatSend)
                                                    };
                                                    Tooltip::new(label).build(window, cx)
                                                })
                                                .on_click(cx.listener(
                                                    move |this, _, window, cx| {
                                                        if streaming {
                                                            this.stop_chat_turn(cx);
                                                        } else {
                                                            this.send_chat(cx);
                                                            this.clear_chat_input(window, cx);
                                                        }
                                                    },
                                                )),
                                        ),
                                ),
                        )
                        .children(slash_rows.map(|menu| {
                            div()
                                .absolute()
                                .left(px(0.0))
                                .right(px(0.0))
                                .bottom(px(86.0))
                                .child(menu)
                                .into_any_element()
                        }))
                        .into_any_element()
                })
                .into_any_element()
        }
    };
    let mut history_rows = if ctx.chat.show_sessions {
        if ctx.chat.sessions.is_empty() {
            vec![div()
                .text_size(px(11.0))
                .text_color(palette.ink_3)
                .child(translate(language, Key::AgentChatChatNoHistory))
                .into_any_element()]
        } else {
            ctx.chat
                .sessions
                .iter()
                .take(10)
                .map(|session| {
                    let session_id = session.session_id.clone();
                    let delete_id = format!("acp-{}", session.session_id);
                    let is_current =
                        ctx.chat.session_id.as_deref() == Some(session.session_id.as_str());
                    let pending_delete =
                        ctx.pending_thread_delete.as_deref() == Some(delete_id.as_str());
                    let title = session.title.clone().unwrap_or_else(|| {
                        let short = session.session_id.chars().take(10).collect::<String>();
                        format!("{short}…")
                    });
                    div()
                        .id(format!("chat-restore-{}", session.session_id))
                        .w_full()
                        .flex()
                        .flex_row()
                        .items_center()
                        .gap(space(1))
                        .px(space(1))
                        .py(px(3.0))
                        .rounded(px(RADIUS_SMALL))
                        .text_size(px(11.0))
                        .text_color(if is_current {
                            palette.accent
                        } else {
                            palette.ink_2
                        })
                        .hover(|style| style.bg(palette.soft))
                        .child(div().flex_1().child(title))
                        .child(
                            div()
                                .id(format!("chat-delete-{}", session.session_id))
                                .px(px(3.0))
                                .rounded(px(RADIUS_SMALL))
                                .text_color(palette.ink_3)
                                .hover(|style| style.bg(palette.card))
                                .child(if pending_delete { "删除?" } else { "×" })
                                .on_click(cx.listener(move |this, _, _, cx| {
                                    this.request_delete_thread(delete_id.clone(), cx);
                                })),
                        )
                        .on_click(cx.listener(move |this, _, _, cx| {
                            if this.pending_thread_delete.is_some() {
                                this.cancel_thread_delete(cx);
                            } else {
                                this.restore_chat_session(session_id.clone(), cx);
                            }
                        }))
                        .into_any_element()
                })
                .collect()
        }
    } else {
        Vec::new()
    };
    if ctx.chat.show_sessions {
        let current_native = ctx
            .native_agent_view
            .as_ref()
            .and_then(|view| view.read(cx).current_thread_id());
        let native_rows = ctx
            .chat
            .local_threads
            .iter()
            .filter(|thread| thread.agent == "native")
            .take(10)
            .map(|thread| {
                let thread_id = thread.id.clone();
                let delete_id = thread.id.clone();
                let is_current = current_native.as_deref() == Some(thread.id.as_str());
                let pending_delete =
                    ctx.pending_thread_delete.as_deref() == Some(delete_id.as_str());
                let title = thread
                    .title
                    .clone()
                    .unwrap_or_else(|| "未命名线程".to_string());
                div()
                    .id(format!("chat-restore-native-{}", thread.id))
                    .w_full()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap(space(1))
                    .px(space(1))
                    .py(px(3.0))
                    .rounded(px(RADIUS_SMALL))
                    .text_size(px(11.0))
                    .text_color(if is_current {
                        palette.accent
                    } else {
                        palette.ink_2
                    })
                    .hover(|style| style.bg(palette.soft))
                    .child(div().flex_1().child(format!("{title}  · native")))
                    .child(
                        div()
                            .id(format!("chat-delete-native-{}", thread.id))
                            .px(px(3.0))
                            .rounded(px(RADIUS_SMALL))
                            .text_color(palette.ink_3)
                            .hover(|style| style.bg(palette.card))
                            .child(if pending_delete { "删除?" } else { "×" })
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.request_delete_thread(delete_id.clone(), cx);
                            })),
                    )
                    .on_click(cx.listener(move |this, _, window, cx| {
                        if this.pending_thread_delete.is_some() {
                            this.cancel_thread_delete(cx);
                        } else {
                            this.open_local_native_thread(thread_id.clone(), window, cx);
                        }
                    }))
                    .into_any_element()
            });
        history_rows.extend(native_rows);
    }
    let thread_sidebar = ctx.chat.show_sessions.then(|| {
        div()
            .w(px(170.0))
            .flex_none()
            .flex()
            .flex_col()
            .gap(space(1))
            .pr(space(1))
            .border_r_1()
            .border_color(palette.line)
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .justify_between()
                    .text_size(px(11.0))
                    .text_color(palette.ink_3)
                    .child(translate(language, Key::AgentChatChatThreads))
                    .child(
                        div()
                            .id("chat-hide-history")
                            .px(space(1))
                            .rounded(px(RADIUS_SMALL))
                            .hover(|style| style.bg(palette.soft))
                            .child("×")
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.chat.show_sessions = false;
                                cx.notify();
                            })),
                    ),
            )
            .child(
                div()
                    .id("chat-thread-list")
                    .flex()
                    .flex_col()
                    .gap(px(2.0))
                    .overflow_y_scroll()
                    .children(history_rows),
            )
            .into_any_element()
    });
    let installed_agents = ctx
        .agent_registry_rows
        .iter()
        .filter(|row| matches!(row.status, AgentStatus::Ready { .. }))
        .map(|row| row.entry.id.clone())
        .collect::<Vec<_>>();
    let agent_options = Registry::builtin()
        .map(|registry| {
            registry
                .agents
                .into_iter()
                .filter(|entry| installed_agents.is_empty() || installed_agents.contains(&entry.id))
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    let _agent_picker = {
        let root = cx.entity().downgrade();
        let load_root = root.clone();
        let options = agent_options.clone();
        let loading = ctx.agent_registry_loading;
        let registry_started = ctx.agent_registry_started;
        let palette = *palette;
        Popover::new("chat-agent-picker-popover")
            .trigger(
                Button::new("chat-agent-picker")
                    .icon(Icon::default().path(AssetIcon::Plus.path()).small())
                    .xsmall()
                    .ghost()
                    .tooltip(if cfg!(target_os = "macos") {
                        "新对话 · ⌘N"
                    } else {
                        "新对话 · Ctrl+N"
                    }),
            )
            .on_open_change(move |open, _, cx| {
                if *open && !registry_started {
                    let _ = load_root.update(cx, |this, cx| {
                        this.start_agent_registry_load(cx);
                    });
                }
            })
            .content(move |_, _, cx| {
                let dismiss = cx.entity().downgrade();
                let new_root = root.clone();
                let new_dismiss = dismiss.clone();
                let cgc_root = root.clone();
                let cgc_dismiss = dismiss.clone();
                let cgc_row = crate::root_view::RootView::native_agent_enabled().then(|| {
                    div()
                        .id("chat-agent-cgc")
                        .flex()
                        .flex_row()
                        .items_center()
                        .gap(space(1))
                        .px(space(1))
                        .py(px(3.0))
                        .rounded(px(RADIUS_SMALL))
                        .hover(|style| style.bg(palette.soft))
                        .child(div().flex_1().child("CGC Agent"))
                        .child(
                            div()
                                .text_size(px(10.0))
                                .text_color(palette.ink_3)
                                .child("Native"),
                        )
                        .on_click(move |_, window, cx| {
                            let _ = cgc_root.update(cx, |this, cx| this.enter_native_chat(cx));
                            let _ = cgc_dismiss.update(cx, |state, cx| state.dismiss(window, cx));
                        })
                        .into_any_element()
                });
                let mut new_row = Some(
                    div()
                        .id("chat-agent-new-thread")
                        .flex()
                        .flex_row()
                        .items_center()
                        .justify_between()
                        .gap(space(2))
                        .px(space(1))
                        .py(px(4.0))
                        .rounded(px(RADIUS_SMALL))
                        .text_color(palette.ink_2)
                        .hover(|style| style.bg(palette.soft))
                        .child("新对话")
                        .child(div().text_size(px(10.0)).text_color(palette.ink_3).child(
                            if cfg!(target_os = "macos") {
                                "⌘N"
                            } else {
                                "Ctrl+N"
                            },
                        ))
                        .on_click(move |_, window, cx| {
                            let _ = new_root.update(cx, |this, cx| this.new_chat(cx));
                            let _ = new_dismiss.update(cx, |state, cx| state.dismiss(window, cx));
                        })
                        .into_any_element(),
                );
                let rows = if options.is_empty() {
                    vec![div()
                        .px(space(1))
                        .py(px(3.0))
                        .text_size(px(10.0))
                        .text_color(palette.ink_3)
                        .child(if loading {
                            "检测本机 agent…"
                        } else {
                            "没有已安装的 agent"
                        })
                        .into_any_element()]
                } else {
                    options
                        .iter()
                        .map(|entry| {
                            let id = entry.id.clone();
                            let name = entry.display_name.clone();
                            let row_root = root.clone();
                            let dismiss = dismiss.clone();
                            div()
                                .id(SharedString::from(format!(
                                    "chat-agent-option-{}",
                                    entry.id
                                )))
                                .flex()
                                .flex_row()
                                .items_center()
                                .gap(space(1))
                                .px(space(1))
                                .py(px(3.0))
                                .rounded(px(RADIUS_SMALL))
                                .hover(|style| style.bg(palette.soft))
                                .child(div().flex_1().child(name.clone()))
                                .on_click(move |_, window, cx| {
                                    let _ = row_root.update(cx, |this, cx| {
                                        this.select_chat_agent(id.clone(), name.clone(), cx);
                                    });
                                    let _ =
                                        dismiss.update(cx, |state, cx| state.dismiss(window, cx));
                                })
                                .into_any_element()
                        })
                        .collect()
                };
                let mut rows = rows;
                if let Some(cgc_row) = cgc_row {
                    rows.insert(0, cgc_row);
                }
                let new_row = new_row.take();
                if let Some(new_row) = new_row {
                    rows.insert(
                        usize::from(crate::root_view::RootView::native_agent_enabled()),
                        new_row,
                    );
                }
                let add_root = root.clone();
                let add_dismiss = dismiss.clone();
                rows.push(
                    div()
                        .id("chat-agent-add-more")
                        .px(space(1))
                        .py(px(3.0))
                        .rounded(px(RADIUS_SMALL))
                        .text_color(palette.accent)
                        .hover(|style| style.bg(palette.soft))
                        .child("Add More Agents")
                        .on_click(move |_, window, cx| {
                            let _ = add_root.update(cx, |this, cx| this.open_agent_registry(cx));
                            let _ = add_dismiss.update(cx, |state, cx| state.dismiss(window, cx));
                        })
                        .into_any_element(),
                );
                div()
                    .flex()
                    .flex_col()
                    .gap(px(1.0))
                    .w(px(220.0))
                    .text_size(px(11.0))
                    .text_color(palette.ink_2)
                    .children(rows)
            })
    };
    let context_chip = (ctx.active_tab.as_deref())
        .and_then(|active| ctx.tabs.iter().find(|tab| tab.id == active))
        .filter(|tab| tab.issue_id.is_some() && !ctx.chat.context_dismissed)
        .map(|tab| {
            div()
                .id("chat-context-chip")
                .flex()
                .flex_row()
                .items_center()
                .gap(space(1))
                .px(space(1))
                .py(px(2.0))
                .rounded(px(RADIUS_SMALL))
                .bg(palette.soft)
                .text_size(px(11.0))
                .text_color(palette.ink_3)
                .child(format!("上下文：{}", tab.title))
                .child(
                    div()
                        .id("chat-context-dismiss")
                        .px(px(4.0))
                        .rounded(px(RADIUS_SMALL))
                        .hover(|style| style.bg(palette.card))
                        .child("×")
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.dismiss_chat_context(cx);
                        })),
                )
                .into_any_element()
        });
    div()
        .flex()
        .flex_row()
        .items_stretch()
        .gap(space(1))
        .h_full()
        .p(space(2))
        .bg(palette.card)
        .children(thread_sidebar)
        .child(
            div()
                .flex()
                .flex_1()
                .min_w(px(0.0))
                .flex_col()
                .gap(space(1))
                .children(context_chip)
                .child(body),
        )
        .into_any_element()
}
