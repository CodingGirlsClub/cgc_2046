//! native agent 的 Host 协议层（设计稿 §12）。
//!
//! `AgentCommand`（客户端 → agent）、`AgentEvent`（agent → 客户端）、
//! `HostState`（事件归约成 UI 状态）与 `TurnObserver` 适配器。
//! P1 先覆盖 prompt / stop / 文本流 / 工具调用 / 审批 / 用量 / 结束。

pub mod adapter;
pub mod commands;
pub mod events;
pub mod state;

pub use adapter::{ChannelObserver, EventCollector};
pub use commands::{AgentCommand, PermissionDecision};
pub use events::AgentEvent;
pub use state::{HostState, PermissionPrompt, UiMessage, UiRole};
