//! 环境数据根与 keychain service 隔离（story 1.9）。
//!
//! dev / staging / prod 使用不同的数据根、缓存根与 keychain service，避免误读写
//! 生产凭证与数据；`CGC_ENV` 显式指定，`CGC_DATA_DIR`/`CGC_CACHE_DIR` 可覆盖。
//! 默认（未指定）为 dev，生产构建必须显式 `CGC_ENV=prod`。

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

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AppPaths {
    pub environment: AppEnvironment,
    pub data_root: PathBuf,
    pub cache_root: PathBuf,
}

impl AppPaths {
    pub fn from_env() -> Self {
        Self::resolve(std::env::var("CGC_ENV").ok().as_deref(), |key| {
            std::env::var_os(key).map(PathBuf::from)
        })
    }

    /// 可注入 env 读取器（测试用），不直接改进程环境。
    pub fn resolve(env_value: Option<&str>, env_path: impl Fn(&str) -> Option<PathBuf>) -> Self {
        let environment = env_value
            .and_then(AppEnvironment::parse)
            .unwrap_or(AppEnvironment::Dev);
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
