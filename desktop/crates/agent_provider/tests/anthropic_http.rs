use cgc_agent_provider::{
    AnthropicCompatibleConfig, AnthropicCompatibleProvider, CompletionEvent, Content, Message,
    Model, ModelLimits, Provider, ProviderErrorCategory, ProviderId, Request, StopReason,
    ThinkingMode, ToolSchema, ToolUse,
};
use futures::StreamExt;
use serde_json::{json, Value};
use std::{
    io::{BufRead, BufReader, Read, Write},
    net::TcpListener,
    sync::mpsc,
    thread,
    time::Duration,
};

fn model() -> Model {
    Model::new(
        ProviderId::new("compatible"),
        "Compatible",
        "test-model",
        "Test",
        ModelLimits::new(32_000, 4_096),
    )
}

struct Captured {
    path: String,
    headers: String,
    body: Value,
}

fn serve(
    status: u16,
    frames: Vec<Value>,
) -> (String, mpsc::Receiver<Captured>, thread::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let (send, receive) = mpsc::channel();
    let task = thread::spawn(move || {
        let (socket, _) = listener.accept().unwrap();
        socket
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        let mut reader = BufReader::new(socket);
        let mut headers = String::new();
        loop {
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            if line == "\r\n" {
                break;
            }
            assert!(!line.is_empty(), "request ended before headers");
            headers.push_str(&line);
        }
        let length = headers
            .lines()
            .find_map(|line| {
                line.to_ascii_lowercase()
                    .strip_prefix("content-length:")
                    .map(|value| value.trim().parse::<usize>().unwrap())
            })
            .unwrap();
        let mut body = vec![0; length];
        reader.read_exact(&mut body).unwrap();
        let path = headers
            .lines()
            .next()
            .unwrap()
            .split_whitespace()
            .nth(1)
            .unwrap()
            .to_string();
        send.send(Captured {
            path,
            headers,
            body: serde_json::from_slice(&body).unwrap(),
        })
        .unwrap();
        let response: String = frames
            .into_iter()
            .map(|frame| {
                format!(
                    "event: {}\r\ndata: {frame}\r\n\r\n",
                    frame["type"].as_str().unwrap_or("error")
                )
            })
            .collect();
        write!(reader.get_mut(), "HTTP/1.1 {status} Test\r\nContent-Type: text/event-stream\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{response}", response.len()).unwrap();
    });
    (format!("http://{address}/proxy/v1/"), receive, task)
}

fn start() -> Value {
    json!({"type":"message_start","message":{"id":"msg_test","usage":{"input_tokens":7,"output_tokens":0,"cache_read_input_tokens":3,"cache_creation_input_tokens":2}}})
}
fn block(index: usize, content: Value) -> Value {
    json!({"type":"content_block_start","index":index,"content_block":content})
}
fn delta(index: usize, value: Value) -> Value {
    json!({"type":"content_block_delta","index":index,"delta":value})
}
fn end_block(index: usize) -> Value {
    json!({"type":"content_block_stop","index":index})
}
fn finish(reason: &str) -> Vec<Value> {
    vec![
        json!({"type":"message_delta","delta":{"stop_reason":reason},"usage":{"output_tokens":9}}),
        json!({"type":"message_stop"}),
    ]
}

#[test]
fn messages_protocol_preserves_tools_images_signed_blocks_and_cumulative_usage() {
    let mut frames = vec![
        start(),
        json!({"type":"ping"}),
        block(0, json!({"type":"thinking","thinking":"","signature":""})),
        delta(0, json!({"type":"thinking_delta","thinking":"检查"})),
        delta(0, json!({"type":"signature_delta","signature":"sig-"})),
        delta(0, json!({"type":"signature_delta","signature":"complete"})),
        end_block(0),
        block(1, json!({"type":"redacted_thinking","data":"opaque"})),
        end_block(1),
        block(
            2,
            json!({"type":"tool_use","id":"call_next","name":"read_file","input":{}}),
        ),
        delta(
            2,
            json!({"type":"input_json_delta","partial_json":"{\"path\":"}),
        ),
        delta(
            2,
            json!({"type":"input_json_delta","partial_json":"\"a.txt\"}"}),
        ),
        end_block(2),
        json!({"type":"message_delta","delta":{},"usage":{"output_tokens":4}}),
    ];
    frames.extend(finish("tool_use"));
    let (url, captured, task) = serve(200, frames);
    let provider = AnthropicCompatibleProvider::new(AnthropicCompatibleConfig::new(
        url,
        "test-key",
        vec![model()],
    ));
    let assistant = Message::new(
        cgc_agent_provider::Role::Assistant,
        vec![
            Content::Thinking {
                text: "old thinking".into(),
                signature: "old signature".into(),
            },
            Content::ToolUse(ToolUse {
                id: "first".into(),
                name: "read_file".into(),
                args: json!({"path":"x"}),
            }),
            Content::ToolUse(ToolUse {
                id: "second".into(),
                name: "read_file".into(),
                args: json!({"path":"y"}),
            }),
        ],
    );
    let mut user = Message::user("read these");
    user.content.push(Content::Image {
        mime_type: "image/jpeg".into(),
        data: "aW1hZ2U=".into(),
    });
    let request = Request::new(vec![
        Message::system("system"),
        user,
        assistant,
        Message::tool_result("first", "x", false),
        Message::tool_result("second", "denied", true),
    ])
    .with_tools(vec![ToolSchema::new(
        "read_file",
        "Read",
        json!({"type":"object"}),
    )]);
    let events = futures::executor::block_on(async {
        provider
            .stream(&model(), request)
            .await
            .unwrap()
            .collect::<Vec<_>>()
            .await
    });
    let events = events.into_iter().collect::<Result<Vec<_>, _>>().unwrap();
    let captured = captured.recv_timeout(Duration::from_secs(5)).unwrap();
    task.join().unwrap();
    assert_eq!(captured.path, "/proxy/v1/messages");
    let headers = captured.headers.to_ascii_lowercase();
    assert!(headers.contains("x-api-key: test-key"));
    assert!(headers.contains("anthropic-version: 2023-06-01"));
    assert!(!headers.contains("authorization:"));
    assert_eq!(captured.body["system"], "system");
    assert_eq!(captured.body["max_tokens"], 4096);
    assert_eq!(
        captured.body["messages"][0]["content"][1]["source"]["media_type"],
        "image/jpeg"
    );
    assert_eq!(
        captured.body["messages"][1]["content"][0],
        json!({"type":"thinking","thinking":"old thinking","signature":"old signature"})
    );
    assert_eq!(
        captured.body["messages"][2],
        json!({"role":"user","content":[{"type":"tool_result","tool_use_id":"first","content":"x","is_error":false},{"type":"tool_result","tool_use_id":"second","content":"denied","is_error":true}]})
    );
    let blocks: Vec<_> = events
        .iter()
        .filter_map(|event| {
            if let CompletionEvent::ContentBlock(block) = event {
                Some(block.clone())
            } else {
                None
            }
        })
        .collect();
    assert_eq!(
        blocks,
        vec![
            Content::Thinking {
                text: "检查".into(),
                signature: "sig-complete".into()
            },
            Content::RedactedThinking {
                data: "opaque".into()
            },
            Content::ToolUse(ToolUse {
                id: "call_next".into(),
                name: "read_file".into(),
                args: json!({"path":"a.txt"})
            })
        ]
    );
    assert!(events.iter().any(|event| matches!(event, CompletionEvent::ToolUse(call) if call.args == json!({"path":"a.txt"}))));
    let usage: Vec<_> = events
        .iter()
        .filter_map(|event| {
            if let CompletionEvent::Usage(usage) = event {
                Some(*usage)
            } else {
                None
            }
        })
        .collect();
    assert_eq!(
        usage,
        vec![cgc_agent_provider::TokenUsage {
            input: 12,
            output: 9,
            cache_read: 3,
            cache_creation: 2
        }]
    );
    assert_eq!(usage[0].total(), 21);
    assert_eq!(
        events.last(),
        Some(&CompletionEvent::Stop(StopReason::ToolUse))
    );
}

#[test]
fn incomplete_message_and_stream_error_are_failures() {
    for frames in [
        vec![start()],
        vec![
            start(),
            json!({"type":"error","error":{"type":"overloaded_error","message":"busy"}}),
        ],
    ] {
        let (url, captured, task) = serve(200, frames);
        let provider = AnthropicCompatibleProvider::new(AnthropicCompatibleConfig::new(
            url,
            "test-key",
            vec![model()],
        ));
        let events = futures::executor::block_on(async {
            provider
                .stream(&model(), Request::new(vec![Message::user("hi")]))
                .await
                .unwrap()
                .collect::<Vec<_>>()
                .await
        });
        captured.recv_timeout(Duration::from_secs(5)).unwrap();
        task.join().unwrap();
        assert!(events.iter().any(Result::is_err));
        assert!(!events
            .iter()
            .any(|event| matches!(event, Ok(CompletionEvent::Stop(_)))));
    }
}

#[test]
fn thinking_modes_use_protocol_fields_and_validate_budget() {
    for (mode, expected, effort) in [
        (
            ThinkingMode::Budget {
                budget_tokens: 2048,
            },
            json!({"type":"enabled","budget_tokens":2048}),
            None,
        ),
        (
            ThinkingMode::Adaptive,
            json!({"type":"adaptive"}),
            Some("high"),
        ),
        (ThinkingMode::Disabled, json!({"type":"disabled"}), None),
    ] {
        let model = model().with_thinking_mode(mode);
        let (url, captured, task) = serve(200, {
            let mut frames = vec![start()];
            frames.extend(finish("end_turn"));
            frames
        });
        let provider = AnthropicCompatibleProvider::new(AnthropicCompatibleConfig::new(
            url,
            "test-key",
            vec![model.clone()],
        ));
        let request = Request::new(vec![Message::user("hi")])
            .with_thinking_enabled(true)
            .with_reasoning_effort(effort.map(str::to_string));
        let events = futures::executor::block_on(async {
            provider
                .stream(&model, request)
                .await
                .unwrap()
                .collect::<Vec<_>>()
                .await
        });
        events.into_iter().collect::<Result<Vec<_>, _>>().unwrap();
        let body = captured.recv_timeout(Duration::from_secs(5)).unwrap().body;
        task.join().unwrap();
        assert_eq!(body["thinking"], expected);
        if let Some(effort) = effort {
            assert_eq!(body["output_config"]["effort"], effort);
        }
        assert!(body.get("reasoning_effort").is_none());
    }
    let model = model().with_thinking_mode(ThinkingMode::Budget {
        budget_tokens: 4096,
    });
    let provider = AnthropicCompatibleProvider::new(AnthropicCompatibleConfig::new(
        "http://127.0.0.1:1",
        "test-key",
        vec![model.clone()],
    ));
    let result = futures::executor::block_on(provider.stream(
        &model,
        Request::new(vec![Message::user("hi")]).with_thinking_enabled(true),
    ));
    assert!(
        matches!(result, Err(error) if error.category() == ProviderErrorCategory::InvalidRequest)
    );
}

#[test]
fn auxiliary_requests_use_model_defaults_but_explicit_off_remains_off() {
    for mode in [
        ThinkingMode::Disabled,
        ThinkingMode::Adaptive,
        ThinkingMode::Budget {
            budget_tokens: 2048,
        },
    ] {
        for explicit_off in [false, true] {
            let model = model().with_thinking_mode(mode);
            let mut frames = vec![start()];
            frames.extend(finish("end_turn"));
            let (url, captured, task) = serve(200, frames);
            let provider = AnthropicCompatibleProvider::new(AnthropicCompatibleConfig::new(
                url,
                "test-key",
                vec![model.clone()],
            ));
            let mut request = Request::new(vec![Message::user("a short auxiliary request")])
                .with_max_output_tokens(64)
                .with_temperature(0.2);
            if explicit_off {
                request = request.with_thinking_enabled(false);
            }
            let events = futures::executor::block_on(async {
                provider
                    .stream(&model, request)
                    .await
                    .unwrap()
                    .collect::<Vec<_>>()
                    .await
            })
            .into_iter()
            .collect::<Result<Vec<_>, _>>()
            .unwrap();
            assert!(events
                .iter()
                .any(|event| matches!(event, CompletionEvent::Stop(StopReason::EndTurn))));
            let body = captured.recv_timeout(Duration::from_secs(5)).unwrap().body;
            task.join().unwrap();
            if explicit_off && mode != ThinkingMode::Adaptive {
                assert_eq!(body["thinking"], json!({"type":"disabled"}));
                assert!((body["temperature"].as_f64().unwrap() - 0.2).abs() < 1e-6);
            } else {
                assert!(
                    body.get("thinking").is_none(),
                    "Adaptive and model-default requests must omit thinking: {body}"
                );
                assert!(
                    body.get("temperature").is_none(),
                    "omitted thinking must not force unsupported sampling parameters"
                );
            }
        }
    }
}

#[test]
fn context_window_exhaustion_preserves_partial_text_and_reports_truncation() {
    let mut frames = vec![
        start(),
        block(0, json!({"type":"text","text":""})),
        delta(0, json!({"type":"text_delta","text":"partial answer"})),
        end_block(0),
    ];
    frames.extend(finish("model_context_window_exceeded"));
    let (url, captured, task) = serve(200, frames);
    let model = model();
    let provider = AnthropicCompatibleProvider::new(AnthropicCompatibleConfig::new(
        url,
        "test-key",
        vec![model.clone()],
    ));
    let events = futures::executor::block_on(async {
        provider
            .stream(&model, Request::new(vec![Message::user("continue")]))
            .await
            .unwrap()
            .collect::<Vec<_>>()
            .await
    })
    .into_iter()
    .collect::<Result<Vec<_>, _>>()
    .unwrap();
    captured.recv_timeout(Duration::from_secs(5)).unwrap();
    task.join().unwrap();
    assert!(events
        .iter()
        .any(|event| matches!(event, CompletionEvent::Text(text) if text == "partial answer")));
    assert_eq!(
        events.last(),
        Some(&CompletionEvent::Stop(StopReason::MaxTokens))
    );
}
