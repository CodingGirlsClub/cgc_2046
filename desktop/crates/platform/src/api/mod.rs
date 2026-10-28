//! GraphQL 传输层（story 3.1 起）：统一的 HTTP/GraphQL 客户端，供各 domain 的 API 实现复用。
//!
//! 只做「发请求 + 解 errors」，不解释业务实体；实体解析放在对应 domain crate，
//! 保证 GraphQL 单一来源（脊柱 AD-2）且各 feature 不各写一套传输。

use std::time::Duration;

use serde_json::Value;

use crate::workspace::WorkspaceScope;

/// 2.5：当前需要注入 workspace 作用域的 operation 清单（新增 operation 必须登记）。
pub const WORKSPACE_SCOPED_OPERATIONS: &[&str] = &["ListEvents", "ListCourses"];

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ApiError {
    /// 网络不可达 / 响应不是合法 JSON。
    Transport(String),
    /// 请求超时（与网络失败区分，便于客户端给不同提示）。
    Timeout(String),
    /// 未认证/登录失效（HTTP 401 或 GraphQL unauthorized 类 code）：统一登出。
    Unauthorized,
    /// GraphQL errors 非空（带可选业务 code）。
    Graphql {
        code: Option<String>,
        message: String,
    },
}

impl ApiError {
    pub fn diagnostic(&self) -> String {
        match self {
            ApiError::Transport(reason) => format!("transport error: {reason}"),
            ApiError::Timeout(reason) => format!("timeout: {reason}"),
            ApiError::Unauthorized => "unauthorized".to_string(),
            ApiError::Graphql { code, message } => match code {
                Some(code) => format!("graphql error {code}: {message}"),
                None => format!("graphql error: {message}"),
            },
        }
    }

    /// 统一错误 key（feature 展示/日志用）：`client.<code|transport|timeout>`。
    pub fn client_key(&self) -> String {
        match self {
            ApiError::Transport(_) => "client.transport".to_string(),
            ApiError::Timeout(_) => "client.timeout".to_string(),
            ApiError::Unauthorized => "client.unauthorized".to_string(),
            ApiError::Graphql { code, .. } => match code {
                Some(code) => format!("client.{code}"),
                None => "client.graphql".to_string(),
            },
        }
    }
}

/// 在 variables 里注入当前 workspace 作用域（仅对登记过的 scoped operation 调用）。
pub fn apply_workspace_scope(variables: &mut Value, scope: Option<&WorkspaceScope>) {
    let Some(scope) = scope else {
        return;
    };
    let filter = variables.as_object_mut().and_then(|variables| {
        variables
            .entry("filter")
            .or_insert_with(|| serde_json::json!({}))
            .as_object_mut()
    });
    if let Some(filter) = filter {
        filter.insert(
            "workspaceId".to_string(),
            serde_json::json!({ "eq": scope.workspace_id }),
        );
    }
}

#[derive(Clone, Debug)]
pub struct GraphqlClient {
    endpoint: String,
    timeout: Duration,
}

impl GraphqlClient {
    pub fn new(endpoint: impl Into<String>) -> Self {
        Self {
            endpoint: endpoint.into(),
            timeout: Duration::from_secs(10),
        }
    }

    pub fn with_timeout(mut self, timeout: Duration) -> Self {
        self.timeout = timeout;
        self
    }

    pub fn timeout(&self) -> Duration {
        self.timeout
    }

    /// 解析当前端点：`CGC_API_URL` > `settings.json` 的 `api.url` > 编译期默认值。
    ///
    /// 发布构建把默认端点编进二进制（`CGC_DEFAULT_API_URL`），用户双击启动也能连上后端。
    pub fn from_env() -> Self {
        Self::new(crate::runtime::api_endpoint())
    }

    pub fn endpoint(&self) -> &str {
        &self.endpoint
    }

    /// POST 一个 GraphQL 请求；`token` 存在时加 `Authorization: Bearer`。
    /// GraphQL errors 非空 → `ApiError::Graphql`（HTTP 仍是 200 的语义）。
    pub fn post(
        &self,
        token: Option<&str>,
        query: &str,
        variables: Value,
    ) -> Result<Value, ApiError> {
        let config = ureq::Agent::config_builder()
            .timeout_global(Some(self.timeout))
            .build();
        let agent: ureq::Agent = config.into();
        let mut request = agent
            .post(&self.endpoint)
            .header("content-type", "application/json");
        if let Some(token) = token {
            request = request.header("authorization", format!("Bearer {token}"));
        }

        let body = serde_json::json!({ "query": query, "variables": variables });
        let mut response = request.send_json(&body).map_err(|error| {
            if matches!(&error, ureq::Error::StatusCode(401)) {
                return ApiError::Unauthorized;
            }
            let reason = error.to_string();
            if reason.contains("timeout") || reason.contains("timed out") {
                ApiError::Timeout(reason)
            } else {
                ApiError::Transport(reason)
            }
        })?;
        let payload = response
            .body_mut()
            .read_json::<Value>()
            .map_err(|error| ApiError::Transport(error.to_string()))?;

        if let Some(errors) = payload.get("errors").and_then(Value::as_array) {
            if let Some(first) = errors.first() {
                let code = first
                    .get("code")
                    .and_then(Value::as_str)
                    .or_else(|| first.get("extensions")?.get("code")?.as_str())
                    .map(str::to_string);
                let message = first
                    .get("message")
                    .and_then(Value::as_str)
                    .unwrap_or("graphql request failed")
                    .to_string();
                if code.as_deref().is_some_and(|code: &str| {
                    matches!(
                        code,
                        "unauthorized" | "unauthenticated" | "authentication_failed"
                    )
                }) {
                    return Err(ApiError::Unauthorized);
                }
                return Err(ApiError::Graphql { code, message });
            }
        }

        Ok(payload)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::TcpListener;

    fn spawn_mock(status: u16, body: &'static str) -> (String, std::sync::mpsc::Receiver<String>) {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let addr = listener.local_addr().expect("addr");
        let (sender, receiver) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept");
            let mut request = Vec::new();
            let mut buf = [0u8; 2048];
            let header_end = loop {
                let read = stream.read(&mut buf).expect("read");
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
                "HTTP/1.1 {status} OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
            stream.write_all(response.as_bytes()).expect("write");
        });
        (format!("http://{addr}/api/graphql"), receiver)
    }

    #[test]
    fn post_sends_bearer_and_parses_data() {
        let (endpoint, received) = spawn_mock(200, r#"{"data":{"ok":true}}"#);
        let client = GraphqlClient::new(endpoint);
        let value = client
            .post(Some("jwt.token"), "query { ok }", serde_json::json!({}))
            .expect("post ok");

        assert_eq!(value["data"]["ok"], true);
        let request = received.recv().expect("request");
        assert!(
            request.contains("authorization: Bearer jwt.token")
                || request
                    .to_ascii_lowercase()
                    .contains("authorization: bearer jwt.token")
        );
    }

    #[test]
    fn graphql_errors_map_to_api_error_with_code() {
        let (endpoint, _rx) = spawn_mock(
            200,
            r#"{"errors":[{"message":"Not authenticated","code":"unauthorized"}]}"#,
        );
        let client = GraphqlClient::new(endpoint);
        let error = client
            .post(None, "mutation { x }", serde_json::json!({}))
            .unwrap_err();
        assert_eq!(error, ApiError::Unauthorized);
    }

    #[test]
    fn http_401_maps_to_unauthorized() {
        let (endpoint, _rx) = spawn_mock(401, r#"{"errors":[{"message":"unauthorized"}]}"#);
        let client = GraphqlClient::new(endpoint);
        let error = client
            .post(None, "query { me { id } }", serde_json::json!({}))
            .unwrap_err();
        assert_eq!(error, ApiError::Unauthorized);
        assert_eq!(error.client_key(), "client.unauthorized");
    }

    #[test]
    fn workspace_scope_is_merged_into_filter() {
        let scope = WorkspaceScope {
            workspace_id: "ws-1".to_string(),
            epoch: 3,
        };
        let mut variables = serde_json::json!({ "filter": { "status": { "eq": "open" } } });
        apply_workspace_scope(&mut variables, Some(&scope));
        assert_eq!(variables["filter"]["workspaceId"]["eq"], "ws-1");
        assert_eq!(variables["filter"]["status"]["eq"], "open");

        let mut untouched = serde_json::json!({ "id": "x" });
        apply_workspace_scope(&mut untouched, None);
        assert!(untouched.get("filter").is_none());
    }

    #[test]
    fn scoped_operation_registry_is_non_empty_and_named() {
        assert!(WORKSPACE_SCOPED_OPERATIONS.contains(&"ListEvents"));
        assert!(WORKSPACE_SCOPED_OPERATIONS.contains(&"ListCourses"));
    }

    #[test]
    fn error_keys_are_stable() {
        assert_eq!(
            ApiError::Transport("x".into()).client_key(),
            "client.transport"
        );
        assert_eq!(ApiError::Timeout("x".into()).client_key(), "client.timeout");
        assert_eq!(ApiError::Unauthorized.client_key(), "client.unauthorized");
        assert_eq!(
            ApiError::Graphql {
                code: Some("order_deposit_consent_required".into()),
                message: "x".into()
            }
            .client_key(),
            "client.order_deposit_consent_required"
        );
    }
}
