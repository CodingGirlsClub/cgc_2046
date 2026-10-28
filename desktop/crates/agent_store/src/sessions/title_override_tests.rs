use super::*;

fn thread() -> Thread {
    Thread::new(
        "thread-1",
        SelectedModel::new(ProviderId::new("p"), ModelId::new("m")),
    )
}

#[test]
fn thread_title_override_roundtrips() {
    let mut store = SessionStore::open_in_memory().expect("store");
    let mut thread = thread();
    thread.title = Some("Generated".to_string());
    thread.title_override = Some("Custom".to_string());
    store.save_thread(&thread).expect("save");
    let loaded = store
        .load_thread("thread-1")
        .expect("load")
        .expect("thread");
    assert_eq!(loaded.display_title().as_deref(), Some("Custom"));
    let summaries = store.list_threads(10).expect("list");
    assert_eq!(summaries[0].title.as_deref(), Some("Custom"));
}

#[test]
fn thread_agent_and_session_roundtrip() {
    let mut store = SessionStore::open_in_memory().expect("store");
    let mut thread = thread();
    thread.agent = "omp".to_string();
    thread.session_id = Some("sess-1".to_string());
    store.save_thread(&thread).expect("save");
    let loaded = store
        .load_thread("thread-1")
        .expect("load")
        .expect("thread");
    assert_eq!(loaded.agent, "omp");
    assert_eq!(loaded.session_id.as_deref(), Some("sess-1"));
    let summaries = store.list_threads(10).expect("list");
    assert_eq!(summaries[0].agent, "omp");
    assert_eq!(summaries[0].session_id.as_deref(), Some("sess-1"));
}

#[test]
fn thinking_entry_roundtrips() {
    let mut store = SessionStore::open_in_memory().expect("store");
    let mut thread = thread();
    thread.entries.push(Entry::Thinking {
        text: "推理过程".to_string(),
        signature: None,
        at: 1,
    });
    store.save_thread(&thread).expect("save");
    let loaded = store
        .load_thread("thread-1")
        .expect("load")
        .expect("thread");
    assert!(matches!(
        loaded.entries.first(),
        Some(Entry::Thinking { text, .. }) if text == "推理过程"
    ));
}

#[test]
fn legacy_acp_titles_migrate_into_threads() {
    let mut store = SessionStore::open_in_memory().expect("store");
    let mut thread = thread();
    thread.id = "acp-sess-1".to_string();
    store.save_thread(&thread).expect("save");
    store
        .conn
        .execute_batch(
            "CREATE TABLE acp_thread_titles (
                    session_id TEXT PRIMARY KEY,
                    title_override TEXT,
                    updated_at INTEGER NOT NULL
                );",
        )
        .expect("legacy table");
    store
        .conn
        .execute(
            "INSERT INTO acp_thread_titles (session_id, title_override, updated_at)
                 VALUES ('sess-1', 'Legacy Title', 1)",
            [],
        )
        .expect("legacy row");
    store.migrate().expect("migrate");
    let loaded = store
        .load_thread("acp-sess-1")
        .expect("load")
        .expect("thread");
    assert_eq!(loaded.title_override.as_deref(), Some("Legacy Title"));
    let legacy_exists: i64 = store
        .conn
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='acp_thread_titles'",
            [],
            |row| row.get(0),
        )
        .expect("count");
    assert_eq!(legacy_exists, 0);
}
