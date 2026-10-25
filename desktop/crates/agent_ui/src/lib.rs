//! CGC Desktop 的「学习搭子」domain crate（Zed `agent_ui` 的子集）。
//!
//! 只负责课程页对话的 UI 与视图模型：面板、会话视图、审批卡、历史、每 agent 设置。
//! ACP 协议与 agent 进程在 `cgc-platform` 的 `acp` / `agent` 模块，不在本 crate（脊柱 AD-1、AD-4）。

pub mod approval;
pub mod conversation;
pub mod history;
pub mod panel;
pub mod settings;

pub mod registration;
