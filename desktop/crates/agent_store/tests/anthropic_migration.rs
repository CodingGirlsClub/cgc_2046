use cgc_agent_core::{SelectedModel, Thread};
use cgc_agent_provider::{ModelId, ProviderId};
use cgc_agent_store::SessionStore;
use rusqlite::Connection;
use std::{
    sync::{Arc, Barrier},
    thread,
    time::{SystemTime, UNIX_EPOCH},
};

#[test]
fn concurrent_legacy_opens_preserve_history_and_allow_new_saves() {
    let root = std::env::temp_dir().join(format!(
        "cgc-anthropic-migration-{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    std::fs::create_dir_all(&root).unwrap();
    let path = root.join("threads.db");
    let mut original = Thread::new(
        "existing",
        SelectedModel::new(ProviderId::new("review"), ModelId::new("model")),
    );
    original.title = Some("Existing conversation".into());
    original.push_user("Keep this history");
    let mut store = SessionStore::open(&path).unwrap();
    store.save_thread(&original).unwrap();
    drop(store);
    let legacy = Connection::open(&path).unwrap();
    legacy
        .execute("ALTER TABLE threads DROP COLUMN thinking_context_json", [])
        .unwrap();
    drop(legacy);
    let workers = 32;
    let barrier = Arc::new(Barrier::new(workers));
    let handles: Vec<_> = (0..workers)
        .map(|_| {
            let path = path.clone();
            let barrier = barrier.clone();
            thread::spawn(move || {
                barrier.wait();
                let store = SessionStore::open(path)?;
                store.load_thread("existing")
            })
        })
        .collect();
    let restored: Vec<_> = handles
        .into_iter()
        .map(|handle| handle.join().unwrap())
        .collect();
    assert!(
        restored
            .iter()
            .all(|result| matches!(result, Ok(Some(thread)) if thread == &original)),
        "legacy migration must succeed for every concurrent opener: {restored:?}"
    );
    let mut store = SessionStore::open(&path).unwrap();
    let mut new = Thread::new("new", original.model.clone());
    new.push_user("A new conversation after migration");
    store.save_thread(&new).unwrap();
    drop(store);
    let store = SessionStore::open(&path).unwrap();
    assert_eq!(store.load_thread("existing").unwrap(), Some(original));
    assert_eq!(store.load_thread("new").unwrap(), Some(new));
    drop(store);
    std::fs::remove_dir_all(root).unwrap();
}
