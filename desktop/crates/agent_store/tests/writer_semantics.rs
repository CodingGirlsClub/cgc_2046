//! 真实临时数据库上的 writer 语义：原子配对、flush 栅栏、清空压过待写快照。
use std::time::Duration;

use cgc_agent_conversation::conversation::{ConversationThread, Entry};
use cgc_agent_core::{SelectedModel, Thread};
use cgc_agent_provider::{ModelId, ProviderId};
use cgc_agent_store::{
    ConversationStore, SavedConversation, SessionStore, SnapshotSource, StoreTarget, StoreWriter,
    WriterCommand,
};

fn temp_root(tag: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("cgc-store-writer-{}-{tag}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn thread(id: &str) -> Thread {
    Thread::new(
        id,
        SelectedModel::new(ProviderId::new("fake"), ModelId::new("m1")),
    )
}

fn conversation(id: &str, text: &str) -> ConversationThread {
    ConversationThread {
        thread_id: id.into(),
        entries: vec![Entry::User { text: text.into() }],
        ..ConversationThread::default()
    }
}

#[test]
fn native_snapshot_and_execution_content_commit_together_and_survive_reopen() {
    let root = temp_root("native");
    let threads_db = root.join("agent/threads.db");
    std::fs::create_dir_all(threads_db.parent().unwrap()).unwrap();
    let writer = StoreWriter::spawn(root.join("conversations.db"), threads_db.clone());

    let mut execution = thread("t1");
    execution.push_user("喂给模型的原文");
    let snapshot = SavedConversation::from_thread(
        &conversation("t1", "展示给用户的气泡"),
        SnapshotSource::Native,
        1,
    );
    assert!(writer.submit(WriterCommand::Snapshot {
        target: StoreTarget::Native,
        thread: Some(Box::new(execution)),
        snapshot: Box::new(snapshot),
    }));
    writer.flush(Duration::from_secs(10)).expect("flush");

    // 重开：执行内容与展示投影都在，且来自同一笔提交。
    let store = SessionStore::open(&threads_db).unwrap();
    let loaded = store.load_thread("t1").unwrap().expect("thread");
    assert!(
        matches!(&loaded.entries[..], [cgc_agent_core::Entry::User { text, .. }] if text == "喂给模型的原文"),
        "执行内容应可读：{:?}",
        loaded.entries
    );
    let restored = store.load_snapshot("t1").unwrap().expect("snapshot");
    assert!(
        matches!(&restored.entries[..], [Entry::User { text }] if text == "展示给用户的气泡"),
        "展示投影必须独立于执行内容"
    );
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn clear_beats_queued_snapshot_and_old_content_never_resurrects() {
    let root = temp_root("clear");
    let threads_db = root.join("agent/threads.db");
    std::fs::create_dir_all(threads_db.parent().unwrap()).unwrap();
    let writer = StoreWriter::spawn(root.join("conversations.db"), threads_db.clone());

    // 先落一版，模拟已存在的历史。
    assert!(writer.submit(WriterCommand::Snapshot {
        target: StoreTarget::Native,
        thread: Some(Box::new(thread("t2"))),
        snapshot: Box::new(SavedConversation::from_thread(
            &conversation("t2", "旧内容"),
            SnapshotSource::Native,
            1,
        )),
    }));
    writer.flush(Duration::from_secs(10)).expect("flush 1");

    // 清空与「清空之后才到达的旧快照」交错：快照必须被丢弃。
    assert!(writer.submit(WriterCommand::Clear {
        target: StoreTarget::Native,
        thread_id: "t2".into(),
    }));
    assert!(writer.submit(WriterCommand::Snapshot {
        target: StoreTarget::Native,
        thread: Some(Box::new(thread("t2"))),
        snapshot: Box::new(SavedConversation::from_thread(
            &conversation("t2", "复活的旧内容"),
            SnapshotSource::Native,
            2,
        )),
    }));
    writer.flush(Duration::from_secs(10)).expect("flush 2");

    let store = SessionStore::open(&threads_db).unwrap();
    assert!(store.load_thread("t2").unwrap().is_none(), "清空后不得复活");
    assert!(
        store.load_snapshot("t2").unwrap().is_none(),
        "快照也不得复活"
    );
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn acp_snapshot_is_additive_and_old_content_still_reads() {
    let root = temp_root("acp");
    let conversations_db = root.join("conversations.db");
    let writer = StoreWriter::spawn(conversations_db.clone(), root.join("agent/threads.db"));
    assert!(writer.submit(WriterCommand::Snapshot {
        target: StoreTarget::Acp,
        thread: None,
        snapshot: Box::new(SavedConversation::from_thread(
            &conversation("a1", "旧 reader 仍应读到的正文"),
            SnapshotSource::Acp,
            1,
        )),
    }));
    writer.flush(Duration::from_secs(10)).expect("flush");

    let mut store = ConversationStore::open(&conversations_db).unwrap();
    // 旧路径（thread_content）保持原样写入与解析。
    let content = conversation("a1", "旧 reader 仍应读到的正文");
    store
        .save_thread(
            &content,
            &cgc_agent_store::SidebarThread {
                thread_id: "a1".into(),
                agent_id: None,
                session_id: None,
                title: None,
                title_override: None,
                created_at: String::new(),
                updated_at: String::new(),
                archived: false,
            },
        )
        .unwrap();
    let old_reader = store.load_content("a1").unwrap().expect("thread_content");
    assert!(matches!(
        &old_reader.entries[..],
        [Entry::User { text }] if text == "旧 reader 仍应读到的正文"
    ));
    let snapshot = store.load_snapshot("a1").unwrap().expect("snapshot");
    assert_eq!(snapshot.revision, 1);
    let _ = std::fs::remove_dir_all(root);
}
