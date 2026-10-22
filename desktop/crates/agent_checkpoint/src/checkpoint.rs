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

/// 在某个工作区仓库里创建/列出/恢复 checkpoint。
#[derive(Debug)]
pub struct CheckpointManager {
    repo: PathBuf,
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
        Ok(Self {
            repo,
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
        let index_path = self.temp_index_path();
        let _ = std::fs::remove_file(&index_path);
        self.populate_index(&index_path)?;
        self.drop_ignored_entries(&index_path)?;
        let tree = self.git_with_index(&index_path, ["write-tree"])?;
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
        let _ = std::fs::remove_file(&index_path);

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
        let index_path = self.temp_index_path();
        let _ = std::fs::remove_file(&index_path);
        self.populate_index(&index_path)?;
        let output = self.git_with_index(
            &index_path,
            ["diff", "--cached", checkpoint.sha.as_str(), "--", "."],
        );
        let _ = std::fs::remove_file(&index_path);
        let output = output?;
        if !output.status.success() {
            return Err(CheckpointError::Git(stderr(&output)));
        }
        Ok(String::from_utf8_lossy(&output.stdout).to_string())
    }

    /// 恢复 tracked 文件到 checkpoint（untracked 文件不删除，避免误删用户文件）。
    pub fn restore(&self, checkpoint: &Checkpoint) -> Result<(), CheckpointError> {
        let output = self.git([
            "restore",
            "--source",
            checkpoint.sha.as_str(),
            "--worktree",
            "--staged",
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

    fn populate_index(&self, index_path: &Path) -> Result<(), CheckpointError> {
        // 空索引起步，再把工作区全部文件加进去（尊重 .gitignore）。
        let read_tree = self.git_with_index(index_path, ["read-tree", "--empty"])?;
        if !read_tree.status.success() {
            return Err(CheckpointError::Git(stderr(&read_tree)));
        }
        let add = self.git_with_index(index_path, ["add", "--all", "--", "."])?;
        if !add.status.success() {
            return Err(CheckpointError::Git(stderr(&add)));
        }
        Ok(())
    }

    /// 从临时索引里剔除超大文件与常见二进制/压缩包。
    fn drop_ignored_entries(&self, index_path: &Path) -> Result<(), CheckpointError> {
        let listed = self.git_with_index(index_path, ["ls-files", "--stage", "-z"])?;
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
                index_path,
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

    fn temp_index_path(&self) -> PathBuf {
        use std::sync::atomic::{AtomicU64, Ordering};
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let serial = COUNTER.fetch_add(1, Ordering::Relaxed);
        self.repo.join(".git").join(format!(
            "cgc-checkpoint-{}-{serial}.index",
            std::process::id()
        ))
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
