use super::worker::{ActiveTurn, Job, Owner};
use super::*;
use cgc_agent_core::{ApprovalRequest, Approver, AutoApprover, ToolResultSummary, TurnObserver};
use cgc_agent_provider::{TokenUsage, ToolUse};
use futures::FutureExt;
use std::sync::Weak;

impl Owner {
    pub(super) fn start_turn(
        &mut self,
        generation: u64,
        thread_id: String,
        turn: NativeTurn,
        reply: oneshot::Sender<Result<ToolTurnOutcome, AgentError>>,
    ) {
        if generation != self.generation || thread_id != self.frozen.id {
            let _ = reply.send(Err(AgentError::StaleConnection));
            return;
        }
        if self.idle().is_err() {
            let _ = reply.send(Err(AgentError::RuntimeBusy));
            return;
        }
        let Some(mut agent) = self.agent.take() else {
            let _ = reply.send(Err(AgentError::RuntimeClosed));
            return;
        };
        let prepared = self.prepared.take();
        let retry = prepared.as_ref().is_some_and(|prepared| prepared.retry);
        if retry {
            agent.thread_mut().truncate_before_last_user();
        }
        if !retry {
            let ordinal = agent
                .thread()
                .entries
                .iter()
                .filter(|entry| matches!(entry, cgc_agent_core::Entry::User { .. }))
                .count()
                + 1;
            self.capture_checkpoint(&agent.thread().id, ordinal);
        }
        if let Some(prepared) = prepared {
            agent.set_pending_user_display(Some(prepared.display));
            agent.set_pending_images(
                prepared
                    .images
                    .into_iter()
                    .map(|image| (image.name, image.mime_type, image.data))
                    .collect(),
            );
        }
        let configured = self
            .production
            .as_ref()
            .and_then(|production| {
                production
                    .providers
                    .iter()
                    .find(|provider| provider.id == self.config.model.provider_id.as_str())
            })
            .map(|provider| provider.model_config(self.config.model.id.as_str()));
        let effort = configured
            .as_ref()
            .filter(|configured| self.thinking_enabled && configured.supports_thinking)
            .and_then(|configured| {
                configured.effort_at(
                    self.effort_index
                        .min(configured.reasoning_efforts.len().saturating_sub(1)),
                )
            })
            .map(str::to_string);
        agent.set_reasoning_effort(effort);
        let cancel = agent.cancel_token();
        cancel.reset();
        let tool_cancel = cancel.clone();
        let native_cancel = cancel.clone();
        turn.cancel.on_cancel(move || native_cancel.cancel());
        self.active = Some(ActiveTurn {
            cancel,
            steer: agent.steer_sender(),
        });
        let mut config = self.config.clone();
        // 让工具（尤其是 run_command）能在 Stop 后立刻收尾，而不是等自身 timeout。
        config.context = config
            .context
            .clone()
            .with_cancel(std::sync::Arc::new(move || tool_cancel.is_cancelled()));
        let registry = if configured.is_some_and(|configured| !configured.supports_tools) {
            self.empty_registry.clone()
        } else {
            config.registry.clone()
        };
        let commands = self.commands.clone();
        self.jobs.push(
            async move {
                let mut observer = Observed {
                    inner: turn.observer,
                    commands,
                };
                let auto_approver = AutoApprover;
                let approver: &dyn Approver = if config.auto_approve {
                    &auto_approver
                } else {
                    turn.approver.as_ref()
                };
                let result = agent
                    .prompt_with_tools_observed(
                        config.provider.as_ref(),
                        &config.model,
                        turn.prompt,
                        &registry,
                        &config.context,
                        approver,
                        &mut observer,
                    )
                    .await;
                Job::Turn {
                    agent: Box::new(agent),
                    result,
                    reply,
                    generation,
                }
            }
            .boxed(),
        );
        self.publish(RuntimeChange::Activity);
    }

    pub(super) fn completed(&mut self, job: Job) {
        match job {
            Job::Turn {
                mut agent,
                result,
                reply,
                generation,
            } => {
                if let Some(title) = self.pending_override.take() {
                    agent.set_thread_title_override(title);
                }
                self.agent = Some(*agent);
                self.refresh_state();
                self.active = None;
                self.persist();
                self.freeze();
                self.reload_checkpoints();
                self.refresh_changes();
                // The owner, not a view, restores its Agent on every result path.
                let result = if generation == self.generation {
                    result
                } else {
                    Err(AgentError::StaleConnection)
                };
                let _ = reply.send(result);
                self.publish(RuntimeChange::Activity);
                if let Some(force) = self.pending_title.take() {
                    self.start_title(force);
                }
            }
            Job::Title {
                generation,
                thread_id,
                serial,
                title,
            } => {
                self.title_running = false;
                if generation == self.generation
                    && thread_id == self.frozen.id
                    && serial == self.title_serial
                {
                    if let Some(agent) = &mut self.agent {
                        agent.set_thread_title(Some(title));
                    }
                    self.persist();
                    self.freeze();
                    self.publish(RuntimeChange::Title);
                }
                self.publish(RuntimeChange::Activity);
            }
            Job::Mcp { context, result } => self.mcp_prepared(context, result),
        }
    }
}

struct Observed {
    inner: Box<dyn TurnObserver + Send>,
    commands: Weak<mpsc::UnboundedSender<Command>>,
}

impl TurnObserver for Observed {
    fn on_turn_started(&mut self, id: &str) {
        self.inner.on_turn_started(id);
    }
    fn on_follow_up_started(&mut self, text: &str) {
        self.inner.on_follow_up_started(text);
    }
    fn on_steer_started(&mut self, text: &str) {
        self.inner.on_steer_started(text);
    }
    fn on_compaction(&mut self, entries: usize) {
        self.inner.on_compaction(entries);
    }
    fn on_text(&mut self, text: &str) {
        self.inner.on_text(text);
    }
    fn on_thinking(&mut self, text: &str) {
        self.inner.on_thinking(text);
    }
    fn on_tool_call(&mut self, call: &ToolUse) {
        self.inner.on_tool_call(call);
    }
    fn on_permission_request(&mut self, request: &ApprovalRequest) {
        self.inner.on_permission_request(request);
    }
    fn on_tool_result(&mut self, result: &ToolResultSummary) {
        self.inner.on_tool_result(result);
        if let Some(commands) = self.commands.upgrade() {
            let _ = commands.unbounded_send(Command::ToolStateChanged);
        }
    }
    fn on_usage(&mut self, usage: TokenUsage, total: TokenUsage) {
        self.inner.on_usage(usage, total);
    }
    fn on_context_estimate(&mut self, tokens: usize, images: bool) {
        self.inner.on_context_estimate(tokens, images);
    }
    fn on_finished(&mut self, result: &ToolTurnOutcome) {
        self.inner.on_finished(result);
    }
}
