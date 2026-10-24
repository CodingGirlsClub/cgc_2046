use std::path::{Path, PathBuf};

use cgc_agent_core::SelectedModel;
use serde::{Deserialize, Serialize};

/// 一个 OpenAI-compatible provider（API key 存系统钥匙串，不落 JSON）。
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProviderPrefs {
    pub id: String,
    pub name: String,
    pub base_url: String,
    pub models: Vec<String>,
    /// 该 provider 的模型是否支持 reasoning/thinking 档位。
    /// 是否已保存 API key（仅标记，key 本体在钥匙串）。
    pub has_key: bool,
    /// 模型级参数（按 model id 索引；缺省时用默认值）。
    pub model_params: Vec<ModelPrefs>,
    /// 是否来自内置目录（内置条目不需要写入用户文件）。
    pub builtin: bool,
}

/// 单个模型的参数（context / output / thinking）。
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ModelPrefs {
    pub id: String,
    pub context_window: u32,
    pub max_output_tokens: u32,
    pub supports_thinking: bool,
    /// 是否在 native agent 的模型选择器中启用。
    pub enabled: bool,
    /// 该模型是否支持工具调用。
    pub supports_tools: bool,
    /// 该模型是否支持图片输入（多模态）。新字段用默认值兼容既有本地配置。
    #[serde(default)]
    pub supports_images: bool,
    /// 该模型接受的 reasoning_effort 取值；空表示不下发该字段。
    pub reasoning_efforts: Vec<String>,
}

fn default_context_window() -> u32 {
    64_000
}

fn default_max_output_tokens() -> u32 {
    8_000
}

impl Default for ModelPrefs {
    fn default() -> Self {
        Self {
            id: String::new(),
            context_window: default_context_window(),
            max_output_tokens: default_max_output_tokens(),
            supports_thinking: false,
            enabled: true,
            supports_tools: true,
            supports_images: false,
            reasoning_efforts: Vec::new(),
        }
    }
}

impl ModelPrefs {
    pub fn effort_at(&self, index: usize) -> Option<&str> {
        self.reasoning_efforts.get(index).map(String::as_str)
    }

    pub fn new(id: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            ..Self::default()
        }
    }
}

impl ProviderPrefs {
    pub fn is_complete(&self) -> bool {
        !self.base_url.is_empty() && !self.models.is_empty()
    }

    pub fn primary_model(&self) -> Option<&str> {
        self.models.first().map(String::as_str)
    }

    pub fn model_config(&self, model_id: &str) -> ModelPrefs {
        self.model_params
            .iter()
            .find(|model| model.id == model_id)
            .cloned()
            .unwrap_or_else(|| ModelPrefs::new(model_id))
    }

    /// 设置或替换一个模型参数；同时确保 model id 在 models 列表里。
    pub fn upsert_model(&mut self, model: ModelPrefs) {
        if !self.models.contains(&model.id) {
            self.models.push(model.id.clone());
        }
        match self
            .model_params
            .iter_mut()
            .find(|existing| existing.id == model.id)
        {
            Some(existing) => *existing = model,
            None => self.model_params.push(model),
        }
    }

    pub fn remove_model(&mut self, model_id: &str) {
        self.models.retain(|id| id != model_id);
        self.model_params.retain(|model| model.id != model_id);
    }
}

/// 跨会话保留的 agent 偏好。
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentPrefs {
    /// 配置 schema 版本；用于一次性迁移新能力字段的默认值。
    #[serde(default)]
    pub schema_version: u32,
    pub selected_model: Option<SelectedModel>,
    pub selected_provider: Option<String>,
    pub providers: Vec<ProviderPrefs>,
}

impl Default for AgentPrefs {
    fn default() -> Self {
        Self {
            schema_version: 1,
            selected_model: None,
            selected_provider: None,
            providers: Vec::new(),
        }
    }
}

impl AgentPrefs {
    /// 一次性迁移：旧配置的模型能力字段取 catalog 默认值（如 DeepSeek flash 的图片支持）。
    pub fn migrate(&mut self) {
        if self.schema_version >= 1 {
            return;
        }
        let catalog = builtin_providers();
        for provider in &mut self.providers {
            if !provider.builtin {
                continue;
            }
            let Some(default) = catalog.iter().find(|item| item.id == provider.id) else {
                continue;
            };
            for model in &mut provider.model_params {
                let Some(catalog_model) =
                    default.model_params.iter().find(|item| item.id == model.id)
                else {
                    continue;
                };
                model.supports_images = catalog_model.supports_images;
            }
        }
        self.schema_version = 1;
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
pub fn provider_key_account(provider_id: &str) -> String {
    format!("native_agent_provider_api_key:{provider_id}")
}

/// 内置 provider 目录：第一次打开设置就能看到的默认配置（不写入用户文件）。
pub fn builtin_providers() -> Vec<ProviderPrefs> {
    fn provider(id: &str, name: &str, base_url: &str) -> ProviderPrefs {
        ProviderPrefs {
            id: id.to_string(),
            name: name.to_string(),
            base_url: base_url.to_string(),
            models: Vec::new(),
            has_key: false,
            model_params: Vec::new(),
            builtin: true,
        }
    }

    let mut deepseek = provider("deepseek", "DeepSeek", "https://api.deepseek.com");
    deepseek.upsert_model(ModelPrefs {
        id: "deepseek-flash".to_string(),
        context_window: 1_000_000,
        max_output_tokens: 384_000,
        supports_thinking: true,
        enabled: true,
        supports_tools: true,
        supports_images: true,
        reasoning_efforts: vec!["low".into(), "high".into(), "max".into()],
    });
    deepseek.upsert_model(ModelPrefs {
        id: "deepseek-v4-pro".to_string(),
        context_window: 1_000_000,
        max_output_tokens: 384_000,
        supports_thinking: true,
        enabled: true,
        supports_tools: true,
        supports_images: false,
        reasoning_efforts: vec!["low".into(), "high".into(), "max".into()],
    });

    let mut moonshot = provider("moonshot", "Moonshot", "https://api.moonshot.cn/v1");
    for (id, output) in [
        ("kimi-k3.1-pro", 32_768),
        ("kimi-k3.1-pro-highspeed", 32_768),
        ("kimi-k3", 32_768),
    ] {
        moonshot.upsert_model(ModelPrefs {
            id: id.to_string(),
            context_window: 1_048_576,
            max_output_tokens: output,
            supports_thinking: true,
            enabled: true,
            supports_tools: true,
            supports_images: false,
            reasoning_efforts: vec!["low".into(), "high".into(), "max".into()],
        });
    }

    let mut minimax = provider("minimax", "MiniMax", "https://api.minimax.io/v1");
    minimax.upsert_model(ModelPrefs {
        id: "MiniMax-M3.1-Flash".to_string(),
        context_window: 1_000_000,
        max_output_tokens: 32_768,
        supports_thinking: true,
        enabled: true,
        supports_tools: true,
        supports_images: false,
        reasoning_efforts: vec![
            "low".into(),
            "medium".into(),
            "high".into(),
            "xhigh".into(),
            "max".into(),
        ],
    });
    minimax.upsert_model(ModelPrefs {
        id: "MiniMax-M3".to_string(),
        context_window: 1_000_000,
        max_output_tokens: 32_768,
        supports_thinking: true,
        enabled: true,
        supports_tools: true,
        supports_images: false,
        reasoning_efforts: Vec::new(),
    });

    let mut zhipu = provider("zhipu", "智谱", "https://open.bigmodel.cn/api/paas/v4");
    let glm53 = ModelPrefs {
        id: "glm-5.3".to_string(),
        context_window: 1_000_000,
        max_output_tokens: 131_072,
        supports_thinking: true,
        enabled: true,
        supports_tools: true,
        supports_images: false,
        reasoning_efforts: vec!["low".into(), "high".into(), "max".into()],
    };
    zhipu.upsert_model(glm53);
    zhipu.upsert_model(ModelPrefs {
        id: "glm-4.6".to_string(),
        context_window: 200_000,
        max_output_tokens: 131_072,
        supports_thinking: true,
        enabled: true,
        supports_tools: true,
        supports_images: false,
        reasoning_efforts: Vec::new(),
    });

    vec![deepseek, moonshot, minimax, zhipu]
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
        prefs.migrate();
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
            has_key: true,
            model_params: Vec::new(),
            builtin: false,
        }
    }

    #[test]
    fn save_then_load_roundtrip() {
        let dir = temp_dir("roundtrip");
        let store = PrefsStore::new(dir.join("agent_prefs.json"));
        let prefs = AgentPrefs {
            schema_version: 1,
            selected_model: Some(selected()),
            selected_provider: Some("deepseek".to_string()),
            providers: vec![provider("deepseek", "https://api.deepseek.com/v1")],
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
    fn migration_enables_image_support_for_builtin_models() {
        let dir = temp_dir("migrate-images");
        let store = PrefsStore::new(dir.join("agent_prefs.json"));
        let mut flash = ModelPrefs::new("deepseek-flash");
        flash.supports_images = false;
        let prefs = AgentPrefs {
            schema_version: 0,
            selected_model: None,
            selected_provider: Some("deepseek".to_string()),
            providers: vec![ProviderPrefs {
                id: "deepseek".to_string(),
                name: "DeepSeek".to_string(),
                base_url: "https://api.deepseek.com".to_string(),
                models: vec!["deepseek-flash".to_string()],
                has_key: true,
                model_params: vec![flash],
                builtin: true,
            }],
        };
        store.save(&prefs).expect("save");
        let loaded = store.load();
        assert!(
            loaded
                .provider("deepseek")
                .unwrap()
                .model_config("deepseek-flash")
                .supports_images
        );
        assert_eq!(loaded.schema_version, 1);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn corrupted_prefs_file_falls_back_to_default() {
        let dir = temp_dir("corrupt");
        let path = dir.join("agent_prefs.json");
        std::fs::write(&path, "{ not json").expect("write");
        let store = PrefsStore::new(path);
        assert_eq!(store.load(), AgentPrefs::default());
        let _ = std::fs::remove_dir_all(&dir);
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

#[cfg(test)]
mod model_param_tests {
    use super::*;

    #[test]
    fn builtin_catalog_covers_domestic_providers() {
        let providers = builtin_providers();
        let ids: Vec<&str> = providers
            .iter()
            .map(|provider| provider.id.as_str())
            .collect();
        assert_eq!(ids, vec!["deepseek", "moonshot", "minimax", "zhipu"]);
        assert!(providers.iter().all(|provider| provider.builtin));
        let deepseek = providers.iter().find(|p| p.id == "deepseek").unwrap();
        assert_eq!(
            deepseek.model_config("deepseek-flash").context_window,
            1_000_000
        );
        assert!(deepseek.model_config("deepseek-v4-pro").supports_thinking);
    }

    #[test]
    fn model_config_falls_back_to_defaults_and_upsert_works() {
        let mut provider = ProviderPrefs {
            id: "custom".to_string(),
            models: vec!["m1".to_string()],
            ..ProviderPrefs::default()
        };
        let config = provider.model_config("m1");
        assert_eq!(config.context_window, 64_000);
        provider.upsert_model(ModelPrefs {
            id: "m1".to_string(),
            context_window: 200_000,
            max_output_tokens: 32_000,
            supports_thinking: true,
            enabled: true,
            supports_tools: true,
            supports_images: false,
            reasoning_efforts: Vec::new(),
        });
        assert_eq!(provider.model_config("m1").context_window, 200_000);
        provider.remove_model("m1");
        assert!(provider.models.is_empty());
    }

    #[test]
    fn model_defaults_support_tools() {
        assert!(ModelPrefs::new("m").supports_tools);
    }

    #[test]
    fn effort_at_maps_and_bounds() {
        let mut model = ModelPrefs::new("m");
        assert_eq!(model.effort_at(0), None);
        model.reasoning_efforts = vec!["low".into(), "high".into(), "max".into()];
        assert_eq!(model.effort_at(0), Some("low"));
        assert_eq!(model.effort_at(2), Some("max"));
        assert_eq!(model.effort_at(3), None);
    }

    #[test]
    fn zhipu_glm53_has_low_high_max_efforts() {
        let zhipu = builtin_providers()
            .into_iter()
            .find(|provider| provider.id == "zhipu")
            .expect("zhipu");
        let glm = zhipu.model_config("glm-5.3");
        assert_eq!(glm.effort_at(2), Some("max"));
    }
}
