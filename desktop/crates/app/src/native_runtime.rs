//! A single actor owns each native Agent. Cloneable handles carry commands only.

mod checkpoint;
mod execution;
mod factory;
mod mcp;
mod operations;
mod title;
mod worker;

use cgc_agent_checkpoint::{Checkpoint, FileChange};
use cgc_agent_core::{AgentError, ImageAttachment, Thread, ToolTurnOutcome};
use cgc_agent_host::{AgentEvent, NativeTurn, NativeTurnRuntime};
use cgc_agent_provider::{Model, Provider, ToolSchema};
use cgc_agent_store::{ProviderPrefs, SessionStore};
use cgc_agent_tools::{AgentState, AppAction, ToolContext, ToolRegistry};
use futures::{
    channel::{mpsc, oneshot},
    future::BoxFuture,
};
use std::future::Future;
use std::{path::PathBuf, sync::Arc};

use crate::{
    agent_scope::AgentScope,
    native_panel_host::{McpContext, NativePanelHost},
};

#[derive(Clone)]
pub struct NativeRuntimeConfig {
    pub provider: Arc<dyn Provider>,
    pub model: Model,
    pub registry: Arc<ToolRegistry>,
    pub context: ToolContext,
    pub context_size: u64,
    pub auto_approve: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RuntimePhase {
    Loading,
    Idle,
    Running,
    Draining,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ApprovalMode {
    Ask,
    Auto,
}

impl ApprovalMode {
    pub fn label(self) -> &'static str {
        match self {
            Self::Ask => "Ask",
            Self::Auto => "Auto",
        }
    }
}

/// Immutable execution projection. It cannot take, replace, or mutate the Agent.
pub struct NativeRuntimeSnapshot {
    pub thread: Arc<Thread>,
    pub model: Arc<Model>,
    pub workspace: Arc<PathBuf>,
    pub phase: RuntimePhase,
    pub generation: u64,
    pub revision: u64,
    pub authorization_epoch: u64,
    pub mcp_unavailable_reason: Option<Arc<str>>,
    pub display_title: Option<Arc<str>>,
    pub schemas: Arc<Vec<ToolSchema>>,
    pub providers: Arc<Vec<ProviderPrefs>>,
    pub using_echo: bool,
    pub thinking_enabled: bool,
    pub effort_index: usize,
    pub approval_mode: ApprovalMode,
    pub checkpoints: Arc<Vec<(usize, Checkpoint)>>,
    pub changes: Arc<Vec<FileChange>>,
    pub agent_state: Arc<AgentState>,
    pub persistence_available: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RuntimeChange {
    Initialized,
    Connected,
    Activity,
    Opened,
    Rewound,
    Configuration,
    Title,
    Checkpoint,
    Tools,
}

pub enum NativeRuntimeEvent {
    Snapshot {
        change: RuntimeChange,
        snapshot: Arc<NativeRuntimeSnapshot>,
    },
    Notice {
        generation: u64,
        message: String,
    },
    Subagent {
        generation: u64,
        event: AgentEvent,
    },
    AppAction {
        generation: u64,
        workspace: PathBuf,
        action: AppAction,
    },
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum NativeRuntimeError {
    Busy,
    StaleConnection,
    Closed,
    MissingThread,
    Configuration(String),
    Storage(String),
    Checkpoint(String),
}

impl std::fmt::Display for NativeRuntimeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Busy => f.write_str("当前会话仍在运行，请完成或停止后再切换"),
            Self::StaleConnection => f.write_str("连接已被新的会话替换"),
            Self::Closed => f.write_str("native runtime 已关闭"),
            Self::MissingThread => f.write_str("会话不存在"),
            Self::Configuration(message) => write!(f, "模型配置不可用：{message}"),
            Self::Storage(message) => write!(f, "会话存储失败：{message}"),
            Self::Checkpoint(message) => write!(f, "检查点操作失败：{message}"),
        }
    }
}

pub struct PreparedNativeTurn {
    pub thread_id: String,
    pub generation: u64,
    pub display: String,
    pub images: Vec<ImageAttachment>,
    pub retry: bool,
}

pub enum CheckpointAction {
    KeepAll,
    KeepFile(String),
    RestoreAll,
    RestoreFile(String),
}
type Reply<T> = oneshot::Sender<Result<T, NativeRuntimeError>>;

#[derive(Clone)]
pub struct NativeRuntimeHandle {
    commands: Arc<mpsc::UnboundedSender<Command>>,
    /// 最近一次发布的快照镜像：视图首帧可以同步读到，不依赖异步事件是否已送达。
    latest: Arc<std::sync::Mutex<Option<Arc<NativeRuntimeSnapshot>>>>,
}

/// One server binding, not another runtime owner.
pub struct NativeRuntimeConnection {
    handle: NativeRuntimeHandle,
    generation: u64,
    thread_id: String,
}

enum Command {
    Subscribe(mpsc::UnboundedSender<Arc<NativeRuntimeEvent>>),
    Inspect(Reply<Arc<NativeRuntimeSnapshot>>),
    Connect(Reply<NativeRuntimeConnection>),
    Disconnect(u64),
    Run {
        generation: u64,
        thread_id: String,
        turn: NativeTurn,
        reply: oneshot::Sender<Result<ToolTurnOutcome, AgentError>>,
    },
    Prepare(PreparedNativeTurn, Reply<()>),
    Stop,
    Steer(String, Reply<()>),
    Open(String, Reply<Arc<NativeRuntimeSnapshot>>),
    New(Reply<Arc<NativeRuntimeSnapshot>>),
    SwitchScope(AgentScope, Reply<Arc<NativeRuntimeSnapshot>>),
    Rewind {
        ordinal: usize,
        restore_files: bool,
        reply: Reply<Arc<NativeRuntimeSnapshot>>,
    },
    Checkpoint(CheckpointAction, Reply<Arc<NativeRuntimeSnapshot>>),
    SelectModel {
        provider: String,
        model: String,
        reply: Reply<Arc<NativeRuntimeSnapshot>>,
    },
    Thinking {
        enabled: bool,
        effort_index: usize,
    },
    Approval(ApprovalMode),
    Rename(Option<String>),
    GenerateTitle(bool),
    Mcp {
        context: Option<McpContext>,
        epoch: u64,
    },
    Subagent {
        generation: u64,
        event: AgentEvent,
    },
    AppAction {
        generation: u64,
        workspace: PathBuf,
        action: AppAction,
    },
    ToolStateChanged,
}

impl NativeRuntimeHandle {
    /// Headless callers supply their real runtime dependencies; the same actor executes them.
    pub fn spawn(
        thread: Thread,
        system_prompt: Option<String>,
        config: NativeRuntimeConfig,
        store: Option<SessionStore>,
    ) -> Self {
        Self::start(worker::Initialization::Explicit {
            thread: Box::new(thread),
            system_prompt,
            config: Box::new(config),
            store,
        })
    }

    pub(crate) fn for_scope(
        scope: AgentScope,
        data_root: PathBuf,
        host: NativePanelHost,
        authorization_epoch: u64,
    ) -> Self {
        Self::start(worker::Initialization::Workspace {
            scope,
            data_root,
            host,
            authorization_epoch,
        })
    }

    fn start(initialization: worker::Initialization) -> Self {
        let (sender, receiver) = mpsc::unbounded();
        let commands = Arc::new(sender);
        let latest = Arc::new(std::sync::Mutex::new(None));
        let weak = Arc::downgrade(&commands);
        let latest_for_owner = Arc::clone(&latest);
        std::thread::Builder::new()
            .name("native-agent-owner".into())
            .spawn(move || {
                futures::executor::block_on(worker::run(
                    initialization,
                    weak,
                    receiver,
                    latest_for_owner,
                ))
            })
            .expect("start native runtime owner");
        Self { commands, latest }
    }

    /// 同步读取最近快照；`None` 表示 owner 还没完成初始化。
    pub fn latest_snapshot(&self) -> Option<Arc<NativeRuntimeSnapshot>> {
        self.latest.lock().ok().and_then(|slot| slot.clone())
    }

    fn request<T: Send + 'static>(
        &self,
        build: impl FnOnce(Reply<T>) -> Command,
    ) -> impl Future<Output = Result<T, NativeRuntimeError>> + Send + 'static {
        let (reply, result) = oneshot::channel();
        let sent = self.commands.unbounded_send(build(reply)).is_ok();
        async move {
            if !sent {
                return Err(NativeRuntimeError::Closed);
            }
            result.await.unwrap_or(Err(NativeRuntimeError::Closed))
        }
    }

    pub fn subscribe(&self) -> mpsc::UnboundedReceiver<Arc<NativeRuntimeEvent>> {
        let (sender, receiver) = mpsc::unbounded();
        let _ = self.commands.unbounded_send(Command::Subscribe(sender));
        receiver
    }

    pub fn inspect(
        &self,
    ) -> impl Future<Output = Result<Arc<NativeRuntimeSnapshot>, NativeRuntimeError>> + Send + 'static
    {
        self.request(Command::Inspect)
    }
    pub fn connect(
        &self,
    ) -> impl Future<Output = Result<NativeRuntimeConnection, NativeRuntimeError>> + Send + 'static
    {
        self.request(Command::Connect)
    }
    pub fn prepare(
        &self,
        turn: PreparedNativeTurn,
    ) -> impl Future<Output = Result<(), NativeRuntimeError>> + Send + 'static {
        self.request(|reply| Command::Prepare(turn, reply))
    }
    pub fn stop(&self) {
        let _ = self.commands.unbounded_send(Command::Stop);
    }
    pub fn steer(
        &self,
        text: String,
    ) -> impl Future<Output = Result<(), NativeRuntimeError>> + Send + 'static {
        self.request(|reply| Command::Steer(text, reply))
    }
    pub fn open_thread(
        &self,
        id: String,
    ) -> impl Future<Output = Result<Arc<NativeRuntimeSnapshot>, NativeRuntimeError>> + Send + 'static
    {
        self.request(|reply| Command::Open(id, reply))
    }
    pub fn new_thread(
        &self,
    ) -> impl Future<Output = Result<Arc<NativeRuntimeSnapshot>, NativeRuntimeError>> + Send + 'static
    {
        self.request(Command::New)
    }
    pub(crate) fn switch_scope(
        &self,
        scope: AgentScope,
    ) -> impl Future<Output = Result<Arc<NativeRuntimeSnapshot>, NativeRuntimeError>> + Send + 'static
    {
        self.request(|reply| Command::SwitchScope(scope, reply))
    }
    pub fn rewind(
        &self,
        ordinal: usize,
        restore_files: bool,
    ) -> impl Future<Output = Result<Arc<NativeRuntimeSnapshot>, NativeRuntimeError>> + Send + 'static
    {
        self.request(move |reply| Command::Rewind {
            ordinal,
            restore_files,
            reply,
        })
    }
    pub fn checkpoint(
        &self,
        action: CheckpointAction,
    ) -> impl Future<Output = Result<Arc<NativeRuntimeSnapshot>, NativeRuntimeError>> + Send + 'static
    {
        self.request(|reply| Command::Checkpoint(action, reply))
    }
    pub fn select_model(
        &self,
        provider: String,
        model: String,
    ) -> impl Future<Output = Result<Arc<NativeRuntimeSnapshot>, NativeRuntimeError>> + Send + 'static
    {
        self.request(|reply| Command::SelectModel {
            provider,
            model,
            reply,
        })
    }
    pub fn set_thinking(&self, enabled: bool, effort_index: usize) {
        let _ = self.commands.unbounded_send(Command::Thinking {
            enabled,
            effort_index,
        });
    }
    pub fn set_approval(&self, mode: ApprovalMode) {
        let _ = self.commands.unbounded_send(Command::Approval(mode));
    }
    pub fn rename(&self, title: Option<String>) {
        let _ = self.commands.unbounded_send(Command::Rename(title));
    }
    pub fn generate_title(&self, force: bool) {
        let _ = self.commands.unbounded_send(Command::GenerateTitle(force));
    }
    pub(crate) fn set_mcp_context(&self, context: Option<McpContext>, epoch: u64) {
        let _ = self
            .commands
            .unbounded_send(Command::Mcp { context, epoch });
    }
}

impl NativeTurnRuntime for NativeRuntimeConnection {
    fn run_turn(
        &mut self,
        turn: NativeTurn,
    ) -> BoxFuture<'static, Result<ToolTurnOutcome, AgentError>> {
        let (reply, result) = oneshot::channel();
        let sent = self
            .handle
            .commands
            .unbounded_send(Command::Run {
                generation: self.generation,
                thread_id: self.thread_id.clone(),
                turn,
                reply,
            })
            .is_ok();
        Box::pin(async move {
            if !sent {
                return Err(AgentError::RuntimeClosed);
            }
            result.await.unwrap_or(Err(AgentError::RuntimeClosed))
        })
    }
}

impl NativeRuntimeConnection {
    pub fn generation(&self) -> u64 {
        self.generation
    }
    pub fn thread_id(&self) -> &str {
        &self.thread_id
    }
}

impl Drop for NativeRuntimeConnection {
    fn drop(&mut self) {
        let _ = self
            .handle
            .commands
            .unbounded_send(Command::Disconnect(self.generation));
    }
}
