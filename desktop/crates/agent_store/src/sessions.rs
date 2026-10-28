use std::path::Path;

use crate::snapshot::{SavedConversation, SnapshotSource};
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
            CREATE TABLE IF NOT EXISTS thread_snapshots (
                thread_id TEXT PRIMARY KEY REFERENCES threads(id) ON DELETE CASCADE,
                revision INTEGER NOT NULL,
                source TEXT NOT NULL,
                data TEXT NOT NULL,
                updated_at INTEGER NOT NULL
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

    /// 执行内容与展示投影在同一事务里提交：二者不能只写一半。
    pub fn save_thread_with_snapshot(
        &mut self,
        thread: &Thread,
        snapshot: &SavedConversation,
    ) -> Result<(), SessionError> {
        let transaction = self.conn.transaction()?;
        Self::write_thread(&transaction, thread)?;
        transaction.execute(
            "INSERT INTO thread_snapshots (thread_id, revision, source, data, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5)
             ON CONFLICT(thread_id) DO UPDATE SET
                 revision = excluded.revision,
                 source = excluded.source,
                 data = excluded.data,
                 updated_at = excluded.updated_at
             WHERE excluded.revision >= thread_snapshots.revision",
            params![
                snapshot.thread_id,
                snapshot.revision as i64,
                snapshot_source_label(snapshot.source),
                serde_json::to_string(snapshot)?,
                now_epoch()
            ],
        )?;
        transaction.commit()?;
        Ok(())
    }

    /// 读取展示投影；旧 thread 没有快照时返回 `None`，调用方从 entries 生成一次投影。
    pub fn load_snapshot(
        &self,
        thread_id: &str,
    ) -> Result<Option<SavedConversation>, SessionError> {
        let data: Option<String> = self
            .conn
            .query_row(
                "SELECT data FROM thread_snapshots WHERE thread_id = ?1",
                params![thread_id],
                |row| row.get(0),
            )
            .optional()?;
        Ok(data.and_then(|data| serde_json::from_str(&data).ok()))
    }

    pub fn save_thread(&mut self, thread: &Thread) -> Result<(), SessionError> {
        let transaction = self.conn.transaction()?;
        Self::write_thread(&transaction, thread)?;
        transaction.commit()?;
        Ok(())
    }

    /// 执行内容的实际写入；调用方负责事务与提交，便于与投影原子配对。
    fn write_thread(
        transaction: &rusqlite::Transaction<'_>,
        thread: &Thread,
    ) -> Result<(), SessionError> {
        let usage_json = serde_json::to_string(&thread.usage_total)?;
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
mod tests;
#[cfg(test)]
mod title_override_tests;

fn snapshot_source_label(source: SnapshotSource) -> &'static str {
    match source {
        SnapshotSource::Acp => "acp",
        SnapshotSource::Native => "native",
    }
}

fn now_epoch() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_secs() as i64)
        .unwrap_or_default()
}
