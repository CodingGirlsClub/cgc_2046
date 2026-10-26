//! Stage 3.3b e2e：统一历史（native + ACP）的自动归档、Rename/Archive/Unarchive、
//! Archive 分桶与设置清空后的刷新信号（CGC_DATA_DIR 指向临时目录，不碰真实数据）。

use std::ffi::OsString;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use cgc_agent_store::SessionStore;
use cgc_agent_ui::conversation::{ConversationThread, Entry};
use cgc_desktop_app::acp_history::{
    self, group_archive, main_list, merge_history, RECENT_PER_AGENT,
};

struct DataDirGuard {
    previous: Option<OsString>,
    dir: PathBuf,
}

impl DataDirGuard {
    fn new(tag: &str) -> Self {
        let serial = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|duration| duration.as_nanos())
            .unwrap_or_default();
        let dir = std::env::temp_dir().join(format!(
            "cgc-history-archive-{}-{tag}-{serial}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("data dir");
        let previous = std::env::var_os("CGC_DATA_DIR");
        std::env::set_var("CGC_DATA_DIR", &dir);
        Self { previous, dir }
    }
}

impl Drop for DataDirGuard {
    fn drop(&mut self) {
        match &self.previous {
            Some(value) => std::env::set_var("CGC_DATA_DIR", value),
            None => std::env::remove_var("CGC_DATA_DIR"),
        }
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn now_epoch() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs() as i64)
        .unwrap_or_default()
}

fn saved_thread() -> ConversationThread {
    let mut thread = ConversationThread::new("acp");
    thread.apply(cgc_agent_ui::conversation::ThreadEvent::TurnStarted {
        user_text: "hello".to_string(),
    });
    thread.apply(cgc_agent_ui::conversation::ThreadEvent::TextDelta(
        "hi".to_string(),
    ));
    thread.entries.push(Entry::User {
        text: "hello".to_string(),
    });
    thread
}

#[test]
fn unified_history_auto_archive_rename_unarchive_and_clear() {
    let _guard = DataDirGuard::new("all");
    let base = now_epoch();
    let paths = cgc_platform::paths::AppPaths::from_env();

    // ---- 造数据：7 条 ACP（omp）+ 6 条 native ----
    let mut acp_store =
        cgc_agent_store::ConversationStore::open(paths.data_root.join("conversations.db"))
            .expect("acp store");
    let thread = saved_thread();
    for index in 0..7 {
        let session_id = format!("sess-{index}");
        // 制造跨桶数据：最旧 2 条分别落在「更早」(10 天前) 与「最近 7 天」
        // (3 天前)；每 agent 保留最近 5 条 → 归档最旧 2 条。
        let offset_days = [10_i64, 3, 2, 1, 0, 0, 0][index];
        let updated_at = cgc_agent_store::format_epoch_rfc3339(base - offset_days * 86_400);
        acp_history::save_transcript(
            &mut acp_store,
            &thread,
            &session_id,
            "omp",
            None,
            &updated_at,
        )
        .expect("save acp transcript");
    }
    let mut thread = thread;
    thread.title = Some("native 线程".to_string());
    let mut native_store =
        SessionStore::open(paths.data_root.join("agent").join("threads.db")).expect("native store");
    for index in 0..6 {
        let mut native = cgc_agent_core::Thread::new(
            format!("native-{index}"),
            cgc_agent_core::SelectedModel::new(
                cgc_agent_provider::ProviderId::new("acp"),
                cgc_agent_provider::ModelId::new("native"),
            ),
        );
        native.agent = "native".to_string();
        native.updated_at = base - (6 - index) as i64;
        native.entries = vec![cgc_agent_core::Entry::User {
            text: format!("native {index}"),
            images: Vec::new(),
            display: None,
            at: native.updated_at,
        }];
        native_store.save_thread(&native).expect("save native");
    }

    // ---- 自动归档：每个 agent 保留最近 N（幂等） ----
    assert_eq!(
        acp_history::auto_archive_recent(RECENT_PER_AGENT),
        2,
        "omp 7 条 → 归档最旧 2 条"
    );
    assert_eq!(
        acp_history::auto_archive_recent(RECENT_PER_AGENT),
        0,
        "幂等"
    );

    // ---- 统一列表：ACP active 5（含 archived 全量）+ native 6 ----
    let native = native_store.list_threads(50).expect("native list");
    let acp = acp_store.list_all(200).expect("acp list");
    let merged = merge_history(native, acp);
    let listed = main_list(&merged, RECENT_PER_AGENT);
    assert_eq!(
        listed
            .iter()
            .filter(|e| e.agent_label() == "native")
            .count(),
        6
    );
    assert_eq!(
        listed.iter().filter(|e| e.agent_label() == "omp").count(),
        RECENT_PER_AGENT,
        "主列表每个 ACP agent 只保留最近 N 条"
    );
    let archived = acp_history::archive_entries(&merged);
    assert_eq!(archived.len(), 2, "更早的 ACP 记录自动归档");
    // Archive 不是删除：内容仍可离线读。
    assert!(acp_store
        .load_content(&archived[0].thread_id)
        .expect("content")
        .is_some());
    // Archive 视图按时间分桶（昨天/最近 7 天/更早）。
    let now = acp_history::now_local();
    let groups = group_archive(&merged, &now);
    assert_eq!(
        groups
            .iter()
            .map(|(bucket, _)| bucket.label())
            .collect::<Vec<_>>(),
        vec!["最近 7 天", "更早"],
        "7 天前的 2 条落在最近 7 天/更早桶"
    );

    // ---- Rename：override 优先，后续生成标题保存不覆盖；清除后回落 ----
    let rename_target = merged
        .iter()
        .find(|entry| entry.agent_label() == "omp" && !entry.archived)
        .expect("rename target")
        .thread_id
        .clone();
    assert!(acp_history::rename_override(
        &rename_target,
        Some("用户改名")
    ));
    acp_history::save_transcript(
        &mut acp_store,
        &thread,
        rename_target.trim_start_matches("acp-"),
        "omp",
        None,
        &cgc_agent_store::format_epoch_rfc3339(base),
    )
    .expect("save generated title");
    let renamed = acp_store
        .load_sidebar(&rename_target)
        .expect("load")
        .expect("row");
    assert_eq!(renamed.display_title(), Some("用户改名"));
    acp_history::rename_override(&rename_target, None);
    let cleared = acp_store
        .load_sidebar(&rename_target)
        .expect("load")
        .expect("row");
    assert_ne!(cleared.display_title(), Some("用户改名"));

    // ---- Archive / Unarchive：主列表消失/恢复，内容都在 ----
    assert!(acp_history::archive_thread(&rename_target));
    let merged = merge_history(
        native_store.list_threads(50).expect("native"),
        acp_store.list_all(200).expect("acp"),
    );
    assert!(
        !main_list(&merged, RECENT_PER_AGENT)
            .iter()
            .any(|entry| entry.thread_id == rename_target),
        "归档后从主列表消失"
    );
    assert!(acp_history::unarchive_thread(&rename_target));
    let merged = merge_history(
        native_store.list_threads(50).expect("native"),
        acp_store.list_all(200).expect("acp"),
    );
    assert!(
        main_list(&merged, RECENT_PER_AGENT)
            .iter()
            .any(|entry| entry.thread_id == rename_target),
        "Unarchive 后回主列表"
    );

    // ---- native 行也可归档：标记存 conversations.db.native_archived，
    //      threads.db schema 不变；主列表消失、Archive 视图可见、可 Unarchive ----
    let native_archived_id = "native-0".to_string();
    assert!(
        acp_history::archive_thread(&native_archived_id),
        "native 归档应成功（写 native_archived 表）"
    );
    let archived_native = acp_store
        .archived_native_threads()
        .expect("native archived");
    assert!(archived_native.contains(&native_archived_id));
    let merged_native = acp_history::merge_history_with_native_archived(
        native_store.list_threads(50).expect("native"),
        acp_store.list_all(200).expect("acp"),
        &archived_native,
    );
    assert!(
        main_list(&merged_native, RECENT_PER_AGENT)
            .iter()
            .all(|entry| entry.thread_id != native_archived_id),
        "归档的 native 行从主列表消失"
    );
    assert_eq!(
        acp_history::archive_entries(&merged_native)
            .iter()
            .filter(|entry| entry.thread_id == native_archived_id)
            .count(),
        1,
        "归档的 native 行出现在 Archive 视图"
    );
    assert!(acp_history::unarchive_thread(&native_archived_id));
    assert!(acp_store
        .archived_native_threads()
        .expect("native archived")
        .is_empty());

    // 再归档一次用于验证「清空 ACP 历史不清 native 归档标记」。
    assert!(acp_history::archive_thread(&native_archived_id));

    // ---- 清空：dirty/cleared 世代号推进，ACP 历史为空、native 不受影响 ----
    let dirty_before = acp_history::history_dirty_generation();
    let cleared_before = acp_history::history_cleared_generation();
    assert_eq!(acp_history::clear_acp_history(), 7);
    assert!(
        acp_history::history_dirty_generation() > dirty_before,
        "清空必须推进全局 dirty 世代号，RootView 据此刷新缓存列表"
    );
    assert!(acp_history::history_cleared_generation() > cleared_before);
    let merged = merge_history(
        native_store.list_threads(50).expect("native"),
        acp_store.list_all(200).expect("acp"),
    );
    assert!(
        merged.iter().all(|entry| entry.agent_label() != "omp"),
        "清空后 ACP 记录为 0"
    );
    assert_eq!(
        merged
            .iter()
            .filter(|e| e.agent_label() == "native")
            .count(),
        6,
        "native threads.db 不受清空影响"
    );
    assert_eq!(acp_history::auto_archive_recent(RECENT_PER_AGENT), 0);
    // 清空 ACP 历史只清 conversations.db 的 ACP 行，native 归档标记保留。
    let archived_native = acp_store
        .archived_native_threads()
        .expect("native archived");
    assert!(
        archived_native.contains(&native_archived_id),
        "清空 ACP 历史不得清掉 native 归档标记"
    );
    let merged_native = acp_history::merge_history_with_native_archived(
        native_store.list_threads(50).expect("native"),
        acp_store.list_all(200).expect("acp"),
        &archived_native,
    );
    assert!(main_list(&merged_native, RECENT_PER_AGENT)
        .iter()
        .all(|entry| entry.thread_id != native_archived_id));
    acp_history::unarchive_thread(&native_archived_id);
}
