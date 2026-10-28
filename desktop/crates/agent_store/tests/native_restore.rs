//! native 旧记录的一次性投影：没有快照时只能从执行内容生成，且必须显式注明
//! 「旧记录不含完整审批历史」，不得伪造审批或计划。
use cgc_agent_core::{SelectedModel, Thread};
use cgc_agent_provider::{ModelId, ProviderId};
use cgc_agent_store::{SavedConversation, SessionStore, SnapshotSource};

fn temp_dir(tag: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("cgc-native-restore-{}-{tag}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn thread() -> Thread {
    Thread::new(
        "legacy-native",
        SelectedModel::new(ProviderId::new("fake"), ModelId::new("m1")),
    )
}

#[test]
fn legacy_execution_thread_projects_once_with_explicit_notice() {
    let root = temp_dir("legacy");
    let path = root.join("threads.db");
    let mut store = SessionStore::open(&path).unwrap();
    let mut execution = thread();
    execution.push_user("用户问题");
    execution.push_assistant("助手回答", Vec::new(), None);

    // 旧版本只写过执行内容，没有快照。
    store.save_thread(&execution).unwrap();
    let (restored_thread, snapshot, from) = store
        .load_restored("legacy-native")
        .unwrap()
        .expect("restore");
    assert_eq!(from, cgc_agent_store::RestoredFrom::Execution);
    assert!(snapshot.is_none(), "旧记录不应被凭空补出快照");
    assert_eq!(restored_thread.id, "legacy-native");

    // 一次性投影：内容来自执行记录，并显式注明缺少审批历史。
    let projected = SavedConversation::from_execution_thread(&execution, 1);
    assert!(matches!(
        projected.entries.first(),
        Some(cgc_agent_conversation::conversation::Entry::Notice {
            level: cgc_agent_conversation::conversation::NoticeLevel::Warning,
            text,
        }) if text.contains("旧记录不含完整审批历史")
    ));
    let restored = projected.into_thread();
    assert!(restored.pending_permission.is_none(), "不得伪造活跃审批");
    assert!(restored.plan.is_empty(), "不得伪造计划");
    assert!(matches!(
        &restored.entries[1..],
        [
            cgc_agent_conversation::conversation::Entry::User { text: question },
            cgc_agent_conversation::conversation::Entry::Assistant { text: answer },
        ] if question == "用户问题" && answer == "助手回答"
    ));
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn snapshot_wins_over_legacy_projection_when_both_exist() {
    let root = temp_dir("both");
    let path = root.join("threads.db");
    let mut store = SessionStore::open(&path).unwrap();
    let mut execution = thread();
    execution.push_user("执行内容");
    let snapshot = SavedConversation::from_thread(
        &cgc_agent_conversation::conversation::ConversationThread {
            thread_id: "legacy-native".into(),
            entries: vec![cgc_agent_conversation::conversation::Entry::User {
                text: "快照内容".into(),
            }],
            ..Default::default()
        },
        SnapshotSource::Native,
        2,
    );
    store
        .save_thread_with_snapshot(&execution, &snapshot)
        .unwrap();

    let (_, loaded, from) = store
        .load_restored("legacy-native")
        .unwrap()
        .expect("restore");
    assert_eq!(from, cgc_agent_store::RestoredFrom::Snapshot);
    assert!(matches!(
        &loaded.expect("snapshot").entries[..],
        [cgc_agent_conversation::conversation::Entry::User { text }] if text == "快照内容"
    ));
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn deleting_a_native_thread_removes_execution_and_snapshot() {
    let root = temp_dir("native-delete");
    let path = root.join("threads.db");
    let mut store = SessionStore::open(&path).unwrap();
    let mut execution = thread();
    execution.push_user("要删除的内容");
    let snapshot = SavedConversation::from_thread(
        &cgc_agent_conversation::conversation::ConversationThread {
            thread_id: "legacy-native".into(),
            entries: vec![cgc_agent_conversation::conversation::Entry::User {
                text: "要删除的内容".into(),
            }],
            ..Default::default()
        },
        SnapshotSource::Native,
        3,
    );
    store
        .save_thread_with_snapshot(&execution, &snapshot)
        .unwrap();
    assert!(store.load_snapshot("legacy-native").unwrap().is_some());

    assert!(store.delete_thread("legacy-native").unwrap());
    assert!(store.load_thread("legacy-native").unwrap().is_none());
    assert!(
        store.load_snapshot("legacy-native").unwrap().is_none(),
        "删除执行内容时投影必须随外键级联清除"
    );
    assert!(store.load_restored("legacy-native").unwrap().is_none());
    let _ = std::fs::remove_dir_all(root);
}

/// 归档不是删除：归档只写 `native_archived`，执行内容与投影都必须保留。
/// 产品有意不提供逐条永久删除（见 `history_row.rs:6`），因此 R3 的断言应测这条契约。
#[test]
fn archiving_keeps_execution_content_and_snapshot() {
    let root = temp_dir("archive");
    let path = root.join("threads.db");
    let mut store = SessionStore::open(&path).unwrap();
    let mut execution = thread();
    execution.push_user("归档后仍应存在");
    let snapshot = SavedConversation::from_thread(
        &cgc_agent_conversation::conversation::ConversationThread {
            thread_id: "legacy-native".into(),
            entries: vec![cgc_agent_conversation::conversation::Entry::User {
                text: "归档后仍应存在".into(),
            }],
            ..Default::default()
        },
        SnapshotSource::Native,
        4,
    );
    store
        .save_thread_with_snapshot(&execution, &snapshot)
        .unwrap();

    // 归档标记在 conversations.db 的 native_archived 表，与 threads.db 无关。
    let conversations_path = root.join("conversations.db");
    let conversations = cgc_agent_store::ConversationStore::open(&conversations_path).unwrap();
    conversations
        .set_native_archived("legacy-native", true)
        .unwrap();

    assert!(store.load_thread("legacy-native").unwrap().is_some());
    assert!(
        store.load_snapshot("legacy-native").unwrap().is_some(),
        "归档不是删除，投影必须保留"
    );
    assert!(conversations
        .archived_native_threads()
        .unwrap()
        .contains(&"legacy-native".to_string()));
    let _ = std::fs::remove_dir_all(root);
}
