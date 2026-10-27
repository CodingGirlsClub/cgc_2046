//! 第一方 native agent 的会话核心（设计稿 §3.2 / §4，P1a 起步）。
//!
//! 当前提供：Thread / Entry 数据模型、`Agent` 的单轮 loop（流式文本、
//! 用量累计、停止原因、取消、tool_call 收集），以及 provider 之上的
//! 请求构建。工具执行、审批、持久化在后续切片加入。

mod context;
pub mod session;
pub mod thread;

pub use session::{
    run_subagent, Agent, AgentError, ApprovalRequest, Approver, AutoApprover, CancelToken,
    DenyApprover, NoopObserver, ToolResultSummary, ToolTurnOutcome, TurnObserver, TurnOutcome,
    MAX_FOLLOW_UP_TURNS, MAX_STEERS, MAX_TOOL_STEPS,
};
pub use thread::{Entry, ImageAttachment, SelectedModel, Thread};
