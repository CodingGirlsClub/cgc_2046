use std::path::Path;

use cgc_agent_core::{Entry, SelectedModel, Thread};
use cgc_agent_provider::{ModelId, ProviderId, TokenUsage};
use rusqlite::{params, Connection, OptionalExtension};

/// 会话存储错误。
#[derive(Debug, thiserror::Error)]
pub enum SessionError {
    #[error("sqlite: {0}")]
    Sqlite(String),
    #[error("json: {0}")]
    Json(String),
}

impl From<rusqlite::Error> for SessionError {
    fn from(error: rusqlite::Error) -> Self {
        Self::Sqlite(error.to_string())
    }
}

impl From<serde_json::Error> for SessionError {
    fn from(error: serde_json::Error) -> Self {
        Self::Json(error.to_string())
    }
}

/// SQLite 会话存储：`<data_root>/agent/threads.db`（设计稿 §3.4）。
pub struct SessionStore {
    conn: Connection,
}

/// checkpoint 与会话的映射（设计稿 §3.7）。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CheckpointRecord {
    pub thread_id: String,
    pub user_entry_seq: i64,
    pub ref_name: String,
    pub sha: String,
    pub base_head: Option<String>,
    pub created_at: i64,
    pub state: String,
}

/// 会话列表项，用于历史侧栏。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ThreadSummary {
    pub id: String,
    pub title: Option<String>,
    pub agent: String,
    pub session_id: Option<String>,
    pub provider_id: String,
    pub model_id: String,
    pub updated_at: i64,
}

impl SessionStore {
    pub fn open(path: impl AsRef<Path>) -> Result<Self, SessionError> {
        if let Some(parent) = path.as_ref().parent() {
            std::fs::create_dir_all(parent)
                .map_err(|error| SessionError::Sqlite(error.to_string()))?;
        }
        let conn = Connection::open(path)?;
        Self::from_connection(conn)
    }

    pub fn open_in_memory() -> Result<Self, SessionError> {
        Self::from_connection(Connection::open_in_memory()?)
    }

    fn from_connection(conn: Connection) -> Result<Self, SessionError> {
        conn.execute_batch("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;")?;
        let store = Self { conn };
        store.migrate()?;
        Ok(store)
    }

    fn migrate(&self) -> Result<(), SessionError> {
        self.conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS threads (
                id TEXT PRIMARY KEY,
                title TEXT,
                title_override TEXT,
                agent TEXT NOT NULL DEFAULT 'native',
                session_id TEXT,
                model_provider TEXT NOT NULL,
                model_id TEXT NOT NULL,
                usage_json TEXT,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS entries (
                thread_id TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
                seq INTEGER NOT NULL,
                kind TEXT NOT NULL,
                payload_json TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                PRIMARY KEY (thread_id, seq)
            );
            CREATE TABLE IF NOT EXISTS checkpoints (
                thread_id TEXT NOT NULL,
                user_entry_seq INTEGER NOT NULL,
                ref TEXT NOT NULL,
                sha TEXT NOT NULL,
                base_head TEXT,
                created_at INTEGER NOT NULL,
                state TEXT NOT NULL DEFAULT 'active',
                PRIMARY KEY (thread_id, user_entry_seq)
            );",
        )?;
        // 兼容旧库：补 title_override 列（已存在时忽略错误）。
        let _ = self
            .conn
            .execute("ALTER TABLE threads ADD COLUMN title_override TEXT", []);
        let _ = self.conn.execute(
            "ALTER TABLE threads ADD COLUMN agent TEXT NOT NULL DEFAULT 'native'",
            [],
        );
        let _ = self
            .conn
            .execute("ALTER TABLE threads ADD COLUMN session_id TEXT", []);
        // 旧表迁移：ACP 标题覆盖收敛到 threads.title_override，然后删除旧表。
        self.migrate_legacy_acp_titles()?;
        Ok(())
    }

    pub fn save_thread(&mut self, thread: &Thread) -> Result<(), SessionError> {
        let usage_json = serde_json::to_string(&thread.usage_total)?;
        let transaction = self.conn.transaction()?;
        transaction.execute(
            "INSERT INTO threads (id, title, title_override, agent, session_id, model_provider, model_id, usage_json, created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
             ON CONFLICT(id) DO UPDATE SET
                title = excluded.title,
                title_override = excluded.title_override,
                agent = excluded.agent,
                session_id = excluded.session_id,
                model_provider = excluded.model_provider,
                model_id = excluded.model_id,
                usage_json = excluded.usage_json,
                updated_at = excluded.updated_at",
            params![
                thread.id,
                thread.title,
                thread.title_override,
                thread.agent,
                thread.session_id,
                thread.model.provider_id.as_str(),
                thread.model.model_id.as_str(),
                usage_json,
                thread.created_at,
                thread.updated_at
            ],
        )?;
        transaction.execute(
            "DELETE FROM entries WHERE thread_id = ?1",
            params![thread.id],
        )?;
        for (seq, entry) in thread.entries.iter().enumerate() {
            let kind = entry_kind(entry);
            let payload_json = serde_json::to_string(entry)?;
            transaction.execute(
                "INSERT INTO entries (thread_id, seq, kind, payload_json, created_at)
                 VALUES (?1, ?2, ?3, ?4, ?5)",
                params![thread.id, seq as i64, kind, payload_json, entry_at(entry)],
            )?;
        }
        transaction.commit()?;
        Ok(())
    }

    pub fn load_thread(&self, id: &str) -> Result<Option<Thread>, SessionError> {
        let row = self
            .conn
            .query_row(
                "SELECT title, title_override, agent, session_id, model_provider, model_id, usage_json, created_at, updated_at
                 FROM threads WHERE id = ?1",
                params![id],
                |row| {
                    Ok((
                        row.get::<_, Option<String>>(0)?,
                        row.get::<_, Option<String>>(1)?,
                        row.get::<_, String>(2)?,
                        row.get::<_, Option<String>>(3)?,
                        row.get::<_, String>(4)?,
                        row.get::<_, String>(5)?,
                        row.get::<_, Option<String>>(6)?,
                        row.get::<_, i64>(7)?,
                        row.get::<_, i64>(8)?,
                    ))
                },
            )
            .optional()?;
        let Some((
            title,
            title_override,
            agent,
            session_id,
            provider_id,
            model_id,
            usage_json,
            created_at,
            updated_at,
        )) = row
        else {
            return Ok(None);
        };
        let usage_total: TokenUsage = usage_json
            .as_deref()
            .map(serde_json::from_str)
            .transpose()?
            .unwrap_or_default();
        let mut statement = self
            .conn
            .prepare("SELECT payload_json FROM entries WHERE thread_id = ?1 ORDER BY seq ASC")?;
        let entries = statement
            .query_map(params![id], |row| row.get::<_, String>(0))?
            .map(|payload| -> Result<Entry, SessionError> { Ok(serde_json::from_str(&payload?)?) })
            .collect::<Result<Vec<_>, _>>()?;
        Ok(Some(Thread {
            id: id.to_string(),
            title,
            title_override,
            agent,
            session_id,
            model: SelectedModel::new(ProviderId::new(provider_id), ModelId::new(model_id)),
            entries,
            usage_total,
            created_at,
            updated_at,
        }))
    }

    pub fn list_threads(&self, limit: usize) -> Result<Vec<ThreadSummary>, SessionError> {
        let mut statement = self.conn.prepare(
            "SELECT id, COALESCE(title_override, title), agent, session_id, model_provider, model_id, updated_at
             FROM threads ORDER BY updated_at DESC LIMIT ?1",
        )?;
        let rows = statement.query_map(params![limit as i64], |row| {
            Ok(ThreadSummary {
                id: row.get(0)?,
                title: row.get(1)?,
                agent: row.get(2)?,
                session_id: row.get(3)?,
                provider_id: row.get(4)?,
                model_id: row.get(5)?,
                updated_at: row.get(6)?,
            })
        })?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    /// 旧 `acp_thread_titles` 表迁移到 Thread.title_override 后删除。
    fn migrate_legacy_acp_titles(&self) -> Result<(), SessionError> {
        let legacy_exists: bool = self
            .conn
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='acp_thread_titles'",
                [],
                |row| row.get::<_, i64>(0),
            )
            .map(|count| count > 0)
            .unwrap_or(false);
        if !legacy_exists {
            return Ok(());
        }
        let mut statement = self
            .conn
            .prepare("SELECT session_id, title_override FROM acp_thread_titles")?;
        let rows = statement.query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, Option<String>>(1)?))
        })?;
        for row in rows {
            let (session_id, title) = row?;
            if let Some(title) = title {
                let _ = self.conn.execute(
                    "UPDATE threads SET title_override = COALESCE(title_override, ?2)
                     WHERE id = ?1",
                    params![format!("acp-{session_id}"), title],
                );
            }
        }
        self.conn
            .execute("DROP TABLE IF EXISTS acp_thread_titles", [])?;
        Ok(())
    }

    pub fn save_checkpoint(
        &mut self,
        checkpoint: &cgc_agent_checkpoint::Checkpoint,
        user_entry_seq: i64,
        created_at: i64,
    ) -> Result<(), SessionError> {
        self.conn.execute(
            "INSERT INTO checkpoints
                (thread_id, user_entry_seq, ref, sha, base_head, created_at, state)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'active')
             ON CONFLICT(thread_id, user_entry_seq) DO UPDATE SET
                ref = excluded.ref,
                sha = excluded.sha,
                base_head = excluded.base_head,
                created_at = excluded.created_at,
                state = 'active'",
            params![
                checkpoint.thread_id,
                user_entry_seq,
                checkpoint.ref_name,
                checkpoint.sha,
                checkpoint.base_head,
                created_at
            ],
        )?;
        Ok(())
    }

    pub fn list_checkpoints(&self, thread_id: &str) -> Result<Vec<CheckpointRecord>, SessionError> {
        let mut statement = self.conn.prepare(
            "SELECT thread_id, user_entry_seq, ref, sha, base_head, created_at, state
             FROM checkpoints WHERE thread_id = ?1 ORDER BY user_entry_seq ASC",
        )?;
        let rows = statement.query_map(params![thread_id], |row| {
            Ok(CheckpointRecord {
                thread_id: row.get(0)?,
                user_entry_seq: row.get(1)?,
                ref_name: row.get(2)?,
                sha: row.get(3)?,
                base_head: row.get(4)?,
                created_at: row.get(5)?,
                state: row.get(6)?,
            })
        })?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    pub fn mark_checkpoint_invalid(
        &mut self,
        thread_id: &str,
        user_entry_seq: i64,
    ) -> Result<bool, SessionError> {
        let updated = self.conn.execute(
            "UPDATE checkpoints SET state = 'invalid' WHERE thread_id = ?1 AND user_entry_seq = ?2",
            params![thread_id, user_entry_seq],
        )?;
        Ok(updated > 0)
    }

    pub fn delete_thread(&mut self, id: &str) -> Result<bool, SessionError> {
        let deleted = self
            .conn
            .execute("DELETE FROM threads WHERE id = ?1", params![id])?;
        Ok(deleted > 0)
    }
}

fn entry_kind(entry: &Entry) -> &'static str {
    match entry {
        Entry::User { .. } => "user",
        Entry::Assistant { .. } => "assistant",
        Entry::Thinking { .. } => "thinking",
        Entry::ToolResult { .. } => "tool_result",
        Entry::Compaction { .. } => "compaction",
    }
}

fn entry_at(entry: &Entry) -> i64 {
    match entry {
        Entry::User { at, .. }
        | Entry::Assistant { at, .. }
        | Entry::Thinking { at, .. }
        | Entry::ToolResult { at, .. }
        | Entry::Compaction { at, .. } => *at,
    }
}

#[cfg(test)]
mod tests {
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
        thread.push_compaction("历史摘要内容", 12);
        store.save_thread(&thread).expect("save");
        let loaded = store.load_thread("t1").expect("load").expect("present");
        assert!(loaded.entries.iter().any(
            |entry| matches!(entry, Entry::Compaction { summary, .. } if summary == "历史摘要内容")
        ));
    }

    #[test]
    fn missing_thread_returns_none() {
        let store = SessionStore::open_in_memory().expect("store");
        assert!(store.load_thread("nope").expect("load").is_none());
    }
}

#[cfg(test)]
mod title_override_tests {
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
}
