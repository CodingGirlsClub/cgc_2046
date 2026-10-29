use super::worker::{ActiveTurn, Job, Owner, TitleOutcome};
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
        // 用户设置文件里的 agent.model_parameters（显式 runtime 不读，保持测试隔离）。
        let settings = self
            .production
            .as_ref()
            .map(|_| crate::user_settings::load_default());
        agent.set_temperature(settings.as_ref().and_then(|settings| {
            settings.temperature_for_model(
                self.config.model.provider_id.as_str(),
                self.config.model.id.as_str(),
            )
        }));
        let cancel = agent.cancel_token();
        cancel.reset();
        let tool_cancel = cancel.clone();
        let native_cancel = cancel.clone();
        turn.cancel.on_cancel(move || native_cancel.cancel());
        self.active = Some(ActiveTurn {
            cancel,
            steer: agent.steer_sender(),
        });
        let had_pending = self
            .production
            .as_ref()
            .is_some_and(|production| production.pending.is_some());
        let resolved = if had_pending {
            let Some(production) = self.production.as_mut() else {
                return;
            };
            factory::resolve_pending_key(production, &mut self.config)
        } else {
            false
        };
        if had_pending {
            // Provider 解析后必须重建工具 registry：SubagentRunner 在构造时
            // 会捕获当时的 provider/model，不能继续使用旧的 UnconfiguredProvider。
            self.rebuild_tools();
            if resolved {
                self.notice("已读取本机保存的 Provider Key，使用真实模型".into());
            } else {
                self.notice(
                    "未读取到 Provider API Key，请先在 Settings → AI → LLM Providers 配置".into(),
                );
            }
            self.publish(RuntimeChange::Configuration);
        }
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
                // 标题 job 可能在 turn 期间完成（后台任务）：agent 归还后再落到
                // thread 上，保证 persist/freeze 看到的是最终标题。
                if let Some((serial, title)) = self.pending_generated_title.take() {
                    if serial == self.title_serial {
                        if let Some(agent) = &mut self.agent {
                            agent.set_thread_title(Some(title));
                        }
                        self.title_generation_error = None;
                    }
                }
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
                let completed = result.is_ok();
                let _ = reply.send(result);
                self.publish(RuntimeChange::Activity);
                if let Some(force) = self.pending_title.take() {
                    self.start_title(force);
                } else if completed {
                    // 对齐 Zed：turn 完成后 title 仍为空才生成。
                    // B4 单 actor 改造前该触发在 native_agent_view::apply_turn_end，
                    // 迁移时漏接，标题因此退化成只能手动 Regenerate。
                    self.start_title(false);
                }
            }
            Job::Title {
                generation,
                thread_id,
                serial,
                outcome,
            } => {
                // serial 不匹配说明这个 job 已被后续操作（切线程/重命名/重新生成）
                // 接管，不能动 title_running，否则会把新一轮的状态清掉。
                if serial != self.title_serial {
                    return;
                }
                self.title_running = false;
                let same_thread = generation == self.generation && thread_id == self.frozen.id;
                match outcome {
                    TitleOutcome::Cancelled => {}
                    TitleOutcome::Generated(title) if same_thread => {
                        self.title_generation_error = None;
                        if let Some(agent) = &mut self.agent {
                            agent.set_thread_title(Some(title));
                            self.persist();
                            self.freeze();
                        } else {
                            // turn 正在跑：先乐观更新显示，等 agent 归还再落盘。
                            self.display_title = Some(Arc::from(title.clone()));
                            self.pending_generated_title = Some((serial, title));
                        }
                        self.publish(RuntimeChange::Title);
                    }
                    TitleOutcome::Generated(_) => {}
                    TitleOutcome::Failed(error) if same_thread => {
                        self.title_generation_error = Some(Arc::from(error));
                        self.publish(RuntimeChange::Title);
                    }
                    TitleOutcome::Failed(_) => {}
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
