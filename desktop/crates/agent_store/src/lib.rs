//! native agent 的本地偏好存储（P0 T4）。
//!
//! 当前只存模型选择；会话内容在 P1b 用 SQLite 单独存，不混在这里。

pub mod prefs;

pub use prefs::{AgentPrefs, PrefsError, PrefsStore};
