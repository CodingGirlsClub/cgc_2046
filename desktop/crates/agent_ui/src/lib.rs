//! CGC Desktop 的「学习搭子」domain crate（Zed `agent_ui` 的子集）。
//!
//! 只负责课程页对话的 UI 与视图模型：面板、会话视图、审批卡、历史、每 agent 设置。
//! ACP 协议与 agent 进程在 `cgc-platform` 的 `acp` / `agent` 模块，不在本 crate（脊柱 AD-1、AD-4）。
//!
//! Stage 1 起承载双栈共享渲染层；Stage 2 起 gpui-free 的会话模型/消息流拆到
//! `cgc_agent_conversation`，本 crate 保留 `conversation` / `message_flow` 的 re-export
//! 以免下游改路径。

pub mod command_menu;
pub mod composer;
pub mod history;
pub mod markdown_text;
pub mod markdown_view;
pub mod message_actions;
pub mod message_row;
pub mod panel;
pub mod permission_card;
pub mod picker;
pub mod settings;
pub mod subagent_row;

// 共享会话模型 crate（gpui-free）；保留 `agent_ui::conversation` / `message_flow` 路径。
pub use cgc_agent_conversation::{conversation, message_flow};

pub mod registration;
pub mod safe_markdown;
