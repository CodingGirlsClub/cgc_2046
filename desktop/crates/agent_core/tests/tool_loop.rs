use std::sync::{
    atomic::{AtomicUsize, Ordering},
    Arc,
};

use cgc_agent_core::{
    Agent, AgentError, ApprovalRequest, Approver, AutoApprover, DenyApprover, MAX_TOOL_STEPS,
};
use cgc_agent_provider::{
    CompletionEvent, FakeProvider, Model, ModelId, ModelLimits, ProviderError, ProviderId,
    StopReason, ToolUse,
};
use cgc_agent_tools::{Approval, ApprovalDecision, Tool, ToolContext, ToolRegistry, ToolResult};
use futures::future::BoxFuture;

struct AskTool;

impl Tool for AskTool {
    fn name(&self) -> &'static str {
        "ask_tool"
    }

    fn description(&self) -> &'static str {
        "test tool that needs approval"
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

struct DenyTool;

impl Tool for DenyTool {
    fn name(&self) -> &'static str {
        "deny_tool"
    }

    fn description(&self) -> &'static str {
        "test tool denied by policy"
    }

    fn schema(&self) -> serde_json::Value {
        serde_json::json!({"type": "object"})
    }

    fn approval(&self, _args: &serde_json::Value) -> Approval {
        Approval::Deny("blocked by policy".to_string())
    }

    fn run(
        &self,
        _args: serde_json::Value,
        _context: ToolContext,
    ) -> BoxFuture<'static, Result<ToolResult, cgc_agent_tools::ToolError>> {
        Box::pin(async { Ok(ToolResult::ok("should not run")) })
    }
}

struct CountingApprover {
    calls: Arc<AtomicUsize>,
    decision: ApprovalDecision,
}

impl Approver for CountingApprover {
    fn decide(&self, _request: ApprovalRequest) -> BoxFuture<'static, ApprovalDecision> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        let decision = self.decision.clone();
        Box::pin(async move { decision })
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

fn temp_workspace(tag: &str) -> std::path::PathBuf {
    use std::sync::atomic::AtomicU64;
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let serial = COUNTER.fetch_add(1, Ordering::Relaxed);
    let dir = std::env::temp_dir().join(format!(
        "cgc-agent-core-{}-{tag}-{serial}",
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("workspace");
    dir
}

fn tool_use(
    id: &str,
    name: &str,
    args: serde_json::Value,
) -> Result<CompletionEvent, ProviderError> {
    Ok(CompletionEvent::ToolUse(ToolUse {
        id: id.to_string(),
        name: name.to_string(),
        args,
    }))
}

fn fake(scripts: Vec<Vec<Result<CompletionEvent, ProviderError>>>) -> FakeProvider {
    let fake = FakeProvider::new(ProviderId::new("fake"), "Fake", vec![model()]);
    for script in scripts {
        fake.push_script(script);
    }
    fake
}

#[test]
fn auto_approved_tool_loop_executes_and_feeds_result_back() {
    let workspace = temp_workspace("read");
    std::fs::write(workspace.join("a.txt"), "hello").expect("write");
    let fake = fake(vec![
        vec![
            tool_use("call_1", "read_file", serde_json::json!({"path": "a.txt"})),
            Ok(CompletionEvent::Stop(StopReason::ToolUse)),
        ],
        vec![
            Ok(CompletionEvent::Text("done".into())),
            Ok(CompletionEvent::Stop(StopReason::EndTurn)),
        ],
    ]);
    let registry = ToolRegistry::with_read_tools();
    let context = ToolContext::new(&workspace);
    let mut agent = agent();
    let outcome = futures::executor::block_on(agent.prompt_with_tools(
        &fake,
        &model(),
        "read it",
        &registry,
        &context,
        &AutoApprover,
    ))
    .expect("turn");
    assert_eq!(outcome.text, "done");
    assert_eq!(outcome.stop_reason, StopReason::EndTurn);
    assert_eq!(outcome.tool_results.len(), 1);
    assert!(!outcome.tool_results[0].is_error);
    assert!(outcome.tool_results[0].content.ends_with("hello"));
    let requests = fake.requests();
    assert_eq!(requests.len(), 2);
    assert_eq!(requests[1].messages.len(), 3);
    assert_eq!(requests[1].messages[2].role, cgc_agent_provider::Role::Tool);
    let _ = std::fs::remove_dir_all(&workspace);
}

#[test]
fn denied_tool_returns_error_result_and_loop_continues() {
    let fake = fake(vec![
        vec![
            tool_use("call_1", "ask_tool", serde_json::json!({})),
            Ok(CompletionEvent::Stop(StopReason::ToolUse)),
        ],
        vec![
            Ok(CompletionEvent::Text("fine".into())),
            Ok(CompletionEvent::Stop(StopReason::EndTurn)),
        ],
    ]);
    let mut registry = ToolRegistry::new();
    registry.register(Arc::new(AskTool));
    let workspace = temp_workspace("deny");
    let mut agent = agent();
    let outcome = futures::executor::block_on(agent.prompt_with_tools(
        &fake,
        &model(),
        "run it",
        &registry,
        &ToolContext::new(&workspace),
        &DenyApprover,
    ))
    .expect("turn");
    assert_eq!(outcome.text, "fine");
    assert!(outcome.tool_results[0].is_error);
    assert!(outcome.tool_results[0].content.contains("denied by user"));
    let _ = std::fs::remove_dir_all(&workspace);
}

#[test]
fn allow_for_session_caches_grants() {
    let calls = Arc::new(AtomicUsize::new(0));
    let approver = CountingApprover {
        calls: calls.clone(),
        decision: ApprovalDecision::AllowForSession,
    };
    let fake = fake(vec![
        vec![
            tool_use("call_1", "ask_tool", serde_json::json!({})),
            Ok(CompletionEvent::Stop(StopReason::ToolUse)),
        ],
        vec![
            tool_use("call_2", "ask_tool", serde_json::json!({})),
            Ok(CompletionEvent::Stop(StopReason::ToolUse)),
        ],
        vec![
            Ok(CompletionEvent::Text("all done".into())),
            Ok(CompletionEvent::Stop(StopReason::EndTurn)),
        ],
    ]);
    let mut registry = ToolRegistry::new();
    registry.register(Arc::new(AskTool));
    let workspace = temp_workspace("grant");
    let mut agent = agent();
    let outcome = futures::executor::block_on(agent.prompt_with_tools(
        &fake,
        &model(),
        "run twice",
        &registry,
        &ToolContext::new(&workspace),
        &approver,
    ))
    .expect("turn");
    assert_eq!(outcome.text, "all done");
    assert_eq!(calls.load(Ordering::SeqCst), 1);
    assert_eq!(outcome.tool_results.len(), 2);
    let _ = std::fs::remove_dir_all(&workspace);
}

#[test]
fn policy_denial_does_not_call_approver() {
    let calls = Arc::new(AtomicUsize::new(0));
    let approver = CountingApprover {
        calls: calls.clone(),
        decision: ApprovalDecision::AllowOnce,
    };
    let fake = fake(vec![
        vec![
            tool_use("call_1", "deny_tool", serde_json::json!({})),
            Ok(CompletionEvent::Stop(StopReason::ToolUse)),
        ],
        vec![
            Ok(CompletionEvent::Text("ok".into())),
            Ok(CompletionEvent::Stop(StopReason::EndTurn)),
        ],
    ]);
    let mut registry = ToolRegistry::new();
    registry.register(Arc::new(DenyTool));
    let workspace = temp_workspace("policy");
    let mut agent = agent();
    let outcome = futures::executor::block_on(agent.prompt_with_tools(
        &fake,
        &model(),
        "try",
        &registry,
        &ToolContext::new(&workspace),
        &approver,
    ))
    .expect("turn");
    assert!(outcome.tool_results[0].is_error);
    assert!(outcome.tool_results[0].content.contains("denied by policy"));
    assert_eq!(calls.load(Ordering::SeqCst), 0);
    let _ = std::fs::remove_dir_all(&workspace);
}

#[test]
fn tool_loop_stops_at_step_limit() {
    let fake = FakeProvider::new(ProviderId::new("fake"), "Fake", vec![model()]);
    for index in 0..MAX_TOOL_STEPS + 2 {
        fake.push_script(vec![
            tool_use(&format!("call_{index}"), "ask_tool", serde_json::json!({})),
            Ok(CompletionEvent::Stop(StopReason::ToolUse)),
        ]);
    }
    let mut registry = ToolRegistry::new();
    registry.register(Arc::new(AskTool));
    let workspace = temp_workspace("limit");
    let mut agent = agent();
    let error = futures::executor::block_on(agent.prompt_with_tools(
        &fake,
        &model(),
        "loop",
        &registry,
        &ToolContext::new(&workspace),
        &AutoApprover,
    ))
    .unwrap_err();
    assert!(matches!(error, AgentError::StepLimitExceeded));
    assert_eq!(fake.requests().len(), MAX_TOOL_STEPS);
    let _ = std::fs::remove_dir_all(&workspace);
}

#[test]
fn unknown_tool_returns_error_result() {
    let fake = fake(vec![
        vec![
            tool_use("call_1", "nope", serde_json::json!({})),
            Ok(CompletionEvent::Stop(StopReason::ToolUse)),
        ],
        vec![
            Ok(CompletionEvent::Text("ok".into())),
            Ok(CompletionEvent::Stop(StopReason::EndTurn)),
        ],
    ]);
    let workspace = temp_workspace("unknown");
    let mut agent = agent();
    let outcome = futures::executor::block_on(agent.prompt_with_tools(
        &fake,
        &model(),
        "nope",
        &ToolRegistry::new(),
        &ToolContext::new(&workspace),
        &AutoApprover,
    ))
    .expect("turn");
    assert!(outcome.tool_results[0].is_error);
    assert!(outcome.tool_results[0].content.contains("unknown tool"));
    let _ = std::fs::remove_dir_all(&workspace);
}

#[test]
fn write_tool_asks_then_writes() {
    let calls = Arc::new(AtomicUsize::new(0));
    let approver = CountingApprover {
        calls: calls.clone(),
        decision: ApprovalDecision::AllowOnce,
    };
    let fake = fake(vec![
        vec![
            tool_use(
                "call_1",
                "write_file",
                serde_json::json!({"path": "out.txt", "content": "written"}),
            ),
            Ok(CompletionEvent::Stop(StopReason::ToolUse)),
        ],
        vec![
            Ok(CompletionEvent::Text("done".into())),
            Ok(CompletionEvent::Stop(StopReason::EndTurn)),
        ],
    ]);
    let registry = ToolRegistry::with_builtin_tools();
    let workspace = temp_workspace("write");
    let mut agent = agent();
    let outcome = futures::executor::block_on(agent.prompt_with_tools(
        &fake,
        &model(),
        "write it",
        &registry,
        &ToolContext::new(&workspace),
        &approver,
    ))
    .expect("turn");
    assert_eq!(calls.load(Ordering::SeqCst), 1);
    assert!(!outcome.tool_results[0].is_error);
    assert_eq!(
        std::fs::read_to_string(workspace.join("out.txt")).unwrap(),
        "written"
    );
    let _ = std::fs::remove_dir_all(&workspace);
}

#[test]
fn allow_pattern_auto_approves_matching_commands() {
    let calls = Arc::new(AtomicUsize::new(0));
    let approver = CountingApprover {
        calls: calls.clone(),
        decision: ApprovalDecision::AllowPattern("echo".to_string()),
    };
    let fake = fake(vec![
        vec![
            tool_use(
                "call_1",
                "run_command",
                serde_json::json!({"command": "echo one"}),
            ),
            Ok(CompletionEvent::Stop(StopReason::ToolUse)),
        ],
        vec![
            tool_use(
                "call_2",
                "run_command",
                serde_json::json!({"command": "echo two"}),
            ),
            Ok(CompletionEvent::Stop(StopReason::ToolUse)),
        ],
        vec![
            Ok(CompletionEvent::Text("done".into())),
            Ok(CompletionEvent::Stop(StopReason::EndTurn)),
        ],
    ]);
    let mut registry = ToolRegistry::new();
    registry.register(Arc::new(cgc_agent_tools::builtin::RunCommandTool::new()));
    let workspace = temp_workspace("pattern");
    let mut agent = agent();
    let outcome = futures::executor::block_on(agent.prompt_with_tools(
        &fake,
        &model(),
        "run twice",
        &registry,
        &ToolContext::new(&workspace),
        &approver,
    ))
    .expect("turn");
    assert_eq!(outcome.text, "done");
    assert_eq!(
        calls.load(Ordering::SeqCst),
        1,
        "second matching command must be auto-approved"
    );
    assert_eq!(outcome.tool_results.len(), 2);
    assert!(!outcome.tool_results[0].is_error);
    assert!(!outcome.tool_results[1].is_error);
    let _ = std::fs::remove_dir_all(&workspace);
}
