//! ACP 历史 / 标题 / 恢复降级的 app 层逻辑（Stage 3.3）。
//!
//! 可纯函数化的部分（历史合并、标题 fallback、resume 降级判定）放这里单测；
//! 存储由 `cgc_agent_store::ConversationStore`（`conversations.db`）承担。
//! native 既有 `agent/threads.db` 的 schema/内容不动：native 历史仍从
//! `SessionStore` 读，ACP 历史从 `ConversationStore` 读，再在这里合并成统一列表。

use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

use cgc_agent_store::{
    ConversationStore, ConversationStoreError, SidebarThread, ThreadSummary, CONVERSATIONS_DB,
};
use cgc_agent_ui::conversation::{ConversationThread, Entry};
use chrono::{DateTime, Local};

/// ACP 历史 thread_id 前缀（`acp-<session_id>`，沿用旧统一列表约定）。
pub const ACP_THREAD_PREFIX: &str = "acp-";
/// agent 历史回放不可用时的降级提示（Zed `resumed_without_history` 语义）。
pub const RESUMED_WITHOUT_HISTORY: &str = "外部 agent 无法恢复会话，以下为本地记录";
/// 主列表每个 agent 保留的最近条数（更早的自动归档，对应 Zed auto-archive）。
/// 可改：改这里即可调整保留窗口（测试通过传参验证边界）。
pub const RECENT_PER_AGENT: usize = 5;

/// 全局历史脏标记：任何窗口（设置清空、归档、重命名）改库后递增；
/// RootView 在渲染/轮询时发现变化即重载统一历史。
static HISTORY_DIRTY_GENERATION: AtomicU64 = AtomicU64::new(0);
/// 永久清空（Settings）专属世代号：RootView 据此判断"清掉的正是当前会话"。
static HISTORY_CLEARED_GENERATION: AtomicU64 = AtomicU64::new(0);

pub fn mark_history_dirty() {
    HISTORY_DIRTY_GENERATION.fetch_add(1, Ordering::Relaxed);
}

pub fn history_cleared_generation() -> u64 {
    HISTORY_CLEARED_GENERATION.load(Ordering::Relaxed)
}

pub fn history_dirty_generation() -> u64 {
    HISTORY_DIRTY_GENERATION.load(Ordering::Relaxed)
}

/// 测试隔离用：把脏计数推进到指定值之后（不重置，避免跨测试串扰）。
pub fn history_dirty_generation_for_test() -> u64 {
    history_dirty_generation()
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HistorySource {
    Native,
    Acp,
}

/// 统一历史列表条目（native + ACP 合并后）。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HistoryEntry {
    pub thread_id: String,
    pub session_id: Option<String>,
    pub agent_id: Option<String>,
    /// 展示标题（ACP override 优先；native 已是 COALESCE(override,title)）。
    pub title: Option<String>,
    pub updated_at: String,
    /// 归档标记（仅 ACP 可归档；native 恒 false）。
    pub archived: bool,
    pub source: HistorySource,
}

impl HistoryEntry {
    /// 列表里的 agent 标签（native / omp / codex …）。
    pub fn agent_label(&self) -> &str {
        match self.source {
            HistorySource::Native => "native",
            HistorySource::Acp => self.agent_id.as_deref().unwrap_or("external"),
        }
    }
}

pub fn acp_thread_id(session_id: &str) -> String {
    format!("{ACP_THREAD_PREFIX}{session_id}")
}

pub fn session_id_from_thread_id(thread_id: &str) -> Option<&str> {
    thread_id.strip_prefix(ACP_THREAD_PREFIX)
}

/// `conversations.db` 路径（`<data_root>/conversations.db`）。
pub fn conversations_db_path() -> PathBuf {
    cgc_platform::paths::AppPaths::from_env()
        .data_root
        .join(CONVERSATIONS_DB)
}

pub fn open_conversation_store() -> Result<ConversationStore, ConversationStoreError> {
    ConversationStore::open(conversations_db_path())
}

/// 线程展示标题：agent 生成标题优先；没有则首条用户消息截断（fallback）。
pub fn thread_display_title(thread: &ConversationThread) -> Option<String> {
    let generated = thread
        .title
        .as_deref()
        .map(clean_title)
        .filter(|title| !title.is_empty());
    generated.or_else(|| {
        thread.entries.iter().find_map(|entry| match entry {
            Entry::User { text } => {
                let title = clean_title(&truncate_chars(text, 30));
                (!title.is_empty()).then_some(title)
            }
            _ => None,
        })
    })
}

/// 标题清洗：折叠空白、截断（列表展示用）。
pub fn clean_title(text: &str) -> String {
    let collapsed = text.split_whitespace().collect::<Vec<_>>().join(" ");
    truncate_chars(&collapsed, 60)
}

fn truncate_chars(text: &str, max_chars: usize) -> String {
    let mut chars = text.chars();
    let truncated: String = chars.by_ref().take(max_chars).collect();
    if chars.next().is_some() {
        format!("{truncated}…")
    } else {
        truncated
    }
}

/// 构造要落库的 sidebar metadata；`created_at` 沿用已有记录（不重置），
/// `title_override` 只在调用方显式提供时传递（生成标题保存不会清掉 override）。
pub fn sidebar_for_save(
    thread: &ConversationThread,
    session_id: &str,
    agent_id: &str,
    title_override: Option<&str>,
    existing: Option<&SidebarThread>,
    now: &str,
) -> SidebarThread {
    let thread_id = acp_thread_id(session_id);
    SidebarThread {
        thread_id,
        agent_id: Some(agent_id.to_string()),
        session_id: Some(session_id.to_string()),
        title: thread_display_title(thread),
        title_override: title_override.map(str::to_string),
        created_at: existing
            .map(|existing| existing.created_at.clone())
            .filter(|created| !created.is_empty())
            .unwrap_or_else(|| now.to_string()),
        updated_at: now.to_string(),
        archived: existing.map(|existing| existing.archived).unwrap_or(false),
    }
}

/// 保存 ACP transcript（内容 + metadata 同一事务）。
pub fn save_transcript(
    store: &mut ConversationStore,
    thread: &ConversationThread,
    session_id: &str,
    agent_id: &str,
    title_override: Option<&str>,
    now: &str,
) -> Result<SidebarThread, ConversationStoreError> {
    let thread_id = acp_thread_id(session_id);
    let existing = store.load_sidebar(&thread_id)?;
    let sidebar = sidebar_for_save(
        thread,
        session_id,
        agent_id,
        title_override,
        existing.as_ref(),
        now,
    );
    store.save_thread(thread, &sidebar)?;
    Ok(sidebar)
}

/// 读取本地 transcript（离线可读）；无/损坏返回 `None`。
///
/// 优先用可恢复投影：未答审批在投影里已降级为失效记录，重开后不会出现
/// 可点击但已无主的 Allow。旧记录没有投影时退回 `thread_content`。
pub fn load_local_transcript(thread_id: &str) -> Option<ConversationThread> {
    let store = open_conversation_store().ok()?;
    store
        .load_restored(thread_id)
        .ok()
        .flatten()
        .map(|(thread, _source)| thread)
}

pub fn load_local_sidebar(thread_id: &str) -> Option<SidebarThread> {
    let store = open_conversation_store().ok()?;
    store.load_sidebar(thread_id).ok().flatten()
}

pub fn delete_local_transcript(thread_id: &str) -> bool {
    open_conversation_store()
        .ok()
        .map(|store| store.delete_thread(thread_id).unwrap_or(false))
        .unwrap_or(false)
}

/// 清空全部 ACP 历史（只动 conversations.db，不碰 native threads.db）。
/// 清空后推进 dirty/cleared 世代号，RootView 下一帧刷新列表并处理当前会话。
pub fn clear_acp_history() -> usize {
    let removed = open_conversation_store()
        .ok()
        .and_then(|store| store.clear_all().ok())
        .unwrap_or(0);
    HISTORY_CLEARED_GENERATION.fetch_add(1, Ordering::Relaxed);
    mark_history_dirty();
    removed
}

/// 合并 native（threads.db）与 ACP（conversations.db）历史，按 updated_at 倒序。
pub fn merge_history(
    native_threads: Vec<ThreadSummary>,
    acp_threads: Vec<SidebarThread>,
) -> Vec<HistoryEntry> {
    merge_history_with_native_archived(native_threads, acp_threads, &Default::default())
}

/// 同 [`merge_history`]，额外带上 native 线程的归档标记（threads.db schema 不变，
/// 标记存在 conversations.db.native_archived）。
pub fn merge_history_with_native_archived(
    native_threads: Vec<ThreadSummary>,
    acp_threads: Vec<SidebarThread>,
    native_archived: &std::collections::HashSet<String>,
) -> Vec<HistoryEntry> {
    let mut entries: Vec<HistoryEntry> = native_threads
        .into_iter()
        .filter(|thread| thread.agent == "native")
        .map(|thread| {
            let archived = native_archived.contains(&thread.id);
            HistoryEntry {
                thread_id: thread.id,
                session_id: thread.session_id,
                agent_id: Some(thread.agent),
                title: thread.title,
                updated_at: cgc_agent_store::format_epoch_rfc3339(thread.updated_at),
                archived,
                source: HistorySource::Native,
            }
        })
        .chain(acp_threads.into_iter().map(|thread| {
            let title = thread
                .display_title()
                .map(str::to_string)
                .or_else(|| thread.title.clone());
            HistoryEntry {
                thread_id: thread.thread_id,
                session_id: thread.session_id,
                agent_id: thread.agent_id,
                title,
                updated_at: thread.updated_at,
                archived: thread.archived,
                source: HistorySource::Acp,
            }
        }))
        .collect();
    entries.sort_by(|left, right| {
        right
            .updated_at
            .cmp(&left.updated_at)
            .then_with(|| right.thread_id.cmp(&left.thread_id))
    });
    entries
}

/// 主列表：ACP 每个 agent 只保留最近 `keep_per_agent` 条（更早自动归档）；
/// native 不自动截断（threads.db 无 archived 列，手动归档的会从主列表消失）。
pub fn main_list(entries: &[HistoryEntry], keep_per_agent: usize) -> Vec<HistoryEntry> {
    let mut acp_seen: std::collections::BTreeMap<String, usize> = std::collections::BTreeMap::new();
    entries
        .iter()
        .filter(|entry| !entry.archived)
        .filter(|entry| match entry.source {
            HistorySource::Native => true,
            HistorySource::Acp => {
                let agent = entry.agent_id.clone().unwrap_or_default();
                let count = acp_seen.entry(agent).or_insert(0);
                *count += 1;
                *count <= keep_per_agent
            }
        })
        .cloned()
        .collect()
}

/// 归档视图条数（含 archived）。
pub fn archive_entries(entries: &[HistoryEntry]) -> Vec<HistoryEntry> {
    entries
        .iter()
        .filter(|entry| entry.archived)
        .cloned()
        .collect()
}

/// 标题/agent/thread_id 子串过滤（大小写不敏感）。
pub fn filter_history(entries: Vec<HistoryEntry>, query: &str) -> Vec<HistoryEntry> {
    let query = query.trim().to_lowercase();
    if query.is_empty() {
        return entries;
    }
    entries
        .into_iter()
        .filter(|entry| {
            let title = entry.title.as_deref().unwrap_or("").to_lowercase();
            let agent = entry.agent_label().to_lowercase();
            title.contains(&query)
                || agent.contains(&query)
                || entry.thread_id.to_lowercase().contains(&query)
        })
        .collect()
}

/// 相对时间标签：`now` / `2m` / `2h` / `1d`（Zed 侧栏样式）。
pub fn relative_time_label(updated_at: &str, now: &DateTime<Local>) -> String {
    let Ok(then) = DateTime::parse_from_rfc3339(updated_at) else {
        return String::new();
    };
    let seconds = now.timestamp() - then.timestamp();
    if seconds < 0 {
        return "now".to_string();
    }
    if seconds < 60 {
        "now".to_string()
    } else if seconds < 3_600 {
        format!("{}m", seconds / 60)
    } else if seconds < 86_400 {
        format!("{}h", seconds / 3_600)
    } else {
        format!("{}d", seconds / 86_400)
    }
}

/// 归档视图分桶（Zed：今天 / 昨天 / 最近 7 天 / 更早）。
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum ArchiveBucket {
    Today,
    Yesterday,
    Last7Days,
    Earlier,
}

impl ArchiveBucket {
    pub fn label(self) -> &'static str {
        match self {
            ArchiveBucket::Today => "今天",
            ArchiveBucket::Yesterday => "昨天",
            ArchiveBucket::Last7Days => "最近 7 天",
            ArchiveBucket::Earlier => "更早",
        }
    }
}

pub fn archive_bucket(updated_at: &str, now: &DateTime<Local>) -> Option<ArchiveBucket> {
    let then = DateTime::parse_from_rfc3339(updated_at).ok()?;
    let then_local = then.with_timezone(&Local);
    let days = (now.date_naive() - then_local.date_naive()).num_days();
    Some(if days <= 0 {
        ArchiveBucket::Today
    } else if days == 1 {
        ArchiveBucket::Yesterday
    } else if days <= 7 {
        ArchiveBucket::Last7Days
    } else {
        ArchiveBucket::Earlier
    })
}

/// 归档视图：按桶分组（跳过空桶），组内按 updated_at 倒序。
pub fn group_archive(
    entries: &[HistoryEntry],
    now: &DateTime<Local>,
) -> Vec<(ArchiveBucket, Vec<HistoryEntry>)> {
    let mut buckets: Vec<(ArchiveBucket, Vec<HistoryEntry>)> = Vec::new();
    for entry in entries.iter().filter(|entry| entry.archived) {
        let Some(bucket) = archive_bucket(&entry.updated_at, now) else {
            continue;
        };
        match buckets.iter_mut().find(|(existing, _)| *existing == bucket) {
            Some((_, rows)) => rows.push(entry.clone()),
            None => buckets.push((bucket, vec![entry.clone()])),
        }
    }
    buckets.sort_by_key(|(bucket, _)| *bucket);
    for (_, rows) in &mut buckets {
        rows.sort_by(|left, right| right.updated_at.cmp(&left.updated_at));
    }
    buckets
}

/// 当前本地时间（归档分桶/时间标签用；测试可注入固定时间）。
pub fn now_local() -> DateTime<Local> {
    Local::now()
}

/// 归档：ACP 写 sidebar_threads.archived；native 写 native_archived
/// （threads.db schema 不变），两者都能从主列表消失、在 Archive 视图 Unarchive。
pub fn archive_thread(thread_id: &str) -> bool {
    if thread_id.starts_with(ACP_THREAD_PREFIX) {
        return open_conversation_store()
            .ok()
            .map(|store| store.set_archived(thread_id, true).unwrap_or(false))
            .unwrap_or(false);
    }
    open_conversation_store()
        .map(|store| store.set_native_archived(thread_id, true).is_ok())
        .unwrap_or(false)
}

pub fn unarchive_thread(thread_id: &str) -> bool {
    if thread_id.starts_with(ACP_THREAD_PREFIX) {
        return open_conversation_store()
            .ok()
            .map(|store| store.set_archived(thread_id, false).unwrap_or(false))
            .unwrap_or(false);
    }
    open_conversation_store()
        .map(|store| store.set_native_archived(thread_id, false).is_ok())
        .unwrap_or(false)
}

/// 重命名（写 title_override；None = 清除 override 回落生成标题）。
pub fn rename_override(thread_id: &str, title: Option<&str>) -> bool {
    open_conversation_store()
        .ok()
        .map(|store| store.set_title_override(thread_id, title).is_ok())
        .unwrap_or(false)
}

/// 自动归档：读历史前执行（幂等），每个 agent 保留最近 N 条。
pub fn auto_archive_recent(keep_per_agent: usize) -> usize {
    open_conversation_store()
        .ok()
        .and_then(|store| store.auto_archive_recent(keep_per_agent).ok())
        .unwrap_or(0)
}

/// 恢复会话时内容来源的判定（纯函数，单测覆盖）。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ResumeDecision {
    /// load 成功且 agent 回放了历史：用回放内容替换本地记录。
    UseReplay,
    /// 无回放（load 失败，或 load 成功但 agent 历史不可用）：保留本地内容 + 提示。
    KeepLocalRecord,
    /// 无本地内容且 load 失败：按旧逻辑重开新会话。
    NewSession,
    /// load 成功但既无回放也无本地内容：保持空线程即可。
    Empty,
}

pub fn resume_decision(
    load_failed: bool,
    has_local_content: bool,
    saw_replay: bool,
) -> ResumeDecision {
    if load_failed {
        return if has_local_content {
            ResumeDecision::KeepLocalRecord
        } else {
            ResumeDecision::NewSession
        };
    }
    if saw_replay {
        ResumeDecision::UseReplay
    } else if has_local_content {
        ResumeDecision::KeepLocalRecord
    } else {
        ResumeDecision::Empty
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use cgc_agent_ui::conversation::{ThreadCapabilities, ThreadEvent};
    use chrono::TimeZone;

    fn thread_with(entries: Vec<Entry>, title: Option<&str>) -> ConversationThread {
        ConversationThread {
            thread_id: "acp-s".to_string(),
            title: title.map(str::to_string),
            entries,
            capabilities: ThreadCapabilities::acp(),
            ..ConversationThread::default()
        }
    }

    #[test]
    fn display_title_prefers_generated_then_first_user_message() {
        let user = Entry::User {
            text: "  帮我\n看看 这道题 ".to_string(),
        };
        assert_eq!(
            thread_display_title(&thread_with(vec![user.clone()], Some("生成标题"))).as_deref(),
            Some("生成标题")
        );
        assert_eq!(
            thread_display_title(&thread_with(vec![user.clone()], None)).as_deref(),
            Some("帮我 看看 这道题"),
            "无标题时 fallback 首条用户消息（折叠空白）"
        );
        let long = Entry::User {
            text: "x".repeat(80),
        };
        let title = thread_display_title(&thread_with(vec![long], None)).expect("fallback");
        assert!(title.ends_with('…'), "超长 fallback 标题截断");
        assert!(title.chars().count() <= 31);
        assert_eq!(
            thread_display_title(&thread_with(Vec::new(), None)),
            None,
            "空线程无标题"
        );
    }

    #[test]
    fn sidebar_for_save_keeps_created_at_and_generated_never_clears_override() {
        let thread = thread_with(
            vec![Entry::User {
                text: "hi".to_string(),
            }],
            Some("生成标题"),
        );
        let existing = SidebarThread {
            thread_id: "acp-s".to_string(),
            agent_id: Some("omp".to_string()),
            session_id: Some("s".to_string()),
            title: Some("旧标题".to_string()),
            title_override: Some("用户标题".to_string()),
            created_at: "2026-10-26T10:00:00Z".to_string(),
            updated_at: "2026-10-26T10:00:00Z".to_string(),
            archived: false,
        };
        let sidebar = sidebar_for_save(
            &thread,
            "s",
            "omp",
            None, // 生成标题保存：不传 override
            Some(&existing),
            "2026-10-26T11:00:00Z",
        );
        assert_eq!(sidebar.thread_id, "acp-s");
        assert_eq!(
            sidebar.created_at, "2026-10-26T10:00:00Z",
            "created_at 不重置"
        );
        assert_eq!(sidebar.updated_at, "2026-10-26T11:00:00Z");
        assert_eq!(
            sidebar.title_override, None,
            "传 None 不覆盖已有 override（由 SQL COALESCE 保留）"
        );
        assert_eq!(sidebar.title.as_deref(), Some("生成标题"));
        assert!(!sidebar.archived);
    }

    #[test]
    fn merge_history_combines_sources_and_sorts_desc() {
        let native = vec![
            ThreadSummary {
                id: "native-1".to_string(),
                title: Some("native 旧".to_string()),
                agent: "native".to_string(),
                session_id: None,
                provider_id: "p".to_string(),
                model_id: "m".to_string(),
                updated_at: 1_790_000_000,
            },
            ThreadSummary {
                id: "acp-legacy".to_string(),
                title: Some("旧 ACP 镜像".to_string()),
                agent: "omp".to_string(),
                session_id: Some("sess-legacy".to_string()),
                provider_id: "acp".to_string(),
                model_id: "omp".to_string(),
                updated_at: 1_790_000_500,
            },
        ];
        let acp = vec![SidebarThread {
            thread_id: "acp-sess-1".to_string(),
            agent_id: Some("codex".to_string()),
            session_id: Some("sess-1".to_string()),
            title: Some("agent 标题".to_string()),
            title_override: Some("用户标题".to_string()),
            created_at: "2026-10-26T10:00:00Z".to_string(),
            updated_at: "2026-10-26T12:00:00Z".to_string(),
            archived: false,
        }];
        let merged = merge_history(native, acp);
        assert_eq!(
            merged
                .iter()
                .map(|entry| entry.thread_id.as_str())
                .collect::<Vec<_>>(),
            vec!["acp-sess-1", "native-1"],
            "只合并 native agent 行 + ACP 本地历史，且 updated_at 倒序"
        );
        assert_eq!(merged[0].source, HistorySource::Acp);
        assert_eq!(merged[0].title.as_deref(), Some("用户标题"));
        assert_eq!(merged[0].agent_label(), "codex");
        assert_eq!(merged[1].source, HistorySource::Native);
        assert_eq!(merged[1].agent_label(), "native");
    }

    #[test]
    fn resume_decision_covers_all_fallback_branches() {
        assert_eq!(
            resume_decision(false, true, true),
            ResumeDecision::UseReplay
        );
        assert_eq!(
            resume_decision(false, true, false),
            ResumeDecision::KeepLocalRecord,
            "load 成功但无回放：显示本地记录"
        );
        assert_eq!(
            resume_decision(true, true, false),
            ResumeDecision::KeepLocalRecord,
            "load 失败但有本地记录：降级显示本地记录（不重开新会话）"
        );
        assert_eq!(
            resume_decision(true, false, false),
            ResumeDecision::NewSession,
            "load 失败且无本地记录：按旧逻辑重开新会话"
        );
        assert_eq!(resume_decision(false, false, false), ResumeDecision::Empty);
        assert_eq!(
            resume_decision(false, false, true),
            ResumeDecision::UseReplay,
            "回放优先"
        );
    }

    #[test]
    fn transcript_save_load_delete_round_trip_uses_store() {
        // 直接测纯逻辑 + 内存 store（文件路径逻辑由 agent_store 测试覆盖）。
        let mut store = ConversationStore::open_in_memory().expect("store");
        let mut thread = thread_with(
            vec![Entry::User {
                text: "hello".to_string(),
            }],
            None,
        );
        thread.apply(ThreadEvent::TextDelta("hi".to_string()));
        thread.usage = cgc_agent_ui::conversation::Usage {
            used: 12,
            size: 100,
            cost: None,
        };
        let now = cgc_agent_store::now_utc_rfc3339();
        let sidebar = save_transcript(&mut store, &thread, "sess-9", "omp", None, &now)
            .expect("save transcript");
        assert_eq!(sidebar.thread_id, "acp-sess-9");
        assert_eq!(
            sidebar.title.as_deref(),
            Some("hello"),
            "无生成标题时 fallback 首条用户消息"
        );
        assert_eq!(
            store.load_content("acp-sess-9").expect("load"),
            Some(thread)
        );
        assert_eq!(store.list_sidebar(10).expect("list").len(), 1);
        assert!(store.delete_thread("acp-sess-9").expect("delete"));
        assert_eq!(store.load_content("acp-sess-9").expect("load"), None);
        assert_eq!(store.clear_all().expect("clear"), 0);
    }

    #[test]
    fn main_list_limits_acp_per_agent_but_keeps_all_native() {
        let mut native = Vec::new();
        for index in 0..6 {
            native.push(ThreadSummary {
                id: format!("native-{index}"),
                title: Some(format!("native {index}")),
                agent: "native".to_string(),
                session_id: None,
                provider_id: "p".to_string(),
                model_id: "m".to_string(),
                updated_at: 1_790_000_000 + index,
            });
        }
        let mut acp = Vec::new();
        for (agent, count) in [("omp", 7), ("codex", 3)] {
            for index in 0..count {
                acp.push(SidebarThread {
                    thread_id: format!("acp-{agent}-{index}"),
                    agent_id: Some(agent.to_string()),
                    session_id: Some(format!("{agent}-{index}")),
                    title: Some(format!("{agent} {index}")),
                    title_override: None,
                    created_at: "2026-10-26T10:00:00Z".to_string(),
                    updated_at: format!("2026-10-26T12:0{index}:00Z"),
                    archived: false,
                });
            }
        }
        let merged = merge_history(native, acp);
        let listed = main_list(&merged, 5);
        assert_eq!(
            listed
                .iter()
                .filter(|e| e.agent_label() == "native")
                .count(),
            6,
            "native 无 archived 列，不截断"
        );
        assert_eq!(
            listed.iter().filter(|e| e.agent_label() == "omp").count(),
            5
        );
        assert_eq!(
            listed.iter().filter(|e| e.agent_label() == "codex").count(),
            3
        );
        // 归档行从主列表消失。
        let mut archived = listed.clone();
        archived[0].archived = true;
        assert!(main_list(&archived, 5)
            .iter()
            .all(|entry| entry.thread_id != archived[0].thread_id));
    }

    fn entry(id: &str, updated_at: &str, archived: bool) -> HistoryEntry {
        HistoryEntry {
            thread_id: id.to_string(),
            session_id: Some(id.trim_start_matches("acp-").to_string()),
            agent_id: Some("omp".to_string()),
            title: Some(format!("title {id}")),
            updated_at: updated_at.to_string(),
            archived,
            source: HistorySource::Acp,
        }
    }

    #[test]
    fn native_archived_marks_hide_from_main_list_and_show_in_archive() {
        let native = vec![
            ThreadSummary {
                id: "native-1".to_string(),
                title: Some("native 1".to_string()),
                agent: "native".to_string(),
                session_id: None,
                provider_id: "p".to_string(),
                model_id: "m".to_string(),
                updated_at: 1_790_000_000,
            },
            ThreadSummary {
                id: "native-2".to_string(),
                title: Some("native 2".to_string()),
                agent: "native".to_string(),
                session_id: None,
                provider_id: "p".to_string(),
                model_id: "m".to_string(),
                updated_at: 1_790_000_100,
            },
        ];
        let archived: std::collections::HashSet<String> =
            ["native-1".to_string()].into_iter().collect();
        let merged = merge_history_with_native_archived(native, Vec::new(), &archived);
        let archived_entry = merged
            .iter()
            .find(|entry| entry.thread_id == "native-1")
            .expect("native-1");
        assert!(archived_entry.archived, "native 归档标记覆盖 archived 位");
        assert!(
            main_list(&merged, 5)
                .iter()
                .all(|entry| entry.thread_id != "native-1"),
            "归档的 native 行从主列表消失"
        );
        assert_eq!(archive_entries(&merged).len(), 1);
        assert_eq!(archive_entries(&merged)[0].thread_id, "native-1");
        assert!(main_list(&merged, 5)
            .iter()
            .any(|entry| entry.thread_id == "native-2"));
    }

    #[test]
    fn archive_and_unarchive_flip_list_membership() {
        let mut entries = vec![
            entry("acp-1", "2026-10-26T10:00:00+08:00", true),
            entry("acp-2", "2026-10-26T11:00:00+08:00", false),
        ];
        // 归档后：主列表消失、归档视图出现。
        assert!(main_list(&entries, 5)
            .iter()
            .all(|entry| entry.thread_id != "acp-1"));
        assert!(archive_entries(&entries)
            .iter()
            .any(|entry| entry.thread_id == "acp-1"));
        // 取消归档后（下一次 reload 的数据）：回到主列表、离开归档视图。
        entries[0].archived = false;
        assert!(main_list(&entries, 5)
            .iter()
            .any(|entry| entry.thread_id == "acp-1"));
        assert!(archive_entries(&entries)
            .iter()
            .all(|entry| entry.thread_id != "acp-1"));
    }

    #[test]
    fn archive_buckets_split_today_yesterday_last7_earlier() {
        let now = now_local();
        let day = 86_400;
        let now_epoch = now.timestamp();
        let entries = vec![
            entry(
                "acp-today",
                &cgc_agent_store::format_epoch_rfc3339(now_epoch - 60),
                true,
            ),
            entry(
                "acp-yesterday",
                &cgc_agent_store::format_epoch_rfc3339(now_epoch - day),
                true,
            ),
            entry(
                "acp-last7",
                &cgc_agent_store::format_epoch_rfc3339(now_epoch - 3 * day),
                true,
            ),
            entry(
                "acp-earlier",
                &cgc_agent_store::format_epoch_rfc3339(now_epoch - 10 * day),
                true,
            ),
            entry(
                "acp-active",
                &cgc_agent_store::format_epoch_rfc3339(now_epoch),
                false,
            ),
        ];
        let groups = group_archive(&entries, &now);
        assert_eq!(
            groups
                .iter()
                .map(|(bucket, _)| bucket.label())
                .collect::<Vec<_>>(),
            vec!["今天", "昨天", "最近 7 天", "更早"]
        );
        assert_eq!(groups[0].1[0].thread_id, "acp-today");
        assert_eq!(groups[3].1[0].thread_id, "acp-earlier");
        assert_eq!(
            archive_entries(&entries).len(),
            4,
            "只有 archived 进入归档视图"
        );
    }

    #[test]
    fn relative_time_labels_are_compact() {
        let now = Local
            .timestamp_opt(1_790_000_000, 0)
            .single()
            .expect("local time");
        let label = |seconds_ago: i64| {
            relative_time_label(
                &cgc_agent_store::format_epoch_rfc3339(1_790_000_000 - seconds_ago),
                &now,
            )
        };
        assert_eq!(label(10), "now");
        assert_eq!(label(120), "2m");
        assert_eq!(label(2 * 3_600), "2h");
        assert_eq!(label(86_400), "1d");
        assert_eq!(relative_time_label("not-a-time", &now), "");
    }

    #[test]
    fn filter_history_matches_title_agent_or_id_case_insensitively() {
        let entries = vec![
            entry("acp-alpha", "2026-10-26T12:00:00Z", false),
            HistoryEntry {
                title: Some("Debug Rust".to_string()),
                agent_id: Some("codex".to_string()),
                ..entry("acp-beta", "2026-10-26T11:00:00Z", false)
            },
        ];
        assert_eq!(filter_history(entries.clone(), "debug").len(), 1);
        assert_eq!(filter_history(entries.clone(), "CODEX").len(), 1);
        assert_eq!(filter_history(entries.clone(), "acp-alpha").len(), 1);
        assert_eq!(filter_history(entries, "   ").len(), 2);
    }

    #[test]
    fn dirty_generation_advances_on_mark() {
        let before = history_dirty_generation_for_test();
        mark_history_dirty();
        let after = history_dirty_generation_for_test();
        assert!(after > before, "mark_history_dirty 必须推进世代号");
    }

    #[test]
    fn acp_thread_id_helpers_round_trip() {
        assert_eq!(acp_thread_id("sess-1"), "acp-sess-1");
        assert_eq!(session_id_from_thread_id("acp-sess-1"), Some("sess-1"));
        assert_eq!(session_id_from_thread_id("native-1"), None);
    }
}
