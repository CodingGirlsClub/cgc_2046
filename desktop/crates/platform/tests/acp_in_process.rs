//! 进程内 ACP transport（Stage 3.1 Phase A）：`AcpHost::start_in_process` 用与子进程
//! 完全相同的客户端路径驱动一个 in-process agent 组件。
//!
//! 这些测试不依赖 native runtime（cgc-platform 不能反向依赖 agent_host），用一个
//! 按 ACP schema 手写的 stub agent 覆盖：initialize / session/new / session/prompt /
//! session/update 映射 / request_permission 往返 / session/cancel。

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use agent_client_protocol::schema::v1::{
    AgentCapabilities, CancelNotification, ContentBlock, ContentChunk, CurrentModeUpdate,
    InitializeRequest, InitializeResponse, NewSessionRequest, NewSessionResponse, PermissionOption,
    PermissionOptionKind, Plan, PlanEntry, PlanEntryPriority, PlanEntryStatus, PromptRequest,
    PromptResponse, RequestPermissionOutcome, RequestPermissionRequest, SessionId,
    SessionNotification, SessionUpdate, StopReason, TextContent, ToolCall, ToolCallStatus,
    ToolCallUpdate, ToolCallUpdateFields, UsageUpdate,
};
use agent_client_protocol::schema::ProtocolVersion;
use agent_client_protocol::{on_receive_notification, on_receive_request, Agent, Client};
use cgc_platform::acp::connection::{AcpHost, AcpHostConfig};

fn config(tag: &str) -> AcpHostConfig {
    let cwd = std::env::temp_dir().join(format!("cgc-acp-in-process-{}-{tag}", std::process::id()));
    std::fs::create_dir_all(&cwd).expect("cwd");
    AcpHostConfig::new("", cwd).with_name("stub")
}

fn wait_for(
    host: &AcpHost,
    events: &mut Vec<cgc_platform::acp::connection::HostEvent>,
    predicate: impl Fn(&cgc_platform::acp::connection::HostEvent) -> bool,
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

/// 标准初始化/建档 handler，所有 stub agent 共用。
fn base_agent(
) -> agent_client_protocol::Builder<Agent, impl agent_client_protocol::HandleDispatchFrom<Client>> {
    Agent
        .builder()
        .name("stub-agent")
        .on_receive_request(
            async |_req: InitializeRequest, responder, _cx| {
                responder.respond(
                    InitializeResponse::new(ProtocolVersion::V1)
                        .agent_capabilities(AgentCapabilities::new())
                        .agent_info(agent_client_protocol::schema::v1::Implementation::new(
                            "stub", "0.0.1",
                        )),
                )
            },
            on_receive_request!(),
        )
        .on_receive_request(
            async |_req: NewSessionRequest, responder, _cx| {
                responder.respond(NewSessionResponse::new("stub-session"))
            },
            on_receive_request!(),
        )
}

#[test]
fn in_process_session_updates_map_to_host_events() {
    let agent = base_agent().on_receive_request(
        async |_req: PromptRequest, responder, cx| {
            let connection = cx.clone();
            cx.spawn(async move {
                let session_id = SessionId::new("stub-session");
                let notify = |update: SessionUpdate| {
                    let _ = connection
                        .send_notification(SessionNotification::new(session_id.clone(), update));
                };
                notify(SessionUpdate::AgentThoughtChunk(ContentChunk::new(
                    ContentBlock::Text(TextContent::new("think")),
                )));
                notify(SessionUpdate::AgentMessageChunk(ContentChunk::new(
                    ContentBlock::Text(TextContent::new("hel")),
                )));
                notify(SessionUpdate::AgentMessageChunk(ContentChunk::new(
                    ContentBlock::Text(TextContent::new("lo")),
                )));
                notify(SessionUpdate::ToolCall(
                    ToolCall::new("call-1", "Read file")
                        .name("read_file")
                        .status(ToolCallStatus::InProgress)
                        .raw_input(serde_json::json!({"path": "a.rs"})),
                ));
                notify(SessionUpdate::ToolCallUpdate(ToolCallUpdate::new(
                    "call-1",
                    ToolCallUpdateFields::new()
                        .status(Some(ToolCallStatus::Completed))
                        .raw_output(Some(serde_json::json!("ok"))),
                )));
                notify(SessionUpdate::Plan(Plan::new(vec![PlanEntry::new(
                    "step",
                    PlanEntryPriority::High,
                    PlanEntryStatus::Completed,
                )])));
                notify(SessionUpdate::UsageUpdate(UsageUpdate::new(120, 4_000)));
                notify(SessionUpdate::UserMessageChunk(ContentChunk::new(
                    ContentBlock::Text(TextContent::new("interject")),
                )));
                notify(SessionUpdate::CurrentModeUpdate(CurrentModeUpdate::new(
                    agent_client_protocol::schema::v1::SessionModeId::new("plan"),
                )));
                responder.respond(PromptResponse::new(StopReason::EndTurn))
            })?;
            Ok(())
        },
        on_receive_request!(),
    );
    let host = AcpHost::start_in_process(config("updates"), agent).expect("start host");
    let mut events = Vec::new();
    assert!(
        wait_for(
            &host,
            &mut events,
            |event| matches!(
                event,
                cgc_platform::acp::connection::HostEvent::Ready { .. }
            ),
            Duration::from_secs(10),
        ),
        "ready: {events:?}"
    );
    assert!(host.prompt("hi"));
    assert!(
        wait_for(
            &host,
            &mut events,
            |event| matches!(
                event,
                cgc_platform::acp::connection::HostEvent::TurnEnd { .. }
            ),
            Duration::from_secs(10),
        ),
        "turn end: {events:?}"
    );

    use cgc_platform::acp::connection::HostEvent;
    let delta: String = events
        .iter()
        .filter_map(|event| match event {
            HostEvent::Delta(text) => Some(text.as_str()),
            _ => None,
        })
        .collect();
    assert_eq!(delta, "hello");
    assert!(events
        .iter()
        .any(|event| matches!(event, HostEvent::ThoughtDelta(text) if text == "think")));
    assert!(events.iter().any(|event| matches!(
        event,
        HostEvent::ToolCall { call } if call.tool_call_id == "call-1"
            && call.name.as_deref() == Some("read_file")
            && call.status == "in_progress"
    )));
    assert!(events.iter().any(|event| matches!(
        event,
        HostEvent::ToolCallUpdated { tool_call_id, status, output, .. }
            if tool_call_id == "call-1" && status.as_deref() == Some("completed")
                && output.as_deref() == Some("ok")
    )));
    assert!(events.iter().any(|event| matches!(
        event,
        HostEvent::PlanUpdated { steps } if steps.len() == 1 && steps[0].content == "step"
    )));
    assert!(events.iter().any(|event| matches!(
        event,
        HostEvent::UsageUpdated {
            used: 120,
            size: 4_000,
            ..
        }
    )));
    assert!(events
        .iter()
        .any(|event| matches!(event, HostEvent::UserMessage(text) if text == "interject")));
    assert!(events
        .iter()
        .any(|event| matches!(event, HostEvent::ModeUpdated { mode_id } if mode_id == "plan")));
    assert!(events.iter().any(|event| matches!(
        event,
        HostEvent::TurnEnd { cancelled: false, stop_reason } if stop_reason == "EndTurn"
    )));
    host.shutdown();
}

#[test]
fn in_process_permission_round_trip_selects_option_id() {
    let selected: Arc<Mutex<Option<RequestPermissionOutcome>>> = Arc::new(Mutex::new(None));
    let selected_for_agent = selected.clone();
    let agent = base_agent().on_receive_request(
        async move |_req: PromptRequest, responder, cx| {
            let selected = selected_for_agent.clone();
            let connection = cx.clone();
            cx.spawn(async move {
                let request = RequestPermissionRequest::new(
                    SessionId::new("stub-session"),
                    ToolCallUpdate::new(
                        "call-1",
                        ToolCallUpdateFields::new()
                            .title(Some("Allow run_command?".to_string()))
                            .name(Some("run_command".to_string()))
                            .raw_input(Some(serde_json::json!({"command": "ls"}))),
                    ),
                    vec![
                        PermissionOption::new(
                            "allow_once",
                            "Allow once",
                            PermissionOptionKind::AllowOnce,
                        ),
                        PermissionOption::new(
                            "reject_once",
                            "Reject",
                            PermissionOptionKind::RejectOnce,
                        ),
                    ],
                );
                let response = connection
                    .send_request(request)
                    .block_task()
                    .await
                    .expect("permission");
                *selected.lock().expect("selected") = Some(response.outcome);
                responder.respond(PromptResponse::new(StopReason::EndTurn))
            })?;
            Ok(())
        },
        on_receive_request!(),
    );
    let host = AcpHost::start_in_process(config("permission"), agent).expect("start host");
    let mut events = Vec::new();
    assert!(wait_for(
        &host,
        &mut events,
        |event| matches!(
            event,
            cgc_platform::acp::connection::HostEvent::Ready { .. }
        ),
        Duration::from_secs(10),
    ));
    assert!(host.prompt("go"));
    assert!(
        wait_for(
            &host,
            &mut events,
            |event| matches!(
                event,
                cgc_platform::acp::connection::HostEvent::PermissionRequested { .. }
            ),
            Duration::from_secs(10),
        ),
        "permission: {events:?}"
    );

    use cgc_platform::acp::connection::HostEvent;
    let (request_id, option_ids, tool_name) = events
        .iter()
        .find_map(|event| match event {
            HostEvent::PermissionRequested {
                request_id,
                options,
                tool_name,
                ..
            } => Some((
                request_id.clone(),
                options
                    .iter()
                    .map(|o| o.option_id.clone())
                    .collect::<Vec<_>>(),
                tool_name.clone(),
            )),
            _ => None,
        })
        .expect("permission event");
    assert_eq!(option_ids, vec!["allow_once", "reject_once"]);
    assert_eq!(tool_name.as_deref(), Some("run_command"));
    assert!(host.respond_permission_option(&request_id, "allow_once"));
    // 同一 request 重复回传必须是 no-op：审批去重不能回退。
    assert!(!host.respond_permission_option(&request_id, "reject_once"));
    assert!(!host.respond_permission_option("perm-unknown", "allow_once"));

    assert!(wait_for(
        &host,
        &mut events,
        |event| matches!(
            event,
            cgc_platform::acp::connection::HostEvent::TurnEnd { .. }
        ),
        Duration::from_secs(10),
    ));
    let outcome = selected.lock().expect("selected").take().expect("outcome");
    match outcome {
        RequestPermissionOutcome::Selected(choice) => {
            assert_eq!(choice.option_id.0.to_string(), "allow_once")
        }
        other => panic!("expected selected outcome, got {other:?}"),
    }
    host.shutdown();
}

#[test]
fn legacy_allow_flag_folds_to_first_allow_option() {
    let selected: Arc<Mutex<Option<RequestPermissionOutcome>>> = Arc::new(Mutex::new(None));
    let selected_for_agent = selected.clone();
    let agent = base_agent().on_receive_request(
        async move |_req: PromptRequest, responder, cx| {
            let selected = selected_for_agent.clone();
            let connection = cx.clone();
            cx.spawn(async move {
                let request = RequestPermissionRequest::new(
                    SessionId::new("stub-session"),
                    ToolCallUpdate::new("call-1", ToolCallUpdateFields::new()),
                    vec![
                        PermissionOption::new(
                            "reject_once",
                            "Reject",
                            PermissionOptionKind::RejectOnce,
                        ),
                        PermissionOption::new(
                            "allow_session",
                            "Allow session",
                            PermissionOptionKind::AllowAlways,
                        ),
                    ],
                );
                let response = connection
                    .send_request(request)
                    .block_task()
                    .await
                    .expect("permission");
                *selected.lock().expect("selected") = Some(response.outcome);
                responder.respond(PromptResponse::new(StopReason::EndTurn))
            })?;
            Ok(())
        },
        on_receive_request!(),
    );
    let host = AcpHost::start_in_process(config("legacy-allow"), agent).expect("start host");
    let mut events = Vec::new();
    assert!(wait_for(
        &host,
        &mut events,
        |event| matches!(
            event,
            cgc_platform::acp::connection::HostEvent::Ready { .. }
        ),
        Duration::from_secs(10),
    ));
    assert!(host.prompt("go"));
    assert!(wait_for(
        &host,
        &mut events,
        |event| matches!(
            event,
            cgc_platform::acp::connection::HostEvent::PermissionRequested { .. }
        ),
        Duration::from_secs(10),
    ));
    let request_id = events
        .iter()
        .find_map(|event| match event {
            cgc_platform::acp::connection::HostEvent::PermissionRequested {
                request_id, ..
            } => Some(request_id.clone()),
            _ => None,
        })
        .expect("permission event");
    assert!(host.respond_permission(&request_id, true));
    assert!(wait_for(
        &host,
        &mut events,
        |event| matches!(
            event,
            cgc_platform::acp::connection::HostEvent::TurnEnd { .. }
        ),
        Duration::from_secs(10),
    ));
    match selected.lock().expect("selected").take().expect("outcome") {
        RequestPermissionOutcome::Selected(choice) => {
            assert_eq!(choice.option_id.0.to_string(), "allow_session")
        }
        other => panic!("expected selected outcome, got {other:?}"),
    }
    host.shutdown();
}

#[test]
fn in_process_stop_cancels_turn() {
    let cancelled = Arc::new(AtomicBool::new(false));
    let cancelled_for_handler = cancelled.clone();
    let cancel_sender: Arc<Mutex<Option<futures::channel::oneshot::Sender<()>>>> =
        Arc::new(Mutex::new(None));
    let cancel_sender_for_handler = cancel_sender.clone();
    let agent = base_agent()
        .on_receive_notification(
            async move |_notif: CancelNotification, _cx| {
                cancelled_for_handler.store(true, Ordering::SeqCst);
                if let Some(sender) = cancel_sender_for_handler
                    .lock()
                    .expect("cancel sender")
                    .take()
                {
                    let _ = sender.send(());
                }
                Ok(())
            },
            on_receive_notification!(),
        )
        .on_receive_request(
            async move |_req: PromptRequest, responder, cx| {
                let (cancel_tx, cancel_rx) = futures::channel::oneshot::channel();
                *cancel_sender.lock().expect("cancel sender") = Some(cancel_tx);
                let connection = cx.clone();
                cx.spawn(async move {
                    connection.send_notification(SessionNotification::new(
                        SessionId::new("stub-session"),
                        SessionUpdate::AgentMessageChunk(ContentChunk::new(ContentBlock::Text(
                            TextContent::new("working"),
                        ))),
                    ))?;
                    let timeout = futures::channel::oneshot::channel::<()>();
                    let (sleep_tx, sleep_rx) = timeout;
                    // 2s 兜底：cancel 没来则自己收尾。
                    std::thread::spawn(move || {
                        std::thread::sleep(Duration::from_secs(2));
                        let _ = sleep_tx.send(());
                    });
                    futures::pin_mut!(cancel_rx, sleep_rx);
                    match futures::future::select(cancel_rx, sleep_rx).await {
                        futures::future::Either::Left(_) | futures::future::Either::Right(_) => {}
                    }
                    responder.respond(PromptResponse::new(StopReason::Cancelled))
                })?;
                Ok(())
            },
            on_receive_request!(),
        );
    let host = AcpHost::start_in_process(config("cancel"), agent).expect("start host");
    let mut events = Vec::new();
    assert!(wait_for(
        &host,
        &mut events,
        |event| matches!(
            event,
            cgc_platform::acp::connection::HostEvent::Ready { .. }
        ),
        Duration::from_secs(10),
    ));
    assert!(host.prompt("long"));
    assert!(wait_for(
        &host,
        &mut events,
        |event| matches!(event, cgc_platform::acp::connection::HostEvent::Delta(_)),
        Duration::from_secs(10),
    ));
    assert!(host.stop());
    assert!(
        wait_for(
            &host,
            &mut events,
            |event| matches!(
                event,
                cgc_platform::acp::connection::HostEvent::TurnEnd {
                    cancelled: true,
                    ..
                }
            ),
            Duration::from_secs(10),
        ),
        "cancelled turn end: {events:?}"
    );
    let mut agent_cancelled = false;
    for _ in 0..100 {
        if cancelled.load(Ordering::SeqCst) {
            agent_cancelled = true;
            break;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    assert!(agent_cancelled, "agent must receive session/cancel");
    host.shutdown();
}
