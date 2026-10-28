//! 环境数据根与 keychain service 隔离（story 1.9）。
//!
//! dev / staging / prod 使用不同的数据根、缓存根与 keychain service，避免误读写
//! 生产凭证与数据；`CGC_ENV` 显式指定，`CGC_DATA_DIR`/`CGC_CACHE_DIR` 可覆盖。
//!
//! 默认（未指定）为 dev；发布构建可用编译期 `CGC_DEFAULT_ENV=prod` 把默认值编进二进制
//! （见 `runtime::build_default_environment`）——用户双击 `.app` 启动时拿不到 shell
//! 环境变量，只能靠这条路径进生产数据根。

use std::path::PathBuf;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AppEnvironment {
    Dev,
    Staging,
    Prod,
}

impl AppEnvironment {
    pub fn parse(value: &str) -> Option<Self> {
        match value.trim().to_ascii_lowercase().as_str() {
            "dev" | "development" | "local" => Some(Self::Dev),
            "staging" | "stage" => Some(Self::Staging),
            "prod" | "production" => Some(Self::Prod),
            _ => None,
        }
    }

    pub fn suffix(self) -> &'static str {
        match self {
            Self::Dev => "-dev",
            Self::Staging => "-staging",
            Self::Prod => "",
        }
    }

    pub fn keychain_service(self) -> &'static str {
        match self {
            Self::Dev => "cgc-desktop-dev",
            Self::Staging => "cgc-desktop-staging",
            Self::Prod => "cgc-desktop",
        }
    }
}

/// 用户配置文件所在平台（与 Zed 的 per-OS settings 路径对齐）。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ConfigPlatform {
    MacOs,
    Linux,
    Windows,
}

pub fn current_config_platform() -> ConfigPlatform {
    if cfg!(target_os = "macos") {
        ConfigPlatform::MacOs
    } else if cfg!(target_os = "windows") {
        ConfigPlatform::Windows
    } else {
        ConfigPlatform::Linux
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AppPaths {
    pub environment: AppEnvironment,
    pub data_root: PathBuf,
    pub cache_root: PathBuf,
}

impl AppPaths {
    /// 解析当前进程路径：`CGC_ENV` > 发布构建默认值 > dev。
    pub fn from_env() -> Self {
        let explicit = std::env::var("CGC_ENV").ok();
        let environment = crate::runtime::resolve_environment(
            explicit.as_deref(),
            crate::runtime::build_default_environment(),
        );
        Self::from_environment(environment, |key| std::env::var_os(key).map(PathBuf::from))
    }

    /// 可注入 env 读取器（测试用），不直接改进程环境；未指定环境按 dev。
    pub fn resolve(env_value: Option<&str>, env_path: impl Fn(&str) -> Option<PathBuf>) -> Self {
        let environment = env_value
            .and_then(AppEnvironment::parse)
            .unwrap_or(AppEnvironment::Dev);
        Self::from_environment(environment, env_path)
    }

    fn from_environment(
        environment: AppEnvironment,
        env_path: impl Fn(&str) -> Option<PathBuf>,
    ) -> Self {
        let suffix = environment.suffix();
        let home = env_path("HOME").unwrap_or_else(std::env::temp_dir);
        let data_base = if cfg!(target_os = "macos") {
            env_path("HOME")
                .map(|home| home.join("Library/Application Support"))
                .unwrap_or_else(std::env::temp_dir)
        } else if cfg!(target_os = "windows") {
            env_path("APPDATA").unwrap_or_else(std::env::temp_dir)
        } else {
            env_path("XDG_DATA_HOME").unwrap_or_else(|| home.join(".local/share"))
        };
        let cache_base = if cfg!(target_os = "macos") {
            env_path("HOME")
                .map(|home| home.join("Library/Caches"))
                .unwrap_or_else(std::env::temp_dir)
        } else if cfg!(target_os = "windows") {
            env_path("LOCALAPPDATA").unwrap_or_else(std::env::temp_dir)
        } else {
            env_path("XDG_CACHE_HOME").unwrap_or_else(|| home.join(".cache"))
        };
        let data_root = env_path("CGC_DATA_DIR")
            .unwrap_or_else(|| data_base.join(format!("cgc-desktop{suffix}")));
        let cache_root = env_path("CGC_CACHE_DIR")
            .unwrap_or_else(|| cache_base.join(format!("cgc-desktop{suffix}")));
        Self {
            environment,
            data_root,
            cache_root,
        }
    }

    pub fn keychain_service(&self) -> &'static str {
        self.environment.keychain_service()
    }

    pub fn session_file(&self) -> PathBuf {
        self.data_root.join("session.json")
    }

    pub fn chat_state_file(&self) -> PathBuf {
        self.data_root.join("chat_state.json")
    }

    pub fn workspace_state_file(&self) -> PathBuf {
        self.data_root.join("workspace_state.json")
    }

    pub fn theme_state_file(&self) -> PathBuf {
        self.data_root.join("theme.txt")
    }

    /// native agent 动作审计（JSONL）。
    pub fn agent_audit_file(&self) -> PathBuf {
        self.data_root.join("agent").join("actions.jsonl")
    }

    /// native agent 的本地偏好（当前是模型选择）。
    pub fn agent_prefs_file(&self) -> PathBuf {
        self.data_root.join("agent_prefs.json")
    }

    /// 用户可编辑的桌面端设置文件（对齐 Zed settings.json 的定位）。
    ///
    /// 按平台放在用户配置目录，`CGC_SETTINGS_FILE` 可整体覆盖（测试/QA）：
    /// - macOS：`~/.cgc2046/settings.json`
    /// - Linux：`$XDG_CONFIG_HOME/cgc2046/settings.json`（默认 `~/.config/cgc2046/settings.json`）
    /// - Windows：`%APPDATA%\\cgc2046\\settings.json`
    pub fn user_settings_file() -> PathBuf {
        Self::resolve_user_settings_file(current_config_platform(), |key| {
            std::env::var_os(key).map(PathBuf::from)
        })
    }

    /// 可注入平台与 env 读取器（测试用），不直接改进程环境。
    pub fn resolve_user_settings_file(
        platform: ConfigPlatform,
        env: impl Fn(&str) -> Option<PathBuf>,
    ) -> PathBuf {
        if let Some(path) = env("CGC_SETTINGS_FILE") {
            return path;
        }
        let home = env("HOME")
            .or_else(|| env("USERPROFILE"))
            .unwrap_or_else(std::env::temp_dir);
        let config_dir = match platform {
            ConfigPlatform::MacOs => home.join(".cgc2046"),
            ConfigPlatform::Linux => env("XDG_CONFIG_HOME")
                .unwrap_or_else(|| home.join(".config"))
                .join("cgc2046"),
            ConfigPlatform::Windows => env("APPDATA")
                .unwrap_or_else(|| home.join("AppData").join("Roaming"))
                .join("cgc2046"),
        };
        config_dir.join("settings.json")
    }

    pub fn notification_state_file(&self) -> PathBuf {
        self.data_root.join("notifications.json")
    }

    pub fn node_runtime_root(&self) -> PathBuf {
        self.data_root.join("node24")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn paths(env: &str) -> AppPaths {
        let mut values = HashMap::new();
        values.insert("HOME".to_string(), PathBuf::from("/home/student"));
        if cfg!(target_os = "macos") {
            values.insert("HOME".to_string(), PathBuf::from("/Users/student"));
        }
        AppPaths::resolve(Some(env), move |key| values.get(key).cloned())
    }

    #[test]
    fn environments_have_distinct_roots_and_services() {
        let dev = paths("dev");
        let staging = paths("staging");
        let prod = paths("prod");
        assert_ne!(dev.data_root, staging.data_root);
        assert_ne!(staging.data_root, prod.data_root);
        assert_ne!(dev.keychain_service(), staging.keychain_service());
        assert_ne!(staging.keychain_service(), prod.keychain_service());
        assert_eq!(prod.keychain_service(), "cgc-desktop");
        assert!(dev.data_root.to_string_lossy().contains("dev"));
        assert!(staging.data_root.to_string_lossy().contains("staging"));
        assert!(!prod.data_root.to_string_lossy().contains("staging"));
    }

    #[test]
    fn unknown_or_missing_env_defaults_to_dev() {
        assert_eq!(paths("nonsense").environment, AppEnvironment::Dev);
        assert_eq!(
            AppPaths::resolve(None, |_| None).environment,
            AppEnvironment::Dev
        );
    }

    #[test]
    fn user_settings_file_uses_zed_style_per_os_config_dir() {
        let mut values = HashMap::new();
        values.insert("HOME".to_string(), PathBuf::from("/home/student"));
        let env = |key: &str| values.get(key).cloned();
        assert_eq!(
            AppPaths::resolve_user_settings_file(ConfigPlatform::MacOs, env),
            PathBuf::from("/home/student/.cgc2046/settings.json")
        );
        assert_eq!(
            AppPaths::resolve_user_settings_file(ConfigPlatform::Linux, env),
            PathBuf::from("/home/student/.config/cgc2046/settings.json")
        );

        let mut values = HashMap::new();
        values.insert("HOME".to_string(), PathBuf::from("/home/student"));
        values.insert(
            "XDG_CONFIG_HOME".to_string(),
            PathBuf::from("/home/student/.config-custom"),
        );
        let env = |key: &str| values.get(key).cloned();
        assert_eq!(
            AppPaths::resolve_user_settings_file(ConfigPlatform::Linux, env),
            PathBuf::from("/home/student/.config-custom/cgc2046/settings.json")
        );

        let mut values = HashMap::new();
        values.insert(
            "APPDATA".to_string(),
            PathBuf::from(r"C:\Users\student\AppData\Roaming"),
        );
        let env = |key: &str| values.get(key).cloned();
        assert_eq!(
            AppPaths::resolve_user_settings_file(ConfigPlatform::Windows, env),
            PathBuf::from(r"C:\Users\student\AppData\Roaming").join("cgc2046/settings.json")
        );

        let mut values = HashMap::new();
        values.insert(
            "CGC_SETTINGS_FILE".to_string(),
            PathBuf::from("/tmp/custom/settings.json"),
        );
        let env = |key: &str| values.get(key).cloned();
        for platform in [
            ConfigPlatform::MacOs,
            ConfigPlatform::Linux,
            ConfigPlatform::Windows,
        ] {
            assert_eq!(
                AppPaths::resolve_user_settings_file(platform, env),
                PathBuf::from("/tmp/custom/settings.json")
            );
        }
    }

    #[test]
    fn explicit_overrides_win() {
        let mut values = HashMap::new();
        values.insert(
            "CGC_DATA_DIR".to_string(),
            PathBuf::from("/tmp/custom-data"),
        );
        values.insert(
            "CGC_CACHE_DIR".to_string(),
            PathBuf::from("/tmp/custom-cache"),
        );
        let paths = AppPaths::resolve(Some("prod"), move |key| values.get(key).cloned());
        assert_eq!(paths.data_root, PathBuf::from("/tmp/custom-data"));
        assert_eq!(paths.cache_root, PathBuf::from("/tmp/custom-cache"));
        assert_eq!(
            paths.chat_state_file(),
            PathBuf::from("/tmp/custom-data/chat_state.json")
        );
    }
}
