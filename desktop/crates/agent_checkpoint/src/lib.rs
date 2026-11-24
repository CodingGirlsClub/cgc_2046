//! Git checkpoint（设计稿 §3.7，P1b 起步）。
//!
//! 用 Git 对象存快照：临时索引 → `write-tree` → `commit-tree` → 隐藏 ref
//! `refs/cgc/checkpoints/<thread>/<seq>`。不移动分支、不污染用户 index。
//! 目录、二进制与超大文件不纳入快照。

pub mod checkpoint;
mod git_cli;
mod index;
pub mod maintenance;

pub use checkpoint::{
    Checkpoint, CheckpointError, CheckpointManager, FileChange, DEFAULT_GC_LOOSE_THRESHOLD,
    DEFAULT_MAX_OBJECT_BYTES, DEFAULT_MAX_REFS, DEFAULT_MAX_TOTAL_REFS, DEFAULT_PRESSURE_KEEP_REFS,
    MAX_FILE_BYTES,
};
pub use maintenance::{
    CheckpointStorageSummary, GcMode, ObjectStoreStats, PrunedRef, ReclaimReport, SnapshotReport,
};
