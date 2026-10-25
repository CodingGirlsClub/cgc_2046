//! native 轨道的会话 ingestion 适配（Stage 2d）。
//!
//! `agent_host` 仍是 native 运行时的事件归约处（provider/tools/checkpoint 等能力不在
//! 这里合并）；本模块只把 typed `AgentEvent` 映射成共享模型 `ThreadEvent`，让 native
//! 视图可以像 ACP 一样只渲染 `ConversationThread`。
//!
//! 映射边界（2d 分步落地）：
//! - 文本/思考/工具/审批/用量/压缩/错误 → 共享模型；
//! - subagent 卡片仍由 `HostState.subagents` 渲染（模型暂无 subagent entry，2e 再定）；
//! - `TurnStarted` 不产生模型事件：native 的 user 气泡由视图在发送时写入模型
//!   （与 ACP 的 delta 回显不同，native prompt 本身不带 user 文本增量）。

use cgc_agent_host::events::AgentEvent;
use cgc_agent_ui::conversation::{ConversationThread, ThreadCapabilities, ThreadEvent};

/// native 线程的初始模型：能力位取 native 全量。
pub fn new_native_thread(thread_id: impl Into<String>) -> ConversationThread {
    ConversationThread::new(thread_id).with_capabilities(ThreadCapabilities::native())
}

/// 把一条 native `AgentEvent` 映射成共享 `ThreadEvent`；不进入模型的事件返回 `None`。
///
/// `context_size` 是该 model 的 context window（模型里没有这个信息，只能由视图传入）。
pub fn thread_event_from_agent_event(event: &AgentEvent, context_size: u64) -> Option<ThreadEvent> {
    match event {
        AgentEvent::TurnStarted { .. } => None,
        AgentEvent::FollowUpStarted { text } | AgentEvent::SteerStarted { text } => {
            Some(ThreadEvent::TurnStarted {
                user_text: text.clone(),
            })
        }
        AgentEvent::SubagentStarted { .. }
        | AgentEvent::SubagentProgress { .. }
        | AgentEvent::SubagentFinished { .. } => None,
        AgentEvent::ContextCompacted { omitted_entries } => Some(ThreadEvent::CompactionUpdated {
            status: "completed".to_string(),
            summary: Some(format!("省略 {omitted_entries} 条更早消息")),
        }),
        AgentEvent::TextDelta { text } => Some(ThreadEvent::TextDelta(text.clone())),
        AgentEvent::ThinkingDelta { text } => Some(ThreadEvent::ThinkingDelta(text.clone())),
        AgentEvent::ToolCallStarted {
            tool_call_id,
            tool_name,
            args,
        } => Some(ThreadEvent::ToolCallStarted {
            tool_call_id: tool_call_id.clone(),
            title: tool_name.clone(),
            name: Some(tool_name.clone()),
            kind: "tool".to_string(),
            status: "in_progress".to_string(),
            args: Some(args.to_string()),
            output: None,
            locations: Vec::new(),
        }),
        AgentEvent::PermissionRequested {
            tool_call_id,
            tool_name,
            args,
        } => Some(ThreadEvent::PermissionRequested {
            request_id: tool_call_id.clone(),
            title: format!("允许运行 {tool_name}？"),
            tool_call_id: Some(tool_call_id.clone()),
            args: Some(args.to_string()),
        }),
        AgentEvent::ToolCallFinished {
            tool_call_id,
            tool_name: _,
            ok,
            content,
        } => Some(ThreadEvent::ToolCallUpdated {
            tool_call_id: tool_call_id.clone(),
            title: None,
            status: Some(if *ok { "completed" } else { "failed" }.to_string()),
            output: Some(content.clone()),
        }),
        AgentEvent::UsageUpdated { usage, .. } => Some(ThreadEvent::UsageUpdated {
            used: usage.total(),
            size: context_size,
            cost: None,
        }),
        AgentEvent::TurnFinished { .. } => Some(ThreadEvent::TurnFinished { cancelled: false }),
        AgentEvent::Error { message } => Some(ThreadEvent::Failed(message.clone())),
    }
}

#[cfg(test)]
mod tests {
    use super::{new_native_thread, thread_event_from_agent_event};
    use cgc_agent_host::events::AgentEvent;
    use cgc_agent_provider::{StopReason, TokenUsage};
    use cgc_agent_ui::conversation::{Entry, NoticeLevel, ThreadEvent, ThreadStatus};

    fn args() -> serde_json::Value {
        serde_json::json!({"path": "a.rs"})
    }

    #[test]
    fn text_and_thinking_map_to_model_deltas() {
        assert_eq!(
            thread_event_from_agent_event(&AgentEvent::TextDelta { text: "hi".into() }, 0),
            Some(ThreadEvent::TextDelta("hi".into()))
        );
        assert_eq!(
            thread_event_from_agent_event(&AgentEvent::ThinkingDelta { text: "hmm".into() }, 0),
            Some(ThreadEvent::ThinkingDelta("hmm".into()))
        );
    }

    #[test]
    fn tool_lifecycle_maps_to_started_and_update() {
        let started = thread_event_from_agent_event(
            &AgentEvent::ToolCallStarted {
                tool_call_id: "call-1".into(),
                tool_name: "read_file".into(),
                args: args(),
            },
            0,
        )
        .expect("tool event");
        let ThreadEvent::ToolCallStarted {
            tool_call_id,
            name,
            status,
            args: tool_args,
            ..
        } = started
        else {
            panic!("tool started");
        };
        assert_eq!(tool_call_id, "call-1");
        assert_eq!(name.as_deref(), Some("read_file"));
        assert_eq!(status, "in_progress");
        assert!(tool_args.expect("args").contains("a.rs"));

        let finished = thread_event_from_agent_event(
            &AgentEvent::ToolCallFinished {
                tool_call_id: "call-1".into(),
                tool_name: "read_file".into(),
                ok: true,
                content: "ok".into(),
            },
            0,
        )
        .expect("tool update");
        assert_eq!(
            finished,
            ThreadEvent::ToolCallUpdated {
                tool_call_id: "call-1".into(),
                title: None,
                status: Some("completed".into()),
                output: Some("ok".into()),
            }
        );
    }

    #[test]
    fn permission_maps_with_tool_id_and_args() {
        let event = thread_event_from_agent_event(
            &AgentEvent::PermissionRequested {
                tool_call_id: "call-9".into(),
                tool_name: "run_command".into(),
                args: args(),
            },
            0,
        )
        .expect("perm");
        let ThreadEvent::PermissionRequested {
            request_id,
            tool_call_id,
            args: perm_args,
            ..
        } = event
        else {
            panic!("permission event");
        };
        assert_eq!(request_id, "call-9");
        assert_eq!(tool_call_id.as_deref(), Some("call-9"));
        assert!(perm_args.expect("args").contains("a.rs"));
    }

    #[test]
    fn usage_uses_context_size_for_percent() {
        let event = thread_event_from_agent_event(
            &AgentEvent::UsageUpdated {
                usage: TokenUsage {
                    input: 10,
                    output: 5,
                    cache_read: 2,
                    cache_creation: 0,
                },
                total: TokenUsage::default(),
            },
            100,
        )
        .expect("usage");
        assert_eq!(
            event,
            ThreadEvent::UsageUpdated {
                used: 17,
                size: 100,
                cost: None,
            }
        );
    }

    #[test]
    fn turn_lifecycle_converges_in_reducer() {
        let mut thread = new_native_thread("t");
        thread.apply(ThreadEvent::TurnStarted {
            user_text: "q".into(),
        });
        for event in [
            AgentEvent::ThinkingDelta {
                text: "plan".into(),
            },
            AgentEvent::TextDelta {
                text: "looking".into(),
            },
            AgentEvent::ToolCallStarted {
                tool_call_id: "c".into(),
                tool_name: "read_file".into(),
                args: args(),
            },
            AgentEvent::ToolCallFinished {
                tool_call_id: "c".into(),
                tool_name: "read_file".into(),
                ok: false,
                content: "denied".into(),
            },
            AgentEvent::ContextCompacted { omitted_entries: 3 },
            AgentEvent::TurnFinished {
                text: String::new(),
                stop_reason: StopReason::EndTurn,
            },
        ] {
            if let Some(event) = thread_event_from_agent_event(&event, 1000) {
                thread.apply(event);
            }
        }
        assert_eq!(thread.status, ThreadStatus::Idle);
        assert_eq!(thread.entries.len(), 5);
        assert!(matches!(thread.entries[0], Entry::User { .. }));
        assert!(matches!(thread.entries[1], Entry::Thinking { .. }));
        assert!(matches!(thread.entries[2], Entry::Assistant { .. }));
        assert!(matches!(thread.entries[3], Entry::ToolCall { .. }));
        assert!(matches!(thread.entries[4], Entry::Compaction { .. }));
        let Entry::ToolCall { status, output, .. } = &thread.entries[3] else {
            panic!("tool");
        };
        assert_eq!(status, "failed");
        assert_eq!(output.as_deref(), Some("denied"));
    }

    #[test]
    fn error_maps_to_failed_notice() {
        let event = thread_event_from_agent_event(
            &AgentEvent::Error {
                message: "boom".into(),
            },
            0,
        )
        .expect("error");
        let mut thread = new_native_thread("t");
        thread.apply(event);
        assert_eq!(thread.status, ThreadStatus::Failed);
        let Entry::Notice { level, text } = thread.entries.last().expect("notice") else {
            panic!("notice");
        };
        assert_eq!(*level, NoticeLevel::Error);
        assert_eq!(text, "boom");
    }

    #[test]
    fn subagent_events_and_turn_started_do_not_enter_model_yet() {
        assert!(thread_event_from_agent_event(
            &AgentEvent::TurnStarted {
                thread_id: "t".into(),
            },
            0
        )
        .is_none());
        assert!(thread_event_from_agent_event(
            &AgentEvent::SubagentStarted { task: "t".into() },
            0
        )
        .is_none());
        assert!(thread_event_from_agent_event(
            &AgentEvent::SubagentProgress { text: "p".into() },
            0
        )
        .is_none());
        assert!(
            thread_event_from_agent_event(&AgentEvent::SubagentFinished { ok: true }, 0).is_none()
        );
    }

    #[test]
    fn follow_up_and_steer_add_user_entries() {
        for event in [
            AgentEvent::FollowUpStarted {
                text: "after".into(),
            },
            AgentEvent::SteerStarted {
                text: "steer".into(),
            },
        ] {
            let mapped = thread_event_from_agent_event(&event, 0).expect("user event");
            let ThreadEvent::TurnStarted { user_text } = mapped else {
                panic!("user event");
            };
            assert!(!user_text.is_empty());
        }
    }
}
