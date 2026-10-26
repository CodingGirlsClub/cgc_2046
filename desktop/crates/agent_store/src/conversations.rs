//! ACP transcript 本地存储（Stage 3.3 / 设计 §2 决策 1）。
//!
//! `<data_root>/conversations.db`（0600、WAL）：一个文件两张表——
//! - `thread_content(thread_id PRIMARY KEY, data JSON, updated_at TEXT)`：
//!   `data` 是共享模型 `ConversationThread` 的 JSON（与两轨 ingestion 同一模型）；
//! - `sidebar_threads(...)`：历史列表需要的 metadata（agent/session/标题/时间/归档）。
//!
//! 带 `schema_migrations` 版本表；缺列/损坏 JSON 容错降级（返回空/`None`），不 panic。
//! native 既有 `agent/threads.db` schema 与内容不动；ACP 只写这里。

use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

use cgc_agent_conversation::conversation::ConversationThread;
use rusqlite::{params, Connection, OptionalExtension};

/// 数据库文件名（`<data_root>/conversations.db`）。
pub const CONVERSATIONS_DB: &str = "conversations.db";
/// 当前 schema 版本；迁移只增不改。
pub const SCHEMA_VERSION: i64 = 1;

#[derive(Debug, thiserror::Error)]
pub enum ConversationStoreError {
    #[error("sqlite: {0}")]
    Sqlite(String),
    #[error("json: {0}")]
    Json(String),
}

impl From<rusqlite::Error> for ConversationStoreError {
    fn from(error: rusqlite::Error) -> Self {
        Self::Sqlite(error.to_string())
    }
}

impl From<serde_json::Error> for ConversationStoreError {
    fn from(error: serde_json::Error) -> Self {
        Self::Json(error.to_string())
    }
}

/// 历史列表条目（sidebar_threads 一行）。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SidebarThread {
    pub thread_id: String,
    /// 外部 agent id（omp / codex / …）。
    pub agent_id: Option<String>,
    /// 外部 agent 的 ACP session id（用于 `session/load`）。
    pub session_id: Option<String>,
    /// agent 生成的标题（不覆盖用户重命名）。
    pub title: Option<String>,
    /// 用户重命名；列表展示优先于 `title`。
    pub title_override: Option<String>,
    pub created_at: String,
    pub updated_at: String,
    /// 预留字段：MVP 不提供归档 UI（见报告）。
    pub archived: bool,
}

impl SidebarThread {
    /// 列表展示标题：用户覆盖优先，其次 agent 标题。
    pub fn display_title(&self) -> Option<&str> {
        self.title_override
            .as_deref()
            .filter(|title| !title.trim().is_empty())
            .or_else(|| {
                self.title
                    .as_deref()
                    .filter(|title| !title.trim().is_empty())
            })
    }
}

/// ACP transcript 存储（`conversations.db`）。
pub struct ConversationStore {
    conn: Connection,
}

impl ConversationStore {
    pub fn open(path: impl AsRef<Path>) -> Result<Self, ConversationStoreError> {
        let path = path.as_ref();
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|error| ConversationStoreError::Sqlite(error.to_string()))?;
        }
        let conn = Connection::open(path)?;
        set_private_permissions(path);
        Self::from_connection(conn)
    }

    pub fn open_in_memory() -> Result<Self, ConversationStoreError> {
        Self::from_connection(Connection::open_in_memory()?)
    }

    fn from_connection(conn: Connection) -> Result<Self, ConversationStoreError> {
        // WAL：读不阻塞写、崩溃后可恢复；busy_timeout 容忍短暂的写锁竞争。
        conn.execute_batch(
            "PRAGMA journal_mode=WAL; PRAGMA busy_timeout=2000; PRAGMA foreign_keys=ON;",
        )?;
        let store = Self { conn };
        store.migrate()?;
        Ok(store)
    }

    /// 版本化迁移：`schema_migrations` 记录已应用版本；缺列用 ALTER 兜底。
    fn migrate(&self) -> Result<(), ConversationStoreError> {
        self.conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS schema_migrations (
                version INTEGER PRIMARY KEY,
                applied_at TEXT NOT NULL
            );",
        )?;
        let applied: i64 = self.conn.query_row(
            "SELECT COALESCE(MAX(version), 0) FROM schema_migrations",
            [],
            |row| row.get(0),
        )?;
        if applied < 1 {
            self.conn.execute_batch(
                "CREATE TABLE IF NOT EXISTS thread_content (
                    thread_id TEXT PRIMARY KEY,
                    data TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS sidebar_threads (
                    thread_id TEXT PRIMARY KEY,
                    agent_id TEXT,
                    session_id TEXT,
                    title TEXT,
                    title_override TEXT,
                    created_at TEXT,
                    updated_at TEXT NOT NULL DEFAULT '',
                    archived INTEGER NOT NULL DEFAULT 0
                );",
            )?;
            // 旧库/外部建库缺列兜底：逐列 ALTER，已存在时忽略错误。
            for column in [
                "agent_id TEXT",
                "session_id TEXT",
                "title TEXT",
                "title_override TEXT",
                "created_at TEXT",
                "updated_at TEXT",
                "archived INTEGER NOT NULL DEFAULT 0",
            ] {
                let _ = self.conn.execute(
                    &format!("ALTER TABLE sidebar_threads ADD COLUMN {column}"),
                    [],
                );
            }
            let _ = self.conn.execute(
                "ALTER TABLE thread_content ADD COLUMN updated_at TEXT NOT NULL DEFAULT ''",
                [],
            );
            self.conn.execute(
                "INSERT OR IGNORE INTO schema_migrations (version, applied_at) VALUES (?1, ?2)",
                params![1_i64, now_utc_rfc3339()],
            )?;
        }
        Ok(())
    }

    /// 迁移版本（测试/诊断用）。
    pub fn schema_version(&self) -> Result<i64, ConversationStoreError> {
        Ok(self.conn.query_row(
            "SELECT COALESCE(MAX(version), 0) FROM schema_migrations",
            [],
            |row| row.get(0),
        )?)
    }

    /// 当前 journal mode（测试/诊断用；期望 `wal`）。
    pub fn journal_mode(&self) -> Result<String, ConversationStoreError> {
        Ok(self
            .conn
            .query_row("PRAGMA journal_mode", [], |row| row.get(0))?)
    }

    /// 一次事务写入内容 + metadata（回合结束/防抖保存用）。
    pub fn save_thread(
        &mut self,
        content: &ConversationThread,
        sidebar: &SidebarThread,
    ) -> Result<(), ConversationStoreError> {
        let json = serde_json::to_string(content)?;
        let tx = self.conn.transaction()?;
        tx.execute(
            "INSERT INTO thread_content (thread_id, data, updated_at)
             VALUES (?1, ?2, ?3)
             ON CONFLICT(thread_id) DO UPDATE SET data = excluded.data, updated_at = excluded.updated_at",
            params![sidebar.thread_id, json, sidebar.updated_at],
        )?;
        upsert_sidebar(&tx, sidebar)?;
        tx.commit()?;
        Ok(())
    }

    pub fn save_content(
        &self,
        thread_id: &str,
        content: &ConversationThread,
        updated_at: &str,
    ) -> Result<(), ConversationStoreError> {
        let json = serde_json::to_string(content)?;
        self.conn.execute(
            "INSERT INTO thread_content (thread_id, data, updated_at)
             VALUES (?1, ?2, ?3)
             ON CONFLICT(thread_id) DO UPDATE SET data = excluded.data, updated_at = excluded.updated_at",
            params![thread_id, json, updated_at],
        )?;
        Ok(())
    }

    pub fn upsert_sidebar(&self, sidebar: &SidebarThread) -> Result<(), ConversationStoreError> {
        upsert_sidebar(&self.conn, sidebar)
    }

    /// 读取内容；JSON 损坏/不兼容时降级为 `None`（不 panic，UI 继续离线/空态）。
    pub fn load_content(
        &self,
        thread_id: &str,
    ) -> Result<Option<ConversationThread>, ConversationStoreError> {
        let data: Option<String> = self
            .conn
            .query_row(
                "SELECT data FROM thread_content WHERE thread_id = ?1",
                params![thread_id],
                |row| row.get(0),
            )
            .optional()?;
        let Some(data) = data else {
            return Ok(None);
        };
        match serde_json::from_str::<ConversationThread>(&data) {
            Ok(thread) => Ok(Some(thread)),
            Err(error) => {
                eprintln!("[conversations] 忽略损坏的 thread_content {thread_id}: {error}");
                Ok(None)
            }
        }
    }

    pub fn load_sidebar(
        &self,
        thread_id: &str,
    ) -> Result<Option<SidebarThread>, ConversationStoreError> {
        self.conn
            .query_row(
                "SELECT thread_id, agent_id, session_id, title, title_override,
                        COALESCE(created_at, ''), COALESCE(updated_at, ''), archived
                 FROM sidebar_threads WHERE thread_id = ?1",
                params![thread_id],
                row_to_sidebar,
            )
            .optional()
            .map_err(Into::into)
    }

    /// 历史列表：按 `updated_at` 倒序（RFC3339 字典序即时间序）。
    pub fn list_sidebar(&self, limit: usize) -> Result<Vec<SidebarThread>, ConversationStoreError> {
        let mut statement = self.conn.prepare(
            "SELECT thread_id, agent_id, session_id, title, title_override,
                    COALESCE(created_at, ''), COALESCE(updated_at, ''), archived
             FROM sidebar_threads
             ORDER BY updated_at DESC, thread_id DESC
             LIMIT ?1",
        )?;
        let rows = statement.query_map(params![limit as i64], row_to_sidebar)?;
        let mut threads = Vec::new();
        for row in rows {
            threads.push(row?);
        }
        Ok(threads)
    }

    /// 删除单条会话（content + metadata）；返回是否存在。
    pub fn delete_thread(&self, thread_id: &str) -> Result<bool, ConversationStoreError> {
        let content = self.conn.execute(
            "DELETE FROM thread_content WHERE thread_id = ?1",
            params![thread_id],
        )?;
        let sidebar = self.conn.execute(
            "DELETE FROM sidebar_threads WHERE thread_id = ?1",
            params![thread_id],
        )?;
        Ok(content + sidebar > 0)
    }

    /// 清空全部 ACP 历史（只清 conversations.db，不碰 native threads.db）；
    /// 返回删除的会话条数。
    pub fn clear_all(&self) -> Result<usize, ConversationStoreError> {
        let count: i64 =
            self.conn
                .query_row("SELECT COUNT(*) FROM sidebar_threads", [], |row| row.get(0))?;
        self.conn.execute("DELETE FROM thread_content", [])?;
        self.conn.execute("DELETE FROM sidebar_threads", [])?;
        Ok(count.max(0) as usize)
    }

    /// agent 生成的标题：只更新 `title`，**永不覆盖** `title_override`。
    pub fn set_generated_title(
        &self,
        thread_id: &str,
        title: Option<&str>,
    ) -> Result<(), ConversationStoreError> {
        self.conn.execute(
            "UPDATE sidebar_threads SET title = ?2 WHERE thread_id = ?1",
            params![thread_id, title],
        )?;
        Ok(())
    }

    /// 用户重命名：写 `title_override`（`None` 表示清除覆盖，回落 agent 标题）。
    pub fn set_title_override(
        &self,
        thread_id: &str,
        title_override: Option<&str>,
    ) -> Result<(), ConversationStoreError> {
        self.conn.execute(
            "UPDATE sidebar_threads SET title_override = ?2 WHERE thread_id = ?1",
            params![thread_id, title_override],
        )?;
        Ok(())
    }

    pub fn touch_updated_at(
        &self,
        thread_id: &str,
        updated_at: &str,
    ) -> Result<(), ConversationStoreError> {
        self.conn.execute(
            "UPDATE sidebar_threads SET updated_at = ?2 WHERE thread_id = ?1",
            params![thread_id, updated_at],
        )?;
        Ok(())
    }
}

fn upsert_sidebar(
    conn: &Connection,
    sidebar: &SidebarThread,
) -> Result<(), ConversationStoreError> {
    conn.execute(
        "INSERT INTO sidebar_threads
            (thread_id, agent_id, session_id, title, title_override, created_at, updated_at, archived)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
         ON CONFLICT(thread_id) DO UPDATE SET
            agent_id = COALESCE(excluded.agent_id, sidebar_threads.agent_id),
            session_id = COALESCE(excluded.session_id, sidebar_threads.session_id),
            title = COALESCE(excluded.title, sidebar_threads.title),
            -- 生成标题更新不得清掉用户重命名；只有显式 set_title_override 才能改。
            title_override = COALESCE(excluded.title_override, sidebar_threads.title_override),
            created_at = COALESCE(sidebar_threads.created_at, excluded.created_at),
            updated_at = excluded.updated_at,
            archived = excluded.archived",
        params![
            sidebar.thread_id,
            sidebar.agent_id,
            sidebar.session_id,
            sidebar.title,
            sidebar.title_override,
            sidebar.created_at,
            sidebar.updated_at,
            i64::from(sidebar.archived),
        ],
    )?;
    Ok(())
}

fn row_to_sidebar(row: &rusqlite::Row<'_>) -> rusqlite::Result<SidebarThread> {
    Ok(SidebarThread {
        thread_id: row.get(0)?,
        agent_id: row.get(1)?,
        session_id: row.get(2)?,
        title: row.get(3)?,
        title_override: row.get(4)?,
        created_at: row.get(5)?,
        updated_at: row.get(6)?,
        archived: row.get::<_, i64>(7)? != 0,
    })
}

/// 文件权限收 0600（仅本人可读写；Unix；Windows 由 ACL 语义兜底）。
fn set_private_permissions(path: &Path) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600));
    }
    #[cfg(not(unix))]
    {
        let _ = path;
    }
}

/// 当前 UTC 时间（RFC3339，秒精度）：`1970-01-01T00:00:00Z` 形状；用于
/// `created_at`/`updated_at`（列表按字典序即时间序）。
pub fn now_utc_rfc3339() -> String {
    let epoch = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs() as i64)
        .unwrap_or_default();
    format_epoch_rfc3339(epoch)
}

/// Unix 秒 → RFC3339 UTC（无外部依赖；Howard Hinnant civil_from_days 算法）。
pub fn format_epoch_rfc3339(epoch_seconds: i64) -> String {
    let days = epoch_seconds.div_euclid(86_400);
    let seconds_of_day = epoch_seconds.rem_euclid(86_400);
    let (year, month, day) = civil_from_days(days);
    let hour = seconds_of_day / 3_600;
    let minute = (seconds_of_day % 3_600) / 60;
    let second = seconds_of_day % 60;
    format!("{year:04}-{month:02}-{day:02}T{hour:02}:{minute:02}:{second:02}Z")
}

/// 返回 (year, month, day)；算法见 Howard Hinnant "chrono-Compatible Low-Level
/// Date Algorithms"（days 以 1970-01-01 为 0）。
fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let mut year = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let month = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    if month <= 2 {
        year += 1;
    }
    (year, month, day)
}

#[cfg(test)]
mod tests {
    use super::*;
    use cgc_agent_conversation::conversation::{
        ConversationThread, Entry, ThreadCapabilities, ThreadStatus, Usage,
    };

    fn temp_dir(tag: &str) -> std::path::PathBuf {
        use std::sync::atomic::{AtomicU64, Ordering};
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let serial = COUNTER.fetch_add(1, Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!(
            "cgc-conversations-{}-{tag}-{serial}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("dir");
        dir
    }

    fn sample_thread(id: &str) -> ConversationThread {
        let mut thread = ConversationThread::new(id).with_capabilities(ThreadCapabilities::acp());
        thread.title = Some("ACP 会话标题".to_string());
        thread.status = ThreadStatus::Idle;
        thread.usage = Usage {
            used: 120,
            size: 4_000,
            cost: None,
        };
        thread.apply(
            cgc_agent_conversation::conversation::ThreadEvent::TurnStarted {
                user_text: "hello".to_string(),
            },
        );
        thread
            .apply(cgc_agent_conversation::conversation::ThreadEvent::TextDelta("hi".to_string()));
        thread
    }

    fn sidebar(thread_id: &str, updated_at: &str) -> SidebarThread {
        SidebarThread {
            thread_id: thread_id.to_string(),
            agent_id: Some("omp".to_string()),
            session_id: Some("sess-1".to_string()),
            title: Some("ACP 会话标题".to_string()),
            title_override: None,
            created_at: updated_at.to_string(),
            updated_at: updated_at.to_string(),
            archived: false,
        }
    }

    #[test]
    fn content_and_sidebar_round_trip() {
        let dir = temp_dir("roundtrip");
        let mut store = ConversationStore::open(dir.join(CONVERSATIONS_DB)).expect("open");
        let thread = sample_thread("acp-sess-1");
        let meta = sidebar("acp-sess-1", "2026-10-26T12:00:00Z");
        store.save_thread(&thread, &meta).expect("save");

        assert_eq!(
            store.load_content("acp-sess-1").expect("load"),
            Some(thread),
            "ConversationThread 序列化/反序列化必须无损"
        );
        assert_eq!(
            store.load_sidebar("acp-sess-1").expect("sidebar"),
            Some(meta)
        );
        let listed = store.list_sidebar(10).expect("list");
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].agent_id.as_deref(), Some("omp"));
        assert_eq!(listed[0].session_id.as_deref(), Some("sess-1"));
        assert_eq!(listed[0].display_title(), Some("ACP 会话标题"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[cfg(unix)]
    #[test]
    fn database_file_is_private_0600_and_wal() {
        use std::os::unix::fs::PermissionsExt;
        let dir = temp_dir("perms");
        let path = dir.join(CONVERSATIONS_DB);
        let store = ConversationStore::open(&path).expect("open");
        let mode = std::fs::metadata(&path)
            .expect("metadata")
            .permissions()
            .mode();
        assert_eq!(mode & 0o777, 0o600, "conversations.db 必须 0600");
        assert_eq!(store.journal_mode().expect("journal"), "wal");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn migration_is_versioned_and_idempotent() {
        let dir = temp_dir("migrate");
        let path = dir.join(CONVERSATIONS_DB);
        {
            let store = ConversationStore::open(&path).expect("open");
            assert_eq!(store.schema_version().expect("version"), SCHEMA_VERSION);
        }
        // 重开不重复迁移，数据仍可正常读写。
        let mut store = ConversationStore::open(&path).expect("reopen");
        store
            .save_thread(
                &sample_thread("acp-a"),
                &sidebar("acp-a", "2026-10-26T12:00:00Z"),
            )
            .expect("save");
        assert_eq!(store.schema_version().expect("version"), SCHEMA_VERSION);
        assert_eq!(store.list_sidebar(10).expect("list").len(), 1);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn legacy_sidebar_without_columns_is_upgraded_not_fatal() {
        let dir = temp_dir("legacy");
        let path = dir.join(CONVERSATIONS_DB);
        {
            // 模拟一个只建了最小列、没有迁移表的旧库。
            let conn = Connection::open(&path).expect("legacy db");
            conn.execute_batch(
                "CREATE TABLE sidebar_threads (thread_id TEXT PRIMARY KEY, updated_at TEXT);
                 CREATE TABLE thread_content (thread_id TEXT PRIMARY KEY, data TEXT);",
            )
            .expect("legacy schema");
        }
        let store = ConversationStore::open(&path).expect("open legacy");
        assert_eq!(store.schema_version().expect("version"), SCHEMA_VERSION);
        // 缺 column 的旧表被 ALTER 补齐后可正常 list / 读写。
        assert!(store.list_sidebar(10).expect("list").is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn corrupt_content_degrades_to_none_without_panic() {
        let dir = temp_dir("corrupt");
        let path = dir.join(CONVERSATIONS_DB);
        {
            let store = ConversationStore::open(&path).expect("open");
            store
                .conn
                .execute(
                    "INSERT INTO thread_content (thread_id, data, updated_at) VALUES ('acp-bad', '{not-json', 'x')",
                    [],
                )
                .expect("insert bad");
        }
        let store = ConversationStore::open(&path).expect("reopen");
        assert_eq!(
            store.load_content("acp-bad").expect("load"),
            None,
            "损坏 JSON 降级为 None（UI 显示本地空/离线态），不 panic"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn generated_title_never_overrides_user_title_override() {
        let dir = temp_dir("titles");
        let mut store = ConversationStore::open(dir.join(CONVERSATIONS_DB)).expect("open");
        let mut meta = sidebar("acp-title", "2026-10-26T12:00:00Z");
        meta.title = Some("agent 生成标题".to_string());
        store
            .save_thread(&sample_thread("acp-title"), &meta)
            .expect("save");

        store
            .set_title_override("acp-title", Some("用户重命名"))
            .expect("override");
        assert_eq!(
            store
                .load_sidebar("acp-title")
                .expect("load")
                .and_then(|thread| thread.display_title().map(str::to_string)),
            Some("用户重命名".to_string()),
            "列表展示 override 优先"
        );

        // 生成标题更新（保存新事件时 title 变化）不得覆盖 override。
        let mut updated = meta.clone();
        updated.title = Some("更新的生成标题".to_string());
        updated.updated_at = "2026-10-26T12:05:00Z".to_string();
        store
            .save_thread(&sample_thread("acp-title"), &updated)
            .expect("save again");
        let loaded = store.load_sidebar("acp-title").expect("load").expect("row");
        assert_eq!(loaded.title.as_deref(), Some("更新的生成标题"));
        assert_eq!(loaded.title_override.as_deref(), Some("用户重命名"));

        // 清除 override 后回落生成标题。
        store.set_title_override("acp-title", None).expect("clear");
        let loaded = store.load_sidebar("acp-title").expect("load").expect("row");
        assert_eq!(loaded.display_title(), Some("更新的生成标题"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn delete_removes_content_and_metadata_and_clear_empties_all() {
        let dir = temp_dir("delete");
        let mut store = ConversationStore::open(dir.join(CONVERSATIONS_DB)).expect("open");
        for (id, at) in [
            ("acp-1", "2026-10-26T12:00:00Z"),
            ("acp-2", "2026-10-26T12:01:00Z"),
            ("acp-3", "2026-10-26T12:02:00Z"),
        ] {
            store
                .save_thread(&sample_thread(id), &sidebar(id, at))
                .expect("save");
        }
        assert!(store.delete_thread("acp-2").expect("delete"));
        assert_eq!(store.load_content("acp-2").expect("content"), None);
        assert_eq!(store.load_sidebar("acp-2").expect("meta"), None);
        assert!(!store.delete_thread("acp-2").expect("delete again"));

        let listed = store.list_sidebar(10).expect("list");
        assert_eq!(listed.len(), 2);
        assert_eq!(
            listed
                .iter()
                .map(|t| t.thread_id.as_str())
                .collect::<Vec<_>>(),
            vec!["acp-3", "acp-1"],
            "按 updated_at 倒序"
        );
        assert_eq!(store.clear_all().expect("clear"), 2);
        assert!(store.list_sidebar(10).expect("list").is_empty());
        assert_eq!(store.load_content("acp-3").expect("content"), None);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn rfc3339_timestamps_are_sortable_and_correct() {
        assert_eq!(format_epoch_rfc3339(0), "1970-01-01T00:00:00Z");
        assert_eq!(format_epoch_rfc3339(1_790_000_000), "2026-09-21T14:13:20Z");
        assert!(format_epoch_rfc3339(1_790_000_000) < format_epoch_rfc3339(1_790_000_001));
        // 闰年/闰日边界。
        assert_eq!(format_epoch_rfc3339(951_782_400), "2000-02-29T00:00:00Z");
    }

    #[test]
    fn entry_round_trip_keeps_permission_options() {
        use cgc_agent_conversation::conversation::{
            PermissionOption, PermissionOptionKind, PermissionRequest,
        };
        let thread = ConversationThread {
            pending_permission: Some(PermissionRequest {
                request_id: "perm-1".to_string(),
                title: "允许运行 run_command？".to_string(),
                tool: Some("run_command".to_string()),
                tool_call_id: Some("call-1".to_string()),
                args: Some("{\"command\":\"ls\"}".to_string()),
                options: vec![PermissionOption {
                    id: "allow_once".to_string(),
                    label: "允许一次".to_string(),
                    kind: PermissionOptionKind::AllowOnce,
                }],
            }),
            entries: vec![Entry::Permission {
                request_id: "perm-1".to_string(),
                title: "允许运行 run_command？".to_string(),
                tool: Some("run_command".to_string()),
                tool_call_id: Some("call-1".to_string()),
                args: Some("{\"command\":\"ls\"}".to_string()),
                options: vec![],
                resolved: None,
            }],
            ..ConversationThread::default()
        };
        let json = serde_json::to_string(&thread).expect("serialize");
        let decoded: ConversationThread = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(decoded, thread);
    }
}
