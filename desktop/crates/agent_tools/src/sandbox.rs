//! OS 沙箱策略（P1a）：macOS Seatbelt、Linux bwrap、Windows 降级审批。
//!
//! 这里只负责把「运行一条命令」包装进沙箱；是否执行仍由工具审批决定。
//! 沙箱不是安全边界本身，审批 + 沙箱一起才构成纵深防御。

use std::path::{Path, PathBuf};
use std::process::Command;

/// 沙箱策略：限制可写路径，可选限制网络。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SandboxPolicy {
    pub workspace: PathBuf,
    pub allow_network: bool,
}

impl SandboxPolicy {
    pub fn new(workspace: impl Into<PathBuf>) -> Self {
        Self {
            workspace: workspace.into(),
            allow_network: false,
        }
    }

    pub fn with_network(mut self, allow_network: bool) -> Self {
        self.allow_network = allow_network;
        self
    }
}

/// 当前平台可用的沙箱实现。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SandboxKind {
    MacosSeatbelt,
    LinuxBwrap,
    WindowsApprovalOnly,
    Unavailable,
}

impl SandboxKind {
    pub fn detect() -> Self {
        if cfg!(target_os = "macos") {
            if Path::new("/usr/bin/sandbox-exec").exists() {
                return Self::MacosSeatbelt;
            }
            return Self::Unavailable;
        }
        if cfg!(target_os = "linux") {
            if command_exists("bwrap") {
                return Self::LinuxBwrap;
            }
            return Self::Unavailable;
        }
        if cfg!(target_os = "windows") {
            return Self::WindowsApprovalOnly;
        }
        Self::Unavailable
    }

    pub fn is_enforcing(self) -> bool {
        matches!(self, Self::MacosSeatbelt | Self::LinuxBwrap)
    }
}

/// 把命令包装进沙箱。
#[derive(Clone, Copy, Debug)]
pub struct CommandSandbox {
    kind: SandboxKind,
}

impl CommandSandbox {
    pub fn detect() -> Self {
        Self {
            kind: SandboxKind::detect(),
        }
    }

    pub fn kind(&self) -> SandboxKind {
        self.kind
    }

    /// 生成可执行的 Command；沙箱不可用（或 Windows 降级）时回退到直接执行。
    pub fn wrap(&self, command: &str, cwd: &Path, policy: &SandboxPolicy) -> Command {
        match self.kind {
            SandboxKind::MacosSeatbelt => {
                let profile = seatbelt_profile(policy);
                let mut process = Command::new("/usr/bin/sandbox-exec");
                process
                    .arg("-p")
                    .arg(profile)
                    .arg("--")
                    .arg("sh")
                    .arg("-c")
                    .arg(command)
                    .current_dir(cwd);
                process
            }
            SandboxKind::LinuxBwrap => {
                let mut process = Command::new("bwrap");
                for arg in bwrap_args(policy, cwd) {
                    process.arg(arg);
                }
                process.args(["--", "sh", "-c", command]);
                process
            }
            SandboxKind::WindowsApprovalOnly | SandboxKind::Unavailable => {
                shell_command(command, cwd)
            }
        }
    }
}

fn shell_command(command: &str, cwd: &Path) -> Command {
    #[cfg(windows)]
    let mut process = {
        let mut process = Command::new("cmd");
        process.arg("/C").arg(command);
        process
    };
    #[cfg(not(windows))]
    let mut process = {
        let mut process = Command::new("sh");
        process.arg("-c").arg(command);
        process
    };
    process.current_dir(cwd);
    process
}

/// macOS Seatbelt 配置：默认允许，禁止写工作区外文件，默认禁网。
pub fn seatbelt_profile(policy: &SandboxPolicy) -> String {
    let workspace = escape_seatbelt_path(&policy.workspace);
    let network = if policy.allow_network {
        ""
    } else {
        "(deny network*)\n"
    };
    format!(
        "(version 1)\n(allow default)\n(deny file-write*)\n(allow file-write* (subpath \"{workspace}\") (subpath \"/private/tmp\") (subpath \"/tmp\") (subpath \"/private/var/folders\"))\n{network}"
    )
}

fn escape_seatbelt_path(path: &Path) -> String {
    path.to_string_lossy()
        .replace('\\', "\\\\")
        .replace('"', "\\\"")
}

/// Linux bubblewrap 参数（不含最后的 `--` 与命令）。
pub fn bwrap_args(policy: &SandboxPolicy, cwd: &Path) -> Vec<String> {
    let workspace = policy.workspace.to_string_lossy().to_string();
    let mut args = vec![
        "--ro-bind".to_string(),
        "/".to_string(),
        "/".to_string(),
        "--bind".to_string(),
        workspace.clone(),
        workspace,
        "--dev".to_string(),
        "/dev".to_string(),
        "--proc".to_string(),
        "/proc".to_string(),
        "--chdir".to_string(),
        cwd.to_string_lossy().to_string(),
    ];
    if !policy.allow_network {
        args.push("--unshare-net".to_string());
    }
    args
}

fn command_exists(name: &str) -> bool {
    std::env::var_os("PATH")
        .map(|paths| std::env::split_paths(&paths).any(|directory| directory.join(name).exists()))
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_workspace(tag: &str) -> PathBuf {
        use std::sync::atomic::{AtomicU64, Ordering};
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let serial = COUNTER.fetch_add(1, Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!(
            "cgc-agent-sandbox-{}-{tag}-{serial}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("workspace");
        dir
    }

    // Seatbelt 是 macOS 的沙箱机制；Windows/Linux 走 bubblewrap，profile 里也不会
    // 出现原样的工作区路径（Windows 反斜杠会被转义），用例只对 macOS 有意义。
    #[cfg(target_os = "macos")]
    #[test]
    fn seatbelt_profile_allows_workspace_and_denies_network_by_default() {
        let workspace = temp_workspace("profile");
        let policy = SandboxPolicy::new(&workspace);
        let profile = seatbelt_profile(&policy);
        assert!(profile.contains(&workspace.to_string_lossy().to_string()));
        assert!(profile.contains("(deny file-write*)"));
        assert!(profile.contains("(deny network*)"));
        let allowed = seatbelt_profile(&policy.clone().with_network(true));
        assert!(!allowed.contains("(deny network*)"));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn seatbelt_path_escapes_quotes() {
        let policy = SandboxPolicy::new("/tmp/weird \"dir\"");
        let profile = seatbelt_profile(&policy);
        assert!(profile.contains("/tmp/weird \\\"dir\\\""));
    }

    #[test]
    fn bwrap_args_include_bind_and_unshare_net() {
        let policy = SandboxPolicy::new("/tmp/ws");
        let args = bwrap_args(&policy, Path::new("/tmp/ws"));
        assert!(args.contains(&"--bind".to_string()));
        assert!(args.contains(&"--unshare-net".to_string()));
        assert!(args.contains(&"/tmp/ws".to_string()));
        let networked = bwrap_args(&policy.with_network(true), Path::new("/tmp/ws"));
        assert!(!networked.contains(&"--unshare-net".to_string()));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn macos_sandbox_runs_echo() {
        let workspace = temp_workspace("echo");
        let policy = SandboxPolicy::new(&workspace);
        let sandbox = CommandSandbox::detect();
        assert_eq!(sandbox.kind(), SandboxKind::MacosSeatbelt);
        let mut command = sandbox.wrap("echo sandbox-ok", &workspace, &policy);
        let output = command.output().expect("run sandboxed command");
        assert!(
            output.status.success(),
            "sandbox command failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        assert!(String::from_utf8_lossy(&output.stdout).contains("sandbox-ok"));
        let _ = std::fs::remove_dir_all(&workspace);
    }

    #[test]
    fn detect_returns_known_kind() {
        let kind = SandboxKind::detect();
        assert!(!matches!(kind, SandboxKind::Unavailable) || cfg!(not(target_os = "macos")));
    }
}
