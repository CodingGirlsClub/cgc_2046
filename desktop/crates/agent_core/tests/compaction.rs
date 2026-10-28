use cgc_agent_core::{Agent, AutoApprover, NoopObserver, SelectedModel, Thread};
use cgc_agent_provider::{
    CompletionEvent, FakeProvider, Model, ModelId, ModelLimits, ProviderError, ProviderId,
    StopReason,
};
use cgc_agent_tools::{ToolContext, ToolRegistry};

fn small_model() -> Model {
    Model::new(
        ProviderId::new("fake"),
        "Fake",
        "small",
        "small",
        ModelLimits::new(800, 100),
    )
}

fn long_thread() -> Thread {
    let mut thread = Thread::new(
        "t1",
        SelectedModel::new(ProviderId::new("fake"), ModelId::new("small")),
    );
    for index in 0..20 {
        thread.push_user(format!("question {index} {}", "x".repeat(300)));
        thread.push_assistant(
            format!("answer {index} {}", "y".repeat(300)),
            Vec::new(),
            None,
        );
    }
    thread
}

fn script(text: &str) -> Vec<Result<CompletionEvent, ProviderError>> {
    vec![
        Ok(CompletionEvent::Text(text.to_string())),
        Ok(CompletionEvent::Stop(StopReason::EndTurn)),
    ]
}

#[test]
fn oversized_thread_is_summarised_before_request() {
    let fake = FakeProvider::new(ProviderId::new("fake"), "Fake", vec![small_model()]);
    fake.push_script(script("summary text"));
    fake.push_script(script("ok"));
    let thread = long_thread();
    let mut agent = Agent::new(thread, Some("system prompt".to_string()));
    let registry = ToolRegistry::with_read_tools();
    let workspace = std::env::temp_dir().join(format!("cgc-compaction-{}", std::process::id()));
    let _ = std::fs::create_dir_all(&workspace);
    let context = ToolContext::new(&workspace);
    futures::executor::block_on(agent.prompt_with_tools_observed(
        &fake,
        &small_model(),
        "new question",
        &registry,
        &context,
        &AutoApprover,
        &mut NoopObserver,
    ))
    .expect("turn");
    assert!(agent
        .thread()
        .entries
        .iter()
        .any(|entry| matches!(entry, cgc_agent_core::Entry::Compaction { .. })));
    let requests = fake.requests();
    let main = requests.last().unwrap();
    assert!(main
        .messages
        .iter()
        .any(|message| message.text() == "new question"));
    assert!(!main
        .messages
        .iter()
        .any(|message| message.text().starts_with("question 0 ")));
    let _ = std::fs::remove_dir_all(&workspace);
}

#[test]
fn summarisation_failure_falls_back_to_truncation() {
    let fake = FakeProvider::new(ProviderId::new("fake"), "Fake", vec![small_model()]);
    fake.push_script(vec![Err(ProviderError::api(429, "busy"))]);
    fake.push_script(script("ok"));
    let thread = long_thread();
    let mut agent = Agent::new(thread, Some("system prompt".to_string()));
    agent.set_reasoning_effort(Some("high".into()));
    let registry = ToolRegistry::with_read_tools();
    let workspace =
        std::env::temp_dir().join(format!("cgc-compaction-fallback-{}", std::process::id()));
    let _ = std::fs::create_dir_all(&workspace);
    let context = ToolContext::new(&workspace);
    let outcome = futures::executor::block_on(agent.prompt_with_tools_observed(
        &fake,
        &small_model(),
        "new question",
        &registry,
        &context,
        &AutoApprover,
        &mut NoopObserver,
    ))
    .expect("turn");
    assert_eq!(outcome.text, "ok");
    let requests = fake.requests();
    let main = requests.last().unwrap();
    assert!(main
        .messages
        .iter()
        .any(|message| message.text() == "new question"));
    assert_eq!(main.reasoning_effort.as_deref(), Some("high"));
    assert_eq!(
        main.max_output_tokens,
        Some(small_model().limits.max_output_tokens)
    );
    assert!(!agent
        .thread()
        .entries
        .iter()
        .any(|entry| matches!(entry, cgc_agent_core::Entry::Compaction { .. })));
    let _ = std::fs::remove_dir_all(&workspace);
}
