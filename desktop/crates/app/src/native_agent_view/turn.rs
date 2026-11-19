//! Native UI adapter: commands to the owner, ACP events to the shared client session.
use super::*;

pub(super) const WALLET_FROZEN_NOTICE: &str =
    "当前 CGC 算力钱包已被冻结，暂无法继续对话或充值。请联系客服处理。";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct TurnErrorEffect {
    opens_quota_card: bool,
    shows_frozen_notice: bool,
}

fn turn_error_effect(kind: NativeTurnErrorKind) -> TurnErrorEffect {
    match kind {
        NativeTurnErrorKind::InsufficientQuota => TurnErrorEffect {
            opens_quota_card: true,
            shows_frozen_notice: false,
        },
        NativeTurnErrorKind::WalletFrozen => TurnErrorEffect {
            opens_quota_card: false,
            shows_frozen_notice: true,
        },
        NativeTurnErrorKind::ConcurrencyLimit | NativeTurnErrorKind::Other => TurnErrorEffect {
            opens_quota_card: false,
            shows_frozen_notice: false,
        },
    }
}

impl NativeAgentView {
    pub(super) fn apply_turn_error(
        &mut self,
        kind: NativeTurnErrorKind,
        message: &str,
        cx: &mut Context<Self>,
    ) {
        let effect = turn_error_effect(kind);
        self.insufficient_quota = effect.opens_quota_card;
        if effect.shows_frozen_notice {
            self.quota_checkout = None;
            self.quota_checkout_serial = self.quota_checkout_serial.wrapping_add(1);
            self.wallet_frozen_notice = Some(WALLET_FROZEN_NOTICE.to_string());
            self.status = WALLET_FROZEN_NOTICE.to_string();
            self.state.push_notice(WALLET_FROZEN_NOTICE);
        } else {
            self.wallet_frozen_notice = None;
            self.status = format!("错误：{message}");
        }
        cx.notify();
    }

    pub(super) fn apply_runtime_event(
        &mut self,
        event: &NativeRuntimeEvent,
        cx: &mut Context<Self>,
    ) {
        match event {
            NativeRuntimeEvent::Snapshot { change, snapshot } => {
                self.apply_snapshot(*change, snapshot.clone(), cx)
            }
            NativeRuntimeEvent::Notice {
                generation,
                message,
            } if self
                .snapshot
                .as_ref()
                .is_none_or(|snapshot| *generation == snapshot.generation) =>
            {
                self.status = message.clone();
                self.state.push_notice(message.clone());
                cx.notify();
            }
            NativeRuntimeEvent::TurnError {
                generation,
                kind,
                message,
            } if self
                .snapshot
                .as_ref()
                .is_none_or(|snapshot| *generation == snapshot.generation) =>
            {
                self.apply_turn_error(*kind, message, cx);
            }
            NativeRuntimeEvent::Subagent { generation, event }
                if self
                    .snapshot
                    .as_ref()
                    .is_some_and(|snapshot| *generation == snapshot.generation) =>
            {
                self.state.apply_subagent_event(event);
                self.state.pair_unlinked_subagents();
                cx.notify();
            }
            NativeRuntimeEvent::AppAction {
                generation,
                workspace,
                action,
            } if self
                .snapshot
                .as_ref()
                .is_some_and(|snapshot| *generation == snapshot.generation) =>
            {
                for window in cx.windows() {
                    if let Some(root) = window.downcast::<crate::root_view::RootView>() {
                        let _ = root.update(cx, |root, _window, cx| {
                            root.apply_native_agent_action(action.clone(), workspace.clone(), cx)
                        });
                        break;
                    }
                }
            }
            _ => {}
        }
    }
    pub(super) fn connect_native(&mut self, cx: &mut Context<Self>) {
        self.state.session.phase = ConnectionPhase::Starting;
        let connection = self.runtime.connect();
        let client_generation = self.state.session.generation;
        let workspace = self.metadata().workspace.clone();
        cx.spawn(async move |this, cx| {
            let result = connection.await.and_then(|connection| {
                let server =
                    NativeAcpServer::new(Box::new(connection)).with_config(NativeAcpServerConfig {
                        agent_name: "cgc-native".into(),
                        version: env!("CARGO_PKG_VERSION").into(),
                    });
                AcpHost::start_in_process(
                    AcpHostConfig::new("", workspace.as_ref().clone()).with_name("cgc-native"),
                    server,
                )
                .map_err(|error| {
                    crate::native_runtime::NativeRuntimeError::Configuration(error.to_string())
                })
            });
            let _ = this.update(cx, |this, cx| {
                if this.state.session.generation != client_generation {
                    return;
                }
                match result {
                    Ok(host) => {
                        let generation = this.state.session.attach(host);
                        this.spawn_session_poller(generation, cx);
                    }
                    Err(error) => {
                        this.state.session.phase = ConnectionPhase::Failed(error.to_string());
                        this.state.push_notice(error.to_string());
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }
    fn spawn_session_poller(&mut self, generation: u64, cx: &mut Context<Self>) {
        cx.spawn(async move |this, cx| loop {
            cx.background_executor()
                .timer(std::time::Duration::from_millis(50))
                .await;
            let keep = this
                .update(cx, |this, cx| this.drain_session(generation, cx))
                .unwrap_or(false);
            if !keep {
                break;
            }
        })
        .detach();
    }
    fn drain_session(&mut self, generation: u64, cx: &mut Context<Self>) -> bool {
        if generation != self.state.session.generation {
            return false;
        }
        let events = self.state.session.drain(generation);
        let old_len = self.state.session.thread.entries.len();
        let terminal = events
            .iter()
            .any(|event| matches!(event, HostEvent::TurnEnd { .. } | HostEvent::Error { .. }));
        let had_error = events
            .iter()
            .any(|event| matches!(event, HostEvent::Error { .. }));
        let completed = events.iter().any(|event| {
            matches!(
                event,
                HostEvent::TurnEnd {
                    cancelled: false,
                    ..
                }
            )
        });
        for event in events {
            if !self.state.ingest(generation, &event) {
                continue;
            }
            match &event {
                HostEvent::ThoughtDelta(_) => {
                    if let Some(last_idx) = self.state.session.thread.entries.len().checked_sub(1) {
                        if matches!(
                            self.state.session.thread.entries.get(last_idx),
                            Some(ConversationEntry::Thinking { .. })
                        ) {
                            let started = *self
                                .thinking_started_at
                                .entry(last_idx)
                                .or_insert_with(std::time::Instant::now);
                            self.state.session.thread.set_thinking_duration(
                                last_idx,
                                (started.elapsed().as_millis() as u64).max(1),
                            );
                        }
                    }
                }
                HostEvent::Delta(_)
                | HostEvent::ToolCall { .. }
                | HostEvent::TurnEnd { .. }
                | HostEvent::Error { .. } => {
                    for (idx, started) in std::mem::take(&mut self.thinking_started_at) {
                        self.state.session.thread.set_thinking_duration(
                            idx,
                            (started.elapsed().as_millis() as u64).max(1),
                        );
                    }
                }
                _ => {}
            }
            self.page_context
                .observe_event(&self.conversation_scope(), &event);
            if let HostEvent::Error { message } = &event {
                if self.wallet_frozen_notice.is_none() {
                    self.status = format!("错误：{message}");
                }
            }
            if matches!(
                event,
                HostEvent::TurnEnd {
                    cancelled: true,
                    ..
                }
            ) {
                self.status = "已停止".into();
            }
        }
        for (index, entry) in self
            .state
            .session
            .thread
            .entries
            .iter()
            .enumerate()
            .skip(old_len)
        {
            if matches!(entry, ConversationEntry::Thinking { .. }) {
                self.expanded_thinking.insert(index);
            }
        }
        if should_clear_quota_state(had_error, completed) {
            self.wallet_frozen_notice = None;
            if self.insufficient_quota {
                self.clear_quota_state();
            }
        }
        if self.state.take_learning_state_changed() {
            cx.emit(NativeAgentViewEvent::LearningStateChanged);
        }
        self.state.pair_unlinked_subagents();
        if terminal {
            let snapshot = self.snapshot.clone();
            if let Some(snapshot) = snapshot.filter(|snapshot| snapshot.phase == RuntimePhase::Idle)
            {
                if self.sync_saved_drafts(&snapshot) {
                    self.persist_native(&snapshot);
                }
            }
            self.refresh_wallet(cx);
        }
        self.dispatch_queued(cx);
        cx.notify();
        self.state.session.host.is_some()
    }
    pub(super) fn dispatch_queued(&mut self, cx: &mut Context<Self>) {
        let idle = self
            .snapshot
            .as_ref()
            .is_some_and(|snapshot| snapshot.phase == RuntimePhase::Idle);
        if !should_dispatch(
            self.state.session.queue.is_empty(),
            idle,
            self.metadata().model_setup.allows_send(),
        ) {
            return;
        }
        let Some(mut submission) = self.state.session.next_queued() else {
            return;
        };
        self.state.session.reserve();
        let generation = self.state.session.generation;
        let preparation = self.runtime.prepare(PreparedNativeTurn {
            thread_id: self.metadata().thread.id.clone(),
            generation: self.metadata().generation,
            display: submission.display.clone(),
            draft: submission
                .draft
                .as_ref()
                .and_then(|draft| serde_json::to_value(draft).ok()),
            images: submission.images.clone(),
            retry: submission.retry,
        });
        cx.spawn(async move |this, cx| {
            let result = preparation.await;
            let _ = this.update(cx, |this, cx| {
                if this.state.session.generation != generation {
                    return;
                }
                match result {
                    Ok(()) => {
                        this.state.session.mark_ready_for_next(generation);
                        let scope = this.conversation_scope();
                        if this.state.session.send_with_context(
                            &mut submission,
                            &this.page_context,
                            &scope,
                        ) {
                            this.scroll_messages_to_bottom(cx);
                        } else {
                            this.state.session.queue.insert(0, submission);
                            this.status = "消息尚未发送，连接不可用".into();
                        }
                    }
                    Err(error) => {
                        this.state.session.queue.insert(0, submission);
                        this.status = error.to_string();
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }
    pub(super) fn steer(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.pending_agent_call.is_some() {
            // steer_with_context has no Submission/agent_call channel. Queue via
            // send instead of silently dropping the structured action.
            self.status = "带学习动作的消息会进入发送队列".into();
            cx.notify();
            return;
        }
        let content = self.input.read(cx).content();
        let text = crate::composer_context::user_text(&content);
        if text.is_empty() {
            return;
        }
        let (draft, prompt, context) = self.composer_context.freeze(
            &content,
            self.page_context.visible(),
            &self.metadata().workspace,
            &self.page_context,
            self.conversation_scope(),
        );
        self.composer_context.reset();
        let scope = self.conversation_scope();
        let display = draft.text.clone();
        self.page_context.stage_steer(display.clone(), context);
        let operation = self.runtime.steer_with_context(
            prompt,
            draft.text.clone(),
            serde_json::to_value(&draft).ok(),
        );
        self.input
            .update(cx, |state, cx| state.set_value("", window, cx));
        cx.spawn(async move |this, cx| {
            let result = operation.await;
            let _ = this.update(cx, |this, cx| {
                this.status = match result {
                    // 入队不证明插话已进入模型历史，不据此标记正文已加载。
                    Ok(()) => "已提交插话".to_string(),
                    Err(error) => {
                        this.page_context.discard_steer(&scope, &display);
                        error.to_string()
                    }
                };
                cx.notify();
            });
        })
        .detach();
    }
}

fn should_dispatch(queue_empty: bool, idle: bool, model_ready: bool) -> bool {
    !queue_empty && idle && model_ready
}

fn should_clear_quota_state(had_error: bool, completed: bool) -> bool {
    completed && !had_error
}

#[cfg(test)]
mod tests {
    use super::{should_clear_quota_state, should_dispatch, turn_error_effect, TurnErrorEffect};
    use crate::native_runtime::NativeTurnErrorKind;

    #[test]
    fn dispatch_requires_queued_work_idle_runtime_and_model() {
        assert!(should_dispatch(false, true, true));
        assert!(!should_dispatch(true, true, true));
        assert!(!should_dispatch(false, false, true));
        assert!(!should_dispatch(false, true, false));
    }

    #[test]
    fn successful_retry_clears_stale_quota_state() {
        assert!(should_clear_quota_state(false, true));
        assert!(!should_clear_quota_state(true, true));
        assert!(!should_clear_quota_state(false, false));
    }

    #[test]
    fn structured_turn_error_opens_quota_card_only_for_insufficient_quota_never_wallet_frozen() {
        assert_eq!(
            turn_error_effect(NativeTurnErrorKind::InsufficientQuota),
            TurnErrorEffect {
                opens_quota_card: true,
                shows_frozen_notice: false,
            }
        );
        assert_eq!(
            turn_error_effect(NativeTurnErrorKind::WalletFrozen),
            TurnErrorEffect {
                opens_quota_card: false,
                shows_frozen_notice: true,
            }
        );
        assert_eq!(
            turn_error_effect(NativeTurnErrorKind::ConcurrencyLimit),
            TurnErrorEffect {
                opens_quota_card: false,
                shows_frozen_notice: false,
            }
        );
        assert_eq!(
            turn_error_effect(NativeTurnErrorKind::Other),
            TurnErrorEffect {
                opens_quota_card: false,
                shows_frozen_notice: false,
            }
        );
    }
}
