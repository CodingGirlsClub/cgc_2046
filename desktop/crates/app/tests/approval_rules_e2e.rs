//! settings 级审批规则端到端回归（Stage 3.2b）：
//! 两轨（native 进程内 ACP / external ACP stub）在收到审批请求时先走规则；
//! 决定性 allow/deny → 自动回传对应 kind 的 option、**不产生 Permission 行/不弹卡**、
//! 会话里补一条 system Notice，回合正常结束；ask/confirm → 回退共享权限卡。
//!
//! 测试里的驱动逻辑刻意与两轨视图的 drain 循环一致（规则命中时跳过 ingestion）。

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
use cgc_agent_ui::conversation::{ConversationThread, Entry};
use cgc_desktop_app::agent_ingest::{apply_notice, apply_thread_event};
use cgc_desktop_app::approval_rules::{
    auto_permission_for_event, ApprovalRules, AutoPermission, ToolPermissionSettings,
};
use cgc_platform::acp::connection::{AcpHost, AcpHostConfig, HostEvent};
use futures::future::BoxFuture;

fn temp_cwd(tag: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "cgc-approval-rules-e2e-{}-{tag}",
        std::process::id()
    ));
    let _ = std::fs::create_dir_all(&dir);
    dir
}

fn args() -> serde_json::Value {
    serde_json::json!({"command": "ls"})
}

fn rules_from(json: serde_json::Value) -> ApprovalRules {
    let settings: ToolPermissionSettings = serde_json::from_value(json).expect("settings");
    ApprovalRules::from_settings(&settings)
}

// ---------------------------------------------------------------------------
// 两轨上游（native runtime / external ACP stub）
// ---------------------------------------------------------------------------

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
            let _ = turn
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

fn stub_approval_agent() -> impl ConnectTo<Client> + 'static {
    stub_approval_agent_for("run_command".to_string(), args())
}

/// 参数化 stub：模拟 external ACP agent 用自己的工具名（如 codex 的
/// `exec_command`）发审批请求，验证通配 `"*"` 规则也能命中。
fn stub_approval_agent_for(
    tool_name: String,
    tool_args: serde_json::Value,
) -> impl ConnectTo<Client> + 'static {
    let tool_for_prompt = tool_name.clone();
    let args_for_prompt = tool_args.clone();
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
            async move |_req: PromptRequest, responder, cx| {
                let connection = cx.clone();
                let tool_name = tool_for_prompt.clone();
                let tool_args = args_for_prompt.clone();
                cx.spawn(async move {
                    let session = SessionId::new("stub-session");
                    connection.send_notification(SessionNotification::new(
                        session.clone(),
                        SessionUpdate::ToolCall(
                            ToolCall::new("call-1", tool_name.clone())
                                .name(tool_name.clone())
                                .kind(ToolKind::Execute)
                                .status(ToolCallStatus::InProgress)
                                .raw_input(tool_args.clone()),
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
                                .title(Some(format!("允许运行 {tool_name}？")))
                                .name(Some(tool_name.clone()))
                                .raw_input(Some(tool_args.clone())),
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

// ---------------------------------------------------------------------------
// 与视图 drain 循环一致的驱动
// ---------------------------------------------------------------------------

struct TrackResult {
    thread: ConversationThread,
    autos: Vec<AutoPermission>,
    /// 规则未命中时，经共享卡片手动回传的次数（回退路径）。
    manual_cards: usize,
    errored: bool,
}

fn drive_turn(host: &AcpHost, rules: &ApprovalRules) -> TrackResult {
    assert!(host.prompt("run"));
    let mut thread = ConversationThread::new("rules");
    let mut autos = Vec::new();
    let mut manual_cards = 0;
    let mut errored = false;
    let deadline = Instant::now() + Duration::from_secs(20);
    while Instant::now() < deadline {
        let Some(event) = host.recv_timeout(Duration::from_millis(50)) else {
            continue;
        };
        if matches!(event, HostEvent::Error { .. }) {
            errored = true;
        }
        let turn_end = matches!(event, HostEvent::TurnEnd { .. });
        // —— 与 native/ACP 视图 drain 一致的规则优先逻辑 ——
        if let Some(auto) = auto_permission_for_event(rules, &event) {
            assert!(
                host.respond_permission_option(&auto.request_id, &auto.option_id),
                "auto option must be answerable"
            );
            apply_notice(&mut thread, auto.notice.clone());
            autos.push(auto);
            if turn_end {
                break;
            }
            continue;
        }
        apply_thread_event(&mut thread, &event);
        if let HostEvent::PermissionRequested { request_id, .. } = &event {
            // 回退到共享权限卡：测试里直接选第一个 allow 选项，模拟用户点按钮。
            manual_cards += 1;
            let allowed_option = thread
                .pending_permission
                .as_ref()
                .expect("card pending")
                .options
                .iter()
                .find(|option| option.kind.is_allow())
                .map(|option| option.id.clone())
                .expect("allow option");
            assert!(host.respond_permission_option(request_id, allowed_option));
            cgc_desktop_app::agent_ingest::apply_permission_resolved(
                &mut thread,
                request_id.clone(),
                true,
            );
        }
        if turn_end {
            break;
        }
    }
    TrackResult {
        thread,
        autos,
        manual_cards,
        errored,
    }
}

fn start_native() -> AcpHost {
    let server =
        NativeAcpServer::new(Box::new(NativeApprovalRuntime)).with_config(NativeAcpServerConfig {
            agent_name: "cgc-native".to_string(),
            version: "0.0.1".to_string(),
        });
    AcpHost::start_in_process(AcpHostConfig::new("", temp_cwd("native")), server)
        .expect("start native host")
}

fn start_acp() -> AcpHost {
    AcpHost::start_in_process(
        AcpHostConfig::new("", temp_cwd("acp")),
        stub_approval_agent(),
    )
    .expect("start acp host")
}

fn start_acp_for(tool_name: &str, tool_args: serde_json::Value) -> AcpHost {
    AcpHost::start_in_process(
        AcpHostConfig::new("", temp_cwd("acp-other-tool")),
        stub_approval_agent_for(tool_name.to_string(), tool_args),
    )
    .expect("start acp host")
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
    panic!("host not ready");
}

fn permission_rows(thread: &ConversationThread) -> usize {
    thread
        .entries
        .iter()
        .filter(|entry| matches!(entry, Entry::Permission { .. }))
        .count()
}

fn notices(thread: &ConversationThread) -> Vec<String> {
    thread
        .entries
        .iter()
        .filter_map(|entry| match entry {
            Entry::Notice { text, .. } => Some(text.clone()),
            _ => None,
        })
        .collect()
}

fn assert_turn_completed(result: &TrackResult) {
    assert!(!result.errored, "turn must not surface HostEvent::Error");
    assert!(!result.thread.is_generating(), "turn must finish");
    assert!(
        result.thread.pending_permission.is_none(),
        "no pending permission may leak"
    );
}

// ---------------------------------------------------------------------------
// 用例
// ---------------------------------------------------------------------------

fn allow_ls_rules() -> ApprovalRules {
    rules_from(serde_json::json!({
        "tools": { "run_command": { "alwaysAllow": ["ls"] } }
    }))
}

fn deny_ls_rules() -> ApprovalRules {
    rules_from(serde_json::json!({
        "tools": { "run_command": { "alwaysDeny": ["ls"] } }
    }))
}

#[test]
fn native_rules_auto_allow_skips_card_and_completes_turn() {
    let host = start_native();
    wait_ready(&host);
    let result = drive_turn(&host, &allow_ls_rules());
    assert_turn_completed(&result);
    assert_eq!(result.manual_cards, 0, "自动允许不得弹卡");
    assert_eq!(result.autos.len(), 1);
    assert!(result.autos[0].allowed);
    assert_eq!(result.autos[0].option_id, "allow_once");
    assert_eq!(
        permission_rows(&result.thread),
        0,
        "自动决定不产生 Permission 行"
    );
    assert_eq!(
        notices(&result.thread),
        vec!["已按设置自动允许 run_command"]
    );
    host.shutdown();
}

#[test]
fn native_rules_auto_deny_skips_card_and_completes_turn() {
    let host = start_native();
    wait_ready(&host);
    let result = drive_turn(&host, &deny_ls_rules());
    assert_turn_completed(&result);
    assert_eq!(result.manual_cards, 0, "自动拒绝不得弹卡");
    assert_eq!(result.autos.len(), 1);
    assert!(!result.autos[0].allowed);
    assert_eq!(result.autos[0].option_id, "deny");
    assert_eq!(permission_rows(&result.thread), 0);
    assert_eq!(
        notices(&result.thread),
        vec!["已按设置自动拒绝 run_command"]
    );
    host.shutdown();
}

#[test]
fn acp_rules_auto_allow_skips_card_and_completes_turn() {
    let host = start_acp();
    wait_ready(&host);
    let result = drive_turn(&host, &allow_ls_rules());
    assert_turn_completed(&result);
    assert_eq!(result.manual_cards, 0);
    assert_eq!(result.autos.len(), 1);
    assert!(result.autos[0].allowed);
    assert_eq!(result.autos[0].option_id, "allow_once");
    assert_eq!(permission_rows(&result.thread), 0);
    assert_eq!(
        notices(&result.thread),
        vec!["已按设置自动允许 run_command"]
    );
    host.shutdown();
}

#[test]
fn acp_rules_auto_deny_skips_card_and_completes_turn() {
    let host = start_acp();
    wait_ready(&host);
    let result = drive_turn(&host, &deny_ls_rules());
    assert_turn_completed(&result);
    assert_eq!(result.manual_cards, 0);
    assert_eq!(result.autos.len(), 1);
    assert!(!result.autos[0].allowed);
    assert_eq!(result.autos[0].option_id, "deny");
    assert_eq!(permission_rows(&result.thread), 0);
    assert_eq!(
        notices(&result.thread),
        vec!["已按设置自动拒绝 run_command"]
    );
    host.shutdown();
}

#[test]
fn two_tracks_same_rules_produce_same_auto_decision_and_notice() {
    let native_host = start_native();
    wait_ready(&native_host);
    let native = drive_turn(&native_host, &allow_ls_rules());
    let acp_host = start_acp();
    wait_ready(&acp_host);
    let acp = drive_turn(&acp_host, &allow_ls_rules());

    assert_turn_completed(&native);
    assert_turn_completed(&acp);
    assert_eq!(native.autos.len(), acp.autos.len());
    assert_eq!(native.autos[0].option_id, acp.autos[0].option_id);
    assert_eq!(native.autos[0].allowed, acp.autos[0].allowed);
    assert_eq!(native.autos[0].notice, acp.autos[0].notice);
    assert_eq!(notices(&native.thread), notices(&acp.thread));
    assert_eq!(
        permission_rows(&native.thread),
        permission_rows(&acp.thread)
    );
    native_host.shutdown();
    acp_host.shutdown();
}

#[test]
fn unmatched_rules_fall_back_to_shared_card() {
    let host = start_native();
    wait_ready(&host);
    let result = drive_turn(&host, &rules_from(serde_json::json!({})));
    assert_turn_completed(&result);
    assert!(result.autos.is_empty());
    assert_eq!(result.manual_cards, 1, "无规则时必须回退共享权限卡");
    assert_eq!(permission_rows(&result.thread), 1);
    host.shutdown();
}

#[test]
fn confirm_beats_default_allow_and_forces_card() {
    let host = start_native();
    wait_ready(&host);
    let rules = rules_from(serde_json::json!({
        "default": "allow",
        "tools": { "run_command": { "alwaysConfirm": ["ls"] } }
    }));
    let result = drive_turn(&host, &rules);
    assert_turn_completed(&result);
    assert!(
        result.autos.is_empty(),
        "confirm 必须弹卡（不叠加 default allow）"
    );
    assert_eq!(result.manual_cards, 1);
    assert_eq!(permission_rows(&result.thread), 1);
    host.shutdown();
}

// ---------------------------------------------------------------------------
// 3.2b 补丁：通配 `"*"` 规则（ACP 工具名与 native 不同）
// ---------------------------------------------------------------------------

fn wildcard_deny_echo_rules() -> ApprovalRules {
    rules_from(serde_json::json!({
        "tools": { "*": { "alwaysDeny": ["echo"] } }
    }))
}

#[test]
fn acp_wildcard_auto_deny_matches_non_native_tool_name() {
    let host = start_acp_for("exec_command", serde_json::json!({"command": "echo hi"}));
    wait_ready(&host);
    let result = drive_turn(&host, &wildcard_deny_echo_rules());
    assert_turn_completed(&result);
    assert_eq!(result.manual_cards, 0, "通配 deny 必须自动拒绝、不弹卡");
    assert_eq!(result.autos.len(), 1);
    assert!(!result.autos[0].allowed);
    assert_eq!(
        result.autos[0].option_id, "deny",
        "回传第一个 reject 类选项"
    );
    assert_eq!(permission_rows(&result.thread), 0);
    assert_eq!(
        notices(&result.thread),
        vec!["已按设置自动拒绝 exec_command"]
    );
    host.shutdown();
}

#[test]
fn acp_wildcard_auto_allow_matches_non_native_tool_name() {
    let host = start_acp_for("exec_command", serde_json::json!({"command": "echo hi"}));
    wait_ready(&host);
    let rules = rules_from(serde_json::json!({
        "tools": { "*": { "alwaysAllow": ["^exec_"] } }
    }));
    let result = drive_turn(&host, &rules);
    assert_turn_completed(&result);
    assert_eq!(result.manual_cards, 0);
    assert_eq!(result.autos.len(), 1);
    assert!(result.autos[0].allowed);
    assert_eq!(result.autos[0].option_id, "allow_once");
    assert_eq!(
        notices(&result.thread),
        vec!["已按设置自动允许 exec_command"]
    );
    host.shutdown();
}

#[test]
fn wildcard_deny_wins_over_exact_allow_across_sources() {
    // 精确键放行 + 通配键拒绝同一命令：合并后 deny 优先。
    let host = start_native();
    wait_ready(&host);
    // native fake runtime 的命令是 `ls`。
    let rules = rules_from(serde_json::json!({
        "tools": {
            "run_command": { "alwaysAllow": ["ls"] },
            "*": { "alwaysDeny": ["ls"] }
        }
    }));
    let result = drive_turn(&host, &rules);
    assert_turn_completed(&result);
    assert_eq!(result.manual_cards, 0);
    assert_eq!(result.autos.len(), 1);
    assert!(!result.autos[0].allowed);
    assert_eq!(result.autos[0].option_id, "deny");
    host.shutdown();
}

#[test]
fn acp_wildcard_rule_miss_falls_back_to_shared_card() {
    let host = start_acp_for("exec_command", serde_json::json!({"command": "echo hi"}));
    wait_ready(&host);
    let rules = rules_from(serde_json::json!({
        "tools": { "*": { "alwaysDeny": ["rm -rf"] } }
    }));
    let result = drive_turn(&host, &rules);
    assert_turn_completed(&result);
    assert!(result.autos.is_empty(), "通配规则未命中不得自动决定");
    assert_eq!(result.manual_cards, 1, "回退共享权限卡");
    assert_eq!(permission_rows(&result.thread), 1);
    host.shutdown();
}
