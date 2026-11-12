//! P2 e2e：真实 openma 0.4.41 ACP adapter + 本地 Anthropic Messages mock。
//!
//! 默认只在设置了 `CGC_DSH_ACP_BIN`（或 `CGC_DSH_ACP_PACKAGE_DIR`）时执行，避免 CI
//! 没有 167MB 内置运行时的机器上失败；验证时：
//!
//! ```bash
//! CGC_DSH_ACP_BIN=/path/to/@openma/deepseek-harness-acp/dist/bin.js \
//!   cargo test -p cgc-desktop-app --test dsh_acp_real_e2e -- --nocapture
//! ```
//!
//! mock 走 Anthropic Messages streaming（adapter 0.4.41 的 DeepSeek route 使用
//! `/v1/messages`），场景 `TOOL_FULL` 依次产生 todo_write、普通 write、带
//! `sandbox_permissions` 的 write 重试，从而覆盖工具、计划、审批、用量与 title。

use std::collections::BTreeMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{SocketAddr, TcpListener};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use cgc_agent_ui::conversation::{ConversationThread, ThreadCapabilities};
use cgc_desktop_app::agent_ingest::apply_thread_event;
use cgc_platform::acp::connection::{AcpHost, AcpHostConfig, HostEvent};
use cgc_platform::agent::launch::LaunchPlan;

// ---------------------------------------------------------------------------
// mock Anthropic Messages endpoint
// ---------------------------------------------------------------------------

struct MockLlm {
    addr: SocketAddr,
    requests: Arc<std::sync::Mutex<Vec<String>>>,
    stop: Arc<AtomicBool>,
}

impl MockLlm {
    fn start(file_path: PathBuf) -> Self {
        Self::start_with(file_path, false, false)
    }

    fn start_text_only(file_path: PathBuf) -> Self {
        Self::start_with(file_path, true, false)
    }

    fn start_slow_text(file_path: PathBuf) -> Self {
        Self::start_with(file_path, true, true)
    }

    fn start_with(file_path: PathBuf, text_only: bool, slow_text: bool) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind mock llm");
        listener
            .set_nonblocking(true)
            .expect("nonblocking mock llm");
        let addr = listener.local_addr().expect("mock llm addr");
        let requests = Arc::new(std::sync::Mutex::new(Vec::new()));
        let stop = Arc::new(AtomicBool::new(false));
        let requests_for_thread = Arc::clone(&requests);
        let stop_for_thread = Arc::clone(&stop);
        std::thread::spawn(move || {
            while !stop_for_thread.load(Ordering::Relaxed) {
                match listener.accept() {
                    Ok((stream, _)) => {
                        let requests = Arc::clone(&requests_for_thread);
                        let file_path = file_path.clone();
                        std::thread::spawn(move || {
                            let _ = handle_connection(
                                stream, &requests, &file_path, text_only, slow_text,
                            );
                        });
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        std::thread::sleep(Duration::from_millis(20));
                    }
                    Err(_) => break,
                }
            }
        });
        Self {
            addr,
            requests,
            stop,
        }
    }

    fn request_count(&self) -> usize {
        self.requests.lock().expect("requests").len()
    }
}

impl Drop for MockLlm {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
    }
}

fn handle_connection(
    mut stream: std::net::TcpStream,
    requests: &std::sync::Mutex<Vec<String>>,
    file_path: &Path,
    text_only: bool,
    slow_text: bool,
) -> std::io::Result<()> {
    let mut reader = BufReader::new(stream.try_clone()?);
    let mut request_line = String::new();
    reader.read_line(&mut request_line)?;
    if !request_line.starts_with("POST ") {
        return Ok(());
    }
    let mut content_length = 0usize;
    loop {
        let mut line = String::new();
        reader.read_line(&mut line)?;
        if line == "\r\n" || line.is_empty() {
            break;
        }
        if let Some(value) = line.to_ascii_lowercase().strip_prefix("content-length:") {
            content_length = value.trim().parse().unwrap_or(0);
        }
    }
    let mut body = vec![0u8; content_length];
    reader.read_exact(&mut body)?;
    let body = String::from_utf8_lossy(&body).to_string();
    requests.lock().expect("requests").push(body.clone());
    if slow_text {
        let headers = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n";
        stream.write_all(headers.as_bytes())?;
        stream.write_all(
            sse(
                "message_start",
                serde_json::json!({
                    "type":"message_start",
                    "message":{"id":"msg_slow","type":"message","role":"assistant","content":[],
                        "model":"deepseek-flash","stop_reason":null,"stop_sequence":null,
                        "usage":{"input_tokens":10,"output_tokens":0}}
                }),
            )
            .as_bytes(),
        )?;
        stream.write_all(
            sse(
                "content_block_start",
                serde_json::json!({
                    "type":"content_block_start","index":0,
                    "content_block":{"type":"text","text":""}
                }),
            )
            .as_bytes(),
        )?;
        for index in 0..200 {
            let delta = sse(
                "content_block_delta",
                serde_json::json!({
                    "type":"content_block_delta","index":0,
                    "delta":{"type":"text_delta","text":format!("chunk-{index} ")}
                }),
            );
            if stream.write_all(delta.as_bytes()).is_err() {
                break;
            }
            stream.flush()?;
            std::thread::sleep(Duration::from_millis(100));
        }
        return Ok(());
    }
    let (content_type, payload) = if !text_only && body.contains("\"tools\":") {
        scenario_response(&body, file_path)
    } else {
        (
            "text/event-stream",
            text_message_stream("你好，这是 mock 回复。"),
        )
    };
    let response = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        payload.len()
    );
    stream.write_all(response.as_bytes())?;
    stream.write_all(payload.as_bytes())?;
    stream.flush()
}

fn scenario_response(body: &str, file_path: &Path) -> (&'static str, String) {
    let results = body.matches("\"type\":\"tool_result\"").count()
        + body.matches("\"type\": \"tool_result\"").count();
    let file_path = serde_json::json!(file_path.to_string_lossy());
    let content = if results == 0 {
        tool_use_stream(
            "todo_write",
            serde_json::json!({"todos":[
                {"content":"检查环境","status":"in_progress"},
                {"content":"写文件","status":"pending"}
            ]}),
        )
    } else if results == 1 {
        tool_use_stream(
            "write",
            serde_json::json!({"file_path": file_path, "content":"hello from mock"}),
        )
    } else if results == 2 {
        tool_use_stream(
            "write",
            serde_json::json!({
                "file_path": file_path,
                "content": "hello from mock",
                "sandbox_permissions": "workspace-write",
                "justification": "need to write the fixture file"
            }),
        )
    } else {
        text_message_stream("你好，这是 mock 回复。")
    };
    ("text/event-stream", content)
}

fn sse(event: &str, payload: serde_json::Value) -> String {
    format!("event: {event}\ndata: {payload}\n\n")
}

fn text_message_stream(text: &str) -> String {
    let mut out = String::new();
    out.push_str(&sse(
        "message_start",
        serde_json::json!({
            "type":"message_start",
            "message":{"id":"msg_mock","type":"message","role":"assistant","content":[],
                "model":"deepseek-flash","stop_reason":null,"stop_sequence":null,
                "usage":{"input_tokens":11,"output_tokens":0}}
        }),
    ));
    out.push_str(&sse(
        "content_block_start",
        serde_json::json!({"type":"content_block_start","index":0,
            "content_block":{"type":"text","text":""}}),
    ));
    for chunk in text.chars().collect::<Vec<_>>().chunks(4) {
        let text: String = chunk.iter().collect();
        out.push_str(&sse(
            "content_block_delta",
            serde_json::json!({"type":"content_block_delta","index":0,
                "delta":{"type":"text_delta","text":text}}),
        ));
    }
    out.push_str(&sse(
        "content_block_stop",
        serde_json::json!({"type":"content_block_stop","index":0}),
    ));
    out.push_str(&sse(
        "message_delta",
        serde_json::json!({"type":"message_delta",
            "delta":{"stop_reason":"end_turn","stop_sequence":null},
            "usage":{"output_tokens":5}}),
    ));
    out.push_str(&sse(
        "message_stop",
        serde_json::json!({"type":"message_stop"}),
    ));
    out
}

fn tool_use_stream(name: &str, input: serde_json::Value) -> String {
    let mut out = String::new();
    out.push_str(&sse(
        "message_start",
        serde_json::json!({
            "type":"message_start",
            "message":{"id":"msg_tool","type":"message","role":"assistant","content":[],
                "model":"deepseek-flash","stop_reason":null,"stop_sequence":null,
                "usage":{"input_tokens":10,"output_tokens":1}}
        }),
    ));
    out.push_str(&sse(
        "content_block_start",
        serde_json::json!({"type":"content_block_start","index":0,
            "content_block":{"type":"tool_use","id":"toolu_mock_1","name":name,"input":{}}}),
    ));
    out.push_str(&sse(
        "content_block_delta",
        serde_json::json!({"type":"content_block_delta","index":0,
            "delta":{"type":"input_json_delta","partial_json":input.to_string()}}),
    ));
    out.push_str(&sse(
        "content_block_stop",
        serde_json::json!({"type":"content_block_stop","index":0}),
    ));
    out.push_str(&sse(
        "message_delta",
        serde_json::json!({"type":"message_delta",
            "delta":{"stop_reason":"tool_use","stop_sequence":null},
            "usage":{"output_tokens":8}}),
    ));
    out.push_str(&sse(
        "message_stop",
        serde_json::json!({"type":"message_stop"}),
    ));
    out
}

// ---------------------------------------------------------------------------
// real openma adapter e2e
// ---------------------------------------------------------------------------

fn temp_dir(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "cgc-dsh-e2e-{}-{tag}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("temp dir");
    dir
}

fn adapter_bin() -> Option<PathBuf> {
    std::env::var_os("CGC_DSH_ACP_BIN")
        .map(PathBuf::from)
        .or_else(|| {
            std::env::var_os("CGC_DSH_ACP_PACKAGE_DIR")
                .map(PathBuf::from)
                .map(|dir| dir.join("dist/bin.js"))
        })
}

#[test]
fn real_openma_0_4_41_full_conversation() {
    let Some(adapter) = adapter_bin() else {
        eprintln!(
            "skip dsh_acp_real_e2e: set CGC_DSH_ACP_BIN to @openma/deepseek-harness-acp/dist/bin.js"
        );
        return;
    };
    let node = std::env::var_os("CGC_DSH_ACP_NODE")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("node"));
    let root = temp_dir("real");
    let cache = root.join("cache");
    let dsh_home = root.join("dsh-home");
    let cwd = root.join("workspace");
    std::fs::create_dir_all(&cache).expect("cache");
    std::fs::create_dir_all(&dsh_home).expect("dsh home");
    std::fs::create_dir_all(&cwd).expect("workspace");
    let output = cwd.join("mock-output.txt");
    let mock = MockLlm::start(output.clone());
    let mut env = BTreeMap::new();
    for key in [
        "PATH",
        "HOME",
        "LANG",
        "TERM",
        "HTTP_PROXY",
        "HTTPS_PROXY",
        "NO_PROXY",
    ] {
        if let Ok(value) = std::env::var(key) {
            env.insert(key.to_string(), value);
        }
    }
    env.insert(
        "XDG_CACHE_HOME".into(),
        cache.to_string_lossy().into_owned(),
    );
    env.insert("DSH_HOME".into(), dsh_home.to_string_lossy().into_owned());
    env.insert("DEEPSEEK_API_KEY".into(), "sk-mock".into());
    env.insert("DEEPSEEK_BASE_URL".into(), format!("http://{}", mock.addr));
    let plan = LaunchPlan {
        program: node,
        args: vec![
            adapter.to_string_lossy().into_owned(),
            "--permission-mode".to_string(),
            "read-only".to_string(),
        ],
        env,
        cwd: cwd.clone(),
    };
    let host = AcpHost::start(AcpHostConfig::from_launch_plan(plan).with_name("dsh"))
        .expect("start dsh adapter");

    let mut configs = Vec::new();
    let mut commands = Vec::new();
    let mut ready = false;
    let mut saw_configs = false;
    let mut saw_commands = false;
    let deadline = Instant::now() + Duration::from_secs(240);
    while Instant::now() < deadline {
        let Some(event) = host.recv_timeout(Duration::from_millis(200)) else {
            continue;
        };
        match &event {
            HostEvent::Ready { version, .. } => {
                assert_eq!(version, "0.4.41");
                ready = true;
            }
            HostEvent::ConfigOptions { options } => {
                configs = options.clone();
                saw_configs = true;
            }
            HostEvent::AvailableCommands { commands: list } => {
                commands = list.clone();
                saw_commands = true;
            }
            HostEvent::Error { message } => panic!("dsh adapter failed before prompt: {message}"),
            HostEvent::Exited => panic!("dsh adapter exited before prompt"),
            _ => {}
        }
        if ready && saw_configs && saw_commands {
            break;
        }
    }
    assert!(ready, "dsh adapter did not become ready");
    assert!(!commands.is_empty(), "available_commands missing");
    assert!(
        configs.iter().any(|config| config.id == "mode"),
        "config_option_update/session config missing: {configs:?}"
    );

    assert!(host.prompt("TOOL_FULL 请更新计划、写文件并汇报"));
    let mut thread = ConversationThread::new("acp").with_capabilities(ThreadCapabilities::acp());
    let mut saw_delta = false;
    let mut saw_plan = false;
    let mut saw_permission = false;
    let mut saw_usage = false;
    let mut saw_title = false;
    let mut saw_diff = false;
    let mut saw_location = false;
    let mut turn_end = false;
    let deadline = Instant::now() + Duration::from_secs(240);
    while Instant::now() < deadline {
        let Some(event) = host.recv_timeout(Duration::from_millis(200)) else {
            continue;
        };
        if let HostEvent::PermissionRequested {
            request_id,
            options,
            ..
        } = &event
        {
            saw_permission = true;
            let option_id = options
                .iter()
                .find(|option| option.kind == "allow_once")
                .or_else(|| options.first())
                .map(|option| option.option_id.clone())
                .expect("permission option");
            assert!(host.respond_permission_option(request_id, option_id));
        }
        match &event {
            HostEvent::Delta(text) => saw_delta |= !text.is_empty(),
            HostEvent::PlanUpdated { steps } => saw_plan |= !steps.is_empty(),
            HostEvent::UsageUpdated { used, .. } => saw_usage |= *used > 0,
            HostEvent::TitleUpdated { title } => saw_title |= title.is_some(),
            HostEvent::ToolCallUpdated {
                output, locations, ..
            } => {
                saw_diff |= output.as_deref().is_some_and(|output| {
                    output.contains("+++ new") && output.contains("hello from mock")
                });
                saw_location |= locations.as_deref().is_some_and(|locations| {
                    locations.iter().any(|l| l.ends_with("mock-output.txt"))
                });
            }
            HostEvent::TurnEnd { cancelled, .. } => {
                assert!(!cancelled, "turn was unexpectedly cancelled");
                turn_end = true;
            }
            HostEvent::Error { message } => panic!("dsh turn failed: {message}"),
            _ => {}
        }
        apply_thread_event(&mut thread, &event);
        if turn_end {
            break;
        }
    }
    host.shutdown();
    assert!(turn_end, "turn did not finish");
    assert!(saw_delta, "streaming delta missing");
    assert!(saw_plan, "todo_write → Plan mapping missing");
    assert!(saw_permission, "session/request_permission missing");
    assert!(saw_usage, "usage_update missing");
    assert!(saw_title, "session_info_update/title missing");
    assert!(saw_diff, "tool diff content missing: {thread:?}");
    assert!(saw_location, "tool location missing");
    assert!(
        mock.request_count() >= 3,
        "expected title + tool turns, got {} requests",
        mock.request_count()
    );
    assert!(
        thread
            .title
            .as_deref()
            .is_some_and(|title| !title.trim().is_empty()),
        "title missing from ConversationThread"
    );
    assert!(
        !thread.plan.is_empty(),
        "plan missing from ConversationThread"
    );
    assert!(
        thread
            .entries
            .iter()
            .any(|entry| matches!(entry, cgc_agent_ui::conversation::Entry::ToolCall { locations, output, args, .. }
                if locations.iter().any(|location| location.ends_with("mock-output.txt"))
                    && output.as_deref().is_some_and(|output| output.contains("+++ new")))),
        "tool card lost diff/location: {thread:?}"
    );
}

fn real_plan(tag: &str, text_only: bool) -> Option<(MockLlm, LaunchPlan)> {
    real_plan_with(tag, text_only, false)
}

fn real_plan_slow(tag: &str) -> Option<(MockLlm, LaunchPlan)> {
    real_plan_with(tag, true, true)
}

fn real_plan_with(tag: &str, text_only: bool, slow_text: bool) -> Option<(MockLlm, LaunchPlan)> {
    let adapter = adapter_bin()?;
    let node = std::env::var_os("CGC_DSH_ACP_NODE")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("node"));
    let root = temp_dir(tag);
    let cache = root.join("cache");
    let dsh_home = root.join("dsh-home");
    let cwd = root.join("workspace");
    std::fs::create_dir_all(&cache).expect("cache");
    std::fs::create_dir_all(&dsh_home).expect("dsh home");
    std::fs::create_dir_all(&cwd).expect("workspace");
    let output = cwd.join("mock-output.txt");
    let mock = if slow_text {
        MockLlm::start_slow_text(output)
    } else if text_only {
        MockLlm::start_text_only(output)
    } else {
        MockLlm::start(output)
    };
    let mut env = BTreeMap::new();
    for key in [
        "PATH",
        "HOME",
        "LANG",
        "TERM",
        "HTTP_PROXY",
        "HTTPS_PROXY",
        "NO_PROXY",
    ] {
        if let Ok(value) = std::env::var(key) {
            env.insert(key.to_string(), value);
        }
    }
    env.insert(
        "XDG_CACHE_HOME".into(),
        cache.to_string_lossy().into_owned(),
    );
    env.insert("DSH_HOME".into(), dsh_home.to_string_lossy().into_owned());
    env.insert("DEEPSEEK_API_KEY".into(), "sk-mock".into());
    env.insert("DEEPSEEK_BASE_URL".into(), format!("http://{}", mock.addr));
    let plan = LaunchPlan {
        program: node,
        args: vec![adapter.to_string_lossy().into_owned()],
        env,
        cwd,
    };
    Some((mock, plan))
}

fn wait_ready(host: &AcpHost, timeout: Duration) -> String {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        let Some(event) = host.recv_timeout(Duration::from_millis(200)) else {
            continue;
        };
        match event {
            HostEvent::Ready { session_id, .. } => return session_id,
            HostEvent::Error { message } => panic!("dsh adapter failed before ready: {message}"),
            HostEvent::Exited => panic!("dsh adapter exited before ready"),
            _ => {}
        }
    }
    panic!("dsh adapter did not become ready");
}

fn wait_turn_end(host: &AcpHost, timeout: Duration) {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        let Some(event) = host.recv_timeout(Duration::from_millis(200)) else {
            continue;
        };
        match event {
            HostEvent::TurnEnd { cancelled, .. } => {
                assert!(!cancelled, "turn unexpectedly cancelled");
                return;
            }
            HostEvent::Error { message } => panic!("dsh turn failed: {message}"),
            _ => {}
        }
    }
    panic!("dsh turn did not finish");
}

#[test]
fn real_openma_session_list_and_resume() {
    let Some((_mock, plan)) = real_plan("list-resume", true) else {
        eprintln!("skip dsh list/resume e2e: set CGC_DSH_ACP_BIN");
        return;
    };
    let host = AcpHost::start(
        AcpHostConfig::from_launch_plan(plan.clone())
            .with_name("dsh")
            .with_list_sessions_after_ready(false),
    )
    .expect("start dsh adapter");
    let session_id = wait_ready(&host, Duration::from_secs(240));
    assert!(host.prompt("第一轮"));
    wait_turn_end(&host, Duration::from_secs(240));
    assert!(host.list_sessions());
    let mut sessions = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(60);
    while Instant::now() < deadline {
        let Some(event) = host.recv_timeout(Duration::from_millis(200)) else {
            continue;
        };
        if let HostEvent::Sessions { sessions: list } = event {
            sessions = list;
            break;
        }
    }
    assert!(
        sessions
            .iter()
            .any(|session| session.session_id == session_id),
        "session/list did not return {session_id}: {sessions:?}"
    );
    host.shutdown();

    let resumed = AcpHost::start(
        AcpHostConfig::from_launch_plan(plan)
            .with_name("dsh")
            .with_resume_session(session_id.clone()),
    )
    .expect("start dsh adapter for resume");
    assert_eq!(wait_ready(&resumed, Duration::from_secs(240)), session_id);
    assert!(resumed.prompt("第二轮"));
    wait_turn_end(&resumed, Duration::from_secs(240));
    resumed.shutdown();
}

#[test]
fn real_openma_cancel_interrupts_stream() {
    let Some((_mock, plan)) = real_plan_slow("cancel") else {
        eprintln!("skip dsh cancel e2e: set CGC_DSH_ACP_BIN");
        return;
    };
    let host = AcpHost::start(AcpHostConfig::from_launch_plan(plan).with_name("dsh"))
        .expect("start dsh adapter");
    let _session_id = wait_ready(&host, Duration::from_secs(240));
    assert!(host.prompt("请持续输出，直到我取消"));
    let deadline = Instant::now() + Duration::from_secs(30);
    let mut saw_delta = false;
    while Instant::now() < deadline && !saw_delta {
        if let Some(event) = host.recv_timeout(Duration::from_millis(200)) {
            match event {
                HostEvent::Delta(text) => saw_delta |= !text.is_empty(),
                HostEvent::Error { message } => {
                    panic!("dsh stream failed before cancel: {message}")
                }
                _ => {}
            }
        }
    }
    assert!(saw_delta, "slow stream produced no delta before cancel");
    assert!(host.stop());
    let deadline = Instant::now() + Duration::from_secs(15);
    let mut cancelled = false;
    while Instant::now() < deadline {
        if let Some(HostEvent::TurnEnd {
            cancelled: value, ..
        }) = host.recv_timeout(Duration::from_millis(200))
        {
            cancelled = value;
            break;
        }
    }
    host.shutdown();
    assert!(
        cancelled,
        "session/cancel did not end the turn as cancelled"
    );
}
