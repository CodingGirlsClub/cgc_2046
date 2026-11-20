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
    run_subagent_with_affinity(
        provider,
        model,
        task,
        system_prompt,
        workspace,
        events,
        None,
    )
    .await
}

/// 跑一个隔离子 agent（只读工具），可选继承父会话的 `x-session-affinity` 标识
/// （同时保持子 agent 本地 `Thread.id` 唯一），避免网关按子 agent 线程 ID 碎片化 ETS 键。
pub async fn run_subagent_with_affinity(
    provider: Arc<dyn Provider>,
    model: Model,
    task: String,
    system_prompt: Option<String>,
    workspace: std::path::PathBuf,
    events: SubagentEventSink,
    affinity_session_id: Option<String>,
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
    agent.set_affinity_session_id(affinity_session_id);
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

#[cfg(test)]
mod tests {
    use super::*;
    use cgc_agent_provider::fake::FakeProvider;
    use cgc_agent_provider::model::{ModelLimits, ProviderId};

    fn test_model() -> Model {
        Model::new(
            ProviderId::new("fake"),
            "Fake",
            "m1",
            "m1",
            ModelLimits::new(8_000, 1_000),
        )
    }

    #[test]
    fn subagent_with_affinity_inherits_parent_session_id() {
        let model = test_model();
        let provider = Arc::new(FakeProvider::new(
            ProviderId::new("fake"),
            "Fake",
            vec![model.clone()],
        ));
        provider.push_script(vec![
            Ok(CompletionEvent::Text("done".to_string())),
            Ok(CompletionEvent::Stop(StopReason::EndTurn)),
        ]);

        let text = futures::executor::block_on(run_subagent_with_affinity(
            provider.clone(),
            model,
            "inspect repo".to_string(),
            None,
            std::env::temp_dir(),
            Arc::new(|_| {}),
            Some("parent-thread-42".to_string()),
        ))
        .expect("subagent succeeds");

        assert_eq!(text, "done");
        let requests = provider.requests();
        assert_eq!(requests.len(), 1);
        assert_eq!(
            requests[0].session_id.as_deref(),
            Some("parent-thread-42"),
            "subagent request must carry parent x-session-affinity"
        );
    }

    #[test]
    fn subagent_without_affinity_uses_unique_subagent_thread_id() {
        let model = test_model();
        let provider = Arc::new(FakeProvider::new(
            ProviderId::new("fake"),
            "Fake",
            vec![model.clone()],
        ));
        provider.push_script(vec![
            Ok(CompletionEvent::Text("first".to_string())),
            Ok(CompletionEvent::Stop(StopReason::EndTurn)),
        ]);
        provider.push_script(vec![
            Ok(CompletionEvent::Text("second".to_string())),
            Ok(CompletionEvent::Stop(StopReason::EndTurn)),
        ]);

        futures::executor::block_on(run_subagent(
            provider.clone(),
            model.clone(),
            "task 1".to_string(),
            None,
            std::env::temp_dir(),
            Arc::new(|_| {}),
        ))
        .expect("first subagent");
        futures::executor::block_on(run_subagent(
            provider.clone(),
            model,
            "task 2".to_string(),
            None,
            std::env::temp_dir(),
            Arc::new(|_| {}),
        ))
        .expect("second subagent");

        let requests = provider.requests();
        assert_eq!(requests.len(), 2);
        let first_id = requests[0].session_id.as_deref().expect("first session_id");
        let second_id = requests[1]
            .session_id
            .as_deref()
            .expect("second session_id");
        assert!(first_id.starts_with("subagent-"));
        assert!(second_id.starts_with("subagent-"));
        assert_ne!(first_id, second_id);
    }
}
