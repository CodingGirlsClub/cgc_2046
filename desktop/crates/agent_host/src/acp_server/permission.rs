//! native 审批 → ACP `session/request_permission` 桥（Stage 3.1 Phase A）。
//!
//! native 4 档选项（允许一次 / 本会话允许 / 允许前缀 / 拒绝）编成 ACP
//! `PermissionOption`；客户端按 `option_id` 回传，这里再还原成
//! [`ApprovalDecision`] 交回 runtime。取消（客户端 `Cancelled` / 本地 turn
//! 被 cancel）一律按 `Deny` 处理：不默认允许。

use agent_client_protocol::schema::v1::{
    PermissionOption, PermissionOptionKind, RequestPermissionOutcome, RequestPermissionRequest,
    SessionId, ToolCallUpdate, ToolCallUpdateFields,
};
use agent_client_protocol::{Client, ConnectionTo};
use cgc_agent_core::{ApprovalRequest, Approver};
use cgc_agent_tools::ApprovalDecision;
use futures::future::BoxFuture;

use super::CancelSwitch;

pub const OPTION_ALLOW_ONCE: &str = "allow_once";
pub const OPTION_ALLOW_SESSION: &str = "allow_session";
pub const OPTION_DENY: &str = "deny";
const OPTION_ALLOW_PATTERN_PREFIX: &str = "allow_pattern:";

/// native 审批的 4 档选项；`allow_pattern` 仅在能从入参推出前缀时提供。
pub(crate) fn approval_options(request: &ApprovalRequest) -> Vec<PermissionOption> {
    let mut options = vec![
        PermissionOption::new(
            OPTION_ALLOW_ONCE,
            "允许一次",
            PermissionOptionKind::AllowOnce,
        ),
        PermissionOption::new(
            OPTION_ALLOW_SESSION,
            "本会话允许",
            PermissionOptionKind::AllowAlways,
        ),
    ];
    if let Some(prefix) = permission_pattern_prefix(&request.args) {
        options.push(PermissionOption::new(
            allow_pattern_option_id(&prefix),
            format!("本会话允许 {prefix} 前缀"),
            PermissionOptionKind::AllowAlways,
        ));
    }
    options.push(PermissionOption::new(
        OPTION_DENY,
        "拒绝",
        PermissionOptionKind::RejectOnce,
    ));
    options
}

/// 客户端侧拼 `allow_pattern` 的 option_id（native UI 用它回传前缀）。
pub fn allow_pattern_option_id(prefix: &str) -> String {
    format!("{OPTION_ALLOW_PATTERN_PREFIX}{prefix}")
}

/// 与 native UI 共用的前缀推导：`command` 取第一个词，`path` 取所在目录。
pub fn permission_pattern_prefix(args: &serde_json::Value) -> Option<String> {
    args.get("command")
        .and_then(|value| value.as_str())
        .and_then(|command| command.split_whitespace().next())
        .map(str::to_string)
        .or_else(|| {
            args.get("path")
                .and_then(|value| value.as_str())
                .and_then(|path| path.rsplit_once('/').map(|(dir, _)| dir.to_string()))
        })
        .filter(|prefix| !prefix.is_empty())
}

/// option_id → native 审批决定。未知 id / 取消 → `Deny`（不默认允许）。
pub(crate) fn decision_for_option(option_id: &str) -> ApprovalDecision {
    match option_id {
        OPTION_ALLOW_ONCE => ApprovalDecision::AllowOnce,
        OPTION_ALLOW_SESSION => ApprovalDecision::AllowForSession,
        OPTION_DENY => ApprovalDecision::Deny,
        _ => match option_id.strip_prefix(OPTION_ALLOW_PATTERN_PREFIX) {
            Some(prefix) if !prefix.is_empty() => {
                ApprovalDecision::AllowPattern(prefix.to_string())
            }
            _ => ApprovalDecision::Deny,
        },
    }
}

/// 一个 turn 的审批桥：把 native `Approver` 调用翻成 ACP request/response。
///
/// 运行在 turn 任务里（不在 dispatch loop），因此可以 `block_task` 等响应；
/// 同时和 turn 的 cancel 竞争，用户取消时立刻按 Deny 收尾，不卡住 turn。
pub(crate) struct PermissionBridge {
    pub(crate) connection: ConnectionTo<Client>,
    pub(crate) session_id: SessionId,
    pub(crate) cancel: CancelSwitch,
}

impl Approver for PermissionBridge {
    fn decide(&self, request: ApprovalRequest) -> BoxFuture<'static, ApprovalDecision> {
        let connection = self.connection.clone();
        let session_id = self.session_id.clone();
        let cancel = self.cancel.clone();
        Box::pin(async move {
            let options = approval_options(&request);
            let tool_call = ToolCallUpdate::new(
                request.tool_call_id.clone(),
                ToolCallUpdateFields::new()
                    .title(Some(format!("允许运行 {}？", request.tool_name)))
                    .name(Some(request.tool_name.clone()))
                    .raw_input(Some(request.args.clone())),
            );
            let permission = connection
                .send_request(RequestPermissionRequest::new(
                    session_id, tool_call, options,
                ))
                .block_task();
            futures::pin_mut!(permission);
            let cancelled = cancel.cancelled();
            futures::pin_mut!(cancelled);
            // 先轮询请求（正常路径最快），cancel 到来时 drop 请求会自动 $/cancel_request。
            match futures::future::select(permission, cancelled).await {
                futures::future::Either::Left((Ok(response), _)) => match response.outcome {
                    RequestPermissionOutcome::Selected(selected) => {
                        decision_for_option(&selected.option_id.0)
                    }
                    _ => ApprovalDecision::Deny,
                },
                futures::future::Either::Left((Err(_), _)) => ApprovalDecision::Deny,
                futures::future::Either::Right(_) => ApprovalDecision::Deny,
            }
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(args: serde_json::Value) -> ApprovalRequest {
        ApprovalRequest {
            tool_call_id: "c1".to_string(),
            tool_name: "run_command".to_string(),
            args,
        }
    }

    #[test]
    fn options_cover_value_more_than_once() {
        let options = approval_options(&request(serde_json::json!({"command": "ls -la"})));
        let ids = options
            .iter()
            .map(|option| option.option_id.0.to_string())
            .collect::<Vec<_>>();
        assert_eq!(
            ids,
            vec![
                OPTION_ALLOW_ONCE.to_string(),
                OPTION_ALLOW_SESSION.to_string(),
                allow_pattern_option_id("ls"),
                OPTION_DENY.to_string(),
            ]
        );
    }

    #[test]
    fn pattern_option_omitted_without_prefix() {
        let options = approval_options(&request(serde_json::json!({"query": "x"})));
        let ids = options
            .iter()
            .map(|option| option.option_id.0.to_string())
            .collect::<Vec<_>>();
        assert_eq!(
            ids,
            vec![
                OPTION_ALLOW_ONCE.to_string(),
                OPTION_ALLOW_SESSION.to_string(),
                OPTION_DENY.to_string(),
            ]
        );
    }

    #[test]
    fn decision_maps_option_ids_and_defaults_to_deny() {
        assert_eq!(
            decision_for_option(OPTION_ALLOW_ONCE),
            ApprovalDecision::AllowOnce
        );
        assert_eq!(
            decision_for_option(OPTION_ALLOW_SESSION),
            ApprovalDecision::AllowForSession
        );
        assert_eq!(decision_for_option(OPTION_DENY), ApprovalDecision::Deny);
        assert_eq!(
            decision_for_option("allow_pattern:cargo"),
            ApprovalDecision::AllowPattern("cargo".to_string())
        );
        assert_eq!(
            decision_for_option("allow_pattern:"),
            ApprovalDecision::Deny
        );
        assert_eq!(
            decision_for_option("something-else"),
            ApprovalDecision::Deny
        );
    }

    #[test]
    fn pattern_prefix_from_command_or_path() {
        assert_eq!(
            permission_pattern_prefix(&serde_json::json!({"command": "cargo test"})),
            Some("cargo".to_string())
        );
        assert_eq!(
            permission_pattern_prefix(&serde_json::json!({"path": "src/main.rs"})),
            Some("src".to_string())
        );
        assert_eq!(permission_pattern_prefix(&serde_json::json!({})), None);
        assert_eq!(
            permission_pattern_prefix(&serde_json::json!({"command": ""})),
            None
        );
    }
}
