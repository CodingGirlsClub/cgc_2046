//! turn 生命周期与 ACP 事件消费（B4b-a 第一片：从视图模块移出，行为不变）。
//!
//! 子模块可直接访问父模块私有字段。

use super::*;

impl NativeAgentView {
    /// 执行一个 turn；`retry` = 重放上一轮（不重复 push 用户消息、不重拍 checkpoint）。
    ///
    /// Phase A：Agent 与 per-turn 配置交给进程内 ACP server 的运行时出口，
    /// 过程事件经 ACP 客户端回到 `drain_acp_events` 再归约进共享会话模型。
    pub(super) fn run_turn(
        &mut self,
        text: String,
        display: String,
        retry: bool,
        cx: &mut Context<Self>,
    ) {
        if !retry {
            self.reload_latest_session();
            // 本条用户消息即将 push（run_turn 里会 push），ordinal = 现有用户消息数 + 1。
            let ordinal = self
                .state
                .thread
                .entries
                .iter()
                .filter(|entry| matches!(entry, ConversationEntry::User { .. }))
                .count()
                + 1;
            if let Some(thread_id) = self.agent.as_ref().map(|agent| agent.thread().id.clone()) {
                self.capture_checkpoint(&thread_id, ordinal);
            }
        }
        self.scroll_messages_to_bottom(cx);
        let Some(mut agent) = self.agent.take() else {
            return;
        };
        if !retry && !self.pending_images.is_empty() {
            agent.set_pending_images(
                self.pending_images
                    .iter()
                    .map(|image| (image.name.clone(), image.mime.clone(), image.data.clone()))
                    .collect(),
            );
            let sent: Vec<SentImage> = self
                .pending_images
                .iter()
                .map(|image| SentImage {
                    name: image.name.clone(),
                    preview: image.preview.clone(),
                })
                .collect();
            if !sent.is_empty() {
                let message_index = self.state.thread.entries.len();
                self.sent_images.insert(message_index, sent);
            }
            self.pending_images.clear();
        }
        let model_config = self
            .providers
            .iter()
            .find(|provider| provider.id == self.model.provider_id.as_str())
            .map(|provider| provider.model_config(self.model.id.as_str()))
            .unwrap_or_default();
        let effort_index = self
            .effort_index
            .min(model_config.reasoning_efforts.len().saturating_sub(1));
        let effort = if self.thinking_enabled && model_config.supports_thinking {
            model_config.effort_at(effort_index).map(str::to_string)
        } else {
            None
        };
        agent.set_reasoning_effort(effort);
        // 记录 UI 展示文本（不含注入上下文），restore 时用户气泡不会显示上下文前缀。
        agent.set_pending_user_display(Some(display.clone()));
        if !retry {
            crate::agent_ingest::apply_user_turn(&mut self.state.thread, display.clone());
        }
        self.busy = true;
        self.status = "思考中…".to_string();
        self.cancel.reset();
        self.ensure_subagent_pump(cx);
        if !self.ensure_acp_host() {
            self.busy = false;
            self.agent = Some(agent);
            cx.notify();
            return;
        }
        let context_size = self.model_context_size();
        if let Some(handle) = &self.acp_context_size {
            handle.store(context_size, std::sync::atomic::Ordering::Relaxed);
        }
        let model_tools_supported = self
            .providers
            .iter()
            .find(|provider| provider.id == self.model.provider_id.as_str())
            .map(|provider| provider.model_config(self.model.id.as_str()).supports_tools)
            .unwrap_or(true);
        self.runtime.put_config(NativeRuntimeConfig {
            provider: self.provider.clone(),
            model: self.model.clone(),
            registry: if model_tools_supported {
                self.registry.clone()
            } else {
                Arc::new(ToolRegistry::new())
            },
            context: self.context.clone(),
            context_size,
            auto_approve: self.approval_mode == ApprovalMode::Auto,
        });
        self.runtime.put_agent(agent);
        self.ensure_acp_poller(cx);
        let prompted = self
            .host
            .acp_host
            .as_ref()
            .map(|host| host.prompt(text))
            .unwrap_or(false);
        if !prompted {
            self.finish_turn(TurnEndState::Failed("agent channel closed".to_string()), cx);
        }
        cx.notify();
    }

    /// 建立 native 的进程内 ACP 连接（client 侧与外部 ACP agent 完全同一条路径）。
    pub(super) fn ensure_acp_host(&mut self) -> bool {
        if self.host.acp_connected() {
            return true;
        }
        let server = NativeAcpServer::new(Box::new(self.runtime.clone())).with_config(
            NativeAcpServerConfig {
                agent_name: "cgc-native".to_string(),
                version: env!("CARGO_PKG_VERSION").to_string(),
            },
        );
        self.acp_context_size = Some(server.context_size_handle());
        let cwd = self.context.workspace().to_path_buf();
        match AcpHost::start_in_process(AcpHostConfig::new("", cwd).with_name("cgc-native"), server)
        {
            Ok(host) => {
                self.host.set_acp_host(Some(host));
                true
            }
            Err(error) => {
                self.state.last_error = Some(error.to_string());
                self.state
                    .push_notice(format!("启动进程内 ACP 连接失败：{error}"));
                self.status = format!("错误：{error}");
                false
            }
        }
    }

    /// 启动 ACP 客户端事件轮询（50ms 批量 drain，与 ACP 面板同一消费方式）。
    pub(super) fn ensure_acp_poller(&mut self, cx: &mut Context<Self>) {
        if self.acp_poller_running {
            return;
        }
        self.acp_poller_running = true;
        self.acp_poller_generation += 1;
        let generation = self.acp_poller_generation;
        cx.spawn(async move |this, cx| loop {
            cx.background_executor()
                .timer(std::time::Duration::from_millis(50))
                .await;
            let keep = this
                .update(cx, |this, cx| this.drain_acp_events(generation, cx))
                .unwrap_or(false);
            if !keep {
                break;
            }
        })
        .detach();
    }

    /// 消费一批 ACP 客户端事件：会话行统一走 `agent_ingest`，native 辅助态更新
    /// 审批卡 / 子 agent 配对；turn 收尾事件触发完成逻辑。
    pub(super) fn drain_acp_events(&mut self, generation: u64, cx: &mut Context<Self>) -> bool {
        if generation != self.acp_poller_generation {
            return false;
        }
        self.retrieve_awaiting_agent(cx);
        let mut events = Vec::new();
        if let Some(host) = &self.host.acp_host {
            while let Some(event) = host.try_recv() {
                events.push(event);
            }
        }
        if events.is_empty() {
            return self.host.acp_connected() || self.awaiting_agent;
        }
        let old_len = self.state.thread.entries.len();
        let mut finished = None;
        for event in events {
            // Stage 3.2b（路线 A）：settings 级规则只作用于 native。决定性 allow/deny
            // 且请求里有对应 kind 的 option 时自动回传、不弹卡，并在会话里补一条
            // system Notice；否则（ask/confirm、无匹配 option）照常走共享权限卡。
            // Auto 模式由 runtime 内 AutoApprover 决定，不叠加规则。
            if self.approval_mode == ApprovalMode::Ask {
                if let Some(auto) = crate::approval_rules::auto_permission_for_event(
                    &crate::approval_rules::ApprovalRules::load(),
                    &event,
                ) {
                    if let Some(host) = &self.host.acp_host {
                        let _ = host.respond_permission_option(&auto.request_id, &auto.option_id);
                    }
                    agent_ingest::apply_notice(&mut self.state.thread, auto.notice);
                    cx.notify();
                    continue;
                }
            }
            self.state.apply_host_event(&event);
            match &event {
                HostEvent::PermissionRequested { .. } => {
                    // Auto 模式在 runtime 内已放行，不应出现审批请求；防御性按
                    // agent 提供的第一个 allow 选项回传。
                    if self.approval_mode == ApprovalMode::Auto {
                        let option_id = self
                            .state
                            .thread
                            .pending_permission
                            .as_ref()
                            .and_then(|request| {
                                request.options.iter().find(|option| option.kind.is_allow())
                            })
                            .map(|option| option.id.clone());
                        if let Some(option_id) = option_id {
                            self.resolve_permission_option(&option_id, cx);
                        }
                    }
                }
                HostEvent::TurnEnd {
                    cancelled,
                    stop_reason,
                } => {
                    let cancelled = *cancelled || stop_reason.eq_ignore_ascii_case("cancelled");
                    finished = Some(if cancelled {
                        TurnEndState::Cancelled
                    } else {
                        TurnEndState::Completed
                    });
                }
                HostEvent::Error { message } => {
                    finished = Some(TurnEndState::Failed(message.clone()));
                }
                HostEvent::Exited => {
                    self.host.set_acp_host(None);
                    self.acp_poller_running = false;
                    finished = Some(TurnEndState::Failed("agent connection exited".to_string()));
                }
                _ => {}
            }
        }
        // 新出现的 thinking 行默认展开（对齐旧行为）。
        for (index, entry) in self.state.thread.entries.iter().enumerate() {
            if index >= old_len && matches!(entry, ConversationEntry::Thinking { .. }) {
                self.expanded_thinking.insert(index);
            }
        }
        self.state.pair_unlinked_subagents();
        self.state.sync_pending_permission();
        if self.busy {
            if let Some(state) = finished {
                self.finish_turn(state, cx);
            }
        }
        cx.notify();
        self.host.acp_connected() || self.awaiting_agent
    }

    /// cancel 宽限期内 client 可能先收到合成 TurnEnd，而 server 稍后才把 Agent
    /// 交回 runtime slot；这里轮询补取，再补做 turn 收尾（保存线程等）。
    pub(super) fn retrieve_awaiting_agent(&mut self, cx: &mut Context<Self>) {
        if !self.awaiting_agent {
            return;
        }
        let Some(agent) = self.runtime.take_agent() else {
            return;
        };
        self.agent = Some(agent);
        self.awaiting_agent = false;
        let state = self
            .pending_turn_end
            .take()
            .unwrap_or(TurnEndState::Completed);
        self.apply_turn_end(state, cx);
    }

    /// turn 收尾：取回 Agent、保存线程、checkpoint / 子 agent / 队列收口。
    pub(super) fn finish_turn(&mut self, state: TurnEndState, cx: &mut Context<Self>) {
        if let Some(agent) = self.runtime.take_agent() {
            self.agent = Some(agent);
        }
        if self.agent.is_none() {
            // turn 还在 server 侧收尾（Agent 尚未交回）：保持 busy（用户输入继续
            // 进 queue，避免丢消息），由 drain 轮询在 Agent 回到 slot 后再收尾。
            self.awaiting_agent = true;
            self.pending_turn_end = Some(state);
            cx.notify();
            return;
        }
        self.apply_turn_end(state, cx);
    }

    /// Agent 已取回后的 turn 收尾（状态、持久化、checkpoint、队列）。
    pub(super) fn apply_turn_end(&mut self, state: TurnEndState, cx: &mut Context<Self>) {
        self.busy = false;
        match &state {
            TurnEndState::Completed => {
                let total = self
                    .agent
                    .as_ref()
                    .map(|agent| agent.thread().usage_total.total())
                    .unwrap_or(0);
                if let Some(agent) = &self.agent {
                    self.state.usage_total = agent.thread().usage_total;
                }
                self.status = format!("完成 · 本会话 {total} tokens");
            }
            TurnEndState::Cancelled => self.status = "已停止".to_string(),
            TurnEndState::Failed(message) => {
                self.state.last_error = Some(message.clone());
                // HostEvent::Error 已由共用 ingestion 落过 Failed 行；这里只补
                // 合成失败（channel closed / 连接退出）缺失的那一行，避免重复。
                if !matches!(
                    self.state.thread.status,
                    cgc_agent_ui::conversation::ThreadStatus::Failed
                ) {
                    self.state
                        .thread
                        .apply(cgc_agent_ui::conversation::ThreadEvent::Failed(
                            message.clone(),
                        ));
                }
                self.status = format!("错误：{message}");
            }
        }
        if let (Some(store), Some(agent)) = (self.session_store.session_mut(), &self.agent) {
            let _ = store.save_thread(agent.thread());
        }
        self.reload_thread_checkpoints();
        self.drain_app_actions(cx);
        self.refresh_checkpoint_changes();
        if matches!(state, TurnEndState::Completed) {
            self.maybe_generate_thread_title(cx);
        }
        if !self.queued_messages.is_empty() {
            let next = self.queued_messages.remove(0);
            self.send_prompt(next.prompt, next.display, cx);
        }
        cx.notify();
    }

    /// 子 agent 实时进度是 ACP v1 表达不了的 native 专属事件，走独立辅助通道。
    pub(super) fn ensure_subagent_pump(&mut self, cx: &mut Context<Self>) {
        if self.subagent_pump_started {
            return;
        }
        self.subagent_pump_started = true;
        let (sender, mut receiver) = mpsc::unbounded::<AgentEvent>();
        if let Ok(mut slot) = self.subagent_tx.lock() {
            *slot = Some(sender);
        }
        cx.spawn(async move |this, cx| {
            while let Some(event) = receiver.next().await {
                let updated = this.update(cx, |this, cx| {
                    this.state.apply_subagent_event(&event);
                    this.state.pair_unlinked_subagents();
                    cx.notify();
                });
                if updated.is_err() {
                    break;
                }
            }
        })
        .detach();
    }

    pub(super) fn steer(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let text = self.input.read(cx).value().trim().to_string();
        if text.is_empty() {
            return;
        }
        if self.steer_sender.send(text).is_ok() {
            self.input
                .update(cx, |state, cx| state.set_value("", window, cx));
            self.status = "已插入 steer，当前生成将被中断".to_string();
        } else {
            self.status = "steer 发送失败".to_string();
        }
        cx.notify();
    }
}
