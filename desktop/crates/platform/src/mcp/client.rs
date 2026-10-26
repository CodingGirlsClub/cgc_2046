//! 3.4a：MCP Streamable HTTP JSON-RPC client（native MCP 工具调用，mock 可测）。
//!
//! 只实现 `initialize` / `tools/list` / `tools/call` 三个方法；Bearer 来自
//! learning_host lease（由调用方注入），token 不进入 Debug/错误/日志。
//! 超时、取消（由取消 = 调用方丢弃/短超时实现）、401/403 一律 fail-closed。

use std::fmt;
use std::time::Duration;

use serde_json::{json, Value};

/// MCP 协议版本（与 2024-11-05 兼容的最小实现）。
const PROTOCOL_VERSION: &str = "2024-11-05";

/// MCP 工具描述。
#[derive(Clone, Debug, PartialEq)]
pub struct McpTool {
    pub name: String,
    pub description: Option<String>,
    pub input_schema: Value,
}

/// MCP client 错误（fail-closed；不含 token/Authorization）。
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum McpClientError {
    Unauthorized,
    Forbidden,
    Timeout,
    Transport(String),
    Protocol(String),
    Rpc { code: i64, message: String },
}

impl fmt::Display for McpClientError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Unauthorized => write!(formatter, "MCP 认证失败（401）"),
            Self::Forbidden => write!(formatter, "MCP 无权限（403）"),
            Self::Timeout => write!(formatter, "MCP 请求超时"),
            Self::Transport(message) => write!(formatter, "MCP 传输失败：{message}"),
            Self::Protocol(message) => write!(formatter, "MCP 协议错误：{message}"),
            Self::Rpc { code, message } => write!(formatter, "MCP 错误 {code}：{message}"),
        }
    }
}

impl std::error::Error for McpClientError {}

/// Streamable HTTP MCP client。
pub struct McpHttpClient {
    endpoint: String,
    token: Option<String>,
    session_id: Option<String>,
    next_id: u64,
    agent: ureq::Agent,
}

impl fmt::Debug for McpHttpClient {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("McpHttpClient")
            .field("endpoint", &self.endpoint)
            .field("token", &self.token.as_ref().map(|_| "<redacted>"))
            .field("session_id", &self.session_id)
            .finish()
    }
}

impl McpHttpClient {
    pub fn new(endpoint: impl Into<String>) -> Self {
        Self::with_timeout(endpoint, Duration::from_secs(10))
    }

    pub fn with_timeout(endpoint: impl Into<String>, timeout: Duration) -> Self {
        let config = ureq::Agent::config_builder()
            .timeout_global(Some(timeout))
            .build();
        Self {
            endpoint: endpoint.into(),
            token: None,
            session_id: None,
            next_id: 1,
            agent: config.into(),
        }
    }

    /// 注入 learning_host lease 的 Bearer token（不实现 Debug 输出）。
    pub fn with_bearer_token(mut self, token: impl Into<String>) -> Self {
        self.token = Some(token.into());
        self
    }

    pub fn endpoint(&self) -> &str {
        &self.endpoint
    }

    /// MCP 握手；成功后保存 `Mcp-Session-Id` 供后续请求使用。
    pub fn initialize(
        &mut self,
        client_name: &str,
        client_version: &str,
    ) -> Result<Value, McpClientError> {
        let result = self.rpc(
            "initialize",
            json!({
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {},
                "clientInfo": { "name": client_name, "version": client_version },
            }),
        )?;
        Ok(result)
    }

    /// 列出 MCP server 提供的工具。
    pub fn list_tools(&mut self) -> Result<Vec<McpTool>, McpClientError> {
        let result = self.rpc("tools/list", json!({}))?;
        let tools = result
            .get("tools")
            .and_then(Value::as_array)
            .ok_or_else(|| McpClientError::Protocol("tools/list 缺少 tools 数组".into()))?;
        tools
            .iter()
            .map(|tool| {
                let name = tool
                    .get("name")
                    .and_then(Value::as_str)
                    .ok_or_else(|| McpClientError::Protocol("tool 缺少 name".into()))?;
                Ok(McpTool {
                    name: name.to_string(),
                    description: tool
                        .get("description")
                        .and_then(Value::as_str)
                        .map(str::to_string),
                    input_schema: tool.get("inputSchema").cloned().unwrap_or(Value::Null),
                })
            })
            .collect()
    }

    /// 调用工具，返回文本结果（多个 text content 以换行拼接）。
    pub fn call_tool(&mut self, name: &str, arguments: Value) -> Result<String, McpClientError> {
        let result = self.rpc(
            "tools/call",
            json!({ "name": name, "arguments": arguments }),
        )?;
        if result.get("isError").and_then(Value::as_bool) == Some(true) {
            let message = text_content(&result).unwrap_or_else(|| "工具返回错误".to_string());
            return Err(McpClientError::Rpc {
                code: -32000,
                message,
            });
        }
        Ok(text_content(&result).unwrap_or_else(|| result.to_string()))
    }

    fn rpc(&mut self, method: &str, params: Value) -> Result<Value, McpClientError> {
        let id = self.next_id;
        self.next_id = self.next_id.saturating_add(1);
        let body = jsonrpc_body(id, method, params);
        let mut request = self
            .agent
            .post(&self.endpoint)
            .header("content-type", "application/json")
            .header("accept", "application/json, text/event-stream");
        if let Some(token) = &self.token {
            request = request.header("authorization", format!("Bearer {token}"));
        }
        if let Some(session_id) = &self.session_id {
            request = request.header("mcp-session-id", session_id.clone());
        }
        let mut response = request.send_json(&body).map_err(map_transport_error)?;
        let status = response.status().as_u16();
        if status == 401 {
            return Err(McpClientError::Unauthorized);
        }
        if status == 403 {
            return Err(McpClientError::Forbidden);
        }
        if method == "initialize" {
            if let Some(session_id) = header_value(&response, "mcp-session-id") {
                self.session_id = Some(session_id);
            }
        }
        let is_sse = header_value(&response, "content-type")
            .map(|value| value.to_ascii_lowercase().contains("text/event-stream"))
            .unwrap_or(false);
        let text = response
            .body_mut()
            .read_to_string()
            .map_err(|error| McpClientError::Transport(error.to_string()))?;
        let payload = if is_sse {
            parse_sse_json(&text)?
        } else {
            serde_json::from_str::<Value>(&text)
                .map_err(|error| McpClientError::Protocol(format!("非法 JSON：{error}")))?
        };
        if let Some(error) = payload.get("error") {
            let code = error.get("code").and_then(Value::as_i64).unwrap_or(-32000);
            let message = error
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or("MCP RPC error")
                .to_string();
            return Err(McpClientError::Rpc { code, message });
        }
        payload
            .get("result")
            .cloned()
            .ok_or_else(|| McpClientError::Protocol("缺少 result".into()))
    }
}

/// 构造 JSON-RPC 2.0 请求体（纯函数，单测覆盖）。
fn jsonrpc_body(id: u64, method: &str, params: Value) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": id,
        "method": method,
        "params": params,
    })
}

fn map_transport_error(error: ureq::Error) -> McpClientError {
    match error {
        ureq::Error::StatusCode(401) => McpClientError::Unauthorized,
        ureq::Error::StatusCode(403) => McpClientError::Forbidden,
        ureq::Error::Timeout(_) => McpClientError::Timeout,
        other => {
            let message = other.to_string();
            if message.contains("timeout") || message.contains("timed out") {
                McpClientError::Timeout
            } else {
                McpClientError::Transport(message)
            }
        }
    }
}

fn header_value(response: &ureq::http::Response<ureq::Body>, name: &str) -> Option<String> {
    response
        .headers()
        .get(name)
        .and_then(|value| value.to_str().ok())
        .map(str::to_string)
}

/// 从 SSE 响应中取最后一个 `data:` JSON（Streamable HTTP 的 text/event-stream 分支）。
fn parse_sse_json(text: &str) -> Result<Value, McpClientError> {
    let mut data = None;
    for line in text.lines() {
        if let Some(value) = line.strip_prefix("data:") {
            let value = value.trim();
            if !value.is_empty() {
                data = Some(value);
            }
        }
    }
    let data = data.ok_or_else(|| McpClientError::Protocol("SSE 响应缺少 data".into()))?;
    serde_json::from_str::<Value>(data)
        .map_err(|error| McpClientError::Protocol(format!("SSE data 非法 JSON：{error}")))
}

/// 拼接 MCP `content` 数组里的 text 项。
fn text_content(result: &Value) -> Option<String> {
    let items = result.get("content")?.as_array()?;
    let texts = items
        .iter()
        .filter(|item| item.get("type").and_then(Value::as_str) == Some("text"))
        .filter_map(|item| item.get("text").and_then(Value::as_str))
        .collect::<Vec<_>>();
    (!texts.is_empty()).then(|| texts.join("\n"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::sync::mpsc;

    struct MockResponse {
        status: u16,
        content_type: &'static str,
        session_id: Option<&'static str>,
        body: String,
        delay: Option<Duration>,
    }

    fn response(status: u16, body: &str) -> MockResponse {
        MockResponse {
            status,
            content_type: "application/json",
            session_id: None,
            body: body.to_string(),
            delay: None,
        }
    }

    /// 依次响应 N 个请求；返回 (endpoint, 请求文本 receiver)。
    fn spawn_mock(responses: Vec<MockResponse>) -> (String, mpsc::Receiver<String>) {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let addr = listener.local_addr().expect("addr");
        let (sender, receiver) = mpsc::channel();
        std::thread::spawn(move || {
            for response in responses {
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
                        }
                    }
                    if let Some(end) = header_end {
                        if content_length > 0 {
                            if request.len() >= end + content_length {
                                break;
                            }
                        } else if request.len() > end {
                            // 无 Content-Length（chunked）：给 body 一点时间到达后结束。
                            let _ = stream.set_read_timeout(Some(Duration::from_millis(300)));
                            while let Ok(read) = stream.read(&mut buffer) {
                                if read == 0 {
                                    break;
                                }
                                request.extend_from_slice(&buffer[..read]);
                            }
                            break;
                        }
                    }
                }
                let _ = sender.send(String::from_utf8_lossy(&request).to_string());
                if let Some(delay) = response.delay {
                    std::thread::sleep(delay);
                }
                let mut headers = format!(
                    "HTTP/1.1 {} X\r\nContent-Type: {}\r\nContent-Length: {}\r\nConnection: close\r\n",
                    response.status,
                    response.content_type,
                    response.body.len()
                );
                if let Some(session_id) = response.session_id {
                    headers.push_str(&format!("Mcp-Session-Id: {session_id}\r\n"));
                }
                headers.push_str("\r\n");
                let _ = stream.write_all(headers.as_bytes());
                let _ = stream.write_all(response.body.as_bytes());
                let _ = stream.flush();
            }
        });
        (format!("http://{addr}/mcp"), receiver)
    }

    #[test]
    fn initialize_captures_session_and_lists_tools() {
        let (endpoint, requests) = spawn_mock(vec![
            MockResponse {
                status: 200,
                content_type: "text/event-stream",
                session_id: Some("sess-1"),
                body: "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2024-11-05\",\"serverInfo\":{\"name\":\"cgc\"}}}\n\n".into(),
                delay: None,
            },
            response(
                200,
                r#"{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"get_course","description":"读取课程","inputSchema":{"type":"object"}}]}}"#,
            ),
        ]);
        let mut client = McpHttpClient::new(endpoint).with_bearer_token("lease-token");
        let init = client.initialize("cgc-desktop", "0.1").expect("initialize");
        assert_eq!(init["protocolVersion"], "2024-11-05");
        let tools = client.list_tools().expect("list tools");
        assert_eq!(tools.len(), 1);
        assert_eq!(tools[0].name, "get_course");
        assert_eq!(tools[0].description.as_deref(), Some("读取课程"));

        let first = requests.recv().expect("first request");
        assert!(
            first.contains("authorization: Bearer lease-token")
                || first.to_ascii_lowercase().contains("bearer lease-token")
        );
        assert!(first.contains("text/event-stream"));
        let second = requests.recv().expect("second request");
        assert!(second
            .to_ascii_lowercase()
            .contains("mcp-session-id: sess-1"));
    }

    #[test]
    fn call_tool_returns_text_and_maps_is_error() {
        let (endpoint, _requests) = spawn_mock(vec![
            response(
                200,
                r#"{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"line1"},{"type":"text","text":"line2"}]}}"#,
            ),
            response(
                200,
                r#"{"jsonrpc":"2.0","id":2,"result":{"isError":true,"content":[{"type":"text","text":"tool failed"}]}}"#,
            ),
        ]);
        let mut client = McpHttpClient::new(endpoint).with_bearer_token("lease-token");
        assert_eq!(
            client
                .call_tool("get_course", json!({"id":"c1"}))
                .expect("call"),
            "line1\nline2"
        );
        let error = client.call_tool("get_course", json!({})).unwrap_err();
        assert!(matches!(error, McpClientError::Rpc { .. }));
    }

    #[test]
    fn unauthorized_and_forbidden_fail_closed() {
        let (endpoint, _requests) = spawn_mock(vec![response(401, "{}")]);
        let mut client = McpHttpClient::new(endpoint).with_bearer_token("secret-token");
        assert_eq!(
            client.initialize("c", "1").unwrap_err(),
            McpClientError::Unauthorized
        );

        let (endpoint, _requests) = spawn_mock(vec![response(403, "{}")]);
        let mut client = McpHttpClient::new(endpoint).with_bearer_token("secret-token");
        assert_eq!(
            client.initialize("c", "1").unwrap_err(),
            McpClientError::Forbidden
        );
    }

    #[test]
    fn timeout_invalid_json_and_rpc_error_are_mapped() {
        let (endpoint, _requests) = spawn_mock(vec![MockResponse {
            status: 200,
            content_type: "application/json",
            session_id: None,
            body: "{}".into(),
            delay: Some(Duration::from_millis(500)),
        }]);
        let mut client = McpHttpClient::with_timeout(endpoint, Duration::from_millis(100));
        assert_eq!(
            client.initialize("c", "1").unwrap_err(),
            McpClientError::Timeout
        );

        let (endpoint, _requests) = spawn_mock(vec![response(200, "not-json")]);
        let mut client = McpHttpClient::new(endpoint);
        assert!(matches!(
            client.initialize("c", "1").unwrap_err(),
            McpClientError::Protocol(_)
        ));

        let (endpoint, _requests) = spawn_mock(vec![response(
            200,
            r#"{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"method not found"}}"#,
        )]);
        let mut client = McpHttpClient::new(endpoint);
        let error = client.initialize("c", "1").unwrap_err();
        assert_eq!(
            error,
            McpClientError::Rpc {
                code: -32601,
                message: "method not found".into()
            }
        );
    }

    #[test]
    fn jsonrpc_body_carries_method_and_params() {
        let body = jsonrpc_body(7, "tools/list", json!({"cursor": "c1"}));
        assert_eq!(body["jsonrpc"], "2.0");
        assert_eq!(body["id"], 7);
        assert_eq!(body["method"], "tools/list");
        assert_eq!(body["params"]["cursor"], "c1");
    }

    #[test]
    fn debug_and_errors_never_expose_token() {
        let client = McpHttpClient::new("http://127.0.0.1:1/mcp").with_bearer_token("top-secret");
        let debug = format!("{client:?}");
        assert!(debug.contains("<redacted>"));
        assert!(!debug.contains("top-secret"));

        let (endpoint, _requests) = spawn_mock(vec![response(401, "{}")]);
        let mut client = McpHttpClient::new(endpoint).with_bearer_token("top-secret");
        let error = client.initialize("c", "1").unwrap_err();
        assert!(!format!("{error}").contains("top-secret"));
        assert!(!format!("{error:?}").contains("top-secret"));
    }
}
