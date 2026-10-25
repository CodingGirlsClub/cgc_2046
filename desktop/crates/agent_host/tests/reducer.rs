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

#[test]
fn steer_flushes_streaming_and_appends_user_message() {
    let mut state = HostState::new();
    state.push_user("first");
    state.apply(AgentEvent::TurnStarted {
        thread_id: "t1".into(),
    });
    state.apply(AgentEvent::TextDelta {
        text: "partial".into(),
    });
    state.apply(AgentEvent::SteerStarted {
        text: "instead do this".into(),
    });
    assert!(state.streaming.is_empty());
    assert_eq!(state.messages.len(), 3);
    assert_eq!(state.messages[1].text, "partial");
    assert_eq!(state.messages[2].text, "instead do this");
}

#[test]
fn compaction_pushes_system_notice() {
    let mut state = HostState::new();
    state.apply(AgentEvent::ContextCompacted { omitted_entries: 7 });
    assert_eq!(state.messages.len(), 1);
    assert_eq!(state.messages[0].role, cgc_agent_host::UiRole::System);
    assert!(state.messages[0].text.contains("省略 7 条"));
}

#[test]
fn subagent_events_update_cards() {
    let mut state = HostState::new();
    state.apply(AgentEvent::SubagentStarted {
        task: "lint".into(),
    });
    state.apply(AgentEvent::SubagentProgress {
        text: "checking".into(),
    });
    assert_eq!(state.subagents.len(), 1);
    assert_eq!(state.subagents[0].task, "lint");
    assert_eq!(state.subagents[0].text, "checking");
    assert_eq!(state.subagents[0].finished, None);
    state.apply(AgentEvent::SubagentFinished { ok: true });
    assert_eq!(state.subagents[0].finished, Some(true));
}

#[test]
fn tool_call_flushes_streaming_text_before_card() {
    let mut state = HostState::new();
    state.push_user("question");
    state.apply(AgentEvent::TurnStarted {
        thread_id: "t1".into(),
    });
    state.apply(AgentEvent::TextDelta {
        text: "先看一眼".into(),
    });
    state.apply(AgentEvent::ToolCallStarted {
        tool_call_id: "call_1".into(),
        tool_name: "read_file".into(),
        args: serde_json::json!({"path": "a.txt"}),
    });
    state.apply(AgentEvent::ToolCallFinished {
        tool_call_id: "call_1".into(),
        tool_name: "read_file".into(),
        ok: true,
        content: "contents".into(),
    });
    state.apply(AgentEvent::TextDelta {
        text: "看完了".into(),
    });
    state.apply(AgentEvent::TurnFinished {
        text: String::new(),
        stop_reason: StopReason::EndTurn,
    });

    // 工具卡之前的文本必须先固化：顺序要与持久化 Entry 重载后一致
    // （对齐 Zed 的 reducer —— 插入 ToolCall 条目前先 flush 流式文本）。
    let order: Vec<(UiRole, &str)> = state
        .messages
        .iter()
        .map(|message| (message.role, message.text.as_str()))
        .collect();
    assert_eq!(
        order,
        vec![
            (UiRole::User, "question"),
            (UiRole::Assistant, "先看一眼"),
            (UiRole::Tool, "read_file"),
            (UiRole::Assistant, "看完了"),
        ]
    );
}

#[test]
fn thinking_and_text_before_tool_keep_persisted_order() {
    let mut state = HostState::new();
    state.apply(AgentEvent::TurnStarted {
        thread_id: "t1".into(),
    });
    state.apply(AgentEvent::ThinkingDelta {
        text: "先想".into(),
    });
    state.apply(AgentEvent::TextDelta {
        text: "先说".into(),
    });
    state.apply(AgentEvent::ToolCallStarted {
        tool_call_id: "call_1".into(),
        tool_name: "read_file".into(),
        args: serde_json::json!({}),
    });
    state.apply(AgentEvent::ToolCallFinished {
        tool_call_id: "call_1".into(),
        tool_name: "read_file".into(),
        ok: true,
        content: "ok".into(),
    });
    state.apply(AgentEvent::TurnFinished {
        text: String::new(),
        stop_reason: StopReason::EndTurn,
    });
    let roles: Vec<UiRole> = state.messages.iter().map(|message| message.role).collect();
    assert_eq!(
        roles,
        vec![UiRole::Thinking, UiRole::Assistant, UiRole::Tool]
    );
    assert_eq!(state.messages[0].text, "先想");
    assert_eq!(state.messages[1].text, "先说");
}

#[test]
fn consecutive_tool_calls_flush_between_texts() {
    let mut state = HostState::new();
    state.apply(AgentEvent::TurnStarted {
        thread_id: "t1".into(),
    });
    for (call, text) in [("call_1", "first"), ("call_2", "second")] {
        state.apply(AgentEvent::TextDelta {
            text: format!("{text} "),
        });
        state.apply(AgentEvent::ToolCallStarted {
            tool_call_id: call.into(),
            tool_name: "read_file".into(),
            args: serde_json::json!({}),
        });
        state.apply(AgentEvent::ToolCallFinished {
            tool_call_id: call.into(),
            tool_name: "read_file".into(),
            ok: true,
            content: "ok".into(),
        });
    }
    state.apply(AgentEvent::TurnFinished {
        text: String::new(),
        stop_reason: StopReason::EndTurn,
    });
    let order: Vec<(UiRole, &str)> = state
        .messages
        .iter()
        .map(|message| (message.role, message.text.as_str()))
        .collect();
    assert_eq!(
        order,
        vec![
            (UiRole::Assistant, "first "),
            (UiRole::Tool, "read_file"),
            (UiRole::Assistant, "second "),
            (UiRole::Tool, "read_file"),
        ]
    );
}

#[test]
fn nested_subagents_get_separate_cards() {
    let mut state = HostState::new();
    state.apply(AgentEvent::SubagentStarted { task: "one".into() });
    state.apply(AgentEvent::SubagentStarted { task: "two".into() });
    state.apply(AgentEvent::SubagentFinished { ok: false });
    assert_eq!(state.subagents.len(), 2);
    assert_eq!(state.subagents[0].finished, None);
    assert_eq!(state.subagents[1].finished, Some(false));
}
