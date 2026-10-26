//! ACP 客户端事件（[`HostEvent`]）→ 共享会话模型（`ConversationThread`）的唯一 ingestion。
//!
//! Stage 3.1 Phase A：native 运行时被包装成进程内 ACP server，协议层之后 native 与
//! external ACP 产生的是同一种 `HostEvent`。因此「把事件归约成对话行」只保留这一份
//! 实现（[`apply_thread_event`]），两条轨道都调用它；各视图只读 `ConversationThread`。
//!
//! 放在 app 而不是更下层的原因：`HostEvent` 属于协议层（`cgc-platform`），
//! `ConversationThread` 属于共享模型层（`cgc-agent-conversation`），两者由组合根
//! `app` 连接；不新增 domain→platform 的反向依赖。

use cgc_agent_ui::conversation::{ConversationThread, PlanStep, ThreadEvent};
use cgc_platform::acp::connection::HostEvent;

/// 把一条 ACP 客户端事件归约进共享会话模型。
///
/// 返回 `false` 表示这不是线程事件（会话就绪/配置/历史列表/退出等由调用方处理）。
pub fn apply_thread_event(thread: &mut ConversationThread, event: &HostEvent) -> bool {
    let thread_event = match event {
        HostEvent::Delta(text) => ThreadEvent::TextDelta(text.clone()),
        HostEvent::ThoughtDelta(text) => ThreadEvent::ThinkingDelta(text.clone()),
        // native follow-up/steer 与 ACP user_message_chunk 都是「用户插话」。
        HostEvent::UserMessage(text) => ThreadEvent::TurnStarted {
            user_text: text.clone(),
        },
        HostEvent::ToolCall { call } => ThreadEvent::ToolCallStarted {
            tool_call_id: call.tool_call_id.clone(),
            title: call.title.clone(),
            name: call.name.clone(),
            kind: call.kind.clone(),
            status: call.status.clone(),
            args: call.args.clone(),
            output: call.output.clone(),
            locations: call.locations.clone(),
        },
        HostEvent::ToolCallUpdated {
            tool_call_id,
            title,
            status,
            output,
        } => ThreadEvent::ToolCallUpdated {
            tool_call_id: tool_call_id.clone(),
            title: title.clone(),
            status: status.clone(),
            output: output.clone(),
        },
        HostEvent::PlanUpdated { steps } => ThreadEvent::PlanUpdated(
            steps
                .iter()
                .map(|step| PlanStep {
                    content: step.content.clone(),
                    priority: step.priority.clone(),
                    status: step.status.clone(),
                })
                .collect(),
        ),
        HostEvent::UsageUpdated { used, size, cost } => ThreadEvent::UsageUpdated {
            used: *used,
            size: *size,
            cost: cost.clone(),
        },
        HostEvent::TitleUpdated { title } => ThreadEvent::TitleUpdated(title.clone()),
        HostEvent::CompactionUpdated { status, summary } => ThreadEvent::CompactionUpdated {
            status: status.clone(),
            summary: summary.clone(),
        },
        HostEvent::PermissionRequested {
            request_id,
            title,
            tool_call_id,
            args,
            ..
        } => ThreadEvent::PermissionRequested {
            request_id: request_id.clone(),
            title: title.clone(),
            tool_call_id: tool_call_id.clone(),
            args: args.clone(),
        },
        HostEvent::TurnEnd { cancelled, .. } => ThreadEvent::TurnFinished {
            cancelled: *cancelled,
        },
        HostEvent::Error { message } => ThreadEvent::Failed(message.clone()),
        HostEvent::Ready { .. }
        | HostEvent::AvailableCommands { .. }
        | HostEvent::ConfigOptions { .. }
        | HostEvent::ModeUpdated { .. }
        | HostEvent::Sessions { .. }
        | HostEvent::Exited => return false,
    };
    thread.apply(thread_event);
    true
}

/// 用户发起一轮（两轨共用）：UI 已把输入框内容作为 user 行落进模型。
pub fn apply_user_turn(thread: &mut ConversationThread, user_text: impl Into<String>) {
    thread.apply(ThreadEvent::TurnStarted {
        user_text: user_text.into(),
    });
}

/// 用户答复审批后落行（两轨共用；`allowed` 为 false 时 Permission 行标记为拒绝）。
pub fn apply_permission_resolved(
    thread: &mut ConversationThread,
    request_id: impl Into<String>,
    allowed: bool,
) {
    thread.apply(ThreadEvent::PermissionResolved {
        request_id: request_id.into(),
        allowed,
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use cgc_agent_ui::conversation::{Entry, ThreadCapabilities, ThreadStatus};
    use cgc_platform::acp::connection::{
        CommandView, HostEvent, PermissionOptionView, ToolCallView,
    };

    fn thread(capabilities: ThreadCapabilities) -> ConversationThread {
        ConversationThread::new("t").with_capabilities(capabilities)
    }

    /// native 进程内 server 与 external ACP agent 对同一对话产出的 HostEvent 序列
    /// 必须归约出完全一致的会话模型（两轨对照的单测版本；端到端对照见 tests/）。
    #[test]
    fn native_and_acp_host_events_converge_on_same_thread() {
        // native 轨道：进程内 ACP server 映射出的 HostEvent。
        let native_events = vec![
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
                size: 4_000,
                cost: None,
            },
            HostEvent::CompactionUpdated {
                status: "completed".to_string(),
                summary: Some("省略 3 条更早消息".to_string()),
            },
            HostEvent::TurnEnd {
                cancelled: false,
                stop_reason: "EndTurn".to_string(),
            },
        ];
        // external ACP 轨道：同一个 agent 语义，经客户端映射后的事件序列。
        let acp_events = vec![
            HostEvent::Delta("hello".to_string()),
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
                size: 4_000,
                cost: None,
            },
            HostEvent::CompactionUpdated {
                status: "completed".to_string(),
                summary: Some("省略 3 条更早消息".to_string()),
            },
            HostEvent::TurnEnd {
                cancelled: false,
                stop_reason: "EndTurn".to_string(),
            },
        ];
        let mut native = thread(ThreadCapabilities::native());
        let mut acp = thread(ThreadCapabilities::acp());
        for event in &native_events {
            assert!(apply_thread_event(&mut native, event));
        }
        for event in &acp_events {
            assert!(apply_thread_event(&mut acp, event));
        }
        assert_eq!(native.entries, acp.entries);
        assert_eq!(native.usage, acp.usage);
        assert_eq!(native.status, ThreadStatus::Idle);
        assert_eq!(native.entries.len(), 4);
    }

    #[test]
    fn permission_request_maps_and_dedupes_repeated_events() {
        let mut thread = thread(ThreadCapabilities::native());
        let event = HostEvent::PermissionRequested {
            request_id: "perm-1".to_string(),
            title: "允许运行 run_command？".to_string(),
            tool_call_id: Some("c1".to_string()),
            tool_name: Some("run_command".to_string()),
            args: Some("{\"command\":\"ls\"}".to_string()),
            options: vec![PermissionOptionView {
                option_id: "allow_once".to_string(),
                name: "允许一次".to_string(),
                kind: "allow_once".to_string(),
            }],
        };
        assert!(apply_thread_event(&mut thread, &event));
        // 重复的同一审批（例如 observer 与 approver 各发一次）只保留一条。
        assert!(apply_thread_event(&mut thread, &event));
        assert_eq!(
            thread
                .entries
                .iter()
                .filter(|entry| matches!(entry, Entry::Permission { .. }))
                .count(),
            1
        );
        assert_eq!(thread.status, ThreadStatus::AwaitingApproval);
        apply_permission_resolved(&mut thread, "perm-1", true);
        let Entry::Permission { resolved, .. } = &thread.entries[0] else {
            panic!("permission entry");
        };
        assert_eq!(*resolved, Some(true));
        assert_eq!(thread.status, ThreadStatus::Generating);
    }

    #[test]
    fn session_level_events_are_not_thread_events() {
        let mut thread = thread(ThreadCapabilities::acp());
        assert!(!apply_thread_event(
            &mut thread,
            &HostEvent::Ready {
                agent_name: "a".to_string(),
                version: "1".to_string(),
                session_id: "s".to_string(),
            }
        ));
        assert!(!apply_thread_event(
            &mut thread,
            &HostEvent::AvailableCommands {
                commands: vec![CommandView {
                    name: "compact".to_string(),
                    description: "c".to_string(),
                    requires_argument: false,
                }],
            }
        ));
        assert!(!apply_thread_event(
            &mut thread,
            &HostEvent::ModeUpdated {
                mode_id: "plan".to_string()
            }
        ));
        assert!(thread.entries.is_empty());
    }

    #[test]
    fn user_message_and_error_map_to_thread_entries() {
        let mut thread = thread(ThreadCapabilities::native());
        assert!(apply_thread_event(
            &mut thread,
            &HostEvent::UserMessage("after".to_string())
        ));
        assert!(apply_thread_event(
            &mut thread,
            &HostEvent::Error {
                message: "boom".to_string()
            }
        ));
        assert!(matches!(&thread.entries[0], Entry::User { text } if text == "after"));
        assert_eq!(thread.status, ThreadStatus::Failed);
    }
}
