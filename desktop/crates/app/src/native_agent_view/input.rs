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
        slash_entries_for(self.registry.as_ref(), &self.skills, value)
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
        if self.busy {
            self.status = "生成中，稍后再编辑".to_string();
            cx.notify();
            return;
        }
        let Some(ConversationEntry::User { text }) = self.state.thread.entries.get(message_index)
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

    /// 从某条用户消息重发（Zed 的 restart from this point）：回滚 checkpoint、
    /// 截断线程到该消息之前，然后用编辑后的文本重跑这一轮。
    pub(super) fn restart_from_user_message(
        &mut self,
        message_index: usize,
        cx: &mut Context<Self>,
    ) {
        if self.busy {
            self.status = "生成中，稍后再试".to_string();
            cx.notify();
            return;
        }
        let Some(input) = self.user_edit_input.clone() else {
            return;
        };
        let content = input.read(cx).content();
        let edited_display = content.text().trim().to_string();
        if edited_display.is_empty() {
            self.status = "消息不能为空".to_string();
            cx.notify();
            return;
        }
        let edited_prompt = mention::resolve_prompt(&content, self.context.workspace());
        let Some(ordinal) = thread_entry_ordinal(&self.state.thread.entries, message_index) else {
            return;
        };
        let has_valid_checkpoint = self
            .available_checkpoints
            .iter()
            .find(|(candidate, _)| *candidate == ordinal)
            .map(|(_, checkpoint)| {
                self.checkpoint_manager
                    .as_ref()
                    .and_then(|manager| manager.is_valid(checkpoint).ok())
                    .unwrap_or(false)
            })
            .unwrap_or(false);
        if needs_checkpoint_confirm(
            has_valid_checkpoint,
            self.pending_restart_confirm,
            message_index,
        ) {
            self.pending_restart_confirm = Some(message_index);
            cx.notify();
            return;
        }
        self.pending_restart_confirm = None;
        let Some(agent) = self.agent.as_mut() else {
            return;
        };
        let thread_id = agent.thread().id.clone();
        let Some(entry_index) = thread_user_entry_index(&agent.thread().entries, ordinal) else {
            self.status = "找不到对应的线程消息".to_string();
            cx.notify();
            return;
        };
        // checkpoint 回滚（尽力而为；失败只提示，不阻断重发）。
        let mut note = String::new();
        if let (Some(manager), Some(store)) =
            (&self.checkpoint_manager, self.session_store.session())
        {
            if let Ok(records) = store.list_checkpoints(&thread_id) {
                if let Some(record) = checkpoint_for_ordinal(&records, ordinal) {
                    let checkpoint = Checkpoint {
                        thread_id: record.thread_id,
                        seq: record.user_entry_seq.max(0) as u64,
                        ref_name: record.ref_name,
                        sha: record.sha,
                        base_head: record.base_head,
                    };
                    match manager.is_valid(&checkpoint) {
                        Ok(true) => match manager.restore(&checkpoint) {
                            Ok(()) => note = " · 已回滚到该消息的 checkpoint".to_string(),
                            Err(error) => note = format!(" · checkpoint 回滚失败：{error}"),
                        },
                        Ok(false) => note = " · checkpoint 已失配，未回滚文件".to_string(),
                        Err(error) => note = format!(" · checkpoint 校验失败：{error}"),
                    }
                }
            }
        }
        agent.thread_mut().entries.truncate(entry_index);
        self.editing_user = None;
        self.user_edit_input = None;
        self.rebuild_state_from_thread();
        self.invalidate_checkpoints_from(ordinal + 1, &thread_id);
        // 截断到空历史时 rebuild 会补一条引导提示；重发场景不需要它。
        self.state.thread.entries.retain(|entry| {
            !matches!(entry, ConversationEntry::Notice { text, .. } if text == EMPTY_THREAD_NOTICE)
        });
        self.state.thread.apply(ThreadEvent::TurnStarted {
            user_text: edited_display.clone(),
        });
        self.state.last_error = None;
        self.last_turn = Some((edited_prompt.clone(), edited_display.clone()));
        let ordinal = self
            .state
            .thread
            .entries
            .iter()
            .filter(|entry| matches!(entry, ConversationEntry::User { .. }))
            .count();
        self.capture_checkpoint(&thread_id, ordinal);
        self.status = format!("从该消息重发{note}");
        self.run_turn(edited_prompt, edited_display, true, cx);
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
