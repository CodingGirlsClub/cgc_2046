use crate::{Content, Model, ProviderError, ProviderErrorCategory, Request, Role, ThinkingMode};
use serde_json::{json, Value};

pub(super) fn build_body(model: &Model, request: &Request) -> Result<Value, ProviderError> {
    let max_tokens = request
        .max_output_tokens
        .unwrap_or(model.limits.max_output_tokens);
    if max_tokens == 0 || max_tokens > model.limits.max_output_tokens {
        return Err(invalid(
            "max_tokens must be positive and within the model output limit",
        ));
    }
    let mut system = Vec::new();
    let mut messages: Vec<Value> = Vec::new();
    for message in &request.messages {
        if message.role == Role::System {
            system.push(message.text());
            continue;
        }
        let role = if message.role == Role::Assistant {
            "assistant"
        } else {
            "user"
        };
        let content = message
            .content
            .iter()
            .map(content_to_json)
            .collect::<Vec<_>>();
        if content.is_empty() {
            continue;
        }
        if let Some(previous) = messages
            .last_mut()
            .filter(|previous| previous["role"] == role)
        {
            previous["content"]
                .as_array_mut()
                .expect("content array")
                .extend(content);
        } else {
            messages.push(json!({"role":role,"content":content}));
        }
    }
    let mut body = json!({"model":model.id.as_str(),"messages":messages,"max_tokens":max_tokens,"stream":true});
    if !system.is_empty() {
        body["system"] = json!(system.join("\n\n"));
    }
    if !request.tools.is_empty() {
        body["tools"] = json!(request.tools.iter().map(|tool| json!({"name":tool.name,"description":tool.description,"input_schema":tool.input_schema})).collect::<Vec<_>>());
    }
    match (request.thinking_enabled, model.thinking_mode) {
        (Some(true), ThinkingMode::Budget { budget_tokens }) => {
            if budget_tokens < 1024 || budget_tokens >= max_tokens {
                return Err(invalid(
                    "thinking budget must be at least 1024 and less than max_tokens",
                ));
            }
            body["thinking"] = json!({"type":"enabled","budget_tokens":budget_tokens});
        }
        (Some(true), ThinkingMode::Adaptive) => {
            body["thinking"] = json!({"type":"adaptive"});
            if let Some(effort) = &request.reasoning_effort {
                if !matches!(effort.as_str(), "low" | "medium" | "high" | "xhigh" | "max") {
                    return Err(invalid("unsupported Anthropic effort"));
                }
                body["output_config"] = json!({"effort":effort});
            }
        }
        // Adaptive spans models whose thinking is always on: `disabled` is a 400 there,
        // so an explicit Off falls back to the model default (off on models that allow it).
        (Some(false), ThinkingMode::Adaptive) | (None, _) => {}
        (Some(_), _) => body["thinking"] = json!({"type":"disabled"}),
    }
    // Thinking controls its own sampling, and Adaptive models reject non-default sampling.
    if request.thinking_enabled == Some(false) && model.thinking_mode != ThinkingMode::Adaptive {
        if let Some(temperature) = request.temperature {
            body["temperature"] = json!(temperature);
        }
    }
    Ok(body)
}

fn content_to_json(content: &Content) -> Value {
    match content {
        Content::Text(text) => json!({"type":"text","text":text}),
        Content::Thinking { text, signature } => {
            json!({"type":"thinking","thinking":text,"signature":signature})
        }
        Content::RedactedThinking { data } => json!({"type":"redacted_thinking","data":data}),
        Content::Image { mime_type, data } => {
            json!({"type":"image","source":{"type":"base64","media_type":mime_type,"data":data}})
        }
        Content::ToolUse(call) => {
            json!({"type":"tool_use","id":call.id,"name":call.name,"input":call.args})
        }
        Content::ToolResult {
            tool_use_id,
            content,
            is_error,
        } => {
            json!({"type":"tool_result","tool_use_id":tool_use_id,"content":content,"is_error":is_error})
        }
    }
}

fn invalid(message: &str) -> ProviderError {
    ProviderError::api_with_category(ProviderErrorCategory::InvalidRequest, None, message)
}
