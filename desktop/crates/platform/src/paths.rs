//! 环境数据根与 keychain service 隔离（story 1.9）。
//!
//! dev / staging / prod 使用不同的数据根、缓存根与 keychain service，避免误读写
//! 生产凭证与数据；`CGC_ENV` 显式指定，`CGC_DATA_DIR`/`CGC_CACHE_DIR` 可覆盖。
//!
//! 默认（未指定）为 dev；发布构建可用编译期 `CGC_DEFAULT_ENV=prod` 把默认值编进二进制
//! （见 `runtime::build_default_environment`）——用户双击 `.app` 启动时拿不到 shell
//! 环境变量，只能靠这条路径进生产数据根。

use std::path::{Path, PathBuf};

fn non_empty_env_path(env: &impl Fn(&str) -> Option<PathBuf>, key: &str) -> Option<PathBuf> {
    env(key).filter(|value| !value.as_os_str().is_empty())
}

/// 按跨平台优先级解析用户 home 目录：`HOME` → `USERPROFILE` → `HOMEDRIVE`+`HOMEPATH`。
///
/// 过滤空串 `""`，避免空的 `HOME=""` 遮蔽 Windows 的 `USERPROFILE` / `HOMEDRIVE`+`HOMEPATH`。
pub fn home_dir_from(env: impl Fn(&str) -> Option<PathBuf>) -> Option<PathBuf> {
    if let Some(home) = non_empty_env_path(&env, "HOME") {
        return Some(home);
    }
    if let Some(profile) = non_empty_env_path(&env, "USERPROFILE") {
        return Some(profile);
    }
    if let (Some(drive), Some(path)) = (
        non_empty_env_path(&env, "HOMEDRIVE"),
        non_empty_env_path(&env, "HOMEPATH"),
    ) {
        let mut combined = drive.into_os_string();
        combined.push(path);
        return Some(PathBuf::from(combined));
    }
    None
}

/// 读取当前进程环境变量解析用户 home 目录。
pub fn home_dir() -> Option<PathBuf> {
    home_dir_from(|key| std::env::var_os(key).map(PathBuf::from))
}

/// 剥离 Windows `canonicalize()` 产出的常规盘符 verbatim 前缀（`\\?\X:\...` / `\\?\X:/...` / `\\?\X:`）。
///
/// 显式排除 `\\?\UNC\...` 等非盘符 verbatim 路径，其余路径原样返回；
/// 用于避免 `cmd.exe` 等工具拒绝 `\\?\` 前缀而退回 `C:\Windows`。
pub fn strip_windows_verbatim(path: &Path) -> PathBuf {
    let Some(raw) = path.to_str() else {
        return path.to_path_buf();
    };
    let Some(rest) = raw.strip_prefix(r"\\?\") else {
        return path.to_path_buf();
    };
    let bytes = rest.as_bytes();
    let is_drive = bytes.len() >= 2
        && bytes[0].is_ascii_alphabetic()
        && bytes[1] == b':'
        && (bytes.len() == 2 || matches!(bytes[2], b'\\' | b'/'));
    if is_drive {
        PathBuf::from(rest)
    } else {
        path.to_path_buf()
    }
}

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
        let resolved_home = home_dir_from(&env_path);
        let home = resolved_home.clone().unwrap_or_else(std::env::temp_dir);
        let data_base = if cfg!(target_os = "macos") {
            resolved_home
                .as_ref()
                .map(|home| home.join("Library/Application Support"))
                .unwrap_or_else(std::env::temp_dir)
        } else if cfg!(target_os = "windows") {
            env_path("APPDATA").unwrap_or_else(std::env::temp_dir)
        } else {
            env_path("XDG_DATA_HOME").unwrap_or_else(|| home.join(".local/share"))
        };
        let cache_base = if cfg!(target_os = "macos") {
            resolved_home
                .as_ref()
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
        let home = home_dir_from(&env).unwrap_or_else(std::env::temp_dir);
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

    /// DSH ACP 外部 agent 的隔离会话根（ADR-0031 D3）：不复用用户自己的 `~/.dsh`。
    pub fn dsh_home_root(&self) -> PathBuf {
        self.data_root.join("dsh-home")
    }
}

/// 本地 DSH 数据目录（ADR-0031 D3 opt-in 共享）：`DSH_HOME` > `<home>/.dsh`。
///
/// `<home>` 通过 [`home_dir_from`] 按 `HOME` → `USERPROFILE` → `HOMEDRIVE`+`HOMEPATH` 解析；
/// 返回 `None` 表示无法确定用户目录，调用方必须回退到隔离目录，
/// 绝不能把空路径当作共享目录传给子进程。
pub fn local_dsh_home(env: impl Fn(&str) -> Option<PathBuf>) -> Option<PathBuf> {
    if let Some(path) = env("DSH_HOME").filter(|path| !path.as_os_str().is_empty()) {
        return Some(path);
    }
    home_dir_from(&env).map(|home| home.join(".dsh"))
}

pub fn local_dsh_home_from_env() -> Option<PathBuf> {
    local_dsh_home(|key| std::env::var_os(key).map(PathBuf::from))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn paths(env: &str) -> AppPaths {
        let mut values = HashMap::new();
        values.insert("HOME".to_string(), PathBuf::from("/home/example"));
        if cfg!(target_os = "macos") {
            values.insert("HOME".to_string(), PathBuf::from("/Users/example"));
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
        assert_eq!(dev.dsh_home_root(), dev.data_root.join("dsh-home"));
        assert_ne!(dev.dsh_home_root(), dev.data_root);
    }

    #[test]
    fn local_dsh_home_prefers_explicit_dsh_home_then_user_home() {
        fn read(values: &HashMap<String, PathBuf>, key: &str) -> Option<PathBuf> {
            values.get(key).cloned()
        }
        let mut values = HashMap::new();
        values.insert("HOME".to_string(), PathBuf::from("/Users/example"));
        values.insert("DSH_HOME".to_string(), PathBuf::from("/data/custom-dsh"));
        assert_eq!(
            local_dsh_home(|key| read(&values, key)),
            Some(PathBuf::from("/data/custom-dsh"))
        );

        values.remove("DSH_HOME");
        assert_eq!(
            local_dsh_home(|key| read(&values, key)),
            Some(PathBuf::from("/Users/example/.dsh"))
        );

        // 空 DSH_HOME 不能当作有效共享目录。
        values.insert("DSH_HOME".to_string(), PathBuf::new());
        assert_eq!(
            local_dsh_home(|key| read(&values, key)),
            Some(PathBuf::from("/Users/example/.dsh"))
        );

        values.clear();
        assert_eq!(local_dsh_home(|key| read(&values, key)), None);
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
        values.insert("HOME".to_string(), PathBuf::from("/home/example"));
        let env = |key: &str| values.get(key).cloned();
        assert_eq!(
            AppPaths::resolve_user_settings_file(ConfigPlatform::MacOs, env),
            PathBuf::from("/home/example/.cgc2046/settings.json")
        );
        assert_eq!(
            AppPaths::resolve_user_settings_file(ConfigPlatform::Linux, env),
            PathBuf::from("/home/example/.config/cgc2046/settings.json")
        );

        let mut values = HashMap::new();
        values.insert("HOME".to_string(), PathBuf::from("/home/example"));
        values.insert(
            "XDG_CONFIG_HOME".to_string(),
            PathBuf::from("/home/example/.config-custom"),
        );
        let env = |key: &str| values.get(key).cloned();
        assert_eq!(
            AppPaths::resolve_user_settings_file(ConfigPlatform::Linux, env),
            PathBuf::from("/home/example/.config-custom/cgc2046/settings.json")
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

    #[test]
    fn home_dir_from_resolves_windows_vars_and_skips_empty_values() {
        let mut values = HashMap::new();
        values.insert("HOME".to_string(), PathBuf::new());
        values.insert("USERPROFILE".to_string(), PathBuf::from(r"C:\Users\alice"));
        values.insert("HOMEDRIVE".to_string(), PathBuf::from("D:"));
        values.insert("HOMEPATH".to_string(), PathBuf::from(r"\Users\fallback"));
        assert_eq!(
            home_dir_from(|key| values.get(key).cloned()),
            Some(PathBuf::from(r"C:\Users\alice")),
            "空 HOME 不能遮蔽 USERPROFILE"
        );

        values.insert("USERPROFILE".to_string(), PathBuf::new());
        assert_eq!(
            home_dir_from(|key| values.get(key).cloned()),
            Some(PathBuf::from(r"D:\Users\fallback")),
            "空 USERPROFILE 时回退到 HOMEDRIVE+HOMEPATH"
        );

        values.insert("HOMEPATH".to_string(), PathBuf::new());
        assert_eq!(home_dir_from(|key| values.get(key).cloned()), None);

        values.insert("HOME".to_string(), PathBuf::from("/home/alice"));
        assert_eq!(
            home_dir_from(|key| values.get(key).cloned()),
            Some(PathBuf::from("/home/alice")),
            "非空 HOME 优先级最高"
        );
    }

    #[test]
    fn local_dsh_home_supports_windows_userprofile_and_homedrive() {
        let mut values = HashMap::new();
        values.insert("HOME".to_string(), PathBuf::new());
        values.insert("USERPROFILE".to_string(), PathBuf::from(r"C:\Users\alice"));
        assert_eq!(
            local_dsh_home(|key| values.get(key).cloned()),
            Some(PathBuf::from(r"C:\Users\alice").join(".dsh"))
        );

        values.remove("USERPROFILE");
        values.insert("HOMEDRIVE".to_string(), PathBuf::from("C:"));
        values.insert("HOMEPATH".to_string(), PathBuf::from(r"\Users\bob"));
        assert_eq!(
            local_dsh_home(|key| values.get(key).cloned()),
            Some(PathBuf::from(r"C:\Users\bob").join(".dsh"))
        );
    }

    #[test]
    fn strip_windows_verbatim_strips_drive_paths_only() {
        assert_eq!(
            strip_windows_verbatim(Path::new(r"\\?\C:\Users\alice\repo")),
            PathBuf::from(r"C:\Users\alice\repo")
        );
        assert_eq!(
            strip_windows_verbatim(Path::new(r"\\?\D:/repo/sub")),
            PathBuf::from(r"D:/repo/sub")
        );
        assert_eq!(
            strip_windows_verbatim(Path::new(r"\\?\C:")),
            PathBuf::from("C:")
        );
        assert_eq!(
            strip_windows_verbatim(Path::new(r"\\?\UNC\server\share\dir")),
            PathBuf::from(r"\\?\UNC\server\share\dir")
        );
        assert_eq!(
            strip_windows_verbatim(Path::new(r"\\?\Volume{1234}\foo")),
            PathBuf::from(r"\\?\Volume{1234}\foo")
        );
        assert_eq!(
            strip_windows_verbatim(Path::new(r"C:\Users\alice")),
            PathBuf::from(r"C:\Users\alice")
        );
        assert_eq!(
            strip_windows_verbatim(Path::new("/tmp/workspace")),
            PathBuf::from("/tmp/workspace")
        );
    }
}
