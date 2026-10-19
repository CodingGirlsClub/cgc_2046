//! 第一方认证 API（story 2.1）：登录 / 撤销的端口与两种实现。
//!
//! - `HttpAuthApi`：POST 到后端 GraphQL，调用 2.13 的 `signInForDesktop` / `revokeToken`；
//! - `FakeAuthApi`：本地 fake auth，供 UI 开发、测试与离线演示使用。

use serde_json::Value;

pub const SIGN_IN_FOR_DESKTOP: &str = r#"
mutation SignInForDesktop($login: String!, $password: String!) {
  signInForDesktop(login: $login, password: $password) {
    token
    userId
    email
    isPlatformAdmin
  }
}
"#;

pub const VALIDATE_SESSION: &str = "query ValidateSession { me { id } }";

const REVOKE_TOKEN: &str = r#"
mutation RevokeToken {
  revokeToken
}
"#;

/// 已登录会话：Bearer token + 最小用户信息（keychain/文件存储的就是它）。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SignedInSession {
    pub token: String,
    pub user_id: String,
    pub email: Option<String>,
    pub is_platform_admin: bool,
}

/// 登录/撤销失败对 UI 可展示的分类（不暴露服务端细节）。
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AuthError {
    /// 账号或密码错误（服务端统一 `authentication_failed`）。
    InvalidCredentials,
    /// 网络不可达 / 超时 / 响应不是合法 JSON。
    Transport(String),
    /// 服务端返回非认证类错误。
    Server(String),
    /// 本地凭证持久化失败（keychain 不可用等）：fail-closed，不进入 SignedIn。
    Storage(String),
}

impl AuthError {
    /// i18n key 由 UI 层映射；这里给稳定的诊断文本，便于日志与测试。
    pub fn diagnostic(&self) -> String {
        match self {
            AuthError::InvalidCredentials => "invalid credentials".to_string(),
            AuthError::Transport(reason) => format!("transport error: {reason}"),
            AuthError::Storage(reason) => format!("storage error: {reason}"),
            AuthError::Server(reason) => format!("server error: {reason}"),
        }
    }
}

pub trait AuthApi {
    fn sign_in(&self, login: &str, password: &str) -> Result<SignedInSession, AuthError>;
    fn revoke(&self, token: &str) -> Result<(), AuthError>;
    /// 启动恢复时校验持久 token 是否仍有效（false=确定失效；Err=网络不确定，保留会话）。
    fn validate(&self, token: &str) -> Result<bool, AuthError>;
}

/// 真实后端：GraphQL over HTTP。
pub struct HttpAuthApi {
    endpoint: String,
}

impl HttpAuthApi {
    pub fn new(endpoint: impl Into<String>) -> Self {
        Self {
            endpoint: endpoint.into(),
        }
    }

    /// 默认本地后端端点，可用 `CGC_API_URL` 覆盖（如 staging / 生产）。
    pub fn from_env() -> Self {
        let endpoint = std::env::var("CGC_API_URL")
            .unwrap_or_else(|_| "http://localhost:4000/api/graphql".to_string());
        Self::new(endpoint)
    }

    fn post(&self, token: Option<&str>, query: &str, variables: Value) -> Result<Value, AuthError> {
        let mut request = ureq::post(&self.endpoint).header("content-type", "application/json");
        if let Some(token) = token {
            request = request.header("authorization", format!("Bearer {token}"));
        }

        let body = serde_json::json!({ "query": query, "variables": variables });
        let mut response = request
            .send_json(&body)
            .map_err(|err| AuthError::Transport(err.to_string()))?;
        response
            .body_mut()
            .read_json::<Value>()
            .map_err(|err| AuthError::Transport(err.to_string()))
    }

    fn parse_errors(body: &Value) -> Option<AuthError> {
        let errors = body.get("errors")?.as_array()?;
        if errors.is_empty() {
            return None;
        }
        let first = &errors[0];
        let code = first
            .get("code")
            .and_then(Value::as_str)
            .or_else(|| first.get("extensions")?.get("code")?.as_str());
        let message = first
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("request failed");

        Some(match code {
            Some("authentication_failed") => AuthError::InvalidCredentials,
            _ => AuthError::Server(message.to_string()),
        })
    }
}

impl AuthApi for HttpAuthApi {
    fn sign_in(&self, login: &str, password: &str) -> Result<SignedInSession, AuthError> {
        let body = self.post(
            None,
            SIGN_IN_FOR_DESKTOP,
            serde_json::json!({ "login": login, "password": password }),
        )?;

        if let Some(error) = Self::parse_errors(&body) {
            return Err(error);
        }

        let result = body
            .get("data")
            .and_then(|data| data.get("signInForDesktop"))
            .ok_or_else(|| AuthError::Server("missing signInForDesktop payload".to_string()))?;

        let token = result
            .get("token")
            .and_then(Value::as_str)
            .ok_or_else(|| AuthError::Server("missing token in signInForDesktop".to_string()))?;

        Ok(SignedInSession {
            token: token.to_string(),
            user_id: result
                .get("userId")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string(),
            email: result
                .get("email")
                .and_then(Value::as_str)
                .map(str::to_string),
            is_platform_admin: result
                .get("isPlatformAdmin")
                .and_then(Value::as_bool)
                .unwrap_or(false),
        })
    }

    fn validate(&self, token: &str) -> Result<bool, AuthError> {
        let body = self.post(Some(token), VALIDATE_SESSION, serde_json::json!({}))?;
        if let Some(errors) = body.get("errors").and_then(Value::as_array) {
            if errors.iter().any(|error| {
                matches!(
                    error.get("code").and_then(Value::as_str),
                    Some("forbidden" | "unauthorized" | "unauthenticated")
                )
            }) {
                return Ok(false);
            }
        }
        Ok(body
            .get("data")
            .and_then(|data| data.get("me"))
            .and_then(|me| me.get("id"))
            .and_then(Value::as_str)
            .is_some())
    }

    fn revoke(&self, token: &str) -> Result<(), AuthError> {
        let body = self.post(Some(token), REVOKE_TOKEN, serde_json::json!({}))?;
        if let Some(error) = Self::parse_errors(&body) {
            return Err(error);
        }
        Ok(())
    }
}

/// 本地 fake auth：固定凭据，供 UI 开发/测试；永远不访问网络。
pub struct FakeAuthApi {
    login: String,
    password: String,
    user_id: String,
    email: String,
}

impl FakeAuthApi {
    /// 默认账号：`demo@example.com` / `demo`。
    pub fn demo() -> Self {
        Self {
            login: "demo@example.com".to_string(),
            password: "demo".to_string(),
            user_id: "00000000-0000-0000-0000-000000000001".to_string(),
            email: "demo@example.com".to_string(),
        }
    }

    pub fn with_credentials(
        mut self,
        login: impl Into<String>,
        password: impl Into<String>,
    ) -> Self {
        self.login = login.into();
        self.password = password.into();
        self
    }
}

impl Default for FakeAuthApi {
    fn default() -> Self {
        Self::demo()
    }
}

impl AuthApi for FakeAuthApi {
    fn sign_in(&self, login: &str, password: &str) -> Result<SignedInSession, AuthError> {
        if login == self.login && password == self.password {
            Ok(SignedInSession {
                token: "fake-desktop-token".to_string(),
                user_id: self.user_id.clone(),
                email: Some(self.email.clone()),
                is_platform_admin: false,
            })
        } else {
            Err(AuthError::InvalidCredentials)
        }
    }

    fn revoke(&self, _token: &str) -> Result<(), AuthError> {
        Ok(())
    }

    fn validate(&self, token: &str) -> Result<bool, AuthError> {
        Ok(!token.is_empty() && token != "expired")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::TcpListener;

    /// 最小 HTTP mock：接收一次请求、返回固定状态码与 JSON body，并回传收到的请求文本。
    fn spawn_mock_server(
        status: u16,
        body: &'static str,
    ) -> (String, std::sync::mpsc::Receiver<String>) {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind mock server");
        let addr = listener.local_addr().expect("local addr");
        let (sender, receiver) = std::sync::mpsc::channel();

        std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept");
            let mut request = Vec::new();
            let mut buf = [0u8; 1024];
            let header_end = loop {
                let read = stream.read(&mut buf).expect("read request");
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
            stream
                .write_all(response.as_bytes())
                .expect("write response");
        });

        (format!("http://{addr}/api/graphql"), receiver)
    }

    #[test]
    fn http_sign_in_calls_sign_in_for_desktop_and_parses_session() {
        let (endpoint, received) = spawn_mock_server(
            200,
            r#"{"data":{"signInForDesktop":{"token":"jwt.token.value","userId":"u-1","email":"demo@example.com","isPlatformAdmin":false}}}"#,
        );
        let api = HttpAuthApi::new(endpoint);

        let session = api.sign_in("demo@example.com", "demo").expect("sign in");
        assert_eq!(session.token, "jwt.token.value");
        assert_eq!(session.user_id, "u-1");
        assert_eq!(session.email.as_deref(), Some("demo@example.com"));
        assert!(!session.is_platform_admin);

        let request = received.recv().expect("request captured");
        assert!(request.contains("POST /api/graphql"), "request: {request}");
        assert!(request.contains("signInForDesktop"), "request: {request}");
        assert!(request.contains("demo@example.com"), "request: {request}");
    }

    #[test]
    fn http_sign_in_maps_authentication_failed_to_invalid_credentials() {
        let (endpoint, _received) = spawn_mock_server(
            200,
            r#"{"errors":[{"message":"Invalid email or password","code":"authentication_failed"}]}"#,
        );
        let api = HttpAuthApi::new(endpoint);

        assert!(matches!(
            api.sign_in("demo@example.com", "wrong"),
            Err(AuthError::InvalidCredentials)
        ));
    }

    #[test]
    fn validate_true_when_me_returns_id() {
        let (endpoint, received) = spawn_mock_server(200, r#"{"data":{"me":{"id":"user-1"}}}"#);
        let api = HttpAuthApi::new(endpoint);
        assert!(api.validate("jwt.token").expect("validate"));
        let request = received.recv().expect("request captured");
        assert!(request.contains("ValidateSession"), "request: {request}");
    }

    #[test]
    fn validate_false_on_forbidden_token() {
        let (endpoint, _received) = spawn_mock_server(
            200,
            r#"{"data":null,"errors":[{"message":"forbidden","code":"forbidden"}]}"#,
        );
        let api = HttpAuthApi::new(endpoint);
        assert!(!api.validate("expired").expect("validate"));
    }

    #[test]
    fn http_revoke_sends_bearer_header_and_succeeds() {
        let (endpoint, received) = spawn_mock_server(200, r#"{"data":{"revokeToken":true}}"#);
        let api = HttpAuthApi::new(endpoint);

        api.revoke("jwt.token.value").expect("revoke");
        let request = received.recv().expect("request captured");
        assert!(request.contains("revokeToken"), "request: {request}");
        assert!(
            request
                .to_ascii_lowercase()
                .contains("authorization: bearer jwt.token.value"),
            "request: {request}"
        );
    }
}
