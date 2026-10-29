//! 消息行渲染（B4b 拆分：从视图模块移出，行为不变）。
//!
//! 子模块可直接访问父模块私有字段。

use super::*;

impl NativeAgentView {
    /// 构建单条历史消息的行元素。
    pub(super) fn render_message_row_element(
        &self,
        message_index: usize,
        palette: theme::Palette,
        menu_root: &WeakEntity<Self>,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let message = ViewRow::from_entry(&self.state.session.thread.entries[message_index]);
        let message = &message;
        let color = match message.role {
            ViewRole::User => palette.accent,
            ViewRole::Error => palette.danger,
            ViewRole::Tool => palette.ink_3,
            ViewRole::System => palette.ink_3,
            ViewRole::Thinking => palette.ink_3,
            ViewRole::Assistant => palette.ink,
        };
        // Copy This Agent Response = 整回合文本（对齐 Zed）；其它角色没有该动作。
        let agent_response = (message.role == ViewRole::Assistant)
            .then(|| {
                self.state
                    .session
                    .thread
                    .row_view()
                    .turn_copy_text(message_index)
            })
            .flatten();
        let payloads = Arc::new(message_menu_payloads(
            message.role,
            &message.text,
            agent_response,
        ));
        let menu_view = menu_root.clone();
        div()
            .id(SharedString::from(format!(
                "native-message-{message_index}"
            )))
            .flex()
            .flex_col()
            .gap(px(2.0))
            // 对齐 Zed：只有 system/error 这类状态消息保留角色标签；
            // user 用卡片区分、assistant 直接 markdown、tool/thinking 自带卡头。
            .child(match message.role {
                ViewRole::Assistant => {
                    // 对齐 Zed #61245 + #61362：只在回合末挂操作栏；历史消息的
                    // 操作栏在流式时仍可见，仅底部条在生成/等审批时隐藏。
                    let actions = self
                        .state
                        .session
                        .thread
                        .row_view()
                        .action_plan(
                            message_index,
                            self.is_generating(),
                            self.state.session.thread.pending_permission.is_some(),
                        )
                        .map(|plan| {
                            self.render_message_actions(
                                &format!("native-message-actions-{message_index}"),
                                self.state
                                    .session
                                    .thread
                                    .row_view()
                                    .turn_copy_text(message_index),
                                plan,
                                palette,
                                cx,
                            )
                        });
                    render_assistant_row(AssistantRowSpec {
                        row_id: SharedString::from(format!("native-assistant-{message_index}")),
                        markdown_id: SharedString::from(format!(
                            "native-assistant-markdown-{message_index}"
                        )),
                        markdown: message.text.clone(),
                        label: None,
                        style: native_message_style(palette),
                        actions,
                    })
                }
                ViewRole::User => {
                    if self.editing_user == Some(message_index) {
                        self.render_user_edit_row(message_index, &palette, cx)
                    } else {
                        let restore_checkpoint = if self
                            .state
                            .session
                            .thread
                            .capabilities
                            .checkpoint_available()
                        {
                            self.checkpoint_for_message(message_index)
                        } else {
                            None
                        };
                        {
                            let content = render_user_message_body(&message.text, &palette);
                            let edit_view = cx.entity().downgrade();
                            let restore_view = cx.entity().downgrade();
                            let edit_index = message_index;
                            let restore_index = message_index;
                            let (show_edit, show_restore) =
                                cgc_agent_ui::message_row::user_row_action_visibility(
                                    self.is_generating(),
                                    self.editing_user == Some(edit_index),
                                    restore_checkpoint.is_some(),
                                );
                            render_user_row(UserRowSpec {
                                row_id: SharedString::from(format!("native-user-{edit_index}")),
                                card_id: SharedString::from(format!(
                                    "native-user-card-{edit_index}"
                                )),
                                restore_id: SharedString::from(format!(
                                    "native-restore-checkpoint-{restore_index}"
                                )),
                                content,
                                show_edit,
                                show_restore,
                                style: native_row_palette(&palette),
                                on_edit: Box::new(move |window, cx| {
                                    let _ = edit_view.update(cx, |this, cx| {
                                        this.begin_edit_user(edit_index, window, cx);
                                    });
                                }),
                                on_restore: Box::new(move |_window, cx| {
                                    let _ = restore_view.update(cx, |this, cx| {
                                        this.restore_to_checkpoint(restore_index, cx);
                                    });
                                }),
                            })
                        }
                    }
                }
                ViewRole::Thinking => {
                    let expanded = self.expanded_thinking.contains(&message_index);
                    let toggle_view = cx.entity().downgrade();
                    render_thinking_row(ThinkingRowSpec {
                        row_id: SharedString::from(format!("native-thinking-{message_index}")),
                        toggle_id: SharedString::from(format!(
                            "native-thinking-toggle-{message_index}"
                        )),
                        markdown_id: SharedString::from(format!(
                            "native-thinking-markdown-{message_index}"
                        )),
                        markdown: message.text.clone(),
                        expanded,
                        style: native_message_style(palette),
                        on_toggle: Box::new(move |cx: &mut App| {
                            let _ = toggle_view
                                .update(cx, |this, cx| this.toggle_thinking(message_index, cx));
                        }),
                    })
                }
                ViewRole::Tool => match &message.tool {
                    Some(tool) => {
                        let tool_call_id = message.tool_call_id.clone().unwrap_or_default();
                        let expanded = self.expanded_tools.contains(&tool_call_id)
                            || matches!(tool.status, ViewToolStatus::Running);
                        let toggle_view = cx.entity().downgrade();
                        let toggle_id = tool_call_id.clone();
                        render_tool_card(tool, expanded, &palette, move |cx| {
                            let _ = toggle_view.update(cx, |this, cx| {
                                this.toggle_tool_call(toggle_id.clone(), cx)
                            });
                        })
                    }
                    None => div()
                        .text_size(px(13.0))
                        .child(message.text.clone())
                        .into_any_element(),
                },
                _ => render_status_row(StatusRowSpec {
                    row_id: SharedString::from(format!("native-status-{message_index}")),
                    label: matches!(message.role, ViewRole::System | ViewRole::Error)
                        .then(|| role_label(message.role).to_string()),
                    label_color: color,
                    text: message.text.clone(),
                    style: native_row_palette(&palette),
                }),
            })
            .context_menu(move |menu, _window, _cx| {
                render_native_message_menu(menu, menu_view.clone(), payloads.clone())
            })
            .children(self.sent_images.get(&message_index).map(|images| {
                div().flex().flex_row().flex_wrap().gap(space(1)).children(
                    images.iter().enumerate().map(|(image_index, image)| {
                        let preview = image.preview.clone();
                        let open_weak = cx.entity().downgrade();
                        let open_preview = image.preview.clone();
                        let open_name = image.name.clone();
                        let trigger = div()
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap(px(4.0))
                            .px(space(1))
                            .py(px(1.0))
                            .text_size(px(11.0))
                            .text_color(palette.ink_2)
                            .child(match image.preview.clone() {
                                Some(preview) => img(preview)
                                    .max_w(px(16.0))
                                    .max_h(px(16.0))
                                    .rounded(px(2.0))
                                    .into_any_element(),
                                None => "🖼".into_any_element(),
                            })
                            .child(image.name.clone())
                            .into_any_element();
                        div()
                            .id(SharedString::from(format!(
                                "native-msg-image-{message_index}-{image_index}"
                            )))
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap(px(4.0))
                            .px(space(1))
                            .py(px(1.0))
                            .rounded(px(RADIUS_SMALL))
                            .border_1()
                            .border_color(palette.line)
                            .text_size(px(11.0))
                            .text_color(palette.ink_2)
                            .on_click(move |_, _, cx| {
                                if let Some(preview) = open_preview.clone() {
                                    let name = open_name.clone();
                                    let _ = open_weak.update(cx, |this, cx| {
                                        this.open_image_viewer(name, preview, cx);
                                    });
                                }
                            })
                            .child(
                                HoverCard::new(SharedString::from(format!(
                                    "native-msg-image-hover-{message_index}-{image_index}"
                                )))
                                .anchor(Anchor::BottomCenter)
                                .open_delay(std::time::Duration::from_millis(80))
                                .trigger(trigger)
                                .content(move |_, _, _| {
                                    match preview.clone() {
                                        Some(preview) => div()
                                            .p(px(4.0))
                                            .rounded(px(RADIUS_SMALL))
                                            .border_1()
                                            .border_color(palette.line)
                                            .bg(palette.card)
                                            .child(
                                                img(preview)
                                                    .max_w(px(280.0))
                                                    .max_h(px(180.0))
                                                    .rounded(px(RADIUS_SMALL)),
                                            )
                                            .into_any_element(),
                                        None => div().child("无预览").into_any_element(),
                                    }
                                }),
                            )
                            .into_any_element()
                    }),
                )
            }))
            .into_any_element()
    }

    /// 当前流式思考行（默认展开，可折叠）。
    /// 失败回调行（带重试）。
    pub(super) fn render_error_row(
        &self,
        palette: theme::Palette,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let Some(error) = self.state.session.last_error.clone() else {
            return div().into_any_element();
        };
        let hint = retry_hint_for_error(&error);
        let can_retry = self.state.retry_available() && self.last_turn.is_some();
        let retry_view = cx.entity().downgrade();
        shared_render_error_row(ErrorRowSpec {
            row_id: SharedString::from("native-agent-error"),
            retry_id: SharedString::from("native-agent-retry"),
            message: error,
            hint: hint.map(str::to_string),
            can_retry,
            style: native_row_palette(&palette),
            on_retry: Box::new(move |cx: &mut App| {
                let _ = retry_view.update(cx, |this, cx| this.retry_last_turn(cx));
            }),
        })
    }

    /// 一组消息操作按钮（对齐 Zed：默认 40% 透明，hover 提亮）。
    ///
    /// gating 与复制内容来自 `agent_ui::message_flow`，与 ACP 栈共用同一份实现；
    /// 这里只负责 native 的渲染与元素 id。
    pub(super) fn render_message_actions(
        &self,
        id_prefix: &str,
        copy_text: Option<String>,
        plan: message_flow::ActionPlan,
        palette: theme::Palette,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let view = cx.entity().downgrade();
        let mut callbacks = ActionCallbacks::default();
        if let Some(copy_text) = copy_text {
            callbacks.on_copy = Some(Box::new(move |cx: &mut App| {
                cx.write_to_clipboard(ClipboardItem::new_string(copy_text.clone()));
            }));
        }
        if let Some(user_index) = plan.scroll_to_user {
            let user_view = view.clone();
            callbacks.on_scroll_user = Some(Box::new(move |cx: &mut App| {
                let _ =
                    user_view.update(cx, |this, cx| this.scroll_to_user_message(user_index, cx));
            }));
        }
        if plan.scroll_to_top {
            let top_view = view;
            callbacks.on_scroll_top = Some(Box::new(move |cx: &mut App| {
                let _ = top_view.update(cx, |this, cx| this.scroll_messages_to_top(cx));
            }));
        }
        // 共享渲染：本函数只组装 spec 与回调（P9）。
        render_action_bar(native_action_bar_spec(
            id_prefix,
            native_action_style(palette),
            native_action_glyphs(),
            callbacks,
        ))
    }

    /// 滚到指定用户消息（再映射到 MessageScroller 的 item index）。
    pub(super) fn scroll_to_user_message(&mut self, user_index: usize, cx: &mut Context<Self>) {
        let kinds = self.message_row_kinds();
        if let Some(row) = kinds
            .iter()
            .position(|kind| *kind == MessageRowKind::Message(user_index))
        {
            self.message_scroller.update(cx, |state, cx| {
                let _ = state.scroll_to_item(row, cx);
            });
            cx.notify();
        }
    }

    /// 线程末尾兜底操作栏：回合停在工具卡等非 assistant 行时，在底部补一条
    /// （对齐 Zed #61245 的 last-assistant fallback）。
    pub(super) fn render_trailing_actions(
        &self,
        palette: theme::Palette,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let Some(plan) = self.state.session.thread.row_view().trailing_plan(
            self.is_generating(),
            self.state.session.thread.pending_permission.is_some(),
        ) else {
            return div().into_any_element();
        };
        self.render_message_actions(
            "native-trailing-actions",
            self.state
                .session
                .thread
                .row_view()
                .turn_copy_text(plan.assistant_index),
            message_flow::ActionPlan {
                scroll_to_user: plan.scroll_to_user,
                scroll_to_top: true,
            },
            palette,
            cx,
        )
    }

    /// 消息区当前的行序列（历史消息 + 内联子 agent + 流式/错误行 + 兜底操作栏）。
    pub(super) fn message_row_kinds(&self) -> Vec<MessageRowKind> {
        let subagents = subagent_cards_for_rows(
            self.state.session.thread.capabilities.subagent_available(),
            &self.state.subagents,
        );
        let mut kinds = build_message_row_kinds(
            &self.state.session.thread.entries,
            subagents,
            self.state.session.last_error.is_some(),
        );
        if self
            .state
            .session
            .thread
            .row_view()
            .trailing_plan(
                self.is_generating(),
                self.state.session.thread.pending_permission.is_some(),
            )
            .is_some()
        {
            kinds.push(MessageRowKind::TrailingActions);
        }
        kinds
    }

    /// 行数变化时增量增删列表行；行高变化时只 remeasure 对应行。
    pub(super) fn sync_message_scroller(
        &mut self,
        row_kinds: &[MessageRowKind],
        cx: &mut Context<Self>,
    ) {
        let desired = row_kinds.len();
        let current = self.message_scroller.read(cx).item_count();
        let signatures: Vec<u64> = row_kinds
            .iter()
            .map(|kind| self.message_row_signature(*kind))
            .collect();
        if desired > current {
            self.message_scroller
                .update(cx, |state, cx| state.append(desired - current, cx));
            if current == 0 {
                // 首次填充（打开线程/启动恢复）：Tail 跟随可能被开窗时的
                // bounce/scroll 事件打断，显式滚到底并重新开启跟随。
                self.message_scroller
                    .update(cx, |state, cx| state.scroll_to_end(cx));
            }
        } else if desired < current {
            self.message_scroller
                .update(cx, |state, cx| state.splice(desired..current, 0, cx));
        } else if self.message_row_signatures.len() == signatures.len() {
            for (index, (new, old)) in signatures
                .iter()
                .zip(self.message_row_signatures.iter())
                .enumerate()
            {
                if new != old {
                    self.message_scroller.update(cx, |state, cx| {
                        let _ = state.remeasure_items(index..index + 1, cx);
                    });
                }
            }
        }
        self.message_row_signatures = signatures;
    }

    /// 行高签名：只含影响布局的字段，避免流式 token 触发全表重测。
    pub(super) fn message_row_signature(&self, kind: MessageRowKind) -> u64 {
        use std::hash::{Hash as _, Hasher as _};
        let mut hasher = std::collections::hash_map::DefaultHasher::new();
        match kind {
            MessageRowKind::Message(index) => {
                0u8.hash(&mut hasher);
                if let Some(entry) = self.state.session.thread.entries.get(index) {
                    let row = ViewRow::from_entry(entry);
                    format!("{:?}", row.role).hash(&mut hasher);
                    row.text.len().hash(&mut hasher);
                    self.expanded_thinking.contains(&index).hash(&mut hasher);
                    (self.editing_user == Some(index)).hash(&mut hasher);
                    row.tool_call_id.hash(&mut hasher);
                    let tool_expanded = row
                        .tool_call_id
                        .as_deref()
                        .is_some_and(|id| self.expanded_tools.contains(id));
                    tool_expanded.hash(&mut hasher);
                    self.sent_images
                        .get(&index)
                        .map(|images| images.len())
                        .hash(&mut hasher);
                }
            }
            MessageRowKind::Subagent(index) => {
                1u8.hash(&mut hasher);
                if let Some(card) = self.state.subagents.get(index) {
                    card.text.len().hash(&mut hasher);
                    card.finished.hash(&mut hasher);
                }
            }
            MessageRowKind::Error => {
                4u8.hash(&mut hasher);
                self.state
                    .session
                    .last_error
                    .as_ref()
                    .map(String::len)
                    .hash(&mut hasher);
                self.state.retry_available().hash(&mut hasher);
            }
            MessageRowKind::TrailingActions => {
                5u8.hash(&mut hasher);
            }
        }
        hasher.finish()
    }

    /// 分发一行到对应的渲染函数。
    pub(super) fn render_message_row(
        &self,
        kind: MessageRowKind,
        menu_root: &WeakEntity<Self>,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let palette = theme::palette_from_theme(cx);
        match kind {
            MessageRowKind::Message(index) => {
                self.render_message_row_element(index, palette, menu_root, cx)
            }
            MessageRowKind::Subagent(index) => self
                .state
                .subagents
                .get(index)
                .map(|card| render_subagent_row(card, &palette))
                .unwrap_or_else(|| div().into_any_element()),
            MessageRowKind::Error => self.render_error_row(palette, cx),
            MessageRowKind::TrailingActions => self.render_trailing_actions(palette, cx),
        }
    }
}
