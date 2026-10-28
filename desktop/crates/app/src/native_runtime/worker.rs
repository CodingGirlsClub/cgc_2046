use super::*;
use cgc_agent_checkpoint::CheckpointManager;
use cgc_agent_core::{Agent, CancelToken};
use cgc_agent_store::SessionStore;
use futures::{stream::FuturesUnordered, FutureExt, StreamExt};
use std::sync::Weak;

pub(super) enum Initialization {
    Explicit {
        thread: Box<Thread>,
        system_prompt: Option<String>,
        config: Box<NativeRuntimeConfig>,
        store: Option<SessionStore>,
    },
    Workspace {
        scope: AgentScope,
        data_root: PathBuf,
        host: NativePanelHost,
        authorization_epoch: u64,
    },
}

/// 后台标题生成的结果；`Cancelled` 不产生任何可观察变化。
pub(super) enum TitleOutcome {
    Generated(String),
    Failed(String),
    Cancelled,
}

pub(super) struct ActiveTurn {
    pub cancel: CancelToken,
    pub steer: std::sync::mpsc::Sender<String>,
}

pub(super) enum Job {
    Turn {
        agent: Box<Agent>,
        result: Result<ToolTurnOutcome, AgentError>,
        reply: oneshot::Sender<Result<ToolTurnOutcome, AgentError>>,
        generation: u64,
    },
    Title {
        generation: u64,
        thread_id: String,
        serial: u64,
        outcome: TitleOutcome,
    },
    Mcp {
        context: McpContext,
        result:
            Result<Vec<Arc<dyn cgc_agent_tools::Tool>>, cgc_platform::mcp::client::McpClientError>,
    },
}

pub(super) struct Owner {
    pub agent: Option<Agent>,
    pub config: NativeRuntimeConfig,
    pub production: Option<factory::Production>,
    pub scope: Option<Arc<AgentScope>>,
    pub store: Option<SessionStore>,
    pub checkpoint_manager: Option<CheckpointManager>,
    pub checkpoints: Arc<Vec<(usize, Checkpoint)>>,
    pub changes: Arc<Vec<FileChange>>,
    pub frozen: Arc<Thread>,
    pub generation: u64,
    pub revision: u64,
    pub thinking_enabled: bool,
    pub effort_index: usize,
    pub prepared: Option<PreparedNativeTurn>,
    pub active: Option<ActiveTurn>,
    pub jobs: FuturesUnordered<BoxFuture<'static, Job>>,
    pub title_serial: u64,
    pub title_running: bool,
    pub title_cancel: CancelToken,
    pub checkpoint_notice_reported: bool,
    pub pending_title: Option<bool>,
    /// 标题在 turn 期间生成完成；等 agent 归还后落到 thread 上再 persist/freeze。
    pub pending_generated_title: Option<(u64, String)>,
    pub title_generation_error: Option<Arc<str>>,
    pub pending_override: Option<Option<String>>,
    pub commands: Weak<mpsc::UnboundedSender<Command>>,
    pub subscribers: Vec<mpsc::UnboundedSender<Arc<NativeRuntimeEvent>>>,
    pub notices: Vec<String>,
    pub schemas: Arc<Vec<ToolSchema>>,
    pub providers: Arc<Vec<ProviderPrefs>>,
    pub model_meta: Arc<Model>,
    pub workspace_meta: Arc<PathBuf>,
    pub empty_registry: Arc<ToolRegistry>,
    pub authorization_epoch: u64,
    pub mcp_unavailable_reason: Option<Arc<str>>,
    pub mcp_tools: Option<super::mcp::McpTools>,
    pub mcp_probe_running: bool,
    pub mcp_probe_pending: bool,
    pub mcp_probe_context: Option<McpContext>,
    pub state_meta: Arc<AgentState>,
    pub display_title: Option<Arc<str>>,
    /// 最近快照镜像，供视图首帧同步读取。
    pub latest: Arc<std::sync::Mutex<Option<Arc<NativeRuntimeSnapshot>>>>,
}

impl Owner {
    fn initialize(
        initialization: Initialization,
        commands: Weak<mpsc::UnboundedSender<Command>>,
        latest: Arc<std::sync::Mutex<Option<Arc<NativeRuntimeSnapshot>>>>,
    ) -> Result<Self, NativeRuntimeError> {
        // 真机 D3（卡在「正在载入会话…」约 1 分钟）没有复现时，这段计时是唯一线索：
        // 每次启动都会在 cgc-run.log 留一行各阶段耗时，用于判断卡在 prefs/keychain、
        // 会话库还是 git 检查点。
        let init_started = std::time::Instant::now();
        let (mut agent, config, production, scope, supplied_store, authorization_epoch) =
            match initialization {
                Initialization::Explicit {
                    thread,
                    system_prompt,
                    config,
                    store,
                } => (
                    Agent::new(*thread, system_prompt),
                    *config,
                    None,
                    None,
                    store,
                    0,
                ),
                Initialization::Workspace {
                    scope,
                    data_root,
                    host,
                    authorization_epoch,
                } => {
                    let (agent, config, production) = factory::initialize(&scope, data_root, host)?;
                    (
                        agent,
                        config,
                        Some(production),
                        Some(Arc::new(scope)),
                        None,
                        authorization_epoch,
                    )
                }
            };
        let after_config = init_started.elapsed();
        let mut notices = Vec::new();
        let store = match production.as_ref() {
            Some(production) => {
                match SessionStore::open(production.data_root.join("agent/threads.db")) {
                    Ok(store) => {
                        match store.load_thread(&agent.thread().id) {
                            Ok(Some(thread)) if thread.model == agent.thread().model => {
                                agent.replace_thread(thread)
                            }
                            Ok(_) => {}
                            Err(error) => notices.push(format!("读取会话失败：{error}")),
                        }
                        Some(store)
                    }
                    Err(error) => {
                        notices.push(format!("会话无法持久保存：{error}"));
                        None
                    }
                }
            }
            None => supplied_store,
        };
        if let Some(production) = production.as_ref() {
            if let Some(notice) = crate::native_context::offline_echo_notice(production.using_echo)
            {
                notices.push(notice.to_string());
            }
        }
        let after_store = init_started.elapsed();
        let checkpoint_manager = if production.is_some() {
            CheckpointManager::open(config.context.workspace())
                .or_else(|_| CheckpointManager::initialize(config.context.workspace()))
                .ok()
        } else {
            None
        };
        let after_checkpoints = init_started.elapsed();
        let frozen = Arc::new(agent.thread().clone());
        let schemas = Arc::new(config.registry.schemas());
        let providers = production
            .as_ref()
            .map(|production| production.providers.clone())
            .unwrap_or_else(|| Arc::new(Vec::new()));
        let model_meta = Arc::new(config.model.clone());
        let workspace_meta = Arc::new(config.context.workspace().to_path_buf());
        let state_meta = Arc::new(factory::state(production.as_ref()));
        let display_title = frozen
            .title_override
            .as_deref()
            .filter(|title| !title.trim().is_empty())
            .or(frozen.title.as_deref())
            .map(Arc::from);
        let mut owner = Self {
            latest,
            agent: Some(agent),
            config,
            production,
            scope,
            store,
            checkpoint_manager,
            checkpoints: Arc::new(Vec::new()),
            changes: Arc::new(Vec::new()),
            frozen,
            generation: 0,
            revision: 0,
            thinking_enabled: true,
            effort_index: 0,
            prepared: None,
            active: None,
            jobs: FuturesUnordered::new(),
            title_serial: 0,
            title_running: false,
            title_cancel: CancelToken::new(),
            checkpoint_notice_reported: false,
            pending_title: None,
            pending_generated_title: None,
            title_generation_error: None,
            pending_override: None,
            commands,
            subscribers: Vec::new(),
            notices,
            schemas,
            providers,
            model_meta,
            workspace_meta,
            empty_registry: Arc::new(ToolRegistry::new()),
            authorization_epoch,
            state_meta,
            display_title,
            mcp_unavailable_reason: None,
            mcp_tools: None,
            mcp_probe_running: false,
            mcp_probe_pending: false,
            mcp_probe_context: None,
        };
        owner.rebuild_tools();
        owner.reload_checkpoints();
        eprintln!(
            "[native] init config={:?} store={:?} checkpoints={:?} total={:?}",
            after_config,
            after_store - after_config,
            after_checkpoints - after_store,
            init_started.elapsed(),
        );
        Ok(owner)
    }

    pub fn snapshot(&self) -> Arc<NativeRuntimeSnapshot> {
        Arc::new(NativeRuntimeSnapshot {
            thread: self.frozen.clone(),
            model: self.model_meta.clone(),
            workspace: self.workspace_meta.clone(),
            phase: if self.active.is_some() {
                RuntimePhase::Running
            } else {
                RuntimePhase::Idle
            },
            generation: self.generation,
            revision: self.revision,
            schemas: self.schemas.clone(),
            authorization_epoch: self.authorization_epoch,
            mcp_unavailable_reason: self.mcp_unavailable_reason.clone(),
            display_title: self.display_title.clone(),
            title_generating: self.title_running,
            title_generation_error: self.title_generation_error.clone(),
            providers: self.providers.clone(),
            using_echo: self
                .production
                .as_ref()
                .is_some_and(|production| production.using_echo),
            thinking_enabled: self.thinking_enabled,
            effort_index: self.effort_index,
            approval_mode: if self.config.auto_approve {
                ApprovalMode::Auto
            } else {
                ApprovalMode::Ask
            },
            checkpoints: self.checkpoints.clone(),
            changes: self.changes.clone(),
            agent_state: self.state_meta.clone(),
            persistence_available: self.store.is_some(),
        })
    }

    pub fn emit(&mut self, event: NativeRuntimeEvent) {
        let event = Arc::new(event);
        self.subscribers
            .retain(|subscriber| subscriber.unbounded_send(event.clone()).is_ok());
    }

    pub fn publish(&mut self, change: RuntimeChange) {
        self.emit(NativeRuntimeEvent::Snapshot {
            change,
            snapshot: self.snapshot(),
        });
    }

    pub fn notice(&mut self, message: String) {
        self.emit(NativeRuntimeEvent::Notice {
            generation: self.generation,
            message,
        });
    }

    pub fn freeze(&mut self) {
        if let Some(agent) = &self.agent {
            self.frozen = Arc::new(agent.thread().clone());
            self.display_title = agent
                .thread()
                .title_override
                .as_deref()
                .filter(|title| !title.trim().is_empty())
                .or(agent.thread().title.as_deref())
                .map(Arc::from);
            self.revision = self.revision.wrapping_add(1);
        }
    }

    /// 让当前/排队的标题生成失效：取消在跑 job、清空错误与待落盘结果。
    /// 线程切换、重命名、rewind、授权（generation）变化都必须走这里，否则
    /// 后台 job 完成后会把 `title_running` 留成 true。
    pub(super) fn cancel_title(&mut self) {
        self.title_cancel.cancel();
        self.title_serial = self.title_serial.wrapping_add(1);
        self.title_running = false;
        self.title_generation_error = None;
        self.pending_title = None;
        self.pending_generated_title = None;
    }

    /// 标题生成是后台 job，不参与 turn 的占用判定（对齐 Zed：不阻塞下一轮）。
    pub fn idle(&self) -> Result<(), NativeRuntimeError> {
        if self.active.is_some() {
            Err(NativeRuntimeError::Busy)
        } else {
            Ok(())
        }
    }

    pub fn refresh_state(&mut self) {
        if let Some(production) = &self.production {
            let state = production
                .host
                .agent_state
                .lock()
                .expect("native tool state");
            if &*state != self.state_meta.as_ref() {
                self.state_meta = Arc::new(state.clone());
            }
        }
    }

    pub fn persist(&mut self) {
        let result = match (&mut self.store, &self.agent) {
            (Some(store), Some(agent)) => store.save_thread(agent.thread()),
            _ => return,
        };
        if let Err(error) = result {
            self.notice(format!("会话尚未保存：{error}"));
        }
    }
}

pub(super) async fn run(
    initialization: Initialization,
    commands: Weak<mpsc::UnboundedSender<Command>>,
    mut receiver: mpsc::UnboundedReceiver<Command>,
    latest: Arc<std::sync::Mutex<Option<Arc<NativeRuntimeSnapshot>>>>,
) {
    let mut owner = match Owner::initialize(initialization, commands, latest) {
        Ok(owner) => owner,
        Err(error) => {
            while let Some(command) = receiver.next().await {
                reject(command, error.clone());
            }
            return;
        }
    };
    enum Next {
        Command(Option<Command>),
        Completed(Box<Job>),
    }
    loop {
        let next = if owner.jobs.is_empty() {
            Next::Command(receiver.next().await)
        } else {
            futures::select_biased! {
                result = owner.jobs.next().fuse() => Next::Completed(Box::new(result.expect("non-empty job set"))),
                command = receiver.next().fuse() => Next::Command(command),
            }
        };
        match next {
            Next::Command(Some(command)) => owner.command(command),
            Next::Completed(job) => owner.completed(*job),
            Next::Command(None) => {
                if let Some(active) = &owner.active {
                    active.cancel.cancel();
                }
                owner.title_cancel.cancel();
                while let Some(job) = owner.jobs.next().await {
                    owner.completed(job);
                }
                owner.persist();
                break;
            }
        }
    }
}

fn reject(command: Command, error: NativeRuntimeError) {
    match command {
        Command::Inspect(reply)
        | Command::Open(_, reply)
        | Command::New(reply)
        | Command::SwitchScope(_, reply)
        | Command::Rewind { reply, .. }
        | Command::Checkpoint(_, reply)
        | Command::SelectModel { reply, .. } => {
            let _ = reply.send(Err(error));
        }
        Command::Prepare(_, reply) | Command::Steer(_, reply) => {
            let _ = reply.send(Err(error));
        }
        Command::Connect(reply) => {
            let _ = reply.send(Err(error));
        }
        Command::Run { reply, .. } => {
            let _ = reply.send(Err(AgentError::RuntimeClosed));
        }
        Command::Subscribe(sender) => {
            let _ = sender.unbounded_send(Arc::new(NativeRuntimeEvent::Notice {
                generation: 0,
                message: error.to_string(),
            }));
        }
        _ => {}
    }
}
