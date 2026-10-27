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
        self.pending_restart_confirm = None;
        self.user_edit_input = Some(input);
        self.editing_user = Some(message_index);
        cx.notify();
    }

    pub(super) fn cancel_edit_user(&mut self, cx: &mut Context<Self>) {
        self.editing_user = None;
        self.user_edit_input = None;
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
        let (prompt, context) = self.page_context.freeze(prompt);
        let rewind = self.runtime.rewind(ordinal, restore_files);
        let generation = self.state.session.generation;
        cx.spawn(async move |this, cx| {
            let result = rewind.await;
            let _ = this.update(cx, |this, cx| match result {
                Ok(snapshot) => {
                    this.apply_snapshot(RuntimeChange::Rewound, snapshot, cx);
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
