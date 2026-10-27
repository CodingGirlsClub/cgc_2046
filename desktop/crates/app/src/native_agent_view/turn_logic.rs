//! turn 生命周期的纯决策逻辑（B4b-a 第一步：从视图方法中抽出，可单测）。
//!
//! 这里不依赖 GPUI/Context：只做「事件 → turn 结束状态」「turn 结束 → 状态/文案」
//! 这类纯映射，视图侧负责副作用（notify/持久化/排队发送）。

use super::*;
use cgc_agent_provider::TokenUsage;
use cgc_agent_ui::conversation::{ConversationThread, ThreadStatus};

/// 把一条 ACP 事件映射成 turn 结束状态（`None` 表示不结束本轮）。
///
/// `cancelled` 标志与 `stop_reason == "cancelled"` 等价（部分 agent 只填其一）。
pub(super) fn turn_end_from_event(event: &HostEvent) -> Option<TurnEndState> {
    match event {
        HostEvent::TurnEnd {
            cancelled,
            stop_reason,
        } => {
            let cancelled = *cancelled || stop_reason.eq_ignore_ascii_case("cancelled");
            Some(if cancelled {
                TurnEndState::Cancelled
            } else {
                TurnEndState::Completed
            })
        }
        HostEvent::Error { message } => Some(TurnEndState::Failed(message.clone())),
        _ => None,
    }
}

/// Auto 模式下应自动回传的 option id（agent 提供的第一个 allow 选项）。
pub(super) fn first_allow_option_id(thread: &ConversationThread) -> Option<String> {
    thread
        .pending_permission
        .as_ref()
        .and_then(|request| request.options.iter().find(|option| option.kind.is_allow()))
        .map(|option| option.id.clone())
}

/// 应用 turn 结束对会话状态的影响，返回状态栏文案（副作用由调用方执行）。
///
/// - `Completed`：同步 usage 总量；
/// - `Failed`：记录 last_error，并在共享会话里补一行失败（若 ingestion 未落过）；
/// - `Cancelled`：只改文案。
pub(super) fn apply_turn_end(
    state: &mut NativeThreadState,
    end: &TurnEndState,
    usage_total: TokenUsage,
) -> String {
    match end {
        TurnEndState::Completed => {
            state.usage_total = usage_total;
            format!("完成 · 本会话 {} tokens", usage_total.total())
        }
        TurnEndState::Cancelled => "已停止".to_string(),
        TurnEndState::Failed(message) => {
            state.last_error = Some(message.clone());
            // HostEvent::Error 已由共用 ingestion 落过 Failed 行；这里只补
            // 合成失败（channel closed / 连接退出）缺失的那一行，避免重复。
            if !matches!(state.thread.status, ThreadStatus::Failed) {
                state
                    .thread
                    .apply(cgc_agent_ui::conversation::ThreadEvent::Failed(
                        message.clone(),
                    ));
            }
            format!("错误：{message}")
        }
    }
}

/// turn 正常结束后是否要生成标题（仅成功轮次）。
pub(super) fn should_generate_title(end: &TurnEndState) -> bool {
    matches!(end, TurnEndState::Completed)
}

#[cfg(test)]
mod tests {
    use super::{
        apply_turn_end, first_allow_option_id, should_generate_title, turn_end_from_event,
        TurnEndState,
    };
    use crate::native_agent_view::NativeThreadState;
    use cgc_agent_provider::TokenUsage;
    use cgc_agent_ui::conversation::ThreadStatus;
    use cgc_platform::acp::connection::HostEvent;

    fn thread_end(cancelled: bool, stop_reason: &str) -> HostEvent {
        HostEvent::TurnEnd {
            cancelled,
            stop_reason: stop_reason.to_string(),
        }
    }

    #[test]
    fn turn_end_maps_cancel_flags_and_errors() {
        assert_eq!(
            turn_end_from_event(&thread_end(true, "EndTurn")),
            Some(TurnEndState::Cancelled)
        );
        // 部分 agent 只填 stop_reason
        assert_eq!(
            turn_end_from_event(&thread_end(false, "cancelled")),
            Some(TurnEndState::Cancelled)
        );
        assert_eq!(
            turn_end_from_event(&thread_end(false, "EndTurn")),
            Some(TurnEndState::Completed)
        );
        assert_eq!(
            turn_end_from_event(&HostEvent::Error {
                message: "boom".into()
            }),
            Some(TurnEndState::Failed("boom".into()))
        );
        assert_eq!(turn_end_from_event(&HostEvent::Exited), None);
    }

    #[test]
    fn completed_updates_usage_and_status_text() {
        let mut state = NativeThreadState::new();
        let usage = TokenUsage {
            input: 10,
            output: 5,
            ..Default::default()
        };
        let status = apply_turn_end(&mut state, &TurnEndState::Completed, usage);
        assert_eq!(state.usage_total, usage);
        assert_eq!(status, format!("完成 · 本会话 {} tokens", usage.total()));
        assert!(should_generate_title(&TurnEndState::Completed));
    }

    #[test]
    fn failed_records_error_and_appends_single_failed_row() {
        let mut state = NativeThreadState::new();
        let status = apply_turn_end(
            &mut state,
            &TurnEndState::Failed("channel closed".into()),
            TokenUsage::default(),
        );
        assert_eq!(status, "错误：channel closed");
        assert_eq!(state.last_error.as_deref(), Some("channel closed"));
        assert!(matches!(state.thread.status, ThreadStatus::Failed));

        // 已经 Failed 的会话不再重复追加
        let before = state.thread.entries.len();
        let _ = apply_turn_end(
            &mut state,
            &TurnEndState::Failed("again".into()),
            TokenUsage::default(),
        );
        assert_eq!(state.thread.entries.len(), before);
        assert!(!should_generate_title(&TurnEndState::Failed("x".into())));
    }

    #[test]
    fn cancelled_only_changes_status_text() {
        let mut state = NativeThreadState::new();
        let status = apply_turn_end(&mut state, &TurnEndState::Cancelled, TokenUsage::default());
        assert_eq!(status, "已停止");
        assert!(state.last_error.is_none());
        assert!(!should_generate_title(&TurnEndState::Cancelled));
    }

    #[test]
    fn auto_mode_picks_first_allow_option() {
        use cgc_agent_ui::conversation::{
            PermissionOption, PermissionOptionKind, PermissionRequest,
        };
        let mut state = NativeThreadState::new();
        assert_eq!(first_allow_option_id(&state.thread), None);

        state.thread.pending_permission = Some(PermissionRequest {
            request_id: "r1".into(),
            title: "审批".into(),
            tool: Some("run_command".into()),
            tool_call_id: None,
            args: None,
            options: vec![
                PermissionOption {
                    id: "deny".into(),
                    label: "拒绝".into(),
                    kind: PermissionOptionKind::RejectOnce,
                },
                PermissionOption {
                    id: "allow".into(),
                    label: "允许".into(),
                    kind: PermissionOptionKind::AllowOnce,
                },
            ],
        });
        assert_eq!(
            first_allow_option_id(&state.thread).as_deref(),
            Some("allow")
        );
    }
}
