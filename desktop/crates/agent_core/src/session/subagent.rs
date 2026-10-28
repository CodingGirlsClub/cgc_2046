use super::*;

/// 跑一个隔离子 agent（只读工具），返回最终文本；供 `task` 工具使用。
pub async fn run_subagent(
    provider: Arc<dyn Provider>,
    model: Model,
    task: String,
    system_prompt: Option<String>,
    workspace: std::path::PathBuf,
    events: SubagentEventSink,
) -> Result<String, AgentError> {
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let serial = COUNTER.fetch_add(1, Ordering::Relaxed);
    events(SubagentEvent::Started { task: task.clone() });
    let thread = Thread::new(
        format!("subagent-{}-{serial}", std::process::id()),
        SelectedModel::new(model.provider_id.clone(), model.id.clone()),
    );
    let mut agent = Agent::new(thread, system_prompt);
    let registry = ToolRegistry::with_read_tools();
    let context = ToolContext::new(workspace);

    struct ForwardObserver {
        events: SubagentEventSink,
    }
    impl TurnObserver for ForwardObserver {
        fn on_text(&mut self, delta: &str) {
            (self.events)(SubagentEvent::TextDelta {
                text: delta.to_string(),
            });
        }
    }

    let mut observer = ForwardObserver {
        events: events.clone(),
    };
    let result = agent
        .prompt_with_tools_observed(
            provider.as_ref(),
            &model,
            task,
            &registry,
            &context,
            &AutoApprover,
            &mut observer,
        )
        .await;
    events(SubagentEvent::Finished { ok: result.is_ok() });
    result.map(|outcome| outcome.text)
}
