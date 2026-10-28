//! 两轨对照测试（Stage 3.1 Phase A 验收项）：同一语义输入下，
//! native 进程内 ACP server 与 external ACP agent 必须产出
//! **同一 HostEvent 序列**，并归约出**同一 ConversationThread**。
//!
//! 两轨都由 `AcpHost::start_in_process` 驱动：客户端 ingestion 是同一份代码，
//! 差异只在上游 agent 实现（native ACP server vs stub ACP agent）。

use std::time::{Duration, Instant};

use agent_client_protocol::schema::v1::{
    AgentCapabilities, ContentBlock, ContentChunk, Implementation, InitializeRequest,
    InitializeResponse, NewSessionRequest, NewSessionResponse, PromptRequest, PromptResponse,
    SessionId, SessionNotification, SessionUpdate, StopReason, TextContent, ToolCall,
    ToolCallStatus, ToolCallUpdate, ToolCallUpdateFields, ToolKind, UsageUpdate,
};
use agent_client_protocol::schema::ProtocolVersion;
use agent_client_protocol::{on_receive_request, Agent, Client, ConnectTo};
use cgc_agent_core::{AgentError, ToolTurnOutcome, TurnObserver};
use cgc_agent_host::{
    AgentEvent, NativeAcpServer, NativeAcpServerConfig, NativeTurn, NativeTurnRuntime,
};
use cgc_agent_provider::{StopReason as NativeStopReason, TokenUsage};
use cgc_desktop_app::agent_ingest::apply_thread_event;
use cgc_platform::acp::connection::{AcpHost, AcpHostConfig, HostEvent};
use futures::future::BoxFuture;

// ---------------------------------------------------------------------------
// 同一段对话的两种上游实现
// ---------------------------------------------------------------------------

fn usage(input: u64, output: u64) -> TokenUsage {
    TokenUsage {
        input,
        output,
        cache_read: 0,
        cache_creation: 0,
    }
}

fn conversation_events() -> Vec<AgentEvent> {
    vec![
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
            usage: usage(10, 5),
            total: usage(20, 5),
        },
        AgentEvent::ContextCompacted { omitted_entries: 3 },
        AgentEvent::FollowUpStarted {
            text: "after".to_string(),
        },
    ]
}

#[derive(Default)]
struct FakeNativeRuntime {
    script: Vec<AgentEvent>,
}

impl NativeTurnRuntime for FakeNativeRuntime {
    fn run_turn(
        &mut self,
        turn: NativeTurn,
    ) -> BoxFuture<'static, Result<ToolTurnOutcome, AgentError>> {
        let script = std::mem::take(&mut self.script);
        Box::pin(async move {
            let mut observer = turn.observer;
            for event in &script {
                emit(&mut *observer, event);
            }
            let outcome = ToolTurnOutcome {
                text: "hello".to_string(),
                usage: usage(20, 5),
                stop_reason: NativeStopReason::EndTurn,
                tool_calls: Vec::new(),
                tool_results: Vec::new(),
            };
            observer.on_finished(&outcome);
            Ok(outcome)
        })
    }
}

fn emit(observer: &mut dyn TurnObserver, event: &AgentEvent) {
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
        } => observer.on_tool_call(&cgc_agent_provider::ToolUse {
            id: tool_call_id.clone(),
            name: tool_name.clone(),
            args: args.clone(),
        }),
        AgentEvent::ToolCallFinished {
            tool_call_id,
            tool_name,
            ok,
            content,
        } => observer.on_tool_result(&cgc_agent_core::ToolResultSummary {
            tool_use_id: tool_call_id.clone(),
            tool_name: tool_name.clone(),
            content: content.clone(),
            is_error: !*ok,
        }),
        AgentEvent::UsageUpdated { usage, total } => observer.on_usage(*usage, *total),
        // 审批不在这段对照脚本里；其余事件不参与本轮。
        _ => {}
    }
}

/// 与 `conversation_events()` 语义等价的 external ACP agent 实现。
fn stub_acp_agent() -> impl ConnectTo<Client> + 'static {
    Agent
        .builder()
        .name("stub-acp")
        .on_receive_request(
            async |_req: InitializeRequest, responder, _cx| {
                responder.respond(
                    InitializeResponse::new(ProtocolVersion::V1)
                        .agent_capabilities(AgentCapabilities::new())
                        .agent_info(Implementation::new("stub-acp", "0.0.1")),
                )
            },
            on_receive_request!(),
        )
        .on_receive_request(
            async |_req: NewSessionRequest, responder, _cx| {
                responder.respond(NewSessionResponse::new("native-session-1"))
            },
            on_receive_request!(),
        )
        .on_receive_request(
            async |_req: PromptRequest, responder, cx| {
                let connection = cx.clone();
                cx.spawn(async move {
                    let session = SessionId::new("native-session-1");
                    let send = |update: SessionUpdate| {
                        let _ = connection
                            .send_notification(SessionNotification::new(session.clone(), update));
                    };
                    send(SessionUpdate::AgentMessageChunk(ContentChunk::new(
                        ContentBlock::Text(TextContent::new("he")),
                    )));
                    send(SessionUpdate::AgentMessageChunk(ContentChunk::new(
                        ContentBlock::Text(TextContent::new("llo")),
                    )));
                    send(SessionUpdate::AgentThoughtChunk(ContentChunk::new(
                        ContentBlock::Text(TextContent::new("think")),
                    )));
                    send(SessionUpdate::ToolCall(
                        ToolCall::new("c1", "read_file")
                            .name("read_file")
                            .kind(ToolKind::Read)
                            .status(ToolCallStatus::InProgress)
                            .raw_input(serde_json::json!({"path": "a.txt"})),
                    ));
                    send(SessionUpdate::ToolCallUpdate(ToolCallUpdate::new(
                        "c1",
                        ToolCallUpdateFields::new()
                            .status(Some(ToolCallStatus::Completed))
                            .raw_output(Some(serde_json::Value::String("ok".to_string()))),
                    )));
                    send(SessionUpdate::UsageUpdate(UsageUpdate::new(15, 0)));
                    send(SessionUpdate::CompactionUpdate(
                        agent_client_protocol::schema::v1::CompactionUpdate::new(
                            "native-compaction-1",
                            agent_client_protocol::schema::v1::CompactionStatus::Completed,
                        )
                        .summary(vec![ContentBlock::Text(
                            TextContent::new("省略 3 条更早消息"),
                        )]),
                    ));
                    send(SessionUpdate::UserMessageChunk(ContentChunk::new(
                        ContentBlock::Text(TextContent::new("after")),
                    )));
                    responder.respond(PromptResponse::new(StopReason::EndTurn))
                })?;
                Ok(())
            },
            on_receive_request!(),
        )
}

// ---------------------------------------------------------------------------
// harness
// ---------------------------------------------------------------------------

fn temp_cwd(tag: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "cgc-native-acp-parity-{}-{tag}",
        std::process::id()
    ));
    let _ = std::fs::create_dir_all(&dir);
    dir
}

fn collect_turn(host: &AcpHost) -> Vec<HostEvent> {
    assert!(host.prompt("hi"));
    let mut events = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(20);
    while Instant::now() < deadline {
        if let Some(event) = host.recv_timeout(Duration::from_millis(50)) {
            let turn_end = matches!(event, HostEvent::TurnEnd { .. });
            events.push(event);
            if turn_end {
                break;
            }
        }
    }
    events
}

fn wait_ready(host: &AcpHost) -> Vec<HostEvent> {
    let mut events = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(20);
    while Instant::now() < deadline {
        if let Some(event) = host.recv_timeout(Duration::from_millis(50)) {
            let ready = matches!(event, HostEvent::Ready { .. });
            events.push(event);
            if ready {
                break;
            }
        }
    }
    assert!(
        matches!(events.last(), Some(HostEvent::Ready { .. })),
        "ready: {events:?}"
    );
    events
}

/// 会话级事件（Ready）也纳入对比：native server 用与 stub 相同的 agent_info
/// 和 session id，保证两轨的 HostEvent 序列逐条相等。
fn native_config() -> NativeAcpServerConfig {
    NativeAcpServerConfig {
        agent_name: "stub-acp".to_string(),
        version: "0.0.1".to_string(),
    }
}

#[test]
fn native_and_acp_tracks_produce_identical_host_events_and_thread() {
    // 第一轨：native 运行时 → 进程内 ACP server → 客户端 HostEvent。
    let runtime = FakeNativeRuntime {
        script: conversation_events(),
    };
    let native_server = NativeAcpServer::new(Box::new(runtime)).with_config(native_config());
    let native_host =
        AcpHost::start_in_process(AcpHostConfig::new("", temp_cwd("native")), native_server)
            .expect("start native in-process host");
    let mut native_events = wait_ready(&native_host);
    native_events.extend(collect_turn(&native_host));

    // 第二轨：external ACP agent（stub）→ 客户端 HostEvent。
    let acp_host =
        AcpHost::start_in_process(AcpHostConfig::new("", temp_cwd("stub")), stub_acp_agent())
            .expect("start stub in-process host");
    let mut acp_events = wait_ready(&acp_host);
    acp_events.extend(collect_turn(&acp_host));

    // 1) 两轨客户端事件逐条一致。
    assert_eq!(native_events, acp_events);

    // 2) 同一 ingestion 归约出同一 ConversationThread。
    let mut native_thread = cgc_agent_ui::conversation::ConversationThread::new("native");
    let mut acp_thread = cgc_agent_ui::conversation::ConversationThread::new("acp");
    for event in &native_events {
        assert!(apply_thread_event(&mut native_thread, event) || !is_thread_event(event));
    }
    for event in &acp_events {
        assert!(apply_thread_event(&mut acp_thread, event) || !is_thread_event(event));
    }
    assert_eq!(native_thread.entries, acp_thread.entries);
    assert_eq!(native_thread.usage, acp_thread.usage);
    assert_eq!(
        native_thread.status,
        cgc_agent_ui::conversation::ThreadStatus::Idle
    );
    assert!(!native_thread.entries.is_empty());
}

fn is_thread_event(event: &HostEvent) -> bool {
    !matches!(
        event,
        HostEvent::Ready { .. }
            | HostEvent::ConfigOptions { .. }
            | HostEvent::AvailableCommands { .. }
            | HostEvent::Sessions { .. }
            | HostEvent::ModeUpdated { .. }
            | HostEvent::Exited
    )
}
