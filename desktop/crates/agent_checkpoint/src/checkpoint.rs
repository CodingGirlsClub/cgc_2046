use std::path::{Path, PathBuf};
use std::process::Command;

/// 单文件超过该大小不进快照。
pub const MAX_FILE_BYTES: u64 = 2 * 1024 * 1024;
/// 默认每线程保留的 checkpoint 数。
pub const DEFAULT_MAX_REFS: usize = 50;

const AGENT_NAME: &str = "CGC Agent";
const AGENT_EMAIL: &str = "cgc-agent@localhost";

#[derive(Debug, thiserror::Error)]
pub enum CheckpointError {
    #[error("not a git repository: {0}")]
    NotRepo(String),
    #[error("git: {0}")]
    Git(String),
    #[error("io: {0}")]
    Io(String),
    #[error("invalid path: {0}")]
    InvalidPath(String),
}

/// 一个 checkpoint 的元数据（内容在 Git 对象里）。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Checkpoint {
    pub thread_id: String,
    pub seq: u64,
    pub ref_name: String,
    pub sha: String,
    pub base_head: Option<String>,
}

/// checkpoint 与当前工作区之间的一处文件变更。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FileChange {
    pub path: String,
    /// `M`（修改）/`A`（新增）/`D`（删除）/`R`（重命名）等。
    pub status: String,
}

/// 在某个工作区仓库里创建/列出/恢复 checkpoint。
#[derive(Debug)]
pub struct CheckpointManager {
    repo: PathBuf,
    /// `git rev-parse --absolute-git-dir` 的结果。worktree / 子目录下不能用
    /// `<repo>/.git` 拼临时索引路径（linked worktree 的 .git 是文件）。
    git_dir: PathBuf,
    /// 持久化的增量索引；每轮快照只更新变化的文件。
    index_path: PathBuf,
    max_refs: usize,
}

impl CheckpointManager {
    /// 打开一个已有的 Git 仓库；不是仓库返回 `NotRepo`。
    pub fn open(repo: impl Into<PathBuf>) -> Result<Self, CheckpointError> {
        let repo = repo.into();
        let output = Command::new("git")
            .arg("-C")
            .arg(&repo)
            .args(["rev-parse", "--git-dir"])
            .output()
            .map_err(|error| CheckpointError::Io(error.to_string()))?;
        if !output.status.success() {
            return Err(CheckpointError::NotRepo(repo.display().to_string()));
        }
        let git_dir = resolve_git_dir(&repo)?;
        let index_path = git_dir.join("cgc-checkpoint.index");
        Ok(Self {
            repo,
            git_dir,
            index_path,
            max_refs: DEFAULT_MAX_REFS,
        })
    }

    /// 初始化 Git 仓库（Git 是 native agent 的硬前提，首次使用工作区时调用）。
    pub fn initialize(repo: impl Into<PathBuf>) -> Result<Self, CheckpointError> {
        let repo = repo.into();
        std::fs::create_dir_all(&repo).map_err(|error| CheckpointError::Io(error.to_string()))?;
        let output = Command::new("git")
            .arg("-C")
            .arg(&repo)
            .args(["init", "--quiet"])
            .output()
            .map_err(|error| CheckpointError::Io(error.to_string()))?;
        if !output.status.success() {
            return Err(CheckpointError::Git(stderr(&output)));
        }
        Self::open(repo)
    }

    pub fn with_max_refs(mut self, max_refs: usize) -> Self {
        self.max_refs = max_refs.max(1);
        self
    }

    pub fn repo(&self) -> &Path {
        &self.repo
    }

    pub fn git_dir(&self) -> &Path {
        &self.git_dir
    }

    /// 当前 HEAD；空仓库返回 `None`。
    pub fn head(&self) -> Result<Option<String>, CheckpointError> {
        let output = self.git(["rev-parse", "--verify", "HEAD"])?;
        if output.status.success() {
            Ok(Some(
                String::from_utf8_lossy(&output.stdout).trim().to_string(),
            ))
        } else {
            Ok(None)
        }
    }

    /// 创建快照并写入隐藏 ref。
    pub fn snapshot(&self, thread_id: &str, seq: u64) -> Result<Checkpoint, CheckpointError> {
        self.populate_index()?;
        self.drop_ignored_entries()?;
        let tree = self.git_with_index(&self.index_path, ["write-tree"])?;
        if !tree.status.success() {
            return Err(CheckpointError::Git(stderr(&tree)));
        }
        let tree_sha = String::from_utf8_lossy(&tree.stdout).trim().to_string();

        let base_head = self.head()?;
        let mut commit_args = vec!["commit-tree".to_string(), tree_sha];
        if let Some(head) = &base_head {
            commit_args.push("-p".to_string());
            commit_args.push(head.clone());
        }
        commit_args.push("-m".to_string());
        commit_args.push(format!("CGC Agent checkpoint {thread_id}/{seq}"));
        let commit = self.git_with_identity(
            commit_args
                .iter()
                .map(String::as_str)
                .collect::<Vec<_>>()
                .as_slice(),
        )?;
        if !commit.status.success() {
            return Err(CheckpointError::Git(stderr(&commit)));
        }
        let sha = String::from_utf8_lossy(&commit.stdout).trim().to_string();

        let ref_name = format!("refs/cgc/checkpoints/{thread_id}/{seq}");
        let update = self.git(["update-ref", ref_name.as_str(), sha.as_str()])?;
        if !update.status.success() {
            return Err(CheckpointError::Git(stderr(&update)));
        }
        self.prune(thread_id)?;
        Ok(Checkpoint {
            thread_id: thread_id.to_string(),
            seq,
            ref_name,
            sha,
            base_head,
        })
    }

    pub fn list(&self, thread_id: &str) -> Result<Vec<Checkpoint>, CheckpointError> {
        let prefix = format!("refs/cgc/checkpoints/{thread_id}/");
        let output = self.git([
            "for-each-ref",
            "--format=%(refname) %(objectname)",
            prefix.as_str(),
        ])?;
        if !output.status.success() {
            return Err(CheckpointError::Git(stderr(&output)));
        }
        let mut checkpoints = Vec::new();
        for line in String::from_utf8_lossy(&output.stdout).lines() {
            let mut parts = line.split_whitespace();
            let (Some(ref_name), Some(sha)) = (parts.next(), parts.next()) else {
                continue;
            };
            let Some(seq_text) = ref_name.rsplit('/').next() else {
                continue;
            };
            let Ok(seq) = seq_text.parse::<u64>() else {
                continue;
            };
            checkpoints.push(Checkpoint {
                thread_id: thread_id.to_string(),
                seq,
                ref_name: ref_name.to_string(),
                sha: sha.to_string(),
                base_head: None,
            });
        }
        checkpoints.sort_by_key(|checkpoint| checkpoint.seq);
        Ok(checkpoints)
    }

    /// 当前工作区相对 checkpoint 的 diff（stat + unified）。
    ///
    /// 用临时索引把工作区（含未跟踪文件、尊重 ignore）装进 index，
    /// 再 `git diff --cached <sha>` 对比；不碰用户自己的 index。
    pub fn diff(&self, checkpoint: &Checkpoint) -> Result<String, CheckpointError> {
        self.populate_index()?;
        let output = self.git_with_index(
            &self.index_path,
            ["diff", "--cached", checkpoint.sha.as_str(), "--", "."],
        );
        let output = output?;
        if !output.status.success() {
            return Err(CheckpointError::Git(stderr(&output)));
        }
        Ok(String::from_utf8_lossy(&output.stdout).to_string())
    }

    /// checkpoint 与当前工作区之间的文件级变更列表。
    pub fn changed_files(
        &self,
        checkpoint: &Checkpoint,
    ) -> Result<Vec<FileChange>, CheckpointError> {
        self.populate_index()?;
        let output = self.git_with_index(
            &self.index_path,
            [
                "diff",
                "--cached",
                "--name-status",
                checkpoint.sha.as_str(),
                "--",
                ".",
            ],
        );
        let output = output?;
        if !output.status.success() {
            return Err(CheckpointError::Git(stderr(&output)));
        }
        let mut changes = Vec::new();
        for line in String::from_utf8_lossy(&output.stdout).lines() {
            let mut parts = line.splitn(2, '\t');
            let (Some(status), Some(path)) = (parts.next(), parts.next()) else {
                continue;
            };
            changes.push(FileChange {
                path: path.to_string(),
                status: status.chars().next().unwrap_or('?').to_string(),
            });
        }
        Ok(changes)
    }

    /// 仅恢复单个文件的工作区内容到 checkpoint（Reject），保留用户 index。
    pub fn restore_file(&self, checkpoint: &Checkpoint, path: &str) -> Result<(), CheckpointError> {
        if path.is_empty()
            || Path::new(path).is_absolute()
            || path.split('/').any(|segment| segment == "..")
        {
            return Err(CheckpointError::InvalidPath(path.to_string()));
        }
        let output = self.git([
            "restore",
            "--source",
            checkpoint.sha.as_str(),
            "--worktree",
            "--overlay",
            "--",
            path,
        ])?;
        if !output.status.success() {
            return Err(CheckpointError::Git(stderr(&output)));
        }
        Ok(())
    }

    /// 覆盖 checkpoint 中的文件；保留用户 index 和快照外的文件（含主动排除项）。
    pub fn restore(&self, checkpoint: &Checkpoint) -> Result<(), CheckpointError> {
        let output = self.git([
            "restore",
            "--source",
            checkpoint.sha.as_str(),
            "--worktree",
            "--overlay",
            "--",
            ".",
        ])?;
        if !output.status.success() {
            return Err(CheckpointError::Git(stderr(&output)));
        }
        Ok(())
    }

    /// HEAD 已偏离 checkpoint 基线时，checkpoint 可能失配。
    pub fn is_valid(&self, checkpoint: &Checkpoint) -> Result<bool, CheckpointError> {
        match (&checkpoint.base_head, self.head()?) {
            (None, None) => Ok(true),
            (Some(expected), Some(actual)) => Ok(expected == &actual),
            _ => Ok(false),
        }
    }

    /// 用持久索引把工作区同步进树；首次创建时先 read-tree --empty。
    /// 每轮只让 git 更新变化文件，避免全量重建索引。
    fn populate_index(&self) -> Result<(), CheckpointError> {
        if !self.index_path.exists() {
            let read_tree = self.git_with_index(&self.index_path, ["read-tree", "--empty"])?;
            if !read_tree.status.success() {
                return Err(CheckpointError::Git(stderr(&read_tree)));
            }
        }
        let add = self.git_with_index(&self.index_path, ["add", "--all", "--", "."])?;
        if add.status.success() {
            return Ok(());
        }
        // 索引可能被外部进程写坏：删掉重来一次。
        let _ = std::fs::remove_file(&self.index_path);
        let read_tree = self.git_with_index(&self.index_path, ["read-tree", "--empty"])?;
        if !read_tree.status.success() {
            return Err(CheckpointError::Git(stderr(&read_tree)));
        }
        let retry = self.git_with_index(&self.index_path, ["add", "--all", "--", "."])?;
        if !retry.status.success() {
            return Err(CheckpointError::Git(stderr(&retry)));
        }
        Ok(())
    }

    /// 从临时索引里剔除超大文件与常见二进制/压缩包。
    fn drop_ignored_entries(&self) -> Result<(), CheckpointError> {
        let listed = self.git_with_index(&self.index_path, ["ls-files", "--stage", "-z"])?;
        if !listed.status.success() {
            return Err(CheckpointError::Git(stderr(&listed)));
        }
        let raw = String::from_utf8_lossy(&listed.stdout).to_string();
        let mut dropped = Vec::new();
        for entry in raw.split('\0') {
            let Some((_, path)) = entry.split_once('\t') else {
                continue;
            };
            if should_skip(path) {
                dropped.push(path.to_string());
                continue;
            }
            let full_path = self.repo.join(path);
            match std::fs::metadata(&full_path) {
                Ok(metadata) if metadata.len() > MAX_FILE_BYTES => dropped.push(path.to_string()),
                _ => {}
            }
        }
        for path in dropped {
            let _ = self.git_with_index(
                &self.index_path,
                ["rm", "--cached", "--quiet", "--", path.as_str()],
            );
        }
        Ok(())
    }

    fn prune(&self, thread_id: &str) -> Result<(), CheckpointError> {
        let checkpoints = self.list(thread_id)?;
        let excess = checkpoints.len().saturating_sub(self.max_refs);
        for checkpoint in checkpoints.into_iter().take(excess) {
            let output = self.git(["update-ref", "-d", checkpoint.ref_name.as_str()])?;
            if !output.status.success() {
                return Err(CheckpointError::Git(stderr(&output)));
            }
        }
        Ok(())
    }

    fn git<const N: usize>(
        &self,
        args: [&str; N],
    ) -> Result<std::process::Output, CheckpointError> {
        Command::new("git")
            .arg("-C")
            .arg(&self.repo)
            .args(args)
            .output()
            .map_err(|error| CheckpointError::Io(error.to_string()))
    }

    fn git_with_index<const N: usize>(
        &self,
        index_path: &Path,
        args: [&str; N],
    ) -> Result<std::process::Output, CheckpointError> {
        Command::new("git")
            .arg("-C")
            .arg(&self.repo)
            .env("GIT_INDEX_FILE", index_path)
            .args(args)
            .output()
            .map_err(|error| CheckpointError::Io(error.to_string()))
    }

    fn git_with_identity(&self, args: &[&str]) -> Result<std::process::Output, CheckpointError> {
        Command::new("git")
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

/// 解析真实 git 目录：支持 linked worktree 与仓库子目录。
/// linked worktree 根目录的 `.git` 是文件，`<repo>/.git` 拼路径会失败。
fn resolve_git_dir(repo: &Path) -> Result<PathBuf, CheckpointError> {
    let output = Command::new("git")
        .arg("-C")
        .arg(repo)
        .args(["rev-parse", "--absolute-git-dir"])
        .output()
        .map_err(|error| CheckpointError::Io(error.to_string()))?;
    let path = if output.status.success() {
        String::from_utf8_lossy(&output.stdout).trim().to_string()
    } else {
        // 老版本 git 没有 --absolute-git-dir，回退 --git-dir 并转绝对路径。
        let output = Command::new("git")
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

fn should_skip(path: &str) -> bool {
    const BINARY_EXTENSIONS: &[&str] = &[
        "zip", "gz", "tgz", "7z", "rar", "png", "jpg", "jpeg", "gif", "webp", "pdf", "mp4", "mov",
        "mp3", "wav", "woff", "woff2", "ttf", "otf", "dylib", "so", "dll", "exe",
    ];
    let extension = Path::new(path)
        .extension()
        .map(|extension| extension.to_string_lossy().to_ascii_lowercase());
    extension
        .as_deref()
        .is_some_and(|extension| BINARY_EXTENSIONS.contains(&extension))
}

fn stderr(output: &std::process::Output) -> String {
    String::from_utf8_lossy(&output.stderr).trim().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};

    static COUNTER: AtomicU64 = AtomicU64::new(0);

    fn temp_dir(name: &str) -> PathBuf {
        let serial = COUNTER.fetch_add(1, Ordering::Relaxed);
        std::env::temp_dir().join(format!(
            "cgc-checkpoint-test-{}-{name}-{serial}",
            std::process::id()
        ))
    }

    fn git(dir: &Path, args: &[&str]) -> std::process::Output {
        Command::new("git")
            .arg("-C")
            .arg(dir)
            .args(args)
            .output()
            .expect("run git")
    }

    fn git_ok(dir: &Path, args: &[&str]) {
        let output = git(dir, args);
        assert!(
            output.status.success(),
            "git {args:?} failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }

    fn init_repo(root: &Path) {
        std::fs::create_dir_all(root).expect("create repo dir");
        git_ok(root, &["init", "--quiet"]);
        // 钉死行尾转换：Windows runner（以及开了 core.autocrlf 的开发机）会在
        // checkout/restore 时把 LF 换成 CRLF，内容断言就变成 "one\r\n" vs "one\n"。
        git_ok(root, &["config", "core.autocrlf", "false"]);
        std::fs::write(root.join("a.txt"), "one\n").expect("write a.txt");
        git_ok(root, &["add", "--all"]);
        git_ok(
            root,
            &[
                "-c",
                "user.name=Test",
                "-c",
                "user.email=test@example.com",
                "commit",
                "--quiet",
                "-m",
                "init",
            ],
        );
    }

    #[test]
    fn snapshot_works_in_regular_repo_even_without_file_changes() {
        let root = temp_dir("regular");
        init_repo(&root);
        let manager = CheckpointManager::open(&root).expect("open repo");

        let first = manager.snapshot("native-test", 1).expect("first snapshot");
        assert_eq!(manager.list("native-test").unwrap().len(), 1);

        // 没有改文件也要有 checkpoint（只是 diff 为空）——对齐 Zed 的每轮快照。
        let second = manager.snapshot("native-test", 2).expect("second snapshot");
        assert_eq!(manager.list("native-test").unwrap().len(), 2);
        assert!(
            manager.changed_files(&second).unwrap().is_empty(),
            "chat-only turn should have an empty diff"
        );

        std::fs::write(root.join("a.txt"), "two\n").expect("modify a.txt");
        let changes = manager.changed_files(&first).unwrap();
        assert_eq!(changes.len(), 1, "one modified file");
        assert_eq!(changes[0].path, "a.txt");
        let _third = manager.snapshot("native-test", 3).expect("third snapshot");

        // 回滚到第一轮：文件内容与 diff 都应恢复。
        manager.restore(&first).expect("restore snapshot");
        assert_eq!(
            std::fs::read_to_string(root.join("a.txt")).unwrap(),
            "one\n"
        );
        assert!(manager.changed_files(&first).unwrap().is_empty());

        // 增量索引应落在真实 git 目录里。
        assert!(manager.git_dir().join("cgc-checkpoint.index").exists());
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn snapshot_works_in_linked_worktree_subdir() {
        let main = temp_dir("main");
        let worktree = temp_dir("worktree");
        init_repo(&main);
        let worktree_s = worktree.display().to_string();
        git_ok(
            &main,
            &[
                "worktree",
                "add",
                "--quiet",
                "-b",
                "cgc-test-wt",
                &worktree_s,
            ],
        );
        let sub = worktree.join("sub");
        std::fs::create_dir_all(&sub).expect("create subdir");

        // 修复前这里会失败：worktree 根的 .git 是文件，subdir 没有 .git 目录。
        let manager = CheckpointManager::open(&sub).expect("open worktree subdir");
        assert!(
            manager.git_dir().is_absolute(),
            "git dir must be resolved absolutely"
        );
        std::fs::write(sub.join("inside.txt"), "hello\n").expect("write inside.txt");
        let checkpoint = manager
            .snapshot("native-wt", 1)
            .expect("snapshot in worktree");
        assert_eq!(manager.list("native-wt").unwrap().len(), 1);
        assert_eq!(checkpoint.seq, 1);
        assert!(manager.git_dir().join("cgc-checkpoint.index").exists());

        std::fs::write(sub.join("inside.txt"), "changed\n").expect("modify inside.txt");
        assert_eq!(manager.changed_files(&checkpoint).unwrap().len(), 1);
        let _second = manager.snapshot("native-wt", 2).expect("second snapshot");
        manager.restore(&checkpoint).expect("restore in worktree");
        assert_eq!(
            std::fs::read_to_string(sub.join("inside.txt")).unwrap(),
            "hello\n"
        );
        let _ = std::fs::remove_dir_all(main);
        let _ = std::fs::remove_dir_all(worktree);
    }
}
