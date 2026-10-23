use cgc_agent_core::{Agent, AutoApprover, TurnObserver, MAX_FOLLOW_UP_TURNS};
use cgc_agent_provider::{
    CompletionEvent, FakeProvider, Model, ModelId, ModelLimits, ProviderError, ProviderId,
    StopReason,
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
    follow_ups: Vec<String>,
}

impl TurnObserver for Recorder {
    fn on_follow_up_started(&mut self, text: &str) {
        self.follow_ups.push(text.to_string());
    }
}

#[test]
fn queued_follow_up_runs_after_first_turn() {
    let fake = fake_with_texts(&["one", "two"]);
    let mut agent = agent();
    agent.queue_follow_up("second");
    let registry = ToolRegistry::with_read_tools();
    let workspace = std::env::temp_dir().join(format!("cgc-follow-up-{}", std::process::id()));
    let _ = std::fs::create_dir_all(&workspace);
    let context = ToolContext::new(&workspace);
    let mut recorder = Recorder::default();
    let outcome = futures::executor::block_on(agent.prompt_with_tools_observed(
        &fake,
        &model(),
        "first",
        &registry,
        &context,
        &AutoApprover,
        &mut recorder,
    ))
    .expect("turn");
    assert_eq!(outcome.text, "onetwo");
    assert_eq!(fake.requests().len(), 2);
    assert_eq!(agent.thread().entries.len(), 4);
    assert_eq!(recorder.follow_ups, vec!["second".to_string()]);
    assert_eq!(agent.pending_follow_ups(), 0);
    let _ = std::fs::remove_dir_all(&workspace);
}

#[test]
fn sender_can_queue_while_agent_is_moved() {
    let fake = fake_with_texts(&["one", "two"]);
    let mut agent = agent();
    let sender = agent.follow_up_sender();
    sender.send("from-ui".to_string()).expect("send");
    let registry = ToolRegistry::with_read_tools();
    let workspace =
        std::env::temp_dir().join(format!("cgc-follow-up-sender-{}", std::process::id()));
    let _ = std::fs::create_dir_all(&workspace);
    let context = ToolContext::new(&workspace);
    let outcome = futures::executor::block_on(agent.prompt_with_tools(
        &fake,
        &model(),
        "first",
        &registry,
        &context,
        &AutoApprover,
    ))
    .expect("turn");
    assert_eq!(outcome.text, "onetwo");
    assert_eq!(fake.requests().len(), 2);
    let _ = std::fs::remove_dir_all(&workspace);
}

#[test]
fn follow_up_turns_are_bounded() {
    let fake = fake_with_texts(&["a", "b", "c", "d", "e", "f"]);
    let mut agent = agent();
    for index in 0..=MAX_FOLLOW_UP_TURNS {
        agent.queue_follow_up(format!("follow-{index}"));
    }
    let registry = ToolRegistry::with_read_tools();
    let workspace =
        std::env::temp_dir().join(format!("cgc-follow-up-limit-{}", std::process::id()));
    let _ = std::fs::create_dir_all(&workspace);
    let context = ToolContext::new(&workspace);
    let outcome = futures::executor::block_on(agent.prompt_with_tools(
        &fake,
        &model(),
        "first",
        &registry,
        &context,
        &AutoApprover,
    ))
    .expect("turn");
    assert_eq!(outcome.text, "abcde");
    assert_eq!(fake.requests().len(), 1 + MAX_FOLLOW_UP_TURNS);
    assert_eq!(agent.pending_follow_ups(), 1);
    let _ = std::fs::remove_dir_all(&workspace);
}
