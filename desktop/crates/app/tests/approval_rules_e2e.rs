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

/// native 轨驱动（与 `NativeAgentView::drain_acp_events` 一致：弹卡前先走
/// settings 级 toolPermissions 规则，决定性 allow/deny 自动回传 + Notice + 不落 Permission 行）。
fn drive_native_turn(host: &AcpHost, rules: &ApprovalRules) -> TrackResult {
    drive_turn_with_auto(host, Some(rules))
}

/// external ACP 轨驱动（与 `RootView::drain_chat_events` 一致：**不做**规则自动
/// 决定，收到 request_permission 一律进共享审批卡，由用户选 option 回传）。
fn drive_acp_turn(host: &AcpHost) -> TrackResult {
    drive_turn_with_auto(host, None)
}

fn drive_turn_with_auto(host: &AcpHost, auto_rules: Option<&ApprovalRules>) -> TrackResult {
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
        // native 轨才走规则自动决定；ACP 轨此处恒为 None（客户端不拦截）。
        if let Some(auto) = auto_rules.and_then(|rules| auto_permission_for_event(rules, &event)) {
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
            // 共享权限卡：测试里直接选第一个 allow 选项，模拟用户点按钮。
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
    let result = drive_native_turn(&host, &allow_ls_rules());
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
    let result = drive_native_turn(&host, &deny_ls_rules());
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

/// 路线 A 核心断言：即使规则命中（引擎判定 Allow），external ACP 轨也必须弹
/// 共享审批卡、不得由客户端自动回传——策略只作用于 native。
#[test]
fn acp_matching_allow_rule_still_shows_shared_card() {
    let rules = allow_ls_rules();
    assert_eq!(
        rules.decide(Some("run_command"), Some("{\"command\":\"ls\"}")),
        cgc_desktop_app::approval_rules::RuleDecision::Allow,
        "规则本身对 stub ACP 工具名/参数是命中的（用于证明 ACP 轨仍不拦截）"
    );
    let host = start_acp();
    wait_ready(&host);
    let result = drive_acp_turn(&host);
    assert_turn_completed(&result);
    assert!(result.autos.is_empty(), "ACP 轨不得自动决定/自动回传");
    assert_eq!(result.manual_cards, 1, "ACP 命中规则也必须弹共享审批卡");
    assert_eq!(permission_rows(&result.thread), 1);
    assert!(notices(&result.thread).is_empty(), "ACP 无自动决定 Notice");
    host.shutdown();
}

/// 同上：deny 规则对 ACP 同样不生效（不自动拒绝），一律交给共享卡。
#[test]
fn acp_matching_deny_rule_still_shows_shared_card() {
    let rules = deny_ls_rules();
    assert_eq!(
        rules.decide(Some("run_command"), Some("{\"command\":\"ls\"}")),
        cgc_desktop_app::approval_rules::RuleDecision::Deny,
        "规则本身判定 deny"
    );
    let host = start_acp();
    wait_ready(&host);
    let result = drive_acp_turn(&host);
    assert_turn_completed(&result);
    assert!(result.autos.is_empty(), "ACP 轨不得自动拒绝");
    assert_eq!(result.manual_cards, 1);
    assert_eq!(permission_rows(&result.thread), 1);
    assert!(notices(&result.thread).is_empty());
    host.shutdown();
}

/// 两轨对照（路线 A）：同一份规则下 native 自动放行（不弹卡 + Notice），
/// external ACP 仍弹卡（客户端不拦截）。
#[test]
fn same_rules_auto_apply_only_to_native_track() {
    let native_host = start_native();
    wait_ready(&native_host);
    let native = drive_native_turn(&native_host, &allow_ls_rules());
    let acp_host = start_acp();
    wait_ready(&acp_host);
    let acp = drive_acp_turn(&acp_host);

    assert_turn_completed(&native);
    assert_turn_completed(&acp);
    // native：规则生效，自动 allow、无卡、有 Notice。
    assert_eq!(native.manual_cards, 0);
    assert_eq!(native.autos.len(), 1);
    assert!(native.autos[0].allowed);
    assert_eq!(permission_rows(&native.thread), 0);
    assert_eq!(
        notices(&native.thread),
        vec!["已按设置自动允许 run_command"]
    );
    // ACP：规则不生效，仍是共享卡 + 用户选择。
    assert!(acp.autos.is_empty());
    assert_eq!(acp.manual_cards, 1);
    assert_eq!(permission_rows(&acp.thread), 1);
    assert!(notices(&acp.thread).is_empty());
    native_host.shutdown();
    acp_host.shutdown();
}

#[test]
fn unmatched_rules_fall_back_to_shared_card() {
    let host = start_native();
    wait_ready(&host);
    let result = drive_native_turn(&host, &rules_from(serde_json::json!({})));
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
    let result = drive_native_turn(&host, &rules);
    assert_turn_completed(&result);
    assert!(
        result.autos.is_empty(),
        "confirm 必须弹卡（不叠加 default allow）"
    );
    assert_eq!(result.manual_cards, 1);
    assert_eq!(permission_rows(&result.thread), 1);
    host.shutdown();
}
