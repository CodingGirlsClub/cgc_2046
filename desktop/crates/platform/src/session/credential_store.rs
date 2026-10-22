//! 会话凭证存储（story 2.1 的 tracer 版本）。
//!
//! 桌面端最终用 keychain（story 2.7 的 fail-closed 适配器）；本 tracer 先提供：
//! - `MemoryStore`：测试与临时会话；
//! - `FileStore`：跨重启的本地开发/离线演示存储（仅当前用户可读，Unix 0600）。
//!
//! 选择文件存储是 tracer 的已知妥协，记录在 story 2.1 的 Decision；keychain 适配器
//! 落地后 UI/服务层不需要改（只换 `CredentialStore` 实现）。

use std::fs;
use std::io;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use super::SignedInSession;

/// 存储接口：load 返回 None 表示未登录/无有效凭证。
pub trait CredentialStore {
    fn load(&self) -> Option<SignedInSession>;
    fn save(&self, session: &SignedInSession) -> io::Result<()>;
    fn clear(&self) -> io::Result<()>;
}

/// Clone 共享同一块内存，便于「重启后恢复」测试用同一 store 重建服务。
#[derive(Default, Clone)]
pub struct MemoryStore {
    session: Arc<Mutex<Option<SignedInSession>>>,
}

impl CredentialStore for MemoryStore {
    fn load(&self) -> Option<SignedInSession> {
        self.session.lock().expect("memory store poisoned").clone()
    }

    fn save(&self, session: &SignedInSession) -> io::Result<()> {
        *self.session.lock().expect("memory store poisoned") = Some(session.clone());
        Ok(())
    }

    fn clear(&self) -> io::Result<()> {
        *self.session.lock().expect("memory store poisoned") = None;
        Ok(())
    }
}

#[derive(Clone, Debug)]
pub struct FileStore {
    path: PathBuf,
}

impl FileStore {
    pub fn new(path: impl Into<PathBuf>) -> Self {
        Self { path: path.into() }
    }

    /// 默认路径：`CGC_SESSION_FILE` > 环境隔离的数据根（story 1.9）。
    pub fn default_path() -> PathBuf {
        if let Some(path) = std::env::var_os("CGC_SESSION_FILE") {
            return path.into();
        }
        crate::paths::AppPaths::from_env().session_file()
    }
}

impl CredentialStore for FileStore {
    fn load(&self) -> Option<SignedInSession> {
        let raw = fs::read_to_string(&self.path).ok()?;
        let value: serde_json::Value = serde_json::from_str(&raw).ok()?;
        Some(SignedInSession {
            token: value.get("token")?.as_str()?.to_string(),
            user_id: value.get("user_id").and_then(|v| v.as_str())?.to_string(),
            email: value
                .get("email")
                .and_then(|v| v.as_str())
                .map(str::to_string),
            is_platform_admin: value
                .get("is_platform_admin")
                .and_then(|v| v.as_bool())
                .unwrap_or(false),
        })
    }

    fn save(&self, session: &SignedInSession) -> io::Result<()> {
        if let Some(parent) = self.path.parent() {
            fs::create_dir_all(parent)?;
        }
        let payload = serde_json::json!({
            "token": session.token,
            "user_id": session.user_id,
            "email": session.email,
            "is_platform_admin": session.is_platform_admin,
        })
        .to_string();

        #[cfg(unix)]
        {
            use std::io::Write;
            use std::os::unix::fs::OpenOptionsExt;
            let mut file = fs::OpenOptions::new()
                .create(true)
                .truncate(true)
                .write(true)
                .mode(0o600)
                .open(&self.path)?;
            file.write_all(payload.as_bytes())?;
        }
        #[cfg(not(unix))]
        {
            fs::write(&self.path, payload)?;
        }
        Ok(())
    }

    fn clear(&self) -> io::Result<()> {
        match fs::remove_file(&self.path) {
            Ok(()) => Ok(()),
            Err(err) if err.kind() == io::ErrorKind::NotFound => Ok(()),
            Err(err) => Err(err),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn session(token: &str) -> SignedInSession {
        SignedInSession {
            token: token.to_string(),
            user_id: "user-1".to_string(),
            email: Some("demo@example.com".to_string()),
            is_platform_admin: false,
        }
    }

    #[test]
    fn memory_store_round_trips() {
        let store = MemoryStore::default();
        assert!(store.load().is_none());
        store.save(&session("t1")).expect("save");
        assert_eq!(store.load().map(|s| s.token), Some("t1".to_string()));
        store.clear().expect("clear");
        assert!(store.load().is_none());
    }

    #[test]
    fn file_store_round_trips_and_clears() {
        let dir = std::env::temp_dir().join(format!("cgc-session-{}", std::process::id()));
        let path = dir.join("session.json");
        let store = FileStore::new(&path);

        store.clear().expect("clear missing is ok");
        store.save(&session("t2")).expect("save");
        assert_eq!(
            store.load().map(|s| s.email),
            Some(Some("demo@example.com".into()))
        );

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = fs::metadata(&path).expect("metadata").permissions().mode() & 0o777;
            assert_eq!(mode, 0o600, "session file must be owner-only");
        }

        store.clear().expect("clear");
        assert!(store.load().is_none());
        let _ = fs::remove_dir_all(&dir);
    }
}

// ---------------------------------------------------------------------------
// 2.7：OS keychain 适配器（fail-closed；不可用时拒绝持久登录、不落明文）
// ---------------------------------------------------------------------------

#[cfg(target_os = "linux")]
use std::process::{Command, Stdio};

/// 平台密钥后端；测试可注入内存/不可用实现。
pub trait SecretBackend: Send + Sync {
    fn set(&self, account: &str, secret: &str) -> io::Result<()>;
    fn get(&self, account: &str) -> io::Result<Option<String>>;
    fn delete(&self, account: &str) -> io::Result<()>;
}

fn unavailable(reason: &str) -> io::Error {
    io::Error::new(io::ErrorKind::Unsupported, reason.to_string())
}

/// macOS Security.framework 通用密码（service=cgc-desktop）。
#[cfg(target_os = "macos")]
pub struct MacKeychain {
    service: String,
}

#[cfg(target_os = "macos")]
impl MacKeychain {
    pub fn new(service: impl Into<String>) -> Self {
        Self {
            service: service.into(),
        }
    }
}

#[cfg(target_os = "macos")]
impl SecretBackend for MacKeychain {
    fn set(&self, account: &str, secret: &str) -> io::Result<()> {
        security_framework::passwords::set_generic_password(
            &self.service,
            account,
            secret.as_bytes(),
        )
        .map_err(|error| io::Error::other(error.to_string()))
    }

    fn get(&self, account: &str) -> io::Result<Option<String>> {
        match security_framework::passwords::get_generic_password(&self.service, account) {
            Ok(bytes) => String::from_utf8(bytes)
                .map(Some)
                .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error.to_string())),
            Err(_) => Ok(None),
        }
    }

    fn delete(&self, account: &str) -> io::Result<()> {
        match security_framework::passwords::delete_generic_password(&self.service, account) {
            Ok(()) => Ok(()),
            Err(_) => Ok(()),
        }
    }
}

/// Linux：`secret-tool`（libsecret）。secret 走 stdin，不进程参数/日志。
#[cfg(target_os = "linux")]
pub struct LinuxSecretTool {
    service: String,
}

#[cfg(target_os = "linux")]
impl LinuxSecretTool {
    pub fn new(service: impl Into<String>) -> Self {
        Self {
            service: service.into(),
        }
    }
    fn available() -> bool {
        Command::new("secret-tool")
            .arg("--version")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .map(|status| status.success())
            .unwrap_or(false)
    }
}

#[cfg(target_os = "linux")]
impl SecretBackend for LinuxSecretTool {
    fn set(&self, account: &str, secret: &str) -> io::Result<()> {
        if !Self::available() {
            return Err(unavailable("secret-tool is not installed"));
        }
        use std::io::Write;
        let mut child = Command::new("secret-tool")
            .args([
                "store",
                "--label",
                "CGC Desktop session",
                "service",
                &self.service,
                "account",
                account,
            ])
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()?;
        child
            .stdin
            .as_mut()
            .ok_or_else(|| unavailable("cannot write secret to stdin"))?
            .write_all(secret.as_bytes())?;
        let status = child.wait()?;
        if status.success() {
            Ok(())
        } else {
            Err(io::Error::other("secret-tool store failed"))
        }
    }

    fn get(&self, account: &str) -> io::Result<Option<String>> {
        if !Self::available() {
            return Err(unavailable("secret-tool is not installed"));
        }
        let output = Command::new("secret-tool")
            .args(["lookup", "service", &self.service, "account", account])
            .output()?;
        if !output.status.success() || output.stdout.is_empty() {
            return Ok(None);
        }
        String::from_utf8(output.stdout)
            .map(Some)
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error.to_string()))
    }

    fn delete(&self, account: &str) -> io::Result<()> {
        if !Self::available() {
            return Err(unavailable("secret-tool is not installed"));
        }
        let _ = Command::new("secret-tool")
            .args(["clear", "service", &self.service, "account", account])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()?;
        Ok(())
    }
}

/// Generic credential 的 blob 上限（CRED_MAX_CREDENTIAL_BLOB_SIZE = 5 * 512）。
#[cfg_attr(not(target_os = "windows"), allow(dead_code))]
const CREDENTIAL_BLOB_MAX: usize = 5 * 512;

#[cfg_attr(not(target_os = "windows"), allow(dead_code))]
fn credential_blob_fits(len: usize) -> bool {
    len <= CREDENTIAL_BLOB_MAX
}

/// Windows Credential Manager（generic credential，当前用户加密存储）。
#[cfg(target_os = "windows")]
pub struct WindowsCredentialManager {
    service: String,
}

#[cfg(target_os = "windows")]
impl WindowsCredentialManager {
    pub fn new(service: impl Into<String>) -> Self {
        Self {
            service: service.into(),
        }
    }

    fn target(&self, account: &str) -> String {
        // TargetName 是 Credential Manager 的查找键；service 已按 dev/staging/prod 隔离。
        format!("{}:{}", self.service, account)
    }
}

#[cfg(target_os = "windows")]
fn credential_error(action: &str, error: windows::core::Error) -> io::Error {
    io::Error::other(format!("Windows Credential Manager {action}: {error}"))
}

#[cfg(target_os = "windows")]
fn credential_not_found(error: &windows::core::Error) -> bool {
    error.code().0 as u32 == windows::Win32::Foundation::ERROR_NOT_FOUND.0
}

#[cfg(target_os = "windows")]
fn wide_null(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(std::iter::once(0)).collect()
}

#[cfg(target_os = "windows")]
impl SecretBackend for WindowsCredentialManager {
    fn set(&self, account: &str, secret: &str) -> io::Result<()> {
        use windows::core::PWSTR;
        use windows::Win32::Security::Credentials::{
            CredWriteW, CREDENTIALW, CRED_PERSIST_LOCAL_MACHINE, CRED_TYPE_GENERIC,
        };

        // CRED_MAX_CREDENTIAL_BLOB_SIZE = 5 * 512；超限必须报错，不能截断 token。
        let mut blob = secret.as_bytes().to_vec();
        if !credential_blob_fits(blob.len()) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "credential exceeds Windows Credential Manager blob limit",
            ));
        }
        let mut target = wide_null(&self.target(account));
        let credential = CREDENTIALW {
            Type: CRED_TYPE_GENERIC,
            TargetName: PWSTR(target.as_mut_ptr()),
            CredentialBlobSize: blob.len() as u32,
            CredentialBlob: blob.as_mut_ptr(),
            Persist: CRED_PERSIST_LOCAL_MACHINE,
            ..Default::default()
        };
        let result = unsafe { CredWriteW(&credential, 0) };
        blob.fill(0);
        result.map_err(|error| credential_error("write", error))
    }

    fn get(&self, account: &str) -> io::Result<Option<String>> {
        use windows::core::PCWSTR;
        use windows::Win32::Security::Credentials::{
            CredFree, CredReadW, CREDENTIALW, CRED_TYPE_GENERIC,
        };

        let target = wide_null(&self.target(account));
        let mut credential: *mut CREDENTIALW = std::ptr::null_mut();
        let result = unsafe {
            CredReadW(
                PCWSTR(target.as_ptr()),
                CRED_TYPE_GENERIC,
                None,
                &mut credential,
            )
        };
        if let Err(error) = result {
            if credential_not_found(&error) {
                return Ok(None);
            }
            return Err(credential_error("read", error));
        }
        if credential.is_null() {
            return Ok(None);
        }

        let bytes = unsafe {
            let credential_ref = &*credential;
            let size = credential_ref.CredentialBlobSize as usize;
            if size == 0 || credential_ref.CredentialBlob.is_null() {
                Vec::new()
            } else {
                std::slice::from_raw_parts(credential_ref.CredentialBlob, size).to_vec()
            }
        };
        unsafe { CredFree(credential.cast()) };

        String::from_utf8(bytes)
            .map(Some)
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error.to_string()))
    }

    fn delete(&self, account: &str) -> io::Result<()> {
        use windows::core::PCWSTR;
        use windows::Win32::Security::Credentials::{CredDeleteW, CRED_TYPE_GENERIC};

        let target = wide_null(&self.target(account));
        let result = unsafe { CredDeleteW(PCWSTR(target.as_ptr()), CRED_TYPE_GENERIC, None) };
        match result {
            Ok(()) => Ok(()),
            Err(error) if credential_not_found(&error) => Ok(()),
            Err(error) => Err(credential_error("delete", error)),
        }
    }
}

/// 其它平台：v1 fail-closed，不落明文；不伪装成可用。
#[derive(Default)]
pub struct UnavailableKeychain;

impl SecretBackend for UnavailableKeychain {
    fn set(&self, _account: &str, _secret: &str) -> io::Result<()> {
        Err(unavailable("OS keychain is not available on this platform"))
    }
    fn get(&self, _account: &str) -> io::Result<Option<String>> {
        Err(unavailable("OS keychain is not available on this platform"))
    }
    fn delete(&self, _account: &str) -> io::Result<()> {
        Ok(())
    }
}

/// 测试/QA 用内存后端（不落盘；不是生产路径）。
#[cfg(test)]
#[derive(Default)]
pub struct MemoryBackend {
    secret: Mutex<Option<(String, String)>>,
}

#[cfg(test)]
impl SecretBackend for MemoryBackend {
    fn set(&self, account: &str, secret: &str) -> io::Result<()> {
        *self.secret.lock().expect("secret") = Some((account.to_string(), secret.to_string()));
        Ok(())
    }
    fn get(&self, account: &str) -> io::Result<Option<String>> {
        Ok(self
            .secret
            .lock()
            .expect("secret")
            .as_ref()
            .filter(|(stored, _)| stored == account)
            .map(|(_, secret)| secret.clone()))
    }
    fn delete(&self, _account: &str) -> io::Result<()> {
        *self.secret.lock().expect("secret") = None;
        Ok(())
    }
}

/// OS keychain 凭证存储：session JSON 整体存 keychain（service=cgc-desktop, account=user_id）。
pub struct KeychainStore {
    backend: Arc<dyn SecretBackend>,
}

impl KeychainStore {
    pub fn new(backend: Arc<dyn SecretBackend>) -> Self {
        Self { backend }
    }

    /// 运行时选择：`CGC_KEYCHAIN=unavailable` 仅供 QA 验证 fail-closed；否则平台后端。
    pub fn from_env() -> Self {
        if std::env::var("CGC_KEYCHAIN").as_deref() == Ok("unavailable") {
            return Self::new(Arc::new(UnavailableKeychain));
        }
        let service = crate::paths::AppPaths::from_env()
            .keychain_service()
            .to_string();
        #[cfg(target_os = "macos")]
        {
            Self::new(Arc::new(MacKeychain::new(service)))
        }
        #[cfg(target_os = "linux")]
        {
            Self::new(Arc::new(LinuxSecretTool::new(service)))
        }
        #[cfg(target_os = "windows")]
        {
            Self::new(Arc::new(WindowsCredentialManager::new(service)))
        }
        #[cfg(not(any(target_os = "macos", target_os = "linux", target_os = "windows")))]
        {
            Self::new(Arc::new(UnavailableKeychain))
        }
    }

    /// 通用命名 secret（如 learning_host）；不写明文文件。
    pub fn save_secret(&self, account: &str, secret: &str) -> io::Result<()> {
        self.backend.set(account, secret)
    }

    pub fn load_secret(&self, account: &str) -> Option<String> {
        self.backend.get(account).ok().flatten()
    }

    pub fn clear_secret(&self, account: &str) -> io::Result<()> {
        self.backend.delete(account)
    }

    fn encode(session: &SignedInSession) -> String {
        serde_json::json!({
            "token": session.token,
            "user_id": session.user_id,
            "email": session.email,
            "is_platform_admin": session.is_platform_admin,
        })
        .to_string()
    }

    fn decode(raw: &str) -> Option<SignedInSession> {
        let value: serde_json::Value = serde_json::from_str(raw).ok()?;
        Some(SignedInSession {
            token: value.get("token")?.as_str()?.to_string(),
            user_id: value.get("user_id")?.as_str()?.to_string(),
            email: value
                .get("email")
                .and_then(|value| value.as_str())
                .map(str::to_string),
            is_platform_admin: value
                .get("is_platform_admin")
                .and_then(|value| value.as_bool())
                .unwrap_or(false),
        })
    }
}

impl CredentialStore for KeychainStore {
    fn load(&self) -> Option<SignedInSession> {
        // load 无错误通道：任何 keychain 错误按「无会话」处理（不落明文、不崩溃）。
        let account =
            std::env::var("CGC_KEYCHAIN_ACCOUNT").unwrap_or_else(|_| "default".to_string());
        self.backend
            .get(&account)
            .ok()
            .flatten()
            .and_then(|raw| Self::decode(&raw))
    }

    fn save(&self, session: &SignedInSession) -> io::Result<()> {
        // 单会话应用：固定 account=default，load/clear 使用同一键。
        self.backend.set("default", &Self::encode(session))
    }

    fn clear(&self) -> io::Result<()> {
        let account =
            std::env::var("CGC_KEYCHAIN_ACCOUNT").unwrap_or_else(|_| "default".to_string());
        self.backend
            .delete(&account)
            .or_else(|_| self.backend.delete("default"))
    }
}

#[cfg(test)]
mod keychain_tests {
    use super::*;

    fn session(token: &str) -> SignedInSession {
        SignedInSession {
            token: token.to_string(),
            user_id: "user-keychain".to_string(),
            email: Some("demo@example.com".to_string()),
            is_platform_admin: false,
        }
    }

    #[test]
    fn memory_backend_round_trips_without_plaintext_file() {
        let store = KeychainStore::new(Arc::new(MemoryBackend::default()));
        store.save(&session("t-keychain")).expect("save");
        assert_eq!(
            store.load().map(|session| session.token),
            Some("t-keychain".to_string())
        );
        store.clear().expect("clear");
        assert!(store.load().is_none());
    }

    #[test]
    fn credential_blob_limit_is_inclusive() {
        assert!(credential_blob_fits(CREDENTIAL_BLOB_MAX));
        assert!(!credential_blob_fits(CREDENTIAL_BLOB_MAX + 1));
    }

    #[cfg(target_os = "windows")]
    #[test]
    fn windows_credential_manager_round_trip() {
        let service = format!("cgc-desktop-test-{}", std::process::id());
        let store = KeychainStore::new(Arc::new(WindowsCredentialManager::new(service)));
        // Cleanup from an earlier interrupted run before asserting the round trip.
        store.clear().expect("clear stale test credential");
        store
            .save(&session("t-windows-keychain"))
            .expect("save to Windows Credential Manager");
        assert_eq!(
            store.load().map(|session| session.token),
            Some("t-windows-keychain".to_string())
        );
        store.clear().expect("clear Windows Credential Manager");
        assert!(store.load().is_none());
    }

    #[cfg(target_os = "macos")]
    #[test]
    #[ignore = "touches the real macOS keychain; run manually for HITL"]
    fn real_mac_keychain_round_trip() {
        let store = KeychainStore::from_env();
        store
            .save(&session("t-real-keychain"))
            .expect("save to real keychain");
        assert_eq!(
            store.load().map(|session| session.token),
            Some("t-real-keychain".to_string())
        );
        store.clear().expect("clear real keychain");
        assert!(store.load().is_none());
    }

    #[test]
    fn unavailable_backend_fails_closed_on_save() {
        let store = KeychainStore::new(Arc::new(UnavailableKeychain));
        let error = store.save(&session("t")).expect_err("must fail");
        assert_eq!(error.kind(), io::ErrorKind::Unsupported);
        assert!(store.load().is_none());
    }
}
