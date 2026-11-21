use std::io::{Read, Write};
use std::net::TcpListener;
use std::sync::mpsc;

use cgc_agent_provider::{
    openai_compatible::build_body, CompletionEvent, Content, Message, Model, ModelLimits,
    OpenAiCompatibleConfig, OpenAiCompatibleProvider, Provider, ProviderError,
    ProviderErrorCategory, ProviderId, Request, Role, StopReason, TokenUsage, ToolUse,
};
use futures::StreamExt;

struct MockHttpReply {
    status: u16,
    content_type: &'static str,
    body: String,
}

fn spawn_mock_gateway(replies: Vec<MockHttpReply>) -> (String, mpsc::Receiver<String>) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind mock gateway");
    let addr = listener.local_addr().expect("local addr");
    let (sender, receiver) = mpsc::channel();
    std::thread::spawn(move || {
        for reply in replies {
            let Ok((mut stream, _)) = listener.accept() else {
                break;
            };
            let mut request = Vec::new();
            let mut buf = [0u8; 4096];
            let header_end = loop {
                let read = stream.read(&mut buf).expect("read headers");
                if read == 0 {
                    break request.len();
                }
                request.extend_from_slice(&buf[..read]);
                if let Some(pos) = request.windows(4).position(|w| w == b"\r\n\r\n") {
                    break pos + 4;
                }
            };
            let headers = String::from_utf8_lossy(&request[..header_end]).to_string();
            let content_length = headers
                .lines()
                .find_map(|line| {
                    let (name, value) = line.split_once(':')?;
                    name.eq_ignore_ascii_case("content-length")
                        .then(|| value.trim().parse::<usize>().ok())
                        .flatten()
                })
                .unwrap_or(0);
            while request.len() < header_end + content_length {
                let read = stream.read(&mut buf).expect("read body");
                if read == 0 {
                    break;
                }
                request.extend_from_slice(&buf[..read]);
            }
            let _ = sender.send(String::from_utf8_lossy(&request).to_string());
            let response = format!(
                "HTTP/1.1 {} OK\r\nContent-Type: {}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                reply.status,
                reply.content_type,
                reply.body.len(),
                reply.body
            );
            let _ = stream.write_all(response.as_bytes());
            let _ = stream.flush();
        }
    });
    (format!("http://{addr}/v1"), receiver)
}

fn gateway_model() -> Model {
    Model::new(
        ProviderId::new("cgc-cloud"),
        "CGC Cloud",
        "deepseek-reasoner",
        "DeepSeek Reasoner",
        ModelLimits::new(64_000, 8_192),
    )
}

fn collect_events(
    provider: &OpenAiCompatibleProvider,
    model: &Model,
    request: Request,
) -> Vec<Result<CompletionEvent, ProviderError>> {
    futures::executor::block_on(async {
        let stream = provider.stream(model, request).await.expect("start stream");
        stream.collect::<Vec<_>>().await
    })
}

#[test]
fn sse_orders_reasoning_then_content_then_tool_calls_then_usage_with_affinity() {
    let sse_body = concat!(
        "data: {\"id\":\"chatcmpl-1\",\"choices\":[{\"delta\":{\"reasoning_content\":\"先检查\"}}]}\n\n",
        "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"目录结构\"}}]}\n\n",
        "data: {\"choices\":[{\"delta\":{\"content\":\"我将读取文件。\"}}]}\n\n",
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_42\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{\\\"path\\\":\"}}]}}]}\n\n",
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"\\\"Cargo.toml\\\"}\"}}]},\"finish_reason\":\"tool_calls\"}]}\n\n",
        "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":120,\"completion_tokens\":35,\"prompt_cache_hit_tokens\":96}}\n\n",
        "data: [DONE]\n\n"
    );
    let (base_url, captured) = spawn_mock_gateway(vec![MockHttpReply {
        status: 200,
        content_type: "text/event-stream",
        body: sse_body.to_string(),
    }]);

    let model = gateway_model();
    let provider = OpenAiCompatibleProvider::new(OpenAiCompatibleConfig::new(
        base_url,
        "cgc_terminal_token",
        vec![model.clone()],
    ));
    let request = Request::new(vec![Message::user("看一下配置")]).with_session_id("sess-sticky-77");
    let events: Vec<CompletionEvent> = collect_events(&provider, &model, request)
        .into_iter()
        .map(|item| item.expect("valid event"))
        .collect();

    assert_eq!(
        events,
        vec![
            CompletionEvent::StartMessage {
                message_id: "chatcmpl-1".into()
            },
            CompletionEvent::Thinking {
                text: "先检查".into(),
                signature: None,
            },
            CompletionEvent::Thinking {
                text: "目录结构".into(),
                signature: None,
            },
            CompletionEvent::Text("我将读取文件。".into()),
            CompletionEvent::ToolUse(ToolUse {
                id: "call_42".into(),
                name: "read_file".into(),
                args: serde_json::json!({"path": "Cargo.toml"}),
            }),
            CompletionEvent::ContentBlock(Content::Thinking {
                text: "先检查目录结构".into(),
                signature: String::new(),
            }),
            CompletionEvent::ContentBlock(Content::Text("我将读取文件。".into())),
            CompletionEvent::ContentBlock(Content::ToolUse(ToolUse {
                id: "call_42".into(),
                name: "read_file".into(),
                args: serde_json::json!({"path": "Cargo.toml"}),
            })),
            CompletionEvent::Stop(StopReason::ToolUse),
            CompletionEvent::Usage(TokenUsage {
                input: 120,
                output: 35,
                cache_read: 96,
                cache_creation: 0,
            }),
        ]
    );

    let raw_http = captured.recv().expect("captured http request");
    let lower = raw_http.to_ascii_lowercase();
    assert!(lower.contains("x-session-affinity: sess-sticky-77"));
    assert!(lower.contains("authorization: bearer cgc_terminal_token"));
}

#[test]
fn http_and_sse_402_and_429_map_to_distinct_gateway_errors() {
    let (base_url, _captured) = spawn_mock_gateway(vec![
        MockHttpReply {
            status: 402,
            content_type: "application/json",
            body: r#"{"error":{"code":"insufficient_quota","type":"billing_error","message":"Insufficient LLM credits."}}"#.into(),
        },
        MockHttpReply {
            status: 200,
            content_type: "text/event-stream",
            body: "data: {\"error\":{\"code\":\"insufficient_quota\",\"message\":\"Mid-stream quota exhausted.\"}}\n\n".into(),
        },
        MockHttpReply {
            status: 429,
            content_type: "application/json",
            body: r#"{"error":{"code":"concurrency_limit_exceeded","type":"rate_limit_error","message":"Too many concurrent active streams."}}"#.into(),
        },
        MockHttpReply {
            status: 200,
            content_type: "text/event-stream",
            body: "data: {\"error\":{\"code\":\"concurrency_limit_exceeded\",\"message\":\"SSE stream slot exhausted.\"}}\n\n".into(),
        },
        MockHttpReply {
            status: 429,
            content_type: "application/json",
            body: r#"{"error":{"code":"rate_limit_exceeded","type":"rate_limit_error","message":"Upstream RPM exceeded."}}"#.into(),
        },
    ]);

    let model = gateway_model();
    let provider = OpenAiCompatibleProvider::new(OpenAiCompatibleConfig::new(
        base_url,
        "cgc_terminal_token",
        vec![model.clone()],
    ));

    // 1. HTTP 402 → InsufficientQuota（禁止自动重试）
    let err_402 = collect_events(&provider, &model, Request::new(vec![Message::user("1")]))
        .into_iter()
        .next()
        .expect("402 event")
        .unwrap_err();
    assert!(matches!(
        &err_402,
        ProviderError::InsufficientQuota { message } if message.contains("Insufficient LLM credits")
    ));
    assert!(!err_402.is_retryable());

    // 2. SSE 402 frame → InsufficientQuota（禁止自动重试）
    let sse_402 = collect_events(&provider, &model, Request::new(vec![Message::user("2")]))
        .into_iter()
        .next()
        .expect("sse 402")
        .unwrap_err();
    assert!(sse_402.is_insufficient_quota());
    assert!(!sse_402.is_retryable());

    // 3. HTTP 429 concurrency_limit_exceeded → ConcurrencyLimitExceeded
    let err_429 = collect_events(&provider, &model, Request::new(vec![Message::user("3")]))
        .into_iter()
        .next()
        .expect("429 concurrency")
        .unwrap_err();
    assert!(matches!(
        &err_429,
        ProviderError::ConcurrencyLimitExceeded { message } if message.contains("Too many concurrent")
    ));
    assert!(err_429.is_concurrency_limit_exceeded());
    assert!(!err_429.is_retryable());

    // 4. SSE 429 concurrency_limit_exceeded → ConcurrencyLimitExceeded
    let sse_429 = collect_events(&provider, &model, Request::new(vec![Message::user("4")]))
        .into_iter()
        .next()
        .expect("sse 429 concurrency")
        .unwrap_err();
    assert!(sse_429.is_concurrency_limit_exceeded());

    // 5. 普通上游 429 保持原有可重试语义不变
    let generic_429 = collect_events(&provider, &model, Request::new(vec![Message::user("5")]))
        .into_iter()
        .next()
        .expect("generic 429")
        .unwrap_err();
    assert_eq!(generic_429.category(), ProviderErrorCategory::RateLimit);
    assert!(generic_429.is_retryable());
}

#[test]
fn wire_history_strips_reasoning_content_on_assistant_turns() {
    let (base_url, captured) = spawn_mock_gateway(vec![MockHttpReply {
        status: 200,
        content_type: "text/event-stream",
        body: "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n".into(),
    }]);
    let model = gateway_model();
    let provider = OpenAiCompatibleProvider::new(OpenAiCompatibleConfig::new(
        base_url,
        "cgc_terminal_token",
        vec![model.clone()],
    ));

    let request = Request::new(vec![
        Message::user("第一轮问题"),
        Message::new(
            Role::Assistant,
            vec![
                Content::Thinking {
                    text: "上一轮内部思考".into(),
                    signature: String::new(),
                },
                Content::Text("上一轮结论".into()),
                Content::ToolUse(ToolUse {
                    id: "call_1".into(),
                    name: "read_file".into(),
                    args: serde_json::json!({"path": "README.md"}),
                }),
            ],
        ),
        Message::tool_result("call_1", "文件内容", false),
        Message::user("继续分析"),
    ]);

    let events = collect_events(&provider, &model, request);
    assert!(events.iter().all(Result::is_ok));

    let raw_http = captured.recv().expect("captured request");
    let (_, json_body) = raw_http.split_once("\r\n\r\n").expect("http body");
    assert!(!json_body.contains("reasoning_content"));
    assert!(!json_body.contains("上一轮内部思考"));
    let parsed: serde_json::Value = serde_json::from_str(json_body).expect("json body");
    assert_eq!(parsed["messages"][1]["role"], "assistant");
    assert_eq!(parsed["messages"][1]["content"], "上一轮结论");
    assert_eq!(
        parsed["messages"][1]["tool_calls"][0]["function"]["name"],
        "read_file"
    );
}

#[test]
fn build_body_includes_reasoning_content_after_last_user_and_strips_before() {
    let model = gateway_model();
    let request = Request::new(vec![
        Message::user("第一轮问题"),
        Message::new(
            Role::Assistant,
            vec![
                Content::Thinking {
                    text: "第一轮思考".into(),
                    signature: String::new(),
                },
                Content::Text("第一轮结论".into()),
            ],
        ),
        Message::user("第二轮问题"),
        Message::new(
            Role::Assistant,
            vec![
                Content::Thinking {
                    text: "第二轮步骤一思考".into(),
                    signature: String::new(),
                },
                Content::Text("正在读文件".into()),
                Content::ToolUse(ToolUse {
                    id: "call_2".into(),
                    name: "read_file".into(),
                    args: serde_json::json!({"path": "Cargo.toml"}),
                }),
            ],
        ),
        Message::tool_result("call_2", "Cargo.toml 内容", false),
    ]);

    let body = build_body(&model, &request);
    assert!(
        body["messages"][1].get("reasoning_content").is_none(),
        "assistant message before last Role::User must strip reasoning_content"
    );
    assert_eq!(body["messages"][1]["content"], "第一轮结论");

    assert_eq!(
        body["messages"][3]["reasoning_content"], "第二轮步骤一思考",
        "assistant message after last Role::User must replay reasoning_content"
    );
    assert_eq!(body["messages"][3]["content"], "正在读文件");
    assert_eq!(
        body["messages"][3]["tool_calls"][0]["function"]["name"],
        "read_file"
    );
}
