//! ACP 会话运行时（story 5.2）：后台线程持有长驻连接，UI 经有界事件通道消费。
//!
//! 设计约束（来自 5.1 tracer）：
//! - `connect_with` 的 future 跑在专用后台线程，GPUI 主线程只收发通道消息；
//! - 事件经有界 `sync_channel`（背压，不丢增量）；
//! - 初始化/建档 45s、单回合 60s 预算；Stop 丢弃请求（SDK drop 取消）并回报 cancelled；
//! - 审批请求只转发给 UI，默认回 Cancelled（不默认允许）；
//! - 日志不打印凭证/对话内容。

use crate::agent::launch::{inherited_environment, LaunchPlan};
use std::collections::{BTreeMap, HashMap};
use std::path::PathBuf;
use std::sync::atomic::AtomicU64;
use std::sync::mpsc::{sync_channel, Receiver, SyncSender};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use agent_client_protocol::schema::v1::McpServer;
use agent_client_protocol::{Client, ConnectTo, DynConnectTo};
use futures::channel::mpsc::{unbounded, UnboundedSender};

mod auth;
mod events;
mod runner;
mod sessions;
mod turn;

pub(super) fn send_event(events: &SyncSender<HostEvent>, event: HostEvent) {
    let _ = events.send(event);
}

pub(super) fn json_text(value: &serde_json::Value) -> String {
    match value {
        serde_json::Value::String(text) => text.clone(),
        other => other.to_string(),
    }
}

#[cfg(test)]
#[path = "connection/tests.rs"]
mod tests;
#[cfg(test)]
#[path = "connection/tests_events.rs"]
mod tests_events;

const INIT_TIMEOUT: Duration = Duration::from_secs(45);
const TURN_TIMEOUT: Duration = Duration::from_secs(60);
/// cancel 后等 agent 回 `stopReason: cancelled` 的宽限期；超时才合成 TurnEnd。
const CANCEL_GRACE: Duration = Duration::from_secs(2);
const EVENT_CAPACITY: usize = 256;
static PERMISSION_COUNTER: AtomicU64 = AtomicU64::new(1);

#[derive(Clone)]
pub struct AcpHostConfig {
    pub command: String,
    pub cwd: PathBuf,
    pub env: BTreeMap<String, String>,
    pub agent_name: String,
    /// 只在 session/new 注入；含凭证，禁止 Debug/日志输出。
    pub mcp_servers: Vec<McpServer>,
    /// 若设置则 `session/load`（历史恢复），否则 `session/new`。
    pub load_session: Option<String>,
    /// 若设置则 `session/resume`（历史恢复）。用于不支持 `session/load` 的
    /// agent；与 `load_session` 互斥，优先 load。
    pub resume_session: Option<String>,
    /// 打开连接后拉取历史列表。
    pub list_sessions_after_ready: bool,
}

impl std::fmt::Debug for AcpHostConfig {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("AcpHostConfig")
            .field("command", &self.command)
            .field("cwd", &self.cwd)
            .field("agent_name", &self.agent_name)
            .field("mcp_servers", &self.mcp_servers.len())
            .finish()
    }
}

impl AcpHostConfig {
    pub fn new(command: impl Into<String>, cwd: PathBuf) -> Self {
        Self::with_process(
            command.into(),
            cwd,
            inherited_environment(|key| std::env::var(key).ok()),
        )
    }

    pub fn from_launch_plan(plan: LaunchPlan) -> Self {
        Self::with_process(plan.command_string(), plan.cwd, plan.env)
    }

    fn with_process(command: String, cwd: PathBuf, env: BTreeMap<String, String>) -> Self {
        Self {
            command,
            cwd,
            env,
            agent_name: "agent".to_string(),
            mcp_servers: Vec::new(),
            load_session: None,
            resume_session: None,
            list_sessions_after_ready: false,
        }
    }

    pub fn with_name(mut self, name: impl Into<String>) -> Self {
        self.agent_name = name.into();
        self
    }

    pub fn with_mcp_servers(mut self, servers: Vec<McpServer>) -> Self {
        self.mcp_servers = servers;
        self
    }

    pub fn with_load_session(mut self, session_id: impl Into<String>) -> Self {
        self.load_session = Some(session_id.into());
        self
    }

    /// 使用 `session/resume` 恢复会话（agent 不实现 `session/load` 时）。
    pub fn with_resume_session(mut self, session_id: impl Into<String>) -> Self {
        self.resume_session = Some(session_id.into());
        self
    }

    /// Ready 后拉取 `session/list`（cwd 过滤由请求携带）。
    pub fn with_list_sessions_after_ready(mut self, enabled: bool) -> Self {
        self.list_sessions_after_ready = enabled;
        self
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SessionSummary {
    pub session_id: String,
    pub title: Option<String>,
    pub updated_at: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ConfigOptionCategory {
    Mode,
    Model,
    ModelConfig,
    ThoughtLevel,
    Other,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ConfigOptionView {
    pub id: String,
    pub name: String,
    pub category: ConfigOptionCategory,
    pub current: String,
    pub values: Vec<(String, String)>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CommandView {
    pub name: String,
    pub description: String,
    pub requires_argument: bool,
}

/// 工具卡视图：字段全部可选/降级，兼容只发 `ToolCall` 不发 `ToolCallUpdate` 的旧 agent。
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct ToolCallView {
    pub tool_call_id: String,
    pub title: String,
    pub name: Option<String>,
    pub kind: String,
    pub status: String,
    /// 原始入参的 JSON 文本（`None` 表示 agent 没给；可能含敏感内容，只用于本地展示）。
    pub args: Option<String>,
    /// 原始输出/内容文本（可能含敏感内容，只用于本地展示）。
    pub output: Option<String>,
    pub locations: Vec<String>,
}

/// 计划步骤视图（ACP `Plan` 每次全量替换）。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PlanStepView {
    pub content: String,
    pub priority: String,
    pub status: String,
}

/// 审批选项视图（ACP `request_permission` 的 options 原样透传）。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PermissionOptionView {
    pub option_id: String,
    pub name: String,
    /// `allow_once` / `allow_always` / `reject_once` / `reject_always` / `other`。
    pub kind: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AuthMethodView {
    pub id: String,
    pub name: String,
    pub description: Option<String>,
    /// `agent`（由 adapter 处理）或 `terminal`（客户端执行命令）。
    pub kind: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum HostEvent {
    Ready {
        agent_name: String,
        version: String,
        session_id: String,
    },
    Delta(String),
    ThoughtDelta(String),
    /// 用户消息（native follow-up/steer 等 agent 侧产生的插话，经 ACP
    /// `user_message_chunk` 回放）。与 `Delta` 同一 ingestion 落成 User 行。
    UserMessage(String),
    AvailableCommands {
        commands: Vec<CommandView>,
    },
    ToolCall {
        call: ToolCallView,
    },
    /// 工具状态/输出更新：按 `tool_call_id` 合并到已有工具卡。
    ToolCallUpdated {
        tool_call_id: String,
        title: Option<String>,
        status: Option<String>,
        output: Option<String>,
        /// 工具入参（0.4.41 的 dsh presenter 会在后续 update 中补全）。
        args: Option<String>,
        /// 0.4.41 起 dsh tool presenter 会转发 location 集合；None 表示本次不更新。
        locations: Option<Vec<String>>,
    },
    PlanUpdated {
        steps: Vec<PlanStepView>,
    },
    UsageUpdated {
        used: u64,
        size: u64,
        cost: Option<String>,
    },
    TitleUpdated {
        title: Option<String>,
    },
    ModeUpdated {
        mode_id: String,
    },
    CompactionUpdated {
        status: String,
        summary: Option<String>,
    },
    /// 审批请求：UI 必须显式允许/拒绝（5.7）。request_id 用于回传决定。
    ///
    /// `options` 是 agent 提供的选项（native 4 档 / external ACP 原样透传）；
    /// 客户端用 [`AcpHost::respond_permission_option`] 按 option_id 精确回传，
    /// 旧 UI 仍可用 [`AcpHost::respond_permission`] 折成允许/拒绝。
    PermissionRequested {
        request_id: String,
        title: String,
        tool_call_id: Option<String>,
        tool_name: Option<String>,
        args: Option<String>,
        options: Vec<PermissionOptionView>,
    },
    Sessions {
        sessions: Vec<SessionSummary>,
    },
    ConfigOptions {
        options: Vec<ConfigOptionView>,
    },
    TurnEnd {
        cancelled: bool,
        stop_reason: String,
    },
    /// agent 返回 `-32000 auth_required`：UI 需要收集 DeepSeek Key 后重连。
    ///
    /// 客户端默认不调用 ACP `authenticate`：openma 的 `api-key` 方法会把明文写入
    /// `$DSH_HOME/.credentials.yaml`。P3 走 keychain env-only + 重启 adapter。
    AuthRequired {
        message: String,
        auth_methods: Vec<AuthMethodView>,
    },
    Error {
        message: String,
    },
    Exited,
}

#[derive(Debug)]
pub enum HostCommand {
    Prompt(String),
    Stop,
    ListSessions,
    SetConfig { config_id: String, value: String },
    Shutdown,
}

#[derive(Debug, PartialEq, Eq)]
pub enum HostError {
    EmptyCommand,
    Thread(String),
}

impl std::fmt::Display for HostError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            HostError::EmptyCommand => formatter.write_str("agent command is empty"),
            HostError::Thread(reason) => write!(formatter, "cannot start host thread: {reason}"),
        }
    }
}

impl std::error::Error for HostError {}

pub struct AcpHost {
    command_tx: UnboundedSender<HostCommand>,
    /// `Option` 只为 `shutdown` 能在 join 前主动丢弃接收端（见 `shutdown`）。
    events: Option<Receiver<HostEvent>>,
    pending_permissions: Arc<Mutex<HashMap<String, PendingPermission>>>,
    thread: Option<std::thread::JoinHandle<()>>,
}

/// agent 端 transport：外部子进程，或进程内组件（native-as-ACP，Stage 3.1）。
enum HostTransport {
    Subprocess,
    InProcess(DynConnectTo<Client>),
}

/// 用户在审批卡上选的 option id；`None` 表示取消（不选任何选项）。
type PermissionChoice = Option<String>;

pub(crate) struct PendingPermission {
    pub(crate) sender: futures::channel::oneshot::Sender<PermissionChoice>,
    /// 旧 UI 的「允许」折叠成的选项（第一个 allow_* 选项）。
    pub(crate) allow_option: Option<String>,
}

type PendingPermissions = Arc<Mutex<HashMap<String, PendingPermission>>>;

impl AcpHost {
    pub fn start(config: AcpHostConfig) -> Result<Self, HostError> {
        if config.command.trim().is_empty() {
            return Err(HostError::EmptyCommand);
        }
        Self::start_with_transport(config, HostTransport::Subprocess)
    }

    /// 进程内 agent（native-as-ACP）：不拉起子进程、不走 stdio，直接与同进程
    /// 的 ACP agent 组件（`agent_host::NativeAcpServer`）经内存 channel 通信。
    ///
    /// 除 transport 外与 [`Self::start`] 完全同一条客户端路径（initialize、
    /// session/new、session/update → [`HostEvent`]、审批 request、cancel）。
    pub fn start_in_process(
        config: AcpHostConfig,
        agent: impl ConnectTo<Client> + 'static,
    ) -> Result<Self, HostError> {
        Self::start_with_transport(config, HostTransport::InProcess(DynConnectTo::new(agent)))
    }

    fn start_with_transport(
        config: AcpHostConfig,
        transport: HostTransport,
    ) -> Result<Self, HostError> {
        let (command_tx, command_rx) = unbounded();
        let (event_tx, events) = sync_channel(EVENT_CAPACITY);
        let pending_permissions: PendingPermissions = Arc::new(Mutex::new(HashMap::new()));
        let pending_for_thread = Arc::clone(&pending_permissions);
        let thread = std::thread::Builder::new()
            .name("cgc-acp-host".to_string())
            .spawn(move || {
                runner::run_thread(config, transport, command_rx, event_tx, pending_for_thread)
            })
            .map_err(|error| HostError::Thread(error.to_string()))?;
        Ok(Self {
            command_tx,
            events: Some(events),
            pending_permissions,
            thread: Some(thread),
        })
    }

    pub fn prompt(&self, text: impl Into<String>) -> bool {
        self.command_tx
            .unbounded_send(HostCommand::Prompt(text.into()))
            .is_ok()
    }

    pub fn stop(&self) -> bool {
        self.command_tx.unbounded_send(HostCommand::Stop).is_ok()
    }

    pub fn list_sessions(&self) -> bool {
        self.command_tx
            .unbounded_send(HostCommand::ListSessions)
            .is_ok()
    }

    pub fn set_config(&self, config_id: impl Into<String>, value: impl Into<String>) -> bool {
        self.command_tx
            .unbounded_send(HostCommand::SetConfig {
                config_id: config_id.into(),
                value: value.into(),
            })
            .is_ok()
    }

    /// 显式回答审批请求；allow=false 等价取消。返回是否找到该请求。
    ///
    /// 旧 UI 只有允许/拒绝两态：允许时折成 agent 提供的第一个 allow_* 选项。
    /// 需要精确选择（native 4 档、ACP 多选题）时用
    /// [`Self::respond_permission_option`]。
    pub fn respond_permission(&self, request_id: &str, allow: bool) -> bool {
        let pending = self
            .pending_permissions
            .lock()
            .expect("pending permissions")
            .remove(request_id);
        pending
            .map(|pending| {
                let choice = if allow { pending.allow_option } else { None };
                pending.sender.send(choice).is_ok()
            })
            .unwrap_or(false)
    }

    /// 按 option_id 回传选择（ACP `selected` 形状）；未知请求返回 false。
    ///
    /// 重复回传同一 request 是 no-op（请求已被移出 pending 表），保证审批
    /// 去重不会回退成第二次答复。
    pub fn respond_permission_option(
        &self,
        request_id: &str,
        option_id: impl Into<String>,
    ) -> bool {
        let pending = self
            .pending_permissions
            .lock()
            .expect("pending permissions")
            .remove(request_id);
        pending
            .map(|pending| pending.sender.send(Some(option_id.into())).is_ok())
            .unwrap_or(false)
    }

    pub fn try_recv(&self) -> Option<HostEvent> {
        self.events.as_ref()?.try_recv().ok()
    }

    pub fn recv_timeout(&self, timeout: Duration) -> Option<HostEvent> {
        self.events.as_ref()?.recv_timeout(timeout).ok()
    }

    pub fn shutdown(mut self) {
        let _ = self.command_tx.unbounded_send(HostCommand::Shutdown);
        // 先丢弃事件接收端：消费方若已停止读事件（窗口关闭、测试收尾），host 线程
        // 会阻塞在 `events.send` 上，`join()` 就永远等不到它退出。丢掉接收端后
        // 那次 send 立刻返回错误，线程走完收尾自然结束。
        self.events.take();
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

impl Drop for AcpHost {
    fn drop(&mut self) {
        let _ = self.command_tx.unbounded_send(HostCommand::Shutdown);
        // 不 join：连接线程在下一个事件点退出；AcpAgent 析构回收子进程。
    }
}
