//! 运行时装配与 checkpoint 操作（B4b-a：从视图模块移出，行为不变）。
//!
//! 子模块可直接访问父模块私有字段。

use super::*;

impl NativeAgentView {
    pub(super) fn drain_app_actions(&mut self, cx: &mut Context<Self>) {
        let actions = self
            .app_actions
            .lock()
            .map(|mut actions| std::mem::take(&mut *actions))
            .unwrap_or_default();
        for action in actions {
            let summary = action.summary();
            let mut dispatched = false;
            let workspace = self.context.workspace().to_path_buf();
            for window in cx.windows() {
                if let Some(root) = window.downcast::<crate::root_view::RootView>() {
                    let _ = root.update(cx, |root, _window, cx| {
                        root.apply_native_agent_action(action.clone(), workspace.clone(), cx);
                    });
                    dispatched = true;
                    break;
                }
            }
            if let Some(log) = &self.host.action_audit {
                let action_name = match &action {
                    AppAction::OpenPage { .. } => "open_page",
                    AppAction::HighlightRange { .. } => "highlight_range",
                };
                let _ = log.append(&ActionAuditEntry {
                    at: now_secs(),
                    action: action_name.to_string(),
                    detail: summary.clone(),
                    dispatched,
                });
            }
            self.state.push_notice(if dispatched {
                format!("已执行：{summary}")
            } else {
                summary
            });
        }
    }

    pub(super) fn keep_all_changes(&mut self, cx: &mut Context<Self>) {
        self.checkpoint_changes.clear();
        self.status = "已全部保留本轮改动".to_string();
        cx.notify();
    }

    pub(super) fn reject_all_changes(&mut self, cx: &mut Context<Self>) {
        let paths = paths_for_restore_all(&self.checkpoint_changes);
        for path in &paths {
            self.restore_checkpoint_file(path.clone(), cx);
        }
        self.status = format!("已回退 {} 个文件", paths.len());
        self.checkpoint_changes.clear();
        cx.notify();
    }

    pub(super) fn refresh_checkpoint_changes(&mut self) {
        self.checkpoint_changes = match (&self.checkpoint_manager, &self.last_checkpoint) {
            (Some(manager), Some(checkpoint)) => {
                manager.changed_files(checkpoint).unwrap_or_default()
            }
            _ => Vec::new(),
        };
    }

    pub(super) fn toggle_checkpoint_panel(&mut self, cx: &mut Context<Self>) {
        self.show_checkpoint_panel = !self.show_checkpoint_panel;
        cx.notify();
    }

    pub(super) fn keep_checkpoint_file(&mut self, path: String, cx: &mut Context<Self>) {
        keep_change_by_path(&mut self.checkpoint_changes, &path);
        cx.notify();
    }

    pub(super) fn restore_checkpoint_file(&mut self, path: String, cx: &mut Context<Self>) {
        let Some(checkpoint) = self.last_checkpoint.clone() else {
            return;
        };
        let Some(manager) = &self.checkpoint_manager else {
            return;
        };
        if !manager.is_valid(&checkpoint).unwrap_or(false) {
            self.status = "checkpoint 已失配（HEAD 有变化），请重新初始化".to_string();
            cx.notify();
            return;
        }
        match manager.restore_file(&checkpoint, &path) {
            Ok(()) => {
                self.status = format!("已回退 {path}");
                self.refresh_checkpoint_changes();
            }
            Err(error) => self.status = format!("回退失败：{error}"),
        }
        cx.notify();
    }

    /// 切换到指定 provider 的指定模型；模型变化时换新 thread。
    pub(super) fn select_model(
        &mut self,
        provider_id: String,
        model_id: String,
        cx: &mut Context<Self>,
    ) {
        self.host.set_selected_model(SelectedModel::new(
            ProviderId::new(provider_id.clone()),
            cgc_agent_provider::ModelId::new(model_id.clone()),
        ));
        let Some(provider) = self
            .providers
            .iter()
            .find(|provider| provider.id == provider_id)
            .cloned()
        else {
            return;
        };
        let api_key = self
            .keychain
            .as_ref()
            .and_then(|keychain| keychain.load_secret(&provider_key_account(&provider.id)));
        let model_config = provider.model_config(&model_id);
        let model = Model::new(
            ProviderId::new(provider.id.clone()),
            provider.name.clone(),
            model_id.clone(),
            model_id,
            ModelLimits::new(model_config.context_window, model_config.max_output_tokens),
        );
        self.provider = match api_key.filter(|key| !key.is_empty()) {
            Some(api_key) => Arc::new(OpenAiCompatibleProvider::new(OpenAiCompatibleConfig::new(
                provider.base_url.clone(),
                api_key,
                vec![model.clone()],
            ))),
            None => Arc::new(EchoProvider::new(model.clone())),
        };
        let changed = self.model != model;
        self.model = model;
        if changed {
            if let Some(agent) = &mut self.agent {
                agent.replace_thread(Thread::new(
                    format!("native-demo-{}", now_secs()),
                    SelectedModel::new(self.model.provider_id.clone(), self.model.id.clone()),
                ));
            }
            self.rebuild_state_from_thread();
        }
        let store = PrefsStore::new(AppPaths::from_env().agent_prefs_file());
        let mut prefs = store.load();
        prefs.selected_provider = Some(provider.id);
        prefs.selected_model = Some(SelectedModel::new(
            self.model.provider_id.clone(),
            self.model.id.clone(),
        ));
        let _ = store.save(&prefs);
        self.status = format!("模型：{}", self.model.id.as_str());
        cx.notify();
    }

    /// 当前滚动位置是否已在底部。
    /// 消息区滚动到顶部（同时停止自动跟随输出）。
    pub(super) fn scroll_messages_to_top(&mut self, cx: &mut Context<Self>) {
        self.message_scroller.update(cx, |state, cx| {
            let _ = state.scroll_to_item(0, cx);
        });
        cx.notify();
    }

    /// 回到最新：恢复 tail 跟随并滚到列表末尾。
    pub(super) fn scroll_messages_to_bottom(&mut self, cx: &mut Context<Self>) {
        self.message_scroller
            .update(cx, |state, cx| state.scroll_to_end(cx));
        cx.notify();
    }

    pub(super) fn set_thinking_enabled(&mut self, enabled: bool, cx: &mut Context<Self>) {
        self.thinking_enabled = enabled;
        self.status = if enabled {
            "Thinking 开".to_string()
        } else {
            "Thinking 关".to_string()
        };
        cx.notify();
    }

    pub(super) fn insert_context_marker(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let current = self.input.read(cx).value().to_string();
        let next = if current.trim().is_empty() {
            "@".to_string()
        } else if current.ends_with(char::is_whitespace) {
            format!("{current}@")
        } else {
            format!("{current} @")
        };
        self.input
            .update(cx, |state, cx| state.set_value(next, window, cx));
        self.status = "输入 @ 引用工作区文件".to_string();
        cx.notify();
    }

    pub(super) fn set_effort_index(&mut self, index: usize, cx: &mut Context<Self>) {
        self.effort_index = index;
        self.status = format!("推理档位索引：{index}");
        cx.notify();
    }

    pub(super) fn set_approval_mode(&mut self, mode: ApprovalMode, cx: &mut Context<Self>) {
        self.approval_mode = mode;
        self.status = format!("审批模式：{}", mode.label());
        cx.notify();
    }

    /// Agent Panel 里点「新对话」：开一个新的 native 会话（不动外部 ACP 会话）。
    pub fn start_new_thread(&mut self, cx: &mut Context<Self>) {
        if self.busy {
            return;
        }
        let thread_id = scope_thread_id(&self.scope);
        let model = self.model.clone();
        if let Some(agent) = &mut self.agent {
            agent.replace_thread(Thread::new(
                thread_id.clone(),
                SelectedModel::new(model.provider_id.clone(), model.id.clone()),
            ));
        }
        // 新会话复用 scope 线程 id，旧 checkpoint 记录必须作废。
        for (ordinal, _) in &self.available_checkpoints {
            let _ = self
                .session_store
                .mark_checkpoint_invalid(&thread_id, *ordinal as i64);
        }
        if let (Some(store), Some(agent)) = (self.session_store.session_mut(), &self.agent) {
            let _ = store.save_thread(agent.thread());
        }
        self.state = NativeThreadState::new();
        self.state
            .push_notice("Native agent：新对话，配置 Provider 后开始。");
        self.last_checkpoint = None;
        self.available_checkpoints.clear();
        self.checkpoint_changes.clear();
        self.show_checkpoint_panel = false;
        self.pending_restart_confirm = None;
        self.status = "新对话".to_string();
        cx.notify();
    }

    /// 渲染前同步全局 scope；变化时切换工作区与线程。
    pub(super) fn ensure_scope(&mut self, cx: &mut Context<Self>) {
        if self.busy {
            return;
        }
        let Some(current) = crate::agent_scope::current() else {
            return;
        };
        if current == self.scope {
            return;
        }
        self.switch_scope(current, cx);
    }

    pub(super) fn action_sink_for(&self) -> ActionSink {
        let app_actions = self.app_actions.clone();
        Arc::new(move |action: AppAction| {
            if let Ok(mut actions) = app_actions.lock() {
                actions.push(action);
            }
        })
    }

    pub(super) fn build_registry_for(&self, workspace: &std::path::Path) -> Arc<ToolRegistry> {
        let provider = self.provider.clone();
        let model = self.model.clone();
        let workspace = workspace.to_path_buf();
        let subagent_runner: SubagentRunner =
            Arc::new(move |request: SubagentRequest, events: SubagentEventSink| {
                let provider = provider.clone();
                let model = model.clone();
                let workspace = workspace.clone();
                Box::pin(async move {
                    run_subagent(
                        provider,
                        model,
                        request.task,
                        request.system_prompt,
                        workspace,
                        events,
                    )
                    .await
                    .map_err(|error| error.to_string())
                })
            });
        let subagent_tx = self.subagent_tx.clone();
        let subagent_sink: SubagentEventSink = Arc::new(move |event: SubagentEvent| {
            let agent_event = match event {
                SubagentEvent::Started { task } => AgentEvent::SubagentStarted { task },
                SubagentEvent::TextDelta { text } => AgentEvent::SubagentProgress { text },
                SubagentEvent::Finished { ok } => AgentEvent::SubagentFinished { ok },
            };
            if let Ok(slot) = subagent_tx.lock() {
                if let Some(sender) = slot.as_ref() {
                    let _ = sender.unbounded_send(agent_event);
                }
            }
        });
        let mut registry = ToolRegistry::with_agent_state(self.host.agent_state.clone())
            .with_app_actions()
            .with_subagent(subagent_runner, subagent_sink);
        let _mcp_tools =
            crate::native_panel_host::register_mcp_tools_for_host(&mut registry, &self.host);
        Arc::new(registry)
    }

    /// 切换工作区 scope：保存当前线程，载入目标 scope 的线程并重建运行时。
    pub(super) fn switch_scope(
        &mut self,
        scope: crate::agent_scope::AgentScope,
        cx: &mut Context<Self>,
    ) {
        if let (Some(store), Some(agent)) = (self.session_store.session_mut(), &self.agent) {
            let _ = store.save_thread(agent.thread());
        }
        let root = scope.root.clone();
        let thread_id = scope_thread_id(&scope);
        let selected = SelectedModel::new(self.model.provider_id.clone(), self.model.id.clone());
        let thread = self
            .session_store
            .load_thread(&thread_id)
            .filter(|thread| thread.model == selected)
            .unwrap_or_else(|| Thread::new(thread_id.clone(), selected));
        let mut state = NativeThreadState::new();
        let restored_images = apply_thread_entries(&mut state, &thread.entries);
        state.usage_total = thread.usage_total;
        state.thread.thread_id = thread.id.clone();
        state.set_context_size(self.model_context_size());
        state.thread.usage = Usage {
            used: thread.usage_total.total(),
            size: self.model_context_size(),
            cost: None,
        };
        if state.thread.entries.is_empty() {
            if let Some(notice) = offline_echo_notice(self.using_echo) {
                state.push_notice(notice);
            }
        }
        self.state = state;
        self.sent_images = restored_images;
        self.workspace_files = collect_workspace_files(&root);
        self.skills = mention::load_skills(&root);
        self.scope = scope;
        self.checkpoint_manager = CheckpointManager::open(&root)
            .or_else(|_| CheckpointManager::initialize(&root))
            .ok();
        self.context = ToolContext::new(&root)
            .with_sandbox(SandboxPolicy::new(&root))
            .with_action_sink(self.action_sink_for());
        self.agent = Some(Agent::new(
            thread,
            Some(build_workspace_system_prompt(&root)),
        ));
        self.registry = self.build_registry_for(&root);
        self.expanded_tools.clear();
        self.expanded_thinking.clear();
        self.editing_user = None;
        self.user_edit_input = None;
        self.last_turn = None;
        self.queued_messages.clear();
        self.checkpoint_changes.clear();
        self.show_checkpoint_panel = false;
        self.pending_restart_confirm = None;
        self.checkpoint_notice_reported = false;
        self.available_checkpoints.clear();
        self.last_checkpoint = None;
        self.pending_images.clear();
        self.busy = false;
        self.status = format!("已切换工作区：{}", root.display());
        self.reload_thread_checkpoints();
        cx.notify();
    }

    /// 从 SQLite 拉取当前 scope 线程的最新内容，保持内联/独立窗口共享同一份历史。
    pub(super) fn reload_latest_session(&mut self) {
        let Some(agent) = &self.agent else {
            return;
        };
        let Some(store) = self.session_store.session() else {
            return;
        };
        let thread_id = agent.thread().id.clone();
        let Ok(Some(loaded)) = store.load_thread(&thread_id) else {
            return;
        };
        if loaded.model != agent.thread().model || &loaded == agent.thread() {
            return;
        }
        if loaded.updated_at < agent.thread().updated_at {
            return;
        }
        if let Some(agent) = &mut self.agent {
            agent.replace_thread(loaded);
        }
        self.rebuild_state_from_thread();
    }

    pub(super) fn rebuild_state_from_thread(&mut self) {
        let Some(agent) = &self.agent else {
            return;
        };
        let thread = agent.thread();
        let mut state = NativeThreadState::new();
        state.usage_total = thread.usage_total;
        let restored_images = apply_thread_entries(&mut state, &thread.entries);
        state.thread.thread_id = thread.id.clone();
        state.set_context_size(self.model_context_size());
        state.thread.usage = Usage {
            used: thread.usage_total.total(),
            size: self.model_context_size(),
            cost: None,
        };
        if state.thread.entries.is_empty() {
            state.push_notice(EMPTY_THREAD_NOTICE);
        }
        self.state = state;
        self.sent_images = restored_images;
    }

    /// 为第 `ordinal` 条用户消息（1-based）拍 checkpoint 并持久化。
    /// 用消息 ordinal 而不是进程内计数器作 key：重启/恢复线程后仍能对上。
    pub(super) fn capture_checkpoint(&mut self, thread_id: &str, ordinal: usize) {
        let Some(manager) = &self.checkpoint_manager else {
            if !self.checkpoint_notice_reported {
                self.checkpoint_notice_reported = true;
                self.state
                    .push_notice("当前工作区不是 git 仓库：检查点不可用，本轮文件改动将无法回滚。");
            }
            return;
        };
        match manager.snapshot(thread_id, ordinal as u64) {
            Ok(checkpoint) => {
                let _ = self
                    .session_store
                    .save_checkpoint(&checkpoint, ordinal as i64, now_secs());
                self.last_checkpoint = Some(checkpoint.clone());
                self.available_checkpoints
                    .retain(|(existing, _)| *existing != ordinal);
                self.available_checkpoints.push((ordinal, checkpoint));
                self.available_checkpoints
                    .sort_by_key(|(ordinal, _)| *ordinal);
            }
            Err(error) => {
                self.status = format!("checkpoint 失败：{error}");
                if !self.checkpoint_notice_reported {
                    self.checkpoint_notice_reported = true;
                    self.state
                        .push_notice(format!("本轮未创建检查点：{error}（文件改动将无法回滚）"));
                }
            }
        }
    }

    /// 从持久化存储重载当前线程的 checkpoint 列表。
    pub(super) fn reload_thread_checkpoints(&mut self) {
        self.available_checkpoints.clear();
        self.last_checkpoint = None;
        let Some(agent) = self.agent.as_ref() else {
            return;
        };
        if !self.session_store.is_available() {
            return;
        }
        let thread_id = agent.thread().id.clone();
        let records = self.session_store.list_checkpoints(&thread_id);
        self.available_checkpoints = checkpoints_from_records(&records);
        self.last_checkpoint = self
            .available_checkpoints
            .last()
            .map(|(_, checkpoint)| checkpoint.clone());
        self.refresh_checkpoint_changes();
    }

    /// 某条 UI 消息可用的 checkpoint（用户消息 ordinal 对应）。
    pub(super) fn checkpoint_for_message(&self, message_index: usize) -> Option<Checkpoint> {
        // 渲染行与模型 entries 1:1，优先用模型 ordinal；旧路径作为兜底。
        let ordinal = thread_entry_ordinal(&self.state.thread.entries, message_index)?;
        self.available_checkpoints
            .iter()
            .find(|(candidate, _)| *candidate == ordinal)
            .map(|(_, checkpoint)| checkpoint.clone())
    }

    /// 会话回退后，把 `ordinal >= from_ordinal` 的 checkpoint 标记失效。
    pub(super) fn invalidate_checkpoints_from(&mut self, from_ordinal: usize, thread_id: &str) {
        if let Some(store) = self.session_store.session_mut() {
            for (ordinal, _) in self
                .available_checkpoints
                .iter()
                .filter(|(ordinal, _)| *ordinal >= from_ordinal)
            {
                let _ = store.mark_checkpoint_invalid(thread_id, *ordinal as i64);
            }
        }
        self.available_checkpoints
            .retain(|(ordinal, _)| *ordinal < from_ordinal);
        self.last_checkpoint = self
            .available_checkpoints
            .last()
            .map(|(_, checkpoint)| checkpoint.clone());
        self.refresh_checkpoint_changes();
    }

    /// Zed 的 Restore Checkpoint：回退工作区文件，并把会话截断到该消息之前。
    pub(super) fn restore_to_checkpoint(&mut self, message_index: usize, cx: &mut Context<Self>) {
        if self.busy {
            self.status = "生成中，稍后再恢复".to_string();
            cx.notify();
            return;
        }
        let Some(checkpoint) = self.checkpoint_for_message(message_index) else {
            return;
        };
        let Some(ordinal) = thread_entry_ordinal(&self.state.thread.entries, message_index) else {
            return;
        };
        let Some(manager) = &self.checkpoint_manager else {
            self.status = "当前工作区没有 checkpoint 能力".to_string();
            cx.notify();
            return;
        };
        match manager.is_valid(&checkpoint) {
            Ok(true) => {}
            Ok(false) => {
                if let (Some(store), Some(agent)) = (self.session_store.session_mut(), &self.agent)
                {
                    let _ = store.mark_checkpoint_invalid(&agent.thread().id, ordinal as i64);
                }
                self.reload_thread_checkpoints();
                self.status = "检查点已失效（工作区 HEAD 已变化）".to_string();
                cx.notify();
                return;
            }
            Err(error) => {
                self.status = format!("检查点校验失败：{error}");
                cx.notify();
                return;
            }
        }
        if let Err(error) = manager.restore(&checkpoint) {
            self.status = format!("回退失败：{error}");
            cx.notify();
            return;
        }
        let Some(agent) = self.agent.as_mut() else {
            return;
        };
        let thread_id = agent.thread().id.clone();
        if let Some(entry_index) = thread_user_entry_index(&agent.thread().entries, ordinal) {
            agent.thread_mut().entries.truncate(entry_index);
        }
        if let Some(store) = self.session_store.session_mut() {
            let _ = store.save_thread(agent.thread());
        }
        self.editing_user = None;
        self.user_edit_input = None;
        self.rebuild_state_from_thread();
        self.state.thread.entries.retain(|entry| {
            !matches!(entry, ConversationEntry::Notice { text, .. } if text == EMPTY_THREAD_NOTICE)
        });
        self.invalidate_checkpoints_from(ordinal, &thread_id);
        self.state
            .push_notice("已恢复检查点：文件已回退，可以从这里重新发送消息");
        self.status = "已恢复检查点".to_string();
        cx.notify();
    }

    pub(super) fn undo_checkpoint(&mut self, cx: &mut Context<Self>) {
        let Some(checkpoint) = self.last_checkpoint.clone() else {
            return;
        };
        let Some(manager) = &self.checkpoint_manager else {
            return;
        };
        if !manager.is_valid(&checkpoint).unwrap_or(false) {
            self.status = "checkpoint 已失配（HEAD 有变化），请重新初始化".to_string();
            cx.notify();
            return;
        }
        match manager.restore(&checkpoint) {
            Ok(()) => {
                self.last_checkpoint = None;
                self.status = "已回退到本轮前".to_string();
            }
            Err(error) => self.status = format!("回退失败：{error}"),
        }
        cx.notify();
    }

    /// 共享权限卡的按钮回调：按 ACP `option_id` 精确回传，随后按共享模型把
    /// Permission 行标记 resolved（不再经过 native 专属 ApprovalDecision）。
    pub(super) fn resolve_permission_option(&mut self, option_id: &str, cx: &mut Context<Self>) {
        self.state.sync_pending_permission();
        let Some(pending) = self.state.thread.pending_permission.clone() else {
            return;
        };
        let allowed = agent_ingest::permission_option_allowed(&pending.options, option_id);
        if let Some(host) = &self.host.acp_host {
            let _ = host.respond_permission_option(&pending.request_id, option_id);
        }
        self.state.resolve_permission(&pending.request_id);
        agent_ingest::apply_permission_resolved(
            &mut self.state.thread,
            pending.request_id,
            allowed,
        );
        cx.notify();
    }
}

impl NativeAgentView {
    /// 当前是否在跑一个回合。`busy` 在结果回调里落回 false，但事件队列可能还没
    pub(super) fn is_generating(&self) -> bool {
        self.busy || self.state.thread.is_generating()
    }

    /// B3b：本轮文件变更面板（capability gated，legacy/shared 视图共用同一渲染）。
    pub(super) fn render_checkpoint_panel(
        &mut self,
        palette: theme::Palette,
        change_count: usize,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let changes = self.checkpoint_changes.clone();
        div()
            .id("native-agent-checkpoint-panel")
            .flex()
            .flex_col()
            .gap(space(1))
            .px(space(3))
            .py(space(2))
            .border_t_1()
            .border_color(palette.line)
            .bg(palette.view)
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap(space(1))
                    .child(
                        div()
                            .flex_1()
                            .text_size(px(12.0))
                            .child(format!("本轮文件变更（{change_count}）")),
                    )
                    .child(
                        div()
                            .id("native-keep-all")
                            .role(Role::Button)
                            .aria_label("全部保留")
                            .px(space(1))
                            .py(px(2.0))
                            .rounded(px(RADIUS_SMALL))
                            .text_size(px(10.0))
                            .text_color(palette.ink_2)
                            .hover(|style| style.bg(palette.soft))
                            .child("全部保留")
                            .on_click(
                                cx.listener(|this, _, _window, cx| this.keep_all_changes(cx)),
                            ),
                    )
                    .child(
                        div()
                            .id("native-reject-all")
                            .role(Role::Button)
                            .aria_label("全部回退")
                            .px(space(1))
                            .py(px(2.0))
                            .rounded(px(RADIUS_SMALL))
                            .text_size(px(10.0))
                            .text_color(palette.danger)
                            .hover(|style| style.bg(palette.soft))
                            .child("全部回退")
                            .on_click(
                                cx.listener(|this, _, _window, cx| this.reject_all_changes(cx)),
                            ),
                    ),
            )
            .children(changes.into_iter().map(|change| {
                let path = change.path.clone();
                let restore_path = change.path.clone();
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap(space(2))
                    .child(
                        div()
                            .flex_1()
                            .text_size(px(12.0))
                            .child(checkpoint_change_label(&change)),
                    )
                    .child(
                        div()
                            .id("checkpoint-keep")
                            .role(Role::Button)
                            .aria_label("保留")
                            .px(space(1))
                            .py(px(2.0))
                            .rounded(px(RADIUS_MEDIUM))
                            .bg(palette.soft)
                            .child("保留")
                            .on_click(cx.listener(move |this, _, _window, cx| {
                                this.keep_checkpoint_file(path.clone(), cx)
                            })),
                    )
                    .child(
                        div()
                            .id("checkpoint-restore")
                            .role(Role::Button)
                            .aria_label("回退")
                            .px(space(1))
                            .py(px(2.0))
                            .rounded(px(RADIUS_MEDIUM))
                            .bg(palette.accent)
                            .text_color(palette.canvas)
                            .child("回退")
                            .on_click(cx.listener(move |this, _, _window, cx| {
                                this.restore_checkpoint_file(restore_path.clone(), cx)
                            })),
                    )
            }))
            .into_any_element()
    }
}
