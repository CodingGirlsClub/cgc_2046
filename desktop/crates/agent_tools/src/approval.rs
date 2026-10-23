/// 工具对一次调用的审批要求。
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Approval {
    /// 只读、工作区内，直接允许。
    Allow,
    /// 硬拒绝，理由直接回给模型。
    Deny(String),
    /// 需要用户确认。
    Ask,
}

/// 用户对审批请求的答复。
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ApprovalDecision {
    AllowOnce,
    AllowForSession,
    /// 允许本会话内匹配该前缀/模式的一类调用（如 `cargo` 前缀命令）。
    AllowPattern(String),
    Deny,
}
