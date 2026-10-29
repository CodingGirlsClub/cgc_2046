use cgc_agent_core::{Agent, AgentError, AutoApprover, TurnObserver};
use cgc_agent_provider::{
    CompletionEvent, FakeProvider, Model, ModelId, ModelLimits, ProviderId, StopReason,
};
use cgc_agent_tools::{ToolContext, ToolRegistry};

fn model() -> Model {
    Model::new(
        ProviderId::new("fake"),
        "Fake",
        "m1",
        "m1",
        ModelLimits::new(8_000, 1_000),
    )
}

fn agent() -> Agent {
    let thread = cgc_agent_core::Thread::new(
        "t1",
        cgc_agent_core::SelectedModel::new(ProviderId::new("fake"), ModelId::new("m1")),
    );
    Agent::new(thread, None)
}

fn fake_with_texts(texts: &[&str]) -> FakeProvider {
    let fake = FakeProvider::new(ProviderId::new("fake"), "Fake", vec![model()]);
    for text in texts {
        fake.push_script(vec![
            Ok(CompletionEvent::Text((*text).to_string())),
            Ok(CompletionEvent::Stop(StopReason::EndTurn)),
        ]);
    }
    fake
}

#[derive(Default)]
struct Recorder {
    steers: Vec<String>,
}

impl TurnObserver for Recorder {
    fn on_steer_started(&mut self, text: &str) {
        self.steers.push(text.to_string());
    }
}

fn context() -> ToolContext {
    let workspace = std::env::temp_dir().join(format!("cgc-steer-{}", std::process::id()));
    let _ = std::fs::create_dir_all(&workspace);
    ToolContext::new(workspace)
}

#[test]
fn steer_interrupts_stream_and_continues_with_new_message() {
    let fake = fake_with_texts(&["partial", "final"]);
    let mut agent = agent();
    agent
        .steer_sender()
        .send("change direction".to_string())
        .expect("send steer");
    let registry = ToolRegistry::with_read_tools();
    let mut recorder = Recorder::default();
    let outcome = futures::executor::block_on(agent.prompt_with_tools_observed(
        &fake,
        &model(),
        "first",
        &registry,
        &context(),
        &AutoApprover,
        &mut recorder,
    ))
    .expect("turn");
    assert_eq!(outcome.text, "partialfinal");
    assert_eq!(fake.requests().len(), 2);
    assert_eq!(recorder.steers, vec!["change direction".to_string()]);
    assert_eq!(agent.thread().entries.len(), 4);
}

#[test]
fn steer_limit_stops_runaway_interrupts() {
    let fake = fake_with_texts(&["a", "b", "c", "d", "e", "f"]);
    let mut agent = agent();
    for index in 0..5 {
        agent
            .steer_sender()
            .send(format!("steer-{index}"))
            .expect("send");
    }
    let registry = ToolRegistry::with_read_tools();
    let error = futures::executor::block_on(agent.prompt_with_tools(
        &fake,
        &model(),
        "first",
        &registry,
        &context(),
        &AutoApprover,
    ))
    .unwrap_err();
    assert!(matches!(error, AgentError::StepLimitExceeded));
    assert_eq!(fake.requests().len(), cgc_agent_core::MAX_STEERS);
}
