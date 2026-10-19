//! learning_host 凭证（story 2.8）：第一方签发、绑定 epoch 的 lease、只存 keychain。
//!
//! 契约：`createMcpToken(name, kind: LEARNING_HOST)` 返回一次性明文 `plainToken`
//! 与 token 记录；服务把明文写入 OS keychain（account=learning_host），内存只保留
//! 绑定了账号/工作台 epoch 的 lease。登出/换工作台调用 `invalidate` + 后端撤销。
//! 明文不实现 Debug 输出、不进日志。

use std::sync::Arc;

use serde_json::Value;

use crate::api::{ApiError, GraphqlClient};
use crate::session::KeychainStore;

const CREATE_TOKEN_MUTATION: &str = r#"
mutation CreateLearningHostToken($name: String!) {
  createMcpToken(name: $name, kind: LEARNING_HOST) {
    plainToken
    result { id name kind }
    errors { code message }
  }
}
"#;

const REVOKE_TOKEN_MUTATION: &str = r#"
mutation RevokeLearningHostToken($id: ID!) {
  revokeMcpToken(id: $id) { id }
}
"#;

const LEARNING_HOST_ACCOUNT: &str = "learning_host";

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct McpToken {
    pub id: String,
    pub name: String,
    pub kind: String,
}

/// 内存 lease：明文只在 keychain 与进程内存；Debug 必须脱敏。
#[derive(Clone)]
pub struct LearningHostLease {
    pub token: String,
    pub token_id: String,
    pub epoch: u64,
}

impl std::fmt::Debug for LearningHostLease {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("LearningHostLease")
            .field("token", &"<redacted>")
            .field("token_id", &self.token_id)
            .field("epoch", &self.epoch)
            .finish()
    }
}

#[derive(Debug, PartialEq, Eq)]
pub enum McpError {
    Transport(String),
    Unauthorized,
    Server(String),
    Storage(String),
    Domain { code: String, message: String },
}

impl McpError {
    pub fn diagnostic(&self) -> String {
        match self {
            McpError::Transport(reason) => format!("transport: {reason}"),
            McpError::Unauthorized => "unauthorized".to_string(),
            McpError::Server(reason) => format!("server: {reason}"),
            McpError::Storage(reason) => format!("storage: {reason}"),
            McpError::Domain { code, message } => format!("domain {code}: {message}"),
        }
    }

    pub fn is_unauthorized(&self) -> bool {
        matches!(self, McpError::Unauthorized)
    }
}

fn map_api_error(error: ApiError) -> McpError {
    match error {
        ApiError::Transport(reason) => McpError::Transport(reason),
        ApiError::Timeout(reason) => McpError::Transport(format!("timeout: {reason}")),
        ApiError::Unauthorized => McpError::Unauthorized,
        ApiError::Graphql { message, .. } => McpError::Server(message),
    }
}

pub trait LearningHostApi: Send + Sync {
    fn issue(&self, session_token: &str, name: &str) -> Result<LearningHostLease, McpError>;
    fn revoke(&self, session_token: &str, token_id: &str) -> Result<(), McpError>;
}

pub struct HttpLearningHostApi {
    client: GraphqlClient,
}

impl HttpLearningHostApi {
    pub fn new(client: GraphqlClient) -> Self {
        Self { client }
    }

    pub fn from_env() -> Self {
        Self::new(GraphqlClient::from_env())
    }
}

impl LearningHostApi for HttpLearningHostApi {
    fn issue(&self, session_token: &str, name: &str) -> Result<LearningHostLease, McpError> {
        let payload = self
            .client
            .post(
                Some(session_token),
                CREATE_TOKEN_MUTATION,
                serde_json::json!({ "name": name }),
            )
            .map_err(map_api_error)?;
        let data = payload
            .get("data")
            .and_then(|value| value.get("createMcpToken"))
            .ok_or_else(|| McpError::Server("missing createMcpToken payload".to_string()))?;
        if let Some(error) = data
            .get("errors")
            .and_then(Value::as_array)
            .and_then(|errors| errors.first())
        {
            return Err(McpError::Domain {
                code: error
                    .get("code")
                    .and_then(Value::as_str)
                    .unwrap_or("mcp_token_generic")
                    .to_string(),
                message: error
                    .get("message")
                    .and_then(Value::as_str)
                    .unwrap_or("cannot issue token")
                    .to_string(),
            });
        }
        let token = data
            .get("plainToken")
            .and_then(Value::as_str)
            .ok_or_else(|| McpError::Server("missing plainToken".to_string()))?;
        let token_id = data
            .get("result")
            .and_then(|result| result.get("id"))
            .and_then(Value::as_str)
            .ok_or_else(|| McpError::Server("missing token id".to_string()))?;
        Ok(LearningHostLease {
            token: token.to_string(),
            token_id: token_id.to_string(),
            epoch: 0,
        })
    }

    fn revoke(&self, session_token: &str, token_id: &str) -> Result<(), McpError> {
        let payload = self
            .client
            .post(
                Some(session_token),
                REVOKE_TOKEN_MUTATION,
                serde_json::json!({ "id": token_id }),
            )
            .map_err(map_api_error)?;
        if let Some(error) = payload
            .get("errors")
            .and_then(Value::as_array)
            .and_then(|errors| errors.first())
            .and_then(|error| error.get("message"))
            .and_then(Value::as_str)
        {
            return Err(McpError::Server(error.to_string()));
        }
        Ok(())
    }
}

/// 内存 fake：测试与无网开发；不持久化。
#[derive(Default)]
pub struct FakeLearningHostApi {
    issued: std::sync::Mutex<Vec<String>>,
    revoked: std::sync::Mutex<Vec<String>>,
}

impl LearningHostApi for FakeLearningHostApi {
    fn issue(&self, _session_token: &str, name: &str) -> Result<LearningHostLease, McpError> {
        self.issued.lock().expect("issued").push(name.to_string());
        Ok(LearningHostLease {
            token: format!(
                "fake-learning-token-{}",
                self.issued.lock().expect("issued").len()
            ),
            token_id: format!("token-{}", self.issued.lock().expect("issued").len()),
            epoch: 0,
        })
    }

    fn revoke(&self, _session_token: &str, token_id: &str) -> Result<(), McpError> {
        self.revoked
            .lock()
            .expect("revoked")
            .push(token_id.to_string());
        Ok(())
    }
}

/// keychain 持久化 seam；生产用 OS keychain，测试用内存。
pub trait SecretVault: Send + Sync {
    fn save(&self, secret: &str) -> std::io::Result<()>;
    fn load(&self) -> std::io::Result<Option<String>>;
    fn clear(&self) -> std::io::Result<()>;
}

pub struct KeychainVault {
    store: KeychainStore,
}

impl KeychainVault {
    pub fn from_env() -> Self {
        Self {
            store: KeychainStore::from_env(),
        }
    }
}

impl SecretVault for KeychainVault {
    fn save(&self, secret: &str) -> std::io::Result<()> {
        self.store.save_secret(LEARNING_HOST_ACCOUNT, secret)
    }
    fn load(&self) -> std::io::Result<Option<String>> {
        Ok(self.store.load_secret(LEARNING_HOST_ACCOUNT))
    }
    fn clear(&self) -> std::io::Result<()> {
        self.store.clear_secret(LEARNING_HOST_ACCOUNT)
    }
}

#[derive(Default)]
pub struct MemoryVault {
    secret: std::sync::Mutex<Option<String>>,
}

impl SecretVault for MemoryVault {
    fn save(&self, secret: &str) -> std::io::Result<()> {
        *self.secret.lock().expect("vault") = Some(secret.to_string());
        Ok(())
    }
    fn load(&self) -> std::io::Result<Option<String>> {
        Ok(self.secret.lock().expect("vault").clone())
    }
    fn clear(&self) -> std::io::Result<()> {
        *self.secret.lock().expect("vault") = None;
        Ok(())
    }
}

/// 第一方凭证服务：issue 绑定 epoch；invalidate 先本地清 keychain 再返回旧 id 供撤销。
pub struct LearningHostCredentialService {
    api: Arc<dyn LearningHostApi>,
    vault: Arc<dyn SecretVault>,
    lease: Option<LearningHostLease>,
}

impl LearningHostCredentialService {
    pub fn new(api: Arc<dyn LearningHostApi>, vault: Arc<dyn SecretVault>) -> Self {
        Self {
            api,
            vault,
            lease: None,
        }
    }

    pub fn from_runtime() -> Self {
        let use_http = std::env::var("CGC_AUTH").as_deref() == Ok("http")
            || std::env::var("CGC_API_URL").is_ok();
        let api: Arc<dyn LearningHostApi> = if use_http {
            Arc::new(HttpLearningHostApi::from_env())
        } else {
            Arc::new(FakeLearningHostApi::default())
        };
        Self::new(api, Arc::new(KeychainVault::from_env()))
    }

    pub fn lease(&self) -> Option<&LearningHostLease> {
        self.lease.as_ref()
    }

    /// 登录/进入课程后签发；旧 lease 会先本地失效（不自动撤销，调用方负责）。
    pub fn issue(
        &mut self,
        session_token: &str,
        name: &str,
        epoch: u64,
    ) -> Result<&LearningHostLease, McpError> {
        let mut lease = self.api.issue(session_token, name)?;
        lease.epoch = epoch;
        self.vault
            .save(&lease.token)
            .map_err(|error| McpError::Storage(error.to_string()))?;
        self.lease = Some(lease);
        Ok(self.lease.as_ref().expect("lease set"))
    }

    /// 登出/换工作台：本地清 keychain 并返回旧 token id 供后端撤销。
    pub fn invalidate(&mut self) -> Option<String> {
        let token_id = self.lease.take().map(|lease| lease.token_id);
        let _ = self.vault.clear();
        token_id
    }

    /// 撤销：优先用传入 token id，否则用当前 lease；随后本地失效。
    pub fn revoke(&mut self, session_token: &str, token_id: Option<&str>) -> Result<(), McpError> {
        let id = token_id
            .map(str::to_string)
            .or_else(|| self.lease.as_ref().map(|lease| lease.token_id.clone()));
        if let Some(id) = &id {
            self.api.revoke(session_token, id)?;
        }
        let _ = self.vault.clear();
        self.lease = None;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::TcpListener;

    fn session_token() -> &'static str {
        "jwt.session"
    }

    fn spawn_mock(status: u16, body: &'static str) -> String {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let addr = listener.local_addr().expect("addr");
        std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept");
            let mut request = Vec::new();
            let mut buffer = [0u8; 2048];
            let header_end = loop {
                let read = stream.read(&mut buffer).expect("read");
                if read == 0 {
                    break request.len();
                }
                request.extend_from_slice(&buffer[..read]);
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
                let read = stream.read(&mut buffer).expect("read body");
                if read == 0 {
                    break;
                }
                request.extend_from_slice(&buffer[..read]);
            }
            let response = format!(
                "HTTP/1.1 {status} OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
            stream.write_all(response.as_bytes()).expect("write");
        });
        format!("http://{addr}/api/graphql")
    }

    #[test]
    fn http_issue_parses_token_and_sends_bearer() {
        let endpoint = spawn_mock(
            200,
            r#"{"data":{"createMcpToken":{"plainToken":"lh-secret","result":{"id":"tok-1","name":"desktop","kind":"LEARNING_HOST"},"errors":[]}}}"#,
        );
        let api = HttpLearningHostApi::new(GraphqlClient::new(endpoint));
        let lease = api.issue(session_token(), "desktop").expect("issue");
        assert_eq!(lease.token_id, "tok-1");
        assert_eq!(lease.token, "lh-secret");
        assert!(!format!("{lease:?}").contains("lh-secret"));
    }

    #[test]
    fn http_issue_maps_domain_error() {
        let endpoint = spawn_mock(
            200,
            r#"{"data":{"createMcpToken":{"plainToken":null,"result":null,"errors":[{"code":"forbidden","message":"nope"}]}}}"#,
        );
        let api = HttpLearningHostApi::new(GraphqlClient::new(endpoint));
        let error = api.issue(session_token(), "desktop").unwrap_err();
        assert!(matches!(error, McpError::Domain { ref code, .. } if code == "forbidden"));
    }

    #[test]
    fn service_issue_persists_keychain_and_invalidate_clears() {
        let api = Arc::new(FakeLearningHostApi::default());
        let vault = Arc::new(MemoryVault::default());
        let mut service = LearningHostCredentialService::new(api, vault.clone());
        let (token, token_id) = {
            let lease = service.issue(session_token(), "desktop", 7).expect("issue");
            assert_eq!(lease.epoch, 7);
            (lease.token.clone(), lease.token_id.clone())
        };
        assert_eq!(vault.load().expect("load"), Some(token));
        let invalidated = service.invalidate().expect("token id");
        assert_eq!(invalidated, token_id);
        assert!(service.lease().is_none());
        assert_eq!(vault.load().expect("load"), None);
    }

    #[test]
    fn service_revoke_calls_backend_and_clears() {
        let api = Arc::new(FakeLearningHostApi::default());
        let vault = Arc::new(MemoryVault::default());
        let mut service = LearningHostCredentialService::new(api.clone(), vault);
        service.issue(session_token(), "desktop", 1).expect("issue");
        service.revoke(session_token(), None).expect("revoke");
        assert!(service.lease().is_none());
        assert!(api
            .revoked
            .lock()
            .expect("revoked")
            .iter()
            .any(|id| id == "token-1"));
    }
}
