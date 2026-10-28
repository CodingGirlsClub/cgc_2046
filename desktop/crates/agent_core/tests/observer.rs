use std::sync::Arc;

use cgc_agent_core::{Agent, AutoApprover, TurnObserver};
use cgc_agent_provider::{
    CompletionEvent, FakeProvider, Model, ModelId, ModelLimits, ProviderError, ProviderId,
    StopReason, ToolUse,
};
use cgc_agent_tools::{Approval, Tool, ToolContext, ToolRegistry, ToolResult};
use futures::future::BoxFuture;

struct Recorder {
    events: Vec<String>,
}

impl Recorder {
    fn new() -> Self {
        Self { events: Vec::new() }
    }
}

impl TurnObserver for Recorder {
    fn on_turn_started(&mut self, thread_id: &str) {
        self.events.push(format!("turn_started:{thread_id}"));
    }

    fn on_text(&mut self, delta: &str) {
        self.events.push(format!("text:{delta}"));
    }

    fn on_tool_call(&mut self, tool_use: &ToolUse) {
        self.events.push(format!("tool_call:{}", tool_use.name));
    }

    fn on_permission_request(&mut self, request: &cgc_agent_core::ApprovalRequest) {
        self.events
            .push(format!("permission:{}", request.tool_name));
    }

    fn on_tool_result(&mut self, summary: &cgc_agent_core::ToolResultSummary) {
        self.events.push(format!(
            "tool_result:{}:{}",
            summary.tool_name, summary.is_error
        ));
    }

    fn on_usage(
        &mut self,
        usage: cgc_agent_provider::TokenUsage,
        _total: cgc_agent_provider::TokenUsage,
    ) {
        self.events.push(format!("usage:{}", usage.total()));
    }

    fn on_finished(&mut self, _outcome: &cgc_agent_core::ToolTurnOutcome) {
        self.events.push("finished".to_string());
    }
}

struct AskTool;

impl Tool for AskTool {
    fn name(&self) -> &'static str {
        "ask_tool"
    }

    fn description(&self) -> &'static str {
        "needs approval"
    }

    fn schema(&self) -> serde_json::Value {
        serde_json::json!({"type": "object"})
    }

    fn approval(&self, _args: &serde_json::Value) -> Approval {
        Approval::Ask
    }

    fn run(
        &self,
        _args: serde_json::Value,
        _context: ToolContext,
    ) -> BoxFuture<'static, Result<ToolResult, cgc_agent_tools::ToolError>> {
        Box::pin(async { Ok(ToolResult::ok("ran")) })
    }
}

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
fn text_turn_emits_start_text_usage_and_finished() {
    let fake = fake(vec![
        Ok(CompletionEvent::Text("hi".into())),
        Ok(CompletionEvent::Usage(cgc_agent_provider::TokenUsage {
            input: 3,
            output: 1,
            ..Default::default()
        })),
        Ok(CompletionEvent::Stop(StopReason::EndTurn)),
    ]);
    let workspace = std::env::temp_dir().join(format!("cgc-observer-{}", std::process::id()));
    let _ = std::fs::create_dir_all(&workspace);
    let registry = ToolRegistry::with_read_tools();
    let context = ToolContext::new(&workspace);
    let mut recorder = Recorder::new();
    let mut agent = agent();
    futures::executor::block_on(agent.prompt_with_tools_observed(
        &fake,
        &model(),
        "hello",
        &registry,
        &context,
        &AutoApprover,
        &mut recorder,
    ))
    .expect("turn");
    assert_eq!(
        recorder.events.first().map(String::as_str),
        Some("turn_started:t1")
    );
    assert!(recorder.events.contains(&"text:hi".to_string()));
    assert!(recorder.events.iter().any(|event| event == "usage:4"));
    assert_eq!(recorder.events.last().map(String::as_str), Some("finished"));
    let _ = std::fs::remove_dir_all(&workspace);
}

#[test]
fn approval_flow_emits_permission_and_tool_events() {
    let fake = FakeProvider::new(ProviderId::new("fake"), "Fake", vec![model()]);
    fake.push_script(vec![
        Ok(CompletionEvent::ToolUse(ToolUse {
            id: "call_1".into(),
            name: "ask_tool".into(),
            args: serde_json::json!({}),
        })),
        Ok(CompletionEvent::Stop(StopReason::ToolUse)),
    ]);
    fake.push_script(vec![
        Ok(CompletionEvent::Text("done".into())),
        Ok(CompletionEvent::Stop(StopReason::EndTurn)),
    ]);
    let workspace = std::env::temp_dir().join(format!("cgc-observer-ask-{}", std::process::id()));
    let _ = std::fs::create_dir_all(&workspace);
    let mut registry = ToolRegistry::new();
    registry.register(Arc::new(AskTool));
    let context = ToolContext::new(&workspace);
    let mut recorder = Recorder::new();
    let mut agent = agent();
    futures::executor::block_on(agent.prompt_with_tools_observed(
        &fake,
        &model(),
        "run",
        &registry,
        &context,
        &AutoApprover,
        &mut recorder,
    ))
    .expect("turn");
    assert!(recorder.events.contains(&"tool_call:ask_tool".to_string()));
    assert!(recorder.events.contains(&"permission:ask_tool".to_string()));
    assert!(recorder
        .events
        .contains(&"tool_result:ask_tool:false".to_string()));
    let _ = std::fs::remove_dir_all(&workspace);
}
