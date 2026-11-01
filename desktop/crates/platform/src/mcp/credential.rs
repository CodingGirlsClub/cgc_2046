//! learning_host 凭证（story 2.8）：第一方签发、绑定 epoch 的 lease、只存 keychain。
//!
//! 契约：`createMcpToken(name, kind: LEARNING_HOST)` 返回一次性明文 `plainToken`
//! 与 token 记录；凭证按账号与服务端保存在 OS keychain，冷启动先核实身份再复用。
//! 工作台切换仅撤销旧客户端的本地访问能力；登出只撤销本机保存的凭证。
//! 明文不实现 Debug 输出、不进日志。

use std::sync::Arc;

use serde_json::Value;
use sha2::{Digest, Sha256};

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

const MY_TOKENS_QUERY: &str = r#"
query MyLearningHostTokens {
  myMcpTokens { id name kind }
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

#[derive(Clone, Debug, PartialEq, Eq)]
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

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LeaseScope {
    pub user_id: String,
    pub endpoint: String,
}

impl LeaseScope {
    pub fn new(user_id: impl Into<String>, api_url: &str) -> Self {
        Self {
            user_id: user_id.into(),
            endpoint: api_url.trim_end_matches('/').into(),
        }
    }

    fn account(&self) -> String {
        let digest = Sha256::digest(format!("{}\0{}", self.endpoint, self.user_id).as_bytes());
        format!("{LEARNING_HOST_ACCOUNT}:{digest:x}")
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LeaseIdentity {
    pub user_id: String,
    pub token_id: String,
    pub kind: String,
}

pub trait LearningHostApi: Send + Sync {
    fn issue(&self, session_token: &str, name: &str) -> Result<LearningHostLease, McpError>;
    fn revoke(&self, session_token: &str, token_id: &str) -> Result<(), McpError>;
    fn list(&self, session_token: &str) -> Result<Vec<McpToken>, McpError>;
    fn identity(&self, token: &str) -> Result<LeaseIdentity, McpError>;
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
    fn identity(&self, token: &str) -> Result<LeaseIdentity, McpError> {
        if !crate::runtime::is_allowed_endpoint(self.client.endpoint()) {
            return Err(McpError::Server("Credential server is not trusted".into()));
        }
        let endpoint = super::inject::mcp_endpoint(Some(self.client.endpoint()));
        let config = ureq::Agent::config_builder()
            .timeout_global(Some(self.client.timeout()))
            .max_redirects(0)
            .build();
        let agent: ureq::Agent = config.into();
        let mut response = agent
            .get(format!("{endpoint}/token"))
            .header("authorization", format!("Bearer {token}"))
            .call()
            .map_err(|error| match error {
                ureq::Error::StatusCode(401) => McpError::Unauthorized,
                ureq::Error::StatusCode(status) => {
                    McpError::Server(format!("Credential verification returned HTTP {status}"))
                }
                ureq::Error::Timeout(_) => {
                    McpError::Transport("Credential verification timed out".into())
                }
                _ => McpError::Transport("Credential verification failed".into()),
            })?;
        if response.status().as_u16() != 200 {
            return Err(McpError::Server(
                "Credential verification did not succeed".into(),
            ));
        }
        let payload = response
            .body_mut()
            .read_json::<Value>()
            .map_err(|_| McpError::Server("Invalid credential identity response".into()))?;
        let field = |name| {
            payload
                .get(name)
                .and_then(Value::as_str)
                .filter(|value| !value.is_empty())
                .map(str::to_string)
                .ok_or_else(|| McpError::Server("Incomplete credential identity response".into()))
        };
        Ok(LeaseIdentity {
            user_id: field("user_id")?,
            token_id: field("token_id")?,
            kind: field("kind")?,
        })
    }

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

    fn list(&self, session_token: &str) -> Result<Vec<McpToken>, McpError> {
        let payload = self
            .client
            .post(Some(session_token), MY_TOKENS_QUERY, serde_json::json!({}))
            .map_err(map_api_error)?;
        let tokens = payload
            .get("data")
            .and_then(|data| data.get("myMcpTokens"))
            .and_then(Value::as_array)
            .ok_or_else(|| McpError::Server("missing myMcpTokens payload".to_string()))?;
        Ok(tokens
            .iter()
            .filter_map(|value| {
                Some(McpToken {
                    id: value.get("id")?.as_str()?.to_string(),
                    name: value.get("name")?.as_str().unwrap_or("").to_string(),
                    kind: value.get("kind")?.as_str()?.to_string(),
                })
            })
            .collect())
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

    fn list(&self, _session_token: &str) -> Result<Vec<McpToken>, McpError> {
        Ok(Vec::new())
    }

    fn identity(&self, _token: &str) -> Result<LeaseIdentity, McpError> {
        Err(McpError::Unauthorized)
    }
}

/// keychain 持久化 seam；生产用 OS keychain，测试用内存。
pub trait SecretVault: Send + Sync {
    fn save(&self, secret: &str) -> std::io::Result<()>;
    fn load(&self) -> std::io::Result<Option<String>>;
    fn clear(&self) -> std::io::Result<()>;
    fn load_legacy(&self) -> std::io::Result<Option<String>> {
        Ok(None)
    }
    fn clear_legacy(&self) -> std::io::Result<()> {
        Ok(())
    }
}

pub struct KeychainVault {
    store: KeychainStore,
    account: String,
}

impl KeychainVault {
    pub fn from_env() -> Self {
        Self {
            store: KeychainStore::from_env(),
            account: LEARNING_HOST_ACCOUNT.into(),
        }
    }

    pub fn for_scope(scope: &LeaseScope) -> Self {
        Self {
            store: KeychainStore::from_env(),
            account: scope.account(),
        }
    }
}

impl SecretVault for KeychainVault {
    fn save(&self, secret: &str) -> std::io::Result<()> {
        self.store.save_secret(&self.account, secret)
    }
    fn load(&self) -> std::io::Result<Option<String>> {
        self.store.try_load_secret(&self.account)
    }
    fn clear(&self) -> std::io::Result<()> {
        self.store.clear_secret(&self.account)
    }
    fn load_legacy(&self) -> std::io::Result<Option<String>> {
        if self.account == LEARNING_HOST_ACCOUNT {
            return Ok(None);
        }
        self.store.try_load_secret(LEARNING_HOST_ACCOUNT)
    }
    fn clear_legacy(&self) -> std::io::Result<()> {
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

/// 恢复并核实本机凭证，确认失效后才签发；明文只保存在系统钥匙串。
pub fn issue_lease(
    api: &dyn LearningHostApi,
    vault: &dyn SecretVault,
    session_token: &str,
    name: &str,
    epoch: u64,
    scope: &LeaseScope,
) -> Result<LearningHostLease, McpError> {
    let stored = vault.load().map_err(storage_error)?;
    let legacy = stored.is_none();
    let candidate = match stored {
        Some(stored) => Some(stored),
        None => vault.load_legacy().map_err(storage_error)?,
    };
    if let Some(candidate) = candidate {
        let record = serde_json::from_str::<Value>(&candidate).ok();
        let scoped = record.as_ref().is_some_and(Value::is_object);
        let same_scope = record.as_ref().is_none_or(|record| {
            record.get("endpoint").and_then(Value::as_str) == Some(scope.endpoint.as_str())
                && record.get("user_id").and_then(Value::as_str) == Some(scope.user_id.as_str())
        });
        if same_scope {
            let token = if scoped {
                record
                    .as_ref()
                    .and_then(|record| record.get("token"))
                    .and_then(Value::as_str)
            } else {
                Some(candidate.as_str())
            };
            if let Some(token) = token.filter(|token| !token.is_empty()) {
                match api.identity(token) {
                    Ok(identity)
                        if identity.user_id == scope.user_id
                            && identity.kind == "learning_host"
                            && (!scoped
                                || record
                                    .as_ref()
                                    .and_then(|record| record.get("token_id"))
                                    .and_then(Value::as_str)
                                    == Some(identity.token_id.as_str())) =>
                    {
                        let lease = LearningHostLease {
                            token: token.into(),
                            token_id: identity.token_id,
                            epoch,
                        };
                        if legacy || !scoped {
                            save_lease(vault, scope, &lease)?;
                            if legacy {
                                let _ = vault.clear_legacy();
                            }
                        }
                        return Ok(lease);
                    }
                    Ok(_) | Err(McpError::Unauthorized) => {}
                    Err(error) => return Err(error),
                }
            }
        }
    }
    let mut lease = api.issue(session_token, name)?;
    lease.epoch = epoch;
    if let Err(error) = save_lease(vault, scope, &lease) {
        let _ = api.revoke(session_token, &lease.token_id);
        return Err(error);
    }
    Ok(lease)
}

fn storage_error(_error: std::io::Error) -> McpError {
    McpError::Storage("Cannot access the platform credential in the system keychain".into())
}

fn save_lease(
    vault: &dyn SecretVault,
    scope: &LeaseScope,
    lease: &LearningHostLease,
) -> Result<(), McpError> {
    vault
        .save(
            &serde_json::json!({
                "endpoint": scope.endpoint, "user_id": scope.user_id,
                "token_id": lease.token_id, "token": lease.token,
            })
            .to_string(),
        )
        .map_err(storage_error)
}

pub fn revoke_saved_lease(
    api: &dyn LearningHostApi,
    vault: &dyn SecretVault,
    session_token: &str,
    scope: &LeaseScope,
) -> Result<(), McpError> {
    let Some(record) = vault.load().map_err(storage_error)? else {
        return Ok(());
    };
    let Ok(record) = serde_json::from_str::<Value>(&record) else {
        return Ok(());
    };
    if record.get("endpoint").and_then(Value::as_str) != Some(scope.endpoint.as_str())
        || record.get("user_id").and_then(Value::as_str) != Some(scope.user_id.as_str())
    {
        return Ok(());
    }
    let Some(id) = record.get("token_id").and_then(Value::as_str) else {
        return Ok(());
    };
    api.revoke(session_token, id)?;
    vault.clear().map_err(storage_error)
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

    pub fn from_runtime(scope: &LeaseScope) -> Self {
        let use_http = !crate::runtime::use_fake_backend();
        let api: Arc<dyn LearningHostApi> = if use_http {
            Arc::new(HttpLearningHostApi::new(GraphqlClient::new(
                &scope.endpoint,
            )))
        } else {
            Arc::new(FakeLearningHostApi::default())
        };
        Self::new(api, Arc::new(KeychainVault::for_scope(scope)))
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
        scope: &LeaseScope,
    ) -> Result<&LearningHostLease, McpError> {
        let lease = issue_lease(
            self.api.as_ref(),
            self.vault.as_ref(),
            session_token,
            name,
            epoch,
            scope,
        )?;
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
mod tests;

#[cfg(test)]
mod http_tests {
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
            let lease = service
                .issue(
                    session_token(),
                    "desktop",
                    7,
                    &LeaseScope::new("user-1", "https://api.codingirlsclub.com/api/graphql"),
                )
                .expect("issue");
            assert_eq!(lease.epoch, 7);
            (lease.token.clone(), lease.token_id.clone())
        };
        assert_eq!(
            serde_json::from_str::<Value>(&vault.load().unwrap().unwrap()).unwrap()["token"],
            token
        );
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
        service
            .issue(
                session_token(),
                "desktop",
                1,
                &LeaseScope::new("user-1", "https://api.codingirlsclub.com/api/graphql"),
            )
            .expect("issue");
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
