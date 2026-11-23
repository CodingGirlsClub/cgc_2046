//! Provider 配置的唯一写入入口：统一 prefs 与 keychain 的保存/删除/清除。

use std::fmt;

use cgc_agent_core::SelectedModel;
use cgc_agent_provider::probe::RemoteModel;
use cgc_agent_store::{
    cgc_cloud_provider, is_builtin_provider_id, is_managed_provider_id, provider_key_account,
    AgentPrefs, ModelPrefs, PrefsStore, ProviderPrefs, CGC_CLOUD_PROVIDER_ID,
};
use cgc_platform::paths::AppPaths;
use cgc_platform::session::KeychainStore;

#[derive(Clone, Debug)]
pub(crate) enum ProviderPrefsChange {
    SaveProvider(ProviderPrefs),
    /// 只更新已保存 provider 的模型目录（获取成功后立即落盘）。
    SaveProviderCatalog {
        provider_id: String,
        models: Vec<RemoteModel>,
        fetched_at: u64,
    },
    /// 只更新已保存 provider 的启用状态。
    SetProviderEnabled {
        provider_id: String,
        enabled: bool,
    },
    /// 托管网关总开关：磁盘没有覆盖记录时先 upsert 再落开关。
    SetManagedProviderEnabled {
        enabled: bool,
    },
    /// 托管网关单模型开关：只写覆盖记录，不落远端全量目录。
    SetManagedModelEnabled {
        model_id: String,
        enabled: bool,
    },
    SaveKey {
        provider: ProviderPrefs,
        key: String,
    },
    ClearKey {
        provider_id: String,
    },
    RemoveProvider {
        provider_id: String,
    },
}

#[derive(Debug)]
pub(crate) enum ProviderSettingsError {
    Prefs(String),
    Keychain(String),
}

impl fmt::Display for ProviderSettingsError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Prefs(message) => write!(formatter, "Provider 保存失败：{message}"),
            Self::Keychain(message) => write!(formatter, "API Key 保存失败：{message}"),
        }
    }
}

pub(crate) struct ProviderSettings {
    prefs: PrefsStore,
    keychain: KeychainStore,
}

impl ProviderSettings {
    pub(crate) fn new() -> Self {
        Self {
            prefs: PrefsStore::new(AppPaths::from_env().agent_prefs_file()),
            keychain: KeychainStore::from_env(),
        }
    }

    pub(crate) fn load(&self) -> AgentPrefs {
        self.prefs.load()
    }

    pub(crate) fn has_key(&self, provider_id: &str) -> bool {
        self.keychain
            .load_secret(&provider_key_account(provider_id))
            .is_some_and(|key| !key.is_empty())
    }

    /// 读取已保存的 Key：让"获取模型"在用户尚未重新输入 Key 时也能用。
    pub(crate) fn key(&self, provider_id: &str) -> Option<String> {
        self.keychain
            .load_secret(&provider_key_account(provider_id))
            .filter(|key| !key.is_empty())
    }

    pub(crate) fn apply(&self, change: ProviderPrefsChange) -> Result<(), ProviderSettingsError> {
        match change {
            ProviderPrefsChange::SaveProvider(mut provider) => {
                provider.builtin |= is_builtin_provider_id(&provider.id);
                let mut prefs = self.prefs.load();
                let selected = prefs.selected_provider.as_deref();
                let should_select = selected.is_none() || selected == Some(provider.id.as_str());
                prefs.upsert_provider(provider.clone());
                if should_select {
                    prefs.selected_provider = Some(provider.id);
                }
                self.save(&mut prefs)
            }
            ProviderPrefsChange::SaveProviderCatalog {
                provider_id,
                models,
                fetched_at,
            } => {
                let mut prefs = self.prefs.load();
                let Some(provider) = prefs
                    .providers
                    .iter_mut()
                    .find(|provider| provider.id == provider_id)
                else {
                    // 草稿 provider 尚未保存：等保存时一起写入。
                    return Ok(());
                };
                provider.available_models = models;
                provider.models_fetched_at = fetched_at;
                self.save(&mut prefs)
            }
            ProviderPrefsChange::SetProviderEnabled {
                provider_id,
                enabled,
            } => {
                let mut prefs = self.prefs.load();
                let Some(provider) = prefs
                    .providers
                    .iter_mut()
                    .find(|provider| provider.id == provider_id)
                else {
                    // 草稿 provider 尚未保存：开关只留在草稿里，保存时一起写入。
                    return Ok(());
                };
                provider.enabled = enabled;
                self.save(&mut prefs)
            }
            ProviderPrefsChange::SetManagedProviderEnabled { enabled } => {
                let mut prefs = self.prefs.load();
                match prefs
                    .providers
                    .iter_mut()
                    .find(|provider| provider.id == CGC_CLOUD_PROVIDER_ID)
                {
                    Some(provider) => provider.enabled = enabled,
                    None => {
                        let mut provider = cgc_cloud_provider();
                        provider.enabled = enabled;
                        prefs.upsert_provider(provider);
                    }
                }
                self.save(&mut prefs)
            }
            ProviderPrefsChange::SetManagedModelEnabled { model_id, enabled } => {
                let mut prefs = self.prefs.load();
                if !prefs
                    .providers
                    .iter()
                    .any(|provider| provider.id == CGC_CLOUD_PROVIDER_ID)
                {
                    prefs.upsert_provider(cgc_cloud_provider());
                }
                let Some(provider) = prefs
                    .providers
                    .iter_mut()
                    .find(|provider| provider.id == CGC_CLOUD_PROVIDER_ID)
                else {
                    return Ok(());
                };
                match provider
                    .model_params
                    .iter_mut()
                    .find(|model| model.id == model_id)
                {
                    Some(model) => model.enabled = enabled,
                    None => {
                        let mut model = ModelPrefs::new(model_id);
                        model.enabled = enabled;
                        provider.model_params.push(model);
                    }
                }
                self.save(&mut prefs)
            }
            ProviderPrefsChange::SaveKey { mut provider, key } => {
                provider.builtin |= is_builtin_provider_id(&provider.id);
                let account = provider_key_account(&provider.id);
                let previous = self.keychain.load_secret(&account);
                self.keychain
                    .save_secret(&account, &key)
                    .map_err(|error| ProviderSettingsError::Keychain(error.to_string()))?;
                provider.has_key = true;
                let mut prefs = self.prefs.load();
                prefs.upsert_provider(provider.clone());
                prefs.selected_provider = Some(provider.id.clone());
                if let Err(error) = self.save(&mut prefs) {
                    let _ = self.restore_key(&provider.id, previous);
                    return Err(error);
                }
                Ok(())
            }
            ProviderPrefsChange::ClearKey { provider_id } => {
                let account = provider_key_account(&provider_id);
                let previous = self.keychain.load_secret(&account);
                self.keychain
                    .clear_secret(&account)
                    .map_err(|error| ProviderSettingsError::Keychain(error.to_string()))?;
                let mut prefs = self.prefs.load();
                if let Some(provider) = prefs
                    .providers
                    .iter_mut()
                    .find(|provider| provider.id == provider_id)
                {
                    provider.has_key = false;
                }
                if let Err(error) = self.save(&mut prefs) {
                    let _ = self.restore_key(&provider_id, previous);
                    return Err(error);
                }
                Ok(())
            }
            ProviderPrefsChange::RemoveProvider { provider_id } => {
                let mut prefs = self.prefs.load();
                prefs.remove_provider(&provider_id);
                self.save(&mut prefs)?;
                // prefs 已删除后不再回滚；清 Key 失败只遗留旧 secret，不丢 Provider。
                let _ = self
                    .keychain
                    .clear_secret(&provider_key_account(&provider_id));
                Ok(())
            }
        }
    }

    fn restore_key(
        &self,
        provider_id: &str,
        previous: Option<String>,
    ) -> Result<(), ProviderSettingsError> {
        let account = provider_key_account(provider_id);
        match previous {
            Some(key) => self
                .keychain
                .save_secret(&account, &key)
                .map_err(|error| ProviderSettingsError::Keychain(error.to_string())),
            None => self
                .keychain
                .clear_secret(&account)
                .map_err(|error| ProviderSettingsError::Keychain(error.to_string())),
        }
    }

    fn save(&self, prefs: &mut AgentPrefs) -> Result<(), ProviderSettingsError> {
        // 切换 Provider 或移除模型后，热刷新可能返回 Busy；持久化选择不能依赖刷新修正。
        if prefs
            .selected_model
            .as_ref()
            .is_some_and(|selection| !selection_is_available(prefs, selection))
        {
            prefs.selected_model = None;
        }
        self.prefs
            .save(prefs)
            .map_err(|error| ProviderSettingsError::Prefs(error.to_string()))
    }
}

/// 选择是否仍可落到当前 provider。
///
/// 托管网关的模型目录只存在内存/缓存里，磁盘覆盖记录不复制远端 `models`；
/// 因此托管分支只校验 provider 启用与单模型未显式禁用。
fn selection_is_available(prefs: &AgentPrefs, selection: &SelectedModel) -> bool {
    let Some(provider) = prefs.active_provider() else {
        return false;
    };
    if selection.provider_id.as_str() != provider.id {
        return false;
    }
    let model_enabled = provider
        .model_params
        .iter()
        .find(|model| model.id == selection.model_id.as_str())
        .is_none_or(|model| model.enabled);
    if is_managed_provider_id(&provider.id) {
        return model_enabled;
    }
    provider
        .models
        .iter()
        .any(|id| id == selection.model_id.as_str())
        && model_enabled
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use cgc_agent_core::SelectedModel;
    use cgc_agent_provider::probe::RemoteModel;
    use cgc_agent_provider::{ModelId, ProviderId};
    use cgc_agent_store::{
        cgc_cloud_provider_with_models, provider_key_account, ModelPrefs, PrefsStore,
        ProviderPrefs, CGC_CLOUD_PROVIDER_ID,
    };
    use cgc_platform::session::{KeychainStore, SecretBackend};

    use super::{ProviderPrefsChange, ProviderSettings};

    #[derive(Default)]
    struct MemoryBackend {
        secret: std::sync::Mutex<Option<(String, String)>>,
    }

    impl SecretBackend for MemoryBackend {
        fn set(&self, account: &str, secret: &str) -> std::io::Result<()> {
            *self.secret.lock().expect("memory secret") =
                Some((account.to_string(), secret.to_string()));
            Ok(())
        }

        fn get(&self, account: &str) -> std::io::Result<Option<String>> {
            let secret = self.secret.lock().expect("memory secret");
            Ok(secret
                .as_ref()
                .filter(|(stored, _)| stored == account)
                .map(|(_, value)| value.clone()))
        }

        fn delete(&self, account: &str) -> std::io::Result<()> {
            let mut secret = self.secret.lock().expect("memory secret");
            if secret.as_ref().is_some_and(|(stored, _)| stored == account) {
                *secret = None;
            }
            Ok(())
        }
    }

    fn provider() -> ProviderPrefs {
        ProviderPrefs {
            id: "test-provider".into(),
            name: "Test".into(),
            base_url: "https://example.test/v1".into(),
            anthropic_url: None,
            responses_url: None,
            models_url: None,
            models: vec!["test-model".into()],
            has_key: false,
            model_params: Vec::new(),
            builtin: false,
            enabled: true,
            protocol: cgc_agent_provider::ProviderProtocol::OpenAiCompatible,
            ..Default::default()
        }
    }

    fn settings(root: &std::path::Path) -> ProviderSettings {
        ProviderSettings {
            prefs: PrefsStore::new(root.join("agent_prefs.json")),
            keychain: KeychainStore::new(Arc::new(MemoryBackend::default())),
        }
    }

    fn settings_with_failing_prefs(root: &std::path::Path) -> ProviderSettings {
        // agent_prefs.json 是目录时 save() 的 rename 必然失败，用来模拟磁盘/权限错误。
        std::fs::create_dir_all(root.join("agent_prefs.json")).expect("failing prefs dir");
        settings(root)
    }

    #[test]
    fn saving_a_builtin_provider_keeps_its_catalog_mark() {
        let root = std::env::temp_dir().join(format!("cgc-builtin-mark-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let settings = settings(&root);
        let mut builtin = provider();
        builtin.id = "deepseek".into();
        builtin.name = "DeepSeek".into();
        settings
            .apply(ProviderPrefsChange::SaveProvider(builtin))
            .expect("save builtin");
        let saved = settings
            .load()
            .provider("deepseek")
            .cloned()
            .expect("saved builtin");
        assert!(saved.builtin);
    }

    #[test]
    fn saving_a_custom_provider_stays_custom() {
        let root = std::env::temp_dir().join(format!("cgc-custom-mark-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let settings = settings(&root);
        settings
            .apply(ProviderPrefsChange::SaveProvider(provider()))
            .expect("save custom");
        let saved = settings
            .load()
            .provider("test-provider")
            .cloned()
            .expect("saved custom");
        assert!(!saved.builtin);
    }

    #[test]
    fn saving_a_key_for_a_builtin_provider_keeps_its_catalog_mark() {
        let root = std::env::temp_dir().join(format!("cgc-builtin-key-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let settings = settings(&root);
        let mut builtin = provider();
        builtin.id = "deepseek".into();
        builtin.name = "DeepSeek".into();
        settings
            .apply(ProviderPrefsChange::SaveKey {
                provider: builtin,
                key: "secret".into(),
            })
            .expect("save key");
        let saved = settings
            .load()
            .provider("deepseek")
            .cloned()
            .expect("saved builtin");
        assert!(saved.builtin);
    }

    #[test]
    fn save_key_and_clear_key_update_both_stores() {
        let root =
            std::env::temp_dir().join(format!("cgc-provider-settings-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let settings = settings(&root);
        let mut provider = provider();
        settings
            .apply(ProviderPrefsChange::SaveKey {
                provider: provider.clone(),
                key: "secret".into(),
            })
            .expect("save key");
        assert!(settings.has_key(&provider.id));
        assert!(settings
            .load()
            .provider(&provider.id)
            .is_some_and(|p| p.has_key));
        assert_eq!(
            settings.load().selected_provider.as_deref(),
            Some(provider.id.as_str())
        );
        // Key 只进 keychain：prefs 文件仅保留 has_key 标记，不含明文。
        let raw = std::fs::read_to_string(root.join("agent_prefs.json")).expect("prefs");
        assert!(
            !raw.contains("secret"),
            "prefs must not contain the key: {raw}"
        );

        settings
            .apply(ProviderPrefsChange::ClearKey {
                provider_id: provider.id.clone(),
            })
            .expect("clear key");
        assert!(!settings.has_key(&provider.id));
        assert!(!settings
            .load()
            .provider(&provider.id)
            .is_some_and(|p| p.has_key));

        provider.has_key = false;
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn remove_provider_clears_its_key() {
        let root =
            std::env::temp_dir().join(format!("cgc-provider-remove-key-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let settings = settings(&root);
        let provider = provider();
        settings
            .apply(ProviderPrefsChange::SaveKey {
                provider: provider.clone(),
                key: "secret".into(),
            })
            .expect("save key");
        settings
            .apply(ProviderPrefsChange::RemoveProvider {
                provider_id: provider.id.clone(),
            })
            .expect("remove provider");
        assert!(!settings.has_key(&provider.id));
        assert!(settings.load().provider(&provider.id).is_none());
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn save_provider_keeps_an_existing_selection() {
        let root =
            std::env::temp_dir().join(format!("cgc-provider-selection-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let settings = settings(&root);
        let mut first = provider();
        first.id = "first".into();
        let mut second = provider();
        second.id = "second".into();
        settings
            .apply(ProviderPrefsChange::SaveProvider(first.clone()))
            .expect("save first");
        let selected = cgc_agent_core::SelectedModel::new(
            cgc_agent_provider::ProviderId::new("first"),
            cgc_agent_provider::ModelId::new("test-model"),
        );
        let mut prefs = settings.load();
        prefs.selected_model = Some(selected.clone());
        settings.prefs.save(&prefs).expect("select first model");
        settings
            .apply(ProviderPrefsChange::SaveProvider(second.clone()))
            .expect("save second");
        assert_eq!(settings.load().selected_provider.as_deref(), Some("first"));
        assert_eq!(settings.load().selected_model, Some(selected));
        settings
            .apply(ProviderPrefsChange::RemoveProvider {
                provider_id: "first".into(),
            })
            .expect("remove first");
        assert_eq!(settings.load().selected_provider.as_deref(), Some("second"));
        assert_eq!(settings.load().selected_model, None);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn saving_another_providers_key_clears_the_previous_model_selection() {
        let root =
            std::env::temp_dir().join(format!("cgc-provider-key-selection-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let settings = settings(&root);
        let first = provider();
        settings
            .apply(ProviderPrefsChange::SaveProvider(first.clone()))
            .expect("save first provider");
        let mut prefs = settings.load();
        prefs.selected_model = Some(cgc_agent_core::SelectedModel::new(
            cgc_agent_provider::ProviderId::new(first.id.clone()),
            cgc_agent_provider::ModelId::new("test-model"),
        ));
        settings.prefs.save(&prefs).expect("select first model");
        let second = ProviderPrefs {
            id: "second-provider".into(),
            models: vec!["second-model".into()],
            ..provider()
        };

        // 热刷新可能返回 Busy；保存本身必须留下可供重启使用的一致配置。
        settings
            .apply(ProviderPrefsChange::SaveKey {
                provider: second,
                key: "second-secret".into(),
            })
            .expect("save second key");

        let saved = settings.load();
        assert_eq!(saved.selected_provider.as_deref(), Some("second-provider"));
        assert_eq!(saved.selected_model, None);
        assert_eq!(
            saved
                .active_provider()
                .and_then(ProviderPrefs::primary_model),
            Some("second-model")
        );
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn save_key_rolls_back_when_prefs_fail() {
        let root =
            std::env::temp_dir().join(format!("cgc-save-key-rollback-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let settings = settings_with_failing_prefs(&root);
        let provider = provider();
        let account = provider_key_account(&provider.id);
        settings
            .keychain
            .save_secret(&account, "old-secret")
            .unwrap();
        let result = settings.apply(ProviderPrefsChange::SaveKey {
            provider: provider.clone(),
            key: "new-secret".into(),
        });
        assert!(result.is_err());
        assert_eq!(
            settings.keychain.load_secret(&account).as_deref(),
            Some("old-secret")
        );
        assert!(settings.load().provider(&provider.id).is_none());
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn clear_key_rolls_back_when_prefs_fail() {
        let root =
            std::env::temp_dir().join(format!("cgc-clear-key-rollback-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let settings = settings_with_failing_prefs(&root);
        let provider = provider();
        let account = provider_key_account(&provider.id);
        settings.keychain.save_secret(&account, "existing").unwrap();
        let result = settings.apply(ProviderPrefsChange::ClearKey {
            provider_id: provider.id.clone(),
        });
        assert!(result.is_err());
        assert_eq!(
            settings.keychain.load_secret(&account).as_deref(),
            Some("existing")
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn remove_provider_leaves_key_if_prefs_fail() {
        let root =
            std::env::temp_dir().join(format!("cgc-remove-prefs-fail-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let settings = settings_with_failing_prefs(&root);
        let provider = provider();
        let account = provider_key_account(&provider.id);
        settings
            .keychain
            .save_secret(&account, "to-be-kept")
            .unwrap();
        let result = settings.apply(ProviderPrefsChange::RemoveProvider {
            provider_id: provider.id.clone(),
        });
        assert!(result.is_err());
        assert_eq!(
            settings.keychain.load_secret(&account).as_deref(),
            Some("to-be-kept")
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn catalog_updates_only_the_named_provider() {
        let root = std::env::temp_dir().join(format!("cgc-catalog-save-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let settings = settings(&root);
        settings
            .apply(ProviderPrefsChange::SaveProvider(provider()))
            .expect("save provider");
        let models = vec![RemoteModel {
            id: "vendor-model".into(),
            name: Some("Vendor Model".into()),
            context_window: Some(128_000),
            max_output_tokens: Some(8_000),
            supports_images: Some(false),
            reasoning_efforts: vec!["low".into(), "high".into()],
        }];
        settings
            .apply(ProviderPrefsChange::SaveProviderCatalog {
                provider_id: "test-provider".into(),
                models: models.clone(),
                fetched_at: 1_700_000_000,
            })
            .expect("save catalog");
        let saved = settings
            .load()
            .provider("test-provider")
            .cloned()
            .expect("saved");
        assert_eq!(saved.available_models, models);
        assert_eq!(saved.models_fetched_at, 1_700_000_000);
        assert_eq!(saved.models, vec!["test-model".to_string()]);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn catalog_update_for_unsaved_provider_is_ignored() {
        let root = std::env::temp_dir().join(format!("cgc-catalog-unsaved-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let settings = settings(&root);
        settings
            .apply(ProviderPrefsChange::SaveProviderCatalog {
                provider_id: "missing".into(),
                models: Vec::new(),
                fetched_at: 1,
            })
            .expect("no-op");
        assert!(settings.load().provider("missing").is_none());
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn enabling_only_updates_the_flag() {
        let root = std::env::temp_dir().join(format!("cgc-enable-only-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let settings = settings(&root);
        let mut saved = provider();
        saved.protocol = cgc_agent_provider::ProviderProtocol::AnthropicCompatible;
        settings
            .apply(ProviderPrefsChange::SaveProvider(saved))
            .expect("save provider");
        settings
            .apply(ProviderPrefsChange::SetProviderEnabled {
                provider_id: "test-provider".into(),
                enabled: false,
            })
            .expect("disable");
        let after = settings
            .load()
            .provider("test-provider")
            .cloned()
            .expect("provider");
        assert!(!after.enabled);
        assert_eq!(
            after.protocol,
            cgc_agent_provider::ProviderProtocol::AnthropicCompatible
        );
        assert_eq!(after.models, vec!["test-model".to_string()]);
        let _ = std::fs::remove_dir_all(&root);
    }

    fn select_managed_model(settings: &ProviderSettings, model_id: &str) {
        let mut prefs = settings.load();
        prefs.upsert_provider(cgc_cloud_provider_with_models(vec![ModelPrefs::new(
            model_id,
        )]));
        prefs.selected_provider = Some(CGC_CLOUD_PROVIDER_ID.to_string());
        prefs.selected_model = Some(SelectedModel::new(
            ProviderId::new(CGC_CLOUD_PROVIDER_ID),
            ModelId::new(model_id),
        ));
        settings.prefs.save(&prefs).expect("seed managed prefs");
    }

    #[test]
    fn managed_selection_survives_byok_save() {
        let root = std::env::temp_dir().join(format!("cgc-managed-select-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let settings = settings(&root);
        select_managed_model(&settings, "managed-model");

        settings
            .apply(ProviderPrefsChange::SaveProvider(provider()))
            .expect("save byok provider");

        let prefs = settings.load();
        assert_eq!(
            prefs.selected_provider.as_deref(),
            Some(CGC_CLOUD_PROVIDER_ID)
        );
        let selection = prefs.selected_model.expect("managed selection kept");
        assert_eq!(selection.provider_id.as_str(), CGC_CLOUD_PROVIDER_ID);
        assert_eq!(selection.model_id.as_str(), "managed-model");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn managed_provider_enable_upserts_missing_record() {
        let root = std::env::temp_dir().join(format!("cgc-managed-upsert-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let settings = settings(&root);

        settings
            .apply(ProviderPrefsChange::SetManagedProviderEnabled { enabled: false })
            .expect("disable managed provider");

        let provider = settings
            .load()
            .provider(CGC_CLOUD_PROVIDER_ID)
            .cloned()
            .expect("managed record upserted");
        assert!(!provider.enabled);
        assert!(provider.models.is_empty());
        assert!(provider.model_params.is_empty());
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn managed_model_enable_upserts_model_param() {
        let root = std::env::temp_dir().join(format!("cgc-managed-model-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let settings = settings(&root);

        settings
            .apply(ProviderPrefsChange::SetManagedModelEnabled {
                model_id: "managed-model".into(),
                enabled: false,
            })
            .expect("disable managed model");

        let provider = settings
            .load()
            .provider(CGC_CLOUD_PROVIDER_ID)
            .cloned()
            .expect("managed record upserted");
        assert!(
            provider.models.is_empty(),
            "must not copy the remote catalog"
        );
        let model = provider
            .model_params
            .iter()
            .find(|model| model.id == "managed-model")
            .expect("model override");
        assert!(!model.enabled);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn disabling_managed_model_clears_selection() {
        let root = std::env::temp_dir().join(format!("cgc-managed-clear-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let settings = settings(&root);
        select_managed_model(&settings, "managed-model");

        settings
            .apply(ProviderPrefsChange::SetManagedModelEnabled {
                model_id: "managed-model".into(),
                enabled: false,
            })
            .expect("disable selected managed model");

        assert!(settings.load().selected_model.is_none());
        let _ = std::fs::remove_dir_all(&root);
    }
}
