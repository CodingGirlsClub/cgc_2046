use super::*;
use futures::executor::block_on;
use serde_json::json;
use std::io::{Read, Write};
use std::net::TcpListener;
use std::sync::mpsc;
use std::time::Duration;

/// 依次响应 N 个请求，返回 (endpoint, 请求文本 receiver)。
fn spawn_mock(
    responses: Vec<&'static str>,
    revoke_before_last: Option<McpLeaseGuard>,
) -> (String, mpsc::Receiver<String>) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let addr = listener.local_addr().expect("addr");
    let (sender, receiver) = mpsc::channel();
    std::thread::spawn(move || {
        let count = responses.len();
        for (index, body) in responses.into_iter().enumerate() {
            let Ok((mut stream, _)) = listener.accept() else {
                break;
            };
            let mut buffer = [0u8; 4096];
            let mut request = Vec::new();
            let mut content_length = 0usize;
            let mut header_end = None;
            while let Ok(read) = stream.read(&mut buffer) {
                if read == 0 {
                    break;
                }
                request.extend_from_slice(&buffer[..read]);
                if header_end.is_none() {
                    if let Some(position) = request.windows(4).position(|w| w == b"\r\n\r\n") {
                        header_end = Some(position + 4);
                        let headers = String::from_utf8_lossy(&request[..position]).to_string();
                        content_length = headers
                            .lines()
                            .find_map(|line| {
                                let (name, value) = line.split_once(':')?;
                                name.eq_ignore_ascii_case("content-length")
                                    .then(|| value.trim().parse::<usize>().ok())
                                    .flatten()
                            })
                            .unwrap_or(0);
                        if content_length == 0 {
                            // 无 Content-Length（chunked）：短暂等待 body 后结束。
                            let _ = stream.set_read_timeout(Some(Duration::from_millis(200)));
                        }
                    }
                }
                if let Some(end) = header_end {
                    if content_length > 0 && request.len() >= end + content_length {
                        break;
                    }
                }
            }
            let _ = sender.send(String::from_utf8_lossy(&request).to_string());
            if index + 1 == count {
                if let Some(guard) = &revoke_before_last {
                    guard.revoke();
                }
            }
            let response = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                );
            let _ = stream.write_all(response.as_bytes());
            let _ = stream.flush();
        }
    });
    (format!("http://{addr}/mcp"), receiver)
}

fn init_response() -> &'static str {
    r#"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","serverInfo":{"name":"cgc"}}}"#
}

fn tools_response() -> &'static str {
    r#"{"jsonrpc":"2.0","id":2,"result":{"tools":[
            {"name":"get_course_content","description":"读取课程内容","inputSchema":{"type":"object","properties":{"course_id":{"type":"string"}}}},
            {"name":"get_course_revision","description":"读取课程修订","inputSchema":{"type":"object"}},
            {"name":"get_learning_state","inputSchema":{"type":"object"}},
            {"name":"get_role_playbook","description":"角色手册"},
            {"name":"get_enrollment_summary","description":"报名摘要","inputSchema":{"type":"object"}},
            {"name":"delete_everything","description":"危险工具","inputSchema":{"type":"object"}},
            {"name":"get_broken_tool","description":"schema 缺失"}
        ]}}"#
}

#[test]
fn discovery_is_fail_closed_and_whitelist_only() {
    let (endpoint, requests) = spawn_mock(vec![init_response(), tools_response()], None);
    let client = McpHttpClient::new(endpoint);
    let tools = discover_read_only_mcp_tools("cgc", client).expect("MCP discovery");
    let names = tools.iter().map(|tool| tool.name()).collect::<Vec<_>>();
    assert_eq!(
        names.len(),
        4,
        "白名单 5 个中 schema 缺失 1 个应跳过：{names:?}"
    );
    for expected in [
        "mcp_cgc_get_course_content",
        "mcp_cgc_get_course_revision",
        "mcp_cgc_get_learning_state",
        "mcp_cgc_get_enrollment_summary",
    ] {
        assert!(names.contains(&expected), "缺少 {expected}");
    }
    assert!(
        !names.contains(&"mcp_cgc_get_role_playbook"),
        "schema 缺失应跳过"
    );
    assert!(
        !names.contains(&"mcp_cgc_delete_everything"),
        "白名单外必须过滤"
    );

    let _ = requests.recv();
    let list_request = requests.recv().expect("tools/list request");
    assert!(
        list_request.contains("\"method\":\"tools/list\"") || list_request.contains("tools/list")
    );
}

#[test]
fn call_tool_returns_text_and_is_error() {
    let (endpoint, requests) = spawn_mock(
        vec![
            init_response(),
            tools_response(),
            r#"{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"课程正文"}]}}"#,
        ],
        None,
    );
    let tools =
        discover_read_only_mcp_tools("cgc", McpHttpClient::new(endpoint)).expect("MCP discovery");
    let tool = tools
        .iter()
        .find(|tool| tool.name() == "mcp_cgc_get_course_content")
        .expect("course tool");
    let result = block_on(tool.run(
        serde_json::json!({"course_id": "crs-002"}),
        ToolContext::new("/tmp"),
    ))
    .expect("tool result");
    assert!(!result.is_error);
    assert_eq!(result.content, "课程正文");

    let _ = requests.recv();
    let _ = requests.recv();
    let call_request = requests.recv().expect("tools/call request");
    assert!(
        call_request.contains("get_course_content") || call_request.contains("tools/call"),
        "应触发 tools/call：{call_request}"
    );
}

#[test]
fn is_error_marks_tool_result_as_error_without_panic() {
    let (endpoint, _requests) = spawn_mock(
        vec![
            init_response(),
            tools_response(),
            r#"{"jsonrpc":"2.0","id":3,"result":{"isError":true,"content":[{"type":"text","text":"课程不存在"}]}}"#,
        ],
        None,
    );
    let tools =
        discover_read_only_mcp_tools("cgc", McpHttpClient::new(endpoint)).expect("MCP discovery");
    let tool = tools
        .iter()
        .find(|tool| tool.name() == "mcp_cgc_get_course_content")
        .expect("course tool");
    let result =
        block_on(tool.run(serde_json::json!({}), ToolContext::new("/tmp"))).expect("tool result");
    assert!(result.is_error);
    assert!(result.content.contains("课程不存在"));
}

#[test]
fn approval_is_allow_for_read_only_tools() {
    let (endpoint, _requests) = spawn_mock(vec![init_response(), tools_response()], None);
    let tools =
        discover_read_only_mcp_tools("cgc", McpHttpClient::new(endpoint)).expect("MCP discovery");
    for tool in &tools {
        assert_eq!(
            tool.approval(&serde_json::json!({})),
            Approval::Allow,
            "{} 应默认 Allow",
            tool.name()
        );
    }
}

#[test]
fn handshake_failure_is_diagnosable_instead_of_an_empty_authorization_set() {
    let (endpoint, _requests) = spawn_mock(
        vec![r#"{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"nope"}}"#],
        None,
    );
    let error = discover_read_only_mcp_tools("cgc", McpHttpClient::new(endpoint))
        .err()
        .expect("handshake error");
    assert!(error.to_string().contains("nope"));
}

#[test]
fn registry_registration_exposes_only_whitelisted_tools_and_runs() {
    use crate::registry::ToolRegistry;
    let (endpoint, _requests) = spawn_mock(
        vec![
            init_response(),
            tools_response(),
            r#"{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"registry 正文"}]}}"#,
        ],
        None,
    );
    let mut registry = ToolRegistry::new();
    let client = McpHttpClient::new(endpoint).with_bearer_token("lease");
    let registered =
        register_read_only_mcp_tools(&mut registry, "cgc", client).expect("MCP registration");
    assert_eq!(registered, 4, "白名单 5 个中 schema 缺失 1 个被跳过");
    assert!(registry.get("mcp_cgc_get_course_content").is_some());
    assert!(registry.get("mcp_cgc_delete_everything").is_none());

    let result = block_on(registry.run(
        "mcp_cgc_get_course_content",
        serde_json::json!({"course_id": "crs-002"}),
        ToolContext::new("/tmp"),
    ))
    .expect("registry run");
    assert_eq!(result.content, "registry 正文");
    assert!(!result.is_error);
}

#[test]
fn lease_registration_fails_closed_without_token() {
    use crate::registry::ToolRegistry;
    let mut registry = ToolRegistry::new();
    // 无 token：不允许建连（endpoint 不可达也不该 panic/超时）。
    let count = register_read_only_mcp_tools_from_lease(
        &mut registry,
        "cgc",
        "http://127.0.0.1:1/mcp",
        None,
    )
    .expect("MCP registration");
    assert_eq!(count, 0);
    assert!(registry.schemas().is_empty());
    let count = register_read_only_mcp_tools_from_lease(
        &mut registry,
        "cgc",
        "http://127.0.0.1:1/mcp",
        Some("  "),
    )
    .expect("MCP registration");
    assert_eq!(count, 0);
}

#[test]
fn non_whitelisted_server_tools_are_not_registered() {
    let (endpoint, _requests) = spawn_mock(
        vec![
            init_response(),
            r#"{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"delete_everything","inputSchema":{"type":"object"}}]}}"#,
        ],
        None,
    );
    let tools =
        discover_read_only_mcp_tools("cgc", McpHttpClient::new(endpoint)).expect("MCP discovery");
    assert!(tools.is_empty());
}
/// provider（OpenAI 兼容）要求 function name 匹配 `^[a-zA-Z0-9_-]+$`；
/// 工具名带 `:` 会被整体拒绝（真机 3.4d 回归）。
#[test]
fn tool_names_match_provider_function_name_pattern() {
    let (endpoint, _requests) = spawn_mock(vec![init_response(), tools_response()], None);
    let client = McpHttpClient::new(endpoint);
    let tools = discover_read_only_mcp_tools("cgc-2046-learning", client).expect("MCP discovery");
    assert!(!tools.is_empty(), "白名单工具应被发现");
    for tool in &tools {
        let name = tool.name();
        assert!(
            !name.is_empty()
                && name
                    .chars()
                    .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-'),
            "工具名 {name} 不符合 provider 函数名约束 ^[a-zA-Z0-9_-]+$"
        );
    }
}
/// 客户端注入的固定参数只补缺失字段，不覆盖模型显式值（3.4d 真机：缺 workspace_id）。
#[test]
fn injected_args_fill_missing_workspace_only() {
    let injected = json!({ "workspace_id": "ws-1" });
    let mut args = json!({ "course_id": "c-1" });
    let merged = merge_injected_args(std::mem::take(&mut args), Some(&injected));
    assert_eq!(merged["workspace_id"], "ws-1");
    assert_eq!(merged["course_id"], "c-1");

    // 模型显式给了 workspace_id → 不被覆盖
    let explicit = json!({ "workspace_id": "ws-2" });
    let merged = merge_injected_args(explicit, Some(&injected));
    assert_eq!(merged["workspace_id"], "ws-2");

    // 空串 / null 等同未提供 → 被注入覆盖（真机 3.4d 回归）
    for placeholder in [json!(""), json!("   "), json!(null)] {
        let args = json!({ "workspace_id": placeholder, "course_id": "c-1" });
        let merged = merge_injected_args(args, Some(&injected));
        assert_eq!(merged["workspace_id"], "ws-1", "占位值应被注入覆盖");
    }

    // 无注入 / 非对象 args → 原样返回
    let empty = json!({ "course_id": "c-1" });
    assert_eq!(merge_injected_args(empty.clone(), None), empty);
    assert_eq!(merge_injected_args(json!("x"), Some(&injected)), json!("x"));
}

#[test]
fn revoked_lease_blocks_an_already_captured_tool_before_http() {
    let (endpoint, requests) = spawn_mock(
        vec![
            init_response(),
            tools_response(),
            r#"{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"current state"}]}}"#,
            r#"{"jsonrpc":"2.0","id":4,"result":{"content":[{"type":"text","text":"old private state"}]}}"#,
        ],
        None,
    );
    let guard = McpLeaseGuard::new();
    let tools = discover_read_only_mcp_tools_with(
        "cgc",
        McpHttpClient::new(&endpoint),
        None,
        Some(guard.clone()),
    )
    .expect("MCP discovery");
    let tool = tools
        .iter()
        .find(|tool| tool.name() == "mcp_cgc_get_learning_state")
        .unwrap();
    let current = block_on(tool.run(json!({}), ToolContext::new("/tmp"))).unwrap();
    assert_eq!(current.content, "current state");
    for _ in 0..3 {
        requests.recv().unwrap();
    }

    guard.revoke();
    let revoked = block_on(tool.run(json!({}), ToolContext::new("/tmp"))).unwrap();
    assert!(
        revoked.is_error,
        "a captured client cannot retain authorization after sign-out"
    );
    assert!(!revoked.content.contains("old private state"));
    assert!(
        matches!(requests.try_recv(), Err(mpsc::TryRecvError::Empty)),
        "revoked calls must not contact the server"
    );
    assert!(matches!(tool.approval(&json!({})), Approval::Deny(_)));

    // Consume the deliberately available bad-path response, so the fixture cannot leak a listener.
    let address = endpoint
        .trim_start_matches("http://")
        .split('/')
        .next()
        .unwrap();
    let mut stream = std::net::TcpStream::connect(address).unwrap();
    stream.write_all(b"POST /mcp HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}").unwrap();
    let mut response = String::new();
    stream.read_to_string(&mut response).unwrap();
    requests.recv().unwrap();
}

#[test]
fn revocation_discards_an_in_flight_mcp_response() {
    let guard = McpLeaseGuard::new();
    let (endpoint, _) = spawn_mock(
        vec![
            init_response(),
            tools_response(),
            r#"{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"old private state"}]}}"#,
        ],
        Some(guard.clone()),
    );
    let tools = discover_read_only_mcp_tools_with(
        "cgc",
        McpHttpClient::new(endpoint),
        None,
        Some(guard.clone()),
    )
    .expect("MCP discovery");
    let tool = tools
        .iter()
        .find(|tool| tool.name() == "mcp_cgc_get_learning_state")
        .unwrap();

    let result = block_on(tool.run(json!({}), ToolContext::new("/tmp"))).unwrap();

    assert!(
        guard.is_revoked(),
        "the server revoked the lease before returning its response"
    );
    assert!(
        result.is_error,
        "late results from the previous authorization epoch must be rejected"
    );
    assert!(!result.content.contains("old private state"));
}

#[test]
fn cancelled_turn_blocks_platform_tool_before_http() {
    let (endpoint, requests) = spawn_mock(
        vec![
            init_response(),
            tools_response(),
            r#"{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"never used"}]}}"#,
        ],
        None,
    );
    let tools = discover_read_only_mcp_tools_with("cgc", McpHttpClient::new(&endpoint), None, None)
        .expect("MCP discovery");
    let tool = tools
        .iter()
        .find(|tool| tool.name() == "mcp_cgc_get_learning_state")
        .unwrap();
    // 消费 discovery 期间产生的两条请求，确保后面判断的是「本轮调用」。
    for _ in 0..2 {
        requests.recv().unwrap();
    }

    let cancelled: crate::tool::CancelProbe = std::sync::Arc::new(|| true);
    let result =
        block_on(tool.run(json!({}), ToolContext::new("/tmp").with_cancel(cancelled))).unwrap();
    assert!(result.is_error, "Stop 之后不得执行平台工具");
    assert!(result.content.contains("本轮已停止"), "{}", result.content);
    assert!(
        matches!(requests.try_recv(), Err(mpsc::TryRecvError::Empty)),
        "已取消的回合不得再发出 HTTP 请求"
    );
}
