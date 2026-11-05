use crate::{
    sse::SseEvent, CompletionEvent, Content, ProviderError, ProviderErrorCategory, StopReason,
    TokenUsage, ToolUse,
};
use serde_json::Value;
use std::collections::BTreeMap;

struct PendingBlock {
    content: Content,
    arguments: String,
}

#[derive(Default)]
pub(super) struct StreamState {
    started: bool,
    pending: BTreeMap<usize, PendingBlock>,
    complete: BTreeMap<usize, Content>,
    usage: TokenUsage,
    stop_reason: Option<StopReason>,
}

impl StreamState {
    pub fn on_event(&mut self, event: SseEvent) -> Result<Vec<CompletionEvent>, ProviderError> {
        if event.data.trim().is_empty() {
            return Ok(Vec::new());
        }
        let event: Value = serde_json::from_str(&event.data).map_err(|error| {
            ProviderError::invalid_response(format!("Anthropic event: {error}"))
        })?;
        let mut events = Vec::new();
        match string(&event, "type")? {
            "message_start" => {
                if self.started {
                    return Err(invalid("duplicate message_start"));
                }
                let message = &event["message"];
                self.started = true;
                update_usage(&mut self.usage, &message["usage"]);
                events.push(CompletionEvent::StartMessage {
                    message_id: string(message, "id")?.into(),
                });
            }
            "content_block_start" => {
                if !self.started {
                    return Err(invalid("content block before message_start"));
                }
                let index = index(&event)?;
                if self.pending.contains_key(&index) || self.complete.contains_key(&index) {
                    return Err(invalid("duplicate content block index"));
                }
                let content = parse_content(&event["content_block"])?;
                match &content {
                    Content::Text(text) if !text.is_empty() => {
                        events.push(CompletionEvent::Text(text.clone()))
                    }
                    Content::Thinking { text, signature } => {
                        events.push(CompletionEvent::Thinking {
                            text: text.clone(),
                            signature: (!signature.is_empty()).then(|| signature.clone()),
                        })
                    }
                    _ => {}
                }
                self.pending.insert(
                    index,
                    PendingBlock {
                        content,
                        arguments: String::new(),
                    },
                );
            }
            "content_block_delta" => {
                let pending = self
                    .pending
                    .get_mut(&index(&event)?)
                    .ok_or_else(|| invalid("delta without open content block"))?;
                let delta = &event["delta"];
                match (string(delta, "type")?, &mut pending.content) {
                    ("text_delta", Content::Text(text)) => {
                        let chunk = string(delta, "text")?;
                        text.push_str(chunk);
                        events.push(CompletionEvent::Text(chunk.into()));
                    }
                    ("thinking_delta", Content::Thinking { text, .. }) => {
                        let chunk = string(delta, "thinking")?;
                        text.push_str(chunk);
                        events.push(CompletionEvent::Thinking {
                            text: chunk.into(),
                            signature: None,
                        });
                    }
                    ("signature_delta", Content::Thinking { signature, .. }) => {
                        signature.push_str(string(delta, "signature")?);
                        events.push(CompletionEvent::Thinking {
                            text: String::new(),
                            signature: Some(signature.clone()),
                        });
                    }
                    ("input_json_delta", Content::ToolUse(_)) => {
                        pending.arguments.push_str(string(delta, "partial_json")?)
                    }
                    ("citations_delta", Content::Text(_)) => {}
                    _ => return Err(invalid("delta type does not match its content block")),
                }
            }
            "content_block_stop" => {
                let index = index(&event)?;
                let mut pending = self
                    .pending
                    .remove(&index)
                    .ok_or_else(|| invalid("stop without open content block"))?;
                if let Content::ToolUse(call) = &mut pending.content {
                    if !pending.arguments.is_empty() {
                        call.args = serde_json::from_str(&pending.arguments).map_err(|error| {
                            ProviderError::invalid_response(format!(
                                "Anthropic tool arguments: {error}"
                            ))
                        })?;
                    }
                    if !call.args.is_object() {
                        return Err(invalid("tool input must be a JSON object"));
                    }
                }
                if let Content::Thinking { signature, .. } = &pending.content {
                    if signature.is_empty() {
                        return Err(invalid("thinking block ended without a signature"));
                    }
                }
                self.complete.insert(index, pending.content);
            }
            "message_delta" => {
                update_usage(&mut self.usage, &event["usage"]);
                if let Some(reason) = event["delta"]["stop_reason"].as_str() {
                    self.stop_reason = Some(match reason {
                        "end_turn" | "stop_sequence" => StopReason::EndTurn,
                        "max_tokens" | "model_context_window_exceeded" => StopReason::MaxTokens,
                        "tool_use" => StopReason::ToolUse,
                        "refusal" => StopReason::ContentFilter,
                        other => StopReason::Other(other.into()),
                    });
                }
            }
            "message_stop" => {
                if !self.started || !self.pending.is_empty() {
                    return Err(invalid("message stopped with incomplete content"));
                }
                let reason = self
                    .stop_reason
                    .take()
                    .ok_or_else(|| invalid("message stopped without a stop_reason"))?;
                for content in std::mem::take(&mut self.complete).into_values() {
                    if let Content::ToolUse(call) = &content {
                        events.push(CompletionEvent::ToolUse(call.clone()));
                    }
                    events.push(CompletionEvent::ContentBlock(content));
                }
                // Anthropic reports uncached input separately; our input includes all input
                // and cache fields remain billing diagnostics, matching OpenAI prompt_tokens.
                self.usage.input += self.usage.cache_read + self.usage.cache_creation;
                events.push(CompletionEvent::Usage(self.usage));
                events.push(CompletionEvent::Stop(reason));
            }
            "error" => {
                let error = &event["error"];
                let category = match string(error, "type")? {
                    "authentication_error" => ProviderErrorCategory::Authentication,
                    "permission_error" => ProviderErrorCategory::Permission,
                    "rate_limit_error" => ProviderErrorCategory::RateLimit,
                    "overloaded_error" | "api_error" => ProviderErrorCategory::Overloaded,
                    "invalid_request_error" => ProviderErrorCategory::InvalidRequest,
                    _ => ProviderErrorCategory::Other,
                };
                return Err(ProviderError::api_with_category(
                    category,
                    None,
                    string(error, "message")?,
                ));
            }
            _ => {} // Ping and future informational events do not alter content.
        }
        Ok(events)
    }
}

fn parse_content(value: &Value) -> Result<Content, ProviderError> {
    Ok(match string(value, "type")? {
        "text" => Content::Text(string(value, "text")?.into()),
        "thinking" => Content::Thinking {
            text: string(value, "thinking")?.into(),
            signature: value["signature"].as_str().unwrap_or_default().into(),
        },
        "redacted_thinking" => Content::RedactedThinking {
            data: string(value, "data")?.into(),
        },
        "tool_use" => Content::ToolUse(ToolUse {
            id: string(value, "id")?.into(),
            name: string(value, "name")?.into(),
            args: value
                .get("input")
                .cloned()
                .unwrap_or_else(|| serde_json::json!({})),
        }),
        _ => return Err(invalid("unsupported Anthropic content block")),
    })
}

fn update_usage(usage: &mut TokenUsage, value: &Value) {
    for (field, target) in [
        ("input_tokens", &mut usage.input),
        ("output_tokens", &mut usage.output),
        ("cache_read_input_tokens", &mut usage.cache_read),
        ("cache_creation_input_tokens", &mut usage.cache_creation),
    ] {
        if let Some(count) = value[field].as_u64() {
            *target = count;
        }
    }
}
fn index(value: &Value) -> Result<usize, ProviderError> {
    value["index"]
        .as_u64()
        .and_then(|index| usize::try_from(index).ok())
        .ok_or_else(|| invalid("missing content block index"))
}
fn string<'a>(value: &'a Value, key: &str) -> Result<&'a str, ProviderError> {
    value[key]
        .as_str()
        .ok_or_else(|| ProviderError::invalid_response(format!("missing Anthropic {key}")))
}
fn invalid(message: &str) -> ProviderError {
    ProviderError::invalid_response(message)
}
