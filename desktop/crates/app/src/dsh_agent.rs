//! DSH external ACP agent 的启动装配（ADR-0030 D2）：从本机 keychain 读取 Key，
//! 只放进子进程环境（`DEEPSEEK_API_KEY` / `DEEPSEEK_BASE_URL`），不写 settings/日志/文件。
//!
//! 选择规则：优先使用内置 `deepseek`（DeepSeek）provider 已保存的 key；否则回退到
//! 当前选中的 OpenAI-compatible provider。都没有 key 时返回空环境，由适配器走
//! `auth_required` 登录路径（P3）。

use std::collections::BTreeMap;

use cgc_agent_provider::ProviderProtocol;
use cgc_agent_store::{provider_key_account, AgentPrefs, PrefsStore};
use cgc_platform::agent::launch::LaunchOptions;
use cgc_platform::paths::AppPaths;
use cgc_platform::session::KeychainStore;

pub(crate) const DEEPSEEK_PROVIDER_ID: &str = "deepseek";

/// DSH 启动装配：固定 bundled 运行时、隔离 DSH_HOME、只带 keychain 注入的 env。
pub(crate) fn dsh_launch_options(
    dsh_home: std::path::PathBuf,
    extra_env: BTreeMap<String, String>,
) -> LaunchOptions {
    LaunchOptions {
        dsh_path: Some("bundled".to_string()),
        dsh_home: Some(dsh_home),
        extra_env,
    }
}

/// 生产入口：读取当前用户 prefs 与系统 keychain。密钥只在内存与子进程环境中。
pub(crate) fn dsh_launch_env() -> BTreeMap<String, String> {
    let prefs = PrefsStore::new(AppPaths::from_env().agent_prefs_file()).load();
    dsh_launch_env_from(&prefs, &KeychainStore::from_env())
}

/// 可注入核心：测试用内存 keychain，避免触碰本机钥匙串。
pub(crate) fn dsh_launch_env_from(
    prefs: &AgentPrefs,
    keychain: &KeychainStore,
) -> BTreeMap<String, String> {
    let provider = prefs
        .provider(DEEPSEEK_PROVIDER_ID)
        .filter(|provider| provider.has_key)
        .or_else(|| {
            prefs.active_provider().filter(|provider| {
                provider.has_key && provider.protocol == ProviderProtocol::OpenAiCompatible
            })
        });
    let Some(provider) = provider else {
        return BTreeMap::new();
    };
    let Some(key) = keychain
        .load_secret(&provider_key_account(&provider.id))
        .map(|key| key.trim().to_string())
        .filter(|key| !key.is_empty())
    else {
        return BTreeMap::new();
    };
    let mut env = BTreeMap::new();
    env.insert("DEEPSEEK_API_KEY".to_string(), key);
    if !provider.base_url.trim().is_empty() {
        env.insert(
            "DEEPSEEK_BASE_URL".to_string(),
            provider.base_url.trim().trim_end_matches('/').to_string(),
        );
    }
    env
}

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Mutex};

    use cgc_agent_store::ProviderPrefs;
    use cgc_platform::session::SecretBackend;

    use super::*;

    #[derive(Default)]
    struct MemoryBackend {
        secret: Mutex<Option<(String, String)>>,
    }

    impl SecretBackend for MemoryBackend {
        fn set(&self, account: &str, secret: &str) -> std::io::Result<()> {
            *self.secret.lock().expect("secret") = Some((account.to_string(), secret.to_string()));
            Ok(())
        }

        fn get(&self, account: &str) -> std::io::Result<Option<String>> {
            let secret = self.secret.lock().expect("secret");
            Ok(secret
                .as_ref()
                .filter(|(stored, _)| stored == account)
                .map(|(_, value)| value.clone()))
        }

        fn delete(&self, account: &str) -> std::io::Result<()> {
            let mut secret = self.secret.lock().expect("secret");
            if secret.as_ref().is_some_and(|(stored, _)| stored == account) {
                *secret = None;
            }
            Ok(())
        }
    }

    fn provider(id: &str, has_key: bool, base_url: &str) -> ProviderPrefs {
        ProviderPrefs {
            id: id.to_string(),
            name: id.to_string(),
            base_url: base_url.to_string(),
            models: Vec::new(),
            has_key,
            model_params: Vec::new(),
            builtin: true,
            protocol: ProviderProtocol::OpenAiCompatible,
        }
    }

    #[test]
    fn deepseek_provider_key_becomes_child_environment_only() {
        let backend = Arc::new(MemoryBackend::default());
        let keychain = KeychainStore::new(backend.clone());
        keychain
            .save_secret(&provider_key_account(DEEPSEEK_PROVIDER_ID), "sk-test")
            .expect("save key");
        let mut prefs = AgentPrefs::default();
        prefs.upsert_provider(provider(
            DEEPSEEK_PROVIDER_ID,
            true,
            "https://api.deepseek.com/",
        ));
        let env = dsh_launch_env_from(&prefs, &keychain);
        assert_eq!(
            env.get("DEEPSEEK_API_KEY").map(String::as_str),
            Some("sk-test")
        );
        assert_eq!(
            env.get("DEEPSEEK_BASE_URL").map(String::as_str),
            Some("https://api.deepseek.com")
        );
    }

    #[test]
    fn keychain_secret_is_not_exposed_in_launch_options_debug() {
        let backend = Arc::new(MemoryBackend::default());
        let keychain = KeychainStore::new(backend);
        keychain
            .save_secret(&provider_key_account(DEEPSEEK_PROVIDER_ID), "sk-secret")
            .expect("save key");
        let mut prefs = AgentPrefs::default();
        prefs.upsert_provider(provider(
            DEEPSEEK_PROVIDER_ID,
            true,
            "https://api.deepseek.com",
        ));
        let env = dsh_launch_env_from(&prefs, &keychain);
        let options = cgc_platform::agent::launch::LaunchOptions {
            dsh_path: Some("bundled".into()),
            dsh_home: None,
            extra_env: env,
        };
        let debug = format!("{options:?}");
        assert!(!debug.contains("sk-secret"));
        assert!(debug.contains("DEEPSEEK_API_KEY"));
    }

    #[test]
    fn no_saved_key_yields_empty_environment() {
        let backend = Arc::new(MemoryBackend::default());
        let keychain = KeychainStore::new(backend);
        let mut prefs = AgentPrefs::default();
        prefs.upsert_provider(provider(
            DEEPSEEK_PROVIDER_ID,
            false,
            "https://api.deepseek.com",
        ));
        assert!(dsh_launch_env_from(&prefs, &keychain).is_empty());
    }

    #[test]
    fn dsh_launch_options_pin_bundled_and_isolated_home() {
        let options = dsh_launch_options(
            std::path::PathBuf::from("/data/dsh-home"),
            BTreeMap::from([("DEEPSEEK_API_KEY".to_string(), "sk-test".to_string())]),
        );
        assert_eq!(options.dsh_path.as_deref(), Some("bundled"));
        assert_eq!(
            options.dsh_home.as_deref(),
            Some(std::path::Path::new("/data/dsh-home"))
        );
        assert_eq!(
            options
                .extra_env
                .get("DEEPSEEK_API_KEY")
                .map(String::as_str),
            Some("sk-test")
        );
    }
}
