//! 固定版本 agent 安装到应用持久目录；运行时直接使用已验证的包入口。

use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use crate::agent::command::run_output;
use crate::agent::detect::parse_version;
use crate::agent::launch::{build_launch, LaunchPlan, NodeRuntime};
use crate::registry::manifest::{AgentEntry, Distribution};
use crate::registry::package::{executable_in, install_dir};

/// npm 安装超时。DSH adapter 首次安装要下载约 176 MB（`vendor/dsh-runtime.tgz`），
/// 冷缓存 + 慢网络下 180s 必然超时（真实用户已复现 `command timed out`），
/// 因此给足 15 分钟；成功后立即返回，不影响其它 agent。
const INSTALL_TIMEOUT: Duration = Duration::from_secs(900);
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

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct UninstallResult {
    pub id: String,
    pub removed_package: bool,
    pub removed_dsh_home: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum UninstallError {
    NodeRuntimeMissing,
    NativeUninstallUnsupported { command: String },
    RemoveFailed { path: PathBuf, message: String },
}

impl std::fmt::Display for UninstallError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NodeRuntimeMissing => {
                formatter.write_str("managed node runtime is not installed")
            }
            Self::NativeUninstallUnsupported { command } => {
                write!(
                    formatter,
                    "native agent `{command}` must be removed by the user"
                )
            }
            Self::RemoveFailed { path, message } => {
                write!(formatter, "failed to remove {}: {message}", path.display())
            }
        }
    }
}

impl std::error::Error for UninstallError {}

/// 卸载 npx agent：删除固定版本安装目录；DSH 条目同时删除隔离的 DSH_HOME
/// （ADR-0030 D3：学员会话数据不残留）。
///
/// `dsh_home` 由调用方注入（AppPaths::dsh_home_root），保持本函数可单测。
pub fn uninstall_entry(
    entry: &AgentEntry,
    node: Option<&NodeRuntime>,
    dsh_home: Option<&std::path::Path>,
) -> Result<UninstallResult, UninstallError> {
    let Distribution::Npx { .. } = &entry.distribution else {
        let Distribution::Native { command } = &entry.distribution else {
            unreachable!()
        };
        return Err(UninstallError::NativeUninstallUnsupported {
            command: command.clone(),
        });
    };
    let runtime = node.ok_or(UninstallError::NodeRuntimeMissing)?;
    let directory = install_dir(entry, runtime);
    let removed_package = if directory.exists() {
        std::fs::remove_dir_all(&directory).map_err(|error| UninstallError::RemoveFailed {
            path: directory.clone(),
            message: error.to_string(),
        })?;
        true
    } else {
        false
    };
    let removed_dsh_home = if entry.uses_dsh_runtime() {
        match dsh_home {
            Some(path) if path.exists() => {
                std::fs::remove_dir_all(path).map_err(|error| UninstallError::RemoveFailed {
                    path: path.to_path_buf(),
                    message: error.to_string(),
                })?;
                true
            }
            _ => false,
        }
    } else {
        false
    };
    Ok(UninstallResult {
        id: entry.id.clone(),
        removed_package,
        removed_dsh_home,
    })
}

/// plugin 形态安装（ADR-0030 D1 修订）：通过 DSH CLI 把 adapter 写进用户
/// `profiles/acp`，adapter 由用户 DSH 的 runtime 加载，从而复用其 providers。
///
/// 只增删 profile 里的 npm 依赖，**不触碰** `$DSH_HOME` 的会话/凭据/设置。
pub fn install_plugin_entry(
    entry: &AgentEntry,
    plugin: &crate::agent::dsh_plugin::DshPlugin,
) -> Result<InstallResult, InstallError> {
    let Distribution::Npx {
        package, version, ..
    } = &entry.distribution
    else {
        return Err(failed(
            "dsh plugin",
            "plugin install only supports npx entries",
        ));
    };
    if !plugin.dsh.is_file() {
        return Err(failed(
            "dsh plugin",
            format!("dsh CLI not found at {}", plugin.dsh.display()),
        ));
    }
    let profile = crate::agent::dsh_plugin::profile_dir(&plugin.home);
    std::fs::create_dir_all(&profile).map_err(|error| failed("dsh plugin", error))?;
    let plan = LaunchPlan {
        program: plugin.dsh.clone(),
        args: vec![
            "plugin".to_string(),
            "--profile".to_string(),
            crate::agent::dsh_plugin::DSH_PLUGIN_PROFILE.to_string(),
            "add".to_string(),
            format!("{package}@{version}"),
        ],
        env: crate::agent::launch::inherited_environment(|key| std::env::var(key).ok()),
        cwd: profile,
    };
    run_output(&plan, INSTALL_TIMEOUT).map_err(|error| failed("dsh plugin", error))?;
    let installed = crate::agent::dsh_plugin::read_profile_version(&plugin.home, package);
    if installed.as_deref() != Some(version.as_str()) {
        return Err(failed(
            "dsh plugin",
            format!("expected {package}@{version}, got {installed:?}"),
        ));
    }
    Ok(InstallResult {
        id: entry.id.clone(),
        version: Some(version.clone()),
        detail: format!("{package}@{version} installed via dsh profile acp"),
    })
}

/// plugin 形态卸载：只从 profile 移除依赖，用户 DSH 数据目录原样保留。
pub fn uninstall_plugin_entry(
    entry: &AgentEntry,
    plugin: &crate::agent::dsh_plugin::DshPlugin,
) -> Result<UninstallResult, UninstallError> {
    let Distribution::Npx { package, .. } = &entry.distribution else {
        return Err(UninstallError::NativeUninstallUnsupported {
            command: entry.id.clone(),
        });
    };
    let profile = crate::agent::dsh_plugin::profile_dir(&plugin.home);
    let plan = LaunchPlan {
        program: plugin.dsh.clone(),
        args: vec![
            "plugin".to_string(),
            "--profile".to_string(),
            crate::agent::dsh_plugin::DSH_PLUGIN_PROFILE.to_string(),
            "remove".to_string(),
            package.clone(),
        ],
        env: crate::agent::launch::inherited_environment(|key| std::env::var(key).ok()),
        cwd: profile,
    };
    run_output(&plan, INSTALL_TIMEOUT)
        .map_err(|error| failed("dsh plugin", error))
        .map_err(|error| UninstallError::RemoveFailed {
            path: plugin.home.clone(),
            message: error.to_string(),
        })?;
    Ok(UninstallResult {
        id: entry.id.clone(),
        removed_package: true,
        removed_dsh_home: false,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agent::launch::NodeRuntime;
    use crate::registry::manifest::Distribution;

    fn entry(id: &str, package: &str, requires_dsh: bool) -> AgentEntry {
        AgentEntry {
            id: id.to_string(),
            display_name: id.to_string(),
            distribution: Distribution::Npx {
                package: package.to_string(),
                version: "1.0.0".to_string(),
                node: "24".to_string(),
            },
            launch_args: Vec::new(),
            version_args: Vec::new(),
            minimum_version: "1.0.0".to_string(),
            mcp_server_name: "mcp".to_string(),
            login_hint: "login".to_string(),
            requires: if requires_dsh {
                vec!["dsh-runtime".to_string()]
            } else {
                Vec::new()
            },
            download_hint: None,
        }
    }

    #[test]
    fn uninstalls_package_and_isolated_dsh_home_idempotently() {
        let root = std::env::temp_dir().join(format!(
            "cgc-uninstall-{}-{}",
            std::process::id(),
            NEXT_INSTALL.fetch_add(1, Ordering::Relaxed)
        ));
        let runtime = NodeRuntime::new(root.join("node24"));
        let dsh_entry = entry("dsh-test", "@openma/deepseek-harness-acp", true);
        let package_dir = install_dir(&dsh_entry, &runtime);
        std::fs::create_dir_all(package_dir.join("node_modules")).unwrap();
        let dsh_home = root.join("dsh-home");
        std::fs::create_dir_all(&dsh_home).unwrap();
        std::fs::write(dsh_home.join("session.lock"), b"").unwrap();

        let result = uninstall_entry(&dsh_entry, Some(&runtime), Some(&dsh_home)).unwrap();
        assert!(result.removed_package);
        assert!(result.removed_dsh_home);
        assert!(!package_dir.exists(), "package directory removed");
        assert!(!dsh_home.exists(), "isolated DSH_HOME removed");

        let again = uninstall_entry(&dsh_entry, Some(&runtime), Some(&dsh_home)).unwrap();
        assert!(!again.removed_package);
        assert!(!again.removed_dsh_home);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[cfg(unix)]
    #[test]
    fn plugin_install_writes_profile_without_touching_home_data() {
        use std::os::unix::fs::PermissionsExt;
        let root = std::env::temp_dir().join(format!(
            "cgc-plugin-install-{}-{}",
            std::process::id(),
            NEXT_INSTALL.fetch_add(1, Ordering::Relaxed)
        ));
        let dsh = root.join("dsh");
        std::fs::create_dir_all(&root).expect("root");
        std::fs::write(
            &dsh,
            b"#!/bin/sh\nprintf '{\"dependencies\":{\"@openma/deepseek-harness-acp\":\"%s\"}}' \"${5##*@}\" > package.json\n",
        )
        .unwrap();
        let mut perms = std::fs::metadata(&dsh).unwrap().permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(&dsh, perms).unwrap();
        let home = root.join("dsh-home");
        std::fs::create_dir_all(crate::agent::dsh_plugin::profile_dir(&home)).unwrap();
        std::fs::write(home.join("settings.yaml"), b"keep").unwrap();
        let plugin = crate::agent::dsh_plugin::DshPlugin {
            dsh,
            home: home.clone(),
            version: "0.4.41".to_string(),
        };
        let mut dsh_entry = entry("dsh-test", "@openma/deepseek-harness-acp", true);
        if let Distribution::Npx { version, .. } = &mut dsh_entry.distribution {
            *version = "0.4.41".to_string();
        }

        let result = install_plugin_entry(&dsh_entry, &plugin).expect("plugin install");
        assert_eq!(result.version.as_deref(), Some("0.4.41"));
        assert_eq!(
            crate::agent::dsh_plugin::read_profile_version(&home, "@openma/deepseek-harness-acp")
                .as_deref(),
            Some("0.4.41")
        );
        assert_eq!(
            std::fs::read(home.join("settings.yaml")).unwrap(),
            b"keep",
            "plugin install must not touch user DSH data"
        );

        let removed = uninstall_plugin_entry(&dsh_entry, &plugin).expect("plugin uninstall");
        assert!(removed.removed_package);
        assert!(!removed.removed_dsh_home);
        assert!(home.exists(), "plugin uninstall must keep DSH_HOME");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[cfg(unix)]
    #[test]
    fn plugin_install_rejects_version_mismatch() {
        use std::os::unix::fs::PermissionsExt;
        let root = std::env::temp_dir().join(format!(
            "cgc-plugin-mismatch-{}-{}",
            std::process::id(),
            NEXT_INSTALL.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir_all(&root).expect("root");
        let dsh = root.join("dsh");
        std::fs::write(
            &dsh,
            b"#!/bin/sh\nprintf '{\"dependencies\":{\"@openma/deepseek-harness-acp\":\"0.0.0\"}}' > package.json\n",
        )
        .unwrap();
        let mut perms = std::fs::metadata(&dsh).unwrap().permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(&dsh, perms).unwrap();
        let home = root.join("dsh-home");
        let plugin = crate::agent::dsh_plugin::DshPlugin {
            dsh,
            home,
            version: "0.4.41".to_string(),
        };
        let mut dsh_entry = entry("dsh-test", "@openma/deepseek-harness-acp", true);
        if let Distribution::Npx { version, .. } = &mut dsh_entry.distribution {
            *version = "0.4.41".to_string();
        }
        let error = install_plugin_entry(&dsh_entry, &plugin).expect_err("mismatch must fail");
        assert!(error.to_string().contains("expected"), "got {error}");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn shared_local_dsh_home_is_never_removed() {
        let root = std::env::temp_dir().join(format!(
            "cgc-uninstall-shared-{}-{}",
            std::process::id(),
            NEXT_INSTALL.fetch_add(1, Ordering::Relaxed)
        ));
        let runtime = NodeRuntime::new(root.join("node24"));
        let dsh_entry = entry("dsh-test", "@openma/deepseek-harness-acp", true);
        let package_dir = install_dir(&dsh_entry, &runtime);
        std::fs::create_dir_all(package_dir.join("node_modules")).unwrap();
        let shared_home = root.join("local-dsh");
        std::fs::create_dir_all(&shared_home).unwrap();
        std::fs::write(shared_home.join("settings.yaml"), b"llm").unwrap();

        // 共享模式由调用方传 None：卸载只删 CGC 安装包。
        let result = uninstall_entry(&dsh_entry, Some(&runtime), None).unwrap();
        assert!(result.removed_package);
        assert!(!result.removed_dsh_home);
        assert!(
            shared_home.join("settings.yaml").exists(),
            "shared DSH data must survive uninstall"
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn non_dsh_uninstall_keeps_dsh_home() {
        let root = std::env::temp_dir().join(format!(
            "cgc-uninstall-plain-{}-{}",
            std::process::id(),
            NEXT_INSTALL.fetch_add(1, Ordering::Relaxed)
        ));
        let runtime = NodeRuntime::new(root.join("node24"));
        let plain = entry("codex-test", "@agentclientprotocol/codex-acp", false);
        let dsh_home = root.join("dsh-home");
        std::fs::create_dir_all(&dsh_home).unwrap();
        let result = uninstall_entry(&plain, Some(&runtime), Some(&dsh_home)).unwrap();
        assert!(!result.removed_dsh_home);
        assert!(dsh_home.exists());
        let _ = std::fs::remove_dir_all(&root);
    }
}
