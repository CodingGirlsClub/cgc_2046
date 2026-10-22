use std::path::{Path, PathBuf};

use cgc_agent_core::SelectedModel;
use serde::{Deserialize, Serialize};

/// 跨会话保留的 agent 偏好。
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentPrefs {
    #[serde(default)]
    pub selected_model: Option<SelectedModel>,
}

#[derive(Debug, PartialEq, Eq, thiserror::Error)]
pub enum PrefsError {
    #[error("io: {0}")]
    Io(String),
    #[error("serialize: {0}")]
    Serialize(String),
}

/// 偏好文件读写。缺失或损坏时返回默认值，不影响启动。
#[derive(Clone, Debug)]
pub struct PrefsStore {
    path: PathBuf,
}

impl PrefsStore {
    pub fn new(path: impl Into<PathBuf>) -> Self {
        Self { path: path.into() }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn load(&self) -> AgentPrefs {
        std::fs::read_to_string(&self.path)
            .ok()
            .and_then(|raw| serde_json::from_str(&raw).ok())
            .unwrap_or_default()
    }

    /// 原子写入：先写 `.tmp` 再 rename，避免半截文件。
    pub fn save(&self, prefs: &AgentPrefs) -> Result<(), PrefsError> {
        if let Some(parent) = self.path.parent() {
            std::fs::create_dir_all(parent).map_err(|error| PrefsError::Io(error.to_string()))?;
        }
        let raw = serde_json::to_string_pretty(prefs)
            .map_err(|error| PrefsError::Serialize(error.to_string()))?;
        let temp_path = self.path.with_extension("json.tmp");
        std::fs::write(&temp_path, raw).map_err(|error| PrefsError::Io(error.to_string()))?;
        std::fs::rename(&temp_path, &self.path).map_err(|error| PrefsError::Io(error.to_string()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use cgc_agent_core::SelectedModel;
    use cgc_agent_provider::{ModelId, ProviderId};

    fn temp_dir(tag: &str) -> PathBuf {
        use std::sync::atomic::{AtomicU64, Ordering};
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let serial = COUNTER.fetch_add(1, Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!(
            "cgc-agent-store-{}-{tag}-{serial}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("dir");
        dir
    }

    fn selected() -> SelectedModel {
        SelectedModel::new(ProviderId::new("deepseek"), ModelId::new("deepseek-chat"))
    }

    #[test]
    fn save_then_load_roundtrip() {
        let dir = temp_dir("roundtrip");
        let store = PrefsStore::new(dir.join("agent_prefs.json"));
        let prefs = AgentPrefs {
            selected_model: Some(selected()),
        };
        store.save(&prefs).expect("save");
        assert_eq!(store.load(), prefs);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn missing_file_returns_default() {
        let dir = temp_dir("missing");
        let store = PrefsStore::new(dir.join("agent_prefs.json"));
        assert_eq!(store.load(), AgentPrefs::default());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn corrupt_file_returns_default() {
        let dir = temp_dir("corrupt");
        let path = dir.join("agent_prefs.json");
        std::fs::write(&path, "{not json").expect("write");
        let store = PrefsStore::new(&path);
        assert_eq!(store.load(), AgentPrefs::default());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn save_creates_parent_dirs() {
        let dir = temp_dir("nested");
        let path = dir.join("nested").join("agent_prefs.json");
        let store = PrefsStore::new(&path);
        store
            .save(&AgentPrefs {
                selected_model: Some(selected()),
            })
            .expect("save");
        assert!(path.exists());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
