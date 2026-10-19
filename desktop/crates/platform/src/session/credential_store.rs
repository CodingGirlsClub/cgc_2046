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

    /// 默认路径：`CGC_SESSION_FILE` > macOS/Linux/Windows 的应用数据目录。
    pub fn default_path() -> PathBuf {
        if let Some(path) = std::env::var_os("CGC_SESSION_FILE") {
            return path.into();
        }
        let base = if cfg!(target_os = "macos") {
            std::env::var_os("HOME")
                .map(|home| PathBuf::from(home).join("Library/Application Support/cgc-desktop"))
        } else if cfg!(target_os = "windows") {
            std::env::var_os("APPDATA").map(|base| PathBuf::from(base).join("cgc-desktop"))
        } else {
            std::env::var_os("XDG_DATA_HOME")
                .map(PathBuf::from)
                .or_else(|| {
                    std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".local/share"))
                })
                .map(|base| base.join("cgc-desktop"))
        };

        base.unwrap_or_else(std::env::temp_dir).join("session.json")
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
