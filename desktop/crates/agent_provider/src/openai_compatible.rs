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
    request::{canonicalize_json, Content, Message, Request, Role, ToolSchema},
    sse::{SseDecoder, SseEvent},
    transport::{map_ureq_error, parse_openai_error, send_blocking},
};

/// OpenAI Chat Completions 兼容 Provider 的配置。
///
/// 事件通道容量：足够吸收正常突发，又能在 UI 卡顿时限住内存。
const DELTA_CAPACITY: usize = 32;

/// 动态 Bearer 令牌解析器：网关模式下每次请求按需读取/签发，遇到 401 时可触发重签。
pub trait BearerTokenSource: Send + Sync {
    fn resolve_token(&self) -> Result<String, ProviderError>;

    /// 当前令牌收到 HTTP 401 时由客户端调用一次；返回 `Some(new_token)` 时自动用新令牌重发一次。
    fn refresh_after_unauthorized(
        &self,
        _rejected_token: &str,
    ) -> Result<Option<String>, ProviderError> {
        Ok(None)
    }
}

/// `base_url` 是 API 根（例如 `https://api.deepseek.com/v1`），末尾斜杠可有可无。
#[derive(Clone)]
pub struct OpenAiCompatibleConfig {
    pub base_url: String,
    pub api_key: String,
    pub models: Vec<Model>,
    pub extra_headers: Vec<(String, String)>,
    token_source: Option<Arc<dyn BearerTokenSource>>,
    model_resolver: Option<Arc<dyn Fn(&Model, &Request) -> String + Send + Sync>>,
}

impl std::fmt::Debug for OpenAiCompatibleConfig {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("OpenAiCompatibleConfig")
            .field("base_url", &self.base_url)
            .field(
                "api_key",
                &if self.api_key.is_empty() {
                    "<dynamic>"
                } else {
                    "<redacted>"
                },
            )
            .field("models", &self.models)
            .field("extra_headers", &self.extra_headers)
            .finish()
    }
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
            token_source: None,
            model_resolver: None,
        }
    }

    pub fn with_token_source(mut self, token_source: Arc<dyn BearerTokenSource>) -> Self {
        self.token_source = Some(token_source);
        self
    }

    pub fn with_model_resolver(
        mut self,
        resolver: Arc<dyn Fn(&Model, &Request) -> String + Send + Sync>,
    ) -> Self {
        self.model_resolver = Some(resolver);
        self
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
        let wire_model = config
            .model_resolver
            .as_ref()
            .map(|resolve| resolve(model, &request))
            .unwrap_or_else(|| model.id.as_str().to_string());
        let session_id = request
            .session_id
            .as_deref()
            .map(str::trim)
            .filter(|id| !id.is_empty())
            .map(str::to_string);
        let body = build_body_with_model(&wire_model, &request);
        // 有界传送：慢消费者（卡顿的 UI）不能让整段模型输出堆在内存里。
        // worker 是独立 std 线程，阻塞式发送即可产生背压，不会卡住 async runtime。
        let (sender, receiver) =
            mpsc::channel::<Result<CompletionEvent, ProviderError>>(DELTA_CAPACITY);
        let spawn = std::thread::Builder::new()
            .name("cgc-agent-provider".to_string())
            .spawn(move || {
                let mut sender = sender;
                if let Err(error) = run_request(&config, &body, session_id.as_deref(), &mut sender)
                {
                    let _ = send_blocking(&mut sender, Err(error));
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
pub fn build_body(model: &Model, request: &Request) -> Value {
    build_body_with_model(model.id.as_str(), request)
}

fn build_body_with_model(model_id: &str, request: &Request) -> Value {
    let mut body = json!({
        "model": model_id,
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
        let mut sorted_tools: Vec<&ToolSchema> = request.tools.iter().collect();
        sorted_tools.sort_by(|left, right| left.name.cmp(&right.name));
        body["tools"] = json!(sorted_tools
            .into_iter()
            .map(|tool| json!({
                "type": "function",
                "function": {
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": canonicalize_json(&tool.input_schema),
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
            // 历史 assistant 消息只保留 `content` 与 `tool_calls`，显式剥离上一轮
            // `Thinking` / `RedactedThinking`（DeepSeek Reasoner 回传 reasoning_content 会 400）。
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
                            "arguments": canonicalize_json(&tool_use.args).to_string(),
                        }
                    })),
                    _ => None,
                })
                .collect();
            let mut json = json!({
                "role": "assistant",
                "content": if text.is_empty() { Value::Null } else { json!(text) }
            });
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
    session_id: Option<&str>,
    sender: &mut mpsc::Sender<Result<CompletionEvent, ProviderError>>,
) -> Result<(), ProviderError> {
    let agent_config = ureq::Agent::config_builder()
        .http_status_as_error(false)
        .timeout_global(Some(Duration::from_secs(300)))
        .build();
    let agent = ureq::Agent::new_with_config(agent_config);
    let bearer = match &config.token_source {
        Some(source) => source.resolve_token()?,
        None => config.api_key.clone(),
    };
    let mut response = send_once(&agent, config, &bearer, session_id, body)?;
    if response.status().as_u16() == 401 {
        if let Some(source) = &config.token_source {
            if let Some(refreshed) = source.refresh_after_unauthorized(&bearer)? {
                response = send_once(&agent, config, &refreshed, session_id, body)?;
            }
        }
    }
    let status = response.status();
    if !status.is_success() {
        let mut response = response;
        let text = response.body_mut().read_to_string().unwrap_or_default();
        return Err(parse_openai_error(Some(status.as_u16()), &text));
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
        if !send_blocking(sender, Ok(event)) {
            return Ok(());
        }
    }
    Ok(())
}

fn send_once(
    agent: &ureq::Agent,
    config: &OpenAiCompatibleConfig,
    bearer: &str,
    session_id: Option<&str>,
    body: &Value,
) -> Result<ureq::http::Response<ureq::Body>, ProviderError> {
    let mut request = agent
        .post(&config.chat_completions_url())
        .header("authorization", format!("Bearer {bearer}"))
        .header("accept", "text/event-stream");
    if let Some(session_id) = session_id {
        request = request.header("x-session-affinity", session_id);
    }
    for (name, value) in &config.extra_headers {
        request = request.header(name, value);
    }
    request.send_json(body).map_err(map_ureq_error)
}

/// 返回 `true` 表示流已结束。
fn process_sse_event(
    state: &mut StreamState,
    event: SseEvent,
    sender: &mut mpsc::Sender<Result<CompletionEvent, ProviderError>>,
) -> Result<bool, ProviderError> {
    let trimmed = event.data.trim();
    if trimmed.is_empty() {
        return Ok(false);
    }
    if trimmed == "[DONE]" {
        for event in state.finish()? {
            if !send_blocking(sender, Ok(event)) {
                return Ok(true);
            }
        }
        return Ok(true);
    }
    if let Ok(raw_json) = serde_json::from_str::<Value>(trimmed) {
        if raw_json.get("error").is_some_and(|err| !err.is_null()) {
            return Err(parse_openai_error(None, trimmed));
        }
    }
    let chunk: OpenAiChatChunk = serde_json::from_str(trimmed)
        .map_err(|error| ProviderError::invalid_response(format!("chunk: {error}")))?;
    for event in state.on_chunk(chunk)? {
        if !send_blocking(sender, Ok(event)) {
            return Ok(true);
        }
    }
    Ok(false)
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
        for choice in chunk.choices {
            if let Some(delta) = choice.delta {
                if let Some(reasoning) = delta
                    .reasoning_content
                    .filter(|reasoning| !reasoning.is_empty())
                {
                    events.push(CompletionEvent::Thinking {
                        text: reasoning,
                        signature: None,
                    });
                }
                if let Some(content) = delta.content.filter(|content| !content.is_empty()) {
                    events.push(CompletionEvent::Text(content));
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
        if let Some(usage) = chunk.usage {
            let cache_read = usage
                .prompt_tokens_details
                .map(|details| details.cached_tokens)
                .or(usage.prompt_cache_hit_tokens)
                .unwrap_or(0);
            events.push(CompletionEvent::Usage(TokenUsage {
                input: usage.prompt_tokens,
                output: usage.completion_tokens,
                cache_read,
                cache_creation: 0,
            }));
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
    #[serde(default)]
    prompt_cache_hit_tokens: Option<u64>,
}

#[derive(Debug, Deserialize)]
struct OpenAiPromptTokensDetails {
    cached_tokens: u64,
}

#[cfg(test)]
mod tests;
