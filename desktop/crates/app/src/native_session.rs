//! B4a-2b：native 会话持久化（threads.db）的薄接口。
//!
//! 视图只做 UI 状态映射；存储语义（thread/checkpoint 读写）集中在这里，
//! 便于 B4b 删除 `native_agent_view.rs` 后复用。

use std::path::Path;

use cgc_agent_checkpoint::Checkpoint;
use cgc_agent_core::Thread;
use cgc_agent_store::{CheckpointRecord, SessionStore};

pub(crate) struct NativeSessionStore {
    store: Option<SessionStore>,
}

impl NativeSessionStore {
    pub(crate) fn open(data_root: &Path) -> Self {
        Self {
            store: SessionStore::open(data_root.join("agent").join("threads.db")).ok(),
        }
    }

    pub(crate) fn is_available(&self) -> bool {
        self.store.is_some()
    }

    /// 只读访问（load/list 等 `&self` 操作）。
    pub(crate) fn session(&self) -> Option<&SessionStore> {
        self.store.as_ref()
    }

    /// 可写访问（save/mark 等 `&mut self` 操作）。
    pub(crate) fn session_mut(&mut self) -> Option<&mut SessionStore> {
        self.store.as_mut()
    }

    pub(crate) fn load_thread(&self, thread_id: &str) -> Option<Thread> {
        self.store.as_ref()?.load_thread(thread_id).ok().flatten()
    }

    pub(crate) fn save_thread(&mut self, thread: &Thread) -> bool {
        self.store
            .as_mut()
            .map(|store| store.save_thread(thread).is_ok())
            .unwrap_or(false)
    }

    pub(crate) fn list_checkpoints(&self, thread_id: &str) -> Vec<CheckpointRecord> {
        self.store
            .as_ref()
            .and_then(|store| store.list_checkpoints(thread_id).ok())
            .unwrap_or_default()
    }

    pub(crate) fn save_checkpoint(
        &mut self,
        checkpoint: &Checkpoint,
        ordinal: i64,
        created_at: i64,
    ) -> bool {
        self.store
            .as_mut()
            .map(|store| {
                store
                    .save_checkpoint(checkpoint, ordinal, created_at)
                    .is_ok()
            })
            .unwrap_or(false)
    }

    pub(crate) fn mark_checkpoint_invalid(&mut self, thread_id: &str, ordinal: i64) -> bool {
        self.store
            .as_mut()
            .map(|store| store.mark_checkpoint_invalid(thread_id, ordinal).is_ok())
            .unwrap_or(false)
    }
}

#[cfg(test)]
mod tests {
    use super::NativeSessionStore;
    use cgc_agent_checkpoint::Checkpoint;
    use cgc_agent_core::{SelectedModel, Thread};
    use cgc_agent_provider::{ModelId, ProviderId};

    fn temp_store(name: &str) -> (NativeSessionStore, std::path::PathBuf) {
        let dir = std::env::temp_dir().join(format!(
            "cgc-native-session-{name}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or_default()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        (NativeSessionStore::open(&dir), dir)
    }

    fn thread() -> Thread {
        Thread::new(
            "native-test",
            SelectedModel::new(ProviderId::new("p"), ModelId::new("m")),
        )
    }

    #[test]
    fn save_then_load_thread_roundtrip() {
        let (mut store, dir) = temp_store("thread");
        assert!(store.is_available());
        assert!(store.save_thread(&thread()));
        let loaded = store.load_thread("native-test").expect("loaded");
        assert_eq!(loaded.id, "native-test");
        assert_eq!(loaded.model.provider_id, ProviderId::new("p"));
        assert!(store.load_thread("missing").is_none());
        std::fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn checkpoint_save_list_and_mark_invalid() {
        let (mut store, dir) = temp_store("checkpoint");
        let checkpoint = Checkpoint {
            thread_id: "native-test".into(),
            seq: 1,
            ref_name: "refs/cgc/1".into(),
            sha: "deadbeef".into(),
            base_head: None,
        };
        assert!(store.save_checkpoint(&checkpoint, 1, 100));
        let records = store.list_checkpoints("native-test");
        assert_eq!(records.len(), 1);
        assert_eq!(records[0].state, "active");
        assert!(store.mark_checkpoint_invalid("native-test", 1));
        let records = store.list_checkpoints("native-test");
        assert_eq!(records[0].state, "invalid");
        std::fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn unavailable_store_is_safe_noop() {
        let mut store = NativeSessionStore { store: None };
        assert!(!store.is_available());
        assert!(store.load_thread("x").is_none());
        assert!(!store.save_thread(&thread()));
        assert!(store.list_checkpoints("x").is_empty());
        assert!(!store.mark_checkpoint_invalid("x", 1));
    }
}
