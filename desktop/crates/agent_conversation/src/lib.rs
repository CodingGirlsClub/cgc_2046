//! 客户端会话模型（Stage 2）：双栈共享的协议无关会话状态 + 消息流纯逻辑。
//!
//! 本 crate 不依赖 gpui，也不依赖任何运行时（provider/tools/store/MCP）；
//! `agent_ui` 在其上做渲染，`agent_host`（native 运行时）用它承载事件归约结果。
//!
//! - [`message_flow`]：操作栏 gating / 整回合复制 / Scroll to User 的纯判定；
//! - [`conversation`]：`ConversationThread` / `Entry` / `ThreadEvent` / reducer / 能力位。

pub mod conversation;
pub mod message_flow;
