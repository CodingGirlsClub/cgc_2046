//! OpenAI Responses API（`POST /responses`）兼容 Provider。
//!
//! 与 Chat 适配器同一形状：独立线程跑同步 HTTP，SSE 事件经有界通道送回。
//! 首版只覆盖文本、图片输入、函数工具与 usage；不回放 reasoning item。

use std::{
    collections::BTreeMap,
    io::{BufRead, BufReader},
    sync::Arc,
    time::Duration,
};

use futures::{channel::mpsc, future, FutureExt, StreamExt};
use serde_json::{json, Value};

use crate::{
    error::ProviderError,
    event::{CompletionEvent, StopReason, TokenUsage, ToolUse},
    model::Model,
    provider::{CompletionStream, Provider},
    request::{Content, Request, Role},
    sse::{SseDecoder, SseEvent},
    transport::{map_ureq_error, send_blocking, truncate},
};

const DELTA_CAPACITY: usize = 32;

/// `base_url` 是 API 根（例如 `https://api.openai.com/v1`），末尾斜杠可有可无。
#[derive(Clone, Debug)]
pub struct ResponsesCompatibleConfig {
    pub base_url: String,
    pub api_key: String,
    pub models: Vec<Model>,
    pub extra_headers: Vec<(String, String)>,
}

impl ResponsesCompatibleConfig {
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

    pub fn responses_url(&self) -> String {
        format!("{}/responses", self.base_url.trim_end_matches('/'))
    }
}

pub struct ResponsesCompatibleProvider {
    config: Arc<ResponsesCompatibleConfig>,
}

impl ResponsesCompatibleProvider {
    pub fn new(config: ResponsesCompatibleConfig) -> Self {
        Self {
            config: Arc::new(config),
        }
    }
}

impl Provider for ResponsesCompatibleProvider {
    fn id(&self) -> &crate::model::ProviderId {
        self.config
            .models
            .first()
            .map(|model| &model.provider_id)
            .expect("ResponsesCompatibleProvider requires at least one model")
    }

    fn name(&self) -> &str {
        self.config
            .models
            .first()
            .map(|model| model.provider_name.as_str())
            .unwrap_or("OpenAI Responses")
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
        let (sender, receiver) =
            mpsc::channel::<Result<CompletionEvent, ProviderError>>(DELTA_CAPACITY);
        let spawn = std::thread::Builder::new()
            .name("cgc-agent-responses".to_string())
            .spawn(move || {
                let mut sender = sender;
                if let Err(error) = run_request(&config, &body, &mut sender) {
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

/// 把统一请求映射成 Responses 的 JSON body。
pub(crate) fn build_body(model: &Model, request: &Request) -> Value {
    let mut instructions: Vec<String> = Vec::new();
    let mut input: Vec<Value> = Vec::new();
    for message in &request.messages {
        match message.role {
            Role::System => {
                let text = message.text();
                if !text.trim().is_empty() {
                    instructions.push(text);
                }
            }
            Role::User | Role::Assistant => {
                let assistant = message.role == Role::Assistant;
                let mut content = Vec::new();
                let text = message.text();
                if !text.is_empty() {
                    content.push(json!({
                        "type": if assistant { "output_text" } else { "input_text" },
                        "text": text,
                    }));
                }
                if !assistant {
                    for part in &message.content {
                        if let Content::Image { mime_type, data } = part {
                            content.push(json!({
                                "type": "input_image",
                                "image_url": format!("data:{mime_type};base64,{data}"),
                            }));
                        }
                    }
                }
                if !content.is_empty() {
                    input.push(json!({
                        "type": "message",
                        "role": if assistant { "assistant" } else { "user" },
                        "content": content,
                    }));
                }
                if assistant {
                    for part in &message.content {
                        if let Content::ToolUse(tool_use) = part {
                            input.push(json!({
                                "type": "function_call",
                                "call_id": tool_use.id,
                                "name": tool_use.name,
                                "arguments": tool_use.args.to_string(),
                            }));
                        }
                    }
                }
            }
            Role::Tool => {
                let mut found = false;
                for part in &message.content {
                    if let Content::ToolResult {
                        tool_use_id,
                        content,
                        ..
                    } = part
                    {
                        found = true;
                        input.push(json!({
                            "type": "function_call_output",
                            "call_id": tool_use_id,
                            "output": content,
                        }));
                    }
                }
                if !found {
                    let text = message.text();
                    if !text.is_empty() {
                        input.push(json!({
                            "type": "message",
                            "role": "user",
                            "content": [{ "type": "input_text", "text": text }],
                        }));
                    }
                }
            }
        }
    }

    let mut body = json!({
        "model": model.id.as_str(),
        "input": input,
        "stream": true,
        "store": false,
        "include": ["reasoning.encrypted_content"],
    });
    if !instructions.is_empty() {
        body["instructions"] = json!(instructions.join("\n\n"));
    }
    if let Some(max_output_tokens) = request.max_output_tokens {
        // Responses 的最小值是 16。
        body["max_output_tokens"] = json!(max_output_tokens.max(16));
    }
    if let Some(temperature) = request.temperature {
        body["temperature"] = json!(temperature);
    }
    if let Some(reasoning_effort) = &request.reasoning_effort {
        body["reasoning"] = json!({ "effort": reasoning_effort });
    }
    if !request.tools.is_empty() {
        body["tools"] = json!(request
            .tools
            .iter()
            .map(|tool| json!({
                "type": "function",
                "name": tool.name,
                "description": tool.description,
                "parameters": tool.input_schema,
                "strict": false,
            }))
            .collect::<Vec<_>>());
    }
    body
}

fn run_request(
    config: &ResponsesCompatibleConfig,
    body: &Value,
    sender: &mut mpsc::Sender<Result<CompletionEvent, ProviderError>>,
) -> Result<(), ProviderError> {
    let agent = ureq::Agent::new_with_config(
        ureq::Agent::config_builder()
            .http_status_as_error(false)
            .timeout_global(Some(Duration::from_secs(300)))
            .build(),
    );
    let mut request = agent
        .post(&config.responses_url())
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
            if process_sse_event(&mut state, event, sender)? || state.done {
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

/// 返回 `true` 表示流已结束。
fn process_sse_event(
    state: &mut StreamState,
    event: SseEvent,
    sender: &mut mpsc::Sender<Result<CompletionEvent, ProviderError>>,
) -> Result<bool, ProviderError> {
    let data = event.data.trim();
    if data.is_empty() || data == "[DONE]" {
        return Ok(false);
    }
    let value: Value = serde_json::from_str(data)
        .map_err(|error| ProviderError::invalid_response(format!("event: {error}")))?;
    for event in state.on_event(value)? {
        if !send_blocking(sender, Ok(event)) {
            return Ok(true);
        }
    }
    Ok(state.done)
}

#[derive(Default)]
struct PendingCall {
    id: Option<String>,
    name: Option<String>,
    arguments: String,
    emitted: bool,
}

#[derive(Default)]
struct StreamState {
    started: bool,
    stop_sent: bool,
    done: bool,
    tools_used: bool,
    calls: BTreeMap<u64, PendingCall>,
}

impl StreamState {
    fn on_event(&mut self, value: Value) -> Result<Vec<CompletionEvent>, ProviderError> {
        let kind = value
            .get("type")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let mut events = Vec::new();
        match kind {
            "response.created" => {
                if !self.started {
                    self.started = true;
                    if let Some(id) = value.pointer("/response/id").and_then(Value::as_str) {
                        events.push(CompletionEvent::StartMessage {
                            message_id: id.to_string(),
                        });
                    }
                }
            }
            "response.output_text.delta" => {
                if let Some(delta) = text_field(&value, "delta") {
                    events.push(CompletionEvent::Text(delta.to_string()));
                }
            }
            "response.reasoning_summary_text.delta" | "response.reasoning_text.delta" => {
                if let Some(delta) = text_field(&value, "delta") {
                    events.push(CompletionEvent::Thinking {
                        text: delta.to_string(),
                        signature: None,
                    });
                }
            }
            "response.function_call_arguments.delta" => {
                let index = output_index(&value);
                if let Some(delta) = text_field(&value, "delta") {
                    self.calls
                        .entry(index)
                        .or_default()
                        .arguments
                        .push_str(delta);
                }
            }
            "response.output_item.added" => {
                if item_kind(&value) == Some("function_call") {
                    let index = output_index(&value);
                    let call = self.calls.entry(index).or_default();
                    if let Some(id) = value.pointer("/item/call_id").and_then(Value::as_str) {
                        call.id = Some(id.to_string());
                    }
                    if let Some(name) = value.pointer("/item/name").and_then(Value::as_str) {
                        call.name = Some(name.to_string());
                    }
                }
            }
            "response.output_item.done" => {
                if item_kind(&value) == Some("function_call") {
                    let index = output_index(&value);
                    let call = self.calls.entry(index).or_default();
                    if let Some(id) = value.pointer("/item/call_id").and_then(Value::as_str) {
                        call.id = Some(id.to_string());
                    }
                    if let Some(name) = value.pointer("/item/name").and_then(Value::as_str) {
                        call.name = Some(name.to_string());
                    }
                    if let Some(arguments) =
                        value.pointer("/item/arguments").and_then(Value::as_str)
                    {
                        call.arguments = arguments.to_string();
                    }
                    if let Some(event) = self.emit_call(index)? {
                        events.push(event);
                    }
                }
            }
            "response.completed" | "response.incomplete" => {
                if let Some(usage) = value.pointer("/response/usage") {
                    events.push(CompletionEvent::Usage(usage_of(usage)));
                }
                events.extend(self.flush()?);
                let reason = if kind == "response.incomplete" {
                    match value
                        .pointer("/response/incomplete_details/reason")
                        .and_then(Value::as_str)
                    {
                        Some("max_output_tokens") => StopReason::MaxTokens,
                        Some(other) => StopReason::Other(other.to_string()),
                        None => StopReason::EndTurn,
                    }
                } else if self.tools_used {
                    StopReason::ToolUse
                } else {
                    StopReason::EndTurn
                };
                self.push_stop(&mut events, reason);
                self.done = true;
            }
            "response.failed" => {
                let message = value
                    .pointer("/response/error/message")
                    .and_then(Value::as_str)
                    .unwrap_or("response failed");
                self.done = true;
                return Err(ProviderError::invalid_response(message.to_string()));
            }
            "error" => {
                let message = value
                    .pointer("/error/message")
                    .or_else(|| value.get("message"))
                    .and_then(Value::as_str)
                    .unwrap_or("stream error");
                self.done = true;
                return Err(ProviderError::invalid_response(message.to_string()));
            }
            _ => {}
        }
        Ok(events)
    }

    fn emit_call(&mut self, index: u64) -> Result<Option<CompletionEvent>, ProviderError> {
        let Some(call) = self.calls.get_mut(&index) else {
            return Ok(None);
        };
        if call.emitted {
            return Ok(None);
        }
        call.emitted = true;
        self.tools_used = true;
        let id = call.id.clone().unwrap_or_else(|| format!("call_{index}"));
        let name = call.name.clone().unwrap_or_else(|| format!("tool_{index}"));
        let args = if call.arguments.trim().is_empty() {
            Value::Object(Default::default())
        } else {
            serde_json::from_str(&call.arguments).map_err(|error| {
                ProviderError::invalid_response(format!("tool arguments for {name}: {error}"))
            })?
        };
        Ok(Some(CompletionEvent::ToolUse(ToolUse { id, name, args })))
    }

    fn flush(&mut self) -> Result<Vec<CompletionEvent>, ProviderError> {
        let mut events = Vec::new();
        for index in self.calls.keys().copied().collect::<Vec<_>>() {
            if let Some(event) = self.emit_call(index)? {
                events.push(event);
            }
        }
        Ok(events)
    }

    fn push_stop(&mut self, events: &mut Vec<CompletionEvent>, reason: StopReason) {
        if self.stop_sent {
            return;
        }
        self.stop_sent = true;
        events.push(CompletionEvent::Stop(reason));
    }

    fn finish(&mut self) -> Result<Vec<CompletionEvent>, ProviderError> {
        let mut events = self.flush()?;
        if !self.stop_sent {
            let reason = if self.tools_used {
                StopReason::ToolUse
            } else {
                StopReason::EndTurn
            };
            self.push_stop(&mut events, reason);
        }
        Ok(events)
    }
}

fn text_field<'a>(value: &'a Value, field: &str) -> Option<&'a str> {
    value
        .get(field)
        .and_then(Value::as_str)
        .filter(|text| !text.is_empty())
}

fn item_kind(value: &Value) -> Option<&str> {
    value.pointer("/item/type").and_then(Value::as_str)
}

fn output_index(value: &Value) -> u64 {
    value
        .get("output_index")
        .and_then(Value::as_u64)
        .unwrap_or(0)
}

fn usage_of(usage: &Value) -> TokenUsage {
    let number = |path: &str| usage.pointer(path).and_then(Value::as_u64).unwrap_or(0);
    TokenUsage {
        input: number("/input_tokens"),
        output: number("/output_tokens"),
        cache_read: number("/input_tokens_details/cached_tokens"),
        cache_creation: 0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{ModelLimits, ProviderId};
    use crate::request::{Message, ToolSchema};

    fn model() -> Model {
        Model::new(
            ProviderId::new("openai"),
            "OpenAI",
            "gpt-probe",
            "GPT Probe",
            ModelLimits::new(128_000, 8_000),
        )
    }

    #[test]
    fn body_folds_system_into_instructions() {
        let request = Request {
            messages: vec![Message::system("be brief"), Message::user("hi")],
            ..Request::default()
        };
        let body = build_body(&model(), &request);
        assert_eq!(body["instructions"], "be brief");
        assert_eq!(body["input"][0]["type"], "message");
        assert_eq!(body["input"][0]["role"], "user");
        assert_eq!(body["input"][0]["content"][0]["type"], "input_text");
        assert_eq!(body["store"], false);
        assert_eq!(body["stream"], true);
    }

    #[test]
    fn body_turns_tool_results_into_function_call_output() {
        let request = Request {
            messages: vec![
                Message::new(
                    Role::Assistant,
                    vec![Content::ToolUse(ToolUse {
                        id: "call_1".to_string(),
                        name: "read_file".to_string(),
                        args: json!({"path": "a"}),
                    })],
                ),
                Message::tool_result("call_1", "contents", false),
            ],
            ..Request::default()
        };
        let body = build_body(&model(), &request);
        assert_eq!(body["input"][0]["type"], "function_call");
        assert_eq!(body["input"][0]["call_id"], "call_1");
        assert_eq!(body["input"][1]["type"], "function_call_output");
        assert_eq!(body["input"][1]["output"], "contents");
    }

    #[test]
    fn body_declares_tools_flat() {
        let request = Request {
            tools: vec![ToolSchema::new(
                "read_file",
                "read a file",
                json!({"type": "object"}),
            )],
            ..Request::default()
        };
        let body = build_body(&model(), &request);
        assert_eq!(body["tools"][0]["type"], "function");
        assert_eq!(body["tools"][0]["name"], "read_file");
        assert!(body["tools"][0].get("function").is_none());
    }

    #[test]
    fn text_and_usage_and_stop() {
        let mut state = StreamState::default();
        let events = state
            .on_event(json!({"type": "response.created", "response": {"id": "resp_1"}}))
            .unwrap();
        assert!(matches!(
            &events[0],
            CompletionEvent::StartMessage { message_id } if message_id == "resp_1"
        ));
        let events = state
            .on_event(json!({"type": "response.output_text.delta", "delta": "hel"}))
            .unwrap();
        assert_eq!(events, vec![CompletionEvent::Text("hel".to_string())]);
        let events = state
            .on_event(json!({
                "type": "response.completed",
                "response": {"usage": {"input_tokens": 7, "output_tokens": 2,
                    "input_tokens_details": {"cached_tokens": 3}}}
            }))
            .unwrap();
        assert!(events.contains(&CompletionEvent::Usage(TokenUsage {
            input: 7,
            output: 2,
            cache_read: 3,
            cache_creation: 0,
        })));
        assert!(events.contains(&CompletionEvent::Stop(StopReason::EndTurn)));
        assert!(state.done);
    }

    #[test]
    fn tool_call_completes_from_output_item_done() {
        let mut state = StreamState::default();
        state
            .on_event(json!({
                "type": "response.output_item.added", "output_index": 0,
                "item": {"type": "function_call", "call_id": "call_9", "name": "read_file"}
            }))
            .unwrap();
        state
            .on_event(json!({
                "type": "response.function_call_arguments.delta",
                "output_index": 0, "delta": "{\"path\":"
            }))
            .unwrap();
        let events = state
            .on_event(json!({
                "type": "response.output_item.done", "output_index": 0,
                "item": {"type": "function_call", "call_id": "call_9", "name": "read_file",
                         "arguments": "{\"path\":\"a\"}"}
            }))
            .unwrap();
        assert_eq!(
            events,
            vec![CompletionEvent::ToolUse(ToolUse {
                id: "call_9".to_string(),
                name: "read_file".to_string(),
                args: json!({"path": "a"}),
            })]
        );
        let events = state
            .on_event(json!({"type": "response.completed", "response": {}}))
            .unwrap();
        assert!(events.contains(&CompletionEvent::Stop(StopReason::ToolUse)));
    }

    #[test]
    fn incomplete_max_tokens_maps_to_max_tokens_stop() {
        let mut state = StreamState::default();
        let events = state
            .on_event(json!({
                "type": "response.incomplete",
                "response": {"incomplete_details": {"reason": "max_output_tokens"}}
            }))
            .unwrap();
        assert!(events.contains(&CompletionEvent::Stop(StopReason::MaxTokens)));
    }

    #[test]
    fn failed_response_is_an_error() {
        let mut state = StreamState::default();
        let error = state
            .on_event(json!({
                "type": "response.failed",
                "response": {"error": {"message": "boom"}}
            }))
            .unwrap_err();
        assert!(error.to_string().contains("boom"));
    }
}
