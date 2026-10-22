use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};

use cgc_agent_provider::{
    CompletionEvent, Message, Model, Provider, ProviderError, Request, StopReason, TokenUsage,
    ToolUse,
};
use futures::StreamExt;

use crate::thread::{now_secs, Entry, Thread};

/// 取消句柄：UI 点击停止时调用 `cancel()`；Agent 在每个事件边界检查。
#[derive(Clone, Debug, Default)]
pub struct CancelToken {
    flag: Arc<AtomicBool>,
}

impl CancelToken {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn cancel(&self) {
        self.flag.store(true, Ordering::SeqCst);
    }

    pub fn reset(&self) {
        self.flag.store(false, Ordering::SeqCst);
    }

    pub fn is_cancelled(&self) -> bool {
        self.flag.load(Ordering::SeqCst)
    }
}

/// 一轮对话的结果。
#[derive(Clone, Debug, PartialEq)]
pub struct TurnOutcome {
    pub text: String,
    pub usage: TokenUsage,
    pub stop_reason: StopReason,
    pub tool_calls: Vec<ToolUse>,
}

#[derive(Debug, thiserror::Error)]
pub enum AgentError {
    #[error("provider error: {0}")]
    Provider(#[from] ProviderError),
    #[error("cancelled")]
    Cancelled,
    #[error("selected model does not match the model being used")]
    ModelMismatch,
}

/// 一个 native agent 会话。P1a 先内存态。
pub struct Agent {
    thread: Thread,
    system_prompt: Option<String>,
    cancel: CancelToken,
}

impl Agent {
    pub fn new(thread: Thread, system_prompt: Option<String>) -> Self {
        Self {
            thread,
            system_prompt,
            cancel: CancelToken::new(),
        }
    }

    pub fn thread(&self) -> &Thread {
        &self.thread
    }

    pub fn thread_mut(&mut self) -> &mut Thread {
        &mut self.thread
    }

    pub fn cancel_token(&self) -> CancelToken {
        self.cancel.clone()
    }

    /// 跑一轮：追加用户消息 → 调 provider → 收集文本/用量/工具调用 → 落线程。
    pub async fn prompt(
        &mut self,
        provider: &dyn Provider,
        model: &Model,
        text: impl Into<String>,
    ) -> Result<TurnOutcome, AgentError> {
        if self.cancel.is_cancelled() {
            return Err(AgentError::Cancelled);
        }
        if provider.id() != &model.provider_id || !self.thread.model.matches(model) {
            return Err(AgentError::ModelMismatch);
        }

        self.thread.push_user(text);

        let mut messages = Vec::new();
        if let Some(system_prompt) = &self.system_prompt {
            messages.push(Message::system(system_prompt.clone()));
        }
        messages.extend(self.thread.messages());
        let request = Request::new(messages);

        let mut stream = provider.stream(model, request).await?;
        let mut text = String::new();
        let mut usage = TokenUsage::default();
        let mut stop_reason = None;
        let mut tool_calls: Vec<ToolUse> = Vec::new();

        while let Some(event) = stream.next().await {
            if self.cancel.is_cancelled() {
                return Err(self.finish_cancelled(text, usage));
            }
            match event? {
                CompletionEvent::StartMessage { .. } => {}
                CompletionEvent::Text(chunk) => text.push_str(&chunk),
                CompletionEvent::Thinking { .. } => {}
                CompletionEvent::ToolUse(tool_use) => tool_calls.push(tool_use),
                CompletionEvent::Usage(delta) => usage.add(delta),
                CompletionEvent::Stop(reason) => {
                    stop_reason = Some(reason);
                    break;
                }
            }
        }

        if self.cancel.is_cancelled() {
            return Err(self.finish_cancelled(text, usage));
        }

        let stop_reason =
            stop_reason.unwrap_or_else(|| StopReason::Other("stream ended".to_string()));
        let usage_for_entry = if usage == TokenUsage::default() {
            None
        } else {
            Some(usage)
        };
        self.thread.usage_total.add(usage);
        self.thread.push_assistant(text.clone(), usage_for_entry);
        for tool_use in &tool_calls {
            self.thread.entries.push(Entry::ToolCall {
                id: tool_use.id.clone(),
                name: tool_use.name.clone(),
                args: tool_use.args.clone(),
                at: now_secs(),
            });
        }

        Ok(TurnOutcome {
            text,
            usage,
            stop_reason,
            tool_calls,
        })
    }

    /// 取消时保留已生成的部分文本与用量，再返回取消错误。
    fn finish_cancelled(&mut self, text: String, usage: TokenUsage) -> AgentError {
        if !text.is_empty() {
            self.thread.push_assistant(
                text,
                if usage == TokenUsage::default() {
                    None
                } else {
                    Some(usage)
                },
            );
        }
        self.thread.usage_total.add(usage);
        AgentError::Cancelled
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use cgc_agent_provider::{
        FakeProvider, ModelId, ModelLimits, ProviderId, StopReason, TokenUsage, ToolUse,
    };

    use super::*;
    use crate::thread::{SelectedModel, Thread};

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
        let thread = Thread::new(
            "t1",
            SelectedModel::new(ProviderId::new("fake"), ModelId::new("m1")),
        );
        Agent::new(thread, Some("be kind".to_string()))
    }

    fn fake_with_script(script: Vec<Result<CompletionEvent, ProviderError>>) -> FakeProvider {
        let fake = FakeProvider::new(ProviderId::new("fake"), "Fake", vec![model()]);
        fake.push_script(script);
        fake
    }

    #[test]
    fn prompt_appends_entries_and_accumulates_usage() {
        let fake = fake_with_script(vec![
            Ok(CompletionEvent::Text("hel".into())),
            Ok(CompletionEvent::Text("lo".into())),
            Ok(CompletionEvent::Usage(TokenUsage {
                input: 10,
                output: 2,
                ..TokenUsage::default()
            })),
            Ok(CompletionEvent::Stop(StopReason::EndTurn)),
        ]);
        let mut agent = agent();
        let outcome =
            futures::executor::block_on(agent.prompt(&fake, &model(), "hi")).expect("turn");
        assert_eq!(outcome.text, "hello");
        assert_eq!(outcome.usage.input, 10);
        assert_eq!(outcome.stop_reason, StopReason::EndTurn);
        assert_eq!(agent.thread().entries.len(), 2);
        assert_eq!(agent.thread().usage_total.input, 10);
        assert_eq!(fake.requests().len(), 1);
        assert_eq!(fake.requests()[0].messages.len(), 2);
        assert_eq!(fake.requests()[0].messages[0].text(), "be kind");
    }

    #[test]
    fn second_turn_includes_history() {
        let fake = fake_with_script(vec![
            Ok(CompletionEvent::Text("one".into())),
            Ok(CompletionEvent::Stop(StopReason::EndTurn)),
        ]);
        fake.push_script(vec![
            Ok(CompletionEvent::Text("two".into())),
            Ok(CompletionEvent::Stop(StopReason::EndTurn)),
        ]);
        let mut agent = agent();
        futures::executor::block_on(agent.prompt(&fake, &model(), "first")).expect("turn 1");
        futures::executor::block_on(agent.prompt(&fake, &model(), "second")).expect("turn 2");
        let requests = fake.requests();
        assert_eq!(requests.len(), 2);
        assert_eq!(requests[1].messages.len(), 4);
        assert_eq!(requests[1].messages[3].text(), "second");
    }

    #[test]
    fn model_mismatch_is_rejected() {
        let fake = FakeProvider::new(ProviderId::new("fake"), "Fake", vec![model()]);
        let mut agent = agent();
        let other = Model::new(
            ProviderId::new("fake"),
            "Fake",
            "m2",
            "m2",
            ModelLimits::new(8_000, 1_000),
        );
        let error = futures::executor::block_on(agent.prompt(&fake, &other, "hi")).unwrap_err();
        assert!(matches!(error, AgentError::ModelMismatch));
        assert!(agent.thread().entries.is_empty());
    }

    #[test]
    fn cancel_before_turn_is_rejected() {
        let fake = FakeProvider::new(ProviderId::new("fake"), "Fake", vec![model()]);
        let mut agent = agent();
        agent.cancel_token().cancel();
        let error = futures::executor::block_on(agent.prompt(&fake, &model(), "hi")).unwrap_err();
        assert!(matches!(error, AgentError::Cancelled));
        assert!(agent.thread().entries.is_empty());
    }

    #[test]
    fn tool_calls_are_recorded_and_returned() {
        let fake = fake_with_script(vec![
            Ok(CompletionEvent::ToolUse(ToolUse {
                id: "call_1".into(),
                name: "read_file".into(),
                args: serde_json::json!({"path": "a.txt"}),
            })),
            Ok(CompletionEvent::Stop(StopReason::ToolUse)),
        ]);
        let mut agent = agent();
        let outcome =
            futures::executor::block_on(agent.prompt(&fake, &model(), "read it")).expect("turn");
        assert_eq!(outcome.stop_reason, StopReason::ToolUse);
        assert_eq!(outcome.tool_calls.len(), 1);
        assert!(agent
            .thread()
            .entries
            .iter()
            .any(|entry| matches!(entry, Entry::ToolCall { name, .. } if name == "read_file")));
    }

    #[test]
    fn default_fake_script_returns_ok() {
        let fake = FakeProvider::new(ProviderId::new("fake"), "Fake", vec![model()]);
        let mut agent = agent();
        let outcome =
            futures::executor::block_on(agent.prompt(&fake, &model(), "hi")).expect("turn");
        assert_eq!(outcome.text, "ok");
        assert_eq!(outcome.stop_reason, StopReason::EndTurn);
    }

    #[test]
    fn provider_errors_flow_through() {
        let fake = fake_with_script(vec![Err(ProviderError::api(429, "slow down"))]);
        let mut agent = agent();
        let error = futures::executor::block_on(agent.prompt(&fake, &model(), "hi")).unwrap_err();
        assert!(matches!(error, AgentError::Provider(error) if error.is_retryable()));
    }

    #[test]
    fn cancel_token_is_shareable() {
        let agent = agent();
        let token = agent.cancel_token();
        assert!(!token.is_cancelled());
        token.cancel();
        assert!(token.is_cancelled());
    }

    #[test]
    fn thread_usage_accumulates_across_turns() {
        let fake = fake_with_script(vec![
            Ok(CompletionEvent::Usage(TokenUsage {
                input: 4,
                output: 1,
                ..TokenUsage::default()
            })),
            Ok(CompletionEvent::Stop(StopReason::EndTurn)),
        ]);
        let mut agent = agent();
        futures::executor::block_on(agent.prompt(&fake, &model(), "hi")).expect("turn");
        assert_eq!(agent.thread().usage_total.input, 4);
    }

    #[test]
    fn arc_provider_object_works() {
        let fake: Arc<dyn Provider> = Arc::new(FakeProvider::new(
            ProviderId::new("fake"),
            "Fake",
            vec![model()],
        ));
        let mut agent = agent();
        let outcome =
            futures::executor::block_on(agent.prompt(fake.as_ref(), &model(), "hi")).expect("turn");
        assert_eq!(outcome.text, "ok");
    }
}
