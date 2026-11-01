use super::*;
use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::TcpListener;
use std::sync::{
    atomic::{AtomicBool, AtomicUsize, Ordering},
    Mutex,
};

struct CappedApi {
    tokens: Mutex<HashMap<String, LeaseIdentity>>,
    issued: AtomicUsize,
    revoked: Mutex<Vec<String>>,
    offline: AtomicBool,
    identities: AtomicUsize,
}

impl CappedApi {
    fn new() -> Self {
        Self {
            tokens: Mutex::new(HashMap::new()),
            issued: AtomicUsize::new(0),
            revoked: Mutex::new(Vec::new()),
            offline: AtomicBool::new(false),
            identities: AtomicUsize::new(0),
        }
    }
    fn seed(&self, token: &str, id: &str, user: &str, kind: &str) {
        self.tokens.lock().unwrap().insert(
            token.into(),
            LeaseIdentity {
                token_id: id.into(),
                user_id: user.into(),
                kind: kind.into(),
            },
        );
    }
}
impl LearningHostApi for CappedApi {
    fn issue(&self, user: &str, _: &str) -> Result<LearningHostLease, McpError> {
        let mut tokens = self.tokens.lock().unwrap();
        if tokens
            .values()
            .filter(|token| token.user_id == user)
            .count()
            >= 10
        {
            return Err(McpError::Domain {
                code: "mcp_token_limit_reached".into(),
                message: "Active credential limit reached".into(),
            });
        }
        let sequence = self.issued.fetch_add(1, Ordering::SeqCst);
        let token = format!("synthetic-lease-{sequence}");
        let id = format!("id-{sequence}");
        tokens.insert(
            token.clone(),
            LeaseIdentity {
                user_id: user.into(),
                token_id: id.clone(),
                kind: "learning_host".into(),
            },
        );
        Ok(LearningHostLease {
            token,
            token_id: id,
            epoch: 0,
        })
    }
    fn identity(&self, token: &str) -> Result<LeaseIdentity, McpError> {
        self.identities.fetch_add(1, Ordering::SeqCst);
        if self.offline.load(Ordering::SeqCst) {
            return Err(McpError::Transport("Offline".into()));
        }
        self.tokens
            .lock()
            .unwrap()
            .get(token)
            .cloned()
            .ok_or(McpError::Unauthorized)
    }
    fn revoke(&self, _: &str, id: &str) -> Result<(), McpError> {
        self.revoked.lock().unwrap().push(id.into());
        self.tokens
            .lock()
            .unwrap()
            .retain(|_, identity| identity.token_id != id);
        Ok(())
    }
    fn list(&self, _: &str) -> Result<Vec<McpToken>, McpError> {
        panic!("Credential recovery must not enumerate or revoke other clients");
    }
}

#[derive(Default)]
struct Vault {
    current: MemoryVault,
    legacy: MemoryVault,
    fail_save: AtomicBool,
    fail_load: AtomicBool,
}
impl SecretVault for Vault {
    fn save(&self, secret: &str) -> std::io::Result<()> {
        if self.fail_save.load(Ordering::SeqCst) {
            return Err(std::io::Error::other("Storage unavailable"));
        }
        self.current.save(secret)
    }
    fn load(&self) -> std::io::Result<Option<String>> {
        if self.fail_load.load(Ordering::SeqCst) {
            return Err(std::io::Error::other("Storage unavailable"));
        }
        self.current.load()
    }
    fn clear(&self) -> std::io::Result<()> {
        self.current.clear()
    }
    fn load_legacy(&self) -> std::io::Result<Option<String>> {
        self.legacy.load()
    }
    fn clear_legacy(&self) -> std::io::Result<()> {
        self.legacy.clear()
    }
}
fn scope() -> LeaseScope {
    LeaseScope::new("user-A", "https://api.codingirlsclub.com/api/graphql")
}
fn acquire(
    api: &CappedApi,
    vault: &dyn SecretVault,
    scope: &LeaseScope,
    epoch: u64,
) -> Result<LearningHostLease, McpError> {
    issue_lease(api, vault, &scope.user_id, "cgc-desktop", epoch, scope)
}

fn identity_server(
    status: u16,
    body: &str,
    extra_headers: &str,
) -> (HttpLearningHostApi, std::sync::mpsc::Receiver<String>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let body = body.to_string();
    let extra_headers = extra_headers.to_string();
    let (sent, received) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut request = Vec::new();
        let mut buffer = [0u8; 1024];
        while !request.windows(4).any(|bytes| bytes == b"\r\n\r\n") {
            let length = stream.read(&mut buffer).unwrap();
            if length == 0 {
                break;
            }
            request.extend_from_slice(&buffer[..length]);
        }
        sent.send(String::from_utf8(request).unwrap()).unwrap();
        let response = format!("HTTP/1.1 {status} Response\r\nContent-Type: application/json\r\n{extra_headers}Content-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len());
        stream.write_all(response.as_bytes()).unwrap();
    });
    (
        HttpLearningHostApi::new(GraphqlClient::new(format!("http://{address}/api/graphql"))),
        received,
    )
}

#[test]
fn http_identity_uses_the_presented_token_and_rejects_invalid_or_redirected_responses() {
    for (status, body, headers, accepted, invalid) in [
        (
            200,
            r#"{"user_id":"user-A","token_id":"id-A","kind":"learning_host"}"#,
            "",
            true,
            false,
        ),
        (401, r#"{"error":"invalid_token"}"#, "", false, true),
        (429, r#"{"error":"rate_limited"}"#, "", false, false),
        (503, r#"{"error":"unavailable"}"#, "", false, false),
        (200, r#"{"kind":"learning_host"}"#, "", false, false),
        (
            302,
            r#"{"user_id":"user-A","token_id":"id-A","kind":"learning_host"}"#,
            "Location: https://untrusted.example/mcp/token\r\n",
            false,
            false,
        ),
    ] {
        let (api, request) = identity_server(status, body, headers);
        let result = api.identity("synthetic-secret");
        assert_eq!(result.is_ok(), accepted);
        assert_eq!(matches!(result, Err(McpError::Unauthorized)), invalid);
        let request = request
            .recv_timeout(std::time::Duration::from_secs(2))
            .unwrap();
        assert!(request.starts_with("GET /mcp/token HTTP/1.1"));
        assert!(request
            .to_ascii_lowercase()
            .contains("authorization: bearer synthetic-secret"));
        if accepted {
            assert_eq!(result.unwrap().user_id, "user-A");
        }
    }
    let api = HttpLearningHostApi::new(GraphqlClient::new("https://untrusted.example/api/graphql"));
    assert!(
        matches!(api.identity("synthetic-secret"), Err(McpError::Server(message)) if message == "Credential server is not trusted")
    );
}

#[test]
fn repeated_cold_starts_reuse_verified_credentials_at_the_active_limit() {
    let api = Arc::new(CappedApi::new());
    let vault = Arc::new(Vault::default());
    let scope = scope();
    let first = acquire(&api, vault.as_ref(), &scope, 0).unwrap();
    for index in 0..9 {
        api.seed(
            &format!("other-{index}"),
            &format!("other-id-{index}"),
            "user-A",
            "learning_host",
        );
    }
    assert!(
        matches!(api.issue("user-A", "another client"), Err(McpError::Domain { code, .. }) if code == "mcp_token_limit_reached")
    );
    for epoch in 1..15 {
        let mut restarted = LearningHostCredentialService::new(api.clone(), vault.clone());
        let restored = restarted
            .issue("user-A", "cgc-desktop", epoch, &scope)
            .unwrap();
        assert_eq!(restored.token_id, first.token_id);
        assert_eq!(restored.epoch, epoch);
    }
    assert_eq!(api.issued.load(Ordering::SeqCst), 1);
    assert_eq!(api.identities.load(Ordering::SeqCst), 14);
    assert_eq!(api.tokens.lock().unwrap().len(), 10);
    assert!(api.revoked.lock().unwrap().is_empty());
}

#[test]
fn legacy_raw_credential_is_migrated_only_after_verifying_owner_and_kind() {
    for (user, kind, reused) in [
        ("user-A", "learning_host", true),
        ("user-B", "learning_host", false),
        ("user-A", "terminal", false),
    ] {
        let api = CappedApi::new();
        api.seed("legacy-secret", "legacy-id", user, kind);
        let vault = Vault::default();
        vault.legacy.save("legacy-secret").unwrap();
        let lease = acquire(&api, &vault, &scope(), 7).unwrap();
        assert_eq!(lease.token_id == "legacy-id", reused);
        assert_eq!(api.issued.load(Ordering::SeqCst), usize::from(!reused));
        assert_eq!(vault.legacy.load().unwrap().is_none(), reused);
        assert!(api.revoked.lock().unwrap().is_empty());
        let record: Value = serde_json::from_str(&vault.current.load().unwrap().unwrap()).unwrap();
        assert_eq!(record["user_id"], "user-A");
        assert_eq!(record["endpoint"], scope().endpoint);
        assert_eq!(record["token_id"], lease.token_id);
    }
}

#[test]
fn temporary_verification_failures_preserve_credentials_without_issuing_another() {
    let api = CappedApi::new();
    let vault = Vault::default();
    let first = acquire(&api, &vault, &scope(), 1).unwrap();
    let record = vault.current.load().unwrap();
    api.offline.store(true, Ordering::SeqCst);
    assert!(matches!(
        acquire(&api, &vault, &scope(), 2),
        Err(McpError::Transport(_))
    ));
    assert_eq!(vault.current.load().unwrap(), record);
    assert_eq!(api.issued.load(Ordering::SeqCst), 1);
    api.offline.store(false, Ordering::SeqCst);
    let recovered = acquire(&api, &vault, &scope(), 3).unwrap();
    assert_eq!(recovered.token_id, first.token_id);
    assert!(api.revoked.lock().unwrap().is_empty());
}

#[test]
fn revoked_credentials_are_replaced_and_scopes_are_never_crossed() {
    let api = CappedApi::new();
    let vault = Vault::default();
    let first = acquire(&api, &vault, &scope(), 1).unwrap();
    api.revoke("user-A", &first.token_id).unwrap();
    let replaced = acquire(&api, &vault, &scope(), 2).unwrap();
    assert_ne!(replaced.token_id, first.token_id);
    let identities = api.identities.load(Ordering::SeqCst);
    let other = LeaseScope::new(
        "user-A",
        "https://staging-api.codingirlsclub.com/api/graphql",
    );
    acquire(&api, &vault, &other, 3).unwrap();
    assert_eq!(api.identities.load(Ordering::SeqCst), identities);
    assert_ne!(scope().account(), other.account());
    assert_ne!(
        scope().account(),
        LeaseScope::new("user-B", &scope().endpoint).account()
    );
}

#[test]
fn saved_token_identity_must_match_the_verified_token_id() {
    let api = CappedApi::new();
    let vault = Vault::default();
    let saved = acquire(&api, &vault, &scope(), 1).unwrap();
    api.seed(&saved.token, "mismatched-id", "user-A", "learning_host");
    let next = acquire(&api, &vault, &scope(), 2).unwrap();
    assert_ne!(next.token, saved.token);
    assert_eq!(api.issued.load(Ordering::SeqCst), 2);
    assert!(api.revoked.lock().unwrap().is_empty());
}

#[test]
fn failed_storage_rolls_back_only_new_issuance_and_keeps_legacy_recoverable() {
    let api = CappedApi::new();
    let vault = Vault::default();
    vault.fail_save.store(true, Ordering::SeqCst);
    assert!(matches!(
        acquire(&api, &vault, &scope(), 1),
        Err(McpError::Storage(_))
    ));
    assert_eq!(*api.revoked.lock().unwrap(), vec!["id-0"]);
    api.seed("legacy-secret", "legacy-id", "user-A", "learning_host");
    vault.legacy.save("legacy-secret").unwrap();
    assert!(matches!(
        acquire(&api, &vault, &scope(), 2),
        Err(McpError::Storage(_))
    ));
    assert!(vault.legacy.load().unwrap().is_some());
    assert_eq!(*api.revoked.lock().unwrap(), vec!["id-0"]);
    let issued = api.issued.load(Ordering::SeqCst);
    vault.fail_load.store(true, Ordering::SeqCst);
    assert!(matches!(
        acquire(&api, &vault, &scope(), 3),
        Err(McpError::Storage(_))
    ));
    assert_eq!(api.issued.load(Ordering::SeqCst), issued);
}

#[test]
fn sign_out_revokes_only_the_credential_saved_for_this_scope() {
    let api = CappedApi::new();
    let vault = Vault::default();
    let saved = acquire(&api, &vault, &scope(), 1).unwrap();
    api.seed("other-device", "other-id", "user-A", "learning_host");
    let other_scope = LeaseScope::new("user-B", &scope().endpoint);
    revoke_saved_lease(&api, &vault, "user-B", &other_scope).unwrap();
    assert!(api.revoked.lock().unwrap().is_empty());
    revoke_saved_lease(&api, &vault, "user-A", &scope()).unwrap();
    assert_eq!(*api.revoked.lock().unwrap(), vec![saved.token_id]);
    assert!(api.tokens.lock().unwrap().contains_key("other-device"));
    assert!(vault.current.load().unwrap().is_none());
}
