use serde::{Deserialize, Serialize};

use cgc_agent_provider::{StopReason, TokenUsage};

/// agent → 客户端的事件。
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub enum AgentEvent {
    TurnStarted {
        thread_id: String,
    },
    TextDelta {
        text: String,
    },
    ToolCallStarted {
        tool_call_id: String,
        tool_name: String,
        args: serde_json::Value,
    },
    PermissionRequested {
        tool_call_id: String,
        tool_name: String,
        args: serde_json::Value,
    },
    ToolCallFinished {
        tool_call_id: String,
        tool_name: String,
        ok: bool,
        content: String,
    },
    UsageUpdated {
        usage: TokenUsage,
        total: TokenUsage,
    },
    TurnFinished {
        text: String,
        stop_reason: StopReason,
    },
    Error {
        message: String,
    },
}
