//! CGC Desktop 的「学习搭子」domain crate（Zed `agent_ui` 的子集）。
//!
//! 只负责课程页对话的 UI 与视图模型：面板、会话视图、审批卡、历史、每 agent 设置。
//! ACP 协议与 agent 进程在 `cgc-platform` 的 `acp` / `agent` 模块，不在本 crate（脊柱 AD-1、AD-4）。
//!
//! Stage 1 起承载双栈共享层：`message_flow`（消息操作栏/复制/滚动的纯判定）与
//! `markdown_text`（Markdown→纯文本）。两套视图各自提供「行分类 + assistant 文本」
//! 窄函数构造 `RowView`，不反向依赖彼此。

pub mod approval;
pub mod conversation;
pub mod history;
pub mod markdown_text;
pub mod message_flow;
pub mod panel;
pub mod settings;

pub mod registration;
