//! native agent 的协议层（设计稿 §12 / Stage 3 设计 §4 Phase A）。
//!
//! `AgentCommand`（客户端 → agent）、`AgentEvent`（agent 运行时出口）、
//! `TurnObserver` 适配器，以及 `acp_server`（native 进程内 ACP server）。
//!
//! 客户端侧的事件归约（旧 `HostState`）已删除：native 运行时经进程内 ACP server
//! 输出 `SessionUpdate`，与外部 ACP agent 在客户端侧走同一份 ingestion。

pub mod acp_server;
pub mod adapter;
pub mod commands;
pub mod events;
pub mod slash;

pub use acp_server::{
    allow_pattern_option_id, permission_pattern_prefix, CancelSwitch, ContextSizeHandle,
    NativeAcpServer, NativeAcpServerConfig, NativeTurn, NativeTurnRuntime, OPTION_ALLOW_ONCE,
    OPTION_ALLOW_SESSION, OPTION_DENY,
};
pub use adapter::{AsyncChannelObserver, ChannelObserver, EventCollector};
pub use commands::{AgentCommand, PermissionDecision};
pub use events::AgentEvent;
pub use slash::{parse as parse_slash, SlashCommand, COMMANDS as SLASH_COMMANDS};
