//! DSH external ACP agent 的启动装配（ADR-0030 D2）：从本机 keychain 读取 Key，
//! 只放进子进程环境（`DEEPSEEK_API_KEY` / `DEEPSEEK_BASE_URL`），不写 settings/日志/文件。
//!
//! 选择规则：优先使用内置 `deepseek`（DeepSeek）provider 已保存的 key；否则回退到
//! 当前选中的、已配置 base URL 的 OpenAI-compatible provider（空 base URL 不注入，
//! 否则 key 会被发到 adapter 默认的 DeepSeek 端点）。都没有可用 key 时返回空环境，
//! 由适配器走 `auth_required` 登录路径（P3）。

use std::collections::BTreeMap;
use std::path::PathBuf;

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
        dsh_plugin: None,
        extra_env,
    }
}

/// DSH plugin 形态（ADR-0030 D1 修订）：有 DSH Desktop 时优先走这个入口。
pub(crate) fn dsh_plugin() -> Option<cgc_platform::agent::dsh_plugin::DshPlugin> {
    cgc_platform::agent::dsh_plugin::probe()
}

/// plugin 形态启动参数：`dsh --profile acp` + 用户 DSH 目录。
pub(crate) fn dsh_plugin_launch_options(
    plugin: cgc_platform::agent::dsh_plugin::DshPlugin,
    mut extra_env: BTreeMap<String, String>,
) -> LaunchOptions {
    // adapter 的 credential gate 只认 `<PROVIDER>_API_KEY`；把本地 DSH 的
    // `apiKeyEnv` 引用映射成这些名字（CGC keychain 已注入的同名值优先）。
    for (key, value) in cgc_platform::agent::dsh_plugin::credential_env(&plugin) {
        extra_env.entry(key).or_insert(value);
    }
    LaunchOptions {
        dsh_path: None,
        dsh_home: Some(plugin.home),
        dsh_plugin: Some(plugin.dsh),
        extra_env,
    }
}

/// 生产入口：读取当前用户 prefs 与系统 keychain。密钥只在内存与子进程环境中。
pub(crate) fn dsh_launch_env() -> BTreeMap<String, String> {
    let prefs = prefs_store().load();
    dsh_launch_env_from(&prefs, &KeychainStore::from_env())
}

fn prefs_store() -> PrefsStore {
    PrefsStore::new(AppPaths::from_env().agent_prefs_file())
}

/// ADR-0030 D3 opt-in：是否与本地 DSH 共享会话数据。
pub(crate) fn dsh_share_local_home() -> bool {
    prefs_store().load().dsh_share_local_home
}

pub(crate) fn set_dsh_share_local_home(shared: bool) -> Result<(), String> {
    let store = prefs_store();
    let mut prefs = store.load();
    prefs.dsh_share_local_home = shared;
    store.save(&prefs).map_err(|error| error.to_string())
}

/// 本次会话使用的 `(DSH_HOME, 是否与本地 DSH 共享)`。
///
/// 共享必须同时满足「用户显式开启」与「能解析出本地目录」；任一不满足都回退
/// 隔离目录，绝不能把空路径当成共享目录。
pub(crate) fn resolve_dsh_home() -> (PathBuf, bool) {
    resolve_dsh_home_with(
        dsh_share_local_home(),
        AppPaths::from_env().dsh_home_root(),
        cgc_platform::paths::local_dsh_home_from_env(),
    )
}

fn resolve_dsh_home_with(
    shared: bool,
    isolated: PathBuf,
    local: Option<PathBuf>,
) -> (PathBuf, bool) {
    match local {
        Some(local) if shared => (local, true),
        _ => (isolated, false),
    }
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
            // 非 DeepSeek provider 的 key 只能用在该 provider 自己的端点上：base_url 为空时
            // adapter 会回落到 DeepSeek 官方端点，等于把别人的 key 发给 DeepSeek。
            prefs.active_provider().filter(|provider| {
                provider.has_key
                    && provider.protocol == ProviderProtocol::OpenAiCompatible
                    && !provider.base_url.trim().is_empty()
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
            dsh_plugin: None,
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
    fn active_provider_without_base_url_does_not_inject_key() {
        let backend = Arc::new(MemoryBackend::default());
        let keychain = KeychainStore::new(backend);
        keychain
            .save_secret(&provider_key_account("custom"), "sk-custom")
            .expect("save key");
        let mut prefs = AgentPrefs::default();
        prefs.upsert_provider(provider("custom", true, ""));
        prefs.selected_provider = Some("custom".into());
        assert!(
            dsh_launch_env_from(&prefs, &keychain).is_empty(),
            "empty base_url would send the key to the DeepSeek default endpoint"
        );
    }

    #[test]
    fn active_provider_with_base_url_routes_key_to_its_endpoint() {
        let backend = Arc::new(MemoryBackend::default());
        let keychain = KeychainStore::new(backend);
        keychain
            .save_secret(&provider_key_account("custom"), "sk-custom")
            .expect("save key");
        let mut prefs = AgentPrefs::default();
        prefs.upsert_provider(provider("custom", true, "https://api.example.test/"));
        prefs.selected_provider = Some("custom".into());
        let env = dsh_launch_env_from(&prefs, &keychain);
        assert_eq!(
            env.get("DEEPSEEK_API_KEY").map(String::as_str),
            Some("sk-custom")
        );
        assert_eq!(
            env.get("DEEPSEEK_BASE_URL").map(String::as_str),
            Some("https://api.example.test")
        );
    }

    #[test]
    fn dsh_home_shares_only_when_enabled_and_local_path_resolves() {
        let isolated = PathBuf::from("/data/dsh-home");
        let local = PathBuf::from("/Users/example/.dsh");

        assert_eq!(
            resolve_dsh_home_with(false, isolated.clone(), Some(local.clone())),
            (isolated.clone(), false),
            "opt-in disabled must stay isolated"
        );
        assert_eq!(
            resolve_dsh_home_with(true, isolated.clone(), Some(local.clone())),
            (local, true)
        );
        assert_eq!(
            resolve_dsh_home_with(true, isolated.clone(), None),
            (isolated, false),
            "missing HOME must fall back to the isolated directory"
        );
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
