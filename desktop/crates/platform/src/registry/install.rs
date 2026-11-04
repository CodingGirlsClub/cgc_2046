//! 固定版本 agent 安装到应用持久目录；运行时直接使用已验证的包入口。

use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use crate::agent::command::run_output;
use crate::agent::detect::parse_version;
use crate::agent::launch::{build_launch, LaunchPlan, NodeRuntime};
use crate::registry::manifest::{AgentEntry, Distribution};
use crate::registry::package::{executable_in, install_dir};

const INSTALL_TIMEOUT: Duration = Duration::from_secs(180);
static NEXT_INSTALL: AtomicU64 = AtomicU64::new(0);

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
}

impl std::fmt::Display for InstallError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NodeRuntimeMissing => {
                formatter.write_str("managed node runtime is not installed")
            }
            Self::NodeRuntimeIncomplete => {
                formatter.write_str("managed node runtime is incomplete")
            }
            Self::NativeInstallUnsupported { command } => write!(
                formatter,
                "native agent `{command}` must be installed by the user"
            ),
            Self::CommandFailed { program, message } => {
                write!(formatter, "{program} failed: {message}")
            }
        }
    }
}

impl std::error::Error for InstallError {}

fn failed(program: &str, message: impl ToString) -> InstallError {
    InstallError::CommandFailed {
        program: program.to_string(),
        message: message.to_string(),
    }
}

struct Staging(PathBuf);

impl Drop for Staging {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

pub fn install_entry(
    entry: &AgentEntry,
    node: Option<&NodeRuntime>,
) -> Result<InstallResult, InstallError> {
    let Distribution::Npx {
        package, version, ..
    } = &entry.distribution
    else {
        let Distribution::Native { command } = &entry.distribution else {
            unreachable!()
        };
        let mut plan = build_launch(entry, None, &std::env::temp_dir())
            .map_err(|error| failed(command, error))?;
        plan.args = vec!["--version".to_string()];
        run_output(&plan, Duration::from_secs(5)).map_err(|_| {
            InstallError::NativeInstallUnsupported {
                command: command.clone(),
            }
        })?;
        return Ok(InstallResult {
            id: entry.id.clone(),
            version: None,
            detail: format!("{command} is already installed"),
        });
    };
    let runtime = node.ok_or(InstallError::NodeRuntimeMissing)?;
    if !runtime.is_ready() {
        return Err(InstallError::NodeRuntimeIncomplete);
    }
    let directory = install_dir(entry, runtime);
    let parent = directory.parent().expect("version directory has parent");
    std::fs::create_dir_all(parent).map_err(|error| failed("npm install", error))?;
    // Keep the lock file: deleting it can split waiters across different inodes.
    let lock = std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(parent.join(format!(".{version}.install.lock")))
        .map_err(|error| failed("agent installation lock", error))?;
    lock.lock()
        .map_err(|error| failed("agent installation lock", error))?;
    if verify_version(entry, runtime, &directory).is_err() {
        let staging = Staging(parent.join(format!(
            ".install-{}-{}",
            std::process::id(),
            NEXT_INSTALL.fetch_add(1, Ordering::Relaxed)
        )));
        std::fs::create_dir(&staging.0).map_err(|error| failed("npm install", error))?;
        std::fs::write(staging.0.join("package.json"), b"{\"private\":true}")
            .map_err(|error| failed("npm install", error))?;
        for filename in ["npm-user.conf", "npm-global.conf"] {
            std::fs::write(runtime.root.join(filename), b"")
                .map_err(|error| failed("npm configuration", error))?;
        }
        let plan = LaunchPlan {
            program: runtime.node(),
            args: vec![
                runtime.npm_cli_js().to_string_lossy().into_owned(),
                "install".to_string(),
                "--save-exact".to_string(),
                format!("{package}@{version}"),
            ],
            env: runtime
                .environment(|key| std::env::var(key).ok())
                .map_err(|error| failed("npm environment", error))?,
            cwd: staging.0.clone(),
        };
        run_output(&plan, INSTALL_TIMEOUT).map_err(|error| failed("npm install", error))?;
        verify_version(entry, runtime, &staging.0)?;
        if directory.exists() {
            std::fs::remove_dir_all(&directory)
                .map_err(|error| failed("agent installation", error))?;
        }
        std::fs::rename(&staging.0, &directory)
            .map_err(|error| failed("agent installation", error))?;
        verify_version(entry, runtime, &directory)?;
    }
    Ok(InstallResult {
        id: entry.id.clone(),
        version: Some(version.clone()),
        detail: format!("{package}@{version} is installed"),
    })
}

fn verify_version(
    entry: &AgentEntry,
    runtime: &NodeRuntime,
    directory: &std::path::Path,
) -> Result<(), InstallError> {
    let executable =
        executable_in(entry, directory).map_err(|error| failed("agent package", error))?;
    let mut args = vec![executable.to_string_lossy().into_owned()];
    args.extend(if entry.version_args.is_empty() {
        vec!["--version".to_string()]
    } else {
        entry.version_args.clone()
    });
    let plan = LaunchPlan {
        program: runtime.node(),
        args,
        env: runtime
            .environment(|key| std::env::var(key).ok())
            .map_err(|error| failed("agent environment", error))?,
        cwd: directory.to_path_buf(),
    };
    let output = run_output(&plan, Duration::from_secs(5))
        .map_err(|error| failed("agent version", error))?;
    let Distribution::Npx { version, .. } = &entry.distribution else {
        unreachable!()
    };
    if parse_version(&output).as_ref() != Some(version) {
        return Err(failed(
            "agent version",
            format!("expected {version}, got {}", output.trim()),
        ));
    }
    Ok(())
}
