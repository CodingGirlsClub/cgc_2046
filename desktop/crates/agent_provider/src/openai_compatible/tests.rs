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
fn maps_usage_and_thinking_with_reasoning_before_content() {
    let mut state = StreamState::default();
    let events = state
        .on_chunk(chunk(
            r#"{"choices":[{"delta":{"reasoning_content":"think","content":"answer"}}],"usage":{"prompt_tokens":10,"completion_tokens":2,"prompt_cache_hit_tokens":4}}"#,
        ))
        .unwrap();
    assert!(matches!(
        &events[0],
        CompletionEvent::Thinking { text, signature: None } if text == "think"
    ));
    assert_eq!(events[1], CompletionEvent::Text("answer".into()));
    assert!(events.iter().any(|event| matches!(
        event,
        CompletionEvent::Usage(usage)
            if usage.input == 10 && usage.output == 2 && usage.cache_read == 4
    )));
}

#[test]
fn invalid_tool_arguments_surface_as_error() {
    let mut state = StreamState::default();
    let result = state.on_chunk(chunk(
        r#"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"x","arguments":"not json"}}]},"finish_reason":"tool_calls"}]}"#,
    ));
    assert!(result.is_err());
}

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

#[test]
fn assistant_message_strips_thinking_blocks_and_preserves_content_and_tool_calls() {
    let message = Message::new(
        Role::Assistant,
        vec![
            Content::Thinking {
                text: "secret chain of thought".into(),
                signature: String::new(),
            },
            Content::RedactedThinking {
                data: "redacted".into(),
            },
            Content::Text("final answer".into()),
            Content::ToolUse(ToolUse {
                id: "call_1".into(),
                name: "read_file".into(),
                args: json!({"path": "main.rs"}),
            }),
        ],
    );
    let serialized = serde_json::to_string(&message_to_json(&message)).expect("json");
    assert!(serialized.contains("\"content\":\"final answer\""));
    assert!(serialized.contains("\"tool_calls\""));
    assert!(!serialized.contains("reasoning_content"));
    assert!(!serialized.contains("secret chain of thought"));
    assert!(!serialized.contains("redacted"));
}
