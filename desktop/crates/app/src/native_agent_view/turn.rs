//! Native UI adapter: commands to the owner, ACP events to the shared client session.
use super::*;

impl NativeAgentView {
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
        for event in events {
            self.state.ingest(generation, &event);
            if let HostEvent::Error { message } = &event {
                self.status = format!("错误：{message}");
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
        self.state.pair_unlinked_subagents();
        self.dispatch_queued(cx);
        cx.notify();
        self.state.session.host.is_some()
    }
    pub(super) fn dispatch_queued(&mut self, cx: &mut Context<Self>) {
        if self
            .snapshot
            .as_ref()
            .is_none_or(|snapshot| snapshot.phase != RuntimePhase::Idle)
        {
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
            images: std::mem::take(&mut submission.images),
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
                        this.last_turn =
                            Some((submission.prompt.clone(), submission.display.clone()));
                        if this.state.session.send(&submission) {
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
        let content = self.input.read(cx).content();
        let text = content.text().trim().to_string();
        if text.is_empty() {
            return;
        }
        let prompt = mention::resolve_prompt(&content, &self.metadata().workspace);
        let (prompt, _) = self.page_context.freeze(prompt);
        let operation = self.runtime.steer(prompt);
        self.input
            .update(cx, |state, cx| state.set_value("", window, cx));
        cx.spawn(async move |this, cx| {
            let result = operation.await;
            let _ = this.update(cx, |this, cx| {
                this.status = result
                    .map(|()| "已提交插话".to_string())
                    .unwrap_or_else(|error| error.to_string());
                cx.notify();
            });
        })
        .detach();
    }
}
