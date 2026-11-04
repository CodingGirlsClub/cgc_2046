use cgc_agent_core::{Agent, AutoApprover, SelectedModel, Thread};
use cgc_agent_provider::{
    CompletionEvent, Content, FakeProvider, Model, ModelLimits, ProviderId, StopReason,
};
use cgc_agent_tools::{ToolContext, ToolRegistry};

#[test]
fn changing_tools_drops_old_signatures_without_reintroducing_them_after_restore() {
    let model = Model::new(
        ProviderId::new("test"),
        "Test",
        "model",
        "Model",
        ModelLimits::new(32000, 4096),
    );
    let provider = FakeProvider::new(model.provider_id.clone(), "Test", vec![model.clone()]);
    let thinking = Content::Thinking {
        text: "original reasoning".into(),
        signature: "original signature".into(),
    };
    provider.push_script(vec![
        Ok(CompletionEvent::ContentBlock(thinking.clone())),
        Ok(CompletionEvent::ContentBlock(Content::Text(
            "answer".into(),
        ))),
        Ok(CompletionEvent::Text("answer".into())),
        Ok(CompletionEvent::Stop(StopReason::EndTurn)),
    ]);
    for _ in 0..2 {
        provider.push_script(vec![
            Ok(CompletionEvent::Text("continued".into())),
            Ok(CompletionEvent::Stop(StopReason::EndTurn)),
        ]);
    }
    let mut agent = Agent::new(
        Thread::new(
            "changed-prefix",
            SelectedModel::new(model.provider_id.clone(), model.id.clone()),
        ),
        Some("fixed system".into()),
    );
    let tools = ToolRegistry::with_read_tools();
    let context = ToolContext::new(std::env::temp_dir());
    futures::executor::block_on(agent.prompt_with_tools(
        &provider,
        &model,
        "first",
        &tools,
        &context,
        &AutoApprover,
    ))
    .unwrap();
    // Removing tools changes the signed prefix, even though the text history is untouched.
    futures::executor::block_on(agent.prompt(&provider, &model, "without tools")).unwrap();
    let restored: Thread =
        serde_json::from_str(&serde_json::to_string(agent.thread()).unwrap()).unwrap();
    assert!(
        restored
            .messages()
            .iter()
            .flat_map(|message| &message.content)
            .any(|block| block == &thinking),
        "the original persisted history stays intact"
    );
    let mut restored = Agent::new(restored, Some("fixed system".into()));
    futures::executor::block_on(restored.prompt_with_tools(
        &provider,
        &model,
        "tools again",
        &tools,
        &context,
        &AutoApprover,
    ))
    .unwrap();
    for request in &provider.requests()[1..] {
        assert!(
            !request
                .messages
                .iter()
                .flat_map(|message| &message.content)
                .any(|block| matches!(
                    block,
                    Content::Thinking { .. } | Content::RedactedThinking { .. }
                )),
            "old reasoning must not cross a changed prefix or reappear later"
        );
        assert!(request
            .messages
            .iter()
            .any(|message| message.text() == "answer"));
    }
}

#[test]
fn restored_signatures_require_the_original_system_history_and_summary() {
    for change in ["unchanged", "system", "history", "compaction"] {
        let model = Model::new(
            ProviderId::new("test"),
            "Test",
            "model",
            "Model",
            ModelLimits::new(32000, 4096),
        );
        let provider = FakeProvider::new(model.provider_id.clone(), "Test", vec![model.clone()]);
        provider.push_script(vec![
            Ok(CompletionEvent::ContentBlock(Content::Thinking {
                text: "reasoning".into(),
                signature: "signed prefix".into(),
            })),
            Ok(CompletionEvent::ContentBlock(Content::RedactedThinking {
                data: "opaque block".into(),
            })),
            Ok(CompletionEvent::ContentBlock(Content::Text(
                "retained answer".into(),
            ))),
            Ok(CompletionEvent::Text("retained answer".into())),
            Ok(CompletionEvent::Stop(StopReason::EndTurn)),
        ]);
        provider.push_script(vec![
            Ok(CompletionEvent::Text("continued".into())),
            Ok(CompletionEvent::Stop(StopReason::EndTurn)),
        ]);
        let mut thread = Thread::new(
            change,
            SelectedModel::new(model.provider_id.clone(), model.id.clone()),
        );
        thread.push_user("old question");
        thread.push_assistant("old answer", vec![], None);
        let mut agent = Agent::new(thread, Some("original system".into()));
        futures::executor::block_on(agent.prompt(&provider, &model, "recent question")).unwrap();
        let mut restored: Thread =
            serde_json::from_str(&serde_json::to_string(agent.thread()).unwrap()).unwrap();
        match change {
            "history" => if let cgc_agent_core::Entry::User { text, .. } = &mut restored.entries[0] { *text = "edited question".into(); },
            "compaction" => restored.entries.push(serde_json::from_value(serde_json::json!({
                "Compaction": { "summary": "new history summary", "replaced_entries": 2, "covered_until": 2, "at": 0 }
            })).unwrap()),
            _ => {}
        }
        let system = if change == "system" {
            "changed system"
        } else {
            "original system"
        };
        let mut agent = Agent::new(restored, Some(system.into()));
        futures::executor::block_on(agent.prompt(&provider, &model, "continue")).unwrap();
        let requests = provider.requests();
        let request = &requests[1];
        for is_redacted in [false, true] {
            assert_eq!(
                request
                    .messages
                    .iter()
                    .flat_map(|message| &message.content)
                    .any(|block| {
                        if is_redacted {
                            matches!(block, Content::RedactedThinking { .. })
                        } else {
                            matches!(block, Content::Thinking { .. })
                        }
                    }),
                change == "unchanged",
                "signature validity for {change}, redacted={is_redacted}"
            );
        }
        assert!(request
            .messages
            .iter()
            .any(|message| message.text() == "retained answer"));
    }
}

#[test]
fn a_signed_tool_continuation_does_not_retry_failed_compaction() {
    use cgc_agent_provider::{ProviderError, ToolUse};
    let model = Model::new(
        ProviderId::new("test"),
        "Test",
        "model",
        "Model",
        ModelLimits::new(6000, 1000),
    );
    let provider = FakeProvider::new(model.provider_id.clone(), "Test", vec![model.clone()]);
    provider.push_script(vec![Err(ProviderError::api(
        429,
        "summary temporarily unavailable",
    ))]);
    let call = ToolUse {
        id: "inspect".into(),
        name: "read_file".into(),
        args: serde_json::json!({"path":"evidence.txt"}),
    };
    let content = vec![
        Content::Thinking {
            text: "inspect first".into(),
            signature: "valid tool prefix".into(),
        },
        Content::ToolUse(call.clone()),
    ];
    let mut response: Vec<_> = content
        .iter()
        .cloned()
        .map(|block| Ok(CompletionEvent::ContentBlock(block)))
        .collect();
    response.push(Ok(CompletionEvent::ToolUse(call)));
    response.push(Ok(CompletionEvent::Stop(StopReason::ToolUse)));
    provider.push_script(response);
    for text in ["final reply", "unexpected extra request"] {
        provider.push_script(vec![
            Ok(CompletionEvent::Text(text.into())),
            Ok(CompletionEvent::Stop(StopReason::EndTurn)),
        ]);
    }
    let mut thread = Thread::new(
        "frozen-summary",
        SelectedModel::new(model.provider_id.clone(), model.id.clone()),
    );
    for _ in 0..20 {
        thread.push_user("q".repeat(600));
        thread.push_assistant("a".repeat(600), vec![], None);
    }
    let root = std::env::temp_dir().join(format!("cgc-frozen-summary-{}", std::process::id()));
    std::fs::create_dir_all(&root).unwrap();
    std::fs::write(root.join("evidence.txt"), "tool evidence").unwrap();
    let mut agent = Agent::new(thread, Some("system".into()));
    let outcome = futures::executor::block_on(agent.prompt_with_tools(
        &provider,
        &model,
        "inspect evidence",
        &ToolRegistry::with_read_tools(),
        &ToolContext::new(&root),
        &AutoApprover,
    ))
    .unwrap();
    let requests = provider.requests();
    let continuation = requests.last().unwrap();
    let initial = &requests[1];
    assert_eq!(
        &continuation.messages[..initial.messages.len()],
        initial.messages.as_slice(),
        "the failed-summary fallback prefix must stay unchanged during the tool turn"
    );
    assert!(continuation
        .messages
        .iter()
        .any(|message| message.content == content));
    assert_eq!(outcome.text, "final reply");
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn invalidated_reasoning_and_its_usage_do_not_evict_small_text_history() {
    let model = Model::new(
        ProviderId::new("test"),
        "Test",
        "model",
        "Model",
        ModelLimits::new(16000, 8192),
    );
    let provider = FakeProvider::new(model.provider_id.clone(), "Test", vec![model.clone()]);
    provider.push_script(vec![
        Ok(CompletionEvent::ContentBlock(Content::Thinking {
            text: "r".repeat(24000),
            signature: "old prefix".into(),
        })),
        Ok(CompletionEvent::ContentBlock(Content::Text(
            "keep this answer".into(),
        ))),
        Ok(CompletionEvent::Text("keep this answer".into())),
        Ok(CompletionEvent::Usage(cgc_agent_provider::TokenUsage {
            input: 40,
            output: 8000,
            ..Default::default()
        })),
        Ok(CompletionEvent::Stop(StopReason::EndTurn)),
    ]);
    provider.push_script(vec![
        Ok(CompletionEvent::Text("continued".into())),
        Ok(CompletionEvent::Stop(StopReason::EndTurn)),
    ]);
    let mut agent = Agent::new(
        Thread::new(
            "reasoning-cost",
            SelectedModel::new(model.provider_id.clone(), model.id.clone()),
        ),
        None,
    );
    futures::executor::block_on(agent.prompt_with_tools(
        &provider,
        &model,
        "keep this question",
        &ToolRegistry::with_read_tools(),
        &ToolContext::new(std::env::temp_dir()),
        &AutoApprover,
    ))
    .unwrap();
    futures::executor::block_on(agent.prompt(&provider, &model, "without tools")).unwrap();
    let requests = provider.requests();
    let request = requests.last().unwrap();
    assert!(request
        .messages
        .iter()
        .any(|message| message.text() == "keep this question"));
    assert!(request
        .messages
        .iter()
        .any(|message| message.text() == "keep this answer"));
    assert!(!request
        .messages
        .iter()
        .flat_map(|message| &message.content)
        .any(Content::is_thinking));
}
