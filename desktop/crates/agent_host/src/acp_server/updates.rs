//! native 运行时事件 → ACP `SessionUpdate` 的唯一映射（Stage 3.1 Phase A）。
//!
//! 只做协议形状转换：native 的 `AgentEvent`（runtime 出口）在这里变成 ACP
//! `session/update` 通知；UI 侧再走客户端既有 `SessionUpdate → HostEvent` 映射，
//! 于是两轨共用同一份 ingestion。表达不了的 native 专属事件（子 agent 实时进度）
//! 不在本模块映射，保持 native 辅助通道（Phase B 再收口）。

use agent_client_protocol::schema::v1::{
    CompactionStatus, CompactionUpdate, ContentBlock, ContentChunk, SessionUpdate, TextContent,
    ToolCall, ToolCallStatus, ToolCallUpdate, ToolCallUpdateFields, ToolKind, UsageUpdate,
};
use futures::channel::mpsc::UnboundedSender;

use crate::events::AgentEvent;

/// 一个 turn 内的映射状态：最终文本兜底、compaction 序号、上下文窗口大小。
pub(crate) struct UpdateTicket {
    context_size: u64,
    saw_text_delta: bool,
    compaction_serial: u64,
}

impl UpdateTicket {
    pub(crate) fn new(context_size: u64) -> Self {
        Self {
            context_size,
            saw_text_delta: false,
            compaction_serial: 0,
        }
    }

    /// 把一条 runtime 事件映射成 0..n 条 ACP update。审批请求不在此列：
    /// 它走 `session/request_permission`（[`super::PermissionBridge`]），
    /// 避免同一审批同时以 update 与 request 重复到达客户端。
    pub(crate) fn updates(&mut self, event: &AgentEvent) -> Vec<SessionUpdate> {
        match event {
            // 用户消息由客户端在发 prompt 时落行；native turn 开始不重复发。
            AgentEvent::TurnStarted { .. } => Vec::new(),
            AgentEvent::TextDelta { text } => {
                self.saw_text_delta = true;
                vec![message_chunk(text.clone())]
            }
            AgentEvent::ThinkingDelta { text } => {
                vec![SessionUpdate::AgentThoughtChunk(ContentChunk::new(
                    ContentBlock::Text(TextContent::new(text.clone())),
                ))]
            }
            AgentEvent::ToolCallStarted {
                tool_call_id,
                tool_name,
                args,
            } => vec![SessionUpdate::ToolCall(
                ToolCall::new(tool_call_id.clone(), tool_name.clone())
                    .name(tool_name.clone())
                    .kind(tool_kind(tool_name))
                    .status(ToolCallStatus::InProgress)
                    .raw_input(args.clone()),
            )],
            // 审批由 request_permission 桥接；observer 侧忽略它（去重）。
            AgentEvent::PermissionRequested { .. } => Vec::new(),
            AgentEvent::ToolCallFinished {
                tool_call_id,
                ok,
                content,
                ..
            } => vec![SessionUpdate::ToolCallUpdate(ToolCallUpdate::new(
                tool_call_id.clone(),
                ToolCallUpdateFields::new()
                    .status(Some(if *ok {
                        ToolCallStatus::Completed
                    } else {
                        ToolCallStatus::Failed
                    }))
                    .raw_output(Some(serde_json::Value::String(content.clone()))),
            ))],
            AgentEvent::UsageUpdated { usage, .. } => vec![SessionUpdate::UsageUpdate(
                UsageUpdate::new(usage.total(), self.context_size),
            )],
            AgentEvent::ContextCompacted { omitted_entries } => {
                self.compaction_serial += 1;
                let compaction = CompactionUpdate::new(
                    format!("native-compaction-{}", self.compaction_serial),
                    CompactionStatus::Completed,
                )
                .summary(vec![ContentBlock::Text(TextContent::new(format!(
                    "省略 {omitted_entries} 条更早消息"
                )))]);
                vec![SessionUpdate::CompactionUpdate(compaction)]
            }
            // 收尾：本轮没有任何流式文本时，把最终文本作为单个 chunk 补发，
            // 行为对齐原 `HostState::apply` 的 TurnFinished 兜底。
            AgentEvent::TurnFinished { text, .. } => {
                if !text.is_empty() && !self.saw_text_delta {
                    vec![message_chunk(text.clone())]
                } else {
                    Vec::new()
                }
            }
            // 已在 turn 开始时整段补发为 user_message_chunk。
            AgentEvent::FollowUpStarted { text } | AgentEvent::SteerStarted { text } => {
                vec![SessionUpdate::UserMessageChunk(ContentChunk::new(
                    ContentBlock::Text(TextContent::new(text.clone())),
                ))]
            }
            // 子 agent 实时进度 ACP v1 表达不了：留在 native 辅助通道（Phase B）。
            AgentEvent::SubagentStarted { .. }
            | AgentEvent::SubagentProgress { .. }
            | AgentEvent::SubagentFinished { .. } => Vec::new(),
            // turn 级错误由 prompt 响应（JSON-RPC error）表达，不是 update。
            AgentEvent::Error { .. } => Vec::new(),
        }
    }
}

fn message_chunk(text: String) -> SessionUpdate {
    SessionUpdate::AgentMessageChunk(ContentChunk::new(ContentBlock::Text(TextContent::new(
        text,
    ))))
}

fn tool_kind(tool_name: &str) -> ToolKind {
    match tool_name {
        "read_file" => ToolKind::Read,
        "write_file" | "edit_file" => ToolKind::Edit,
        "list_directory" => ToolKind::Search,
        "run_command" => ToolKind::Execute,
        "task" => ToolKind::Think,
        _ => ToolKind::Other,
    }
}

/// `TurnObserver` → ACP 通知泵的发送端。runtime 侧只管把 `AgentEvent` 投进来。
pub(crate) struct EventSink {
    sender: UnboundedSender<super::PumpMessage>,
}

impl EventSink {
    pub(crate) fn new(sender: UnboundedSender<super::PumpMessage>) -> Self {
        Self { sender }
    }

    fn emit(&self, event: AgentEvent) {
        let _ = self.sender.unbounded_send(super::PumpMessage::Event(event));
    }
}

impl cgc_agent_core::TurnObserver for EventSink {
    fn on_turn_started(&mut self, thread_id: &str) {
        self.emit(AgentEvent::TurnStarted {
            thread_id: thread_id.to_string(),
        });
    }

    fn on_follow_up_started(&mut self, text: &str) {
        self.emit(AgentEvent::FollowUpStarted {
            text: text.to_string(),
        });
    }

    fn on_steer_started(&mut self, text: &str) {
        self.emit(AgentEvent::SteerStarted {
            text: text.to_string(),
        });
    }

    fn on_compaction(&mut self, omitted_entries: usize) {
        self.emit(AgentEvent::ContextCompacted { omitted_entries });
    }

    fn on_text(&mut self, delta: &str) {
        self.emit(AgentEvent::TextDelta {
            text: delta.to_string(),
        });
    }

    fn on_thinking(&mut self, delta: &str) {
        self.emit(AgentEvent::ThinkingDelta {
            text: delta.to_string(),
        });
    }

    fn on_tool_call(&mut self, tool_use: &cgc_agent_provider::ToolUse) {
        self.emit(AgentEvent::ToolCallStarted {
            tool_call_id: tool_use.id.clone(),
            tool_name: tool_use.name.clone(),
            args: tool_use.args.clone(),
        });
    }

    fn on_permission_request(&mut self, request: &cgc_agent_core::ApprovalRequest) {
        // 审批单独走 request_permission 桥；这里仍记录事件但映射为 None，
        // 保证「一次审批只有一条客户端事件」。
        self.emit(AgentEvent::PermissionRequested {
            tool_call_id: request.tool_call_id.clone(),
            tool_name: request.tool_name.clone(),
            args: request.args.clone(),
        });
    }

    fn on_tool_result(&mut self, summary: &cgc_agent_core::ToolResultSummary) {
        self.emit(AgentEvent::ToolCallFinished {
            tool_call_id: summary.tool_use_id.clone(),
            tool_name: summary.tool_name.clone(),
            ok: !summary.is_error,
            content: summary.content.clone(),
        });
    }

    fn on_usage(
        &mut self,
        usage: cgc_agent_provider::TokenUsage,
        total: cgc_agent_provider::TokenUsage,
    ) {
        self.emit(AgentEvent::UsageUpdated { usage, total });
    }

    fn on_finished(&mut self, outcome: &cgc_agent_core::ToolTurnOutcome) {
        self.emit(AgentEvent::TurnFinished {
            text: outcome.text.clone(),
            stop_reason: outcome.stop_reason.clone(),
        });
    }
}
