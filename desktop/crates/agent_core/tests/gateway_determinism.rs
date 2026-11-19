use std::io::{Read, Write};
use std::net::TcpListener;
use std::sync::mpsc;

use cgc_agent_core::{Agent, AutoApprover, Entry, SelectedModel, Thread};
use cgc_agent_provider::{
    Model, ModelCapabilities, ModelId, ModelLimits, OpenAiCompatibleConfig,
    OpenAiCompatibleProvider, ProviderId,
};
use cgc_agent_tools::{SandboxPolicy, ToolContext, ToolRegistry};

struct CapturedRequest {
    headers: String,
    body: String,
}

fn spawn_sse_gateway(sse_replies: Vec<String>) -> (String, mpsc::Receiver<CapturedRequest>) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind mock gateway");
    let addr = listener.local_addr().expect("local addr");
    let (sender, receiver) = mpsc::channel();
    std::thread::spawn(move || {
        for body in sse_replies {
            let Ok((mut stream, _)) = listener.accept() else {
                break;
            };
            let mut raw = Vec::new();
            let mut buf = [0u8; 4096];
            let header_end = loop {
                let read = stream.read(&mut buf).expect("read headers");
                if read == 0 {
                    break raw.len();
                }
                raw.extend_from_slice(&buf[..read]);
                if let Some(pos) = raw.windows(4).position(|w| w == b"\r\n\r\n") {
                    break pos + 4;
                }
            };
            let headers = String::from_utf8_lossy(&raw[..header_end]).to_string();
            let content_length = headers
                .lines()
                .find_map(|line| {
                    let (name, value) = line.split_once(':')?;
                    name.eq_ignore_ascii_case("content-length")
                        .then(|| value.trim().parse::<usize>().ok())
                        .flatten()
                })
                .unwrap_or(0);
            while raw.len() < header_end + content_length {
                let read = stream.read(&mut buf).expect("read body");
                if read == 0 {
                    break;
                }
                raw.extend_from_slice(&buf[..read]);
            }
            let body_str = String::from_utf8_lossy(&raw[header_end..]).to_string();
            let _ = sender.send(CapturedRequest {
                headers,
                body: body_str,
            });
            let response = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                body.len(),
                body
            );
            let _ = stream.write_all(response.as_bytes());
            let _ = stream.flush();
        }
    });
    (format!("http://{addr}/v1"), receiver)
}

fn temp_workspace(tag: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "cgc-gateway-determinism-{tag}-{}",
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("create workspace");
    dir
}

#[test]
fn tool_loop_keeps_session_affinity_strips_reasoning_and_preserves_prefix_bytes() {
    let workspace = temp_workspace("tool-loop");
    std::fs::write(workspace.join("hello.txt"), "gateway-content\n").expect("write file");

    let step1_sse = concat!(
        "data: {\"id\":\"cmpl-1\",\"choices\":[{\"delta\":{\"reasoning_content\":\"先检查 hello.txt\"}}]}\n\n",
        "data: {\"choices\":[{\"delta\":{\"content\":\"正在读取文件\"}}]}\n\n",
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{\\\"path\\\":\\\"hello.txt\\\"}\"}}]},\"finish_reason\":\"tool_calls\"}]}\n\n",
        "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":100,\"completion_tokens\":20,\"prompt_cache_hit_tokens\":80}}\n\n",
        "data: [DONE]\n\n"
    )
    .to_string();
    let step2_sse = concat!(
        "data: {\"id\":\"cmpl-2\",\"choices\":[{\"delta\":{\"reasoning_content\":\"已拿到文件内容\"}}]}\n\n",
        "data: {\"choices\":[{\"delta\":{\"content\":\"文件里写着 gateway-content。\"},\"finish_reason\":\"stop\"}]}\n\n",
        "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":140,\"completion_tokens\":15,\"prompt_cache_hit_tokens\":110}}\n\n",
        "data: [DONE]\n\n"
    )
    .to_string();
    let step3_sse = concat!(
        "data: {\"id\":\"cmpl-3\",\"choices\":[{\"delta\":{\"reasoning_content\":\"第二轮再思考\"}}]}\n\n",
        "data: {\"choices\":[{\"delta\":{\"content\":\"第二轮回复完成。\"},\"finish_reason\":\"stop\"}]}\n\n",
        "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":160,\"completion_tokens\":10,\"prompt_cache_hit_tokens\":120}}\n\n",
        "data: [DONE]\n\n"
    )
    .to_string();

    let (base_url, captured) = spawn_sse_gateway(vec![step1_sse, step2_sse, step3_sse]);
    let model = Model::new(
        ProviderId::new("cgc-cloud"),
        "CGC Cloud",
        "cgc-reasoning",
        "CGC Reasoning",
        ModelLimits::new(64_000, 4_096),
    )
    .with_capabilities(ModelCapabilities {
        tools: true,
        images: false,
        thinking: true,
    });
    let provider = OpenAiCompatibleProvider::new(OpenAiCompatibleConfig::new(
        base_url,
        "cgc_terminal_token",
        vec![model.clone()],
    ));

    let thread = Thread::new(
        "native-session-affinity-001",
        SelectedModel::new(ProviderId::new("cgc-cloud"), ModelId::new("cgc-reasoning")),
    );
    let system_prompt = "你运行在用户的本地工作区。当前日期：2026-11-18".to_string();
    let mut agent = Agent::new(thread, Some(system_prompt));
    agent.set_thinking_enabled(true);

    let tools = ToolRegistry::with_builtin_tools().with_app_actions();
    let context = ToolContext::new(&workspace).with_sandbox(SandboxPolicy::new(&workspace));

    let outcome = futures::executor::block_on(agent.prompt_with_tools(
        &provider,
        &model,
        "读一下 hello.txt",
        &tools,
        &context,
        &AutoApprover,
    ))
    .expect("tool loop succeeds");

    assert!(outcome.text.contains("gateway-content"));
    assert_eq!(outcome.usage.cache_read, 190);

    // 线程内记录了两段 Thinking 且都带有非零耗时统计。
    let thinking_durations: Vec<Option<u64>> = agent
        .thread()
        .entries
        .iter()
        .filter_map(|entry| match entry {
            Entry::Thinking { duration_ms, .. } => Some(*duration_ms),
            _ => None,
        })
        .collect();
    assert_eq!(thinking_durations.len(), 2);
    assert!(thinking_durations
        .iter()
        .all(|duration| duration.is_some_and(|ms| ms >= 1)));

    let first = captured.recv().expect("step 1 request");
    let second = captured.recv().expect("step 2 request");

    // 1. 同一会话的 tool_loop 两轮请求携带完全相同的 x-session-affinity。
    assert!(first
        .headers
        .to_ascii_lowercase()
        .contains("x-session-affinity: native-session-affinity-001\r\n"));
    assert!(second
        .headers
        .to_ascii_lowercase()
        .contains("x-session-affinity: native-session-affinity-001\r\n"));

    let req1: serde_json::Value = serde_json::from_str(&first.body).expect("json 1");
    let req2: serde_json::Value = serde_json::from_str(&second.body).expect("json 2");

    // 2. 同一用户轮次内的 tool_loop（step 1 -> step 2）必须回传 assistant 的 reasoning_content。
    let assistant_with_tool_call = req2["messages"]
        .as_array()
        .expect("req2 messages array")
        .iter()
        .find(|msg| msg["role"] == "assistant" && msg.get("tool_calls").is_some())
        .expect("assistant message with tool_calls in step 2");
    assert_eq!(
        assistant_with_tool_call["reasoning_content"], "先检查 hello.txt",
        "same-turn tool loop must replay reasoning_content on assistant tool_calls message"
    );

    // 3. System Prompt 与 tools 数组的 JSON 字节序列连续两次完全一致，且 tools 字典序固定。
    assert_eq!(
        serde_json::to_vec(&req1["messages"][0]).expect("sys 1"),
        serde_json::to_vec(&req2["messages"][0]).expect("sys 2"),
        "system prompt JSON bytes must be identical across requests in the same session"
    );
    assert_eq!(
        serde_json::to_vec(&req1["tools"]).expect("tools 1"),
        serde_json::to_vec(&req2["tools"]).expect("tools 2"),
        "tools JSON bytes must be identical across requests in the same session"
    );

    // 4. 开启第二个用户轮次：step 3 必须剥离上一用户轮次所有 assistant 的 reasoning_content，
    //    同时保持 system prompt 与 tools 字节序列 100% 一致。
    let second_turn = futures::executor::block_on(agent.prompt_with_tools(
        &provider,
        &model,
        "再总结一下刚才的结果",
        &tools,
        &context,
        &AutoApprover,
    ))
    .expect("second user turn succeeds");
    assert!(second_turn.text.contains("第二轮回复完成"));

    let third = captured.recv().expect("step 3 request");
    assert!(third
        .headers
        .to_ascii_lowercase()
        .contains("x-session-affinity: native-session-affinity-001\r\n"));
    assert!(
        !third.body.contains("reasoning_content"),
        "next user turn must strip reasoning_content from previous turn assistant messages"
    );
    assert!(!third.body.contains("先检查 hello.txt"));
    assert!(!third.body.contains("已拿到文件内容"));

    let req3: serde_json::Value = serde_json::from_str(&third.body).expect("json 3");
    assert_eq!(
        serde_json::to_vec(&req1["messages"][0]).expect("sys 1"),
        serde_json::to_vec(&req3["messages"][0]).expect("sys 3"),
        "system prompt JSON bytes must stay identical across user turns"
    );
    assert_eq!(
        serde_json::to_vec(&req1["tools"]).expect("tools 1"),
        serde_json::to_vec(&req3["tools"]).expect("tools 3"),
        "tools JSON bytes must stay identical across user turns"
    );

    let tool_names: Vec<&str> = req1["tools"]
        .as_array()
        .expect("tools array")
        .iter()
        .map(|tool| {
            tool["function"]["name"]
                .as_str()
                .expect("tool function name")
        })
        .collect();
    let mut sorted = tool_names.clone();
    sorted.sort_unstable();
    assert_eq!(
        tool_names, sorted,
        "tools must be sorted lexicographically by name"
    );

    let _ = std::fs::remove_dir_all(&workspace);
}

#[test]
fn compaction_uses_background_logical_model_and_preserves_session_affinity() {
    let compaction_sse = concat!(
        "data: {\"choices\":[{\"delta\":{\"content\":\"早期对话摘要\"},\"finish_reason\":\"stop\"}]}\n\n",
        "data: [DONE]\n\n"
    )
    .to_string();
    let turn_sse = concat!(
        "data: {\"choices\":[{\"delta\":{\"content\":\"主模型回复\"},\"finish_reason\":\"stop\"}]}\n\n",
        "data: [DONE]\n\n"
    )
    .to_string();

    let (base_url, captured) = spawn_sse_gateway(vec![compaction_sse, turn_sse]);
    let default_model = Model::new(
        ProviderId::new("cgc-cloud"),
        "CGC Cloud",
        "cgc-default",
        "CGC Default",
        // 窄窗口触发自动前缀压缩（capacity = 260 - 64 - 32 = 164 tokens）。
        ModelLimits::new(260, 64),
    );
    let background_model = Model::new(
        ProviderId::new("cgc-cloud"),
        "CGC Cloud",
        "cgc-background",
        "CGC Background",
        ModelLimits::new(8_000, 1_024),
    );
    let provider = OpenAiCompatibleProvider::new(OpenAiCompatibleConfig::new(
        base_url,
        "cgc_terminal_token",
        vec![default_model.clone(), background_model.clone()],
    ));

    let mut thread = Thread::new(
        "native-compaction-session",
        SelectedModel::new(ProviderId::new("cgc-cloud"), ModelId::new("cgc-default")),
    );
    thread.push_user("第一轮长历史：".to_string() + &"甲乙丙丁戊己庚辛".repeat(16));
    thread.push_assistant(
        "第一轮长回复：".to_string() + &"子丑寅卯辰巳午未".repeat(16),
        Vec::new(),
        None,
    );

    let mut agent = Agent::new(thread, None);
    agent.set_background_model(Some(background_model));

    let outcome =
        futures::executor::block_on(agent.prompt(&provider, &default_model, "当前简短问题"))
            .expect("prompt with compaction");
    assert_eq!(outcome.text, "主模型回复");

    let summary_req = captured.recv().expect("compaction request");
    let main_req = captured.recv().expect("main request");

    assert!(summary_req
        .headers
        .to_ascii_lowercase()
        .contains("x-session-affinity: native-compaction-session\r\n"));
    assert!(main_req
        .headers
        .to_ascii_lowercase()
        .contains("x-session-affinity: native-compaction-session\r\n"));

    let summary_json: serde_json::Value =
        serde_json::from_str(&summary_req.body).expect("summary body");
    let main_json: serde_json::Value = serde_json::from_str(&main_req.body).expect("main body");
    assert_eq!(summary_json["model"], "cgc-background");
    assert_eq!(main_json["model"], "cgc-default");
}
