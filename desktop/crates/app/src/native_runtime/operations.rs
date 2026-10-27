use super::worker::Owner;
use super::*;
use cgc_agent_checkpoint::CheckpointManager;
use cgc_agent_core::{Agent, SelectedModel};
use cgc_agent_tools::SandboxPolicy;

impl Owner {
    pub(super) fn command(&mut self, command: Command) {
        match command {
            Command::Subscribe(sender) => {
                let _ = sender.unbounded_send(Arc::new(NativeRuntimeEvent::Snapshot {
                    change: RuntimeChange::Initialized,
                    snapshot: self.snapshot(),
                }));
                for message in &self.notices {
                    let _ = sender.unbounded_send(Arc::new(NativeRuntimeEvent::Notice {
                        generation: self.generation,
                        message: message.clone(),
                    }));
                }
                self.subscribers.push(sender);
            }
            Command::Inspect(reply) => {
                let _ = reply.send(Ok(self.snapshot()));
            }
            Command::Connect(reply) => {
                let result = self.idle().and_then(|()| {
                    let commands = self.commands.upgrade().ok_or(NativeRuntimeError::Closed)?;
                    self.generation = self.generation.wrapping_add(1);
                    self.prepared = None;
                    self.rebuild_tools();
                    Ok(NativeRuntimeConnection {
                        handle: NativeRuntimeHandle { commands },
                        generation: self.generation,
                        thread_id: self.frozen.id.clone(),
                    })
                });
                if result.is_ok() {
                    self.publish(RuntimeChange::Connected);
                }
                let _ = reply.send(result);
            }
            Command::Disconnect(generation) => {
                if generation == self.generation {
                    self.generation = self.generation.wrapping_add(1);
                    self.prepared = None;
                    if let Some(active) = &self.active {
                        active.cancel.cancel();
                    }
                    self.title_cancel.cancel();
                    self.publish(RuntimeChange::Activity);
                }
            }
            Command::Run {
                generation,
                thread_id,
                turn,
                reply,
            } => self.start_turn(generation, thread_id, turn, reply),
            Command::Prepare(turn, reply) => {
                let result = self.idle().and_then(|()| {
                    if turn.generation != self.generation || turn.thread_id != self.frozen.id {
                        return Err(NativeRuntimeError::StaleConnection);
                    }
                    if self.prepared.is_some() {
                        return Err(NativeRuntimeError::Busy);
                    }
                    self.prepared = Some(turn);
                    Ok(())
                });
                let _ = reply.send(result);
            }
            Command::Stop => {
                if let Some(active) = &self.active {
                    active.cancel.cancel();
                }
                self.title_cancel.cancel();
                self.title_serial = self.title_serial.wrapping_add(1);
                self.pending_title = None;
            }
            Command::Steer(text, reply) => {
                let result = self
                    .active
                    .as_ref()
                    .ok_or(NativeRuntimeError::Busy)
                    .and_then(|active| {
                        active
                            .steer
                            .send(text)
                            .map_err(|_| NativeRuntimeError::Closed)
                    });
                let _ = reply.send(result);
            }
            Command::Open(id, reply) => {
                let result = self.open(id);
                let _ = reply.send(result);
            }
            Command::New(reply) => {
                let result = self.new_thread();
                let _ = reply.send(result);
            }
            Command::SwitchScope(scope, reply) => {
                let result = self.switch_scope(scope);
                let _ = reply.send(result);
            }
            Command::Rewind {
                ordinal,
                restore_files,
                reply,
            } => {
                let result = self.rewind(ordinal, restore_files);
                let _ = reply.send(result);
            }
            Command::Checkpoint(action, reply) => {
                let result = self.checkpoint(action);
                let _ = reply.send(result);
            }
            Command::SelectModel {
                provider,
                model,
                reply,
            } => {
                let result = self.select_model(&provider, &model);
                let _ = reply.send(result);
            }
            Command::Thinking {
                enabled,
                effort_index,
            } => {
                self.thinking_enabled = enabled;
                self.effort_index = effort_index;
                self.publish(RuntimeChange::Configuration);
            }
            Command::Approval(mode) => {
                self.config.auto_approve = mode == ApprovalMode::Auto;
                self.publish(RuntimeChange::Configuration);
            }
            Command::Rename(title) => {
                self.title_serial = self.title_serial.wrapping_add(1);
                if let Some(agent) = &mut self.agent {
                    agent.set_thread_title_override(title);
                    self.persist();
                    self.freeze();
                } else {
                    self.display_title = title
                        .as_deref()
                        .filter(|title| !title.trim().is_empty())
                        .or(self.frozen.title.as_deref())
                        .map(Arc::from);
                    self.pending_override = Some(title);
                }
                self.publish(RuntimeChange::Title);
            }
            Command::GenerateTitle(force) => self.start_title(force),
            Command::Mcp { context, epoch } => self.update_mcp(context, epoch),
            Command::Subagent { generation, event } if generation == self.generation => {
                self.emit(NativeRuntimeEvent::Subagent { generation, event })
            }
            Command::AppAction {
                generation,
                workspace,
                action,
            } if generation == self.generation => {
                if let Some(audit) = self
                    .production
                    .as_ref()
                    .and_then(|production| production.host.action_audit.as_ref())
                {
                    let name = match &action {
                        AppAction::OpenPage { .. } => "open_page",
                        AppAction::HighlightRange { .. } => "highlight_range",
                    };
                    if let Err(error) = audit.append(&cgc_agent_store::ActionAuditEntry {
                        at: crate::native_context::now_secs(),
                        action: name.into(),
                        detail: action.summary(),
                        dispatched: true,
                    }) {
                        self.notice(format!("应用动作审计保存失败：{error}"));
                    }
                }
                self.emit(NativeRuntimeEvent::AppAction {
                    generation,
                    workspace,
                    action,
                });
            }
            Command::ToolStateChanged => {
                self.refresh_state();
                self.publish(RuntimeChange::Tools);
            }
            Command::Subagent { .. } | Command::AppAction { .. } => {}
        }
    }

    fn replace(&mut self, thread: Thread, change: RuntimeChange) {
        self.generation = self.generation.wrapping_add(1);
        self.title_serial = self.title_serial.wrapping_add(1);
        self.pending_title = None;
        self.pending_override = None;
        self.prepared = None;
        self.agent = Some(Agent::new(
            thread,
            Some(crate::native_context::build_workspace_system_prompt(
                self.config.context.workspace(),
            )),
        ));
        self.rebuild_tools();
        self.freeze();
        self.reload_checkpoints();
        self.refresh_changes();
        self.publish(change);
    }

    fn open(&mut self, id: String) -> Result<Arc<NativeRuntimeSnapshot>, NativeRuntimeError> {
        self.idle()?;
        let thread = self
            .store
            .as_ref()
            .ok_or(NativeRuntimeError::MissingThread)?
            .load_thread(&id)
            .map_err(|error| NativeRuntimeError::Storage(error.to_string()))?
            .ok_or(NativeRuntimeError::MissingThread)?;
        let selected = SelectedModel::new(
            self.config.model.provider_id.clone(),
            self.config.model.id.clone(),
        );
        if thread.model != selected {
            let production = self.production.as_mut().ok_or_else(|| {
                NativeRuntimeError::Configuration("历史模型不在当前 runtime 中".into())
            })?;
            let (provider, model) = factory::select_model(
                production,
                thread.model.provider_id.as_str(),
                thread.model.model_id.as_str(),
            )?;
            self.config.provider = provider;
            self.config.context_size = model.limits.context_window as u64;
            self.config.model = model;
        }
        self.persist();
        self.replace(thread, RuntimeChange::Opened);
        Ok(self.snapshot())
    }

    fn new_thread(&mut self) -> Result<Arc<NativeRuntimeSnapshot>, NativeRuntimeError> {
        self.idle()?;
        let id = self
            .scope
            .as_ref()
            .map(|scope| format!("native-{}", scope.key))
            .unwrap_or_else(|| self.frozen.id.clone());
        self.invalidate_checkpoints(1)?;
        self.replace(
            Thread::new(
                id,
                SelectedModel::new(
                    self.config.model.provider_id.clone(),
                    self.config.model.id.clone(),
                ),
            ),
            RuntimeChange::Opened,
        );
        self.persist();
        Ok(self.snapshot())
    }

    fn switch_scope(
        &mut self,
        scope: AgentScope,
    ) -> Result<Arc<NativeRuntimeSnapshot>, NativeRuntimeError> {
        self.idle()?;
        self.persist();
        std::fs::create_dir_all(&scope.root)
            .map_err(|error| NativeRuntimeError::Storage(error.to_string()))?;
        let selected = SelectedModel::new(
            self.config.model.provider_id.clone(),
            self.config.model.id.clone(),
        );
        let id = format!("native-{}", scope.key);
        let thread = match &self.store {
            Some(store) => store
                .load_thread(&id)
                .map_err(|error| NativeRuntimeError::Storage(error.to_string()))?
                .filter(|thread| thread.model == selected)
                .unwrap_or_else(|| Thread::new(id, selected)),
            None => Thread::new(id, selected),
        };
        self.config.context =
            ToolContext::new(&scope.root).with_sandbox(SandboxPolicy::new(&scope.root));
        self.checkpoint_manager = CheckpointManager::open(&scope.root)
            .or_else(|_| CheckpointManager::initialize(&scope.root))
            .ok();
        if let Some(production) = &self.production {
            if let Ok(mut state) = production.host.agent_state.lock() {
                *state = AgentState::default();
            }
        }
        self.scope = Some(Arc::new(scope));
        self.checkpoint_notice_reported = false;
        self.replace(thread, RuntimeChange::Opened);
        Ok(self.snapshot())
    }

    fn select_model(
        &mut self,
        provider: &str,
        model: &str,
    ) -> Result<Arc<NativeRuntimeSnapshot>, NativeRuntimeError> {
        self.idle()?;
        let production = self
            .production
            .as_mut()
            .ok_or_else(|| NativeRuntimeError::Configuration("runtime 未配置模型目录".into()))?;
        let (provider, model) = factory::select_model(production, provider, model)?;
        if self.config.model == model {
            return Ok(self.snapshot());
        }
        self.persist();
        self.config.provider = provider;
        self.config.context_size = model.limits.context_window as u64;
        self.config.model = model;
        let serial = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        self.replace(
            Thread::new(
                format!("native-demo-{serial}"),
                SelectedModel::new(
                    self.config.model.provider_id.clone(),
                    self.config.model.id.clone(),
                ),
            ),
            RuntimeChange::Opened,
        );
        self.persist();
        Ok(self.snapshot())
    }
}
