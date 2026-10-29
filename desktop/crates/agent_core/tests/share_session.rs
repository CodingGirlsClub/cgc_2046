use cgc_agent_core::{Agent, AutoApprover, SelectedModel, Thread};
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

fn thread(id: &str) -> Thread {
    Thread::new(
        id,
        SelectedModel::new(ProviderId::new("fake"), ModelId::new("m1")),
    )
}

#[test]
fn replace_thread_switches_history_and_keeps_working() {
    let fake = FakeProvider::new(ProviderId::new("fake"), "Fake", vec![model()]);
    fake.push_script(vec![
        Ok(CompletionEvent::Text("ok".into())),
        Ok(CompletionEvent::Stop(StopReason::EndTurn)),
    ]);
    let mut agent = Agent::new(thread("local"), None);
    let mut shared = thread("shared");
    shared.push_user("from another view");
    shared.push_assistant("shared answer", Vec::new(), None);
    agent.replace_thread(shared);
    assert_eq!(agent.thread().id, "shared");
    assert_eq!(agent.thread().entries.len(), 2);

    let workspace = std::env::temp_dir().join(format!("cgc-share-{}", std::process::id()));
    let _ = std::fs::create_dir_all(&workspace);
    let outcome = futures::executor::block_on(agent.prompt_with_tools(
        &fake,
        &model(),
        "continue",
        &ToolRegistry::with_read_tools(),
        &ToolContext::new(&workspace),
        &AutoApprover,
    ))
    .expect("turn");
    assert_eq!(outcome.text, "ok");
    assert_eq!(agent.thread().entries.len(), 4);
    let _ = std::fs::remove_dir_all(&workspace);
}
