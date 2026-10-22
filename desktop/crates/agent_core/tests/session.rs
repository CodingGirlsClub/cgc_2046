use cgc_agent_core::{Agent, AgentError};
use cgc_agent_provider::{
    CompletionEvent, FakeProvider, Model, ModelId, ModelLimits, ProviderError, ProviderId,
    StopReason,
};

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

fn fake(script: Vec<Result<CompletionEvent, ProviderError>>) -> FakeProvider {
    let fake = FakeProvider::new(ProviderId::new("fake"), "Fake", vec![model()]);
    fake.push_script(script);
    fake
}

#[test]
fn text_prompt_records_turn_and_usage() {
    let fake = fake(vec![
        Ok(CompletionEvent::Text("hi".into())),
        Ok(CompletionEvent::Stop(StopReason::EndTurn)),
    ]);
    let mut agent = agent();
    let outcome =
        futures::executor::block_on(agent.prompt(&fake, &model(), "hello")).expect("turn");
    assert_eq!(outcome.text, "hi");
    assert_eq!(agent.thread().entries.len(), 2);
    assert_eq!(
        agent.thread().usage_total,
        cgc_agent_provider::TokenUsage::default()
    );
}

#[test]
fn cancelled_agent_rejects_prompt() {
    let fake = fake(vec![Ok(CompletionEvent::Stop(StopReason::EndTurn))]);
    let mut agent = agent();
    agent.cancel_token().cancel();
    let error = futures::executor::block_on(agent.prompt(&fake, &model(), "hello")).unwrap_err();
    assert!(matches!(error, AgentError::Cancelled));
}

#[test]
fn provider_error_is_surfaced() {
    let fake = fake(vec![Err(ProviderError::api(429, "busy"))]);
    let mut agent = agent();
    let error = futures::executor::block_on(agent.prompt(&fake, &model(), "hello")).unwrap_err();
    assert!(matches!(error, AgentError::Provider(error) if error.is_retryable()));
}

#[test]
fn no_tools_prompt_still_records_tool_calls() {
    let fake = fake(vec![
        Ok(CompletionEvent::ToolUse(cgc_agent_provider::ToolUse {
            id: "call_1".into(),
            name: "read_file".into(),
            args: serde_json::json!({}),
        })),
        Ok(CompletionEvent::Stop(StopReason::ToolUse)),
    ]);
    let mut agent = agent();
    let outcome = futures::executor::block_on(agent.prompt(&fake, &model(), "read")).expect("turn");
    assert_eq!(outcome.stop_reason, StopReason::ToolUse);
    assert_eq!(agent.thread().entries.len(), 2);
}
