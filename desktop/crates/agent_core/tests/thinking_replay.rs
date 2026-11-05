use cgc_agent_core::{Agent, SelectedModel, Thread};
use cgc_agent_provider::{
    CompletionEvent, FakeProvider, Model, ModelLimits, ProviderId, StopReason,
};

#[test]
fn signed_thinking_survives_a_completed_turn_and_serialization() {
    let model = Model::new(
        ProviderId::new("anthropic"),
        "Anthropic",
        "test",
        "Test",
        ModelLimits::new(32_000, 4_096),
    );
    let provider = FakeProvider::new(
        ProviderId::new("anthropic"),
        "Anthropic",
        vec![model.clone()],
    );
    provider.push_script(vec![
        Ok(CompletionEvent::Thinking {
            text: "先检查约束。".into(),
            signature: None,
        }),
        Ok(CompletionEvent::Thinking {
            text: String::new(),
            signature: Some("signed-reasoning".into()),
        }),
        Ok(CompletionEvent::Text("答案".into())),
        Ok(CompletionEvent::Stop(StopReason::EndTurn)),
    ]);
    let thread = Thread::new(
        "signed-history",
        SelectedModel::new(model.provider_id.clone(), model.id.clone()),
    );
    let mut agent = Agent::new(thread, None);
    futures::executor::block_on(agent.prompt(&provider, &model, "检查这个答案")).unwrap();
    let serialized = serde_json::to_string(agent.thread()).unwrap();
    let restored: Thread = serde_json::from_str(&serialized).unwrap();
    let thinking = restored.entries.iter().find_map(|entry| match entry {
        cgc_agent_core::Entry::Thinking {
            text, signature, ..
        } => Some((text.as_str(), signature.as_deref())),
        _ => None,
    });
    assert_eq!(thinking, Some(("先检查约束。", Some("signed-reasoning"))));
}

#[test]
fn tool_continuation_and_restored_history_keep_exact_content_order() {
    use cgc_agent_provider::{Content, Role, ToolUse};
    let model = Model::new(
        ProviderId::new("anthropic"),
        "Anthropic",
        "test",
        "Test",
        ModelLimits::new(32_000, 4096),
    );
    let provider = FakeProvider::new(model.provider_id.clone(), "Anthropic", vec![model.clone()]);
    let call = ToolUse {
        id: "read".into(),
        name: "read_file".into(),
        args: serde_json::json!({"path":"note.txt"}),
    };
    let content = vec![
        Content::Thinking {
            text: "first block".into(),
            signature: "first signature".into(),
        },
        Content::Text("checking".into()),
        Content::RedactedThinking {
            data: "opaque reasoning".into(),
        },
        Content::Thinking {
            text: "second block".into(),
            signature: "second signature".into(),
        },
        Content::ToolUse(call.clone()),
    ];
    let mut first = vec![
        Ok(CompletionEvent::Text("checking".into())),
        Ok(CompletionEvent::ToolUse(call)),
    ];
    first.extend(
        content
            .iter()
            .cloned()
            .map(|block| Ok(CompletionEvent::ContentBlock(block))),
    );
    first.push(Ok(CompletionEvent::Stop(StopReason::ToolUse)));
    provider.push_script(first);
    provider.push_script(vec![
        Ok(CompletionEvent::Text("finished".into())),
        Ok(CompletionEvent::Stop(StopReason::EndTurn)),
    ]);
    let workspace =
        std::env::temp_dir().join(format!("cgc-thinking-replay-{}", std::process::id()));
    std::fs::create_dir_all(&workspace).unwrap();
    std::fs::write(workspace.join("note.txt"), "the exercise").unwrap();
    let mut agent = Agent::new(
        Thread::new(
            "ordered",
            SelectedModel::new(model.provider_id.clone(), model.id.clone()),
        ),
        None,
    );
    let outcome = futures::executor::block_on(agent.prompt_with_tools(
        &provider,
        &model,
        "inspect note",
        &cgc_agent_tools::ToolRegistry::with_read_tools(),
        &cgc_agent_tools::ToolContext::new(&workspace),
        &cgc_agent_core::AutoApprover,
    ))
    .unwrap();
    assert_eq!(outcome.text, "checkingfinished");
    let requests = provider.requests();
    let replay = requests[1]
        .messages
        .iter()
        .find(|message| message.role == Role::Assistant)
        .unwrap();
    assert_eq!(replay.content, content);
    assert!(requests[1].messages.iter().any(|message| message.content.iter().any(|block| matches!(block, Content::ToolResult { content, is_error: false, .. } if content.contains("the exercise")))));
    let restored: Thread =
        serde_json::from_str(&serde_json::to_string(agent.thread()).unwrap()).unwrap();
    let replay = restored
        .messages()
        .into_iter()
        .find(|message| message.role == Role::Assistant)
        .unwrap();
    assert_eq!(replay.content, content);
    std::fs::remove_dir_all(workspace).unwrap();
}
