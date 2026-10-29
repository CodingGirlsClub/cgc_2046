use cgc_agent_core::{Agent, SelectedModel, Thread};
use cgc_agent_provider::{
    CompletionEvent, FakeProvider, Model, ModelId, ModelLimits, ProviderId, StopReason,
};

fn model() -> Model {
    Model::new(
        ProviderId::new("fake"),
        "Fake",
        "small",
        "small",
        ModelLimits::new(2_000, 200),
    )
}

fn history() -> Thread {
    let mut thread = Thread::new(
        "context-budget",
        SelectedModel::new(ProviderId::new("fake"), ModelId::new("small")),
    );
    for index in 0..12 {
        thread.push_user(format!("question {index} {}", "x".repeat(300)));
        thread.push_assistant(format!("answer {index} {}", "y".repeat(300)), vec![], None);
    }
    thread
}

fn answer(provider: &FakeProvider, text: &str) {
    provider.push_script(vec![
        Ok(CompletionEvent::Text(text.into())),
        Ok(CompletionEvent::Stop(StopReason::EndTurn)),
    ]);
}

#[test]
fn compaction_preserves_explicit_reasoning_effort() {
    let model = model();
    let provider = FakeProvider::new(ProviderId::new("fake"), "Fake", vec![model.clone()]);
    answer(&provider, "Keep the original learning goal.");
    answer(&provider, "Continue the exercise.");
    let mut agent = Agent::new(history(), Some("Teach the current exercise.".into()));
    agent.set_reasoning_effort(Some("high".into()));

    futures::executor::block_on(agent.prompt(&provider, &model, "continue"))
        .expect("compacted conversation continues");

    let requests = provider.requests();
    let completion = requests.last().expect("completion request");
    assert_eq!(completion.reasoning_effort.as_deref(), Some("high"));
}

#[test]
fn oversized_fixed_inputs_fail_before_contacting_the_provider() {
    for (system, input) in [
        ("遵守当前课程约束。".repeat(200), "continue".to_string()),
        (
            "Teach this exercise.".to_string(),
            "保留这条完整输入。".repeat(200),
        ),
    ] {
        let model = model();
        let provider = FakeProvider::new(ProviderId::new("fake"), "Fake", vec![model.clone()]);
        let thread = Thread::new(
            "fixed-input",
            SelectedModel::new(ProviderId::new("fake"), ModelId::new("small")),
        );
        let mut agent = Agent::new(thread, Some(system));
        agent.set_pending_images(vec![(
            "exercise.png".into(),
            "image/png".into(),
            "aGVsbG8=".into(),
        )]);
        let error = futures::executor::block_on(agent.prompt(&provider, &model, input.clone()))
            .expect_err("known oversized fixed input must be rejected");
        assert!(matches!(
            error,
            cgc_agent_core::AgentError::ContextTooLarge {
                image_cost_unknown: true,
                ..
            }
        ));
        assert!(
            provider.requests().is_empty(),
            "no known oversized request may leave core"
        );
        assert!(
            agent.thread().entries.iter().any(
                |entry| matches!(entry, cgc_agent_core::Entry::User { text, .. } if text == &input)
            ),
            "rejection retains the user's original input for recovery"
        );
    }
}

#[test]
fn short_follow_ups_reuse_the_checkpoint_without_reprocessing_covered_history() {
    let model = model();
    let provider = FakeProvider::new(ProviderId::new("fake"), "Fake", vec![model.clone()]);
    for _ in 0..32 {
        answer(&provider, "Learn ownership before concurrency.");
    }
    let mut agent = Agent::new(history(), Some("Teach the current exercise.".into()));
    futures::executor::block_on(agent.prompt(&provider, &model, "continue")).unwrap();
    let checkpoints = agent
        .thread()
        .entries
        .iter()
        .filter(|entry| {
            matches!(
                entry,
                cgc_agent_core::Entry::Compaction {
                    covered_until: Some(_),
                    ..
                }
            )
        })
        .count();
    assert_eq!(
        checkpoints, 1,
        "first compression records one authoritative prefix"
    );
    let before = provider.requests().len();

    for input in ["clarify ownership", "give one example"] {
        futures::executor::block_on(agent.prompt(&provider, &model, input)).unwrap();
    }

    let requests = provider.requests();
    assert_eq!(
        requests[before..]
            .iter()
            .filter(|request| request
                .messages
                .iter()
                .any(|message| message.text().contains("question 0 ")))
            .count(),
        0,
        "covered source never returns to summary or completion requests"
    );
    assert_eq!(
        agent
            .thread()
            .entries
            .iter()
            .filter(|entry| matches!(
                entry,
                cgc_agent_core::Entry::Compaction {
                    covered_until: Some(_),
                    ..
                }
            ))
            .count(),
        checkpoints,
        "unchanged prefix must not be summarised again"
    );
    assert!(requests
        .last()
        .unwrap()
        .messages
        .iter()
        .any(|message| message.text() == "give one example"));
    assert!(agent.thread().entries.iter().any(
        |entry| matches!(entry, cgc_agent_core::Entry::User { text, .. } if text.starts_with("question 0 "))
    ), "compression must retain the original transcript");
}

#[test]
fn new_injected_context_is_not_scaled_by_the_previous_usage_ratio() {
    use cgc_agent_provider::TokenUsage;
    let model = model();
    let provider = FakeProvider::new(ProviderId::new("fake"), "Fake", vec![model.clone()]);
    answer(&provider, "Learn ownership.");
    answer(&provider, "Continue.");
    let mut thread = Thread::new(
        "usage-delta",
        SelectedModel::new(ProviderId::new("fake"), ModelId::new("small")),
    );
    thread.push_user("Remember the learning goal.");
    thread.push_assistant(
        "Ready.",
        vec![],
        Some(TokenUsage {
            input: 1_600,
            output: 100,
            ..TokenUsage::default()
        }),
    );
    let input = "新的课程文件上下文。".repeat(40);
    let mut agent = Agent::new(thread, None);

    futures::executor::block_on(agent.prompt(&provider, &model, input.clone()))
        .expect("new fixed input fits after reclaiming the previous history");

    let requests = provider.requests();
    let main = requests.last().unwrap();
    assert!(main.messages.iter().any(|message| message.text() == input));
    assert!(!main
        .messages
        .iter()
        .any(|message| message.text() == "Remember the learning goal."));
    assert!(main
        .messages
        .iter()
        .any(|message| message.text().contains("Learn ownership.")));
}

#[test]
fn tool_schemas_share_the_same_fixed_input_budget() {
    use cgc_agent_tools::{ToolContext, ToolRegistry};
    let mut model = model();
    model.limits = ModelLimits::new(180, 20);
    let selected = SelectedModel::new(ProviderId::new("fake"), ModelId::new("small"));
    let provider = FakeProvider::new(ProviderId::new("fake"), "Fake", vec![model.clone()]);
    let mut plain = Agent::new(Thread::new("plain", selected.clone()), None);
    futures::executor::block_on(plain.prompt(&provider, &model, "hello")).unwrap();

    let provider = FakeProvider::new(ProviderId::new("fake"), "Fake", vec![model.clone()]);
    let mut tools = Agent::new(Thread::new("tools", selected), None);
    let error = futures::executor::block_on(tools.prompt_with_tools(
        &provider,
        &model,
        "hello",
        &ToolRegistry::with_read_tools(),
        &ToolContext::new(std::env::temp_dir()),
        &cgc_agent_core::AutoApprover,
    ))
    .expect_err("schemas must not be treated as free context");

    assert!(matches!(
        error,
        cgc_agent_core::AgentError::ContextTooLarge { .. }
    ));
    assert!(
        provider.requests().is_empty(),
        "a schema-heavy fixed request cannot be sent"
    );
}
