//! 真实 Responses 端点的手动联调测试（默认 ignore）。
//!
//! 运行：
//! ```text
//! MAGPIE_BASE_URL=http://127.0.0.1:3425/v1 MAGPIE_API_KEY=magpie \
//!   cargo test -p cgc-agent-provider --test responses_live -- --ignored --nocapture
//! ```
//! 建议运行时清掉 SOCKS 代理环境变量，避免本地请求被代理拦截。

use cgc_agent_provider::{
    CompletionEvent, Message, Model, ModelLimits, Provider, ProviderId, Request,
    ResponsesCompatibleConfig, ResponsesCompatibleProvider,
};

#[test]
#[ignore = "needs a live Responses endpoint (MAGPIE_BASE_URL / MAGPIE_API_KEY)"]
fn responses_streams_text_from_a_live_endpoint() {
    let base_url = std::env::var("MAGPIE_BASE_URL").expect("MAGPIE_BASE_URL");
    let api_key = std::env::var("MAGPIE_API_KEY").expect("MAGPIE_API_KEY");
    let model = Model::new(
        ProviderId::new("magpie"),
        "Magpie",
        "auto/deepseek-v4.1-flash",
        "DeepSeek V4.1 Flash",
        ModelLimits::new(1_048_576, 384_000),
    );
    let provider = ResponsesCompatibleProvider::new(ResponsesCompatibleConfig::new(
        base_url,
        api_key,
        vec![model.clone()],
    ));
    let request = Request::new(vec![Message::user("ping")]).with_max_output_tokens(32);
    let mut stream = futures::executor::block_on(provider.stream(&model, request))
        .expect("open responses stream");

    let mut text = String::new();
    let mut stopped = false;
    while let Some(event) = futures::executor::block_on(futures::StreamExt::next(&mut stream)) {
        match event.expect("stream event") {
            CompletionEvent::Text(delta) => text.push_str(&delta),
            CompletionEvent::Stop(_) => {
                stopped = true;
                break;
            }
            _ => {}
        }
    }
    assert!(stopped, "stream should end with Stop");
    assert!(!text.trim().is_empty(), "reply text should not be empty");
    println!("reply: {text}");
}

#[test]
#[ignore = "needs a live Responses endpoint (MAGPIE_BASE_URL / MAGPIE_API_KEY)"]
fn responses_returns_a_function_call() {
    use cgc_agent_provider::{ToolSchema, ToolUse};
    let base_url = std::env::var("MAGPIE_BASE_URL").expect("MAGPIE_BASE_URL");
    let api_key = std::env::var("MAGPIE_API_KEY").expect("MAGPIE_API_KEY");
    let model = Model::new(
        ProviderId::new("magpie"),
        "Magpie",
        "auto/deepseek-v4.1-flash",
        "DeepSeek V4.1 Flash",
        ModelLimits::new(1_048_576, 384_000),
    );
    let provider = ResponsesCompatibleProvider::new(ResponsesCompatibleConfig::new(
        base_url,
        api_key,
        vec![model.clone()],
    ));
    let tool = ToolSchema::new(
        "read_file",
        "Read a file from disk",
        serde_json::json!({
            "type": "object",
            "properties": { "path": { "type": "string" } },
            "required": ["path"]
        }),
    );
    let request = Request::new(vec![Message::user(
        "Call the read_file tool with path 'a.txt'. Do not answer in text.",
    )])
    .with_tools(vec![tool])
    .with_max_output_tokens(128);
    let mut stream = futures::executor::block_on(provider.stream(&model, request))
        .expect("open responses stream");
    let mut call: Option<ToolUse> = None;
    while let Some(event) = futures::executor::block_on(futures::StreamExt::next(&mut stream)) {
        if let CompletionEvent::ToolUse(tool_use) = event.expect("stream event") {
            call = Some(tool_use);
        }
    }
    let call = call.expect("model should call read_file");
    assert_eq!(call.name, "read_file");
    assert_eq!(call.args["path"], "a.txt");
    println!("tool: {} {}", call.name, call.args);
}

#[test]
#[ignore = "needs a live Responses endpoint (MAGPIE_BASE_URL / MAGPIE_API_KEY)"]
fn responses_accepts_a_function_call_output() {
    use cgc_agent_provider::{Content, Role, ToolSchema, ToolUse};
    let base_url = std::env::var("MAGPIE_BASE_URL").expect("MAGPIE_BASE_URL");
    let api_key = std::env::var("MAGPIE_API_KEY").expect("MAGPIE_API_KEY");
    let model = Model::new(
        ProviderId::new("magpie"),
        "Magpie",
        "auto/deepseek-v4.1-flash",
        "DeepSeek V4.1 Flash",
        ModelLimits::new(1_048_576, 384_000),
    );
    let provider = ResponsesCompatibleProvider::new(ResponsesCompatibleConfig::new(
        base_url,
        api_key,
        vec![model.clone()],
    ));
    let tool = ToolSchema::new(
        "read_file",
        "Read a file from disk",
        serde_json::json!({
            "type": "object",
            "properties": { "path": { "type": "string" } },
            "required": ["path"]
        }),
    );
    let messages = vec![
        Message::user("Call the read_file tool with path 'a.txt'. Do not answer in text."),
        Message::new(
            Role::Assistant,
            vec![Content::ToolUse(ToolUse {
                id: "call_probe".to_string(),
                name: "read_file".to_string(),
                args: serde_json::json!({ "path": "a.txt" }),
            })],
        ),
        Message::tool_result("call_probe", "the file says: hello from a.txt", false),
    ];
    let request = Request::new(messages)
        .with_tools(vec![tool])
        .with_max_output_tokens(64);
    let mut stream = futures::executor::block_on(provider.stream(&model, request))
        .expect("open responses stream");
    let mut text = String::new();
    while let Some(event) = futures::executor::block_on(futures::StreamExt::next(&mut stream)) {
        if let CompletionEvent::Text(delta) = event.expect("stream event") {
            text.push_str(&delta);
        }
    }
    assert!(!text.trim().is_empty(), "reply text should not be empty");
    println!("round-2 reply: {text}");
}
