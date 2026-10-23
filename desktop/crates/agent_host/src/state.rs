use cgc_agent_provider::TokenUsage;
use serde::{Deserialize, Serialize};

use crate::events::AgentEvent;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum UiRole {
    User,
    Assistant,
    Tool,
    System,
    Error,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct UiMessage {
    pub role: UiRole,
    pub text: String,
    /// 工具相关消息关联的 tool call id（用于 subagent 卡片内联）。
    #[serde(default)]
    pub tool_call_id: Option<String>,
}

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

/// 事件归约出的 UI 状态。UI 只读它渲染，不反向改 agent 线程。
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct HostState {
    pub messages: Vec<UiMessage>,
    pub streaming: String,
    pub turn_active: bool,
    pub pending_permission: Option<PermissionPrompt>,
    pub usage_total: TokenUsage,
    pub last_error: Option<String>,
    #[serde(default)]
    pub subagents: Vec<SubagentCard>,
    #[serde(default)]
    pub last_tool_call_id: Option<String>,
}

impl HostState {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn apply(&mut self, event: AgentEvent) {
        match event {
            AgentEvent::TurnStarted { .. } => {
                self.turn_active = true;
                self.streaming.clear();
                self.last_error = None;
            }
            AgentEvent::FollowUpStarted { text } => {
                if !self.streaming.is_empty() {
                    self.messages.push(UiMessage {
                        role: UiRole::Assistant,
                        text: std::mem::take(&mut self.streaming),
                        tool_call_id: None,
                    });
                }
                self.push_user(text);
            }
            AgentEvent::SteerStarted { text } => {
                if !self.streaming.is_empty() {
                    self.messages.push(UiMessage {
                        role: UiRole::Assistant,
                        text: std::mem::take(&mut self.streaming),
                        tool_call_id: None,
                    });
                }
                self.push_user(text);
            }
            AgentEvent::SubagentStarted { task } => {
                if self.subagents.len() >= 20 {
                    self.subagents.remove(0);
                }
                self.subagents.push(SubagentCard {
                    task,
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
                    card.text.push_str(&text);
                }
            }
            AgentEvent::SubagentFinished { ok } => {
                if let Some(card) = self
                    .subagents
                    .iter_mut()
                    .rev()
                    .find(|card| card.finished.is_none())
                {
                    card.finished = Some(ok);
                }
            }
            AgentEvent::ContextCompacted { omitted_entries } => {
                self.push_system(format!("上下文已压缩：省略 {omitted_entries} 条更早消息"));
            }
            AgentEvent::TextDelta { text } => self.streaming.push_str(&text),
            AgentEvent::ToolCallStarted {
                tool_call_id,
                tool_name,
                args,
            } => {
                self.last_tool_call_id = Some(tool_call_id.clone());
                self.messages.push(UiMessage {
                    role: UiRole::Tool,
                    text: format!("{tool_name}\n{args}"),
                    tool_call_id: Some(tool_call_id),
                });
            }
            AgentEvent::PermissionRequested {
                tool_call_id,
                tool_name,
                args,
            } => {
                self.pending_permission = Some(PermissionPrompt {
                    tool_call_id,
                    tool_name,
                    args,
                });
            }
            AgentEvent::ToolCallFinished {
                tool_call_id,
                tool_name,
                ok,
                content,
            } => {
                self.last_tool_call_id = None;
                if self
                    .pending_permission
                    .as_ref()
                    .is_some_and(|prompt| prompt.tool_call_id == tool_call_id)
                {
                    self.pending_permission = None;
                }
                self.messages.push(UiMessage {
                    role: UiRole::Tool,
                    text: format!(
                        "{} · {}\n{}",
                        tool_name,
                        if ok { "完成" } else { "失败" },
                        content
                    ),
                    tool_call_id: Some(tool_call_id),
                });
            }
            AgentEvent::UsageUpdated { total, .. } => self.usage_total = total,
            AgentEvent::TurnFinished { text, .. } => {
                if !self.streaming.is_empty() {
                    self.messages.push(UiMessage {
                        role: UiRole::Assistant,
                        text: std::mem::take(&mut self.streaming),
                        tool_call_id: None,
                    });
                } else if !text.is_empty() {
                    self.messages.push(UiMessage {
                        role: UiRole::Assistant,
                        text,
                        tool_call_id: None,
                    });
                }
                self.turn_active = false;
                self.pending_permission = None;
                self.last_tool_call_id = None;
            }
            AgentEvent::Error { message } => {
                self.last_error = Some(message);
                self.turn_active = false;
                self.pending_permission = None;
            }
        }
    }

    pub fn push_user(&mut self, text: impl Into<String>) {
        self.messages.push(UiMessage {
            role: UiRole::User,
            text: text.into(),
            tool_call_id: None,
        });
    }

    pub fn push_assistant(&mut self, text: impl Into<String>) {
        self.messages.push(UiMessage {
            role: UiRole::Assistant,
            text: text.into(),
            tool_call_id: None,
        });
    }

    pub fn push_tool(&mut self, text: impl Into<String>) {
        self.messages.push(UiMessage {
            role: UiRole::Tool,
            text: text.into(),
            tool_call_id: None,
        });
    }

    pub fn push_system(&mut self, text: impl Into<String>) {
        self.messages.push(UiMessage {
            role: UiRole::System,
            text: text.into(),
            tool_call_id: None,
        });
    }

    pub fn resolve_permission(&mut self, tool_call_id: &str) -> Option<PermissionPrompt> {
        match &self.pending_permission {
            Some(prompt) if prompt.tool_call_id == tool_call_id => self.pending_permission.take(),
            _ => None,
        }
    }
}
