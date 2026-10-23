use cgc_agent_core::{Agent, AutoApprover, SelectedModel, Thread, TurnObserver};
use cgc_agent_provider::{
    CompletionEvent, FakeProvider, Model, ModelId, ModelLimits, ProviderId, StopReason,
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
fn oversized_thread_is_truncated_before_request() {
    let fake = FakeProvider::new(ProviderId::new("fake"), "Fake", vec![small_model()]);
    fake.push_script(vec![
        Ok(CompletionEvent::Text("ok".into())),
        Ok(CompletionEvent::Stop(StopReason::EndTurn)),
    ]);
    let thread = long_thread();
    let full_history = thread.messages().len();
    let mut agent = Agent::new(thread, Some("system prompt".to_string()));
    let registry = ToolRegistry::with_read_tools();
    let workspace = std::env::temp_dir().join(format!("cgc-compaction-{}", std::process::id()));
    let _ = std::fs::create_dir_all(&workspace);
    let context = ToolContext::new(&workspace);
    let mut recorder = Recorder::default();
    futures::executor::block_on(agent.prompt_with_tools_observed(
        &fake,
        &small_model(),
        "new question",
        &registry,
        &context,
        &AutoApprover,
        &mut recorder,
    ))
    .expect("turn");
    let request = &fake.requests()[0];
    assert!(request.messages.len() < full_history + 1);
    assert_eq!(request.messages[0].role, cgc_agent_provider::Role::System);
    assert!(request.messages[0].text().contains("system prompt"));
    assert!(!recorder.compactions.is_empty());
    assert!(recorder.compactions[0] > 0);
    let _ = std::fs::remove_dir_all(&workspace);
}
