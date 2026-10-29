//! native agent 的进程内 ACP server（Stage 3 设计 §4 Phase A / 切片 3.1）。
//!
//! 把现有 native 运行时「包装成 ACP agent」：客户端（桌面 app）用与外部 ACP agent
//! 完全相同的连接/ingestion 路径（`cgc_platform::acp::connection::AcpHost`），只是
//! transport 换成进程内 `agent-client-protocol` 的 `Channel`，不起子进程、不走 stdio。
//!
//! 分工：
//! - 协议壳（本模块）：`initialize` / `session/new` / `session/prompt` /
//!   `session/cancel`、turn 生命周期、并发/重复请求守卫；
//! - 事件映射（[`updates`]）：native `AgentEvent` → ACP `SessionUpdate`；
//! - 审批（[`permission`]）：native `Approver` → ACP `session/request_permission`；
//! - 运行时（[`NativeTurnRuntime`]）：由 app 提供（provider/tools/Agent 都在 app 侧），
//!   测试用 fake。native 专属能力（附件/queue/steer/checkpoint）不经过本适配层，
//!   仍在 native 运行时的现有接口上，Phase B 再迁。
//!
//! 协议版本用 ACP v1（`agent-client-protocol 3.4` 的 `Agent` 角色），不自己写 JSON-RPC。

mod permission;
mod updates;

use updates::EventSink;

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use agent_client_protocol::schema::v1::{
    AgentCapabilities, CancelNotification, ContentBlock, Implementation, InitializeRequest,
    InitializeResponse, NewSessionRequest, NewSessionResponse, PromptRequest, PromptResponse,
    SessionId, SessionNotification, StopReason as AcpStopReason,
};
use agent_client_protocol::{
    on_receive_notification, on_receive_request, Agent, Client, ConnectTo, ConnectionTo, Error,
};
use cgc_agent_core::{AgentError, Approver, ToolTurnOutcome, TurnObserver};
use cgc_agent_provider::StopReason;
use futures::channel::mpsc::{unbounded, UnboundedSender};
use futures::channel::oneshot;
use futures::StreamExt;

pub use permission::{
    allow_pattern_option_id, permission_pattern_prefix, OPTION_ALLOW_ONCE, OPTION_ALLOW_SESSION,
    OPTION_DENY,
};

/// native server 的标识信息（`initialize` 回给客户端的 agent_info）。
#[derive(Clone, Debug)]
pub struct NativeAcpServerConfig {
    pub agent_name: String,
    pub version: String,
}

impl Default for NativeAcpServerConfig {
    fn default() -> Self {
        Self {
            agent_name: "cgc-native".to_string(),
            version: env!("CARGO_PKG_VERSION").to_string(),
        }
    }
}

/// 可用 session 的上下文窗口（usage_update 的 `size`），由 app 在模型/设置变化时更新。
pub type ContextSizeHandle = Arc<AtomicU64>;

/// 一次 `session/prompt` 交给 native 运行时执行的任务描述。
pub struct NativeTurn {
    pub session_id: String,
    pub prompt: String,
    /// 过程事件出口：映射成 ACP `session/update` 后发给客户端。
    pub observer: Box<dyn TurnObserver + Send>,
    /// 审批出口：实现为 ACP `session/request_permission` 往返。
    pub approver: Arc<dyn Approver>,
    /// turn 级取消信号（`session/cancel` / server 关闭）。runtime 应把它转发给
    /// 自己的取消机制（例如 `Agent::cancel_token()`）。
    pub cancel: CancelSwitch,
}

impl std::fmt::Debug for NativeTurn {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("NativeTurn")
            .field("session_id", &self.session_id)
            .field("prompt_len", &self.prompt.len())
            .finish_non_exhaustive()
    }
}

/// native 运行时出口；由 app 的 native runtime 实现（测试用 fake）。
///
/// `run_turn` 在 server 的 turn 任务里执行（不在连接 dispatch loop 内），因此
/// 可以长时间 await，也可以发起 `request_permission` 反向请求。
pub trait NativeTurnRuntime: Send + 'static {
    fn run_turn(
        &mut self,
        turn: NativeTurn,
    ) -> futures::future::BoxFuture<'static, Result<ToolTurnOutcome, AgentError>>;
}

/// turn 级取消开关：server 在 `session/cancel` 时触发；runtime 注册回调把取消
/// 转发给自身（例如 `Agent::cancel_token().cancel()`），审批桥也在这里等取消。
#[derive(Clone, Default)]
pub struct CancelSwitch {
    inner: Arc<CancelSwitchInner>,
}

#[derive(Default)]
struct CancelSwitchInner {
    cancelled: AtomicBool,
    callback: Mutex<Option<Box<dyn Fn() + Send + Sync>>>,
    waiters: Mutex<Vec<oneshot::Sender<()>>>,
}

impl CancelSwitch {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn is_cancelled(&self) -> bool {
        self.inner.cancelled.load(Ordering::SeqCst)
    }

    /// 触发取消；重复调用是 no-op（回调/等待者只跑一次）。
    pub fn cancel(&self) {
        if self.inner.cancelled.swap(true, Ordering::SeqCst) {
            return;
        }
        if let Some(callback) = self.inner.callback.lock().expect("cancel callback").take() {
            callback();
        }
        for waiter in self.inner.waiters.lock().expect("cancel waiters").drain(..) {
            let _ = waiter.send(());
        }
    }

    /// 注册取消回调；已经取消时立即执行（避免注册竞态吃掉这次取消）。
    pub fn on_cancel(&self, callback: impl Fn() + Send + Sync + 'static) {
        let mut slot = self.inner.callback.lock().expect("cancel callback");
        if self.is_cancelled() {
            drop(slot);
            callback();
            return;
        }
        *slot = Some(Box::new(callback));
        // 注册后再次检查：cancel 可能刚好发生在检查与写入之间。
        if self.is_cancelled() {
            let callback = slot.take();
            drop(slot);
            if let Some(callback) = callback {
                callback();
            }
        }
    }

    /// 等待取消（审批桥用）。已取消时立即返回。
    pub(crate) async fn cancelled(&self) {
        if self.is_cancelled() {
            return;
        }
        let (sender, receiver) = oneshot::channel();
        self.inner
            .waiters
            .lock()
            .expect("cancel waiters")
            .push(sender);
        if self.is_cancelled() {
            // cancel 恰好发生在 push 之前：waiters 已被 drain，直接返回。
            return;
        }
        let _ = receiver.await;
    }
}

/// 进程内 ACP server（Agent 角色）。交给
/// `cgc_platform::acp::connection::AcpHost::start_in_process` 驱动。
pub struct NativeAcpServer {
    runtime: Arc<futures::lock::Mutex<Box<dyn NativeTurnRuntime>>>,
    state: Arc<Mutex<ServerState>>,
    context_size: ContextSizeHandle,
    config: NativeAcpServerConfig,
}

#[derive(Default)]
struct ServerState {
    sessions: HashMap<String, SessionState>,
    next_session: u64,
}

#[derive(Default)]
struct SessionState {
    /// 正在跑的 turn；`None` = 空闲。
    active: Option<CancelSwitch>,
}

enum TurnStart {
    Started(CancelSwitch),
    Busy,
    UnknownSession,
}

impl NativeAcpServer {
    pub fn new(runtime: Box<dyn NativeTurnRuntime>) -> Self {
        Self {
            runtime: Arc::new(futures::lock::Mutex::new(runtime)),
            state: Arc::new(Mutex::new(ServerState::default())),
            context_size: Arc::new(AtomicU64::new(0)),
            config: NativeAcpServerConfig::default(),
        }
    }

    pub fn with_config(mut self, config: NativeAcpServerConfig) -> Self {
        self.config = config;
        self
    }

    /// 共享的上下文窗口句柄；app 在模型切换时 `store` 新值，下一次 turn 的
    /// `usage_update.size` 用它。
    pub fn context_size_handle(&self) -> ContextSizeHandle {
        Arc::clone(&self.context_size)
    }

    fn begin_turn(&self, session_id: &SessionId) -> TurnStart {
        let mut state = self.state.lock().expect("native acp state");
        let Some(session) = state.sessions.get_mut(session_id.0.as_ref()) else {
            return TurnStart::UnknownSession;
        };
        if session.active.is_some() {
            return TurnStart::Busy;
        }
        let cancel = CancelSwitch::new();
        session.active = Some(cancel.clone());
        TurnStart::Started(cancel)
    }

    fn end_turn(&self, session_id: &SessionId) {
        let mut state = self.state.lock().expect("native acp state");
        if let Some(session) = state.sessions.get_mut(session_id.0.as_ref()) {
            session.active = None;
        }
    }

    fn new_session(&self, request: &NewSessionRequest) -> NewSessionResponse {
        let mut state = self.state.lock().expect("native acp state");
        state.next_session += 1;
        let session_id = format!("native-session-{}", state.next_session);
        state
            .sessions
            .insert(session_id.clone(), SessionState::default());
        let _ = request;
        NewSessionResponse::new(session_id)
    }

    fn cancel_session(&self, session_id: &SessionId) {
        let state = self.state.lock().expect("native acp state");
        if let Some(session) = state.sessions.get(session_id.0.as_ref()) {
            if let Some(cancel) = &session.active {
                cancel.cancel();
            }
        }
    }
}

impl ConnectTo<Client> for NativeAcpServer {
    async fn connect_to(self, client: impl ConnectTo<Agent>) -> Result<(), Error> {
        let config = self.config.clone();
        let server = Arc::new(self);
        let server_for_new_session = Arc::clone(&server);
        let server_for_prompt = Arc::clone(&server);
        let server_for_cancel = Arc::clone(&server);

        Agent
            .builder()
            .name(config.agent_name.clone())
            .on_receive_request(
                async move |request: InitializeRequest, responder, _cx| {
                    responder.respond(
                        InitializeResponse::new(request.protocol_version)
                            .agent_capabilities(AgentCapabilities::new())
                            .agent_info(Implementation::new(
                                config.agent_name.clone(),
                                config.version.clone(),
                            )),
                    )
                },
                on_receive_request!(),
            )
            .on_receive_request(
                async move |request: NewSessionRequest, responder, _cx| {
                    responder.respond(server_for_new_session.new_session(&request))
                },
                on_receive_request!(),
            )
            .on_receive_request(
                async move |request: PromptRequest, responder, cx| {
                    handle_prompt(Arc::clone(&server_for_prompt), request, responder, cx)
                },
                on_receive_request!(),
            )
            .on_receive_notification(
                async move |notification: CancelNotification, _cx| {
                    server_for_cancel.cancel_session(&notification.session_id);
                    Ok(())
                },
                on_receive_notification!(),
            )
            .connect_to(client)
            .await
    }
}

fn handle_prompt(
    server: Arc<NativeAcpServer>,
    request: PromptRequest,
    responder: agent_client_protocol::Responder<PromptResponse>,
    cx: ConnectionTo<Client>,
) -> Result<(), Error> {
    let prompt = prompt_text(&request.prompt);
    if prompt.is_empty() {
        return responder
            .respond_with_error(Error::invalid_params().data("prompt has no text content"));
    }
    let cancel = match server.begin_turn(&request.session_id) {
        TurnStart::Started(cancel) => cancel,
        TurnStart::Busy => {
            return responder
                .respond_with_error(Error::invalid_request().data("a turn is already running"));
        }
        TurnStart::UnknownSession => {
            return responder.respond_with_error(
                Error::invalid_params().data(format!("unknown session: {}", request.session_id.0)),
            );
        }
    };
    let context_size = server.context_size.load(Ordering::Relaxed);
    let session_id = request.session_id.clone();
    let session_key = session_id.0.to_string();
    let runtime = Arc::clone(&server.runtime);
    let state = Arc::clone(&server.state);
    let session_for_spawn_error = request.session_id.clone();
    let connection = cx.clone();
    let spawned = cx.spawn(async move {
        let mut pump = EventPump::start(connection.clone(), session_id.clone(), context_size);
        let approver: Arc<dyn Approver> = Arc::new(permission::PermissionBridge {
            connection: connection.clone(),
            session_id: session_id.clone(),
            cancel: cancel.clone(),
        });
        let turn = NativeTurn {
            session_id: session_key.clone(),
            prompt,
            observer: Box::new(pump.sink()),
            approver,
            cancel: cancel.clone(),
        };
        let result = {
            let mut runtime = runtime.lock().await;
            runtime.run_turn(turn).await
        };
        pump.flush().await;
        let mut state = state.lock().expect("native acp state");
        if let Some(session) = state.sessions.get_mut(&session_key) {
            session.active = None;
        }
        drop(state);
        let cancelled = cancel.is_cancelled();
        match result {
            Ok(outcome) if !cancelled => {
                let _ =
                    responder.respond(PromptResponse::new(acp_stop_reason(outcome.stop_reason)));
            }
            Ok(_) | Err(AgentError::Cancelled) => {
                let _ = responder.respond(PromptResponse::new(AcpStopReason::Cancelled));
            }
            Err(error) => {
                let _ = responder.respond_with_error(
                    Error::internal_error().data(format!("native turn failed: {error}")),
                );
            }
        }
        Ok(())
    });
    if spawned.is_err() {
        // 连接的任务运行器已关闭：客户端已断开，没有 response 可回，只要把
        // 会话恢复成空闲，避免后续 prompt 被误判为 Busy。
        server.end_turn(&session_for_spawn_error);
    }
    Ok(())
}

fn prompt_text(blocks: &[ContentBlock]) -> String {
    blocks
        .iter()
        .filter_map(|block| match block {
            ContentBlock::Text(text) => Some(text.text.as_str()),
            _ => None,
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn acp_stop_reason(stop_reason: StopReason) -> AcpStopReason {
    match stop_reason {
        StopReason::EndTurn => AcpStopReason::EndTurn,
        StopReason::MaxTokens => AcpStopReason::MaxTokens,
        StopReason::ContentFilter => AcpStopReason::Refusal,
        StopReason::ToolUse | StopReason::Other(_) => AcpStopReason::EndTurn,
    }
}

/// 事件泵消息：`Event` 是 runtime 过程事件；`Flush` 用于 turn 收尾前确认所有
/// update 已发出（不依赖 observer drop 时序）。
pub(crate) enum PumpMessage {
    Event(crate::events::AgentEvent),
    Flush(oneshot::Sender<()>),
}

struct EventPump {
    sender: UnboundedSender<PumpMessage>,
}

impl EventPump {
    fn start(cx: ConnectionTo<Client>, session_id: SessionId, context_size: u64) -> Self {
        let (sender, mut receiver) = unbounded();
        let connection = cx.clone();
        let _ = cx.spawn(async move {
            let mut ticket = updates::UpdateTicket::new(context_size);
            while let Some(message) = receiver.next().await {
                match message {
                    PumpMessage::Event(event) => {
                        for update in ticket.updates(&event) {
                            if connection
                                .send_notification(SessionNotification::new(
                                    session_id.clone(),
                                    update,
                                ))
                                .is_err()
                            {
                                return Ok(());
                            }
                        }
                    }
                    PumpMessage::Flush(ack) => {
                        let _ = ack.send(());
                    }
                }
            }
            Ok(())
        });
        Self { sender }
    }

    fn sink(&self) -> EventSink {
        EventSink::new(self.sender.clone())
    }

    async fn flush(&mut self) {
        let (ack_sender, ack_receiver) = oneshot::channel();
        if self
            .sender
            .unbounded_send(PumpMessage::Flush(ack_sender))
            .is_ok()
        {
            let _ = ack_receiver.await;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicUsize;

    #[test]
    fn cancel_switch_fires_callback_and_waiters_once() {
        let switch = CancelSwitch::new();
        let calls = Arc::new(AtomicUsize::new(0));
        let calls_for_callback = Arc::clone(&calls);
        switch.on_cancel(move || {
            calls_for_callback.fetch_add(1, Ordering::SeqCst);
        });
        assert!(!switch.is_cancelled());
        switch.cancel();
        switch.cancel();
        assert!(switch.is_cancelled());
        assert_eq!(calls.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn cancel_switch_after_cancel_runs_callback_immediately() {
        let switch = CancelSwitch::new();
        switch.cancel();
        let called = Arc::new(AtomicBool::new(false));
        let called_for_callback = Arc::clone(&called);
        switch.on_cancel(move || {
            called_for_callback.store(true, Ordering::SeqCst);
        });
        assert!(called.load(Ordering::SeqCst));
    }

    #[test]
    fn cancel_switch_await_returns_immediately_when_already_cancelled() {
        let switch = CancelSwitch::new();
        switch.cancel();
        futures::executor::block_on(switch.cancelled());
    }

    #[test]
    fn acp_stop_reason_maps_native_reasons() {
        assert_eq!(acp_stop_reason(StopReason::EndTurn), AcpStopReason::EndTurn);
        assert_eq!(
            acp_stop_reason(StopReason::MaxTokens),
            AcpStopReason::MaxTokens
        );
        assert_eq!(
            acp_stop_reason(StopReason::ContentFilter),
            AcpStopReason::Refusal
        );
        assert_eq!(acp_stop_reason(StopReason::ToolUse), AcpStopReason::EndTurn);
    }
}
