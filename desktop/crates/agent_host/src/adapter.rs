use std::sync::mpsc::Sender;

use futures::channel::mpsc::UnboundedSender;

use cgc_agent_core::{ApprovalRequest, ToolResultSummary, ToolTurnOutcome, TurnObserver};
use cgc_agent_provider::TokenUsage;
use cgc_agent_provider::ToolUse;

use crate::events::AgentEvent;

/// 收集事件的 observer（测试、回放）。
#[derive(Default)]
pub struct EventCollector {
    events: Vec<AgentEvent>,
}

impl EventCollector {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn events(&self) -> &[AgentEvent] {
        &self.events
    }

    pub fn into_events(self) -> Vec<AgentEvent> {
        self.events
    }
}

impl TurnObserver for EventCollector {
    fn on_turn_started(&mut self, thread_id: &str) {
        self.events.push(AgentEvent::TurnStarted {
            thread_id: thread_id.to_string(),
        });
    }

    fn on_text(&mut self, delta: &str) {
        self.events.push(AgentEvent::TextDelta {
            text: delta.to_string(),
        });
    }

    fn on_tool_call(&mut self, tool_use: &ToolUse) {
        self.events.push(AgentEvent::ToolCallStarted {
            tool_call_id: tool_use.id.clone(),
            tool_name: tool_use.name.clone(),
            args: tool_use.args.clone(),
        });
    }

    fn on_permission_request(&mut self, request: &ApprovalRequest) {
        self.events.push(AgentEvent::PermissionRequested {
            tool_call_id: request.tool_call_id.clone(),
            tool_name: request.tool_name.clone(),
            args: request.args.clone(),
        });
    }

    fn on_tool_result(&mut self, summary: &ToolResultSummary) {
        self.events.push(AgentEvent::ToolCallFinished {
            tool_call_id: summary.tool_use_id.clone(),
            tool_name: summary.tool_name.clone(),
            ok: !summary.is_error,
            content: summary.content.clone(),
        });
    }

    fn on_usage(&mut self, usage: TokenUsage, total: TokenUsage) {
        self.events.push(AgentEvent::UsageUpdated { usage, total });
    }

    fn on_finished(&mut self, outcome: &ToolTurnOutcome) {
        self.events.push(AgentEvent::TurnFinished {
            text: outcome.text.clone(),
            stop_reason: outcome.stop_reason.clone(),
        });
    }
}

/// 把事件转发到 channel 的 observer（UI 侧使用）。
pub struct ChannelObserver {
    sender: Sender<AgentEvent>,
}

impl ChannelObserver {
    pub fn new(sender: Sender<AgentEvent>) -> Self {
        Self { sender }
    }
}

impl TurnObserver for ChannelObserver {
    fn on_turn_started(&mut self, thread_id: &str) {
        let _ = self.sender.send(AgentEvent::TurnStarted {
            thread_id: thread_id.to_string(),
        });
    }

    fn on_text(&mut self, delta: &str) {
        let _ = self.sender.send(AgentEvent::TextDelta {
            text: delta.to_string(),
        });
    }

    fn on_tool_call(&mut self, tool_use: &ToolUse) {
        let _ = self.sender.send(AgentEvent::ToolCallStarted {
            tool_call_id: tool_use.id.clone(),
            tool_name: tool_use.name.clone(),
            args: tool_use.args.clone(),
        });
    }

    fn on_permission_request(&mut self, request: &ApprovalRequest) {
        let _ = self.sender.send(AgentEvent::PermissionRequested {
            tool_call_id: request.tool_call_id.clone(),
            tool_name: request.tool_name.clone(),
            args: request.args.clone(),
        });
    }

    fn on_tool_result(&mut self, summary: &ToolResultSummary) {
        let _ = self.sender.send(AgentEvent::ToolCallFinished {
            tool_call_id: summary.tool_use_id.clone(),
            tool_name: summary.tool_name.clone(),
            ok: !summary.is_error,
            content: summary.content.clone(),
        });
    }

    fn on_usage(&mut self, usage: TokenUsage, total: TokenUsage) {
        let _ = self.sender.send(AgentEvent::UsageUpdated { usage, total });
    }

    fn on_finished(&mut self, outcome: &ToolTurnOutcome) {
        let _ = self.sender.send(AgentEvent::TurnFinished {
            text: outcome.text.clone(),
            stop_reason: outcome.stop_reason.clone(),
        });
    }
}

/// 把事件转发到 futures 无界 channel 的 observer（GPUI 的 async 事件循环使用）。
pub struct AsyncChannelObserver {
    sender: UnboundedSender<AgentEvent>,
}

impl AsyncChannelObserver {
    pub fn new(sender: UnboundedSender<AgentEvent>) -> Self {
        Self { sender }
    }
}

impl TurnObserver for AsyncChannelObserver {
    fn on_turn_started(&mut self, thread_id: &str) {
        let _ = self.sender.unbounded_send(AgentEvent::TurnStarted {
            thread_id: thread_id.to_string(),
        });
    }

    fn on_text(&mut self, delta: &str) {
        let _ = self.sender.unbounded_send(AgentEvent::TextDelta {
            text: delta.to_string(),
        });
    }

    fn on_tool_call(&mut self, tool_use: &ToolUse) {
        let _ = self.sender.unbounded_send(AgentEvent::ToolCallStarted {
            tool_call_id: tool_use.id.clone(),
            tool_name: tool_use.name.clone(),
            args: tool_use.args.clone(),
        });
    }

    fn on_permission_request(&mut self, request: &ApprovalRequest) {
        let _ = self.sender.unbounded_send(AgentEvent::PermissionRequested {
            tool_call_id: request.tool_call_id.clone(),
            tool_name: request.tool_name.clone(),
            args: request.args.clone(),
        });
    }

    fn on_tool_result(&mut self, summary: &ToolResultSummary) {
        let _ = self.sender.unbounded_send(AgentEvent::ToolCallFinished {
            tool_call_id: summary.tool_use_id.clone(),
            tool_name: summary.tool_name.clone(),
            ok: !summary.is_error,
            content: summary.content.clone(),
        });
    }

    fn on_usage(&mut self, usage: TokenUsage, total: TokenUsage) {
        let _ = self
            .sender
            .unbounded_send(AgentEvent::UsageUpdated { usage, total });
    }

    fn on_finished(&mut self, outcome: &ToolTurnOutcome) {
        let _ = self.sender.unbounded_send(AgentEvent::TurnFinished {
            text: outcome.text.clone(),
            stop_reason: outcome.stop_reason.clone(),
        });
    }
}
