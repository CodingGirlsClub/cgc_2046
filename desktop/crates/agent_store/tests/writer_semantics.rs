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

#[test]
fn restore_prefers_snapshot_and_falls_back_to_legacy_content() {
    let root = temp_root("restore");
    let path = root.join("conversations.db");
    let mut store = ConversationStore::open(&path).unwrap();
    let sidebar = |id: &str| cgc_agent_store::SidebarThread {
        thread_id: id.into(),
        agent_id: None,
        session_id: None,
        title: None,
        title_override: None,
        created_at: String::new(),
        updated_at: String::new(),
        archived: false,
    };

    // 只有旧内容的记录：退回 LegacyContent，内容可读。
    store
        .save_thread(&conversation("legacy", "旧记录正文"), &sidebar("legacy"))
        .unwrap();
    let (restored, source) = store.load_restored("legacy").unwrap().expect("legacy");
    assert_eq!(source, cgc_agent_store::RestoredFrom::LegacyContent);
    assert!(matches!(&restored.entries[..], [Entry::User { text }] if text == "旧记录正文"));

    // 有快照的记录：优先快照，且恢复后没有活跃审批。
    store
        .save_thread(&conversation("both", "旧正文"), &sidebar("both"))
        .unwrap();
    store
        .save_snapshot(&SavedConversation::from_thread(
            &conversation("both", "快照正文"),
            SnapshotSource::Acp,
            1,
        ))
        .unwrap();
    let (restored, source) = store.load_restored("both").unwrap().expect("both");
    assert_eq!(source, cgc_agent_store::RestoredFrom::Snapshot);
    assert!(matches!(&restored.entries[..], [Entry::User { text }] if text == "快照正文"));
    assert!(restored.pending_permission.is_none());

    assert!(store.load_restored("missing").unwrap().is_none());
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn out_of_order_revisions_never_overwrite_a_newer_snapshot() {
    let root = temp_root("revision");
    let path = root.join("conversations.db");
    let mut store = ConversationStore::open(&path).unwrap();
    let snapshot = |revision: u64, text: &str| {
        SavedConversation::from_thread(&conversation("r1", text), SnapshotSource::Acp, revision)
    };
    store.save_snapshot(&snapshot(5, "新版本")).unwrap();
    // 迟到的旧回调：不得覆盖更新的内容。
    store.save_snapshot(&snapshot(4, "迟到的旧版本")).unwrap();
    let loaded = store.load_snapshot("r1").unwrap().expect("snapshot");
    assert_eq!(loaded.revision, 5);
    assert!(matches!(&loaded.entries[..], [Entry::User { text }] if text == "新版本"));
    // 更新的 revision 仍然可以推进。
    store.save_snapshot(&snapshot(6, "再新一版")).unwrap();
    let loaded = store.load_snapshot("r1").unwrap().expect("snapshot");
    assert_eq!(loaded.revision, 6);
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn deleting_a_thread_removes_its_snapshot_too() {
    let root = temp_root("delete");
    let path = root.join("conversations.db");
    let mut store = ConversationStore::open(&path).unwrap();
    let sidebar = cgc_agent_store::SidebarThread {
        thread_id: "d1".into(),
        agent_id: None,
        session_id: None,
        title: None,
        title_override: None,
        created_at: String::new(),
        updated_at: String::new(),
        archived: false,
    };
    store
        .save_thread(&conversation("d1", "正文"), &sidebar)
        .unwrap();
    store
        .save_snapshot(&SavedConversation::from_thread(
            &conversation("d1", "正文"),
            SnapshotSource::Acp,
            1,
        ))
        .unwrap();
    assert!(store.delete_thread("d1").unwrap());

    // 删除后不得从投影复活：否则删掉的历史会被快照重新读出来。
    assert!(store.load_restored("d1").unwrap().is_none());
    assert!(store.load_snapshot("d1").unwrap().is_none());
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn a_snapshot_written_after_deletion_cannot_resurrect_history() {
    let root = temp_root("late");
    let path = root.join("conversations.db");
    let mut store = ConversationStore::open(&path).unwrap();
    let sidebar = cgc_agent_store::SidebarThread {
        thread_id: "late1".into(),
        agent_id: None,
        session_id: None,
        title: None,
        title_override: None,
        created_at: String::new(),
        updated_at: String::new(),
        archived: false,
    };
    store
        .save_thread(&conversation("late1", "已删除正文"), &sidebar)
        .unwrap();
    assert!(store.delete_thread("late1").unwrap());

    // 删除之后才到达的投影写入（延迟保存/竞态）：不得让历史复活。
    store
        .save_snapshot(&SavedConversation::from_thread(
            &conversation("late1", "迟到的投影"),
            SnapshotSource::Acp,
            9,
        ))
        .unwrap();
    assert!(
        store.load_restored("late1").unwrap().is_none(),
        "没有正文与侧栏的孤儿投影不得被读成历史"
    );
    let _ = std::fs::remove_dir_all(root);
}
