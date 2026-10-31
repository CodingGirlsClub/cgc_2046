use super::*;
use cgc_agent_provider::ToolUse;

fn model() -> SelectedModel {
    SelectedModel::new(ProviderId::new("fake"), ModelId::new("m1"))
}

fn sample_thread() -> Thread {
    let mut thread = Thread::new("t1", model());
    thread.title = Some("第一课".to_string());
    thread.push_user("你好");
    thread.push_assistant(
        "你好呀",
        vec![ToolUse {
            id: "call_1".into(),
            name: "read_file".into(),
            args: serde_json::json!({"path": "a.txt"}),
        }],
        Some(TokenUsage {
            input: 10,
            output: 2,
            ..TokenUsage::default()
        }),
    );
    thread.push_tool_result("call_1", "read_file", "hello", false);
    thread.usage_total.input = 10;
    thread.usage_total.output = 2;
    thread
}

#[test]
fn save_then_load_roundtrip() {
    let mut store = SessionStore::open_in_memory().expect("store");
    let thread = sample_thread();
    store.save_thread(&thread).expect("save");
    let loaded = store.load_thread("t1").expect("load").expect("present");
    assert_eq!(loaded, thread);
}

#[test]
fn scope_selection_survives_late_saves_and_keeps_empty_current_thread() {
    let mut store = SessionStore::open_in_memory().unwrap();
    let original = sample_thread();
    let empty = Thread::new("new-empty-thread", model());
    store.activate_scope_thread("scope-a", &original).unwrap();
    store.activate_scope_thread("scope-a", &empty).unwrap();
    store.save_thread(&original).unwrap();
    assert_eq!(store.load_scope_thread("scope-a").unwrap().unwrap(), empty);
    store
        .activate_scope_thread("scope-b", &Thread::new("other", model()))
        .unwrap();
    assert_eq!(
        store.load_scope_thread("scope-a").unwrap().unwrap().id,
        empty.id
    );
    store.activate_scope_thread("scope-a", &original).unwrap();
    assert_eq!(
        store.load_scope_thread("scope-a").unwrap().unwrap(),
        original
    );
    store.delete_thread(&original.id).unwrap();
    assert!(store.load_scope_thread("scope-a").unwrap().is_none());
}

#[test]
fn save_is_idempotent_and_updates_entries() {
    let mut store = SessionStore::open_in_memory().expect("store");
    let mut thread = sample_thread();
    store.save_thread(&thread).expect("save");
    thread.push_user("再问一句");
    store.save_thread(&thread).expect("save again");
    let loaded = store.load_thread("t1").expect("load").expect("present");
    assert_eq!(loaded.entries.len(), 4);
}

#[test]
fn list_threads_orders_by_updated_at() {
    let mut store = SessionStore::open_in_memory().expect("store");
    let mut older = sample_thread();
    older.id = "older".into();
    older.updated_at = 10;
    let mut newer = sample_thread();
    newer.id = "newer".into();
    newer.updated_at = 20;
    store.save_thread(&older).expect("older");
    store.save_thread(&newer).expect("newer");
    let summaries = store.list_threads(10).expect("list");
    assert_eq!(summaries[0].id, "newer");
    assert_eq!(summaries[1].id, "older");
    assert_eq!(summaries[0].title.as_deref(), Some("第一课"));
}

#[test]
fn delete_thread_cascades_entries() {
    let mut store = SessionStore::open_in_memory().expect("store");
    let thread = sample_thread();
    store.save_thread(&thread).expect("save");
    assert!(store.delete_thread("t1").expect("delete"));
    assert!(store.load_thread("t1").expect("load").is_none());
    assert!(!store.delete_thread("t1").expect("delete missing"));
}

#[test]
fn checkpoint_mapping_roundtrip_and_invalidation() {
    let mut store = SessionStore::open_in_memory().expect("store");
    let thread = sample_thread();
    store.save_thread(&thread).expect("save thread");
    let checkpoint = cgc_agent_checkpoint::Checkpoint {
        thread_id: "t1".into(),
        seq: 1,
        ref_name: "refs/cgc/checkpoints/t1/1".into(),
        sha: "abc123".into(),
        base_head: None,
    };
    store.save_checkpoint(&checkpoint, 1, 100).expect("save cp");
    let listed = store.list_checkpoints("t1").expect("list");
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].sha, "abc123");
    assert_eq!(listed[0].state, "active");
    assert!(store.mark_checkpoint_invalid("t1", 1).expect("invalidate"));
    assert_eq!(
        store.list_checkpoints("t1").expect("list")[0].state,
        "invalid"
    );
}

#[test]
fn compaction_entries_roundtrip() {
    let mut store = SessionStore::open_in_memory().expect("store");
    let mut thread = sample_thread();
    thread.entries.push(
        serde_json::from_value(serde_json::json!({
            "Compaction": { "summary": "历史摘要内容", "replaced_entries": 12, "at": 0 }
        }))
        .expect("legacy compaction"),
    );
    store.save_thread(&thread).expect("save");
    let loaded = store.load_thread("t1").expect("load").expect("present");
    assert!(loaded.entries.iter().any(
        |entry| matches!(entry, Entry::Compaction { summary, .. } if summary == "历史摘要内容")
    ));
    assert!(loaded
        .messages()
        .iter()
        .any(|message| message.text() == "你好"));
    assert!(
        !loaded
            .messages()
            .iter()
            .any(|message| message.text().contains("历史摘要内容")),
        "legacy counts cannot authorize dropping the raw prefix"
    );
}

#[test]
fn covered_prefix_survives_storage_and_is_not_resent_on_continuation() {
    use cgc_agent_core::Agent;
    use cgc_agent_provider::{FakeProvider, Model, ModelLimits};
    use std::{
        future::Future,
        task::{Context, Poll, Waker},
    };
    let mut store = SessionStore::open_in_memory().unwrap();
    let mut thread = sample_thread();
    thread.entries.push(
        serde_json::from_value(serde_json::json!({
            "Compaction": {
                "summary": "学习 Rust 所有权。", "replaced_entries": 3,
                "covered_until": 3, "at": 0
            }
        }))
        .unwrap(),
    );
    store.save_thread(&thread).unwrap();
    let restored = store.load_thread("t1").unwrap().unwrap();
    let model = Model::new(
        ProviderId::new("fake"),
        "Fake",
        "m1",
        "m1",
        ModelLimits::new(8_000, 1_000),
    );
    let provider = FakeProvider::new(ProviderId::new("fake"), "Fake", vec![model.clone()]);
    let mut agent = Agent::new(restored, None);
    let mut turn = Box::pin(agent.prompt(&provider, &model, "继续"));
    // FakeProvider is immediately ready; no production executor or dependency is needed.
    assert!(matches!(
        turn.as_mut().poll(&mut Context::from_waker(Waker::noop())),
        Poll::Ready(Ok(_))
    ));
    let requests = provider.requests();
    let main = requests.last().unwrap();
    assert!(main
        .messages
        .iter()
        .any(|message| message.text().contains("学习 Rust 所有权。")));
    assert!(main.messages.iter().any(|message| message.text() == "继续"));
    assert!(!main.messages.iter().any(|message| message.text() == "你好"));
    assert!(!main
        .messages
        .iter()
        .flat_map(|message| &message.content)
        .any(|content| matches!(content, cgc_agent_provider::Content::ToolUse(_))));
}

#[test]
fn missing_thread_returns_none() {
    let store = SessionStore::open_in_memory().expect("store");
    assert!(store.load_thread("nope").expect("load").is_none());
}
