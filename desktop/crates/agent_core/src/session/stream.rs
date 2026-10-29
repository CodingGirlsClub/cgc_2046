use super::*;

pub(super) enum StreamOutcome {
    Finished {
        text: String,
        thinking: String,
        usage: TokenUsage,
        stop_reason: StopReason,
        tool_calls: Vec<ToolUse>,
    },
}

pub(super) async fn run_stream(
    provider: &dyn Provider,
    model: &Model,
    request: Request,
    cancel: &CancelToken,
    observer: &mut dyn TurnObserver,
) -> Result<StreamOutcome, AgentError> {
    let mut stream = provider.stream(model, request).await?;
    let mut text = String::new();
    let mut thinking = String::new();
    let mut usage = TokenUsage::default();
    let mut stop_reason = None;
    let mut tool_calls: Vec<ToolUse> = Vec::new();
    // 与取消竞争：模型沉默期间也能立刻收尾，而不是等下一个事件。
    let mut cancelled = std::pin::pin!(cancel.cancelled());
    loop {
        let event = match futures::future::select(stream.next(), cancelled.as_mut()).await {
            futures::future::Either::Left((event, _)) => event,
            futures::future::Either::Right(_) => return Err(AgentError::Cancelled),
        };
        let Some(event) = event else { break };
        if cancel.is_cancelled() {
            return Err(AgentError::Cancelled);
        }
        match event? {
            CompletionEvent::StartMessage { .. } => {}
            CompletionEvent::Text(chunk) => {
                observer.on_text(&chunk);
                text.push_str(&chunk);
            }
            CompletionEvent::Thinking { text: chunk, .. } => {
                observer.on_thinking(&chunk);
                thinking.push_str(&chunk);
            }
            CompletionEvent::ToolUse(tool_use) => tool_calls.push(tool_use),
            CompletionEvent::Usage(delta) => usage.add(delta),
            CompletionEvent::Stop(reason) => {
                // 记录结束原因但**不 break**：OpenAI 兼容端点会在 finish_reason 之后
                // 再补一个只带 usage 的尾块（`include_usage` 时如此）。提前跳出会丢掉
                // usage，上下文用量与 observed-token 修正都会失准。流随后自然结束。
                if stop_reason.is_none() {
                    stop_reason = Some(reason);
                }
            }
        }
    }
    Ok(StreamOutcome::Finished {
        text,
        thinking,
        usage,
        stop_reason: stop_reason.unwrap_or_else(|| StopReason::Other("stream ended".to_string())),
        tool_calls,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use cgc_agent_provider::fake::FakeProvider;
    use cgc_agent_provider::model::ModelLimits;
    use cgc_agent_provider::Message;

    fn model() -> Model {
        Model::new(
            cgc_agent_provider::model::ProviderId::new("fake"),
            "Fake",
            "m1",
            "m1",
            ModelLimits::new(8_000, 1_000),
        )
    }

    fn provider() -> FakeProvider {
        FakeProvider::new(
            cgc_agent_provider::model::ProviderId::new("fake"),
            "Fake",
            vec![model()],
        )
    }

    #[test]
    fn trailing_usage_after_stop_is_recorded() {
        let provider = provider();
        provider.push_script(vec![
            Ok(CompletionEvent::Text("hi".to_string())),
            Ok(CompletionEvent::Stop(StopReason::EndTurn)),
            Ok(CompletionEvent::Usage(TokenUsage {
                input: 11,
                output: 7,
                cache_read: 3,
                cache_creation: 0,
            })),
        ]);
        let cancel = CancelToken::default();
        let mut observer = NoopObserver;

        let outcome = futures::executor::block_on(run_stream(
            &provider,
            &model(),
            Request::new(vec![Message::user("hi")]),
            &cancel,
            &mut observer,
        ))
        .expect("stream");

        match outcome {
            StreamOutcome::Finished {
                text,
                usage,
                stop_reason,
                ..
            } => {
                assert_eq!(text, "hi");
                assert_eq!(stop_reason, StopReason::EndTurn);
                // finish_reason 之后的尾块 usage 必须记下来。
                assert_eq!(usage.input, 11);
                assert_eq!(usage.output, 7);
                assert_eq!(usage.cache_read, 3);
            }
        }
    }
}
