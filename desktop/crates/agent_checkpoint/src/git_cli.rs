use std::path::{Path, PathBuf};
use std::process::Command;

use crate::checkpoint::{CheckpointError, CheckpointManager};

const AGENT_NAME: &str = "CGC Agent";
const AGENT_EMAIL: &str = "cgc-agent@localhost";

impl CheckpointManager {
    pub(crate) fn git<const N: usize>(
        &self,
        args: [&str; N],
    ) -> Result<std::process::Output, CheckpointError> {
        self.git_var(&args)
    }

    pub(crate) fn git_var(&self, args: &[&str]) -> Result<std::process::Output, CheckpointError> {
        git_command()
            .arg("-C")
            .arg(&self.repo)
            .args(args)
            .output()
            .map_err(|error| CheckpointError::Io(error.to_string()))
    }

    pub(crate) fn git_stdin(
        &self,
        args: &[&str],
        stdin_bytes: &[u8],
    ) -> Result<std::process::Output, CheckpointError> {
        run_with_stdin(
            git_command().arg("-C").arg(&self.repo).args(args),
            stdin_bytes,
        )
    }

    pub(crate) fn git_with_index<const N: usize>(
        &self,
        index_path: &Path,
        args: [&str; N],
    ) -> Result<std::process::Output, CheckpointError> {
        git_command()
            .arg("-C")
            .arg(&self.repo)
            .env("GIT_INDEX_FILE", index_path)
            .args(args)
            .output()
            .map_err(|error| CheckpointError::Io(error.to_string()))
    }

    pub(crate) fn git_with_index_stdin(
        &self,
        index_path: &Path,
        args: &[&str],
        stdin_bytes: &[u8],
    ) -> Result<std::process::Output, CheckpointError> {
        run_with_stdin(
            git_command()
                .arg("--literal-pathspecs")
                .arg("-C")
                .arg(&self.repo)
                .env("GIT_INDEX_FILE", index_path)
                .args(args),
            stdin_bytes,
        )
    }

    pub(crate) fn git_with_identity(
        &self,
        args: &[&str],
    ) -> Result<std::process::Output, CheckpointError> {
        git_command()
            .arg("-C")
            .arg(&self.repo)
            .env("GIT_AUTHOR_NAME", AGENT_NAME)
            .env("GIT_AUTHOR_EMAIL", AGENT_EMAIL)
            .env("GIT_COMMITTER_NAME", AGENT_NAME)
            .env("GIT_COMMITTER_EMAIL", AGENT_EMAIL)
            .args(args)
            .output()
            .map_err(|error| CheckpointError::Io(error.to_string()))
    }
}

fn run_with_stdin(
    command: &mut Command,
    stdin_bytes: &[u8],
) -> Result<std::process::Output, CheckpointError> {
    use std::io::{ErrorKind, Write as _};
    use std::process::Stdio;

    let mut child = command
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| CheckpointError::Io(error.to_string()))?;
    if let Some(mut stdin) = child.stdin.take() {
        if let Err(error) = stdin.write_all(stdin_bytes) {
            if error.kind() != ErrorKind::BrokenPipe {
                return Err(CheckpointError::Io(error.to_string()));
            }
        }
    }
    child
        .wait_with_output()
        .map_err(|error| CheckpointError::Io(error.to_string()))
}

/// 解析真实 git 目录：支持 linked worktree 与仓库子目录。
/// linked worktree 根目录的 `.git` 是文件，`<repo>/.git` 拼路径会失败。
pub(crate) fn resolve_git_dir(repo: &Path) -> Result<PathBuf, CheckpointError> {
    let output = git_command()
        .arg("-C")
        .arg(repo)
        .args(["rev-parse", "--absolute-git-dir"])
        .output()
        .map_err(|error| CheckpointError::Io(error.to_string()))?;
    let path = if output.status.success() {
        String::from_utf8_lossy(&output.stdout).trim().to_string()
    } else {
        // 老版本 git 没有 --absolute-git-dir，回退 --git-dir 并转绝对路径。
        let output = git_command()
            .arg("-C")
            .arg(repo)
            .args(["rev-parse", "--git-dir"])
            .output()
            .map_err(|error| CheckpointError::Io(error.to_string()))?;
        if !output.status.success() {
            return Err(CheckpointError::Git(stderr(&output)));
        }
        let raw = PathBuf::from(String::from_utf8_lossy(&output.stdout).trim());
        if raw.is_absolute() {
            raw.display().to_string()
        } else {
            repo.join(raw).display().to_string()
        }
    };
    if path.is_empty() {
        return Err(CheckpointError::NotRepo(repo.display().to_string()));
    }
    Ok(PathBuf::from(path))
}

pub(crate) fn stderr(output: &std::process::Output) -> String {
    String::from_utf8_lossy(&output.stderr).trim().to_string()
}

/// `git` 是控制台程序；Windows GUI 子系统（无 console）下不隐藏就会闪黑窗。
///
/// 与 `cgc-platform::process::hide_console_window` 同义；本 crate 不依赖 platform，
/// 为不改依赖图保留这 6 行本地实现。
pub(crate) fn git_command() -> Command {
    // 非 Windows 平台不需要 creation_flags，mut 只在 cfg(windows) 分支用到。
    #[cfg_attr(not(windows), allow(unused_mut))]
    let mut command = Command::new("git");
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt as _;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        command.creation_flags(CREATE_NO_WINDOW);
    }
    command
}
