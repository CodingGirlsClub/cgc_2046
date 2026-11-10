//! GraphQL 传输层（story 3.1 起）：统一的 HTTP/GraphQL 客户端，供各 domain 的 API 实现复用。
//!
//! 只做「发请求 + 解 errors」，不解释业务实体；实体解析放在对应 domain crate，
//! 保证 GraphQL 单一来源（脊柱 AD-2）且各 feature 不各写一套传输。

use std::time::Duration;

use serde_json::Value;

use crate::workspace::{OfferingScope, WorkspaceScope};

pub mod media;

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

/// 公开面（`OfferingScope::Public`）的列表过滤口径；与 Web 公开发现页一致。
const PUBLIC_OFFERING_STATUS: &str = "open";
const PUBLIC_OFFERING_VISIBILITY: &str = "public";

/// 在 variables 里注入列表作用域：
/// 工作区面 → `filter.workspaceId`；公开面 → `status=open` + `visibility=public`，不带工作区。
pub fn apply_offering_scope(variables: &mut Value, scope: OfferingScope<'_>) {
    if let Some(workspace) = scope.workspace() {
        apply_workspace_scope(variables, Some(workspace));
        return;
    }
    let Some(variables) = variables.as_object_mut() else {
        return;
    };
    let Some(filter) = variables
        .entry("filter")
        .or_insert_with(|| serde_json::json!({}))
        .as_object_mut()
    else {
        return;
    };
    filter.insert(
        "status".to_string(),
        serde_json::json!({ "eq": PUBLIC_OFFERING_STATUS }),
    );
    filter.insert(
        "visibility".to_string(),
        serde_json::json!({ "eq": PUBLIC_OFFERING_VISIBILITY }),
    );
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

/// GraphQL 文档的 operation 名；匿名操作/片段返回 `anonymous`。
///
/// 只用于日志定位，不做完整解析：跳过前导空白，读 `query|mutation|subscription`
/// 之后的标识符，遇到空白/`(`/`{` 即止。
fn operation_name(document: &str) -> &str {
    let trimmed = document.trim_start();
    let Some((kind, rest)) =
        trimmed.split_once(|ch: char| ch.is_whitespace() || ch == '(' || ch == '{')
    else {
        return "anonymous";
    };
    if !matches!(kind, "query" | "mutation" | "subscription") {
        return "anonymous";
    }
    let rest = rest.trim_start();
    let end = rest
        .find(|ch: char| ch.is_whitespace() || ch == '(' || ch == '{')
        .unwrap_or(rest.len());
    let name = &rest[..end];
    if name.is_empty()
        || !name
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || ch == '_')
    {
        "anonymous"
    } else {
        name
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
    ///
    /// 失败统一在传输层落一条 `WARN`：UI 只给泛化文案，用户反馈的「后台连不上」
    /// 只能靠 `app.log` 定位到具体 operation 与端点。凭证只走请求头，不进日志
    /// （logger 另有一次 `redact_sensitive` 兜底）。
    pub fn post(
        &self,
        token: Option<&str>,
        query: &str,
        variables: Value,
    ) -> Result<Value, ApiError> {
        let result = self.send(token, query, variables);
        if let Err(error) = &result {
            log::warn!(
                target: "graphql",
                "{} 失败 endpoint={}：{}",
                operation_name(query),
                self.endpoint,
                error.diagnostic()
            );
        }
        result
    }

    fn send(&self, token: Option<&str>, query: &str, variables: Value) -> Result<Value, ApiError> {
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
    fn public_offering_scope_forces_open_public_and_never_workspace() {
        let mut variables = serde_json::json!({ "first": 10 });
        apply_offering_scope(&mut variables, OfferingScope::Public);
        assert_eq!(variables["filter"]["status"]["eq"], "open");
        assert_eq!(variables["filter"]["visibility"]["eq"], "public");
        assert!(variables["filter"].get("workspaceId").is_none());
    }

    #[test]
    fn public_offering_scope_overrides_a_stale_status_filter() {
        let mut variables = serde_json::json!({ "filter": { "status": { "eq": "closed" } } });
        apply_offering_scope(&mut variables, OfferingScope::Public);
        assert_eq!(variables["filter"]["status"]["eq"], "open");
        assert_eq!(variables["filter"]["visibility"]["eq"], "public");
    }

    #[test]
    fn workspace_offering_scope_keeps_the_status_filter() {
        let scope = WorkspaceScope {
            workspace_id: "ws-7".to_string(),
            epoch: 1,
        };
        let mut variables = serde_json::json!({ "filter": { "status": { "eq": "closed" } } });
        apply_offering_scope(&mut variables, OfferingScope::Workspace(&scope));
        assert_eq!(variables["filter"]["workspaceId"]["eq"], "ws-7");
        assert_eq!(variables["filter"]["status"]["eq"], "closed");
        assert!(variables["filter"].get("visibility").is_none());
    }

    #[test]
    fn scoped_operation_registry_is_non_empty_and_named() {
        assert!(WORKSPACE_SCOPED_OPERATIONS.contains(&"ListEvents"));
        assert!(WORKSPACE_SCOPED_OPERATIONS.contains(&"ListCourses"));
    }

    /// 失败请求必须留一条可诊断日志：operation 名 + endpoint + 错误类别；绝不带凭证。
    #[test]
    fn failed_post_logs_operation_endpoint_and_never_the_token() {
        install_capture_logger();
        let (endpoint, _received) = spawn_mock(500, "{}");
        let client = GraphqlClient::new(endpoint.clone());
        let token = "eyJhbGciOiJIUzI1NiJ9.payload.signature";
        let error = client
            .post(
                Some(token),
                "query ListWorkspaces($token: String) { meWorkspaces { id } }",
                serde_json::json!({}),
            )
            .expect_err("step 1: 500 must fail");
        assert!(
            matches!(error, ApiError::Transport(_)),
            "step 1: transport error, got {error:?}"
        );

        let lines = captured_lines_containing(&endpoint);
        assert!(
            !lines.is_empty(),
            "step 2: failed GraphQL request must be logged"
        );
        let logged = lines.join("\n");
        assert!(
            logged.contains("ListWorkspaces"),
            "step 2: log names the operation: {logged}"
        );
        assert!(
            logged.contains("transport error"),
            "step 2: log carries the error class: {logged}"
        );
        assert!(
            !logged.contains(token),
            "step 3: bearer token must never reach the log: {logged}"
        );
    }

    #[test]
    fn operation_name_reads_the_graphql_document() {
        assert_eq!(
            operation_name("query ListWorkspaces { a }"),
            "ListWorkspaces"
        );
        assert_eq!(
            operation_name("\n  mutation CreateLearningHostToken($name: String!) { a }"),
            "CreateLearningHostToken"
        );
        assert_eq!(operation_name("query { a }"), "anonymous");
        assert_eq!(operation_name("  "), "anonymous");
        assert_eq!(operation_name("fragment X on Y { a }"), "anonymous");
    }

    static CAPTURED: std::sync::Mutex<Vec<String>> = std::sync::Mutex::new(Vec::new());

    struct CaptureLogger;

    impl log::Log for CaptureLogger {
        fn enabled(&self, _: &log::Metadata<'_>) -> bool {
            true
        }

        fn log(&self, record: &log::Record<'_>) {
            if let Ok(mut captured) = CAPTURED.lock() {
                captured.push(format!(
                    "{} {} {}",
                    record.level(),
                    record.target(),
                    record.args()
                ));
            }
        }

        fn flush(&self) {}
    }

    fn install_capture_logger() {
        static ONCE: std::sync::Once = std::sync::Once::new();
        ONCE.call_once(|| {
            let _ = log::set_logger(&CaptureLogger);
            log::set_max_level(log::LevelFilter::Trace);
        });
    }

    fn captured_lines_containing(needle: &str) -> Vec<String> {
        CAPTURED
            .lock()
            .map(|captured| {
                captured
                    .iter()
                    .filter(|line| line.contains(needle))
                    .cloned()
                    .collect()
            })
            .unwrap_or_default()
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
