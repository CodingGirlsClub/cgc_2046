use serde::{Deserialize, Serialize};

/// 客户端 → agent 的命令（P1 最小集）。
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum AgentCommand {
    Prompt {
        text: String,
    },
    /// turn 运行中排队，结束后执行。
    FollowUp {
        text: String,
    },
    Stop,
    PermissionResponse {
        tool_call_id: String,
        decision: PermissionDecision,
    },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum PermissionDecision {
    AllowOnce,
    AllowForSession,
    Deny,
}
