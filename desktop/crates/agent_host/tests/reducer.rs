use cgc_agent_host::{AgentEvent, HostState, UiRole};
use cgc_agent_provider::{StopReason, TokenUsage};

#[test]
fn text_deltas_become_one_assistant_message_and_turn_closes() {
    let mut state = HostState::new();
    state.push_user("hi");
    state.apply(AgentEvent::TurnStarted {
        thread_id: "t1".into(),
    });
    state.apply(AgentEvent::TextDelta { text: "he".into() });
    state.apply(AgentEvent::TextDelta { text: "llo".into() });
    assert_eq!(state.streaming, "hello");
    assert!(state.turn_active);
    state.apply(AgentEvent::TurnFinished {
        text: "hello".into(),
        stop_reason: StopReason::EndTurn,
    });
    assert!(!state.turn_active);
    assert_eq!(state.messages.len(), 2);
    assert_eq!(state.messages[1].role, UiRole::Assistant);
    assert_eq!(state.messages[1].text, "hello");
}

#[test]
fn permission_request_and_tool_result_update_state() {
    let mut state = HostState::new();
    state.apply(AgentEvent::PermissionRequested {
        tool_call_id: "call_1".into(),
        tool_name: "write_file".into(),
        args: serde_json::json!({"path": "a.txt"}),
    });
    let prompt = state.pending_permission.clone().expect("prompt");
    assert_eq!(prompt.tool_call_id, "call_1");
    assert!(state.resolve_permission("call_1").is_some());
    assert!(state.pending_permission.is_none());
    state.apply(AgentEvent::ToolCallFinished {
        tool_call_id: "call_1".into(),
        tool_name: "write_file".into(),
        ok: true,
        content: "wrote".into(),
    });
    assert_eq!(state.messages.len(), 1);
    assert_eq!(state.messages[0].role, UiRole::Tool);
}

#[test]
fn usage_event_updates_total() {
    let mut state = HostState::new();
    state.apply(AgentEvent::UsageUpdated {
        usage: TokenUsage {
            input: 3,
            output: 1,
            ..Default::default()
        },
        total: TokenUsage {
            input: 9,
            output: 4,
            ..Default::default()
        },
    });
    assert_eq!(state.usage_total.total(), 13);
}

#[test]
fn error_event_sets_last_error() {
    let mut state = HostState::new();
    state.apply(AgentEvent::Error {
        message: "boom".into(),
    });
    assert_eq!(state.last_error.as_deref(), Some("boom"));
    assert!(!state.turn_active);
}

#[test]
fn events_are_serde_roundtrippable() {
    let event = AgentEvent::TurnFinished {
        text: "done".into(),
        stop_reason: StopReason::EndTurn,
    };
    let raw = serde_json::to_string(&event).expect("ser");
    let back: AgentEvent = serde_json::from_str(&raw).expect("de");
    assert_eq!(back, event);
}

#[test]
fn follow_up_flushes_streaming_and_appends_user_message() {
    let mut state = HostState::new();
    state.push_user("first");
    state.apply(AgentEvent::TurnStarted {
        thread_id: "t1".into(),
    });
    state.apply(AgentEvent::TextDelta {
        text: "reply-one".into(),
    });
    state.apply(AgentEvent::FollowUpStarted {
        text: "second".into(),
    });
    assert!(state.streaming.is_empty());
    assert_eq!(
        state.messages.last().map(|message| message.text.as_str()),
        Some("second")
    );
    assert_eq!(state.messages.len(), 3);
}
