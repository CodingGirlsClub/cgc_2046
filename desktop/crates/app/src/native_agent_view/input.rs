//! 输入编辑：mention/slash 插入与 user 消息编辑（B4b 结构拆分第五片）。
//!
//! 子模块可直接访问父模块私有字段。

use super::*;

impl NativeAgentView {
    pub(super) fn mention_matches(&self, query: &str) -> Vec<String> {
        mention_matches(&self.workspace_files, query)
    }

    pub(super) fn insert_mention(
        &mut self,
        path: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let value = self.input.read(cx).value().to_string();
        if let Some((position, _)) = trailing_mention(&value) {
            let mention = Mention::File { path };
            self.insert_mention_chip(mention, &value[..position], window, cx);
        }
        self.mention_index = 0;
        cx.notify();
    }

    pub(super) fn insert_skill_mention(
        &mut self,
        skill: SkillEntry,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let mention = Mention::skill(&skill);
        self.insert_mention_chip(mention, "", window, cx);
        self.slash_dismissed = true;
        self.slash_index = 0;
        cx.notify();
    }

    /// 把 mention 作为原子 chip 写进输入框（链接文本 + inline token），光标落到末尾。
    pub(super) fn insert_mention_chip(
        &mut self,
        mention: Mention,
        prefix: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let content = mention.content_at(prefix, " ");
        let text = content.text().to_string();
        let end = Position::new(
            text.matches('\n').count() as u32,
            text.rsplit('\n').next().unwrap_or_default().chars().count() as u32,
        );
        self.input.update(cx, |state, cx| {
            state.set_value(content, window, cx);
            state.set_cursor_position(end, window, cx);
        });
        self.mention_index = 0;
        cx.notify();
    }

    pub(super) fn slash_entries(&self, value: &str) -> Vec<SlashEntry> {
        slash_entries_for(
            self.metadata()
                .schemas
                .iter()
                .map(|schema| (schema.name.as_str(), schema.description.as_str())),
            &self.skills,
            value,
        )
    }

    pub(super) fn run_slash_entry(
        &mut self,
        entries: Vec<SlashEntry>,
        index: usize,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(entry) = entries.get(index) else {
            return;
        };
        if let Some(tool) = entry.tool.clone() {
            let text = format!("使用 {tool} 工具：");
            self.input
                .update(cx, |state, cx| state.set_value(text.clone(), window, cx));
            self.slash_dismissed = true;
            self.slash_index = 0;
            cx.notify();
            return;
        }
        if let Some(skill) = entry.skill.clone() {
            self.insert_skill_mention(skill, window, cx);
            return;
        }
        self.run_slash_command(&entry.label, window, cx);
    }

    pub(super) fn run_slash_command(
        &mut self,
        command: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if let Some(command) = parse_slash(command) {
            self.handle_slash(command, cx);
        }
        self.input
            .update(cx, |state, cx| state.set_value("", window, cx));
        self.slash_index = 0;
        self.slash_dismissed = false;
        cx.notify();
    }

    /// 进入某条用户消息的行内编辑态（预填展示文本）。
    pub(super) fn begin_edit_user(
        &mut self,
        message_index: usize,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.is_generating() {
            self.status = "生成中，稍后再编辑".to_string();
            cx.notify();
            return;
        }
        let Some(ConversationEntry::User { text }) =
            self.state.session.thread.entries.get(message_index)
        else {
            return;
        };
        let text = text.clone();
        let skills = self.skills.clone();
        let input = cx.new(|cx| {
            let mut state = TextareaState::new(window, cx).auto_grow(1, 8);
            let content = mention::content_with_mentions(&text, |scope, name| {
                skills
                    .iter()
                    .find(|skill| skill.name == name && skill.scope == scope)
                    .map(|skill| skill.file_path.clone())
            });
            state.set_value(content, window, cx);
            state
        });
        let original = input.read(cx).content().text().to_string();
        self.pending_restart_confirm = None;
        // 点击消息气泡后直接进入可输入状态（对齐 Zed 的行内编辑，不用再点一次）。
        let focus = input.read(cx).focus_handle(cx);
        // Zed 语义：点击消息之外的地方（编辑器失焦）退出编辑。这里延迟一拍，
        // 避免点 X/✓ 时先因失焦清掉编辑态，导致按钮回调读不到输入。
        let serial = self.edit_serial.wrapping_add(1);
        self.edit_serial = serial;
        self.user_edit_subscription = Some(cx.on_blur(&focus, window, move |this, _window, cx| {
            this.schedule_edit_cancel(serial, cx);
        }));
        let enter_index = message_index;
        self.user_edit_key_subscription = Some(cx.subscribe(
            &input,
            move |this, _state, event: &InputEvent, cx| {
                if let InputEvent::PressEnter { shift, .. } = event {
                    if !shift {
                        this.restart_from_user_message(enter_index, cx);
                    }
                }
            },
        ));
        window.focus(&focus, cx);
        self.user_edit_input = Some(input);
        self.edit_original = Some(original);
        self.editing_user = Some(message_index);
        cx.notify();
    }

    /// 失焦后延迟取消编辑；串行号变化（新编辑/已取消）时放弃，避免误杀。
    fn schedule_edit_cancel(&mut self, serial: u64, cx: &mut Context<Self>) {
        cx.spawn(async move |view, cx| {
            cx.background_executor()
                .timer(std::time::Duration::from_millis(80))
                .await;
            let _ = view.update(cx, |this, cx| {
                // 无 checkpoint 的确认面板需要保持编辑态，等用户确认。
                let unchanged = this
                    .user_edit_input
                    .as_ref()
                    .zip(this.edit_original.as_ref())
                    .is_some_and(|(input, original)| {
                        input.read(cx).content().text().as_str() == original.as_str()
                    });
                if should_cancel_edit_on_blur(
                    this.edit_serial,
                    serial,
                    this.pending_restart_confirm.is_some(),
                    unchanged,
                ) {
                    this.cancel_edit_user(cx);
                }
            });
        })
        .detach();
    }

    pub(super) fn cancel_edit_user(&mut self, cx: &mut Context<Self>) {
        self.editing_user = None;
        self.user_edit_input = None;
        self.edit_serial = self.edit_serial.wrapping_add(1);
        self.edit_original = None;
        self.user_edit_subscription = None;
        self.user_edit_key_subscription = None;
        self.pending_restart_confirm = None;
        cx.notify();
    }

    /// Rewind succeeds in the owner before the edited message is submitted.
    pub(super) fn restart_from_user_message(&mut self, index: usize, cx: &mut Context<Self>) {
        if self.is_generating() {
            self.status = "生成中，稍后再试".into();
            cx.notify();
            return;
        }
        let Some(input) = &self.user_edit_input else {
            return;
        };
        let content = input.read(cx).content();
        let display = content.text().trim().to_string();
        if display.is_empty() {
            self.status = "消息不能为空".into();
            cx.notify();
            return;
        }
        let Some(ordinal) = thread_entry_ordinal(&self.state.session.thread.entries, index) else {
            return;
        };
        let restore_files = self.checkpoint_for_message(index).is_some();
        if needs_checkpoint_confirm(restore_files, self.pending_restart_confirm, index) {
            self.pending_restart_confirm = Some(index);
            cx.notify();
            return;
        }
        let prompt = mention::resolve_prompt(&content, &self.metadata().workspace);
        let context = self.page_context.visible();
        let runtime = self.runtime.clone();
        let thread_id = self.metadata().thread.id.clone();
        let rewind = self
            .runtime
            .rewind_thread(thread_id.clone(), ordinal, restore_files);
        let generation = self.state.session.generation;
        cx.spawn(async move |this, cx| {
            // 旧实现是「检查点尽力回滚，失败不阻断重发」；单 actor 重构后
            // runtime.rewind 遇到失效 checkpoint 会直接报错，编辑重发就整条
            // 停住。这里保留旧语义：文件回滚失败时退回只回滚对话再重发。
            let mut fallback_note = None;
            let result = match rewind.await {
                Ok(snapshot) => Ok(snapshot),
                Err(first_error) if restore_files => match runtime
                    .rewind_thread(thread_id.clone(), ordinal, false)
                    .await
                {
                    Ok(snapshot) => {
                        fallback_note =
                            Some(format!("检查点无法回滚，已仅回滚对话：{first_error}"));
                        Ok(snapshot)
                    }
                    Err(_) => Err(first_error),
                },
                Err(error) => Err(error),
            };
            let _ = this.update(cx, |this, cx| match result {
                Ok(snapshot) => {
                    if this.metadata().thread.id != thread_id
                        || this.metadata().revision > snapshot.revision
                    {
                        return;
                    }
                    this.apply_snapshot(RuntimeChange::Rewound, snapshot, cx);
                    if let Some(note) = fallback_note {
                        this.status = note.clone();
                        this.state.push_notice(note);
                    }
                    let (prompt, context) =
                        this.page_context
                            .freeze_page(this.conversation_scope(), prompt, context);
                    let submission =
                        this.state
                            .session
                            .submission(display, prompt, context, Vec::new(), false);
                    this.state.session.queue.push(submission);
                    this.state.session.queue_mode = QueueMode::Auto;
                    this.dispatch_queued(cx);
                }
                Err(error) if this.state.session.generation == generation => {
                    this.status = error.to_string();
                    this.state.push_notice(error.to_string());
                    cx.notify();
                }
                Err(_) => {}
            });
        })
        .detach();
    }

    /// 编辑态行内编辑器。
    pub(super) fn render_user_edit_row(
        &self,
        message_index: usize,
        palette: &theme::Palette,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let Some(input) = self.user_edit_input.clone() else {
            return div().into_any_element();
        };
        let view = cx.entity().downgrade();
        let cancel_view = view.clone();
        let resend_view = view.clone();
        let confirm_cancel_view = view.clone();
        let confirm_resend_view = view;
        shared_render_user_edit_row(UserEditRowSpec {
            input,
            cancel_id: SharedString::from("native-user-edit-cancel"),
            resend_id: SharedString::from("native-user-edit-resend"),
            confirm_cancel_id: SharedString::from("native-restart-cancel"),
            confirm_resend_id: SharedString::from("native-restart-confirm"),
            pending_confirm: user_edit_confirm_visible(self.pending_restart_confirm, message_index),
            style: native_row_palette(palette),
            on_cancel: Box::new(move |cx| {
                let _ = cancel_view.update(cx, |this, cx| this.cancel_edit_user(cx));
            }),
            on_resend: Box::new(move |cx| {
                let _ = resend_view.update(cx, |this, cx| {
                    this.restart_from_user_message(message_index, cx)
                });
            }),
            on_confirm_cancel: Box::new(move |cx| {
                let _ = confirm_cancel_view.update(cx, |this, cx| {
                    this.pending_restart_confirm = None;
                    cx.notify();
                });
            }),
            on_confirm_resend: Box::new(move |cx| {
                let _ = confirm_resend_view.update(cx, |this, cx| {
                    this.restart_from_user_message(message_index, cx)
                });
            }),
        })
    }

    /// 展开/折叠一条思考块。
    pub(super) fn toggle_thinking(&mut self, message_index: usize, cx: &mut Context<Self>) {
        if !self.expanded_thinking.remove(&message_index) {
            self.expanded_thinking.insert(message_index);
        }
        cx.notify();
    }

    /// 展开/折叠某张工具调用卡片。
    pub(super) fn toggle_tool_call(&mut self, tool_call_id: String, cx: &mut Context<Self>) {
        if !self.expanded_tools.remove(&tool_call_id) {
            self.expanded_tools.insert(tool_call_id);
        }
        cx.notify();
    }
}

/// 失焦延迟任务是否应取消编辑（对齐 Zed `LostFocus`）：
/// 编辑版本未变、没有等待确认的重发面板，且内容未被修改。
fn should_cancel_edit_on_blur(
    current_serial: u64,
    edit_serial: u64,
    pending_confirm: bool,
    content_unchanged: bool,
) -> bool {
    current_serial == edit_serial && !pending_confirm && content_unchanged
}

#[cfg(test)]
mod tests {
    // 显式导入，避免 glob 链在 rustc 展开测试宏时触发 SIGBUS。
    use super::should_cancel_edit_on_blur;

    #[test]
    fn blur_cancel_requires_same_edit_no_confirm_and_unchanged_content() {
        assert!(should_cancel_edit_on_blur(7, 7, false, true));
        assert!(
            !should_cancel_edit_on_blur(8, 7, false, true),
            "重新进入编辑后，旧失焦任务不得取消新编辑"
        );
        assert!(
            !should_cancel_edit_on_blur(7, 7, true, true),
            "无 checkpoint 确认面板期间保持编辑态"
        );
        assert!(
            !should_cancel_edit_on_blur(7, 7, false, false),
            "已修改内容时点外部保留草稿，避免丢字"
        );
    }
}
