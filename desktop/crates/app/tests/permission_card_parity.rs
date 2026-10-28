//! 两轨审批卡对照（Stage 3.2a 验收项）：
//! 同一语义的审批请求，native（进程内 ACP server，4 档）与 external ACP
//! （stub agent 原样透传）→ 共享 `ThreadEvent`/`PermissionRequest` → 同一张
//! 权限卡数据（按钮顺序/文案/kind 样式完全一致）。

use std::time::{Duration, Instant};

use agent_client_protocol::schema::v1::{
    AgentCapabilities, InitializeRequest, InitializeResponse, NewSessionRequest,
    NewSessionResponse, PermissionOption, PermissionOptionKind, PromptRequest, PromptResponse,
    RequestPermissionRequest, SessionId, SessionNotification, SessionUpdate,
    StopReason as AcpStopReason, ToolCall, ToolCallStatus, ToolCallUpdate, ToolCallUpdateFields,
    ToolKind,
};
use agent_client_protocol::schema::ProtocolVersion;
use agent_client_protocol::{on_receive_request, Agent, Client, ConnectTo};
use cgc_agent_core::{AgentError, ApprovalRequest, ToolResultSummary, ToolTurnOutcome};
use cgc_agent_host::{NativeAcpServer, NativeAcpServerConfig, NativeTurn, NativeTurnRuntime};
use cgc_agent_provider::{StopReason, TokenUsage, ToolUse};
use cgc_agent_ui::conversation::{ConversationThread, PermissionRequest};
use cgc_agent_ui::permission_card::{
    permission_card_view, PermissionButtonTone, PermissionCardModel, PermissionCardView,
};
use cgc_desktop_app::agent_ingest::apply_thread_event;
use cgc_platform::acp::connection::{AcpHost, AcpHostConfig, HostEvent};
use futures::future::BoxFuture;

fn temp_cwd(tag: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "cgc-permission-card-parity-{}-{tag}",
        std::process::id()
    ));
    let _ = std::fs::create_dir_all(&dir);
    dir
}

fn args() -> serde_json::Value {
    serde_json::json!({"command": "ls"})
}

/// native 侧：运行时在工具执行前发起审批（approver → session/request_permission）。
struct NativeApprovalRuntime;

impl NativeTurnRuntime for NativeApprovalRuntime {
    fn run_turn(
        &mut self,
        turn: NativeTurn,
    ) -> BoxFuture<'static, Result<ToolTurnOutcome, AgentError>> {
        Box::pin(async move {
            let mut observer = turn.observer;
            observer.on_tool_call(&ToolUse {
                id: "call-1".to_string(),
                name: "run_command".to_string(),
                args: args(),
            });
            let _decision = turn
                .approver
                .decide(ApprovalRequest {
                    tool_call_id: "call-1".to_string(),
                    tool_name: "run_command".to_string(),
                    args: args(),
                })
                .await;
            observer.on_tool_result(&ToolResultSummary {
                tool_use_id: "call-1".to_string(),
                tool_name: "run_command".to_string(),
                content: "ok".to_string(),
                is_error: false,
            });
            let outcome = ToolTurnOutcome {
                text: "done".to_string(),
                usage: TokenUsage::default(),
                stop_reason: StopReason::EndTurn,
                tool_calls: Vec::new(),
                tool_results: Vec::new(),
            };
            observer.on_finished(&outcome);
            Ok(outcome)
        })
    }
}

/// external ACP 侧：stub agent 原样透传四个选项（与 native 4 档同 id/label/kind）。
fn stub_approval_agent() -> impl ConnectTo<Client> + 'static {
    Agent
        .builder()
        .name("stub-acp")
        .on_receive_request(
            async |_req: InitializeRequest, responder, _cx| {
                responder.respond(
                    InitializeResponse::new(ProtocolVersion::V1)
                        .agent_capabilities(AgentCapabilities::new()),
                )
            },
            on_receive_request!(),
        )
        .on_receive_request(
            async |_req: NewSessionRequest, responder, _cx| {
                responder.respond(NewSessionResponse::new(SessionId::new("stub-session")))
            },
            on_receive_request!(),
        )
        .on_receive_request(
            async |_req: PromptRequest, responder, cx| {
                let connection = cx.clone();
                cx.spawn(async move {
                    let session = SessionId::new("stub-session");
                    connection.send_notification(SessionNotification::new(
                        session.clone(),
                        SessionUpdate::ToolCall(
                            ToolCall::new("call-1", "run_command")
                                .name("run_command")
                                .kind(ToolKind::Execute)
                                .status(ToolCallStatus::InProgress)
                                .raw_input(args()),
                        ),
                    ))?;
                    let options = vec![
                        PermissionOption::new(
                            "allow_once",
                            "允许一次",
                            PermissionOptionKind::AllowOnce,
                        ),
                        PermissionOption::new(
                            "allow_session",
                            "本会话允许",
                            PermissionOptionKind::AllowAlways,
                        ),
                        PermissionOption::new(
                            "allow_pattern:ls",
                            "本会话允许 ls 前缀",
                            PermissionOptionKind::AllowAlways,
                        ),
                        PermissionOption::new("deny", "拒绝", PermissionOptionKind::RejectOnce),
                    ];
                    let request = RequestPermissionRequest::new(
                        session.clone(),
                        ToolCallUpdate::new(
                            "call-1",
                            ToolCallUpdateFields::new()
                                .title(Some("允许运行 run_command？".to_string()))
                                .name(Some("run_command".to_string()))
                                .raw_input(Some(args())),
                        ),
                        options,
                    );
                    let _ = connection.send_request(request).block_task().await;
                    connection.send_notification(SessionNotification::new(
                        session,
                        SessionUpdate::ToolCallUpdate(ToolCallUpdate::new(
                            "call-1",
                            ToolCallUpdateFields::new()
                                .status(Some(ToolCallStatus::Completed))
                                .raw_output(Some(serde_json::Value::String("ok".to_string()))),
                        )),
                    ))?;
                    responder.respond(PromptResponse::new(AcpStopReason::EndTurn))
                })?;
                Ok(())
            },
            on_receive_request!(),
        )
}

fn wait_ready(host: &AcpHost) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline {
        if let Some(event) = host.recv_timeout(Duration::from_millis(50)) {
            if matches!(event, HostEvent::Ready { .. }) {
                return;
            }
        }
    }
    panic!("native/acp host not ready");
}

/// 跑一轮并捕获共享模型里的审批请求与卡片数据。
fn run_and_capture(host: &AcpHost, prompt: &str) -> (PermissionRequest, PermissionCardView) {
    assert!(host.prompt(prompt));
    let mut thread = ConversationThread::new("parity");
    let mut captured: Option<PermissionRequest> = None;
    let mut responded = false;
    let deadline = Instant::now() + Duration::from_secs(20);
    while Instant::now() < deadline {
        let Some(event) = host.recv_timeout(Duration::from_millis(50)) else {
            continue;
        };
        let turn_end = matches!(event, HostEvent::TurnEnd { .. });
        apply_thread_event(&mut thread, &event);
        if let HostEvent::PermissionRequested { request_id, .. } = &event {
            let pending = thread
                .pending_permission
                .clone()
                .expect("approval must land in shared model");
            captured = Some(pending);
            assert!(
                host.respond_permission_option(request_id, "allow_once"),
                "approval card must be answerable"
            );
            responded = true;
        }
        if turn_end {
            break;
        }
    }
    assert!(responded, "turn must surface a permission request");
    let request = captured.expect("captured permission request");
    let view = permission_card_view(&PermissionCardModel::from_request(&request));
    (request, view)
}

#[test]
fn native_and_acp_tracks_produce_same_permission_card_data() {
    let native_server =
        NativeAcpServer::new(Box::new(NativeApprovalRuntime)).with_config(NativeAcpServerConfig {
            agent_name: "cgc-native".to_string(),
            version: "0.0.1".to_string(),
        });
    let native_host =
        AcpHost::start_in_process(AcpHostConfig::new("", temp_cwd("native")), native_server)
            .expect("start native in-process host");
    wait_ready(&native_host);
    let (native_request, native_view) = run_and_capture(&native_host, "run");

    let acp_host = AcpHost::start_in_process(
        AcpHostConfig::new("", temp_cwd("stub")),
        stub_approval_agent(),
    )
    .expect("start stub in-process host");
    wait_ready(&acp_host);
    let (acp_request, acp_view) = run_and_capture(&acp_host, "run");

    // 1) 两轨共享模型里的审批请求一致（request_id 是客户端本地序号，归一化后比较）。
    let normalize = |mut request: PermissionRequest| {
        request.request_id = "req".to_string();
        request
    };
    assert_eq!(normalize(native_request), normalize(acp_request));

    // 2) 两轨卡片数据逐字段一致：按钮顺序/文案/kind 样式相同。
    assert_eq!(native_view, acp_view);
    assert_eq!(
        native_view
            .buttons
            .iter()
            .map(|button| button.option_id.as_str())
            .collect::<Vec<_>>(),
        vec!["allow_once", "allow_session", "allow_pattern:ls", "deny"]
    );
    assert_eq!(
        native_view
            .buttons
            .iter()
            .map(|button| button.label.as_str())
            .collect::<Vec<_>>(),
        vec!["允许一次", "本会话允许", "本会话允许 ls 前缀", "拒绝"]
    );
    assert_eq!(
        native_view
            .buttons
            .iter()
            .map(|button| button.tone)
            .collect::<Vec<_>>(),
        vec![
            PermissionButtonTone::Primary,
            PermissionButtonTone::Secondary,
            PermissionButtonTone::Secondary,
            PermissionButtonTone::Danger,
        ]
    );

    native_host.shutdown();
    acp_host.shutdown();
}
