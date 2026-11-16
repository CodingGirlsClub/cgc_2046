//! P2 stub ACP e2e：默认 CI 执行，覆盖 session/new、流式、工具 diff/location、审批、
//! 计划、用量、mode/config/commands/title 映射与 CGC MCP 注入（真实 openma 见
//! `dsh_acp_real_e2e.rs`，需设置 `CGC_DSH_ACP_BIN`）。

use std::sync::Arc;
use std::time::{Duration, Instant};

use cgc_agent_ui::conversation::{ConversationThread, ThreadCapabilities};
use cgc_desktop_app::agent_ingest::apply_thread_event;
use cgc_platform::acp::connection::{AcpHost, AcpHostConfig, HostEvent};

fn temp_dir(tag: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "cgc-dsh-stub-{}-{tag}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("temp dir");
    dir
}

// ---------------------------------------------------------------------------
// stub ACP e2e：不依赖真实 adapter，默认 CI 也执行；覆盖全部 update 映射与 MCP 注入
// ---------------------------------------------------------------------------

fn stub_agent(
    mcp_seen: Arc<std::sync::Mutex<Vec<agent_client_protocol::schema::v1::McpServer>>>,
) -> impl agent_client_protocol::ConnectTo<agent_client_protocol::Client> + 'static {
    use agent_client_protocol::schema::v1::{
        AgentCapabilities, AvailableCommand, AvailableCommandsUpdate, ConfigOptionUpdate,
        ContentBlock, ContentChunk, CurrentModeUpdate, Diff, InitializeRequest, InitializeResponse,
        NewSessionRequest, NewSessionResponse, PermissionOption, PermissionOptionKind, Plan,
        PlanEntry, PlanEntryPriority, PlanEntryStatus, PromptRequest, PromptResponse,
        RequestPermissionRequest, SessionConfigOption, SessionConfigSelectOption, SessionId,
        SessionInfoUpdate, SessionModeId, SessionNotification, SessionUpdate,
        StopReason as StubStopReason, TextContent, ToolCall, ToolCallContent, ToolCallLocation,
        ToolCallStatus, ToolCallUpdate, ToolCallUpdateFields, ToolKind, UsageUpdate,
    };
    use agent_client_protocol::schema::ProtocolVersion;
    use agent_client_protocol::{on_receive_request, Agent};

    Agent
        .builder()
        .name("stub-openma")
        .on_receive_request(
            async |_request: InitializeRequest, responder, _cx| {
                responder.respond(
                    InitializeResponse::new(ProtocolVersion::V1)
                        .agent_capabilities(AgentCapabilities::new()),
                )
            },
            on_receive_request!(),
        )
        .on_receive_request(
            async move |request: NewSessionRequest, responder, _cx| {
                *mcp_seen.lock().expect("mcp seen") = request.mcp_servers.clone();
                responder.respond(NewSessionResponse::new(SessionId::new("stub-session")))
            },
            on_receive_request!(),
        )
        .on_receive_request(
            async |_request: PromptRequest, responder, cx| {
                let connection = cx.clone();
                cx.spawn(async move {
                    let session = SessionId::new("stub-session");
                    let send = |update: SessionUpdate| {
                        connection
                            .send_notification(SessionNotification::new(session.clone(), update))
                    };
                    send(SessionUpdate::AgentThoughtChunk(ContentChunk::new(
                        ContentBlock::Text(TextContent::new("thinking")),
                    )))?;
                    send(SessionUpdate::AgentMessageChunk(ContentChunk::new(
                        ContentBlock::Text(TextContent::new("working")),
                    )))?;
                    send(SessionUpdate::ToolCall(
                        ToolCall::new("call-1", "Edit file")
                            .name("write")
                            .kind(ToolKind::Edit)
                            .status(ToolCallStatus::InProgress)
                            .raw_input(serde_json::json!({"file_path": "a.rs"}))
                            .content(vec![ToolCallContent::Diff(
                                Diff::new("a.rs", "new line").old_text("old line"),
                            )])
                            .locations(vec![ToolCallLocation::new("a.rs").line(Some(2))]),
                    ))?;
                    send(SessionUpdate::ToolCallUpdate(ToolCallUpdate::new(
                        "call-1",
                        ToolCallUpdateFields::new()
                            .status(Some(ToolCallStatus::Completed))
                            .content(vec![ToolCallContent::Diff(
                                Diff::new("a.rs", "new line").old_text("old line"),
                            )])
                            .locations(vec![ToolCallLocation::new("a.rs").line(Some(3))])
                            .raw_input(Some(serde_json::json!({"file_path": "a.rs"})))
                            .raw_output(Some(serde_json::json!("ok"))),
                    )))?;
                    send(SessionUpdate::Plan(Plan::new(vec![PlanEntry::new(
                        "inspect",
                        PlanEntryPriority::High,
                        PlanEntryStatus::Completed,
                    )])))?;
                    send(SessionUpdate::UsageUpdate(UsageUpdate::new(10, 100).cost(
                        agent_client_protocol::schema::v1::Cost::new(0.001, "USD"),
                    )))?;
                    send(SessionUpdate::CurrentModeUpdate(CurrentModeUpdate::new(
                        SessionModeId::new("plan"),
                    )))?;
                    send(SessionUpdate::ConfigOptionUpdate(ConfigOptionUpdate::new(
                        vec![SessionConfigOption::select(
                            "mode",
                            "Permissions",
                            "workspace-write",
                            vec![SessionConfigSelectOption::new("read-only", "Read-only")],
                        )],
                    )))?;
                    send(SessionUpdate::AvailableCommandsUpdate(
                        AvailableCommandsUpdate::new(vec![AvailableCommand::new(
                            "compact",
                            "Compact history",
                        )]),
                    ))?;
                    send(SessionUpdate::SessionInfoUpdate(
                        SessionInfoUpdate::new().title("Stub title"),
                    ))?;
                    let permission = RequestPermissionRequest::new(
                        session.clone(),
                        ToolCallUpdate::new(
                            "call-1",
                            ToolCallUpdateFields::new().title(Some("Approve write".to_string())),
                        ),
                        vec![
                            PermissionOption::new(
                                "allow-once",
                                "Allow once",
                                PermissionOptionKind::AllowOnce,
                            ),
                            PermissionOption::new(
                                "reject-once",
                                "Reject",
                                PermissionOptionKind::RejectOnce,
                            ),
                        ],
                    );
                    let _ = connection.send_request(permission).block_task().await;
                    send(SessionUpdate::AgentMessageChunk(ContentChunk::new(
                        ContentBlock::Text(TextContent::new("done")),
                    )))?;
                    responder.respond(PromptResponse::new(StubStopReason::EndTurn))
                })?;
                Ok(())
            },
            on_receive_request!(),
        )
}

#[test]
fn stub_full_conversation_maps_all_updates_and_injects_mcp() {
    use agent_client_protocol::schema::v1::{HttpHeader, McpServer, McpServerHttp};

    let mcp = McpServer::Http(
        McpServerHttp::new("cgc-2046-learning", "http://127.0.0.1:9/mcp")
            .headers(vec![HttpHeader::new("Authorization", "Bearer test-token")]),
    );
    let mcp_seen = Arc::new(std::sync::Mutex::new(Vec::new()));
    let host = AcpHost::start_in_process(
        AcpHostConfig::new("", temp_dir("stub")).with_mcp_servers(vec![mcp.clone()]),
        stub_agent(Arc::clone(&mcp_seen)),
    )
    .expect("start stub host");

    let mut saw_ready = false;
    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline && !saw_ready {
        if let Some(event) = host.recv_timeout(Duration::from_millis(100)) {
            saw_ready = matches!(event, HostEvent::Ready { .. });
        }
    }
    assert!(saw_ready, "stub agent did not become ready");
    assert_eq!(*mcp_seen.lock().expect("mcp seen"), vec![mcp.clone()]);

    assert!(host.prompt("hello stub"));
    let mut thread = ConversationThread::new("acp").with_capabilities(ThreadCapabilities::acp());
    let mut saw_thought = false;
    let mut saw_delta = false;
    let mut saw_plan = false;
    let mut saw_permission = false;
    let mut saw_usage = false;
    let mut saw_title = false;
    let mut saw_mode = false;
    let mut saw_config = false;
    let mut saw_commands = false;
    let mut saw_diff = false;
    let mut saw_location = false;
    let mut saw_args = false;
    let mut turn_end = false;
    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline {
        let Some(event) = host.recv_timeout(Duration::from_millis(100)) else {
            continue;
        };
        if let HostEvent::PermissionRequested {
            request_id,
            options,
            ..
        } = &event
        {
            saw_permission = true;
            assert!(host.respond_permission_option(
                request_id,
                options.first().expect("option").option_id.clone()
            ));
        }
        match &event {
            HostEvent::ThoughtDelta(text) => saw_thought |= text == "thinking",
            HostEvent::Delta(text) => saw_delta |= text == "done",
            HostEvent::PlanUpdated { steps } => saw_plan |= steps.len() == 1,
            HostEvent::UsageUpdated { used, cost, .. } => {
                saw_usage |= *used == 10 && cost.as_deref() == Some("0.0010 USD")
            }
            HostEvent::TitleUpdated { title } => {
                saw_title |= title.as_deref() == Some("Stub title")
            }
            HostEvent::ModeUpdated { mode_id } => saw_mode |= mode_id == "plan",
            HostEvent::ConfigOptions { options } => {
                saw_config |= options.iter().any(|option| option.id == "mode")
            }
            HostEvent::AvailableCommands { commands } => {
                saw_commands |= commands.iter().any(|command| command.name == "compact")
            }
            HostEvent::ToolCallUpdated {
                output,
                locations,
                args,
                ..
            } => {
                saw_diff |= output.as_deref().is_some_and(|output| {
                    output.contains("--- old\nold line") && output.contains("+++ new\nnew line")
                });
                saw_location |= locations
                    .as_deref()
                    .is_some_and(|locations| locations == ["a.rs:3"]);
                saw_args |= args.as_deref().is_some_and(|args| args.contains("a.rs"));
            }
            HostEvent::TurnEnd { .. } => turn_end = true,
            HostEvent::Error { message } => panic!("stub turn failed: {message}"),
            _ => {}
        }
        apply_thread_event(&mut thread, &event);
        if turn_end {
            break;
        }
    }
    host.shutdown();
    assert!(turn_end, "stub turn did not finish");
    assert!(saw_thought && saw_delta, "streaming mapping missing");
    assert!(saw_plan && saw_usage, "plan/usage mapping missing");
    assert!(saw_permission, "permission mapping missing");
    assert!(
        saw_title && saw_mode && saw_config && saw_commands,
        "metadata events missing"
    );
    assert!(
        saw_diff && saw_location && saw_args,
        "tool diff/location/args mapping missing"
    );
    assert!(
        thread.entries.iter().any(|entry| matches!(
            entry,
            cgc_agent_ui::conversation::Entry::ToolCall { output, locations, args, .. }
                if output.as_deref().is_some_and(|output| output.contains("+++ new\nnew line"))
                    && locations == &vec!["a.rs:3".to_string()]
                    && args.as_deref().is_some_and(|args| args.contains("a.rs"))
        )),
        "thread lost tool diff/location: {thread:?}"
    );
}
