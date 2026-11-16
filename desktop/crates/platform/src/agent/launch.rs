//! agent 启动计划（story 5.4）：按内置清单把条目翻译成可执行命令与环境白名单。
//!
//! - OMP：直接使用本机 `omp acp`（BYO 安装）。
//! - Codex / Claude Code：用托管 Node 直接执行持久安装的固定版本 npm 包入口。
//! - 托管 Node 的目录同时放入 PATH，覆盖 agent 派生的 shebang 子进程。
//! - 环境变量白名单：保留 PATH/HOME/临时目录/语言、标准 HTTP 代理与 npm 缓存，不携带 API 密钥。

use std::collections::BTreeMap;
use std::fmt;
use std::path::{Path, PathBuf};

use crate::registry::manifest::{AgentEntry, Distribution};

/// 允许从父进程继承的环境变量（最小集；不含 API token/密钥类变量）。
pub const ALLOWED_ENV: &[&str] = &[
    "PATH",
    "HOME",
    "USERPROFILE",
    "SYSTEMROOT",
    "TMPDIR",
    "TMP",
    "TEMP",
    "LANG",
    "LC_ALL",
    "LC_CTYPE",
    "TERM",
    "COLORTERM",
    "APPDATA",
    "LOCALAPPDATA",
    "XDG_CONFIG_HOME",
    "XDG_CACHE_HOME",
    "HTTP_PROXY",
    "HTTPS_PROXY",
    "NO_PROXY",
    "http_proxy",
    "https_proxy",
    "no_proxy",
];

#[derive(Clone, PartialEq, Eq)]
pub struct LaunchPlan {
    pub program: PathBuf,
    pub args: Vec<String>,
    pub env: BTreeMap<String, String>,
    pub cwd: PathBuf,
}

impl fmt::Debug for LaunchPlan {
    /// 启动计划可能携带 keychain 注入的 API Key（DSH adapter 的 DEEPSEEK_API_KEY），
    /// Debug 只打印变量名，绝不打印值。
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("LaunchPlan")
            .field("program", &self.program)
            .field("args", &self.args)
            .field("env_keys", &self.env.keys().collect::<Vec<_>>())
            .field("cwd", &self.cwd)
            .finish()
    }
}

/// 单次 agent 启动的可选覆盖项（ADR-0031 D2/D3）：
/// - `dsh_path`：传给 `dsh-acp --dsh-path` 的外部路径，或字面量 `bundled`；
/// - `dsh_home`：隔离的 `DSH_HOME`，仅对 `requires: ["dsh-runtime"]` 的条目生效；
/// - `extra_env`：显式注入的子进程环境（来自 keychain，禁止日志/Debug 输出值）。
#[derive(Clone, Default, PartialEq, Eq)]
pub struct LaunchOptions {
    pub dsh_path: Option<String>,
    pub dsh_home: Option<PathBuf>,
    /// DSH plugin 形态：`dsh --profile acp` 的 CLI 路径（ADR-0031 D1 修订）。
    /// 设置后忽略 `dsh_path`，启动的是用户 DSH profile 里的 adapter 插件。
    pub dsh_plugin: Option<PathBuf>,
    pub extra_env: BTreeMap<String, String>,
}

impl fmt::Debug for LaunchOptions {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("LaunchOptions")
            .field("dsh_path", &self.dsh_path)
            .field("dsh_home", &self.dsh_home)
            .field("dsh_plugin", &self.dsh_plugin)
            .field("extra_env_keys", &self.extra_env.keys().collect::<Vec<_>>())
            .finish()
    }
}

impl LaunchPlan {
    /// 供 `AcpAgent::from_str` 使用的命令串（含空格的路径/参数加引号，`shell_words` 可解析）。
    pub fn command_string(&self) -> String {
        let mut command = quote_part(&self.program.to_string_lossy());
        for arg in &self.args {
            command.push(' ');
            command.push_str(&quote_part(arg));
        }
        command
    }
}

/// `shell_words` 兼容的引号：含空格/引号/反斜杠时用双引号包裹并转义。
fn quote_part(part: &str) -> String {
    if part.contains([' ', '"', '\'', '\\']) {
        format!("\"{}\"", part.replace('\\', "\\\\").replace('"', "\\\""))
    } else {
        part.to_string()
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum LaunchError {
    NodeRuntimeMissing { expected: PathBuf },
    AgentPackageMissing(String),
    InvalidEnvironment(String),
}

impl std::fmt::Display for LaunchError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            LaunchError::NodeRuntimeMissing { expected } => {
                write!(
                    formatter,
                    "managed node runtime missing: {}",
                    expected.display()
                )
            }
            LaunchError::AgentPackageMissing(message) => formatter.write_str(message),
            LaunchError::InvalidEnvironment(message) => formatter.write_str(message),
        }
    }
}

impl std::error::Error for LaunchError {}

/// 客户端管理的 Node runtime 根目录。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NodeRuntime {
    pub root: PathBuf,
}

impl NodeRuntime {
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    pub fn bin_dir(&self) -> PathBuf {
        if cfg!(windows) {
            self.root.clone()
        } else {
            self.root.join("bin")
        }
    }

    pub fn node(&self) -> PathBuf {
        self.bin_dir()
            .join(if cfg!(windows) { "node.exe" } else { "node" })
    }

    pub fn npm_cli_js(&self) -> PathBuf {
        self.root.join(if cfg!(windows) {
            "node_modules/npm/bin/npm-cli.js"
        } else {
            "lib/node_modules/npm/bin/npm-cli.js"
        })
    }

    pub fn exists(&self) -> bool {
        self.node().is_file() && self.npm_cli_js().is_file()
    }

    pub fn version(&self) -> Option<String> {
        if !self.exists() {
            return None;
        }
        let plan = LaunchPlan {
            program: self.node(),
            args: vec!["--version".to_string()],
            env: self.environment(|key| std::env::var(key).ok()).ok()?,
            cwd: self.root.clone(),
        };
        let output = super::command::run_output(&plan, std::time::Duration::from_secs(5)).ok()?;
        super::detect::parse_version(&output)
    }

    pub fn is_ready(&self) -> bool {
        self.version().is_some_and(|version| {
            super::detect::version_at_least(&version, super::node_runtime::NODE_VERSION)
        })
    }

    pub fn environment(
        &self,
        env_source: impl Fn(&str) -> Option<String>,
    ) -> Result<BTreeMap<String, String>, LaunchError> {
        let mut env = inherited_environment(env_source);
        let inherited_path = env.remove("PATH").unwrap_or_default();
        let path = std::env::join_paths(
            std::iter::once(self.bin_dir()).chain(std::env::split_paths(&inherited_path)),
        )
        .map_err(|error| LaunchError::InvalidEnvironment(error.to_string()))?;
        env.insert("PATH".to_string(), path.to_string_lossy().into_owned());
        for (key, relative) in [
            ("NPM_CONFIG_USERCONFIG", "npm-user.conf"),
            ("NPM_CONFIG_GLOBALCONFIG", "npm-global.conf"),
            ("NPM_CONFIG_CACHE", "npm-cache"),
        ] {
            env.insert(
                key.to_string(),
                self.root.join(relative).to_string_lossy().into_owned(),
            );
        }
        env.insert(
            "NPM_CONFIG_UPDATE_NOTIFIER".to_string(),
            "false".to_string(),
        );
        env.insert("NPM_CONFIG_FUND".to_string(), "false".to_string());
        env.insert("NPM_CONFIG_AUDIT".to_string(), "false".to_string());
        Ok(env)
    }
}

pub(crate) fn inherited_environment(
    env_source: impl Fn(&str) -> Option<String>,
) -> BTreeMap<String, String> {
    let mut env = BTreeMap::new();
    for key in ALLOWED_ENV {
        if let Some(value) = env_source(key) {
            env.insert((*key).to_string(), value);
        }
    }
    env.insert("NO_COLOR".to_string(), "1".to_string());
    env
}

pub fn build_launch(
    entry: &AgentEntry,
    node: Option<&NodeRuntime>,
    cwd: &Path,
) -> Result<LaunchPlan, LaunchError> {
    build_launch_with_options(entry, node, cwd, &LaunchOptions::default())
}

/// 带显式启动覆盖项（DSH 路径 / DSH_HOME / keychain env）的生产入口。
pub fn build_launch_with_options(
    entry: &AgentEntry,
    node: Option<&NodeRuntime>,
    cwd: &Path,
    options: &LaunchOptions,
) -> Result<LaunchPlan, LaunchError> {
    build_launch_with_env_and_options(entry, node, cwd, options, |key| std::env::var(key).ok())
}

/// 可注入的 env 读取器：测试用闭包，生产用 `std::env::var`。
pub fn build_launch_with_env(
    entry: &AgentEntry,
    node: Option<&NodeRuntime>,
    cwd: &Path,
    env_source: impl Fn(&str) -> Option<String>,
) -> Result<LaunchPlan, LaunchError> {
    build_launch_with_env_and_options(entry, node, cwd, &LaunchOptions::default(), env_source)
}

pub fn build_launch_with_env_and_options(
    entry: &AgentEntry,
    node: Option<&NodeRuntime>,
    cwd: &Path,
    options: &LaunchOptions,
    env_source: impl Fn(&str) -> Option<String>,
) -> Result<LaunchPlan, LaunchError> {
    match &entry.distribution {
        Distribution::Native { command } => {
            let mut env = inherited_environment(env_source);
            let mut args = Vec::new();
            apply_launch_options(entry, options, &mut args, &mut env)?;
            args.extend(entry.launch_args.clone());
            Ok(LaunchPlan {
                program: PathBuf::from(command),
                args,
                env,
                cwd: cwd.to_path_buf(),
            })
        }
        Distribution::Npx { .. } => {
            // ADR-0031 D1 修订：有 DSH Desktop 时优先 plugin 形态，adapter 由
            // `dsh --profile acp` 加载，直接复用用户 profile 的 providers。
            if let Some(dsh) = &options.dsh_plugin {
                let mut env = inherited_environment(env_source);
                let mut args = vec![
                    "--profile".to_string(),
                    crate::agent::dsh_plugin::DSH_PLUGIN_PROFILE.to_string(),
                ];
                apply_plugin_options(options, &mut env)?;
                args.extend(entry.launch_args.clone());
                return Ok(LaunchPlan {
                    program: dsh.clone(),
                    args,
                    env,
                    cwd: cwd.to_path_buf(),
                });
            }
            let runtime = node.ok_or_else(|| LaunchError::NodeRuntimeMissing {
                expected: PathBuf::from("<managed node runtime>"),
            })?;
            if !runtime.is_ready() {
                return Err(LaunchError::NodeRuntimeMissing {
                    expected: runtime.root.clone(),
                });
            }
            let executable = crate::registry::package::executable(entry, runtime)
                .map_err(LaunchError::AgentPackageMissing)?;
            let mut env = runtime.environment(env_source)?;
            let mut args = vec![executable.to_string_lossy().into_owned()];
            apply_launch_options(entry, options, &mut args, &mut env)?;
            args.extend(entry.launch_args.clone());
            Ok(LaunchPlan {
                program: runtime.node(),
                args,
                env,
                cwd: cwd.to_path_buf(),
            })
        }
    }
}

fn apply_plugin_options(
    options: &LaunchOptions,
    env: &mut BTreeMap<String, String>,
) -> Result<(), LaunchError> {
    if let Some(dsh_home) = &options.dsh_home {
        if dsh_home.as_os_str().is_empty() {
            return Err(LaunchError::InvalidEnvironment(
                "DSH_HOME must not be empty".to_string(),
            ));
        }
        env.insert(
            "DSH_HOME".to_string(),
            dsh_home.to_string_lossy().into_owned(),
        );
    }
    for (key, value) in &options.extra_env {
        if key.trim().is_empty() {
            return Err(LaunchError::InvalidEnvironment(
                "environment variable name must not be empty".to_string(),
            ));
        }
        env.insert(key.clone(), value.clone());
    }
    Ok(())
}

fn apply_launch_options(
    entry: &AgentEntry,
    options: &LaunchOptions,
    args: &mut Vec<String>,
    env: &mut BTreeMap<String, String>,
) -> Result<(), LaunchError> {
    if entry.uses_dsh_runtime() {
        if let Some(dsh_path) = &options.dsh_path {
            if dsh_path.trim().is_empty() {
                return Err(LaunchError::InvalidEnvironment(
                    "dsh path must not be empty".to_string(),
                ));
            }
            args.push("--dsh-path".to_string());
            args.push(dsh_path.clone());
        }
        if let Some(dsh_home) = &options.dsh_home {
            if dsh_home.as_os_str().is_empty() {
                return Err(LaunchError::InvalidEnvironment(
                    "DSH_HOME must not be empty".to_string(),
                ));
            }
            env.insert(
                "DSH_HOME".to_string(),
                dsh_home.to_string_lossy().into_owned(),
            );
        }
    }
    for (key, value) in &options.extra_env {
        if key.trim().is_empty() {
            return Err(LaunchError::InvalidEnvironment(
                "environment variable name must not be empty".to_string(),
            ));
        }
        env.insert(key.clone(), value.clone());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::registry::manifest::Registry;

    fn entry(id: &str) -> AgentEntry {
        Registry::builtin()
            .expect("registry")
            .get(id)
            .expect("entry")
            .clone()
    }

    #[test]
    fn plugin_plan_uses_dsh_profile_without_dsh_path() {
        let options = LaunchOptions {
            dsh_path: Some("bundled".to_string()),
            dsh_home: Some(PathBuf::from("/Users/example/.dsh")),
            dsh_plugin: Some(PathBuf::from("/Users/example/.local/bin/dsh")),
            extra_env: BTreeMap::new(),
        };
        let plan = build_launch_with_options(&entry("deepseek"), None, Path::new("/tmp"), &options)
            .expect("plugin plan");
        assert_eq!(plan.program, PathBuf::from("/Users/example/.local/bin/dsh"));
        assert_eq!(plan.args, vec!["--profile".to_string(), "acp".to_string()]);
        assert_eq!(
            plan.env.get("DSH_HOME"),
            Some(&"/Users/example/.dsh".to_string())
        );
        assert!(
            !plan.args.iter().any(|arg| arg == "--dsh-path"),
            "plugin form must not pass --dsh-path"
        );
    }

    #[test]
    fn native_plan_uses_omp_acp() {
        let plan = build_launch(&entry("omp"), None, Path::new("/tmp")).expect("plan");
        assert_eq!(plan.program, PathBuf::from("omp"));
        assert_eq!(plan.args, vec!["acp".to_string()]);
        assert_eq!(plan.command_string(), "omp acp");
    }

    #[test]
    fn env_allowlist_excludes_secrets() {
        let plan = build_launch_with_env(&entry("omp"), None, Path::new("/tmp"), |key| match key {
            "PATH" => Some("/usr/bin".to_string()),
            "HOME" => Some("/Users/example".to_string()),
            "CGC_SESSION_TOKEN" => Some("jwt.secret".to_string()),
            "OPENAI_API_KEY" => Some("sk-secret".to_string()),
            _ => None,
        })
        .expect("plan");
        assert_eq!(plan.env.get("PATH").map(String::as_str), Some("/usr/bin"));
        assert!(plan.env.contains_key("HOME"));
        assert!(!plan.env.contains_key("CGC_SESSION_TOKEN"));
        assert!(!plan.env.contains_key("OPENAI_API_KEY"));
        assert!(!plan.env.values().any(|value| value.contains("secret")));
    }

    #[test]
    fn npx_plan_requires_managed_runtime() {
        let error = build_launch(&entry("codex"), None, Path::new("/tmp")).unwrap_err();
        assert!(matches!(error, LaunchError::NodeRuntimeMissing { .. }));
    }

    #[test]
    fn command_string_quotes_paths_with_spaces() {
        // macOS 的托管 runtime 落在 `~/Library/Application Support/...`，路径含空格；
        // AcpHost 用 shell_words 解析命令串，参数不加引号会被拆坏。
        let plan = LaunchPlan {
            program: PathBuf::from("/Applications/CGC App/node"),
            args: vec![
                "/Users/a/Library/Application Support/cgc-desktop/node24/lib/node_modules/npm/bin/npx-cli.js"
                    .to_string(),
                "--yes".to_string(),
                "pkg@1.0.0".to_string(),
            ],
            env: BTreeMap::new(),
            cwd: PathBuf::from("/tmp"),
        };
        assert_eq!(
            plan.command_string(),
            "\"/Applications/CGC App/node\" \"/Users/a/Library/Application Support/cgc-desktop/node24/lib/node_modules/npm/bin/npx-cli.js\" --yes pkg@1.0.0"
        );
    }

    #[test]
    fn native_plan_requires_managed_runtime_only_for_npx() {
        let plan = build_launch_with_env(&entry("omp"), None, Path::new("/tmp"), |key| {
            (key == "PATH").then(|| "/bin".to_string())
        })
        .expect("native works without node");
        assert!(!plan.env.contains_key("OPENAI_API_KEY"));
    }

    #[test]
    fn dsh_launch_options_add_path_home_and_keychain_env() {
        let dsh = entry("deepseek");
        let mut args = vec!["/pkg/dist/bin.js".to_string()];
        let mut env = BTreeMap::new();
        let options = LaunchOptions {
            // 决策 A：不把 DSH Desktop 的 wrapper 传给 --dsh-path，统一 bundled。
            dsh_path: Some("bundled".to_string()),
            dsh_home: Some(PathBuf::from("/data/dsh-home")),
            dsh_plugin: None,
            extra_env: BTreeMap::from([
                ("DEEPSEEK_API_KEY".to_string(), "sk-secret".to_string()),
                (
                    "DEEPSEEK_BASE_URL".to_string(),
                    "https://api.deepseek.com".to_string(),
                ),
            ]),
        };
        apply_launch_options(&dsh, &options, &mut args, &mut env).expect("options");
        assert_eq!(args, vec!["/pkg/dist/bin.js", "--dsh-path", "bundled"]);
        assert_eq!(
            env.get("DSH_HOME").map(String::as_str),
            Some("/data/dsh-home")
        );
        assert_eq!(
            env.get("DEEPSEEK_API_KEY").map(String::as_str),
            Some("sk-secret")
        );

        // Debug 只暴露变量名，不能泄漏 key 值。
        let debug = format!("{:?}", options);
        assert!(!debug.contains("sk-secret"));
        assert!(debug.contains("DEEPSEEK_API_KEY"));
    }

    #[test]
    fn dsh_launch_options_are_ignored_by_non_dsh_agents() {
        let omp = entry("omp");
        let mut args = Vec::new();
        let mut env = BTreeMap::new();
        let options = LaunchOptions {
            dsh_path: Some("/opt/dsh".to_string()),
            dsh_home: Some(PathBuf::from("/data/dsh-home")),
            dsh_plugin: None,
            extra_env: BTreeMap::from([("DEEPSEEK_API_KEY".to_string(), "sk".to_string())]),
        };
        apply_launch_options(&omp, &options, &mut args, &mut env).expect("options");
        assert!(args.is_empty());
        assert!(!env.contains_key("DSH_HOME"));
        assert_eq!(env.get("DEEPSEEK_API_KEY").map(String::as_str), Some("sk"));
    }

    #[test]
    fn launch_plan_debug_redacts_environment_values() {
        let plan = LaunchPlan {
            program: PathBuf::from("node"),
            args: vec!["bin.js".to_string()],
            env: BTreeMap::from([("DEEPSEEK_API_KEY".to_string(), "sk-secret".to_string())]),
            cwd: PathBuf::from("/tmp"),
        };
        let debug = format!("{plan:?}");
        assert!(!debug.contains("sk-secret"));
        assert!(debug.contains("DEEPSEEK_API_KEY"));
    }
}
