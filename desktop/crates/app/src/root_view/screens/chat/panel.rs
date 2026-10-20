use super::super::super::*;
use super::super::ScreenContext;

pub(in crate::root_view) fn render_chat_panel(
    ctx: &mut ScreenContext<'_>,
    language: Language,
    palette: &theme::Palette,
    cx: &mut Context<RootView>,
) -> AnyElement {
    let phase = ctx.chat.phase.clone();
    let messages = ctx.chat.messages.clone();
    let input = ctx.chat.input.clone();
    let agent_label = if ctx.chat.agent.is_empty() {
        "agent".to_string()
    } else {
        ctx.chat.agent.clone()
    };
    let body: AnyElement =
        match &phase {
            ChatPhase::Idle => div()
                .flex()
                .flex_row()
                .items_center()
                .gap(space(2))
                .child(
                    div()
                        .text_size(px(12.0))
                        .text_color(palette.ink_3)
                        .child(format!("{agent_label} · 本机运行")),
                )
                .child(
                    div()
                        .id("chat-start")
                        .role(Role::Button)
                        .aria_label(translate(language, Key::AgentChatChatStart))
                        .role(Role::Button)
                        .aria_label(translate(language, Key::AgentChatChatStart))
                        .px(space(2))
                        .py(px(5.0))
                        .rounded(px(RADIUS_MEDIUM))
                        .bg(palette.accent)
                        .text_color(palette.canvas)
                        .child(translate(language, Key::AgentChatChatStart))
                        .on_click(cx.listener(|this, _, _, cx| this.start_chat(cx))),
                )
                .into_any_element(),
            ChatPhase::Starting => div()
                .text_size(px(12.0))
                .text_color(palette.ink_3)
                .child(translate(language, Key::AgentChatChatStarting))
                .into_any_element(),
            ChatPhase::Failed(message) => {
                let guidance =
                    ctx.chat.guidance.clone().map(|guidance| {
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
                            .child(div().text_size(px(11.0)).text_color(palette.ink_3).child(
                                format!(
                                    "Node runtime: {} (required 24.x)",
                                    guidance
                                        .node_found
                                        .clone()
                                        .unwrap_or_else(|| "missing".to_string())
                                ),
                            ))
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
                let rows = messages
                    .iter()
                    .map(|entry| match entry {
                        ChatEntry::User(text) => div()
                            .flex()
                            .flex_col()
                            .gap(px(1.0))
                            .text_size(px(11.0))
                            .text_color(palette.ink_3)
                            .child("你".to_string())
                            .child(
                                div()
                                    .text_size(px(13.0))
                                    .text_color(palette.ink)
                                    .child(text.clone()),
                            )
                            .into_any_element(),
                        ChatEntry::Assistant(text) => div()
                            .flex()
                            .flex_col()
                            .gap(px(1.0))
                            .text_size(px(11.0))
                            .text_color(palette.ink_3)
                            .child(agent_label.clone())
                            .child(
                                TextView::markdown(
                                    format!("chat-markdown-{}", text.len()),
                                    sanitize_markdown(text),
                                )
                                .into_any_element(),
                            )
                            .into_any_element(),
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
                    })
                    .collect::<Vec<_>>();
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
                    .child(
                        div()
                            .id("chat-input")
                            .role(Role::TextInput)
                            .aria_label(translate(language, Key::AgentChatChatInputHint))
                            .h(px(34.0))
                            .flex()
                            .items_center()
                            .px(space(2))
                            .rounded(px(RADIUS_MEDIUM))
                            .border_1()
                            .border_color(if ctx.chat.focused {
                                palette.accent
                            } else {
                                palette.line
                            })
                            .bg(palette.view)
                            .text_size(px(13.0))
                            .text_color(if input.is_empty() {
                                palette.ink_3
                            } else {
                                palette.ink
                            })
                            .child(if input.is_empty() {
                                translate(language, Key::AgentChatChatInputHint).to_string()
                            } else {
                                input.clone()
                            })
                            .on_mouse_down(
                                MouseButton::Left,
                                cx.listener(|this, _, window, cx| {
                                    this.chat.focused = true;
                                    let focus = this.ensure_key_focus(cx);
                                    window.focus(&focus, cx);
                                    cx.notify();
                                }),
                            ),
                    )
                    .child(
                        div()
                            .flex()
                            .flex_row()
                            .gap(space(1))
                            .child(
                                div()
                                    .id("chat-send")
                                    .role(Role::Button)
                                    .aria_label(translate(language, Key::AgentChatChatSend))
                                    .role(Role::Button)
                                    .aria_label(translate(language, Key::AgentChatChatSend))
                                    .role(Role::Button)
                                    .aria_label(translate(language, Key::AgentChatChatSend))
                                    .px(space(2))
                                    .py(px(4.0))
                                    .rounded(px(RADIUS_MEDIUM))
                                    .bg(if streaming {
                                        palette.soft
                                    } else {
                                        palette.accent
                                    })
                                    .text_color(if streaming {
                                        palette.ink_3
                                    } else {
                                        palette.canvas
                                    })
                                    .child(translate(language, Key::AgentChatChatSend))
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.chat.focused = true;
                                        this.send_chat(cx);
                                    })),
                            )
                            .child(
                                div()
                                    .id("chat-new")
                                    .role(Role::Button)
                                    .aria_label(translate(language, Key::AgentChatChatNew))
                                    .role(Role::Button)
                                    .aria_label(translate(language, Key::AgentChatChatNew))
                                    .role(Role::Button)
                                    .aria_label(translate(language, Key::AgentChatChatNew))
                                    .px(space(2))
                                    .py(px(4.0))
                                    .rounded(px(RADIUS_MEDIUM))
                                    .bg(palette.soft)
                                    .text_color(palette.ink_2)
                                    .child(translate(language, Key::AgentChatChatNew))
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        if let Some(course_id) = this.chat.course_id.clone() {
                                            clear_chat_pointer(&course_id);
                                        }
                                        this.reset_chat_local();
                                        this.start_chat(cx);
                                    })),
                            )
                            .children(streaming.then(|| {
                                div()
                                    .id("chat-stop")
                                    .role(Role::Button)
                                    .aria_label(translate(language, Key::AgentChatChatStop))
                                    .role(Role::Button)
                                    .aria_label(translate(language, Key::AgentChatChatStop))
                                    .role(Role::Button)
                                    .aria_label(translate(language, Key::AgentChatChatStop))
                                    .px(space(2))
                                    .py(px(4.0))
                                    .rounded(px(RADIUS_MEDIUM))
                                    .bg(palette.soft)
                                    .text_color(palette.ink_2)
                                    .child(translate(language, Key::AgentChatChatStop))
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.stop_chat_turn(cx);
                                    }))
                                    .into_any_element()
                            })),
                    )
                    .into_any_element()
            }
        };
    let version = ctx
        .chat
        .version
        .as_deref()
        .map(|version| format!(" · {version}"))
        .unwrap_or_default();
    let config_rows = ctx
        .chat
        .configs
        .iter()
        .take(2)
        .enumerate()
        .map(|(index, config)| {
            div()
                .flex()
                .flex_row()
                .items_center()
                .gap(space(1))
                .text_size(px(11.0))
                .text_color(palette.ink_3)
                .child(format!("{}：{}", config.name, config.current))
                .child(
                    div()
                        .id(format!("chat-config-{index}"))
                        .px(space(1))
                        .py(px(2.0))
                        .rounded(px(RADIUS_SMALL))
                        .bg(palette.soft)
                        .text_color(palette.ink_2)
                        .child(translate(language, Key::AgentChatChatConfig))
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.cycle_chat_config(index, cx);
                        })),
                )
                .into_any_element()
        })
        .collect::<Vec<_>>();
    let history_rows = if ctx.chat.show_sessions {
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
                    let title = session.title.clone().unwrap_or_else(|| {
                        let short = session.session_id.chars().take(10).collect::<String>();
                        format!("{short}…")
                    });
                    div()
                        .id(format!("chat-restore-{}", session.session_id))
                        .w_full()
                        .px(space(1))
                        .py(px(3.0))
                        .rounded(px(RADIUS_SMALL))
                        .text_size(px(11.0))
                        .text_color(palette.ink_2)
                        .hover(|style| style.bg(palette.soft))
                        .child(title)
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.restore_chat_session(session_id.clone(), cx);
                        }))
                        .into_any_element()
                })
                .collect()
        }
    } else {
        Vec::new()
    };
    let status_color = match &phase {
        ChatPhase::Ready | ChatPhase::Streaming => palette.accent,
        ChatPhase::Failed(_) => palette.danger,
        _ => palette.ink_3,
    };
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
    let toolbar = div()
        .flex()
        .flex_row()
        .items_center()
        .gap(space(1))
        .child(div().size(px(6.0)).rounded_full().bg(status_color))
        .child(
            div()
                .text_size(px(15.0))
                .text_color(palette.ink)
                .child(translate_registered(language, "agent_chat.panel.title")),
        )
        .child(
            div()
                .text_size(px(11.0))
                .text_color(palette.ink_3)
                .child(format!("{agent_label}{version}")),
        )
        .child(div().flex_1())
        .child(
            div()
                .id("chat-new-toolbar")
                .role(Role::Button)
                .aria_label(translate(language, Key::AgentChatChatNew))
                .px(space(1))
                .py(px(3.0))
                .rounded(px(RADIUS_SMALL))
                .text_size(px(11.0))
                .text_color(palette.accent)
                .hover(|style| style.bg(palette.soft))
                .child(translate(language, Key::AgentChatChatNew))
                .on_click(cx.listener(|this, _, _, cx| {
                    if let Some(course_id) = this.chat.course_id.clone() {
                        clear_chat_pointer(&course_id);
                    }
                    this.reset_chat_local();
                    this.start_chat(cx);
                })),
        )
        .child(
            div()
                .id("chat-history-toolbar")
                .role(Role::Button)
                .aria_label(translate(language, Key::AgentChatChatHistory))
                .px(space(1))
                .py(px(3.0))
                .rounded(px(RADIUS_SMALL))
                .text_size(px(11.0))
                .text_color(if ctx.chat.show_sessions {
                    palette.ink
                } else {
                    palette.accent
                })
                .bg(if ctx.chat.show_sessions {
                    palette.soft
                } else {
                    palette.card
                })
                .child(translate(language, Key::AgentChatChatHistory))
                .on_click(cx.listener(|this, _, _, cx| {
                    this.open_chat_history(cx);
                })),
        );
    div()
        .flex()
        .flex_row()
        .items_stretch()
        .gap(space(1))
        .h_full()
        .p(space(2))
        .rounded(px(RADIUS_MEDIUM))
        .border_1()
        .border_color(palette.line)
        .bg(palette.card)
        .children(thread_sidebar)
        .child(
            div()
                .flex()
                .flex_1()
                .min_w(px(0.0))
                .flex_col()
                .gap(space(1))
                .child(toolbar)
                .children(config_rows)
                .child(body),
        )
        .into_any_element()
}
