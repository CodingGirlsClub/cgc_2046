//! Provider 配置的唯一写入入口：统一 prefs 与 keychain 的保存/删除/清除。

use std::fmt;

use cgc_agent_store::{provider_key_account, AgentPrefs, PrefsStore, ProviderPrefs};
use cgc_platform::paths::AppPaths;
use cgc_platform::session::KeychainStore;

#[derive(Clone, Debug)]
pub(crate) enum ProviderPrefsChange {
    SaveProvider(ProviderPrefs),
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

    pub(crate) fn apply(&self, change: ProviderPrefsChange) -> Result<(), ProviderSettingsError> {
        match change {
            ProviderPrefsChange::SaveProvider(provider) => {
                let mut prefs = self.prefs.load();
                let selected = prefs.selected_provider.as_deref();
                let should_select = selected.is_none() || selected == Some(provider.id.as_str());
                prefs.upsert_provider(provider.clone());
                if should_select {
                    prefs.selected_provider = Some(provider.id);
                }
                self.save(&prefs)
            }
            ProviderPrefsChange::SaveKey { mut provider, key } => {
                let account = provider_key_account(&provider.id);
                let previous = self.keychain.load_secret(&account);
                self.keychain
                    .save_secret(&account, &key)
                    .map_err(|error| ProviderSettingsError::Keychain(error.to_string()))?;
                provider.has_key = true;
                let mut prefs = self.prefs.load();
                prefs.upsert_provider(provider.clone());
                prefs.selected_provider = Some(provider.id.clone());
                if let Err(error) = self.save(&prefs) {
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
                if let Err(error) = self.save(&prefs) {
                    let _ = self.restore_key(&provider_id, previous);
                    return Err(error);
                }
                Ok(())
            }
            ProviderPrefsChange::RemoveProvider { provider_id } => {
                let mut prefs = self.prefs.load();
                prefs.remove_provider(&provider_id);
                self.save(&prefs)?;
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

    fn save(&self, prefs: &AgentPrefs) -> Result<(), ProviderSettingsError> {
        self.prefs
            .save(prefs)
            .map_err(|error| ProviderSettingsError::Prefs(error.to_string()))
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use cgc_agent_store::{provider_key_account, PrefsStore, ProviderPrefs};
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
            models: vec!["test-model".into()],
            has_key: false,
            model_params: Vec::new(),
            builtin: false,
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
        settings
            .apply(ProviderPrefsChange::SaveProvider(second.clone()))
            .expect("save second");
        assert_eq!(settings.load().selected_provider.as_deref(), Some("first"));
        settings
            .apply(ProviderPrefsChange::RemoveProvider {
                provider_id: "first".into(),
            })
            .expect("remove first");
        assert_eq!(settings.load().selected_provider.as_deref(), Some("second"));
        let _ = std::fs::remove_dir_all(&root);
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
}
