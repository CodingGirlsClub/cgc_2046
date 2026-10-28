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
                stop_reason = Some(reason);
                break;
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
