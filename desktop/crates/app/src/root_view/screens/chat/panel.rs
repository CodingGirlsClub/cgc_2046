use super::super::super::*;
use super::super::ScreenContext;
use gpui_kit::component::button::{Button, ButtonVariants};
use gpui_kit::component::popover::Popover;

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
                .child({
                    let slash_open = input.starts_with('/') && !input.contains(' ');
                    let commands = [
                        ("/help", "显示可用命令"),
                        ("/clear", "清空当前对话"),
                        ("/model", "切换模型"),
                        ("/compact", "压缩上下文"),
                    ];
                    let slash_rows = slash_open.then(|| {
                        div()
                            .id("chat-slash-menu")
                            .flex()
                            .flex_col()
                            .gap(px(1.0))
                            .p(space(1))
                            .rounded(px(RADIUS_MEDIUM))
                            .border_1()
                            .border_color(palette.line)
                            .bg(palette.card)
                            .children(commands.into_iter().map(|(command, description)| {
                                let command = command.to_string();
                                div()
                                    .id(SharedString::from(format!("chat-slash-{command}")))
                                    .flex()
                                    .flex_row()
                                    .items_center()
                                    .justify_between()
                                    .gap(space(2))
                                    .px(space(1))
                                    .py(px(3.0))
                                    .rounded(px(RADIUS_SMALL))
                                    .hover(|style| style.bg(palette.soft))
                                    .child(
                                        div()
                                            .text_size(px(11.0))
                                            .text_color(palette.ink)
                                            .child(command.clone()),
                                    )
                                    .child(
                                        div()
                                            .text_size(px(10.0))
                                            .text_color(palette.ink_3)
                                            .child(description),
                                    )
                                    .on_click(cx.listener(move |this, _, window, cx| {
                                        this.chat.input = format!("{command} ");
                                        this.chat.focused = true;
                                        let focus = this.ensure_key_focus(cx);
                                        window.focus(&focus, cx);
                                        cx.notify();
                                    }))
                            }))
                            .into_any_element()
                    });
                    let permission = ctx.chat.permission;
                    let configs = ctx
                        .chat
                        .configs
                        .iter()
                        .take(2)
                        .enumerate()
                        .map(|(index, config)| (index, config.name.clone(), config.current.clone()))
                        .collect::<Vec<_>>();
                    let has_model = !configs.is_empty();
                    let has_reasoning = configs.len() > 1;
                    let model_label = configs
                        .first()
                        .map(|(_, _, current)| current.clone())
                        .unwrap_or_else(|| "Default".to_string());
                    let reasoning_label = configs
                        .get(1)
                        .map(|(_, _, current)| current.clone())
                        .unwrap_or_else(|| "Medium".to_string());
                    let placeholder = match language {
                        Language::Zh => {
                            format!("给 {agent_label} 发消息… @ 引用上下文，/ 查看命令")
                        }
                        Language::En => {
                            format!("Message {agent_label} — @ to include context, / for commands")
                        }
                    };
                    div()
                        .flex()
                        .flex_col()
                        .gap(space(1))
                        .children(slash_rows)
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
                                .child(
                                    div()
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
                                        .items_center()
                                        .gap(space(1))
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
                                                .on_click(cx.listener(|this, _, _, cx| {
                                                    this.chat.focused = true;
                                                    this.chat.input.push('@');
                                                    cx.notify();
                                                })),
                                        )
                                        .child(
                                            div()
                                                .id("chat-permission")
                                                .flex()
                                                .flex_row()
                                                .items_center()
                                                .gap(px(4.0))
                                                .px(space(1))
                                                .py(px(2.0))
                                                .rounded(px(RADIUS_SMALL))
                                                .text_size(px(10.0))
                                                .text_color(palette.ink_2)
                                                .hover(|style| style.bg(palette.soft))
                                                .child(
                                                    Icon::default()
                                                        .path(AssetIcon::Shield.path())
                                                        .small(),
                                                )
                                                .child(permission.label())
                                                .on_click(cx.listener(|this, _, _, cx| {
                                                    this.cycle_chat_permission(cx);
                                                })),
                                        )
                                        .child(
                                            div()
                                                .id("chat-model")
                                                .px(space(1))
                                                .py(px(2.0))
                                                .rounded(px(RADIUS_SMALL))
                                                .text_size(px(10.0))
                                                .text_color(palette.ink_2)
                                                .hover(|style| style.bg(palette.soft))
                                                .child(model_label)
                                                .on_click(cx.listener(move |this, _, _, cx| {
                                                    if has_model {
                                                        this.cycle_chat_config(0, cx);
                                                    }
                                                })),
                                        )
                                        .child(
                                            div()
                                                .id("chat-reasoning")
                                                .px(space(1))
                                                .py(px(2.0))
                                                .rounded(px(RADIUS_SMALL))
                                                .text_size(px(10.0))
                                                .text_color(palette.ink_2)
                                                .hover(|style| style.bg(palette.soft))
                                                .child(reasoning_label)
                                                .on_click(cx.listener(move |this, _, _, cx| {
                                                    if has_reasoning {
                                                        this.cycle_chat_config(1, cx);
                                                    }
                                                })),
                                        )
                                        .child(div().flex_1())
                                        .children(streaming.then(|| {
                                            div()
                                                .id("chat-stop")
                                                .size(px(24.0))
                                                .rounded(px(RADIUS_SMALL))
                                                .flex()
                                                .items_center()
                                                .justify_center()
                                                .bg(palette.soft)
                                                .text_color(palette.ink_2)
                                                .child(
                                                    Icon::default()
                                                        .path(AssetIcon::SquarePen.path())
                                                        .small(),
                                                )
                                                .on_click(cx.listener(|this, _, _, cx| {
                                                    this.stop_chat_turn(cx);
                                                }))
                                                .into_any_element()
                                        }))
                                        .child(
                                            div()
                                                .id("chat-new")
                                                .size(px(24.0))
                                                .rounded(px(RADIUS_SMALL))
                                                .flex()
                                                .items_center()
                                                .justify_center()
                                                .text_color(palette.ink_3)
                                                .hover(|style| style.bg(palette.soft))
                                                .child(
                                                    Icon::default()
                                                        .path(AssetIcon::Plus.path())
                                                        .small(),
                                                )
                                                .on_click(cx.listener(|this, _, _, cx| {
                                                    if let Some(course_id) =
                                                        this.chat.course_id.clone()
                                                    {
                                                        clear_chat_pointer(&course_id);
                                                    }
                                                    this.reset_chat_local(cx);
                                                    this.start_chat(cx);
                                                })),
                                        )
                                        .child(
                                            div()
                                                .id("chat-send")
                                                .role(Role::Button)
                                                .aria_label(translate(
                                                    language,
                                                    Key::AgentChatChatSend,
                                                ))
                                                .size(px(24.0))
                                                .rounded(px(RADIUS_SMALL))
                                                .flex()
                                                .items_center()
                                                .justify_center()
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
                                                .child(
                                                    Icon::default()
                                                        .path(AssetIcon::ArrowUp.path())
                                                        .small(),
                                                )
                                                .on_click(cx.listener(|this, _, _, cx| {
                                                    this.chat.focused = true;
                                                    this.send_chat(cx);
                                                })),
                                        ),
                                ),
                        )
                        .into_any_element()
                })
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
    let agent_picker = {
        let root = cx.entity().downgrade();
        let load_root = root.clone();
        let options = agent_options.clone();
        let loading = ctx.agent_registry_loading;
        let registry_started = ctx.agent_registry_started;
        let palette = *palette;
        Popover::new("chat-agent-picker-popover")
            .trigger(
                Button::new("chat-agent-picker")
                    .label(format!("{agent_label}{version}"))
                    .ghost(),
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
        .child(agent_picker)
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
                    this.reset_chat_local(cx);
                    this.start_chat(cx);
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
                .children(context_chip)
                .children(config_rows)
                .child(body),
        )
        .into_any_element()
}
