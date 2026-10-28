use std::io::Write;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

/// AppAction 执行审计记录。
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ActionAuditEntry {
    pub at: i64,
    pub action: String,
    pub detail: String,
    pub dispatched: bool,
}

/// 追加式 JSONL 审计日志（不做轮转，由调用方/运维控制清理）。
#[derive(Clone, Debug)]
pub struct AuditLog {
    path: PathBuf,
}

impl AuditLog {
    pub fn new(path: impl Into<PathBuf>) -> Self {
        Self { path: path.into() }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn append(&self, entry: &ActionAuditEntry) -> std::io::Result<()> {
        if let Some(parent) = self.path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let line = serde_json::to_string(entry).map_err(std::io::Error::other)?;
        let mut file = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.path)?;
        writeln!(file, "{line}")
    }

    /// 读取全部可解析记录；损坏行跳过，不阻塞历史。
    pub fn read_all(&self) -> Vec<ActionAuditEntry> {
        let Ok(raw) = std::fs::read_to_string(&self.path) else {
            return Vec::new();
        };
        raw.lines()
            .filter_map(|line| serde_json::from_str(line).ok())
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_path(tag: &str) -> PathBuf {
        use std::sync::atomic::{AtomicU64, Ordering};
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let serial = COUNTER.fetch_add(1, Ordering::Relaxed);
        std::env::temp_dir().join(format!(
            "cgc-audit-{}-{tag}-{serial}.jsonl",
            std::process::id()
        ))
    }

    fn entry(at: i64, action: &str) -> ActionAuditEntry {
        ActionAuditEntry {
            at,
            action: action.to_string(),
            detail: "route=/courses/1".to_string(),
            dispatched: true,
        }
    }

    #[test]
    fn append_then_read_roundtrip() {
        let path = temp_path("roundtrip");
        let log = AuditLog::new(&path);
        log.append(&entry(1, "open_page")).expect("append");
        log.append(&entry(2, "highlight_range")).expect("append");
        let entries = log.read_all();
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].action, "open_page");
        assert_eq!(entries[1].at, 2);
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn corrupt_lines_are_skipped() {
        let path = temp_path("corrupt");
        let log = AuditLog::new(&path);
        log.append(&entry(1, "open_page")).expect("append");
        let mut file = std::fs::OpenOptions::new()
            .append(true)
            .open(&path)
            .expect("open");
        writeln!(file, "not json").expect("write");
        log.append(&entry(3, "highlight_range")).expect("append");
        let entries = log.read_all();
        assert_eq!(entries.len(), 2);
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn missing_file_returns_empty() {
        let path = temp_path("missing");
        assert!(AuditLog::new(&path).read_all().is_empty());
    }
}
