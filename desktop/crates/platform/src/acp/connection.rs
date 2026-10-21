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
    CancelNotification, ContentBlock, InitializeRequest, ListSessionsRequest, LoadSessionRequest,
    McpServer, NewSessionRequest, PromptRequest, RequestPermissionOutcome,
    RequestPermissionRequest, RequestPermissionResponse, SelectedPermissionOutcome,
    SessionConfigId, SessionConfigKind, SessionConfigOption, SessionConfigOptionCategory,
    SessionConfigOptionValue, SessionConfigSelectOptions, SessionConfigValueId, SessionId,
    SessionNotification, SessionUpdate, SetSessionConfigOptionRequest, TextContent,
};
use agent_client_protocol::schema::ProtocolVersion;
use agent_client_protocol::{
    on_receive_notification, on_receive_request, AcpAgent, Agent, Client, ConnectionTo,
};
use futures::channel::mpsc::{unbounded, UnboundedReceiver, UnboundedSender};
use futures::StreamExt;

const INIT_TIMEOUT: Duration = Duration::from_secs(45);
const TURN_TIMEOUT: Duration = Duration::from_secs(60);
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
pub enum HostEvent {
    Ready {
        agent_name: String,
        version: String,
        session_id: String,
    },
    Delta(String),
    ThoughtDelta(String),
    ToolCall {
        title: String,
        kind: String,
    },
    /// 审批请求：UI 必须显式允许/拒绝（5.7）。request_id 用于回传决定。
    PermissionRequested {
        request_id: String,
        title: String,
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
    events: Receiver<HostEvent>,
    pending_permissions: Arc<Mutex<HashMap<String, PendingPermission>>>,
    thread: Option<std::thread::JoinHandle<()>>,
}

pub(crate) struct PendingPermission {
    pub(crate) sender: futures::channel::oneshot::Sender<bool>,
}

type PendingPermissions = Arc<Mutex<HashMap<String, PendingPermission>>>;

impl AcpHost {
    pub fn start(config: AcpHostConfig) -> Result<Self, HostError> {
        if config.command.trim().is_empty() {
            return Err(HostError::EmptyCommand);
        }
        let (command_tx, command_rx) = unbounded();
        let (event_tx, events) = sync_channel(EVENT_CAPACITY);
        let pending_permissions: PendingPermissions = Arc::new(Mutex::new(HashMap::new()));
        let pending_for_thread = Arc::clone(&pending_permissions);
        let thread = std::thread::Builder::new()
            .name("cgc-acp-host".to_string())
            .spawn(move || run_thread(config, command_rx, event_tx, pending_for_thread))
            .map_err(|error| HostError::Thread(error.to_string()))?;
        Ok(Self {
            command_tx,
            events,
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
    pub fn respond_permission(&self, request_id: &str, allow: bool) -> bool {
        let pending = self
            .pending_permissions
            .lock()
            .expect("pending permissions")
            .remove(request_id);
        pending
            .map(|pending| pending.sender.send(allow).is_ok())
            .unwrap_or(false)
    }

    pub fn try_recv(&self) -> Option<HostEvent> {
        self.events.try_recv().ok()
    }

    pub fn recv_timeout(&self, timeout: Duration) -> Option<HostEvent> {
        self.events.recv_timeout(timeout).ok()
    }

    pub fn shutdown(mut self) {
        let _ = self.command_tx.unbounded_send(HostCommand::Shutdown);
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
    command_rx: UnboundedReceiver<HostCommand>,
    events: SyncSender<HostEvent>,
    pending_permissions: PendingPermissions,
) {
    let result = futures::executor::block_on(run_connection(
        config,
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
    mut command_rx: UnboundedReceiver<HostCommand>,
    events: SyncSender<HostEvent>,
    pending_permissions: PendingPermissions,
) -> Result<(), String> {
    let agent =
        AcpAgent::from_str(&config.command).map_err(|error| format!("agent launch: {error}"))?;
    let events_for_notifications = events.clone();
    let events_for_permissions = events.clone();
    let pending_for_permissions = Arc::clone(&pending_permissions);

    let result = Client
        .builder()
        .name("cgc-desktop")
        .on_receive_notification(
            async move |notification: SessionNotification, _cx| {
                match notification.update {
                    SessionUpdate::AgentMessageChunk(chunk) => {
                        if let ContentBlock::Text(text) = chunk.content {
                            send_event(&events_for_notifications, HostEvent::Delta(text.text));
                        }
                    }
                    SessionUpdate::AgentThoughtChunk(chunk) => {
                        if let ContentBlock::Text(text) = chunk.content {
                            send_event(
                                &events_for_notifications,
                                HostEvent::ThoughtDelta(text.text),
                            );
                        }
                    }
                    SessionUpdate::ToolCall(call) => {
                        send_event(
                            &events_for_notifications,
                            HostEvent::ToolCall {
                                title: call.title,
                                kind: format!("{:?}", call.kind),
                            },
                        );
                    }
                    _ => {}
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
                            agent_client_protocol::schema::v1::PermissionOptionKind::AllowOnce
                                | agent_client_protocol::schema::v1::PermissionOptionKind::AllowAlways
                        )
                    })
                    .map(|option| option.option_id.0.to_string());
                let (sender, receiver) = futures::channel::oneshot::channel();
                pending_for_permissions
                    .lock()
                    .expect("pending permissions")
                    .insert(
                        request_id.clone(),
                        PendingPermission { sender },
                    );
                send_event(
                    &events_for_permissions,
                    HostEvent::PermissionRequested {
                        request_id,
                        title,
                    },
                );
                let timeout = sleep(Duration::from_secs(300));
                futures::pin_mut!(receiver, timeout);
                let allowed = match futures::future::select(receiver, timeout).await {
                    futures::future::Either::Left((decision, _)) => decision.unwrap_or(false),
                    futures::future::Either::Right(_) => false,
                };
                let outcome = if allowed {
                    match allow_option {
                        Some(option_id) => RequestPermissionOutcome::Selected(
                            SelectedPermissionOutcome::new(option_id),
                        ),
                        None => RequestPermissionOutcome::Cancelled,
                    }
                } else {
                    RequestPermissionOutcome::Cancelled
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
                                Err(message) => {
                                    send_event(&events, HostEvent::Error { message })
                                }
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
) {
    let prompt = connection
        .send_request(PromptRequest::new(
            session_id.clone(),
            vec![ContentBlock::Text(TextContent::new(text))],
        ))
        .block_task();
    futures::pin_mut!(prompt);
    let deadline = sleep(TURN_TIMEOUT);
    futures::pin_mut!(deadline);

    loop {
        let command = command_rx.next();
        futures::pin_mut!(command);
        let prompt_or_command = futures::future::select(prompt.as_mut(), command);
        futures::pin_mut!(prompt_or_command);
        match futures::future::select(prompt_or_command, deadline.as_mut()).await {
            futures::future::Either::Left((
                futures::future::Either::Left((result, _command)),
                _,
            )) => {
                match result {
                    Ok(response) => send_event(
                        events,
                        HostEvent::TurnEnd {
                            cancelled: false,
                            stop_reason: format!("{:?}", response.stop_reason),
                        },
                    ),
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
                futures::future::Either::Right((command, _prompt)),
                _,
            )) => match command {
                Some(HostCommand::Stop) => {
                    let _ =
                        connection.send_notification(CancelNotification::new(session_id.clone()));
                    send_event(
                        events,
                        HostEvent::TurnEnd {
                            cancelled: true,
                            stop_reason: "cancelled".to_string(),
                        },
                    );
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
}
