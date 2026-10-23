use cgc_agent_core::{Agent, AutoApprover};
use cgc_agent_host::{AgentEvent, AsyncChannelObserver, ChannelObserver, EventCollector};
use cgc_agent_provider::{
    CompletionEvent, FakeProvider, Model, ModelId, ModelLimits, ProviderId, StopReason, ToolUse,
};
use cgc_agent_tools::{ToolContext, ToolRegistry};
use futures::StreamExt as _;

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

fn temp_workspace(tag: &str) -> std::path::PathBuf {
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let serial = COUNTER.fetch_add(1, Ordering::Relaxed);
    let dir = std::env::temp_dir().join(format!(
        "cgc-agent-host-{}-{tag}-{serial}",
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("workspace");
    dir
}

#[test]
fn collector_records_full_tool_turn() {
    let workspace = temp_workspace("collector");
    std::fs::write(workspace.join("a.txt"), "hello").expect("write");
    let fake = FakeProvider::new(ProviderId::new("fake"), "Fake", vec![model()]);
    fake.push_script(vec![
        Ok(CompletionEvent::ToolUse(ToolUse {
            id: "call_1".into(),
            name: "read_file".into(),
            args: serde_json::json!({"path": "a.txt"}),
        })),
        Ok(CompletionEvent::Stop(StopReason::ToolUse)),
    ]);
    fake.push_script(vec![
        Ok(CompletionEvent::Text("done".into())),
        Ok(CompletionEvent::Stop(StopReason::EndTurn)),
    ]);
    let registry = ToolRegistry::with_read_tools();
    let context = ToolContext::new(&workspace);
    let mut collector = EventCollector::new();
    let mut agent = agent();
    futures::executor::block_on(agent.prompt_with_tools_observed(
        &fake,
        &model(),
        "read",
        &registry,
        &context,
        &AutoApprover,
        &mut collector,
    ))
    .expect("turn");
    let events = collector.events();
    assert!(matches!(
        events.first(),
        Some(AgentEvent::TurnStarted { .. })
    ));
    assert!(events
        .iter()
        .any(|event| matches!(event, AgentEvent::ToolCallStarted { tool_name, .. } if tool_name == "read_file")));
    assert!(events
        .iter()
        .any(|event| matches!(event, AgentEvent::ToolCallFinished { ok: true, .. })));
    assert!(events
        .iter()
        .any(|event| matches!(event, AgentEvent::TextDelta { text } if text == "done")));
    assert!(matches!(
        events.last(),
        Some(AgentEvent::TurnFinished { .. })
    ));
    let _ = std::fs::remove_dir_all(&workspace);
}

#[test]
fn channel_observer_streams_events() {
    let fake = FakeProvider::new(ProviderId::new("fake"), "Fake", vec![model()]);
    fake.push_script(vec![
        Ok(CompletionEvent::Text("hi".into())),
        Ok(CompletionEvent::Stop(StopReason::EndTurn)),
    ]);
    let (sender, receiver) = std::sync::mpsc::channel();
    let mut observer = ChannelObserver::new(sender);
    let registry = ToolRegistry::with_read_tools();
    let workspace = temp_workspace("channel");
    let context = ToolContext::new(&workspace);
    let mut agent = agent();
    futures::executor::block_on(agent.prompt_with_tools_observed(
        &fake,
        &model(),
        "hello",
        &registry,
        &context,
        &AutoApprover,
        &mut observer,
    ))
    .expect("turn");
    let events: Vec<AgentEvent> = receiver.try_iter().collect();
    assert!(events
        .iter()
        .any(|event| matches!(event, AgentEvent::TextDelta { text } if text == "hi")));
    assert!(matches!(
        events.last(),
        Some(AgentEvent::TurnFinished { .. })
    ));
    let _ = std::fs::remove_dir_all(&workspace);
}

#[test]
fn async_observer_streams_events() {
    let fake = FakeProvider::new(ProviderId::new("fake"), "Fake", vec![model()]);
    fake.push_script(vec![
        Ok(CompletionEvent::Text("hi".into())),
        Ok(CompletionEvent::Stop(StopReason::EndTurn)),
    ]);
    let (sender, mut receiver) = futures::channel::mpsc::unbounded();
    let mut observer = AsyncChannelObserver::new(sender);
    let registry = ToolRegistry::with_read_tools();
    let workspace = temp_workspace("async");
    let context = ToolContext::new(&workspace);
    let mut agent = agent();
    futures::executor::block_on(agent.prompt_with_tools_observed(
        &fake,
        &model(),
        "hello",
        &registry,
        &context,
        &AutoApprover,
        &mut observer,
    ))
    .expect("turn");
    drop(observer);
    let mut events = Vec::new();
    while let Some(event) = futures::executor::block_on(receiver.next()) {
        events.push(event);
    }
    assert!(events
        .iter()
        .any(|event| matches!(event, AgentEvent::TextDelta { text } if text == "hi")));
    let _ = std::fs::remove_dir_all(&workspace);
}
