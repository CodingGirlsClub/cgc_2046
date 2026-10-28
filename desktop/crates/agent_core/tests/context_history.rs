use cgc_agent_core::{Agent, SelectedModel, Thread};
use cgc_agent_provider::{
    CompletionEvent, Content, FakeProvider, Model, ModelId, ModelLimits, ProviderError, ProviderId,
    StopReason, ToolUse,
};

#[test]
fn oversized_tool_turn_never_sends_an_orphan_tool_result() {
    let model = Model::new(
        ProviderId::new("fake"),
        "Fake",
        "small",
        "small",
        ModelLimits::new(2_000, 200),
    );
    let provider = FakeProvider::new(ProviderId::new("fake"), "Fake", vec![model.clone()]);
    provider.push_script(vec![Err(ProviderError::api(429, "busy"))]);
    provider.push_script(vec![
        Ok(CompletionEvent::Text("continue".into())),
        Ok(CompletionEvent::Stop(StopReason::EndTurn)),
    ]);
    let mut thread = Thread::new(
        "tool-history",
        SelectedModel::new(ProviderId::new("fake"), ModelId::new("small")),
    );
    thread.push_user("Inspect the old exercise.");
    thread.push_assistant(
        "",
        vec![ToolUse {
            id: "old-call".into(),
            name: "read_file".into(),
            args: serde_json::json!({"path": "x".repeat(8_000)}),
        }],
        None,
    );
    thread.push_tool_result("old-call", "read_file", "old output", false);
    let mut agent = Agent::new(thread, None);

    // Even if the provider rejects the continuation, its request must remain legal.
    let _ =
        futures::executor::block_on(agent.prompt(&provider, &model, "Solve the next exercise."));

    let requests = provider.requests();
    let request = requests.last().expect("main completion");
    assert!(request
        .messages
        .iter()
        .any(|message| message.text() == "Solve the next exercise."));
    assert!(!request.messages.iter().flat_map(|message| &message.content).any(
        |content| matches!(content, Content::ToolResult { tool_use_id, .. } if tool_use_id == "old-call")
    ), "a dropped tool batch cannot leave its result in the next model request");
}

#[test]
fn restored_summary_replaces_covered_prefix_without_duplicating_the_tail() {
    let mut thread = Thread::new(
        "summary-replay",
        SelectedModel::new(ProviderId::new("fake"), ModelId::new("small")),
    );
    thread.push_user("covered question");
    thread.push_assistant("covered answer", vec![], None);
    thread.push_user("recent question");
    thread.push_assistant("recent answer", vec![], None);
    thread.entries.push(
        serde_json::from_value(serde_json::json!({
            "Compaction": {
                "summary": "The agreed learning goal.",
                "replaced_entries": 2,
                "covered_until": 2,
                "at": 0
            }
        }))
        .unwrap(),
    );
    thread.push_user("continue");

    let messages = thread.messages();
    assert!(!messages
        .iter()
        .any(|message| message.text().contains("covered question")));
    assert!(!messages
        .iter()
        .any(|message| message.text().contains("covered answer")));
    assert_eq!(
        messages
            .iter()
            .filter(|message| message.text() == "recent question")
            .count(),
        1
    );
    assert_eq!(
        messages
            .iter()
            .filter(|message| message.text() == "recent answer")
            .count(),
        1
    );
    assert_eq!(
        messages
            .iter()
            .filter(|message| message.text().contains("The agreed learning goal."))
            .count(),
        1
    );
}

#[test]
fn oversized_middle_turn_cannot_backfill_older_small_turns() {
    let model = Model::new(
        ProviderId::new("fake"),
        "Fake",
        "small",
        "small",
        ModelLimits::new(2_000, 200),
    );
    let provider = FakeProvider::new(ProviderId::new("fake"), "Fake", vec![model.clone()]);
    provider.push_script(vec![Err(ProviderError::api(429, "busy"))]);
    let mut thread = Thread::new(
        "continuous-history",
        SelectedModel::new(ProviderId::new("fake"), ModelId::new("small")),
    );
    thread.push_user("old small question");
    thread.push_assistant("old small answer", vec![], None);
    thread.push_user("middle question");
    thread.push_assistant("x".repeat(8_000), vec![], None);
    thread.push_user("recent question");
    thread.push_assistant("recent answer", vec![], None);
    let mut agent = Agent::new(thread, None);
    let _ = futures::executor::block_on(agent.prompt(&provider, &model, "next question"));

    let requests = provider.requests();
    let request = requests.last().expect("continuation request");
    for retained in ["recent question", "recent answer", "next question"] {
        assert!(request
            .messages
            .iter()
            .any(|message| message.text() == retained));
    }
    assert!(!request
        .messages
        .iter()
        .any(|message| message.text().starts_with("old small")));
}
