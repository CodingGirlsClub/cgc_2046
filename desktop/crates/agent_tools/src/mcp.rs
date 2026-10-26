//! 3.4b：MCP 工具适配 —— 把 MCP server 的只读工具包装成第一方 `Tool`。
//!
//! 白名单 fail-closed：只有 5 个只读课程工具会被注册；其它工具一律不暴露给模型。
//! MCP 调用失败（超时/401/403/协议错误/isError）以 error 文本回灌模型，不 panic。
//!
//! Layering：本模块依赖 `cgc_platform::mcp::client`（client 是最底层传输，
//! 不依赖 agent_tools，无环）。

use std::sync::{Arc, Mutex};

use cgc_platform::mcp::client::{McpClientError, McpHttpClient};
use futures::future::BoxFuture;
use futures::FutureExt as _;
use serde_json::Value;

use crate::approval::Approval;
use crate::error::ToolError;
use crate::tool::{Tool, ToolContext, ToolResult};

/// 只读课程工具白名单（3.4b；白名单外一律不注册）。
pub const READ_ONLY_MCP_TOOLS: [&str; 5] = [
    "get_course_content",
    "get_course_revision",
    "get_learning_state",
    "get_role_playbook",
    "get_enrollment_summary",
];

/// 是否在白名单内（纯函数，fail-closed）。
pub fn is_read_only_mcp_tool(name: &str) -> bool {
    READ_ONLY_MCP_TOOLS.contains(&name)
}

/// 一个 MCP 工具的第一方包装。
pub struct McpTool {
    name: &'static str,
    description: &'static str,
    schema: Value,
    remote_name: String,
    client: Arc<Mutex<McpHttpClient>>,
}

impl Tool for McpTool {
    fn name(&self) -> &'static str {
        self.name
    }

    fn description(&self) -> &'static str {
        self.description
    }

    fn schema(&self) -> Value {
        self.schema.clone()
    }

    /// 白名单内全部是只读课程工具：默认 Allow，不弹审批卡。
    fn approval(&self, _args: &Value) -> Approval {
        Approval::Allow
    }

    fn run(
        &self,
        args: Value,
        _context: ToolContext,
    ) -> BoxFuture<'static, Result<ToolResult, ToolError>> {
        let client = self.client.clone();
        let remote_name = self.remote_name.clone();
        async move {
            let (sender, receiver) = futures::channel::oneshot::channel();
            // MCP client 是同步（ureq）实现；放到独立线程避免阻塞工具执行器。
            std::thread::spawn(move || {
                let result = match client.lock() {
                    Ok(mut guard) => guard.call_tool(&remote_name, args),
                    Err(_) => Err(McpClientError::Transport("MCP client 锁中毒".to_string())),
                };
                let _ = sender.send(result);
            });
            match receiver.await {
                Ok(Ok(text)) => Ok(ToolResult::ok(text)),
                Ok(Err(error)) => Ok(ToolResult::error(format!("MCP 调用失败：{error}"))),
                Err(_) => Ok(ToolResult::error("MCP 调用被取消".to_string())),
            }
        }
        .boxed()
    }
}

/// 连接 MCP server、握手、拉取 tools/list，并按白名单包装成工具。
///
/// fail-closed：握手/列表失败 → 返回空列表；白名单外、schema 非法的工具跳过。
pub fn discover_read_only_mcp_tools(
    server_name: &str,
    mut client: McpHttpClient,
) -> Vec<Arc<dyn Tool>> {
    if client
        .initialize("cgc-desktop", env!("CARGO_PKG_VERSION"))
        .is_err()
    {
        return Vec::new();
    }
    let Ok(tools) = client.list_tools() else {
        return Vec::new();
    };
    let client = Arc::new(Mutex::new(client));
    tools
        .into_iter()
        .filter(|tool| is_read_only_mcp_tool(&tool.name))
        .filter_map(|tool| {
            let schema = valid_tool_schema(&tool.input_schema)?;
            let name: &'static str =
                Box::leak(format!("mcp:{server_name}:{}", tool.name).into_boxed_str());
            let description: &'static str = Box::leak(
                tool.description
                    .unwrap_or_else(|| format!("MCP 只读工具 {}", tool.name))
                    .into_boxed_str(),
            );
            Some(Arc::new(McpTool {
                name,
                description,
                schema,
                remote_name: tool.name,
                client: client.clone(),
            }) as Arc<dyn Tool>)
        })
        .collect()
}

/// MCP `inputSchema` 必须是 object；缺失/非法（Null/非 object）→ 跳过该工具。
fn valid_tool_schema(schema: &Value) -> Option<Value> {
    schema.is_object().then(|| schema.clone())
}

#[cfg(test)]
mod tests {
    use super::*;
    use futures::executor::block_on;
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::sync::mpsc;
    use std::time::Duration;

    /// 依次响应 N 个请求，返回 (endpoint, 请求文本 receiver)。
    fn spawn_mock(responses: Vec<&'static str>) -> (String, mpsc::Receiver<String>) {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let addr = listener.local_addr().expect("addr");
        let (sender, receiver) = mpsc::channel();
        std::thread::spawn(move || {
            for body in responses {
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
        let (endpoint, requests) = spawn_mock(vec![init_response(), tools_response()]);
        let client = McpHttpClient::new(endpoint);
        let tools = discover_read_only_mcp_tools("cgc", client);
        let names = tools.iter().map(|tool| tool.name()).collect::<Vec<_>>();
        assert_eq!(
            names.len(),
            4,
            "白名单 5 个中 schema 缺失 1 个应跳过：{names:?}"
        );
        for expected in [
            "mcp:cgc:get_course_content",
            "mcp:cgc:get_course_revision",
            "mcp:cgc:get_learning_state",
            "mcp:cgc:get_enrollment_summary",
        ] {
            assert!(names.contains(&expected), "缺少 {expected}");
        }
        assert!(
            !names.contains(&"mcp:cgc:get_role_playbook"),
            "schema 缺失应跳过"
        );
        assert!(
            !names.contains(&"mcp:cgc:delete_everything"),
            "白名单外必须过滤"
        );

        let _ = requests.recv();
        let list_request = requests.recv().expect("tools/list request");
        assert!(
            list_request.contains("\"method\":\"tools/list\"")
                || list_request.contains("tools/list")
        );
    }

    #[test]
    fn schema_is_preserved_and_missing_schema_is_skipped() {
        let (endpoint, _requests) = spawn_mock(vec![init_response(), tools_response()]);
        let tools = discover_read_only_mcp_tools("cgc", McpHttpClient::new(endpoint));
        let course = tools
            .iter()
            .find(|tool| tool.name() == "mcp:cgc:get_course_content")
            .expect("course tool");
        assert_eq!(course.schema()["type"], "object");
        assert_eq!(course.schema()["properties"]["course_id"]["type"], "string");
        assert!(tools
            .iter()
            .all(|tool| tool.name() != "mcp:cgc:get_role_playbook"));
    }

    #[test]
    fn call_tool_returns_text_and_is_error() {
        let (endpoint, requests) = spawn_mock(vec![
            init_response(),
            tools_response(),
            r#"{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"课程正文"}]}}"#,
        ]);
        let tools = discover_read_only_mcp_tools("cgc", McpHttpClient::new(endpoint));
        let tool = tools
            .iter()
            .find(|tool| tool.name() == "mcp:cgc:get_course_content")
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
        let (endpoint, _requests) = spawn_mock(vec![
            init_response(),
            tools_response(),
            r#"{"jsonrpc":"2.0","id":3,"result":{"isError":true,"content":[{"type":"text","text":"课程不存在"}]}}"#,
        ]);
        let tools = discover_read_only_mcp_tools("cgc", McpHttpClient::new(endpoint));
        let tool = tools
            .iter()
            .find(|tool| tool.name() == "mcp:cgc:get_course_content")
            .expect("course tool");
        let result = block_on(tool.run(serde_json::json!({}), ToolContext::new("/tmp")))
            .expect("tool result");
        assert!(result.is_error);
        assert!(result.content.contains("课程不存在"));
    }

    #[test]
    fn approval_is_allow_for_read_only_tools() {
        let (endpoint, _requests) = spawn_mock(vec![init_response(), tools_response()]);
        let tools = discover_read_only_mcp_tools("cgc", McpHttpClient::new(endpoint));
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
    fn handshake_failure_returns_empty_tools() {
        let (endpoint, _requests) = spawn_mock(vec![
            r#"{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"nope"}}"#,
        ]);
        let tools = discover_read_only_mcp_tools("cgc", McpHttpClient::new(endpoint));
        assert!(tools.is_empty(), "握手失败必须 fail-closed");
    }

    #[test]
    fn non_whitelisted_server_tools_are_not_registered() {
        let (endpoint, _requests) = spawn_mock(vec![
            init_response(),
            r#"{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"delete_everything","inputSchema":{"type":"object"}}]}}"#,
        ]);
        let tools = discover_read_only_mcp_tools("cgc", McpHttpClient::new(endpoint));
        assert!(tools.is_empty());
    }
}
