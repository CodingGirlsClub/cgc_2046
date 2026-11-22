use std::collections::HashSet;
use std::path::Path;

use crate::checkpoint::{Checkpoint, CheckpointError, CheckpointManager};
use crate::git_cli::stderr;

const DEFAULT_EXCLUDES_MARKER: &str = "# cgc-checkpoint-defaults";
const DEFAULT_EXCLUDES_BLOCK: &str = "\
# cgc-checkpoint-defaults
node_modules/
target/
.venv/
__pycache__/
.next/
.cache/
.DS_Store
";

/// 被淘汰或删除的隐藏 checkpoint ref。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PrunedRef {
    pub thread_id: String,
    pub seq: u64,
    pub ref_name: String,
}

/// `.git/objects` 体积与对象计数统计（来源：`git count-objects -v`）。
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ObjectStoreStats {
    pub loose_count: u64,
    pub loose_bytes: u64,
    pub pack_count: u64,
    pub pack_bytes: u64,
    pub garbage_bytes: u64,
}

impl ObjectStoreStats {
    pub fn total_bytes(&self) -> u64 {
        self.loose_bytes
            .saturating_add(self.pack_bytes)
            .saturating_add(self.garbage_bytes)
    }
}

/// Git GC 执行模式。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GcMode {
    Auto,
    PruneGracePeriod,
    PruneNow,
}

/// 设置页展示用的检查点仓库占用与 ref 计数概览。
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct CheckpointStorageSummary {
    pub stats: ObjectStoreStats,
    pub total_refs: usize,
    pub limit_bytes: u64,
}

/// 单次快照返回，包含同步裁剪掉的旧 ref 与是否需要后台 GC 的提示。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SnapshotReport {
    pub checkpoint: Checkpoint,
    pub pruned: Vec<PrunedRef>,
    pub needs_gc: bool,
}

/// 超过 500 MB 水位或手动全量清理后的返回摘要。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ReclaimReport {
    pub pruned: Vec<PrunedRef>,
    pub remaining_refs: usize,
    pub stats_after: ObjectStoreStats,
    pub within_budget: bool,
    pub limit_bytes: u64,
}

#[derive(Clone, Debug)]
struct RefEntry {
    thread_id: String,
    seq: u64,
    ref_name: String,
    committed_at: i64,
}

impl From<RefEntry> for PrunedRef {
    fn from(entry: RefEntry) -> Self {
        Self {
            thread_id: entry.thread_id,
            seq: entry.seq,
            ref_name: entry.ref_name,
        }
    }
}

impl CheckpointManager {
    /// 读取仓库对象库计数与占用字节数（持锁执行）。
    pub fn object_store_stats(&self) -> Result<ObjectStoreStats, CheckpointError> {
        let _guard = self.lock_git()?;
        self.object_store_stats_locked()
    }

    /// 读取检查点对象库占用、全部隐藏 ref 数与容量预算上限。
    pub fn storage_summary(&self) -> Result<CheckpointStorageSummary, CheckpointError> {
        let _guard = self.lock_git()?;
        let stats = self.object_store_stats_locked()?;
        let total_refs = self.list_all_checkpoint_refs_locked()?.len();
        Ok(CheckpointStorageSummary {
            stats,
            total_refs,
            limit_bytes: self.max_object_bytes,
        })
    }

    /// 删除指定线程 `seq >= min_seq` 的隐藏 ref（rewind 时使用），绝不触碰用户分支。
    pub fn delete_refs_from(
        &self,
        thread_id: &str,
        min_seq: u64,
    ) -> Result<Vec<PrunedRef>, CheckpointError> {
        let _guard = self.lock_git()?;
        let mut targets: Vec<RefEntry> = self
            .list_all_checkpoint_refs_locked()?
            .into_iter()
            .filter(|entry| entry.thread_id == thread_id && entry.seq >= min_seq)
            .collect();
        targets.sort_by_key(|entry| entry.seq);
        let pruned: Vec<PrunedRef> = targets.into_iter().map(PrunedRef::from).collect();
        self.delete_refs_locked(&pruned)?;
        Ok(pruned)
    }

    /// 删除指定线程的所有隐藏 checkpoint ref（删会话时使用），绝不触碰用户分支或其它线程。
    pub fn delete_thread_refs(&self, thread_id: &str) -> Result<Vec<PrunedRef>, CheckpointError> {
        let _guard = self.lock_git()?;
        let mut targets: Vec<RefEntry> = self
            .list_all_checkpoint_refs_locked()?
            .into_iter()
            .filter(|entry| entry.thread_id == thread_id)
            .collect();
        targets.sort_by_key(|entry| entry.seq);
        let pruned: Vec<PrunedRef> = targets.into_iter().map(PrunedRef::from).collect();
        self.delete_refs_locked(&pruned)?;
        Ok(pruned)
    }

    /// 在串口 Git 锁保护下执行 GC 并返回最新对象库统计。
    pub fn run_gc(&self, mode: GcMode) -> Result<ObjectStoreStats, CheckpointError> {
        let _guard = self.lock_git()?;
        self.run_gc_locked(mode)?;
        self.object_store_stats_locked()
    }

    /// 对象库超出预算时的自救清理：清理其它线程 ref 与当前线程超出 `keep_current` 的旧 ref，
    /// 并执行带 1 小时安全窗口的 GC 打包压缩，始终不触碰用户分支与 HEAD 提交。
    pub fn reclaim_for_budget(
        &self,
        current_thread_id: &str,
        keep_current: usize,
    ) -> Result<ReclaimReport, CheckpointError> {
        self.reclaim_locked(
            Some(current_thread_id),
            keep_current,
            GcMode::PruneGracePeriod,
        )
    }

    /// 用户在设置页显式触发的全量历史检查点清理：
    /// 仅保留 `current_thread_id` 最新 `keep_current` 条隐藏 ref，其余全部删除并立即执行 `--prune=now`，
    /// 始终不触碰用户分支、索引与 HEAD 提交。
    pub fn purge_history_checkpoints(
        &self,
        current_thread_id: Option<&str>,
        keep_current: usize,
    ) -> Result<ReclaimReport, CheckpointError> {
        self.reclaim_locked(current_thread_id, keep_current, GcMode::PruneNow)
    }

    fn reclaim_locked(
        &self,
        current_thread_id: Option<&str>,
        keep_current: usize,
        gc_mode: GcMode,
    ) -> Result<ReclaimReport, CheckpointError> {
        let _guard = self.lock_git()?;
        let all_refs = self.list_all_checkpoint_refs_locked()?;
        let total_before = all_refs.len();
        let mut other_refs = Vec::new();
        let mut current_refs = Vec::new();
        for entry in all_refs {
            if current_thread_id.is_some_and(|id| entry.thread_id == id) {
                current_refs.push(entry);
            } else {
                other_refs.push(entry);
            }
        }
        other_refs.sort_by(|a, b| {
            (a.committed_at, a.seq, &a.thread_id).cmp(&(b.committed_at, b.seq, &b.thread_id))
        });
        current_refs.sort_by_key(|entry| entry.seq);

        let mut pruned: Vec<PrunedRef> = other_refs.into_iter().map(PrunedRef::from).collect();
        let excess_current = current_refs.len().saturating_sub(keep_current);
        pruned.extend(
            current_refs
                .into_iter()
                .take(excess_current)
                .map(PrunedRef::from),
        );

        let remaining_refs = total_before.saturating_sub(pruned.len());
        self.delete_refs_locked(&pruned)?;
        self.run_gc_locked(gc_mode)?;
        let stats_after = self.object_store_stats_locked()?;
        Ok(ReclaimReport {
            pruned,
            remaining_refs,
            within_budget: stats_after.total_bytes() <= self.max_object_bytes,
            stats_after,
            limit_bytes: self.max_object_bytes,
        })
    }

    pub(crate) fn object_store_stats_locked(&self) -> Result<ObjectStoreStats, CheckpointError> {
        let output = self.git(["count-objects", "-v"])?;
        if !output.status.success() {
            return Err(CheckpointError::Git(stderr(&output)));
        }
        Ok(parse_count_objects(&String::from_utf8_lossy(
            &output.stdout,
        )))
    }

    pub(crate) fn prune_refs_locked(
        &self,
        thread_id: &str,
    ) -> Result<Vec<PrunedRef>, CheckpointError> {
        let all_refs = self.list_all_checkpoint_refs_locked()?;
        let mut current_refs = Vec::new();
        let mut other_refs = Vec::new();
        for entry in all_refs {
            if entry.thread_id == thread_id {
                current_refs.push(entry);
            } else {
                other_refs.push(entry);
            }
        }
        current_refs.sort_by_key(|entry| entry.seq);
        other_refs.sort_by(|a, b| {
            (a.committed_at, a.seq, &a.thread_id).cmp(&(b.committed_at, b.seq, &b.thread_id))
        });

        let mut to_delete = Vec::new();
        let per_thread_excess = current_refs.len().saturating_sub(self.max_refs);
        let remaining_current: Vec<RefEntry> = current_refs
            .into_iter()
            .enumerate()
            .filter_map(|(idx, entry)| {
                if idx < per_thread_excess {
                    to_delete.push(PrunedRef::from(entry));
                    None
                } else {
                    Some(entry)
                }
            })
            .collect();

        let remaining_total = other_refs.len() + remaining_current.len();
        let global_excess = remaining_total.saturating_sub(self.max_total_refs);
        if global_excess > 0 {
            let from_others = global_excess.min(other_refs.len());
            to_delete.extend(
                other_refs
                    .into_iter()
                    .take(from_others)
                    .map(PrunedRef::from),
            );

            let still_excess = global_excess.saturating_sub(from_others);
            if still_excess > 0 {
                // 即使全局上限极小，也始终保留当前线程最新的至少 1 条 checkpoint。
                let deletable_current = remaining_current.len().saturating_sub(1);
                let take_current = still_excess.min(deletable_current);
                to_delete.extend(
                    remaining_current
                        .into_iter()
                        .take(take_current)
                        .map(PrunedRef::from),
                );
            }
        }

        self.delete_refs_locked(&to_delete)?;
        Ok(to_delete)
    }

    pub(crate) fn ensure_default_excludes(git_dir: &Path) -> Result<(), CheckpointError> {
        let info_dir = git_dir.join("info");
        std::fs::create_dir_all(&info_dir)
            .map_err(|error| CheckpointError::Io(error.to_string()))?;
        let exclude_path = info_dir.join("exclude");
        let existing = match std::fs::read_to_string(&exclude_path) {
            Ok(content) => content,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => String::new(),
            Err(error) => return Err(CheckpointError::Io(error.to_string())),
        };
        if existing.contains(DEFAULT_EXCLUDES_MARKER) {
            return Ok(());
        }
        let mut updated = existing;
        if !updated.is_empty() && !updated.ends_with('\n') {
            updated.push('\n');
        }
        updated.push_str(DEFAULT_EXCLUDES_BLOCK);
        std::fs::write(&exclude_path, updated)
            .map_err(|error| CheckpointError::Io(error.to_string()))
    }

    fn list_all_checkpoint_refs_locked(&self) -> Result<Vec<RefEntry>, CheckpointError> {
        let output = self.git([
            "for-each-ref",
            "--format=%(refname)%09%(committerdate:unix)",
            "refs/cgc/checkpoints/",
        ])?;
        if !output.status.success() {
            return Err(CheckpointError::Git(stderr(&output)));
        }
        let mut entries = Vec::new();
        for line in String::from_utf8_lossy(&output.stdout).lines() {
            let Some((ref_name, committed_text)) = line.split_once('\t') else {
                continue;
            };
            let Some((thread_id, seq)) = parse_checkpoint_ref(ref_name) else {
                continue;
            };
            let committed_at = committed_text.trim().parse::<i64>().unwrap_or(0);
            entries.push(RefEntry {
                thread_id,
                seq,
                ref_name: ref_name.to_string(),
                committed_at,
            });
        }
        Ok(entries)
    }

    fn delete_refs_locked(&self, refs: &[PrunedRef]) -> Result<(), CheckpointError> {
        if refs.is_empty() {
            return Ok(());
        }
        let mut seen = HashSet::with_capacity(refs.len());
        let mut stdin_bytes = Vec::new();
        for item in refs {
            if seen.insert(item.ref_name.as_str()) {
                stdin_bytes.extend_from_slice(b"delete ");
                stdin_bytes.extend_from_slice(item.ref_name.as_bytes());
                stdin_bytes.extend_from_slice(b"\0\0");
            }
        }
        if stdin_bytes.is_empty() {
            return Ok(());
        }
        let output = self.git_stdin(&["update-ref", "--stdin", "-z"], &stdin_bytes)?;
        if !output.status.success() {
            return Err(CheckpointError::Git(stderr(&output)));
        }
        Ok(())
    }

    fn run_gc_locked(&self, mode: GcMode) -> Result<(), CheckpointError> {
        let output = match mode {
            GcMode::Auto => self.git(["-c", "gc.autoDetach=false", "gc", "--auto", "--quiet"])?,
            GcMode::PruneGracePeriod => self.git([
                "-c",
                "gc.autoDetach=false",
                "gc",
                "--prune=1.hour.ago",
                "--quiet",
            ])?,
            GcMode::PruneNow => {
                self.git(["-c", "gc.autoDetach=false", "gc", "--prune=now", "--quiet"])?
            }
        };
        // `git gc` 不感知私有 `cgc-checkpoint.index`，可能清理仅被 `diff()` / `changed_files()`
        // 暂存进该私有索引、尚未写入任何 checkpoint commit 的 blob；GC 后移除该私有索引，
        // 迫使下次 `populate_index()` 从工作区重新建树，避免 `write-tree` 命中已删对象报错。
        let _ = std::fs::remove_file(&self.index_path);
        if !output.status.success() {
            return Err(CheckpointError::Git(stderr(&output)));
        }
        Ok(())
    }
}

fn parse_checkpoint_ref(ref_name: &str) -> Option<(String, u64)> {
    let rest = ref_name.strip_prefix("refs/cgc/checkpoints/")?;
    let (thread_id, seq_text) = rest.rsplit_once('/')?;
    if thread_id.is_empty() {
        return None;
    }
    let seq = seq_text.parse::<u64>().ok()?;
    Some((thread_id.to_string(), seq))
}

fn parse_count_objects(stdout: &str) -> ObjectStoreStats {
    let mut stats = ObjectStoreStats::default();
    for line in stdout.lines() {
        let Some((key, value)) = line.split_once(':') else {
            continue;
        };
        let Ok(parsed) = value.trim().parse::<u64>() else {
            continue;
        };
        match key.trim() {
            "count" => stats.loose_count = parsed,
            "size" => stats.loose_bytes = parsed.saturating_mul(1024),
            "packs" => stats.pack_count = parsed,
            "size-pack" => stats.pack_bytes = parsed.saturating_mul(1024),
            "size-garbage" => stats.garbage_bytes = parsed.saturating_mul(1024),
            _ => {}
        }
    }
    stats
}
