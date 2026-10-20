//! 安装到共享安装根、检测已安装（与 `cgc-host` 共存）、版本查询与卸载。
//!
//! v1 的安装动作是“把签名清单里的固定版本准备好”：
//! - npx 分发：用托管 Node 的 `npx --yes <pkg>@<version> --version` 预热/验证；
//! - native 分发：只检查命令是否已存在，不在客户端替用户安装系统工具。
//!
//! 真正的文件落盘/卸载留给后续版本；这里先保证签名清单是唯一入口。

use std::path::Path;
use std::process::Command;
use std::time::{Duration, Instant};

use crate::agent::launch::NodeRuntime;
use crate::registry::manifest::{AgentEntry, Distribution};

const INSTALL_TIMEOUT: Duration = Duration::from_secs(180);

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InstallResult {
    pub id: String,
    pub version: Option<String>,
    pub detail: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum InstallError {
    NodeRuntimeMissing,
    NodeRuntimeIncomplete,
    NativeInstallUnsupported { command: String },
    CommandFailed { program: String, message: String },
    Timeout { program: String },
}

impl std::fmt::Display for InstallError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            InstallError::NodeRuntimeMissing => {
                write!(formatter, "managed node runtime is not installed")
            }
            InstallError::NodeRuntimeIncomplete => {
                write!(formatter, "managed node runtime is incomplete")
            }
            InstallError::NativeInstallUnsupported { command } => write!(
                formatter,
                "native agent `{command}` must be installed by the user"
            ),
            InstallError::CommandFailed { program, message } => {
                write!(formatter, "{program} failed: {message}")
            }
            InstallError::Timeout { program } => write!(formatter, "{program} timed out"),
        }
    }
}

impl std::error::Error for InstallError {}

/// 命令执行 seam：生产用 [`SystemRunner`]，测试注入静态结果。
pub trait InstallRunner: Send + Sync {
    fn run(&self, program: &Path, args: &[&str]) -> Result<String, String>;
}

pub struct SystemRunner;

impl InstallRunner for SystemRunner {
    fn run(&self, program: &Path, args: &[&str]) -> Result<String, String> {
        let mut child = Command::new(program)
            .args(args)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .spawn()
            .map_err(|error| error.to_string())?;
        let started = Instant::now();
        loop {
            match child.try_wait() {
                Ok(Some(status)) => {
                    let output = child
                        .wait_with_output()
                        .map_err(|error| error.to_string())?;
                    let stdout = String::from_utf8_lossy(&output.stdout).to_string();
                    let stderr = String::from_utf8_lossy(&output.stderr).to_string();
                    if status.success() {
                        return Ok(format!("{stdout}{stderr}"));
                    }
                    return Err(format!("{stderr}{stdout}"));
                }
                Ok(None) if started.elapsed() < INSTALL_TIMEOUT => {
                    std::thread::sleep(Duration::from_millis(40));
                }
                Ok(None) => {
                    let _ = child.kill();
                    let _ = child.wait();
                    return Err("timeout".to_string());
                }
                Err(error) => return Err(error.to_string()),
            }
        }
    }
}

pub fn install_entry(
    entry: &AgentEntry,
    node: Option<&NodeRuntime>,
    runner: &dyn InstallRunner,
) -> Result<InstallResult, InstallError> {
    match &entry.distribution {
        Distribution::Native { command } => {
            let program = Path::new(command);
            match runner.run(program, &["--version"]) {
                Ok(_) => Ok(InstallResult {
                    id: entry.id.clone(),
                    version: None,
                    detail: format!("{command} is already installed"),
                }),
                Err(_) => Err(InstallError::NativeInstallUnsupported {
                    command: command.clone(),
                }),
            }
        }
        Distribution::Npx {
            package, version, ..
        } => {
            let node = node.ok_or(InstallError::NodeRuntimeMissing)?;
            if !node.exists() {
                return Err(InstallError::NodeRuntimeIncomplete);
            }
            let npx = node.npx();
            let spec = format!("{package}@{version}");
            runner
                .run(&npx, &["--yes", &spec, "--version"])
                .map_err(|message| InstallError::CommandFailed {
                    program: "npx".to_string(),
                    message,
                })?;
            Ok(InstallResult {
                id: entry.id.clone(),
                version: Some(version.clone()),
                detail: format!("{spec} is ready via managed npx"),
            })
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::registry::manifest::Registry;
    use std::sync::Mutex;

    #[derive(Default)]
    struct FakeRunner {
        calls: Mutex<Vec<(String, Vec<String>)>>,
        fail: bool,
    }

    impl InstallRunner for FakeRunner {
        fn run(&self, program: &Path, args: &[&str]) -> Result<String, String> {
            self.calls.lock().expect("calls").push((
                program.display().to_string(),
                args.iter().map(|arg| (*arg).to_string()).collect(),
            ));
            if self.fail {
                Err("boom".to_string())
            } else {
                Ok("ok".to_string())
            }
        }
    }

    fn entry(id: &str) -> AgentEntry {
        Registry::builtin()
            .expect("registry")
            .get(id)
            .expect("entry")
            .clone()
    }

    fn runtime() -> NodeRuntime {
        let root = std::env::temp_dir().join(format!("cgc-install-node-{}", std::process::id()));
        std::fs::create_dir_all(root.join("bin")).expect("mkdir");
        std::fs::write(root.join("bin/node"), b"#!/bin/sh\n").expect("node");
        std::fs::write(root.join("bin/npx"), b"#!/bin/sh\n").expect("npx");
        NodeRuntime::new(root)
    }

    #[test]
    fn npx_install_pins_package_and_uses_managed_npx() {
        let runner = FakeRunner::default();
        let node = runtime();
        let result = install_entry(&entry("codex"), Some(&node), &runner).expect("installed");
        assert_eq!(result.version.as_deref(), Some("2.2.2"));
        let calls = runner.calls.lock().expect("calls");
        assert_eq!(calls.len(), 1);
        assert!(calls[0].0.ends_with("npx"));
        assert_eq!(
            calls[0].1,
            vec![
                "--yes".to_string(),
                "codex-acp@2.2.2".to_string(),
                "--version".to_string()
            ]
        );
        let _ = std::fs::remove_dir_all(node.root);
    }

    #[test]
    fn native_missing_is_not_silently_installed() {
        let runner = FakeRunner {
            fail: true,
            ..Default::default()
        };
        let error = install_entry(&entry("omp"), None, &runner).unwrap_err();
        assert!(matches!(
            error,
            InstallError::NativeInstallUnsupported { .. }
        ));
    }

    #[test]
    fn npx_requires_complete_node_runtime() {
        let runner = FakeRunner::default();
        let error = install_entry(&entry("codex"), None, &runner).unwrap_err();
        assert_eq!(error, InstallError::NodeRuntimeMissing);
    }
}
