//! ACP 历史 / 标题 / 恢复降级的 app 层逻辑（Stage 3.3）。
//!
//! 可纯函数化的部分（历史合并、标题 fallback、resume 降级判定）放这里单测；
//! 存储由 `cgc_agent_store::ConversationStore`（`conversations.db`）承担。
//! native 既有 `agent/threads.db` 的 schema/内容不动：native 历史仍从
//! `SessionStore` 读，ACP 历史从 `ConversationStore` 读，再在这里合并成统一列表。

use std::path::PathBuf;

use cgc_agent_store::{
    ConversationStore, ConversationStoreError, SidebarThread, ThreadSummary, CONVERSATIONS_DB,
};
use cgc_agent_ui::conversation::{ConversationThread, Entry};

/// ACP 历史 thread_id 前缀（`acp-<session_id>`，沿用旧统一列表约定）。
pub const ACP_THREAD_PREFIX: &str = "acp-";
/// agent 历史回放不可用时的降级提示（Zed `resumed_without_history` 语义）。
pub const RESUMED_WITHOUT_HISTORY: &str = "外部 agent 无法恢复会话，以下为本地记录";

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
pub fn load_local_transcript(thread_id: &str) -> Option<ConversationThread> {
    let store = open_conversation_store().ok()?;
    store.load_content(thread_id).ok().flatten()
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
pub fn clear_acp_history() -> usize {
    open_conversation_store()
        .ok()
        .and_then(|store| store.clear_all().ok())
        .unwrap_or(0)
}

/// 合并 native（threads.db）与 ACP（conversations.db）历史，按 updated_at 倒序。
pub fn merge_history(
    native_threads: Vec<ThreadSummary>,
    acp_threads: Vec<SidebarThread>,
) -> Vec<HistoryEntry> {
    let mut entries: Vec<HistoryEntry> = native_threads
        .into_iter()
        .filter(|thread| thread.agent == "native")
        .map(|thread| HistoryEntry {
            thread_id: thread.id,
            session_id: thread.session_id,
            agent_id: Some(thread.agent),
            title: thread.title,
            updated_at: cgc_agent_store::format_epoch_rfc3339(thread.updated_at),
            source: HistorySource::Native,
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
    fn acp_thread_id_helpers_round_trip() {
        assert_eq!(acp_thread_id("sess-1"), "acp-sess-1");
        assert_eq!(session_id_from_thread_id("acp-sess-1"), Some("sess-1"));
        assert_eq!(session_id_from_thread_id("native-1"), None);
    }
}
