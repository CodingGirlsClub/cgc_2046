use std::{
    collections::BTreeMap,
    io::{BufRead, BufReader},
    sync::Arc,
    time::Duration,
};

use futures::{channel::mpsc, future, FutureExt, StreamExt};
use serde::Deserialize;
use serde_json::{json, Value};

use crate::{
    error::ProviderError,
    event::{CompletionEvent, StopReason, TokenUsage, ToolUse},
    model::Model,
    provider::{CompletionStream, Provider},
    request::{Content, Message, Request, Role},
    sse::{SseDecoder, SseEvent},
};

/// OpenAI Chat Completions 兼容 Provider 的配置。
///
/// `base_url` 是 API 根（例如 `https://api.deepseek.com/v1`），末尾斜杠可有可无。
#[derive(Clone, Debug)]
pub struct OpenAiCompatibleConfig {
    pub base_url: String,
    pub api_key: String,
    pub models: Vec<Model>,
    pub extra_headers: Vec<(String, String)>,
}

impl OpenAiCompatibleConfig {
    pub fn new(
        base_url: impl Into<String>,
        api_key: impl Into<String>,
        models: Vec<Model>,
    ) -> Self {
        Self {
            base_url: base_url.into(),
            api_key: api_key.into(),
            models,
            extra_headers: Vec::new(),
        }
    }

    pub fn with_extra_headers(mut self, headers: Vec<(String, String)>) -> Self {
        self.extra_headers = headers;
        self
    }

    pub fn chat_completions_url(&self) -> String {
        format!("{}/chat/completions", self.base_url.trim_end_matches('/'))
    }
}

/// OpenAI-compatible Provider：覆盖国产 provider、自定义 endpoint 与 CGC 网关。
pub struct OpenAiCompatibleProvider {
    config: Arc<OpenAiCompatibleConfig>,
}

impl OpenAiCompatibleProvider {
    pub fn new(config: OpenAiCompatibleConfig) -> Self {
        Self {
            config: Arc::new(config),
        }
    }
}

impl Provider for OpenAiCompatibleProvider {
    fn id(&self) -> &crate::model::ProviderId {
        self.config
            .models
            .first()
            .map(|model| &model.provider_id)
            .expect("OpenAiCompatibleProvider requires at least one model")
    }

    fn name(&self) -> &str {
        self.config
            .models
            .first()
            .map(|model| model.provider_name.as_str())
            .unwrap_or("OpenAI Compatible")
    }

    fn models(&self) -> Vec<Model> {
        self.config.models.clone()
    }

    fn stream(
        &self,
        model: &Model,
        request: Request,
    ) -> future::BoxFuture<'static, Result<CompletionStream, ProviderError>> {
        let config = Arc::clone(&self.config);
        let body = build_body(model, &request);
        let (sender, receiver) = mpsc::unbounded::<Result<CompletionEvent, ProviderError>>();
        let spawn = std::thread::Builder::new()
            .name("cgc-agent-provider".to_string())
            .spawn(move || {
                if let Err(error) = run_request(&config, &body, &sender) {
                    let _ = sender.unbounded_send(Err(error));
                }
            });
        match spawn {
            Ok(_) => future::ready(Ok(receiver.boxed())).boxed(),
            Err(error) => future::ready(Err(ProviderError::transport(format!(
                "spawn provider thread: {error}"
            ))))
            .boxed(),
        }
    }
}

/// 把统一请求映射成 OpenAI Chat Completions 的 JSON body。
pub(crate) fn build_body(model: &Model, request: &Request) -> Value {
    let mut body = json!({
        "model": model.id.as_str(),
        "messages": request.messages.iter().map(message_to_json).collect::<Vec<_>>(),
        "stream": true,
        "stream_options": { "include_usage": true },
    });
    if let Some(temperature) = request.temperature {
        body["temperature"] = json!(temperature);
    }
    if let Some(max_output_tokens) = request.max_output_tokens {
        body["max_tokens"] = json!(max_output_tokens);
    }
    if let Some(reasoning_effort) = &request.reasoning_effort {
        body["reasoning_effort"] = json!(reasoning_effort);
    }
    if !request.tools.is_empty() {
        body["tools"] = json!(request
            .tools
            .iter()
            .map(|tool| json!({
                "type": "function",
                "function": {
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": tool.input_schema,
                }
            }))
            .collect::<Vec<_>>());
    }
    body
}

fn message_to_json(message: &Message) -> Value {
    match message.role {
        Role::System | Role::User => {
            let images: Vec<Value> = message
                .content
                .iter()
                .filter_map(|content| match content {
                    Content::Image { mime_type, data } => Some(json!({
                        "type": "image_url",
                        "image_url": {
                            "url": format!("data:{mime_type};base64,{data}"),
                        }
                    })),
                    _ => None,
                })
                .collect();
            let content = if images.is_empty() {
                json!(message.text())
            } else {
                let mut parts = vec![json!({"type": "text", "text": message.text()})];
                parts.extend(images);
                json!(parts)
            };
            json!({
                "role": if message.role == Role::System { "system" } else { "user" },
                "content": content,
            })
        }
        Role::Assistant => {
            let text = message.text();
            let tool_calls: Vec<Value> = message
                .content
                .iter()
                .filter_map(|content| match content {
                    Content::ToolUse(tool_use) => Some(json!({
                        "id": tool_use.id,
                        "type": "function",
                        "function": {
                            "name": tool_use.name,
                            "arguments": tool_use.args.to_string(),
                        }
                    })),
                    _ => None,
                })
                .collect();
            let mut json = json!({ "role": "assistant", "content": if text.is_empty() { Value::Null } else { json!(text) } });
            if !tool_calls.is_empty() {
                json["tool_calls"] = json!(tool_calls);
            }
            json
        }
        Role::Tool => {
            let first_result = message.content.iter().find_map(|content| match content {
                Content::ToolResult {
                    tool_use_id,
                    content,
                    ..
                } => Some((tool_use_id.clone(), content.clone())),
                _ => None,
            });
            match first_result {
                Some((tool_use_id, content)) => json!({
                    "role": "tool",
                    "tool_call_id": tool_use_id,
                    "content": content,
                }),
                None => json!({ "role": "tool", "content": message.text() }),
            }
        }
    }
}

fn run_request(
    config: &OpenAiCompatibleConfig,
    body: &Value,
    sender: &mpsc::UnboundedSender<Result<CompletionEvent, ProviderError>>,
) -> Result<(), ProviderError> {
    let agent_config = ureq::Agent::config_builder()
        .http_status_as_error(false)
        .timeout_global(Some(Duration::from_secs(300)))
        .build();
    let agent = ureq::Agent::new_with_config(agent_config);
    let mut request = agent
        .post(&config.chat_completions_url())
        .header("authorization", format!("Bearer {}", config.api_key))
        .header("accept", "text/event-stream");
    for (name, value) in &config.extra_headers {
        request = request.header(name, value);
    }
    let response = request.send_json(body).map_err(map_ureq_error)?;
    let status = response.status();
    if !status.is_success() {
        let mut response = response;
        let text = response.body_mut().read_to_string().unwrap_or_default();
        return Err(ProviderError::api(status.as_u16(), truncate(&text, 500)));
    }

    let mut reader = BufReader::new(response.into_body().into_reader());
    let mut decoder = SseDecoder::new();
    let mut state = StreamState::default();
    let mut line = String::new();
    loop {
        line.clear();
        match reader.read_line(&mut line) {
            Ok(0) => break,
            Ok(_) => {}
            Err(error) => return Err(ProviderError::transport(format!("read stream: {error}"))),
        }
        for event in decoder.feed(&line) {
            if process_sse_event(&mut state, event, sender)? {
                return Ok(());
            }
        }
    }
    if let Some(event) = decoder.finish() {
        let _ = process_sse_event(&mut state, event, sender)?;
    }
    for event in state.finish()? {
        let _ = sender.unbounded_send(Ok(event));
    }
    Ok(())
}

/// 返回 `true` 表示流已结束。
fn process_sse_event(
    state: &mut StreamState,
    event: SseEvent,
    sender: &mpsc::UnboundedSender<Result<CompletionEvent, ProviderError>>,
) -> Result<bool, ProviderError> {
    if event.data.trim() == "[DONE]" {
        for event in state.finish()? {
            let _ = sender.unbounded_send(Ok(event));
        }
        return Ok(true);
    }
    let chunk: OpenAiChatChunk = serde_json::from_str(&event.data)
        .map_err(|error| ProviderError::invalid_response(format!("chunk: {error}")))?;
    for event in state.on_chunk(chunk)? {
        if sender.unbounded_send(Ok(event)).is_err() {
            return Ok(true);
        }
    }
    Ok(false)
}

fn map_ureq_error(error: ureq::Error) -> ProviderError {
    match error {
        ureq::Error::StatusCode(status) => ProviderError::api(status, "http status error"),
        ureq::Error::Timeout(_) => ProviderError::transport("request timed out"),
        ureq::Error::Io(error) => ProviderError::transport(error.to_string()),
        other => ProviderError::transport(other.to_string()),
    }
}

fn truncate(text: &str, max_chars: usize) -> String {
    text.chars().take(max_chars).collect()
}

#[derive(Default)]
struct PendingToolCall {
    id: Option<String>,
    name: Option<String>,
    arguments: String,
}

#[derive(Default)]
struct StreamState {
    started: bool,
    stop_sent: bool,
    tool_calls: BTreeMap<u32, PendingToolCall>,
}

impl StreamState {
    fn on_chunk(&mut self, chunk: OpenAiChatChunk) -> Result<Vec<CompletionEvent>, ProviderError> {
        let mut events = Vec::new();
        if let (false, Some(id)) = (self.started, chunk.id.as_ref()) {
            self.started = true;
            events.push(CompletionEvent::StartMessage {
                message_id: id.clone(),
            });
        }
        if let Some(usage) = chunk.usage {
            events.push(CompletionEvent::Usage(TokenUsage {
                input: usage.prompt_tokens,
                output: usage.completion_tokens,
                cache_read: usage
                    .prompt_tokens_details
                    .map(|details| details.cached_tokens)
                    .unwrap_or(0),
                cache_creation: 0,
            }));
        }
        for choice in chunk.choices {
            if let Some(delta) = choice.delta {
                if let Some(content) = delta.content.filter(|content| !content.is_empty()) {
                    events.push(CompletionEvent::Text(content));
                }
                if let Some(reasoning) = delta
                    .reasoning_content
                    .filter(|reasoning| !reasoning.is_empty())
                {
                    events.push(CompletionEvent::Thinking {
                        text: reasoning,
                        signature: None,
                    });
                }
                for call in delta.tool_calls.unwrap_or_default() {
                    let pending = self.tool_calls.entry(call.index).or_default();
                    if let Some(id) = call.id {
                        pending.id = Some(id);
                    }
                    if let Some(function) = call.function {
                        if let Some(name) = function.name {
                            pending.name = Some(name);
                        }
                        if let Some(arguments) = function.arguments {
                            pending.arguments.push_str(&arguments);
                        }
                    }
                }
            }
            if let Some(reason) = choice.finish_reason {
                events.extend(self.flush_tool_calls()?);
                self.push_stop(&mut events, Some(reason));
            }
        }
        Ok(events)
    }

    fn flush_tool_calls(&mut self) -> Result<Vec<CompletionEvent>, ProviderError> {
        let mut events = Vec::new();
        for (index, pending) in std::mem::take(&mut self.tool_calls) {
            let name = pending.name.unwrap_or_else(|| format!("tool_{index}"));
            let id = pending.id.unwrap_or_else(|| format!("call_{index}"));
            let args = if pending.arguments.trim().is_empty() {
                Value::Object(Default::default())
            } else {
                serde_json::from_str(&pending.arguments).map_err(|error| {
                    ProviderError::invalid_response(format!("tool arguments for {name}: {error}"))
                })?
            };
            events.push(CompletionEvent::ToolUse(ToolUse { id, name, args }));
        }
        Ok(events)
    }

    fn push_stop(&mut self, events: &mut Vec<CompletionEvent>, reason: Option<String>) {
        if self.stop_sent {
            return;
        }
        self.stop_sent = true;
        events.push(CompletionEvent::Stop(match reason.as_deref() {
            Some("stop") => StopReason::EndTurn,
            Some("length") => StopReason::MaxTokens,
            Some("tool_calls") | Some("function_call") => StopReason::ToolUse,
            Some("content_filter") => StopReason::ContentFilter,
            Some(other) => StopReason::Other(other.to_string()),
            None => StopReason::EndTurn,
        }));
    }

    fn finish(&mut self) -> Result<Vec<CompletionEvent>, ProviderError> {
        let mut events = self.flush_tool_calls()?;
        self.push_stop(&mut events, None);
        Ok(events)
    }
}

#[derive(Debug, Deserialize)]
struct OpenAiChatChunk {
    id: Option<String>,
    #[serde(default)]
    choices: Vec<OpenAiChoice>,
    usage: Option<OpenAiUsage>,
}

#[derive(Debug, Deserialize)]
struct OpenAiChoice {
    delta: Option<OpenAiDelta>,
    finish_reason: Option<String>,
}

#[derive(Debug, Deserialize)]
struct OpenAiDelta {
    content: Option<String>,
    #[serde(alias = "reasoning")]
    reasoning_content: Option<String>,
    tool_calls: Option<Vec<OpenAiToolCallDelta>>,
}

#[derive(Debug, Deserialize)]
struct OpenAiToolCallDelta {
    index: u32,
    id: Option<String>,
    function: Option<OpenAiFunctionDelta>,
}

#[derive(Debug, Deserialize)]
struct OpenAiFunctionDelta {
    name: Option<String>,
    arguments: Option<String>,
}

#[derive(Debug, Deserialize)]
struct OpenAiUsage {
    prompt_tokens: u64,
    completion_tokens: u64,
    prompt_tokens_details: Option<OpenAiPromptTokensDetails>,
}

#[derive(Debug, Deserialize)]
struct OpenAiPromptTokensDetails {
    cached_tokens: u64,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{model::ModelLimits, request::ToolSchema};

    fn model() -> Model {
        Model::new(
            crate::model::ProviderId::new("deepseek"),
            "DeepSeek",
            "deepseek-chat",
            "DeepSeek Chat",
            ModelLimits::new(64_000, 8_000),
        )
    }

    fn chunk(json: &str) -> OpenAiChatChunk {
        serde_json::from_str(json).expect("chunk json")
    }

    #[test]
    fn builds_openai_body_with_tools_and_temperature() {
        let request = Request::new(vec![Message::user("hi")])
            .with_temperature(0.2)
            .with_max_output_tokens(512)
            .with_tools(vec![ToolSchema::new(
                "read_file",
                "read a file",
                serde_json::json!({"type": "object"}),
            )]);
        let body = build_body(&model(), &request);
        assert_eq!(body["model"], "deepseek-chat");
        assert!((body["temperature"].as_f64().expect("temperature") - 0.2).abs() < 1e-6);
        assert_eq!(body["max_tokens"], 512);
        assert_eq!(body["messages"][0]["role"], "user");
        assert_eq!(body["tools"][0]["function"]["name"], "read_file");
        assert_eq!(body["stream"], true);
    }

    #[test]
    fn body_carries_reasoning_effort_when_set() {
        let request =
            Request::new(vec![Message::user("hi")]).with_reasoning_effort(Some("high".to_string()));
        let body = build_body(&model(), &request);
        assert_eq!(body["reasoning_effort"], "high");
    }

    #[test]
    fn body_omits_reasoning_effort_by_default() {
        let request = Request::new(vec![Message::user("hi")]);
        let body = build_body(&model(), &request);
        assert!(body.get("reasoning_effort").is_none());
    }

    #[test]
    fn maps_text_chunks_and_stop() {
        let mut state = StreamState::default();
        let events = state
            .on_chunk(chunk(
                r#"{"id":"c1","choices":[{"delta":{"content":"hel"}}]}"#,
            ))
            .unwrap();
        assert!(
            matches!(events.as_slice(), [CompletionEvent::StartMessage { .. }, CompletionEvent::Text(text)] if text == "hel")
        );
        let events = state
            .on_chunk(chunk(
                r#"{"choices":[{"delta":{"content":"lo"},"finish_reason":"stop"}]}"#,
            ))
            .unwrap();
        assert_eq!(events[0], CompletionEvent::Text("lo".into()));
        assert_eq!(events[1], CompletionEvent::Stop(StopReason::EndTurn));
    }

    #[test]
    fn accumulates_tool_call_arguments() {
        let mut state = StreamState::default();
        state
            .on_chunk(chunk(r#"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"read_file","arguments":"{\"pa"}}]}}]}"#))
            .unwrap();
        let events = state
            .on_chunk(chunk(r#"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"th\":\"a.txt\"}"}}]},"finish_reason":"tool_calls"}]}"#))
            .unwrap();
        let tool_use = events
            .iter()
            .find_map(|event| match event {
                CompletionEvent::ToolUse(tool_use) => Some(tool_use.clone()),
                _ => None,
            })
            .expect("tool use");
        assert_eq!(tool_use.id, "call_1");
        assert_eq!(tool_use.name, "read_file");
        assert_eq!(tool_use.args["path"], "a.txt");
        assert!(events.contains(&CompletionEvent::Stop(StopReason::ToolUse)));
    }

    #[test]
    fn maps_usage_and_thinking() {
        let mut state = StreamState::default();
        let events = state
            .on_chunk(chunk(r#"{"choices":[{"delta":{"reasoning_content":"think"}}],"usage":{"prompt_tokens":10,"completion_tokens":2,"prompt_tokens_details":{"cached_tokens":4}}}"#))
            .unwrap();
        assert!(events.iter().any(
            |event| matches!(event, CompletionEvent::Thinking { text, .. } if text == "think")
        ));
        assert!(events.iter().any(|event| matches!(event, CompletionEvent::Usage(usage) if usage.input == 10 && usage.output == 2 && usage.cache_read == 4)));
    }

    #[test]
    fn invalid_tool_arguments_surface_as_error() {
        let mut state = StreamState::default();
        let result = state.on_chunk(chunk(
            r#"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"x","arguments":"not json"}}]},"finish_reason":"tool_calls"}]}"#,
        ));
        assert!(result.is_err());
    }
}

#[cfg(test)]
mod image_tests {
    use super::*;

    #[test]
    fn user_message_with_image_serializes_multimodal_content() {
        let mut message = Message::user("看图");
        message.content.push(Content::Image {
            mime_type: "image/png".to_string(),
            data: "AAAA".to_string(),
        });
        let json = message_to_json(&message);
        let parts = json["content"].as_array().expect("multimodal parts");
        assert_eq!(parts.len(), 2);
        assert_eq!(parts[0]["type"], "text");
        assert_eq!(parts[0]["text"], "看图");
        assert_eq!(parts[1]["type"], "image_url");
        assert_eq!(parts[1]["image_url"]["url"], "data:image/png;base64,AAAA");
    }
}
