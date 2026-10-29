//! ACP 会话运行时（story 5.2）：后台线程持有长驻连接，UI 经有界事件通道消费。
//!
//! 设计约束（来自 5.1 tracer）：
//! - `connect_with` 的 future 跑在专用后台线程，GPUI 主线程只收发通道消息；
//! - 事件经有界 `sync_channel`（背压，不丢增量）；
//! - 初始化/建档 45s、单回合 60s 预算；Stop 丢弃请求（SDK drop 取消）并回报 cancelled；
//! - 审批请求只转发给 UI，默认回 Cancelled（不默认允许）；
//! - 日志不打印凭证/对话内容。

use std::collections::HashMap;
use std::path::PathBuf;
use std::str::FromStr;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{sync_channel, Receiver, SyncSender};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use agent_client_protocol::schema::v1::{
    AvailableCommand, CancelNotification, ContentBlock, InitializeRequest, ListSessionsRequest,
    LoadSessionRequest, McpServer, NewSessionRequest, PermissionOption, PermissionOptionKind,
    PromptRequest, RequestPermissionOutcome, RequestPermissionRequest, RequestPermissionResponse,
    SelectedPermissionOutcome, SessionConfigId, SessionConfigKind, SessionConfigOption,
    SessionConfigOptionCategory, SessionConfigOptionValue, SessionConfigSelectOptions,
    SessionConfigValueId, SessionId, SessionNotification, SessionUpdate,
    SetSessionConfigOptionRequest, StopReason, TextContent, ToolCall, ToolCallContent,
    ToolCallLocation, ToolCallStatus,
};
use agent_client_protocol::schema::{MaybeUndefined, ProtocolVersion};
use agent_client_protocol::{
    on_receive_notification, on_receive_request, AcpAgent, Agent, Client, ConnectTo, ConnectionTo,
    DynConnectTo,
};
use futures::channel::mpsc::{unbounded, UnboundedReceiver, UnboundedSender};
use futures::StreamExt;

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
    pub agent_name: String,
    /// 只在 session/new 注入；含凭证，禁止 Debug/日志输出。
    pub mcp_servers: Vec<McpServer>,
    /// 若设置则 `session/load`（历史恢复），否则 `session/new`。
    pub load_session: Option<String>,
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
        Self {
            command: command.into(),
            cwd,
            agent_name: "agent".to_string(),
            mcp_servers: Vec::new(),
            load_session: None,
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
            .spawn(move || run_thread(config, transport, command_rx, event_tx, pending_for_thread))
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

fn run_thread(
    config: AcpHostConfig,
    transport: HostTransport,
    command_rx: UnboundedReceiver<HostCommand>,
    events: SyncSender<HostEvent>,
    pending_permissions: PendingPermissions,
) {
    let result = futures::executor::block_on(run_connection(
        config,
        transport,
        command_rx,
        events.clone(),
        pending_permissions,
    ));
    if let Err(message) = result {
        send_event(&events, HostEvent::Error { message });
    }
    send_event(&events, HostEvent::Exited);
}

fn send_event(events: &SyncSender<HostEvent>, event: HostEvent) {
    // 有界通道：满了就阻塞后台线程（背压），不静默丢弃增量。
    let _ = events.send(event);
}

async fn run_connection(
    config: AcpHostConfig,
    transport: HostTransport,
    mut command_rx: UnboundedReceiver<HostCommand>,
    events: SyncSender<HostEvent>,
    pending_permissions: PendingPermissions,
) -> Result<(), String> {
    let agent: DynConnectTo<Client> = match transport {
        HostTransport::Subprocess => DynConnectTo::new(
            AcpAgent::from_str(&config.command)
                .map_err(|error| format!("agent launch: {error}"))?,
        ),
        HostTransport::InProcess(agent) => agent,
    };
    let events_for_notifications = events.clone();
    let activity = Arc::new(AtomicU64::new(0));
    let activity_for_notifications = Arc::clone(&activity);
    let events_for_permissions = events.clone();
    let pending_for_permissions = Arc::clone(&pending_permissions);

    let result = Client
        .builder()
        .name("cgc-desktop")
        .on_receive_notification(
            async move |notification: SessionNotification, _cx| {
                let _ = activity_for_notifications.fetch_add(1, Ordering::Relaxed);
                if let Some(event) = host_event_from_update(notification.update) {
                    send_event(&events_for_notifications, event);
                }
                Ok(())
            },
            on_receive_notification!(),
        )
        .on_receive_request(
            async move |request: RequestPermissionRequest, responder, _connection| {
                let counter = PERMISSION_COUNTER.fetch_add(1, Ordering::Relaxed);
                let request_id = format!("perm-{counter}");
                let title = request
                    .tool_call
                    .fields
                    .title
                    .clone()
                    .or_else(|| request.options.first().map(|option| option.name.clone()))
                    .unwrap_or_else(|| "tool approval".to_string());
                let allow_option = request
                    .options
                    .iter()
                    .find(|option| {
                        matches!(
                            option.kind,
                            PermissionOptionKind::AllowOnce | PermissionOptionKind::AllowAlways
                        )
                    })
                    .map(|option| option.option_id.0.to_string());
                let (sender, receiver) = futures::channel::oneshot::channel();
                pending_for_permissions
                    .lock()
                    .expect("pending permissions")
                    .insert(
                        request_id.clone(),
                        PendingPermission {
                            sender,
                            allow_option: allow_option.clone(),
                        },
                    );
                send_event(
                    &events_for_permissions,
                    HostEvent::PermissionRequested {
                        request_id,
                        title,
                        tool_call_id: Some(request.tool_call.tool_call_id.0.to_string()),
                        tool_name: request.tool_call.fields.name.clone(),
                        args: request.tool_call.fields.raw_input.as_ref().map(json_text),
                        options: permission_option_views(&request.options),
                    },
                );
                let timeout = sleep(Duration::from_secs(300));
                futures::pin_mut!(receiver, timeout);
                let choice = match futures::future::select(receiver, timeout).await {
                    futures::future::Either::Left((decision, _)) => decision.unwrap_or(None),
                    futures::future::Either::Right(_) => None,
                };
                let outcome = match choice {
                    Some(option_id) => RequestPermissionOutcome::Selected(
                        SelectedPermissionOutcome::new(option_id),
                    ),
                    None => RequestPermissionOutcome::Cancelled,
                };
                let _ = responder.respond(RequestPermissionResponse::new(outcome));
                Ok(())
            },
            on_receive_request!(),
        )
        .connect_with(agent, async move |connection: ConnectionTo<Agent>| {
            let inner: Result<(), String> = async {
                let init = with_timeout(
                    connection
                        .send_request(InitializeRequest::new(ProtocolVersion::V1))
                        .block_task(),
                    INIT_TIMEOUT,
                    "initialize",
                )
                .await?;
                let agent_name = init
                    .agent_info
                    .as_ref()
                    .map(|info| info.name.clone())
                    .unwrap_or_else(|| config.agent_name.clone());
                let version = init
                    .agent_info
                    .as_ref()
                    .map(|info| info.version.clone())
                    .unwrap_or_default();

                let (session_id, config_options) = if let Some(load_id) = &config.load_session {
                    let request = LoadSessionRequest::new(
                        SessionId::new(load_id.clone()),
                        config.cwd.clone(),
                    )
                    .mcp_servers(config.mcp_servers.clone());
                    let response = with_timeout(
                        connection.send_request(request).block_task(),
                        INIT_TIMEOUT,
                        "session/load",
                    )
                    .await?;
                    (
                        SessionId::new(load_id.clone()),
                        response.config_options.unwrap_or_default(),
                    )
                } else {
                    let session_request = NewSessionRequest::new(config.cwd.clone())
                        .mcp_servers(config.mcp_servers.clone());
                    let session = with_timeout(
                        connection.send_request(session_request).block_task(),
                        INIT_TIMEOUT,
                        "session/new",
                    )
                    .await?;
                    (
                        session.session_id.clone(),
                        session.config_options.unwrap_or_default(),
                    )
                };
                send_event(
                    &events,
                    HostEvent::Ready {
                        agent_name,
                        version,
                        session_id: session_id.to_string(),
                    },
                );
                send_event(
                    &events,
                    HostEvent::ConfigOptions {
                        options: config_option_views(&config_options),
                    },
                );
                if config.list_sessions_after_ready {
                    send_sessions(&connection, &events, &config.cwd).await;
                }

                while let Some(command) = command_rx.next().await {
                    match command {
                        HostCommand::Prompt(text) => {
                            run_turn(
                                &connection,
                                &mut command_rx,
                                &events,
                                session_id.clone(),
                                text,
                                Arc::clone(&activity),
                            )
                            .await;
                        }
                        HostCommand::Stop => {}
                        HostCommand::ListSessions => {
                            send_sessions(&connection, &events, &config.cwd).await;
                        }
                        HostCommand::SetConfig { config_id, value } => {
                            let request = SetSessionConfigOptionRequest::new(
                                session_id.clone(),
                                SessionConfigId::new(config_id),
                                SessionConfigOptionValue::ValueId {
                                    value: SessionConfigValueId::new(value),
                                },
                            );
                            match with_timeout(
                                connection.send_request(request).block_task(),
                                INIT_TIMEOUT,
                                "session/set_config_option",
                            )
                            .await
                            {
                                Ok(response) => send_event(
                                    &events,
                                    HostEvent::ConfigOptions {
                                        options: config_option_views(&response.config_options),
                                    },
                                ),
                                Err(message) => send_event(&events, HostEvent::Error { message }),
                            }
                        }
                        HostCommand::Shutdown => return Ok(()),
                    }
                }
                Ok(())
            }
            .await;
            inner.map_err(|message| agent_client_protocol::Error::internal_error().data(message))
        })
        .await;
    result.map_err(|error| format!("acp connection: {error}"))?;
    Ok(())
}

async fn send_sessions(
    connection: &ConnectionTo<Agent>,
    events: &SyncSender<HostEvent>,
    cwd: &std::path::Path,
) {
    let request = ListSessionsRequest::new().cwd(cwd.to_path_buf());
    match with_timeout(
        connection.send_request(request).block_task(),
        INIT_TIMEOUT,
        "session/list",
    )
    .await
    {
        Ok(response) => send_event(
            events,
            HostEvent::Sessions {
                sessions: response
                    .sessions
                    .into_iter()
                    .map(|session| SessionSummary {
                        session_id: session.session_id.to_string(),
                        title: session.title,
                        updated_at: session.updated_at,
                    })
                    .collect(),
            },
        ),
        Err(message) => send_event(events, HostEvent::Error { message }),
    }
}

fn json_text(value: &serde_json::Value) -> String {
    match value {
        serde_json::Value::String(text) => text.clone(),
        other => other.to_string(),
    }
}

fn debug_label(value: impl std::fmt::Debug) -> String {
    format!("{value:?}").to_lowercase()
}

fn tool_status_label(status: ToolCallStatus) -> String {
    match status {
        ToolCallStatus::Pending => "pending",
        ToolCallStatus::InProgress => "in_progress",
        ToolCallStatus::Completed => "completed",
        ToolCallStatus::Failed => "failed",
        _ => "unknown",
    }
    .to_string()
}

fn tool_output_text(content: &[ToolCallContent]) -> Option<String> {
    let mut parts = Vec::new();
    for item in content {
        match item {
            ToolCallContent::Content(content) => {
                if let ContentBlock::Text(text) = &content.content {
                    parts.push(text.text.clone());
                }
            }
            ToolCallContent::Diff(diff) => parts.push(format!("diff: {}", diff.path.display())),
            ToolCallContent::Terminal(terminal) => {
                parts.push(format!("terminal: {}", terminal.terminal_id.0));
            }
            _ => {}
        }
    }
    (!parts.is_empty()).then(|| parts.join("\n"))
}

fn tool_locations(locations: &[ToolCallLocation]) -> Vec<String> {
    locations
        .iter()
        .map(|location| match location.line {
            Some(line) => format!("{}:{line}", location.path.display()),
            None => location.path.display().to_string(),
        })
        .collect()
}

fn tool_call_view(call: ToolCall) -> ToolCallView {
    ToolCallView {
        tool_call_id: call.tool_call_id.0.to_string(),
        title: call.title,
        name: call.name,
        kind: format!("{:?}", call.kind),
        status: tool_status_label(call.status),
        args: call.raw_input.as_ref().map(json_text),
        output: call
            .raw_output
            .as_ref()
            .map(json_text)
            .or_else(|| tool_output_text(&call.content)),
        locations: tool_locations(&call.locations),
    }
}

/// 把 ACP `session/update` 映射成 UI 事件；未识别/不再关心的变体返回 `None`。
fn host_event_from_update(update: SessionUpdate) -> Option<HostEvent> {
    match update {
        SessionUpdate::AgentMessageChunk(chunk) => match chunk.content {
            ContentBlock::Text(text) => Some(HostEvent::Delta(text.text)),
            _ => None,
        },
        SessionUpdate::AgentThoughtChunk(chunk) => match chunk.content {
            ContentBlock::Text(text) => Some(HostEvent::ThoughtDelta(text.text)),
            _ => None,
        },
        SessionUpdate::UserMessageChunk(chunk) => match chunk.content {
            ContentBlock::Text(text) => Some(HostEvent::UserMessage(text.text)),
            _ => None,
        },
        SessionUpdate::AvailableCommandsUpdate(update) => Some(HostEvent::AvailableCommands {
            commands: command_views(update.available_commands),
        }),
        SessionUpdate::ToolCall(call) => Some(HostEvent::ToolCall {
            call: tool_call_view(call),
        }),
        SessionUpdate::ToolCallUpdate(update) => Some(HostEvent::ToolCallUpdated {
            tool_call_id: update.tool_call_id.0.to_string(),
            title: update.fields.title,
            status: update.fields.status.map(tool_status_label),
            output: update
                .fields
                .raw_output
                .as_ref()
                .map(json_text)
                .or_else(|| update.fields.content.as_deref().and_then(tool_output_text)),
        }),
        SessionUpdate::Plan(plan) => Some(HostEvent::PlanUpdated {
            steps: plan
                .entries
                .into_iter()
                .map(|entry| PlanStepView {
                    content: entry.content,
                    priority: debug_label(entry.priority),
                    status: debug_label(entry.status),
                })
                .collect(),
        }),
        SessionUpdate::UsageUpdate(usage) => Some(HostEvent::UsageUpdated {
            used: usage.used,
            size: usage.size,
            cost: usage
                .cost
                .map(|cost| format!("{:.2} {}", cost.amount, cost.currency)),
        }),
        SessionUpdate::ConfigOptionUpdate(update) => Some(HostEvent::ConfigOptions {
            options: config_option_views(&update.config_options),
        }),
        SessionUpdate::CurrentModeUpdate(update) => Some(HostEvent::ModeUpdated {
            mode_id: update.current_mode_id.0.to_string(),
        }),
        SessionUpdate::SessionInfoUpdate(update) => Some(HostEvent::TitleUpdated {
            title: match update.title {
                MaybeUndefined::Value(title) => Some(title),
                _ => None,
            },
        }),
        SessionUpdate::CompactionUpdate(update) => Some(HostEvent::CompactionUpdated {
            status: debug_label(update.status),
            summary: match update.summary {
                MaybeUndefined::Value(blocks) => {
                    let text = blocks
                        .iter()
                        .filter_map(|block| match block {
                            ContentBlock::Text(text) => Some(text.text.clone()),
                            _ => None,
                        })
                        .collect::<Vec<_>>()
                        .join("\n");
                    (!text.is_empty()).then_some(text)
                }
                _ => match update.error {
                    MaybeUndefined::Value(error) => Some(error),
                    _ => None,
                },
            },
        }),
        _ => None,
    }
}

fn command_views(commands: Vec<AvailableCommand>) -> Vec<CommandView> {
    commands
        .into_iter()
        .map(|command| CommandView {
            name: command.name,
            description: command.description,
            requires_argument: command.input.is_some(),
        })
        .collect()
}

fn permission_option_kind_label(kind: PermissionOptionKind) -> &'static str {
    match kind {
        PermissionOptionKind::AllowOnce => "allow_once",
        PermissionOptionKind::AllowAlways => "allow_always",
        PermissionOptionKind::RejectOnce => "reject_once",
        PermissionOptionKind::RejectAlways => "reject_always",
        _ => "other",
    }
}

fn permission_option_views(options: &[PermissionOption]) -> Vec<PermissionOptionView> {
    options
        .iter()
        .map(|option| PermissionOptionView {
            option_id: option.option_id.0.to_string(),
            name: option.name.clone(),
            kind: permission_option_kind_label(option.kind).to_string(),
        })
        .collect()
}

fn config_category(category: &Option<SessionConfigOptionCategory>) -> ConfigOptionCategory {
    match category {
        Some(SessionConfigOptionCategory::Mode) => ConfigOptionCategory::Mode,
        Some(SessionConfigOptionCategory::Model) => ConfigOptionCategory::Model,
        Some(SessionConfigOptionCategory::ModelConfig) => ConfigOptionCategory::ModelConfig,
        Some(SessionConfigOptionCategory::ThoughtLevel) => ConfigOptionCategory::ThoughtLevel,
        _ => ConfigOptionCategory::Other,
    }
}

fn config_option_views(options: &[SessionConfigOption]) -> Vec<ConfigOptionView> {
    options
        .iter()
        .filter_map(|option| match &option.kind {
            SessionConfigKind::Select(select) => {
                let values = match &select.options {
                    SessionConfigSelectOptions::Ungrouped(options) => options
                        .iter()
                        .map(|value| (value.value.0.to_string(), value.name.clone()))
                        .collect(),
                    SessionConfigSelectOptions::Grouped(groups) => groups
                        .iter()
                        .flat_map(|group| {
                            group
                                .options
                                .iter()
                                .map(|value| (value.value.0.to_string(), value.name.clone()))
                        })
                        .collect(),
                    _ => Vec::new(),
                };
                Some(ConfigOptionView {
                    id: option.id.0.to_string(),
                    name: option.name.clone(),
                    category: config_category(&option.category),
                    current: select.current_value.0.to_string(),
                    values,
                })
            }
            SessionConfigKind::Boolean(value) => Some(ConfigOptionView {
                id: option.id.0.to_string(),
                name: option.name.clone(),
                category: config_category(&option.category),
                current: value.current_value.to_string(),
                values: vec![
                    ("true".to_string(), "开".to_string()),
                    ("false".to_string(), "关".to_string()),
                ],
            }),
            _ => None,
        })
        .collect()
}

async fn run_turn(
    connection: &ConnectionTo<Agent>,
    command_rx: &mut UnboundedReceiver<HostCommand>,
    events: &SyncSender<HostEvent>,
    session_id: SessionId,
    text: String,
    activity: Arc<AtomicU64>,
) {
    let prompt = connection
        .send_request(PromptRequest::new(
            session_id.clone(),
            vec![ContentBlock::Text(TextContent::new(text))],
        ))
        .block_task();
    futures::pin_mut!(prompt);
    // 超时按“活跃阶段”计算：只要 agent 仍在推进（任何 session/update），
    // 就重新计满一轮预算；等待用户审批或长工具执行不会把整轮判成超时。
    let mut seen_activity = activity.load(Ordering::Relaxed);
    let mut last_activity_at = std::time::Instant::now();

    loop {
        let command = command_rx.next();
        futures::pin_mut!(command);
        // 先轮询命令（Stop 优先于同时到达的 prompt 响应），否则用户点停止时
        // 若 agent 恰好同刻收尾，TurnEnd 会被误报成 cancelled=false。
        let command_or_prompt = futures::future::select(command, prompt.as_mut());
        futures::pin_mut!(command_or_prompt);
        let idle = sleep(TURN_TIMEOUT.saturating_sub(last_activity_at.elapsed()));
        futures::pin_mut!(idle);
        match futures::future::select(command_or_prompt, idle).await {
            futures::future::Either::Left((
                futures::future::Either::Right((result, _command)),
                _,
            )) => {
                match result {
                    Ok(response) => {
                        let stop_reason = format!("{:?}", response.stop_reason);
                        send_event(
                            events,
                            HostEvent::TurnEnd {
                                cancelled: response.stop_reason == StopReason::Cancelled,
                                stop_reason,
                            },
                        )
                    }
                    Err(error) => send_event(
                        events,
                        HostEvent::Error {
                            message: format!("turn: {error}"),
                        },
                    ),
                }
                break;
            }
            futures::future::Either::Left((
                futures::future::Either::Left((command, _prompt)),
                _,
            )) => match command {
                Some(HostCommand::Stop) => {
                    // 先发 cancel，再等 prompt 响应一个宽限期：in-process native
                    // server 会立刻回 `stopReason: cancelled`，等它回来再收尾
                    // 才不会和 agent 交还状态竞争；外部 agent 不响应也不会卡住。
                    let _ =
                        connection.send_notification(CancelNotification::new(session_id.clone()));
                    let grace = sleep(CANCEL_GRACE);
                    futures::pin_mut!(grace);
                    match futures::future::select(prompt.as_mut(), grace).await {
                        futures::future::Either::Left((Ok(response), _)) => send_event(
                            events,
                            HostEvent::TurnEnd {
                                cancelled: true,
                                stop_reason: format!("{:?}", response.stop_reason),
                            },
                        ),
                        futures::future::Either::Left((Err(_), _)) => send_event(
                            events,
                            HostEvent::TurnEnd {
                                cancelled: true,
                                stop_reason: "cancelled".to_string(),
                            },
                        ),
                        futures::future::Either::Right(_) => send_event(
                            events,
                            HostEvent::TurnEnd {
                                cancelled: true,
                                stop_reason: "cancelled".to_string(),
                            },
                        ),
                    }
                    break;
                }
                Some(HostCommand::Shutdown) | None => {
                    send_event(
                        events,
                        HostEvent::TurnEnd {
                            cancelled: true,
                            stop_reason: "shutdown".to_string(),
                        },
                    );
                    break;
                }
                Some(HostCommand::Prompt(_))
                | Some(HostCommand::ListSessions)
                | Some(HostCommand::SetConfig { .. }) => {}
            },
            futures::future::Either::Right(_) => {
                let current = activity.load(Ordering::Relaxed);
                if !idle_expired(seen_activity, current) {
                    // 期间有真实进展：重新计一轮空闲预算，而不是把整轮判死。
                    seen_activity = current;
                    last_activity_at = std::time::Instant::now();
                    continue;
                }
                send_event(
                    events,
                    HostEvent::Error {
                        message: "turn timeout".to_string(),
                    },
                );
                break;
            }
        }
    }
}

async fn with_timeout<F, T>(future: F, timeout: Duration, phase: &str) -> Result<T, String>
where
    F: std::future::Future<Output = Result<T, agent_client_protocol::Error>>,
{
    let deadline = sleep(timeout);
    futures::pin_mut!(future, deadline);
    match futures::future::select(future, deadline).await {
        futures::future::Either::Left((result, _)) => {
            result.map_err(|error| format!("{phase}: {error}"))
        }
        futures::future::Either::Right(_) => Err(format!("{phase} timeout")),
    }
}

/// 空闲预算是否真的耗尽：期间只要有过新活动，就应重新计时而不是判超时。
///
/// 审批等待与长工具执行都会产生更新事件；把它们算进“模型沉默”会把正常流程误杀。
fn idle_expired(seen_activity: u64, current_activity: u64) -> bool {
    current_activity == seen_activity
}

fn sleep(duration: Duration) -> impl std::future::Future<Output = ()> {
    let (sender, receiver) = futures::channel::oneshot::channel();
    std::thread::spawn(move || {
        std::thread::sleep(duration);
        let _ = sender.send(());
    });
    async move {
        let _ = receiver.await;
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn turn_timeout_only_counts_silence_not_user_or_tool_waiting() {
        // 期间没有新事件：空闲预算确实耗尽，应判超时。
        assert!(super::idle_expired(7, 7));
        // 期间有进度（审批回传、工具更新、增量）：重新计时，不判超时。
        assert!(!super::idle_expired(7, 8));
        assert!(!super::idle_expired(0, 1));
    }

    #[test]
    fn available_commands_map_to_command_views() {
        let commands = super::command_views(vec![
            agent_client_protocol::schema::v1::AvailableCommand::new(
                "compact",
                "Compact the conversation",
            ),
            agent_client_protocol::schema::v1::AvailableCommand::new(
                "review",
                "Review the current diff",
            )
            .input(
                agent_client_protocol::schema::v1::AvailableCommandInput::Unstructured(
                    agent_client_protocol::schema::v1::UnstructuredCommandInput::new(
                        "file to review",
                    ),
                ),
            ),
        ]);
        assert_eq!(commands.len(), 2);
        assert_eq!(commands[0].name, "compact");
        assert!(!commands[0].requires_argument);
        assert_eq!(commands[1].name, "review");
        assert!(commands[1].requires_argument);
    }

    #[test]
    fn config_categories_map_from_acp_and_preserve_unknown() {
        assert_eq!(
            super::config_category(&Some(
                agent_client_protocol::schema::v1::SessionConfigOptionCategory::Mode
            )),
            super::ConfigOptionCategory::Mode
        );
        assert_eq!(
            super::config_category(&Some(
                agent_client_protocol::schema::v1::SessionConfigOptionCategory::Model
            )),
            super::ConfigOptionCategory::Model
        );
        assert_eq!(
            super::config_category(&Some(
                agent_client_protocol::schema::v1::SessionConfigOptionCategory::ModelConfig
            )),
            super::ConfigOptionCategory::ModelConfig
        );
        assert_eq!(
            super::config_category(&Some(
                agent_client_protocol::schema::v1::SessionConfigOptionCategory::ThoughtLevel
            )),
            super::ConfigOptionCategory::ThoughtLevel
        );
        assert_eq!(
            super::config_category(&Some(
                agent_client_protocol::schema::v1::SessionConfigOptionCategory::Other(
                    "custom".to_string()
                )
            )),
            super::ConfigOptionCategory::Other
        );
        assert_eq!(
            super::config_category(&None),
            super::ConfigOptionCategory::Other
        );
    }

    use super::*;

    #[test]
    fn config_debug_does_not_leak_mcp_credentials() {
        use agent_client_protocol::schema::v1::{HttpHeader, McpServerHttp};
        let server = McpServer::Http(
            McpServerHttp::new("cgc-2046", "http://127.0.0.1:4000/mcp").headers(vec![
                HttpHeader::new("Authorization", "Bearer super-secret-token"),
            ]),
        );
        let config =
            AcpHostConfig::new("omp acp", PathBuf::from("/tmp")).with_mcp_servers(vec![server]);
        let debug = format!("{config:?}");
        assert!(!debug.contains("super-secret-token"));
        assert!(!debug.contains("Authorization"));
        assert!(debug.contains("mcp_servers: 1"));
    }

    #[test]
    fn empty_command_is_rejected() {
        let error = match AcpHost::start(AcpHostConfig::new("", PathBuf::from("/tmp"))) {
            Ok(_) => panic!("empty command must be rejected"),
            Err(error) => error,
        };
        assert_eq!(error, HostError::EmptyCommand);
    }

    /// HITL：真实 OMP。默认 ignored，手动：
    /// `cargo test -p cgc-platform real_omp -- --ignored --nocapture`
    #[test]
    #[ignore = "spawns the real omp agent; run manually for HITL"]
    fn real_omp_round_trip_and_stop() {
        let host =
            AcpHost::start(AcpHostConfig::new("omp acp", PathBuf::from("/tmp")).with_name("omp"))
                .expect("start host");
        let ready = wait_for(&host, |event| matches!(event, HostEvent::Ready { .. }), 60);
        assert!(matches!(ready, HostEvent::Ready { .. }), "ready: {ready:?}");

        assert!(host.prompt("请只回复 ok 两个字母"));
        let mut text = String::new();
        let mut ended = false;
        let deadline = std::time::Instant::now() + Duration::from_secs(90);
        while std::time::Instant::now() < deadline {
            match host.recv_timeout(Duration::from_secs(5)) {
                Some(HostEvent::Delta(chunk)) => text.push_str(&chunk),
                Some(HostEvent::TurnEnd { .. }) => {
                    ended = true;
                    break;
                }
                Some(HostEvent::Error { message }) => panic!("host error: {message}"),
                Some(_) => {}
                None => {}
            }
        }
        assert!(ended, "turn did not end");
        assert!(!text.trim().is_empty(), "no streamed text");
        host.shutdown();
    }

    /// HITL：真实 OMP 的 Stop 路径。手动：`cargo test -p cgc-platform real_omp_stop -- --ignored --nocapture`
    #[test]
    #[ignore = "spawns the real omp agent; run manually for HITL"]
    fn real_omp_stop_cancels_turn() {
        let host =
            AcpHost::start(AcpHostConfig::new("omp acp", PathBuf::from("/tmp")).with_name("omp"))
                .expect("start host");
        wait_for(&host, |event| matches!(event, HostEvent::Ready { .. }), 60);
        assert!(host.prompt("请写一篇 500 字的散文，慢慢写"));
        std::thread::sleep(Duration::from_millis(500));
        assert!(host.stop());
        let mut cancelled = false;
        let deadline = std::time::Instant::now() + Duration::from_secs(15);
        while std::time::Instant::now() < deadline {
            if let Some(HostEvent::TurnEnd {
                cancelled: true, ..
            }) = host.recv_timeout(Duration::from_millis(500))
            {
                cancelled = true;
                break;
            }
        }
        assert!(cancelled, "stop did not produce cancelled turn end");
        host.shutdown();
    }

    fn wait_for(host: &AcpHost, predicate: impl Fn(&HostEvent) -> bool, seconds: u64) -> HostEvent {
        let deadline = std::time::Instant::now() + Duration::from_secs(seconds);
        while std::time::Instant::now() < deadline {
            if let Some(event) = host.recv_timeout(Duration::from_millis(500)) {
                if predicate(&event) {
                    return event;
                }
            }
        }
        panic!("event not received within {seconds}s");
    }

    #[test]
    fn tool_call_maps_id_status_args_output_and_locations() {
        use agent_client_protocol::schema::v1::{
            ToolCall, ToolCallLocation, ToolCallStatus, ToolKind,
        };
        let call = ToolCall::new("call-1", "Edit file")
            .name("edit_file")
            .kind(ToolKind::Edit)
            .status(ToolCallStatus::InProgress)
            .raw_input(serde_json::json!({"path": "src/main.rs"}))
            .raw_output(serde_json::json!({"ok": true}))
            .locations(vec![ToolCallLocation::new("/tmp/a.rs").line(Some(3))]);
        let event = super::host_event_from_update(SessionUpdate::ToolCall(call)).expect("event");
        let HostEvent::ToolCall { call } = event else {
            panic!("expected ToolCall event");
        };
        assert_eq!(call.tool_call_id, "call-1");
        assert_eq!(call.title, "Edit file");
        assert_eq!(call.name.as_deref(), Some("edit_file"));
        assert_eq!(call.kind, "Edit");
        assert_eq!(call.status, "in_progress");
        assert_eq!(call.args.as_deref(), Some(r#"{"path":"src/main.rs"}"#));
        assert_eq!(call.output.as_deref(), Some(r#"{"ok":true}"#));
        assert_eq!(call.locations, vec!["/tmp/a.rs:3"]);
    }

    #[test]
    fn tool_call_update_maps_status_title_and_output() {
        use agent_client_protocol::schema::v1::{
            ToolCallStatus, ToolCallUpdate, ToolCallUpdateFields,
        };
        let update = ToolCallUpdate::new(
            "call-1",
            ToolCallUpdateFields::new()
                .title(Some("Edited".to_string()))
                .status(Some(ToolCallStatus::Completed))
                .raw_output(Some(serde_json::json!("done"))),
        );
        let event =
            super::host_event_from_update(SessionUpdate::ToolCallUpdate(update)).expect("event");
        let HostEvent::ToolCallUpdated {
            tool_call_id,
            title,
            status,
            output,
        } = event
        else {
            panic!("expected ToolCallUpdated");
        };
        assert_eq!(tool_call_id, "call-1");
        assert_eq!(title.as_deref(), Some("Edited"));
        assert_eq!(status.as_deref(), Some("completed"));
        assert_eq!(output.as_deref(), Some("done"));
    }

    #[test]
    fn tool_call_content_is_flattened_when_raw_output_missing() {
        use agent_client_protocol::schema::v1::{TextContent, ToolCall, ToolCallContent};
        let call = ToolCall::new("call-2", "Read file")
            .kind(agent_client_protocol::schema::v1::ToolKind::Read)
            .content(vec![ToolCallContent::Content(
                agent_client_protocol::schema::v1::Content::new(
                    agent_client_protocol::schema::v1::ContentBlock::Text(TextContent::new(
                        "line 1",
                    )),
                ),
            )]);
        let event = super::host_event_from_update(SessionUpdate::ToolCall(call)).expect("event");
        let HostEvent::ToolCall { call } = event else {
            panic!("expected ToolCall");
        };
        assert_eq!(call.output.as_deref(), Some("line 1"));
    }

    #[test]
    fn plan_and_usage_updates_map_to_events() {
        use agent_client_protocol::schema::v1::{
            Plan, PlanEntry, PlanEntryPriority, PlanEntryStatus, UsageUpdate,
        };
        let plan = Plan::new(vec![
            PlanEntry::new(
                "inspect",
                PlanEntryPriority::High,
                PlanEntryStatus::Completed,
            ),
            PlanEntry::new(
                "implement",
                PlanEntryPriority::Medium,
                PlanEntryStatus::InProgress,
            ),
        ]);
        let event = super::host_event_from_update(SessionUpdate::Plan(plan)).expect("event");
        let HostEvent::PlanUpdated { steps } = event else {
            panic!("expected PlanUpdated");
        };
        assert_eq!(steps.len(), 2);
        assert_eq!(steps[0].content, "inspect");
        assert_eq!(steps[0].priority, "high");
        assert_eq!(steps[0].status, "completed");
        assert_eq!(steps[1].status, "inprogress");

        let usage = UsageUpdate::new(1200, 64_000);
        let event =
            super::host_event_from_update(SessionUpdate::UsageUpdate(usage)).expect("event");
        let HostEvent::UsageUpdated { used, size, cost } = event else {
            panic!("expected UsageUpdated");
        };
        assert_eq!((used, size, cost), (1200, 64_000, None));
    }

    #[test]
    fn user_message_chunks_map_to_user_messages() {
        use agent_client_protocol::schema::v1::{ContentBlock, ContentChunk, TextContent};
        let event = super::host_event_from_update(SessionUpdate::UserMessageChunk(
            ContentChunk::new(ContentBlock::Text(TextContent::new("after"))),
        ))
        .expect("user message event");
        assert_eq!(event, HostEvent::UserMessage("after".to_string()));
    }

    #[test]
    fn compaction_update_prefers_summary_text_and_falls_back_to_error() {
        use agent_client_protocol::schema::v1::{
            CompactionStatus, CompactionUpdate, ContentBlock, TextContent,
        };
        let with_summary =
            CompactionUpdate::new("cmp-1", CompactionStatus::Completed).summary(vec![
                ContentBlock::Text(TextContent::new("省略 3 条更早消息")),
            ]);
        let event = super::host_event_from_update(SessionUpdate::CompactionUpdate(with_summary))
            .expect("compaction event");
        assert_eq!(
            event,
            HostEvent::CompactionUpdated {
                status: "completed".to_string(),
                summary: Some("省略 3 条更早消息".to_string()),
            }
        );

        let with_error =
            CompactionUpdate::new("cmp-2", CompactionStatus::Failed).error("boom".to_string());
        let event = super::host_event_from_update(SessionUpdate::CompactionUpdate(with_error))
            .expect("compaction event");
        assert_eq!(
            event,
            HostEvent::CompactionUpdated {
                status: "failed".to_string(),
                summary: Some("boom".to_string()),
            }
        );
    }

    #[test]
    fn permission_options_keep_ids_names_and_kind_labels() {
        use agent_client_protocol::schema::v1::{PermissionOption, PermissionOptionKind};
        let options = super::permission_option_views(&[
            PermissionOption::new("allow_once", "Allow once", PermissionOptionKind::AllowOnce),
            PermissionOption::new(
                "allow_session",
                "Allow session",
                PermissionOptionKind::AllowAlways,
            ),
            PermissionOption::new("deny", "Deny", PermissionOptionKind::RejectOnce),
        ]);
        assert_eq!(
            options,
            vec![
                super::PermissionOptionView {
                    option_id: "allow_once".to_string(),
                    name: "Allow once".to_string(),
                    kind: "allow_once".to_string(),
                },
                super::PermissionOptionView {
                    option_id: "allow_session".to_string(),
                    name: "Allow session".to_string(),
                    kind: "allow_always".to_string(),
                },
                super::PermissionOptionView {
                    option_id: "deny".to_string(),
                    name: "Deny".to_string(),
                    kind: "reject_once".to_string(),
                },
            ]
        );
    }

    #[test]
    fn unknown_session_update_is_ignored() {
        use agent_client_protocol::schema::v1::{CurrentModeUpdate, SessionModeId};
        let event = super::host_event_from_update(SessionUpdate::CurrentModeUpdate(
            CurrentModeUpdate::new(SessionModeId::new("plan")),
        ))
        .expect("mode event");
        assert_eq!(
            event,
            HostEvent::ModeUpdated {
                mode_id: "plan".to_string()
            }
        );
    }
}
