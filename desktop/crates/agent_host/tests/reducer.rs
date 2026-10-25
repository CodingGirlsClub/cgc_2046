use cgc_agent_conversation::conversation::{ConversationThread, Entry, NoticeLevel, ThreadStatus};
use cgc_agent_host::{AgentEvent, HostState};
use cgc_agent_provider::{StopReason, TokenUsage};

fn state() -> HostState {
    HostState::new()
}

fn usage(input: u64, output: u64) -> TokenUsage {
    TokenUsage {
        input,
        output,
        cache_read: 0,
        cache_creation: 0,
    }
}

#[test]
fn text_deltas_merge_into_one_assistant_entry_and_turn_closes() {
    let mut state = state();
    state.apply(AgentEvent::TurnStarted {
        thread_id: "t1".into(),
    });
    state.apply(AgentEvent::TextDelta { text: "he".into() });
    state.apply(AgentEvent::TextDelta { text: "llo".into() });
    assert_eq!(state.thread.entries.len(), 1);
    assert_eq!(
        state.thread.entries[0],
        Entry::Assistant {
            text: "hello".into()
        }
    );
    state.apply(AgentEvent::TurnFinished {
        text: "hello".into(),
        stop_reason: StopReason::EndTurn,
    });
    assert_eq!(state.thread.status, ThreadStatus::Idle);
    assert_eq!(state.thread.entries.len(), 1, "最终文本不重复追加");
}

#[test]
fn turn_finished_falls_back_to_final_text_without_deltas() {
    let mut state = state();
    state.apply(AgentEvent::TurnStarted {
        thread_id: "t1".into(),
    });
    state.apply(AgentEvent::TurnFinished {
        text: "final only".into(),
        stop_reason: StopReason::EndTurn,
    });
    assert_eq!(
        state.thread.entries[0],
        Entry::Assistant {
            text: "final only".into()
        }
    );
}

#[test]
fn follow_up_and_steer_append_user_entries() {
    let mut state = state();
    state.apply(AgentEvent::TurnStarted {
        thread_id: "t1".into(),
    });
    state.apply(AgentEvent::FollowUpStarted {
        text: "after".into(),
    });
    state.apply(AgentEvent::SteerStarted {
        text: "steer".into(),
    });
    assert_eq!(state.thread.entries.len(), 2);
    assert!(matches!(&state.thread.entries[0], Entry::User { text } if text == "after"));
    assert!(matches!(&state.thread.entries[1], Entry::User { text } if text == "steer"));
}

#[test]
fn tool_lifecycle_maps_args_status_output() {
    let mut state = state();
    state.apply(AgentEvent::TurnStarted {
        thread_id: "t1".into(),
    });
    state.apply(AgentEvent::ToolCallStarted {
        tool_call_id: "c1".into(),
        tool_name: "read_file".into(),
        args: serde_json::json!({"path": "a.rs"}),
    });
    state.apply(AgentEvent::ToolCallFinished {
        tool_call_id: "c1".into(),
        tool_name: "read_file".into(),
        ok: true,
        content: "ok".into(),
    });
    let Entry::ToolCall {
        tool_call_id,
        name,
        status,
        args,
        output,
        ..
    } = &state.thread.entries[0]
    else {
        panic!("tool entry");
    };
    assert_eq!(tool_call_id, "c1");
    assert_eq!(name.as_deref(), Some("read_file"));
    assert_eq!(status, "completed");
    assert!(args.as_deref().unwrap_or_default().contains("a.rs"));
    assert_eq!(output.as_deref(), Some("ok"));
}

#[test]
fn permission_request_sets_pending_and_resolves() {
    let mut state = state();
    state.apply(AgentEvent::PermissionRequested {
        tool_call_id: "c1".into(),
        tool_name: "run_command".into(),
        args: serde_json::json!({"cmd": "ls"}),
    });
    assert_eq!(state.thread.status, ThreadStatus::AwaitingApproval);
    assert!(state.pending_permission.is_some());
    assert!(state.resolve_permission("c1").is_some());
    assert!(state.pending_permission.is_none());
}

#[test]
fn usage_and_context_size_feed_model_usage() {
    let mut state = state();
    state.set_context_size(1000);
    state.apply(AgentEvent::UsageUpdated {
        usage: usage(10, 5),
        total: usage(20, 5),
    });
    assert_eq!(state.usage_total.total(), 25);
    assert_eq!(state.thread.usage.used, 15);
    assert_eq!(state.thread.usage.size, 1000);
}

#[test]
fn compaction_maps_to_entry_and_error_to_failed_notice() {
    let mut state = state();
    state.apply(AgentEvent::ContextCompacted { omitted_entries: 3 });
    let Entry::Compaction { summary, .. } = &state.thread.entries[0] else {
        panic!("compaction entry");
    };
    assert!(summary.as_deref().unwrap_or_default().contains('3'));

    state.apply(AgentEvent::Error {
        message: "boom".into(),
    });
    assert_eq!(state.thread.status, ThreadStatus::Failed);
    let Entry::Notice { level, text } = state.thread.entries.last().expect("notice") else {
        panic!("notice entry");
    };
    assert_eq!(*level, NoticeLevel::Error);
    assert_eq!(text, "boom");
    assert_eq!(state.last_error.as_deref(), Some("boom"));
}

#[test]
fn subagents_track_separately_from_thread_entries() {
    let mut state = state();
    state.apply(AgentEvent::ToolCallStarted {
        tool_call_id: "c1".into(),
        tool_name: "task".into(),
        args: serde_json::json!({}),
    });
    state.apply(AgentEvent::SubagentStarted { task: "t".into() });
    state.apply(AgentEvent::SubagentProgress { text: "p".into() });
    state.apply(AgentEvent::SubagentFinished { ok: true });
    assert_eq!(state.subagents.len(), 1);
    assert_eq!(state.subagents[0].tool_call_id.as_deref(), Some("c1"));
    assert_eq!(state.subagents[0].finished, Some(true));
    assert_eq!(state.thread.entries.len(), 1, "子 agent 不进对话行");
}

#[test]
fn begin_retry_requires_error_and_clears_it() {
    let mut state = state();
    assert!(!state.begin_retry());
    state.apply(AgentEvent::Error {
        message: "x".into(),
    });
    assert!(state.begin_retry());
    assert!(state.last_error.is_none());
    assert!(!state.begin_retry());
}

#[test]
fn new_state_uses_native_capabilities() {
    let thread: &ConversationThread = &HostState::new().thread;
    assert!(thread.capabilities.checkpoint_restore);
    assert!(thread.capabilities.steer);
    assert!(!cgc_agent_conversation::conversation::ThreadCapabilities::acp().checkpoint_restore);
}
