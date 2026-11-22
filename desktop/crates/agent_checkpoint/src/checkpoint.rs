use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock, Weak};

use crate::git_cli::{git_command, resolve_git_dir, stderr};
use crate::maintenance::{PrunedRef, SnapshotReport};

fn repo_git_lock(git_dir: &Path) -> Arc<Mutex<()>> {
    static LOCKS: OnceLock<Mutex<HashMap<PathBuf, Weak<Mutex<()>>>>> = OnceLock::new();
    let key = std::fs::canonicalize(git_dir).unwrap_or_else(|_| git_dir.to_path_buf());
    let mut map = LOCKS
        .get_or_init(|| Mutex::new(HashMap::new()))
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    map.retain(|_, weak| weak.strong_count() > 0);
    if let Some(existing) = map.get(&key).and_then(Weak::upgrade) {
        return existing;
    }
    let lock = Arc::new(Mutex::new(()));
    map.insert(key, Arc::downgrade(&lock));
    lock
}

/// 单文件超过该大小不进快照。
pub const MAX_FILE_BYTES: u64 = 2 * 1024 * 1024;
/// 默认每线程保留的 checkpoint 数。
pub const DEFAULT_MAX_REFS: usize = 50;
/// 仓库全局保留的隐藏 checkpoint ref 上限。
pub const DEFAULT_MAX_TOTAL_REFS: usize = 200;
/// 对象库体积水位上限（500 MiB）。
pub const DEFAULT_MAX_OBJECT_BYTES: u64 = 500 * 1024 * 1024;
/// 超限自救时当前线程最多保留的 checkpoint 数。
pub const DEFAULT_PRESSURE_KEEP_REFS: usize = 5;
/// 松散对象达到此阈值时提示后台执行 GC。
pub const DEFAULT_GC_LOOSE_THRESHOLD: u64 = 500;

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
    #[error("checkpoint object store exceeds budget ({used_bytes} bytes > {limit_bytes} bytes)")]
    BudgetExceeded { used_bytes: u64, limit_bytes: u64 },
    #[error("{source}")]
    GcAfterPrune {
        pruned: Vec<PrunedRef>,
        #[source]
        source: Box<CheckpointError>,
    },
}

impl CheckpointError {
    /// 当 ref 裁剪已经落盘但后续 `git gc` 或统计步骤失败时，返回已删除的 ref 列表以便调用方同步元数据。
    pub fn pruned_refs(&self) -> &[PrunedRef] {
        match self {
            Self::GcAfterPrune { pruned, .. } => pruned,
            _ => &[],
        }
    }
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
#[derive(Clone, Debug)]
pub struct CheckpointManager {
    pub(crate) repo: PathBuf,
    /// `git rev-parse --absolute-git-dir` 的结果。worktree / 子目录下不能用
    /// `<repo>/.git` 拼临时索引路径（linked worktree 的 .git 是文件）。
    pub(crate) git_dir: PathBuf,
    /// 持久化的增量索引；每轮快照只更新变化的文件。
    pub(crate) index_path: PathBuf,
    pub(crate) max_refs: usize,
    pub(crate) max_total_refs: usize,
    pub(crate) max_object_bytes: u64,
    pub(crate) git_lock: Arc<Mutex<()>>,
}

impl CheckpointManager {
    /// 打开一个已有的 Git 仓库；不是仓库返回 `NotRepo`。
    pub fn open(repo: impl Into<PathBuf>) -> Result<Self, CheckpointError> {
        let repo = repo.into();
        let output = git_command()
            .arg("-C")
            .arg(&repo)
            .args(["rev-parse", "--git-dir"])
            .output()
            .map_err(|error| CheckpointError::Io(error.to_string()))?;
        if !output.status.success() {
            return Err(CheckpointError::NotRepo(repo.display().to_string()));
        }
        let git_dir = resolve_git_dir(&repo)?;
        let git_lock = repo_git_lock(&git_dir);
        let index_path = git_dir.join("cgc-checkpoint.index");
        Ok(Self {
            repo,
            git_dir,
            index_path,
            max_refs: DEFAULT_MAX_REFS,
            max_total_refs: DEFAULT_MAX_TOTAL_REFS,
            max_object_bytes: DEFAULT_MAX_OBJECT_BYTES,
            git_lock,
        })
    }

    /// 初始化 Git 仓库（Git 是 native agent 的硬前提，首次使用工作区时调用）。
    pub fn initialize(repo: impl Into<PathBuf>) -> Result<Self, CheckpointError> {
        let repo = repo.into();
        std::fs::create_dir_all(&repo).map_err(|error| CheckpointError::Io(error.to_string()))?;
        let output = git_command()
            .arg("-C")
            .arg(&repo)
            .args(["init", "--quiet"])
            .output()
            .map_err(|error| CheckpointError::Io(error.to_string()))?;
        if !output.status.success() {
            return Err(CheckpointError::Git(stderr(&output)));
        }
        let manager = Self::open(repo)?;
        Self::ensure_default_excludes(&manager.git_dir)?;
        Ok(manager)
    }

    pub fn with_max_refs(mut self, max_refs: usize) -> Self {
        self.max_refs = max_refs.max(1);
        self
    }

    pub fn with_max_total_refs(mut self, max_total_refs: usize) -> Self {
        self.max_total_refs = max_total_refs.max(1);
        self
    }

    pub fn with_max_object_bytes(mut self, max_object_bytes: u64) -> Self {
        self.max_object_bytes = max_object_bytes.max(1);
        self
    }

    pub fn max_object_bytes(&self) -> u64 {
        self.max_object_bytes
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
        self.snapshot_with_report(thread_id, seq)
            .map(|report| report.checkpoint)
    }

    /// 创建快照并同步返回被淘汰的旧 ref 与是否需要后台 GC。
    pub fn snapshot_with_report(
        &self,
        thread_id: &str,
        seq: u64,
    ) -> Result<SnapshotReport, CheckpointError> {
        let _guard = self.lock_git()?;
        let stats = self.object_store_stats_locked()?;
        if stats.total_bytes() > self.max_object_bytes {
            return Err(CheckpointError::BudgetExceeded {
                used_bytes: stats.total_bytes(),
                limit_bytes: self.max_object_bytes,
            });
        }
        self.populate_index()?;
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
        let pruned = self.prune_refs_locked(thread_id)?;
        let needs_gc = !pruned.is_empty() || stats.loose_count >= DEFAULT_GC_LOOSE_THRESHOLD;
        Ok(SnapshotReport {
            checkpoint: Checkpoint {
                thread_id: thread_id.to_string(),
                seq,
                ref_name,
                sha,
                base_head,
            },
            pruned,
            needs_gc,
        })
    }

    pub fn list(&self, thread_id: &str) -> Result<Vec<Checkpoint>, CheckpointError> {
        let _guard = self.lock_git()?;
        self.list_locked(thread_id)
    }

    pub(crate) fn list_locked(&self, thread_id: &str) -> Result<Vec<Checkpoint>, CheckpointError> {
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
        let _guard = self.lock_git()?;
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
        let _guard = self.lock_git()?;
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
        let _guard = self.lock_git()?;
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
        let _guard = self.lock_git()?;
        let files = self.git([
            "ls-tree",
            "--name-only",
            "-z",
            checkpoint.sha.as_str(),
            "--",
            ".",
        ])?;
        if !files.status.success() {
            return Err(CheckpointError::Git(stderr(&files)));
        }
        if files.stdout.is_empty() {
            return Ok(());
        }
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

    pub(crate) fn lock_git(&self) -> Result<MutexGuard<'_, ()>, CheckpointError> {
        match self.git_lock.lock() {
            Ok(guard) => Ok(guard),
            Err(poisoned) => Ok(poisoned.into_inner()),
        }
    }
}

#[cfg(test)]
#[path = "checkpoint_tests.rs"]
mod tests;
