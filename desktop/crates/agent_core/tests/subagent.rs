use std::sync::Arc;

use cgc_agent_core::run_subagent;
use cgc_agent_provider::{
    CompletionEvent, FakeProvider, Model, ModelLimits, ProviderId, StopReason,
};
use cgc_agent_tools::{SubagentEvent, SubagentEventSink};

fn model() -> Model {
    Model::new(
        ProviderId::new("fake"),
        "Fake",
        "m1",
        "m1",
        ModelLimits::new(8_000, 1_000),
    )
}

#[test]
fn subagent_runs_isolated_turn() {
    let fake = FakeProvider::new(ProviderId::new("fake"), "Fake", vec![model()]);
    fake.push_script(vec![
        Ok(CompletionEvent::Text("sub ok".into())),
        Ok(CompletionEvent::Stop(StopReason::EndTurn)),
    ]);
    let provider: Arc<dyn cgc_agent_provider::Provider> = Arc::new(fake);
    let workspace = std::env::temp_dir().join(format!("cgc-subagent-{}", std::process::id()));
    let _ = std::fs::create_dir_all(&workspace);
    let captured = Arc::new(std::sync::Mutex::new(Vec::new()));
    let events: SubagentEventSink = {
        let captured = captured.clone();
        Arc::new(move |event| captured.lock().unwrap().push(event))
    };
    let text = futures::executor::block_on(run_subagent(
        provider,
        model(),
        "do a small task".to_string(),
        Some("sub system".to_string()),
        workspace.clone(),
        events,
    ))
    .expect("subagent");
    assert_eq!(text, "sub ok");
    let captured = captured.lock().unwrap();
    assert!(captured.contains(&SubagentEvent::Started {
        task: "do a small task".to_string()
    }));
    assert!(captured.contains(&SubagentEvent::Finished { ok: true }));
    let _ = std::fs::remove_dir_all(&workspace);
}
