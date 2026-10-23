//! 第一方 native agent 的工具层（设计稿 §3.3，P1a 起步）。
//!
//! 当前提供：Tool trait、工作区路径约束、审批分类，以及只读工具
//! `read_file` / `list_directory`。写入工具、终端与沙箱在后续切片加入。

pub mod approval;
pub mod builtin;
pub mod error;
pub mod registry;
pub mod sandbox;
pub mod state;
pub mod tool;

pub use approval::{Approval, ApprovalDecision};
pub use error::ToolError;
pub use registry::ToolRegistry;
pub use sandbox::{CommandSandbox, SandboxKind, SandboxPolicy};
pub use state::{AgentState, Goal, ItemStatus, PlanStep, SharedAgentState, TodoItem};
pub use tool::{Tool, ToolContext, ToolResult};
