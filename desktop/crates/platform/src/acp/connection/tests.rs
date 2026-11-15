use super::auth::RequestFailure;
use super::events::*;
use super::runner::idle_expired;
use super::*;
use agent_client_protocol::schema::v1::SessionUpdate;

#[test]
fn turn_timeout_only_counts_silence_not_user_or_tool_waiting() {
    // 期间没有新事件：空闲预算确实耗尽，应判超时。
    assert!(idle_expired(7, 7, false));
    // 期间有进度（审批回传、工具更新、增量）：重新计时，不判超时。
    assert!(!idle_expired(7, 8, false));
    assert!(!idle_expired(0, 1, false));
    // 等待用户审批：即使没有 session/update，也不能判超时。
    assert!(!idle_expired(7, 7, true));
}

#[test]
fn config_debug_does_not_leak_mcp_credentials() {
    use agent_client_protocol::schema::v1::{HttpHeader, McpServerHttp};
    let server = McpServer::Http(
        McpServerHttp::new("cgc-2046", "http://127.0.0.1:4000/mcp").headers(vec![HttpHeader::new(
            "Authorization",
            "Bearer super-secret-token",
        )]),
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
    use agent_client_protocol::schema::v1::{ToolCall, ToolCallLocation, ToolCallStatus, ToolKind};
    let call = ToolCall::new("call-1", "Edit file")
        .name("edit_file")
        .kind(ToolKind::Edit)
        .status(ToolCallStatus::InProgress)
        .raw_input(serde_json::json!({"path": "src/main.rs"}))
        .raw_output(serde_json::json!({"ok": true}))
        .locations(vec![ToolCallLocation::new("/tmp/a.rs").line(Some(3))]);
    let event = host_event_from_update(SessionUpdate::ToolCall(call)).expect("event");
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
    use agent_client_protocol::schema::v1::{ToolCallStatus, ToolCallUpdate, ToolCallUpdateFields};
    let update = ToolCallUpdate::new(
        "call-1",
        ToolCallUpdateFields::new()
            .title(Some("Edited".to_string()))
            .status(Some(ToolCallStatus::Completed))
            .raw_output(Some(serde_json::json!("done"))),
    );
    let event = host_event_from_update(SessionUpdate::ToolCallUpdate(update)).expect("event");
    let HostEvent::ToolCallUpdated {
        tool_call_id,
        title,
        status,
        output,
        locations,
        args,
    } = event
    else {
        panic!("expected ToolCallUpdated");
    };
    assert_eq!(tool_call_id, "call-1");
    assert_eq!(title.as_deref(), Some("Edited"));
    assert_eq!(status.as_deref(), Some("completed"));
    assert_eq!(output.as_deref(), Some("done"));
    assert_eq!(locations, None);
    assert_eq!(args, None);
}

#[test]
fn tool_call_update_forwards_locations_and_diff_content() {
    use agent_client_protocol::schema::v1::{
        Diff, ToolCallContent, ToolCallLocation, ToolCallStatus, ToolCallUpdate,
        ToolCallUpdateFields,
    };
    let update = ToolCallUpdate::new(
        "call-1",
        ToolCallUpdateFields::new()
            .status(Some(ToolCallStatus::Completed))
            .content(vec![ToolCallContent::Diff(
                Diff::new("/tmp/a.rs", "new line").old_text("old line"),
            )])
            .locations(vec![ToolCallLocation::new("/tmp/a.rs").line(Some(2))]),
    );
    let event = host_event_from_update(SessionUpdate::ToolCallUpdate(update)).expect("event");
    let HostEvent::ToolCallUpdated {
        output, locations, ..
    } = event
    else {
        panic!("expected ToolCallUpdated");
    };
    assert_eq!(locations, Some(vec!["/tmp/a.rs:2".to_string()]));
    let output = output.expect("diff output");
    assert!(output.contains("diff: /tmp/a.rs"), "{output}");
    assert!(output.contains("--- old\nold line"), "{output}");
    assert!(output.contains("+++ new\nnew line"), "{output}");
}

#[test]
fn tool_call_content_is_flattened_when_raw_output_missing() {
    use agent_client_protocol::schema::v1::{TextContent, ToolCall, ToolCallContent};
    let call = ToolCall::new("call-2", "Read file")
        .kind(agent_client_protocol::schema::v1::ToolKind::Read)
        .content(vec![ToolCallContent::Content(
            agent_client_protocol::schema::v1::Content::new(
                agent_client_protocol::schema::v1::ContentBlock::Text(TextContent::new("line 1")),
            ),
        )]);
    let event = host_event_from_update(SessionUpdate::ToolCall(call)).expect("event");
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
    let event = host_event_from_update(SessionUpdate::Plan(plan)).expect("event");
    let HostEvent::PlanUpdated { steps } = event else {
        panic!("expected PlanUpdated");
    };
    assert_eq!(steps.len(), 2);
    assert_eq!(steps[0].content, "inspect");
    assert_eq!(steps[0].priority, "high");
    assert_eq!(steps[0].status, "completed");
    assert_eq!(steps[1].status, "inprogress");

    let usage = UsageUpdate::new(1200, 64_000);
    let event = host_event_from_update(SessionUpdate::UsageUpdate(usage)).expect("event");
    let HostEvent::UsageUpdated { used, size, cost } = event else {
        panic!("expected UsageUpdated");
    };
    assert_eq!((used, size, cost), (1200, 64_000, None));
}

#[test]
fn usage_cost_preserves_subcent_precision_and_currency() {
    use agent_client_protocol::schema::v1::{Cost, UsageUpdate};

    for (amount, currency, expected) in [
        (0.0001, "USD", "0.0001 USD"),
        (0.004, "USD", "0.0040 USD"),
        (0.0083, "USD", "0.0083 USD"),
        (0.0, "USD", "0.00 USD"),
        (0.01, "USD", "0.01 USD"),
        (1.23, "EUR", "1.23 EUR"),
    ] {
        let update = UsageUpdate::new(26_000, 1_000_000).cost(Cost::new(amount, currency));
        let event =
            host_event_from_update(SessionUpdate::UsageUpdate(update)).expect("usage event");
        let HostEvent::UsageUpdated { cost, .. } = event else {
            panic!("expected UsageUpdated");
        };
        assert_eq!(cost.as_deref(), Some(expected), "amount={amount}");
    }
}

#[test]
fn user_message_chunks_map_to_user_messages() {
    use agent_client_protocol::schema::v1::{ContentBlock, ContentChunk, TextContent};
    let event = host_event_from_update(SessionUpdate::UserMessageChunk(ContentChunk::new(
        ContentBlock::Text(TextContent::new("after")),
    )))
    .expect("user message event");
    assert_eq!(event, HostEvent::UserMessage("after".to_string()));
}

#[test]
fn compaction_update_prefers_summary_text_and_falls_back_to_error() {
    use agent_client_protocol::schema::v1::{
        CompactionStatus, CompactionUpdate, ContentBlock, TextContent,
    };
    let with_summary = CompactionUpdate::new("cmp-1", CompactionStatus::Completed).summary(vec![
        ContentBlock::Text(TextContent::new("省略 3 条更早消息")),
    ]);
    let event = host_event_from_update(SessionUpdate::CompactionUpdate(with_summary))
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
    let event = host_event_from_update(SessionUpdate::CompactionUpdate(with_error))
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
fn available_commands_config_updates_and_title_map() {
    use agent_client_protocol::schema::v1::{
        AvailableCommand, AvailableCommandsUpdate, ConfigOptionUpdate, SessionConfigOption,
        SessionConfigSelectOption, SessionInfoUpdate,
    };
    let commands = host_event_from_update(SessionUpdate::AvailableCommandsUpdate(
        AvailableCommandsUpdate::new(vec![AvailableCommand::new("compact", "Compact history")]),
    ))
    .expect("commands event");
    assert_eq!(
        commands,
        HostEvent::AvailableCommands {
            commands: vec![CommandView {
                name: "compact".to_string(),
                description: "Compact history".to_string(),
                requires_argument: false,
            }]
        }
    );

    let config = host_event_from_update(SessionUpdate::ConfigOptionUpdate(
        ConfigOptionUpdate::new(vec![SessionConfigOption::select(
            "mode",
            "Permissions",
            "workspace-write",
            vec![
                SessionConfigSelectOption::new("read-only", "Read-only"),
                SessionConfigSelectOption::new("workspace-write", "Workspace write"),
            ],
        )]),
    ))
    .expect("config event");
    let HostEvent::ConfigOptions { options } = config else {
        panic!("expected ConfigOptions");
    };
    assert_eq!(options.len(), 1);
    assert_eq!(options[0].id, "mode");
    assert_eq!(options[0].current, "workspace-write");
    assert_eq!(
        options[0].values,
        vec![
            ("read-only".to_string(), "Read-only".to_string()),
            ("workspace-write".to_string(), "Workspace write".to_string()),
        ]
    );

    let title = host_event_from_update(SessionUpdate::SessionInfoUpdate(
        SessionInfoUpdate::new().title("ACP title"),
    ))
    .expect("title event");
    assert_eq!(
        title,
        HostEvent::TitleUpdated {
            title: Some("ACP title".to_string())
        }
    );
}

#[test]
fn auth_required_error_exposes_methods_without_secret() {
    let error = agent_client_protocol::Error::auth_required().data(serde_json::json!({
        "authMethods": [
            {"id": "api-key", "name": "DeepSeek API Key", "description": "paste a key"},
            {"id": "terminal", "name": "dsh-acp login", "type": "terminal"}
        ]
    }));
    let failure = RequestFailure::from_error("session/new", error);
    assert!(failure.is_auth_required());
    let event = failure.auth_event().expect("auth event");
    let HostEvent::AuthRequired {
        message,
        auth_methods,
    } = event
    else {
        panic!("expected AuthRequired");
    };
    assert!(!message.contains("sk-"));
    assert_eq!(auth_methods.len(), 2);
    assert_eq!(auth_methods[0].id, "api-key");
    assert_eq!(auth_methods[0].name, "DeepSeek API Key");
    assert_eq!(auth_methods[0].kind, "agent");
    assert_eq!(auth_methods[1].kind, "terminal");
}

#[test]
fn non_auth_error_does_not_become_auth_required() {
    let failure = RequestFailure::from_error(
        "initialize",
        agent_client_protocol::Error::internal_error().data("boom"),
    );
    assert!(!failure.is_auth_required());
    assert!(failure.auth_event().is_none());
}

#[test]
fn permission_options_keep_ids_names_and_kind_labels() {
    use agent_client_protocol::schema::v1::{PermissionOption, PermissionOptionKind};
    let options = permission_option_views(&[
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
    let event = host_event_from_update(SessionUpdate::CurrentModeUpdate(CurrentModeUpdate::new(
        SessionModeId::new("plan"),
    )))
    .expect("mode event");
    assert_eq!(
        event,
        HostEvent::ModeUpdated {
            mode_id: "plan".to_string()
        }
    );
}
