//! agent 启动计划（story 5.4）：按内置清单把条目翻译成可执行命令与环境白名单。
//!
//! - OMP：直接使用本机 `omp acp`（BYO 安装）。
//! - Codex / Claude Code：使用客户端管理的 Node.js 24 runtime，由托管 node 直接执行
//!   npm 的 `npx-cli.js`（固定版本 `--yes <pkg>@<version>`）；不依赖用户 PATH 里的
//!   node/npm——npx 是 `#!/usr/bin/env node` 脚本，只选绝对路径仍会回落到 PATH。
//! - 环境变量白名单：清空后只注入 PATH/HOME/临时目录/语言与 npm 缓存，不携带凭证。

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use crate::registry::manifest::{AgentEntry, Distribution};

/// 允许从父进程继承的环境变量（最小集；不含 token/密钥类变量）。
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
    NpxMissing { expected: PathBuf },
    UnsupportedDistribution(String),
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
            LaunchError::NpxMissing { expected } => {
                write!(formatter, "managed npx missing: {}", expected.display())
            }
            LaunchError::UnsupportedDistribution(kind) => {
                write!(formatter, "unsupported distribution: {kind}")
            }
        }
    }
}

impl std::error::Error for LaunchError {}

/// 客户端管理的 Node runtime 根目录（包含 bin/node 与 bin/npx）。
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
            self.root.join("node_modules/.bin")
        } else {
            self.root.join("bin")
        }
    }

    pub fn node(&self) -> PathBuf {
        if cfg!(windows) {
            self.root.join("node.exe")
        } else {
            self.bin_dir().join("node")
        }
    }

    /// npm 的 npx 入口（JS）。npx 脚本本身是 `#!/usr/bin/env node`，必须由托管
    /// node 执行，否则会去 PATH 找 node——没有系统 Node 的机器上直接失败。
    pub fn npx_cli_js(&self) -> PathBuf {
        if cfg!(windows) {
            self.root.join("node_modules/npm/bin/npx-cli.js")
        } else {
            self.root.join("lib/node_modules/npm/bin/npx-cli.js")
        }
    }

    pub fn exists(&self) -> bool {
        self.node().is_file() && self.npx_cli_js().is_file()
    }
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
    let mut env = BTreeMap::new();
    for key in ALLOWED_ENV {
        if let Some(value) = env_source(key) {
            env.insert((*key).to_string(), value);
        }
    }
    // 隔离 npm 缓存/配置，避免写用户全局 npm 目录或读取用户 npmrc 凭证。
    env.insert(
        "NPM_CONFIG_UPDATE_NOTIFIER".to_string(),
        "false".to_string(),
    );
    env.insert("NPM_CONFIG_FUND".to_string(), "false".to_string());
    env.insert("NO_COLOR".to_string(), "1".to_string());

    match &entry.distribution {
        Distribution::Native { command } => Ok(LaunchPlan {
            program: PathBuf::from(command),
            args: entry.launch_args.clone(),
            env,
            cwd: cwd.to_path_buf(),
        }),
        Distribution::Npx {
            package, version, ..
        } => {
            let runtime = node.ok_or_else(|| LaunchError::NodeRuntimeMissing {
                expected: PathBuf::from("<managed node runtime>"),
            })?;
            if !runtime.exists() {
                return Err(LaunchError::NodeRuntimeMissing {
                    expected: runtime.root.clone(),
                });
            }
            let npx_cli = runtime.npx_cli_js();
            if !npx_cli.is_file() {
                return Err(LaunchError::NpxMissing {
                    expected: npx_cli.clone(),
                });
            }
            // 用托管 node 执行 npx-cli.js：npx 的 shebang 是 `#!/usr/bin/env node`，
            // 直接 spawn 绝对路径仍会去 PATH 找 node，无系统 Node 的机器上必挂。
            let mut args = vec![
                npx_cli.to_string_lossy().to_string(),
                "--yes".to_string(),
                format!("{package}@{version}"),
            ];
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
    fn npx_plan_uses_managed_node_and_pinned_package() {
        let dir = std::env::temp_dir().join(format!("cgc-node-{}", std::process::id()));
        let runtime = NodeRuntime::new(&dir);
        // 夹具按平台布局落文件：Unix 是 bin/node + lib/node_modules/npm/bin/npx-cli.js，
        // Windows 是 node.exe + node_modules/npm/bin/npx-cli.js。
        std::fs::create_dir_all(runtime.bin_dir()).expect("mkdir");
        std::fs::write(runtime.node(), b"#!/bin/sh\n").expect("node");
        std::fs::create_dir_all(runtime.npx_cli_js().parent().expect("parent")).expect("mkdir npx");
        std::fs::write(runtime.npx_cli_js(), b"#!/usr/bin/env node\n").expect("npx-cli");
        let plan = build_launch(&entry("codex"), Some(&runtime), Path::new("/tmp")).expect("plan");
        // 必须由托管 node 执行 npx-cli.js；直接 spawn npx 脚本会退回 PATH 找 node。
        assert_eq!(plan.program, runtime.node());
        assert_eq!(
            plan.args,
            vec![
                runtime.npx_cli_js().to_string_lossy().to_string(),
                "--yes".to_string(),
                "@agentclientprotocol/codex-acp@2.2.2".to_string()
            ]
        );
        assert_eq!(
            plan.env
                .get("NPM_CONFIG_UPDATE_NOTIFIER")
                .map(String::as_str),
            Some("false")
        );
        let _ = std::fs::remove_dir_all(&dir);
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
