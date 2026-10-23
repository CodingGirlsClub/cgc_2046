use cgc_agent_core::{Agent, AutoApprover, SelectedModel, Thread, TurnObserver};
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

#[derive(Default)]
struct Recorder {
    compactions: Vec<usize>,
}

impl TurnObserver for Recorder {
    fn on_compaction(&mut self, omitted_entries: usize) {
        self.compactions.push(omitted_entries);
    }
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
    let mut recorder = Recorder::default();
    let outcome = futures::executor::block_on(agent.prompt_with_tools_observed(
        &fake,
        &small_model(),
        "new question",
        &registry,
        &context,
        &AutoApprover,
        &mut recorder,
    ))
    .expect("turn");
    assert_eq!(outcome.text, "ok");
    let requests = fake.requests();
    assert_eq!(requests.len(), 2);
    assert!(requests[0].messages[0].text().contains("压缩器"));
    assert!(requests[1]
        .messages
        .iter()
        .any(|message| message.text().contains("历史摘要：summary text")));
    assert!(agent
        .thread()
        .entries
        .iter()
        .any(|entry| matches!(entry, cgc_agent_core::Entry::Compaction { .. })));
    assert!(!recorder.compactions.is_empty());
    let _ = std::fs::remove_dir_all(&workspace);
}

#[test]
fn summarisation_failure_falls_back_to_truncation() {
    let fake = FakeProvider::new(ProviderId::new("fake"), "Fake", vec![small_model()]);
    fake.push_script(vec![Err(ProviderError::api(429, "busy"))]);
    fake.push_script(script("ok"));
    let thread = long_thread();
    let full_history = thread.messages().len();
    let mut agent = Agent::new(thread, Some("system prompt".to_string()));
    let registry = ToolRegistry::with_read_tools();
    let workspace =
        std::env::temp_dir().join(format!("cgc-compaction-fallback-{}", std::process::id()));
    let _ = std::fs::create_dir_all(&workspace);
    let context = ToolContext::new(&workspace);
    let mut recorder = Recorder::default();
    let outcome = futures::executor::block_on(agent.prompt_with_tools_observed(
        &fake,
        &small_model(),
        "new question",
        &registry,
        &context,
        &AutoApprover,
        &mut recorder,
    ))
    .expect("turn");
    assert_eq!(outcome.text, "ok");
    let requests = fake.requests();
    assert_eq!(requests.len(), 2);
    assert!(requests[1].messages.len() < full_history + 1);
    assert!(!agent
        .thread()
        .entries
        .iter()
        .any(|entry| matches!(entry, cgc_agent_core::Entry::Compaction { .. })));
    assert!(!recorder.compactions.is_empty());
    let _ = std::fs::remove_dir_all(&workspace);
}
