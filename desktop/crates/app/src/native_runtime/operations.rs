use super::worker::Owner;
use super::*;
use cgc_agent_checkpoint::CheckpointManager;
use cgc_agent_core::{Agent, SelectedModel};
use cgc_agent_provider::{EchoProvider, UnconfiguredProvider};
use cgc_agent_store::PrefsStore;
use cgc_agent_tools::SandboxPolicy;

impl Owner {
    pub(super) fn command(&mut self, command: Command) {
        match command {
            Command::Subscribe(sender) => {
                let snapshot = self.snapshot();
                if let Ok(mut slot) = self.latest.lock() {
                    *slot = Some(Arc::clone(&snapshot));
                }
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
                    // 新连接会作废旧连接的 turn/标题结果，后台 job 一并取消。
                    self.cancel_title();
                    self.prepared = None;
                    self.rebuild_tools();
                    Ok(NativeRuntimeConnection {
                        handle: NativeRuntimeHandle {
                            commands,
                            latest: Arc::clone(&self.latest),
                        },
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
                    self.cancel_title();
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
                // 标题是后台 job，Stop 只终止当前 turn，不取消标题生成。
                if let Some(active) = &self.active {
                    active.cancel.cancel();
                }
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
            Command::RefreshProviders(reply) => {
                let result = self.refresh_providers();
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
                self.cancel_title();
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
        self.cancel_title();
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

    /// Settings 保存并验证 Provider 后重新读取 `agent_prefs.json`，同步当前会话的
    /// provider/model，避免用户重启客户端。
    fn refresh_providers(&mut self) -> Result<Arc<NativeRuntimeSnapshot>, NativeRuntimeError> {
        self.idle()?;
        let production = self
            .production
            .as_mut()
            .ok_or_else(|| NativeRuntimeError::Configuration("runtime 未配置模型目录".into()))?;
        let prefs = PrefsStore::new(production.data_root.join("agent_prefs.json")).load();
        production.providers = Arc::new(prefs.providers.clone());
        self.providers = Arc::new(prefs.providers.clone());
        let active = prefs.active_provider();
        let model_id = active.and_then(|active| {
            prefs
                .selected_model
                .as_ref()
                .filter(|selection| selection.provider_id.as_str() == active.id)
                .map(|selection| selection.model_id.as_str())
                .filter(|id| model_is_available(active, id))
                .or_else(|| {
                    active
                        .models
                        .iter()
                        .find(|id| active.model_config(id).enabled)
                        .map(String::as_str)
                })
        });
        let Some((active, model_id)) = active.zip(model_id) else {
            let allow_echo = production.allow_echo && active.is_none();
            production.pending = None;
            production.model_setup = if allow_echo {
                ModelSetup::DemoEcho
            } else {
                ModelSetup::Unconfigured
            };
            self.config.provider = if allow_echo {
                Arc::new(EchoProvider::new(self.config.model.clone()))
            } else {
                Arc::new(UnconfiguredProvider::new(self.config.model.clone()))
            };
            self.model_meta = Arc::new(self.config.model.clone());
            self.cancel_title();
            self.rebuild_tools();
            self.publish(RuntimeChange::Configuration);
            return Ok(self.snapshot());
        };
        let (provider, model) = factory::select_model(production, &active.id, model_id)?;
        self.config.provider = provider;
        self.config.context_size = model.limits.context_window as u64;
        self.config.model = model.clone();
        self.model_meta = Arc::new(model.clone());
        let selected = SelectedModel::new(model.provider_id.clone(), model.id.clone());
        if self.frozen.model != selected {
            self.persist();
            // 保留当前会话的 entries，只切换模型；否则同 ID 的空 thread 会把原对话覆盖掉。
            self.replace(
                thread_for_model_switch(&self.frozen, selected),
                RuntimeChange::Opened,
            );
        } else {
            // 同一个 model 但 provider/key 变了：SubagentRunner 仍持有旧 provider，
            // 必须重建 tools registry 后再发布配置快照。
            self.rebuild_tools();
            self.publish(RuntimeChange::Configuration);
        }
        self.persist();
        Ok(self.snapshot())
    }
}

fn model_is_available(active: &cgc_agent_store::ProviderPrefs, model_id: &str) -> bool {
    active.models.iter().any(|id| id == model_id) && active.model_config(model_id).enabled
}

fn thread_for_model_switch(current: &Thread, selected: SelectedModel) -> Thread {
    let mut thread = current.clone();
    thread.model = selected;
    thread
}

#[cfg(test)]
mod tests {
    use super::{model_is_available, thread_for_model_switch};
    use cgc_agent_core::{SelectedModel, Thread};
    use cgc_agent_provider::{ModelId, ProviderId};
    use cgc_agent_store::{ModelPrefs, ProviderPrefs};

    fn provider(models: &[(&str, bool)]) -> ProviderPrefs {
        ProviderPrefs {
            id: "test".into(),
            name: "Test".into(),
            base_url: "https://example.test/v1".into(),
            models: models.iter().map(|(id, _)| id.to_string()).collect(),
            has_key: true,
            model_params: models
                .iter()
                .map(|(id, enabled)| ModelPrefs {
                    enabled: *enabled,
                    ..ModelPrefs::new(*id)
                })
                .collect(),
            builtin: false,
        }
    }

    #[test]
    fn refresh_requires_membership_before_retaining_selected_model() {
        let active = provider(&[("removed", false), ("available", true)]);
        assert!(!model_is_available(&active, "removed"));
        assert!(!model_is_available(&active, "missing"));
        assert!(model_is_available(&active, "available"));
    }

    #[test]
    fn switching_model_keeps_thread_entries() {
        let old_model = SelectedModel::new(ProviderId::new("p"), ModelId::new("old"));
        let mut current = Thread::new("native-scope", old_model);
        current.push_user("keep this conversation");
        let next_model = SelectedModel::new(ProviderId::new("p"), ModelId::new("new"));

        let switched = thread_for_model_switch(&current, next_model.clone());

        assert_eq!(switched.id, "native-scope");
        assert_eq!(switched.entries, current.entries);
        assert_eq!(switched.model, next_model);
    }
}
