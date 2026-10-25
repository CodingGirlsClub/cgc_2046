//! native 运行时事件归约：`AgentEvent` → 共享会话模型 + native 专属 UI 状态。
//!
//! Stage 2d 起 `HostState` 不再维护自己的消息列表；所有对话行由
//! `cgc_agent_conversation::conversation::ConversationThread` 承载，视图只读模型。
//! 这里只保留视图仍需要的 native 专属状态（子 agent 卡、审批提示、用量、错误）。

use cgc_agent_conversation::conversation::{
    ConversationThread, NoticeLevel, ThreadCapabilities, ThreadEvent,
};
use cgc_agent_provider::TokenUsage;
use serde::{Deserialize, Serialize};

use crate::events::AgentEvent;

/// 子 agent 卡片状态（P2 实时进度）。
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SubagentCard {
    pub task: String,
    pub text: String,
    /// `None` 表示仍在运行。
    pub finished: Option<bool>,
    /// 触发该子 agent 的 task tool call id。
    #[serde(default)]
    pub tool_call_id: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct PermissionPrompt {
    pub tool_call_id: String,
    pub tool_name: String,
    pub args: serde_json::Value,
}

/// 事件归约出的 native 状态。UI 只读它渲染，不反向改 agent 线程。
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct HostState {
    /// 共享会话模型（对话行的唯一来源）。
    #[serde(skip)]
    pub thread: ConversationThread,
    /// 当前 model 的 context window，用于 usage 百分比。
    #[serde(skip)]
    pub context_size: u64,
    pub pending_permission: Option<PermissionPrompt>,
    pub usage_total: TokenUsage,
    pub last_error: Option<String>,
    #[serde(default)]
    pub subagents: Vec<SubagentCard>,
    #[serde(default)]
    pub last_tool_call_id: Option<String>,
    /// 本轮是否收到过流式文本（TurnFinished 无增量时补最终文本用）。
    #[serde(skip)]
    saw_text_delta: bool,
}

impl HostState {
    pub fn new() -> Self {
        Self {
            thread: ConversationThread::new("native")
                .with_capabilities(ThreadCapabilities::native()),
            ..Self::default()
        }
    }

    pub fn set_context_size(&mut self, size: u64) {
        self.context_size = size;
    }

    pub fn retry_available(&self) -> bool {
        self.last_error.is_some()
    }

    /// 允许重试时清掉错误；没有错误则返回 false。
    pub fn begin_retry(&mut self) -> bool {
        if self.last_error.is_none() {
            return false;
        }
        self.last_error = None;
        true
    }

    /// 追加一条系统提示（进共享模型 Notice）。
    pub fn push_notice(&mut self, text: impl Into<String>) {
        self.thread.apply(ThreadEvent::Notice {
            level: NoticeLevel::Info,
            text: text.into(),
        });
    }

    /// 清理待审批提示；返回被清理的 prompt（供 UI 回传决定）。
    pub fn resolve_permission(&mut self, tool_call_id: &str) -> Option<PermissionPrompt> {
        let prompt = self.pending_permission.clone()?;
        if prompt.tool_call_id != tool_call_id {
            return None;
        }
        self.pending_permission = None;
        Some(prompt)
    }

    pub fn apply(&mut self, event: AgentEvent) {
        self.apply_native_state(&event);
        if let Some(thread_event) = thread_event(&event, self.context_size) {
            self.thread.apply(thread_event);
        }
    }

    fn apply_native_state(&mut self, event: &AgentEvent) {
        match event {
            AgentEvent::TurnStarted { .. } => {
                self.last_error = None;
                self.saw_text_delta = false;
            }
            AgentEvent::TextDelta { .. } => self.saw_text_delta = true,
            AgentEvent::ThinkingDelta { .. } => {}
            AgentEvent::SubagentStarted { task } => {
                if self.subagents.len() >= 20 {
                    self.subagents.remove(0);
                }
                self.subagents.push(SubagentCard {
                    task: task.clone(),
                    text: String::new(),
                    finished: None,
                    tool_call_id: self.last_tool_call_id.clone(),
                });
            }
            AgentEvent::SubagentProgress { text } => {
                if let Some(card) = self
                    .subagents
                    .iter_mut()
                    .rev()
                    .find(|card| card.finished.is_none())
                {
                    card.text.push_str(text);
                }
            }
            AgentEvent::SubagentFinished { ok } => {
                if let Some(card) = self
                    .subagents
                    .iter_mut()
                    .rev()
                    .find(|card| card.finished.is_none())
                {
                    card.finished = Some(*ok);
                }
            }
            AgentEvent::ToolCallStarted { tool_call_id, .. } => {
                self.last_tool_call_id = Some(tool_call_id.clone());
            }
            AgentEvent::PermissionRequested {
                tool_call_id,
                tool_name,
                args,
            } => {
                self.pending_permission = Some(PermissionPrompt {
                    tool_call_id: tool_call_id.clone(),
                    tool_name: tool_name.clone(),
                    args: args.clone(),
                });
            }
            AgentEvent::ToolCallFinished { tool_call_id, .. } => {
                self.last_tool_call_id = None;
                if self
                    .pending_permission
                    .as_ref()
                    .is_some_and(|prompt| &prompt.tool_call_id == tool_call_id)
                {
                    self.pending_permission = None;
                }
            }
            AgentEvent::UsageUpdated { total, .. } => self.usage_total = *total,
            AgentEvent::TurnFinished { text, .. } => {
                if !text.is_empty() && !self.saw_text_delta {
                    self.thread.apply(ThreadEvent::TextDelta(text.clone()));
                }
                self.pending_permission = None;
                self.last_tool_call_id = None;
            }
            AgentEvent::Error { message } => {
                self.last_error = Some(message.clone());
                self.pending_permission = None;
            }
            AgentEvent::ContextCompacted { .. } => {}
            AgentEvent::FollowUpStarted { .. } | AgentEvent::SteerStarted { .. } => {}
        }
    }
}

/// `AgentEvent` → 共享 `ThreadEvent`；subagent/TurnStarted 由 native 状态自行处理。
fn thread_event(event: &AgentEvent, context_size: u64) -> Option<ThreadEvent> {
    match event {
        AgentEvent::TurnStarted { .. } => None,
        AgentEvent::FollowUpStarted { text } | AgentEvent::SteerStarted { text } => {
            Some(ThreadEvent::TurnStarted {
                user_text: text.clone(),
            })
        }
        AgentEvent::SubagentStarted { .. }
        | AgentEvent::SubagentProgress { .. }
        | AgentEvent::SubagentFinished { .. } => None,
        AgentEvent::ContextCompacted { omitted_entries } => Some(ThreadEvent::CompactionUpdated {
            status: "completed".to_string(),
            summary: Some(format!("省略 {omitted_entries} 条更早消息")),
        }),
        AgentEvent::TextDelta { text } => Some(ThreadEvent::TextDelta(text.clone())),
        AgentEvent::ThinkingDelta { text } => Some(ThreadEvent::ThinkingDelta(text.clone())),
        AgentEvent::ToolCallStarted {
            tool_call_id,
            tool_name,
            args,
        } => Some(ThreadEvent::ToolCallStarted {
            tool_call_id: tool_call_id.clone(),
            title: tool_name.clone(),
            name: Some(tool_name.clone()),
            kind: "tool".to_string(),
            status: "in_progress".to_string(),
            args: Some(args.to_string()),
            output: None,
            locations: Vec::new(),
        }),
        AgentEvent::PermissionRequested {
            tool_call_id,
            tool_name,
            args,
        } => Some(ThreadEvent::PermissionRequested {
            request_id: tool_call_id.clone(),
            title: format!("允许运行 {tool_name}？"),
            tool_call_id: Some(tool_call_id.clone()),
            args: Some(args.to_string()),
        }),
        AgentEvent::ToolCallFinished {
            tool_call_id,
            ok,
            content,
            ..
        } => Some(ThreadEvent::ToolCallUpdated {
            tool_call_id: tool_call_id.clone(),
            title: None,
            status: Some(if *ok { "completed" } else { "failed" }.to_string()),
            output: Some(content.clone()),
        }),
        AgentEvent::UsageUpdated { usage, .. } => Some(ThreadEvent::UsageUpdated {
            used: usage.total(),
            size: context_size,
            cost: None,
        }),
        AgentEvent::TurnFinished { .. } => Some(ThreadEvent::TurnFinished { cancelled: false }),
        AgentEvent::Error { message } => Some(ThreadEvent::Failed(message.clone())),
    }
}
