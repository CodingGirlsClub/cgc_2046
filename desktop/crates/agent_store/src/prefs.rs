use std::path::{Path, PathBuf};

use cgc_agent_core::SelectedModel;
use serde::{Deserialize, Serialize};

/// 一个 OpenAI-compatible provider（API key 存系统钥匙串，不落 JSON）。
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProviderPrefs {
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub base_url: String,
    #[serde(default)]
    pub models: Vec<String>,
    /// 该 provider 的模型是否支持 reasoning/thinking 档位。
    #[serde(default)]
    pub supports_thinking: bool,
    /// 是否已保存 API key（仅标记，key 本体在钥匙串）。
    #[serde(default)]
    pub has_key: bool,
}

impl ProviderPrefs {
    pub fn is_complete(&self) -> bool {
        !self.base_url.is_empty() && !self.models.is_empty()
    }

    pub fn primary_model(&self) -> Option<&str> {
        self.models.first().map(String::as_str)
    }
}

/// 旧版单 provider 字段（只读迁移用）。
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
struct LegacyProvider {
    #[serde(default)]
    base_url: String,
    #[serde(default)]
    provider_name: String,
    #[serde(default)]
    model_id: String,
}

/// 跨会话保留的 agent 偏好。
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentPrefs {
    #[serde(default)]
    pub selected_model: Option<SelectedModel>,
    #[serde(default)]
    pub selected_provider: Option<String>,
    #[serde(default)]
    pub providers: Vec<ProviderPrefs>,
    /// 兼容旧版 `provider` 单对象；读取后迁移进 `providers`，不再写回。
    #[serde(default, rename = "provider", skip_serializing)]
    legacy_provider: Option<LegacyProvider>,
}

impl AgentPrefs {
    /// 旧版单 provider 迁入列表；幂等。
    pub fn normalize(&mut self) {
        if !self.providers.is_empty() {
            self.legacy_provider = None;
            return;
        }
        let Some(legacy) = self.legacy_provider.take() else {
            return;
        };
        if legacy.base_url.is_empty() {
            return;
        }
        let models = if legacy.model_id.is_empty() {
            Vec::new()
        } else {
            vec![legacy.model_id]
        };
        self.providers.push(ProviderPrefs {
            id: "custom".to_string(),
            name: if legacy.provider_name.is_empty() {
                "OpenAI Compatible".to_string()
            } else {
                legacy.provider_name
            },
            base_url: legacy.base_url,
            models,
            supports_thinking: false,
            has_key: false,
        });
        if self.selected_provider.is_none() {
            self.selected_provider = Some("custom".to_string());
        }
    }

    pub fn active_provider(&self) -> Option<&ProviderPrefs> {
        if let Some(id) = &self.selected_provider {
            if let Some(provider) = self.providers.iter().find(|provider| &provider.id == id) {
                return Some(provider);
            }
        }
        self.providers.first()
    }

    pub fn provider(&self, id: &str) -> Option<&ProviderPrefs> {
        self.providers.iter().find(|provider| provider.id == id)
    }

    pub fn upsert_provider(&mut self, provider: ProviderPrefs) {
        if provider.id.is_empty() {
            return;
        }
        match self
            .providers
            .iter_mut()
            .find(|existing| existing.id == provider.id)
        {
            Some(existing) => *existing = provider,
            None => self.providers.push(provider),
        }
    }

    pub fn remove_provider(&mut self, id: &str) {
        self.providers.retain(|provider| provider.id != id);
        if self.selected_provider.as_deref() == Some(id) {
            self.selected_provider = self.providers.first().map(|provider| provider.id.clone());
        }
    }
}

/// 每个 provider 的 API key 在钥匙串里的 account。
///
/// `custom` 是旧版单 provider 的 id，沿用旧 account 以继承已保存的 key。
pub fn provider_key_account(provider_id: &str) -> String {
    if provider_id == "custom" {
        "native_agent_provider_api_key".to_string()
    } else {
        format!("native_agent_provider_api_key:{provider_id}")
    }
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
        let mut prefs = std::fs::read_to_string(&self.path)
            .ok()
            .and_then(|raw| serde_json::from_str::<AgentPrefs>(&raw).ok())
            .unwrap_or_default();
        prefs.normalize();
        prefs
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

    fn provider(id: &str, base_url: &str) -> ProviderPrefs {
        ProviderPrefs {
            id: id.to_string(),
            name: "Test".to_string(),
            base_url: base_url.to_string(),
            models: vec!["model-a".to_string()],
            supports_thinking: false,
            has_key: true,
        }
    }

    #[test]
    fn save_then_load_roundtrip() {
        let dir = temp_dir("roundtrip");
        let store = PrefsStore::new(dir.join("agent_prefs.json"));
        let prefs = AgentPrefs {
            selected_model: Some(selected()),
            selected_provider: Some("deepseek".to_string()),
            providers: vec![provider("deepseek", "https://api.deepseek.com/v1")],
            ..AgentPrefs::default()
        };
        store.save(&prefs).expect("save");
        assert_eq!(store.load(), prefs);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn legacy_single_provider_is_migrated() {
        let dir = temp_dir("legacy");
        let store = PrefsStore::new(dir.join("agent_prefs.json"));
        std::fs::write(
            store.path(),
            r#"{
                "selected_model": {"provider_id": "custom", "model_id": "deepseek-flash"},
                "provider": {
                    "base_url": "https://api.deepseek.com",
                    "provider_name": "OpenAI Compatible",
                    "model_id": "deepseek-flash"
                }
            }"#,
        )
        .expect("write");
        let prefs = store.load();
        assert_eq!(prefs.providers.len(), 1);
        assert_eq!(prefs.providers[0].id, "custom");
        assert_eq!(
            prefs.providers[0].models,
            vec!["deepseek-flash".to_string()]
        );
        assert_eq!(
            prefs.selected_model,
            Some(SelectedModel::new(
                ProviderId::new("custom"),
                ModelId::new("deepseek-flash")
            ))
        );
        assert_eq!(prefs.selected_provider.as_deref(), Some("custom"));
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
                ..AgentPrefs::default()
            })
            .expect("save");
        assert!(path.exists());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn upsert_and_remove_provider() {
        let mut prefs = AgentPrefs::default();
        prefs.upsert_provider(provider("a", "https://a"));
        prefs.upsert_provider(provider("b", "https://b"));
        assert_eq!(prefs.providers.len(), 2);
        prefs.upsert_provider(ProviderPrefs {
            base_url: "https://a2".to_string(),
            ..provider("a", "https://a")
        });
        assert_eq!(prefs.provider("a").unwrap().base_url, "https://a2");
        prefs.selected_provider = Some("b".to_string());
        prefs.remove_provider("b");
        assert_eq!(prefs.providers.len(), 1);
        assert_eq!(prefs.selected_provider.as_deref(), Some("a"));
    }

    #[test]
    fn active_provider_falls_back_to_first() {
        let mut prefs = AgentPrefs::default();
        prefs.upsert_provider(provider("a", "https://a"));
        prefs.upsert_provider(provider("b", "https://b"));
        assert_eq!(prefs.active_provider().unwrap().id, "a");
        prefs.selected_provider = Some("b".to_string());
        assert_eq!(prefs.active_provider().unwrap().id, "b");
    }

    #[test]
    fn key_account_is_scoped_by_provider() {
        assert_eq!(
            provider_key_account("deepseek"),
            "native_agent_provider_api_key:deepseek"
        );
    }

    #[test]
    fn provider_is_complete_requires_models() {
        assert!(!ProviderPrefs::default().is_complete());
        assert!(provider("a", "https://a").is_complete());
    }
}
