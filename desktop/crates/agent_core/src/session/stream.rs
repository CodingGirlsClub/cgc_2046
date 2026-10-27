use super::*;

pub(super) enum StreamOutcome {
    Finished {
        text: String,
        thinking: String,
        usage: TokenUsage,
        stop_reason: StopReason,
        tool_calls: Vec<ToolUse>,
    },
    Steered {
        text: String,
        thinking: String,
        usage: TokenUsage,
        steer_text: String,
    },
}

pub(super) async fn run_stream(
    provider: &dyn Provider,
    model: &Model,
    request: Request,
    cancel: &CancelToken,
    observer: &mut dyn TurnObserver,
    steers: &mut mpsc::Receiver<String>,
) -> Result<StreamOutcome, AgentError> {
    let mut stream = provider.stream(model, request).await?;
    let mut text = String::new();
    let mut thinking = String::new();
    let mut usage = TokenUsage::default();
    let mut stop_reason = None;
    let mut tool_calls: Vec<ToolUse> = Vec::new();
    while let Some(event) = stream.next().await {
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
        if let Ok(steer_text) = steers.try_recv() {
            return Ok(StreamOutcome::Steered {
                text,
                thinking,
                usage,
                steer_text,
            });
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
