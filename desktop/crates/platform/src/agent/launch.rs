//! agent 启动计划（story 5.4）：按内置清单把条目翻译成可执行命令与环境白名单。
//!
//! - OMP：直接使用本机 `omp acp`（BYO 安装）。
//! - Codex / Claude Code：用托管 Node 直接执行持久安装的固定版本 npm 包入口。
//! - 托管 Node 的目录同时放入 PATH，覆盖 agent 派生的 shebang 子进程。
//! - 环境变量白名单：保留 PATH/HOME/临时目录/语言、标准 HTTP 代理与 npm 缓存，不携带 API 密钥。

use std::collections::BTreeMap;
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

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LaunchPlan {
    pub program: PathBuf,
    pub args: Vec<String>,
    pub env: BTreeMap<String, String>,
    pub cwd: PathBuf,
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
    build_launch_with_env(entry, node, cwd, |key| std::env::var(key).ok())
}

/// 可注入的 env 读取器：测试用闭包，生产用 `std::env::var`。
pub fn build_launch_with_env(
    entry: &AgentEntry,
    node: Option<&NodeRuntime>,
    cwd: &Path,
    env_source: impl Fn(&str) -> Option<String>,
) -> Result<LaunchPlan, LaunchError> {
    match &entry.distribution {
        Distribution::Native { command } => Ok(LaunchPlan {
            program: PathBuf::from(command),
            args: entry.launch_args.clone(),
            env: inherited_environment(env_source),
            cwd: cwd.to_path_buf(),
        }),
        Distribution::Npx { .. } => {
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
            let mut args = vec![executable.to_string_lossy().into_owned()];
            args.extend(entry.launch_args.clone());
            Ok(LaunchPlan {
                program: runtime.node(),
                args,
                env: runtime.environment(env_source)?,
                cwd: cwd.to_path_buf(),
            })
        }
    }
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
}
