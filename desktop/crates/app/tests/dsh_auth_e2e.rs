//! P3 e2e：无预置凭据时 ACP 返回结构化 auth_required；注入 Key 后可直接对话。
//!
//! 需本机 openma 0.4.41：
//! ```bash
//! CGC_DSH_ACP_BIN=.../dist/bin.js \
//! CGC_DSH_ACP_NODE=$(which node) \
//! cargo test -p cgc-desktop-app --test dsh_auth_e2e -- --nocapture
//! ```

use std::collections::BTreeMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{SocketAddr, TcpListener};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use cgc_platform::acp::connection::{AcpHost, AcpHostConfig, HostEvent};
use cgc_platform::agent::launch::LaunchPlan;

struct MockLlm {
    addr: SocketAddr,
    stop: Arc<AtomicBool>,
}

impl MockLlm {
    fn start() -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind mock llm");
        listener.set_nonblocking(true).expect("nonblocking");
        let addr = listener.local_addr().expect("mock addr");
        let stop = Arc::new(AtomicBool::new(false));
        let stop_for_thread = Arc::clone(&stop);
        std::thread::spawn(move || {
            while !stop_for_thread.load(Ordering::Relaxed) {
                match listener.accept() {
                    Ok((stream, _)) => {
                        std::thread::spawn(move || {
                            let _ = respond(stream);
                        });
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        std::thread::sleep(Duration::from_millis(20));
                    }
                    Err(_) => break,
                }
            }
        });
        Self { addr, stop }
    }
}

impl Drop for MockLlm {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
    }
}

fn respond(mut stream: std::net::TcpStream) -> std::io::Result<()> {
    let mut reader = BufReader::new(stream.try_clone()?);
    let mut request_line = String::new();
    reader.read_line(&mut request_line)?;
    if !request_line.starts_with("POST ") {
        return Ok(());
    }
    let mut length = 0;
    loop {
        let mut line = String::new();
        reader.read_line(&mut line)?;
        if line == "\r\n" || line.is_empty() {
            break;
        }
        if let Some(value) = line.to_ascii_lowercase().strip_prefix("content-length:") {
            length = value.trim().parse().unwrap_or(0);
        }
    }
    let mut body = vec![0u8; length];
    reader.read_exact(&mut body)?;
    let _ = String::from_utf8_lossy(&body);
    let payload = sse([
        (
            "message_start",
            serde_json::json!({
                "type":"message_start",
                "message":{"id":"msg_auth","type":"message","role":"assistant","content":[],
                    "model":"deepseek-flash","stop_reason":null,"stop_sequence":null,
                    "usage":{"input_tokens":3,"output_tokens":0}}
            }),
        ),
        (
            "content_block_start",
            serde_json::json!({"type":"content_block_start","index":0,
            "content_block":{"type":"text","text":""}}),
        ),
        (
            "content_block_delta",
            serde_json::json!({"type":"content_block_delta","index":0,
            "delta":{"type":"text_delta","text":"凭据已注入"}}),
        ),
        (
            "content_block_stop",
            serde_json::json!({"type":"content_block_stop","index":0}),
        ),
        (
            "message_delta",
            serde_json::json!({"type":"message_delta",
            "delta":{"stop_reason":"end_turn","stop_sequence":null},
            "usage":{"output_tokens":4}}),
        ),
        ("message_stop", serde_json::json!({"type":"message_stop"})),
    ]);
    let response = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        payload.len()
    );
    stream.write_all(response.as_bytes())?;
    stream.write_all(payload.as_bytes())?;
    stream.flush()
}

fn sse(events: impl IntoIterator<Item = (&'static str, serde_json::Value)>) -> String {
    events
        .into_iter()
        .map(|(name, data)| format!("event: {name}\ndata: {data}\n\n"))
        .collect()
}

fn temp_dir(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "cgc-dsh-auth-{}-{tag}-{}",
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

fn adapter() -> Option<PathBuf> {
    std::env::var_os("CGC_DSH_ACP_BIN")
        .map(PathBuf::from)
        .or_else(|| {
            std::env::var_os("CGC_DSH_ACP_PACKAGE_DIR")
                .map(PathBuf::from)
                .map(|dir| dir.join("dist/bin.js"))
        })
}

fn base_env(cache: &std::path::Path, dsh_home: &std::path::Path) -> BTreeMap<String, String> {
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
    env
}

fn start(
    adapter: &std::path::Path,
    node: &std::path::Path,
    env: BTreeMap<String, String>,
    cwd: PathBuf,
) -> AcpHost {
    let plan = LaunchPlan {
        program: node.to_path_buf(),
        args: vec![adapter.to_string_lossy().into_owned()],
        env,
        cwd,
    };
    AcpHost::start(AcpHostConfig::from_launch_plan(plan).with_name("dsh"))
        .expect("start dsh adapter")
}

#[test]
fn auth_required_then_key_env_allows_conversation() {
    let Some(adapter) = adapter() else {
        eprintln!("skip dsh_auth_e2e: set CGC_DSH_ACP_BIN");
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

    // 1) 无 Key：adapter 在 session/new 返回 -32000 auth_required。
    let mut env = base_env(&cache, &dsh_home);
    env.remove("DEEPSEEK_API_KEY");
    let host = start(&adapter, &node, env, cwd.clone());
    let deadline = Instant::now() + Duration::from_secs(240);
    let mut auth_event = None;
    while Instant::now() < deadline {
        let Some(event) = host.recv_timeout(Duration::from_millis(200)) else {
            continue;
        };
        match event {
            HostEvent::AuthRequired {
                message,
                auth_methods,
            } => {
                auth_event = Some((message, auth_methods));
                break;
            }
            HostEvent::Error { message } => panic!("expected auth_required, got Error: {message}"),
            HostEvent::Exited => break,
            _ => {}
        }
    }
    host.shutdown();
    let (message, methods) = auth_event.expect("adapter must emit AuthRequired without key");
    assert!(
        message.contains("credential") || message.contains("authenticate"),
        "unexpected auth message: {message}"
    );
    assert!(!methods.is_empty(), "authMethods must be forwarded");
    assert!(methods.iter().any(|method| !method.id.is_empty()));
    assert!(!message.contains("sk-"));
    assert!(
        !dsh_home.join(".credentials.yaml").exists(),
        "auth-required path must not write DSH credential files"
    );

    // 2) 注入 Key 后：可以建会话并完成一轮文本对话。
    let mock = MockLlm::start();
    let mut env = base_env(&cache, &dsh_home);
    env.insert("DEEPSEEK_API_KEY".into(), "sk-mock".into());
    env.insert("DEEPSEEK_BASE_URL".into(), format!("http://{}", mock.addr));
    let host = start(&adapter, &node, env, cwd);
    let mut ready = false;
    let deadline = Instant::now() + Duration::from_secs(240);
    while Instant::now() < deadline && !ready {
        if let Some(event) = host.recv_timeout(Duration::from_millis(200)) {
            match event {
                HostEvent::Ready { .. } => ready = true,
                HostEvent::Error { message } => panic!("key injection failed: {message}"),
                HostEvent::AuthRequired { .. } => panic!("key env was not accepted"),
                HostEvent::Exited => break,
                _ => {}
            }
        }
    }
    assert!(ready, "adapter did not become Ready with DEEPSEEK_API_KEY");
    assert!(host.prompt("with-credentials"));
    let mut delta = String::new();
    let mut ended = false;
    let deadline = Instant::now() + Duration::from_secs(240);
    while Instant::now() < deadline && !ended {
        if let Some(event) = host.recv_timeout(Duration::from_millis(200)) {
            match event {
                HostEvent::Delta(text) => delta.push_str(&text),
                HostEvent::TurnEnd { .. } => ended = true,
                HostEvent::Error { message } => panic!("turn failed: {message}"),
                _ => {}
            }
        }
    }
    host.shutdown();
    assert!(ended, "turn did not finish");
    assert!(delta.contains("凭据已注入"), "unexpected delta: {delta}");
}
