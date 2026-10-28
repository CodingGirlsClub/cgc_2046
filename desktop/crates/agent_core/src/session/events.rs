use cgc_agent_provider::{StopReason, TokenUsage, ToolUse};
use cgc_agent_tools::ApprovalDecision;
use futures::future::BoxFuture;

/// 一轮对话的结果。
#[derive(Clone, Debug, PartialEq)]
pub struct TurnOutcome {
    pub text: String,
    pub usage: TokenUsage,
    pub stop_reason: StopReason,
    pub tool_calls: Vec<ToolUse>,
}

/// 工具循环结束后的结果。
#[derive(Clone, Debug, PartialEq)]
pub struct ToolTurnOutcome {
    pub text: String,
    pub usage: TokenUsage,
    pub stop_reason: StopReason,
    pub tool_calls: Vec<ToolUse>,
    pub tool_results: Vec<ToolResultSummary>,
}

/// 一次工具执行的结果摘要，供 UI/日志使用。
#[derive(Clone, Debug, PartialEq)]
pub struct ToolResultSummary {
    pub tool_use_id: String,
    pub tool_name: String,
    pub content: String,
    pub is_error: bool,
}

/// 需要用户确认的审批请求。
#[derive(Clone, Debug, PartialEq)]
pub struct ApprovalRequest {
    pub tool_call_id: String,
    pub tool_name: String,
    pub args: serde_json::Value,
}

/// 审批回调。UI 在后台任务里等待用户点击，然后 resolve。
pub trait Approver: Send + Sync {
    fn decide(&self, request: ApprovalRequest) -> BoxFuture<'static, ApprovalDecision>;
}

/// 一轮 turn 的过程事件。UI/Host 通过它把流式过程渲染出来。
pub trait TurnObserver: Send {
    fn on_turn_started(&mut self, _thread_id: &str) {}
    fn on_follow_up_started(&mut self, _text: &str) {}
    fn on_steer_started(&mut self, _text: &str) {}
    fn on_compaction(&mut self, _omitted_entries: usize) {}
    fn on_text(&mut self, _delta: &str) {}
    fn on_thinking(&mut self, _delta: &str) {}
    fn on_tool_call(&mut self, _tool_use: &ToolUse) {}
    fn on_permission_request(&mut self, _request: &ApprovalRequest) {}
    fn on_tool_result(&mut self, _summary: &ToolResultSummary) {}
    fn on_usage(&mut self, _usage: TokenUsage, _total: TokenUsage) {}
    fn on_context_estimate(&mut self, _tokens: usize, _image_cost_unknown: bool) {}
    fn on_finished(&mut self, _outcome: &ToolTurnOutcome) {}
}

/// 不关心过程的调用方（测试、无 UI 场景）。
pub struct NoopObserver;

impl TurnObserver for NoopObserver {}

/// 无人值守场景（测试、CLI demo）：全部允许一次。
pub struct AutoApprover;

impl Approver for AutoApprover {
    fn decide(&self, _request: ApprovalRequest) -> BoxFuture<'static, ApprovalDecision> {
        Box::pin(async { ApprovalDecision::AllowOnce })
    }
}

/// 全部拒绝，用于演示拒绝路径。
pub struct DenyApprover;

impl Approver for DenyApprover {
    fn decide(&self, _request: ApprovalRequest) -> BoxFuture<'static, ApprovalDecision> {
        Box::pin(async { ApprovalDecision::Deny })
    }
}
