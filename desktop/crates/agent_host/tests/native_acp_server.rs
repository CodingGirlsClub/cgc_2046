//! native-as-ACP server 的端到端测试（Stage 3.1 Phase A）。
//!
//! 走真实链路：`NativeAcpServer`（进程内 ACP agent）↔ `agent-client-protocol`
//! 内存 `Channel` ↔ `cgc_platform::acp::connection::AcpHost`（与外部 ACP agent
//! 完全相同的客户端路径）→ `HostEvent` 序列。
//!
//! 覆盖：golden 事件序列、最终文本兜底、权限 4 档往返、cancel、并发/重复请求守卫。

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use agent_client_protocol::schema::v1::{
    ContentBlock, InitializeRequest, NewSessionRequest, PromptRequest, SessionId, TextContent,
};
use agent_client_protocol::schema::ProtocolVersion;
use agent_client_protocol::{Channel, Client, ConnectTo};
use cgc_agent_core::{
    AgentError, ApprovalRequest, Approver, ToolResultSummary, ToolTurnOutcome, TurnObserver,
};
use cgc_agent_host::{
    NativeAcpServer, NativeTurn, NativeTurnRuntime, OPTION_ALLOW_ONCE, OPTION_ALLOW_SESSION,
    OPTION_DENY,
};
use cgc_agent_provider::{StopReason, TokenUsage, ToolUse};
use cgc_platform::acp::connection::{AcpHost, AcpHostConfig, HostEvent, ToolCallView};
use futures::future::BoxFuture;

// ---------------------------------------------------------------------------
// fake native runtime
// ---------------------------------------------------------------------------

#[derive(Default)]
struct FakeState {
    /// 依次经 observer 发出的过程事件。
    script: Vec<cgc_agent_host::AgentEvent>,
    /// 若设置：run_turn 里发起一次审批请求并记录用户决定。
    permission: Option<ApprovalRequest>,
    decision: Option<cgc_agent_tools::ApprovalDecision>,
    /// run_turn 完成结果。
    outcome: Option<ToolTurnOutcome>,
    /// run_turn 开始信号（守卫测试用来等第一个 turn 真的在跑）。
    started: Option<futures::channel::oneshot::Sender<()>>,
    /// run_turn 等待这个 gate 才结束（守卫测试制造长 turn）。
    gate: Option<futures::channel::oneshot::Receiver<()>>,
    /// 模拟 native runtime：cancel 后返回 Err(Cancelled)。
    cancel_observed: Arc<AtomicBool>,
    cancel_then_fail: bool,
}

#[derive(Clone, Default)]
struct FakeRuntime {
    state: Arc<Mutex<FakeState>>,
}

impl FakeRuntime {
    fn new() -> Self {
        Self::default()
    }

    fn with_script(script: Vec<cgc_agent_host::AgentEvent>) -> Self {
        let runtime = Self::new();
        runtime.state.lock().unwrap().script = script;
        runtime
    }

    fn state(&self) -> std::sync::MutexGuard<'_, FakeState> {
        self.state.lock().expect("fake runtime")
    }
}

impl NativeTurnRuntime for FakeRuntime {
    fn run_turn(
        &mut self,
        turn: NativeTurn,
    ) -> BoxFuture<'static, Result<ToolTurnOutcome, AgentError>> {
        let state = Arc::clone(&self.state);
        Box::pin(async move {
            let (script, permission, gate, cancel_observed, cancel_then_fail) = {
                let mut state = state.lock().expect("fake runtime");
                if let Some(started) = state.started.take() {
                    let _ = started.send(());
                }
                (
                    std::mem::take(&mut state.script),
                    state.permission.take(),
                    state.gate.take(),
                    Arc::clone(&state.cancel_observed),
                    state.cancel_then_fail,
                )
            };
            let mut observer = turn.observer;
            for event in &script {
                emit(&mut *observer, event);
            }
            let approver: Arc<dyn Approver> = turn.approver;
            let mut decision = None;
            if let Some(request) = permission {
                decision = Some(approver.decide(request).await);
            }
            if let Some(gate) = gate {
                let _ = gate.await;
            }
            if cancel_then_fail {
                // 对齐真实 native runtime：注册取消回调后等 cancel，再返回 Cancelled。
                let (cancel_tx, cancel_rx) = futures::channel::oneshot::channel();
                let cancel_tx = Arc::new(Mutex::new(Some(cancel_tx)));
                let cancel_for_callback = Arc::clone(&cancel_tx);
                let cancel_observed_for_callback = Arc::clone(&cancel_observed);
                turn.cancel.on_cancel(move || {
                    cancel_observed_for_callback.store(true, Ordering::SeqCst);
                    if let Some(sender) = cancel_for_callback.lock().unwrap().take() {
                        let _ = sender.send(());
                    }
                });
                if turn.cancel.is_cancelled() {
                    cancel_observed.store(true, Ordering::SeqCst);
                }
                let _ = cancel_rx.await;
                return Err(AgentError::Cancelled);
            }
            let outcome = {
                let mut state = state.lock().expect("fake runtime");
                state.decision = decision;
                state.outcome.clone()
            };
            let outcome = outcome.unwrap_or_else(|| ToolTurnOutcome {
                text: String::new(),
                usage: TokenUsage::default(),
                stop_reason: StopReason::EndTurn,
                tool_calls: Vec::new(),
                tool_results: Vec::new(),
            });
            observer.on_finished(&outcome);
            Ok(outcome)
        })
    }
}

/// 把 `AgentEvent` 回放到 `TurnObserver`（fake runtime 用）。
fn emit(observer: &mut dyn TurnObserver, event: &cgc_agent_host::AgentEvent) {
    use cgc_agent_host::AgentEvent;
    match event {
        AgentEvent::TurnStarted { thread_id } => observer.on_turn_started(thread_id),
        AgentEvent::FollowUpStarted { text } => observer.on_follow_up_started(text),
        AgentEvent::SteerStarted { text } => observer.on_steer_started(text),
        AgentEvent::ContextCompacted { omitted_entries } => {
            observer.on_compaction(*omitted_entries)
        }
        AgentEvent::TextDelta { text } => observer.on_text(text),
        AgentEvent::ThinkingDelta { text } => observer.on_thinking(text),
        AgentEvent::ToolCallStarted {
            tool_call_id,
            tool_name,
            args,
        } => observer.on_tool_call(&ToolUse {
            id: tool_call_id.clone(),
            name: tool_name.clone(),
            args: args.clone(),
        }),
        AgentEvent::PermissionRequested {
            tool_call_id,
            tool_name,
            args,
        } => observer.on_permission_request(&ApprovalRequest {
            tool_call_id: tool_call_id.clone(),
            tool_name: tool_name.clone(),
            args: args.clone(),
        }),
        AgentEvent::ToolCallFinished {
            tool_call_id,
            tool_name,
            ok,
            content,
        } => observer.on_tool_result(&ToolResultSummary {
            tool_use_id: tool_call_id.clone(),
            tool_name: tool_name.clone(),
            content: content.clone(),
            is_error: !*ok,
        }),
        AgentEvent::UsageUpdated { usage, total } => observer.on_usage(*usage, *total),
        AgentEvent::TurnFinished { text, stop_reason } => observer.on_finished(&ToolTurnOutcome {
            text: text.clone(),
            usage: TokenUsage::default(),
            stop_reason: stop_reason.clone(),
            tool_calls: Vec::new(),
            tool_results: Vec::new(),
        }),
        AgentEvent::SubagentStarted { .. }
        | AgentEvent::SubagentProgress { .. }
        | AgentEvent::SubagentFinished { .. }
        | AgentEvent::Error { .. } => {}
    }
}

fn start_native(runtime: FakeRuntime) -> AcpHost {
    let cwd = std::env::temp_dir().join(format!(
        "cgc-native-acp-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    std::fs::create_dir_all(&cwd).expect("cwd");
    AcpHost::start_in_process(
        AcpHostConfig::new("", cwd),
        NativeAcpServer::new(Box::new(runtime)),
    )
    .expect("start native in-process host")
}

fn wait_for(
    host: &AcpHost,
    events: &mut Vec<HostEvent>,
    predicate: impl Fn(&HostEvent) -> bool,
    timeout: Duration,
) -> bool {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if let Some(event) = host.recv_timeout(Duration::from_millis(50)) {
            let matched = predicate(&event);
            events.push(event);
            if matched {
                return true;
            }
        }
    }
    false
}

fn turn_outcome(text: &str, stop_reason: StopReason) -> ToolTurnOutcome {
    ToolTurnOutcome {
        text: text.to_string(),
        usage: TokenUsage::default(),
        stop_reason,
        tool_calls: Vec::new(),
        tool_results: Vec::new(),
    }
}

// ---------------------------------------------------------------------------
// golden 事件序列
// ---------------------------------------------------------------------------

#[test]
fn golden_event_sequence_maps_native_events_to_host_events() {
    use cgc_agent_host::AgentEvent;
    let runtime = FakeRuntime::with_script(vec![
        AgentEvent::TurnStarted {
            thread_id: "native-thread".to_string(),
        },
        AgentEvent::TextDelta {
            text: "he".to_string(),
        },
        AgentEvent::TextDelta {
            text: "llo".to_string(),
        },
        AgentEvent::ThinkingDelta {
            text: "think".to_string(),
        },
        AgentEvent::ToolCallStarted {
            tool_call_id: "c1".to_string(),
            tool_name: "read_file".to_string(),
            args: serde_json::json!({"path": "a.txt"}),
        },
        AgentEvent::ToolCallFinished {
            tool_call_id: "c1".to_string(),
            tool_name: "read_file".to_string(),
            ok: true,
            content: "ok".to_string(),
        },
        AgentEvent::UsageUpdated {
            usage: turn_usage(10, 5),
            total: turn_usage(20, 5),
        },
        AgentEvent::ContextCompacted { omitted_entries: 3 },
        AgentEvent::FollowUpStarted {
            text: "after".to_string(),
        },
    ]);
    runtime.state().outcome = Some(turn_outcome("hello", StopReason::EndTurn));
    let host = start_native(runtime);
    let mut events = Vec::new();
    assert!(
        wait_for(
            &host,
            &mut events,
            |event| matches!(event, HostEvent::Ready { .. }),
            Duration::from_secs(10)
        ),
        "ready: {events:?}"
    );
    assert!(host.prompt("hi"));
    assert!(
        wait_for(
            &host,
            &mut events,
            |event| matches!(event, HostEvent::TurnEnd { .. }),
            Duration::from_secs(10)
        ),
        "turn end: {events:?}"
    );
    let expected = vec![
        HostEvent::Ready {
            agent_name: "cgc-native".to_string(),
            version: env!("CARGO_PKG_VERSION").to_string(),
            session_id: "native-session-1".to_string(),
        },
        HostEvent::ConfigOptions { options: vec![] },
        HostEvent::Delta("he".to_string()),
        HostEvent::Delta("llo".to_string()),
        HostEvent::ThoughtDelta("think".to_string()),
        HostEvent::ToolCall {
            call: ToolCallView {
                tool_call_id: "c1".to_string(),
                title: "read_file".to_string(),
                name: Some("read_file".to_string()),
                kind: "Read".to_string(),
                status: "in_progress".to_string(),
                args: Some("{\"path\":\"a.txt\"}".to_string()),
                output: None,
                locations: Vec::new(),
            },
        },
        HostEvent::ToolCallUpdated {
            tool_call_id: "c1".to_string(),
            title: None,
            status: Some("completed".to_string()),
            output: Some("ok".to_string()),
        },
        HostEvent::UsageUpdated {
            used: 15,
            size: 0,
            cost: None,
        },
        HostEvent::CompactionUpdated {
            status: "completed".to_string(),
            summary: Some("省略 3 条更早消息".to_string()),
        },
        HostEvent::UserMessage("after".to_string()),
        HostEvent::TurnEnd {
            cancelled: false,
            stop_reason: "EndTurn".to_string(),
        },
    ];
    assert_eq!(events, expected);
    host.shutdown();
}

fn turn_usage(input: u64, output: u64) -> TokenUsage {
    let _ = (input, output);
    // 与 `turn_usage` 同义；保留独立函数名便于 golden 可读性。
    TokenUsage {
        input,
        output,
        cache_read: 0,
        cache_creation: 0,
    }
}

#[test]
fn turn_finished_falls_back_to_final_text_without_deltas() {
    let runtime = FakeRuntime::new();
    runtime.state().outcome = Some(turn_outcome("final only", StopReason::EndTurn));
    let host = start_native(runtime);
    let mut events = Vec::new();
    assert!(wait_for(
        &host,
        &mut events,
        |event| matches!(event, HostEvent::Ready { .. }),
        Duration::from_secs(10)
    ));
    assert!(host.prompt("hi"));
    assert!(wait_for(
        &host,
        &mut events,
        |event| matches!(event, HostEvent::TurnEnd { .. }),
        Duration::from_secs(10)
    ));
    assert_eq!(
        events
            .iter()
            .filter(|event| matches!(event, HostEvent::Delta(text) if text == "final only"))
            .count(),
        1,
        "final text must be emitted exactly once: {events:?}"
    );
    host.shutdown();
}

// ---------------------------------------------------------------------------
// 权限 4 档往返
// ---------------------------------------------------------------------------

#[test]
fn permission_request_carries_four_options_and_round_trips_decision() {
    use cgc_agent_host::AgentEvent;
    let runtime = FakeRuntime::with_script(vec![
        AgentEvent::ToolCallStarted {
            tool_call_id: "c1".to_string(),
            tool_name: "run_command".to_string(),
            args: serde_json::json!({"command": "ls -la"}),
        },
        AgentEvent::ToolCallFinished {
            tool_call_id: "c1".to_string(),
            tool_name: "run_command".to_string(),
            ok: true,
            content: "done".to_string(),
        },
    ]);
    {
        let mut state = runtime.state();
        state.permission = Some(ApprovalRequest {
            tool_call_id: "c1".to_string(),
            tool_name: "run_command".to_string(),
            args: serde_json::json!({"command": "ls -la"}),
        });
        state.outcome = Some(turn_outcome("done", StopReason::EndTurn));
    }
    let host = start_native(runtime.clone());
    let mut events = Vec::new();
    assert!(wait_for(
        &host,
        &mut events,
        |event| matches!(event, HostEvent::Ready { .. }),
        Duration::from_secs(10)
    ));
    assert!(host.prompt("go"));
    assert!(
        wait_for(
            &host,
            &mut events,
            |event| matches!(event, HostEvent::PermissionRequested { .. }),
            Duration::from_secs(10)
        ),
        "permission: {events:?}"
    );
    let (request_id, option_ids, tool_name, args) = events
        .iter()
        .find_map(|event| match event {
            HostEvent::PermissionRequested {
                request_id,
                options,
                tool_name,
                args,
                tool_call_id,
                ..
            } => {
                assert_eq!(tool_call_id.as_deref(), Some("c1"));
                Some((
                    request_id.clone(),
                    options
                        .iter()
                        .map(|o| o.option_id.clone())
                        .collect::<Vec<_>>(),
                    tool_name.clone(),
                    args.clone(),
                ))
            }
            _ => None,
        })
        .expect("permission event");
    assert_eq!(
        option_ids,
        vec![
            OPTION_ALLOW_ONCE,
            OPTION_ALLOW_SESSION,
            "allow_pattern:ls",
            OPTION_DENY,
        ]
    );
    assert_eq!(tool_name.as_deref(), Some("run_command"));
    assert!(args.unwrap_or_default().contains("ls -la"));
    // 只应有一条审批事件：observer 的 PermissionRequested 不重复映射（去重守卫）。
    assert_eq!(
        events
            .iter()
            .filter(|event| matches!(event, HostEvent::PermissionRequested { .. }))
            .count(),
        1
    );
    assert!(host.respond_permission_option(&request_id, OPTION_ALLOW_SESSION));
    assert!(!host.respond_permission_option(&request_id, OPTION_DENY));
    assert!(wait_for(
        &host,
        &mut events,
        |event| matches!(event, HostEvent::TurnEnd { .. }),
        Duration::from_secs(10)
    ));
    assert_eq!(
        runtime.state().decision,
        Some(cgc_agent_tools::ApprovalDecision::AllowForSession)
    );
    host.shutdown();
}

#[test]
fn permission_pattern_option_round_trips_prefix() {
    let runtime = FakeRuntime::new();
    {
        let mut state = runtime.state();
        state.permission = Some(ApprovalRequest {
            tool_call_id: "c1".to_string(),
            tool_name: "run_command".to_string(),
            args: serde_json::json!({"command": "cargo test -p x"}),
        });
        state.outcome = Some(turn_outcome("", StopReason::EndTurn));
    }
    let host = start_native(runtime.clone());
    let mut events = Vec::new();
    assert!(wait_for(
        &host,
        &mut events,
        |event| matches!(event, HostEvent::Ready { .. }),
        Duration::from_secs(10)
    ));
    assert!(host.prompt("go"));
    assert!(wait_for(
        &host,
        &mut events,
        |event| matches!(event, HostEvent::PermissionRequested { .. }),
        Duration::from_secs(10)
    ));
    let request_id = events
        .iter()
        .find_map(|event| match event {
            HostEvent::PermissionRequested { request_id, .. } => Some(request_id.clone()),
            _ => None,
        })
        .expect("permission event");
    let option_id = cgc_agent_host::allow_pattern_option_id("cargo");
    assert!(host.respond_permission_option(&request_id, option_id));
    assert!(wait_for(
        &host,
        &mut events,
        |event| matches!(event, HostEvent::TurnEnd { .. }),
        Duration::from_secs(10)
    ));
    assert_eq!(
        runtime.state().decision,
        Some(cgc_agent_tools::ApprovalDecision::AllowPattern(
            "cargo".to_string()
        ))
    );
    host.shutdown();
}

// ---------------------------------------------------------------------------
// cancel
// ---------------------------------------------------------------------------

#[test]
fn session_cancel_reaches_runtime_and_ends_turn_cancelled() {
    use cgc_agent_host::AgentEvent;
    let runtime = FakeRuntime::with_script(vec![AgentEvent::TextDelta {
        text: "working".to_string(),
    }]);
    {
        let mut state = runtime.state();
        state.cancel_then_fail = true;
    }
    let host = start_native(runtime.clone());
    let mut events = Vec::new();
    assert!(wait_for(
        &host,
        &mut events,
        |event| matches!(event, HostEvent::Ready { .. }),
        Duration::from_secs(10)
    ));
    assert!(host.prompt("long"));
    assert!(wait_for(
        &host,
        &mut events,
        |event| matches!(event, HostEvent::Delta(_)),
        Duration::from_secs(10)
    ));
    assert!(host.stop());
    assert!(
        wait_for(
            &host,
            &mut events,
            |event| matches!(
                event,
                HostEvent::TurnEnd {
                    cancelled: true,
                    ..
                }
            ),
            Duration::from_secs(10)
        ),
        "cancelled turn end: {events:?}"
    );
    assert!(
        runtime.state().cancel_observed.load(Ordering::SeqCst),
        "runtime must observe cancel"
    );
    // turn 已收尾：再发 prompt 不应被误判为 Busy。
    {
        let mut state = runtime.state();
        state.cancel_then_fail = false;
        state.outcome = Some(turn_outcome("ok", StopReason::EndTurn));
    }
    assert!(host.prompt("again"));
    assert!(wait_for(
        &host,
        &mut events,
        |event| matches!(event, HostEvent::TurnEnd { .. }),
        Duration::from_secs(10)
    ));
    host.shutdown();
}

// ---------------------------------------------------------------------------
// 并发 / 重复请求守卫（raw ACP client）
// ---------------------------------------------------------------------------

#[test]
fn duplicate_prompt_while_busy_is_rejected_and_unknown_session_errors() {
    let runtime = FakeRuntime::new();
    let (started_tx, started_rx) = futures::channel::oneshot::channel();
    let (gate_tx, gate_rx) = futures::channel::oneshot::channel();
    {
        let mut state = runtime.state();
        state.started = Some(started_tx);
        state.gate = Some(gate_rx);
        state.outcome = Some(turn_outcome("ok", StopReason::EndTurn));
    }
    let (client_side, server_side) = Channel::duplex();
    let server = NativeAcpServer::new(Box::new(runtime));
    std::thread::spawn(move || futures::executor::block_on(server.connect_to(server_side)));

    let results: Arc<Mutex<Vec<bool>>> = Arc::new(Mutex::new(Vec::new()));
    let results_for_client = Arc::clone(&results);
    futures::executor::block_on(Client.builder().name("guard-test").connect_with(
        client_side,
        async move |cx| {
            cx.send_request(InitializeRequest::new(ProtocolVersion::V1))
                .block_task()
                .await?;
            let session = cx
                .send_request(NewSessionRequest::new(std::path::PathBuf::from("/tmp")))
                .block_task()
                .await?;
            let session_id = session.session_id.clone();
            let prompt_with = |text: &str, session: SessionId| {
                PromptRequest::new(
                    session,
                    vec![ContentBlock::Text(TextContent::new(text.to_string()))],
                )
            };

            // 第一个 prompt 在后台跑到 gate 放行。
            let first_connection = cx.clone();
            let first_request = prompt_with("first", session_id.clone());
            let (first_done_tx, first_done_rx) = futures::channel::oneshot::channel();
            cx.spawn(async move {
                let result = first_connection
                    .send_request(first_request)
                    .block_task()
                    .await;
                let _ = first_done_tx.send(result.is_ok());
                Ok(())
            })?;
            started_rx.await.expect("runtime started");
            // 同 session 再来一个 prompt：必须是错误（Busy 守卫），不能排队或并发执行。
            let busy = cx
                .send_request(prompt_with("second", session_id.clone()))
                .block_task()
                .await;
            results_for_client.lock().unwrap().push(busy.is_err());
            // 未知 session：错误。
            let unknown = cx
                .send_request(prompt_with("third", SessionId::new("no-such-session")))
                .block_task()
                .await;
            results_for_client.lock().unwrap().push(unknown.is_err());
            // 放行第一个 turn 并等它成功。
            let _ = gate_tx.send(());
            let first_ok = first_done_rx.await.unwrap_or(false);
            results_for_client.lock().unwrap().push(first_ok);
            Ok(())
        },
    ))
    .expect("raw client connection");

    let results = results.lock().unwrap().clone();
    assert_eq!(results, vec![true, true, true]);
}
