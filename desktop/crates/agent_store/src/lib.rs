//! native agent 的本地偏好存储（P0 T4）。
//!
//! 当前只存模型选择；会话内容在 P1b 用 SQLite 单独存，不混在这里。

pub mod audit;
pub mod conversations;
pub mod model_lines;
pub mod prefs;
pub mod sessions;
pub mod snapshot;
pub mod writer;

pub use audit::{ActionAuditEntry, AuditLog};
pub use conversations::{
    format_epoch_rfc3339, now_utc_rfc3339, ConversationStore, ConversationStoreError,
    SidebarThread, CONVERSATIONS_DB, SCHEMA_VERSION,
};
pub use model_lines::{format_model_lines, normalized_provider_name, parse_model_lines};
pub use prefs::{
    builtin_providers, provider_key_account, AgentPrefs, ModelPrefs, PrefsError, PrefsStore,
    ProviderPrefs,
};
pub use sessions::{CheckpointRecord, SessionError, SessionStore, ThreadSummary};
pub use snapshot::{SavedConversation, SnapshotSource};
pub use writer::{StoreTarget, StoreWriter, WriterCommand};
