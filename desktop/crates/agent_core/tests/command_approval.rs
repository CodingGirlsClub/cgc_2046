use std::sync::{
    atomic::{AtomicUsize, Ordering},
    Arc,
};

use cgc_agent_core::{Agent, ApprovalRequest, Approver, SelectedModel, Thread};
use cgc_agent_provider::{
    CompletionEvent, FakeProvider, Model, ModelId, ModelLimits, ProviderId, StopReason, ToolUse,
};
use cgc_agent_tools::{builtin::RunCommandTool, ApprovalDecision, ToolContext, ToolRegistry};
use futures::future::BoxFuture;

struct PrefixThenDeny {
    calls: AtomicUsize,
}

impl Approver for PrefixThenDeny {
    fn decide(&self, _request: ApprovalRequest) -> BoxFuture<'static, ApprovalDecision> {
        let decision = if self.calls.fetch_add(1, Ordering::SeqCst) == 0 {
            ApprovalDecision::AllowPattern("echo".to_string())
        } else {
            ApprovalDecision::Deny
        };
        Box::pin(async move { decision })
    }
}

fn assert_fresh_approval(command: &str) {
    static COUNTER: AtomicUsize = AtomicUsize::new(0);
    let workspace = std::env::temp_dir().join(format!(
        "cgc-command-approval-{}-{}",
        std::process::id(),
        COUNTER.fetch_add(1, Ordering::Relaxed)
    ));
    std::fs::create_dir_all(&workspace).unwrap();
    std::fs::write(workspace.join("input.txt"), "input").unwrap();
    let model = Model::new(
        ProviderId::new("fake"),
        "Fake",
        "m1",
        "m1",
        ModelLimits::new(8_000, 1_000),
    );
    let provider = FakeProvider::new(ProviderId::new("fake"), "Fake", vec![model.clone()]);
    for (id, command) in [("grant", "echo granted"), ("candidate", command)] {
        provider.push_script(vec![
            Ok(CompletionEvent::ToolUse(ToolUse {
                id: id.to_string(),
                name: "run_command".to_string(),
                args: serde_json::json!({"command": command}),
            })),
            Ok(CompletionEvent::Stop(StopReason::ToolUse)),
        ]);
    }
    provider.push_script(vec![Ok(CompletionEvent::Stop(StopReason::EndTurn))]);
    let mut agent = Agent::new(
        Thread::new(
            "approval-test",
            SelectedModel::new(ProviderId::new("fake"), ModelId::new("m1")),
        ),
        None,
    );
    let mut registry = ToolRegistry::new();
    registry.register(Arc::new(RunCommandTool::new()));
    let approver = PrefixThenDeny {
        calls: AtomicUsize::new(0),
    };
    let outcome = futures::executor::block_on(agent.prompt_with_tools(
        &provider,
        &model,
        "run commands",
        &registry,
        &ToolContext::new(&workspace),
        &approver,
    ))
    .expect("tool turn");

    assert_eq!(outcome.tool_results.len(), 2);
    assert!(!outcome.tool_results[0].is_error);
    assert!(outcome.tool_results[0].content.contains("granted"));
    assert_eq!(
        approver.calls.load(Ordering::SeqCst),
        2,
        "command reused a prefix grant: {command:?}"
    );
    assert!(outcome.tool_results[1].is_error, "{command:?}");
    assert_eq!(outcome.tool_results[1].content, "denied by user");
    assert!(!workspace.join("unexpected.txt").exists(), "{command:?}");
    std::fs::remove_dir_all(workspace).unwrap();
}

#[test]
fn prefix_grant_requires_fresh_approval_for_compound_commands() {
    for command in [
        "echo listed && echo bypass > unexpected.txt",
        "echo listed; echo bypass > unexpected.txt",
        "echo listed || echo bypass > unexpected.txt",
        "echo listed | echo bypass > unexpected.txt",
        "echo listed & echo bypass > unexpected.txt",
        "echo listed\necho bypass > unexpected.txt",
        "echo listed\r\necho bypass > unexpected.txt",
    ] {
        assert_fresh_approval(command);
    }
}

#[test]
fn prefix_grant_requires_fresh_approval_for_expansions_and_redirections() {
    for command in [
        "echo $(echo bypass > unexpected.txt)",
        "echo `echo bypass > unexpected.txt`",
        "echo harmless > unexpected.txt",
        "echo harmless 2> unexpected.txt",
        "echo harmless < input.txt",
        "echo %CGC_APPROVAL_PAYLOAD%",
        "echo !CGC_APPROVAL_PAYLOAD!",
        "echo ^& echo bypass > unexpected.txt",
        "echo \"quoted argument\"",
        "echo harmless\\\necho bypass > unexpected.txt",
    ] {
        assert_fresh_approval(command);
    }
}

#[test]
fn command_prefix_grants_end_at_argument_boundaries() {
    for command in ["echo-other", "echo/other", "echo:other"] {
        assert_fresh_approval(command);
    }
}
