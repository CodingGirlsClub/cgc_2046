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
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
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
                    });
                }
                self.push_user(text);
            }
            AgentEvent::SteerStarted { text } => {
                if !self.streaming.is_empty() {
                    self.messages.push(UiMessage {
                        role: UiRole::Assistant,
                        text: std::mem::take(&mut self.streaming),
                    });
                }
                self.push_user(text);
            }
            AgentEvent::TextDelta { text } => self.streaming.push_str(&text),
            AgentEvent::ToolCallStarted { .. } => {}
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
                });
            }
            AgentEvent::UsageUpdated { total, .. } => self.usage_total = total,
            AgentEvent::TurnFinished { text, .. } => {
                if !self.streaming.is_empty() {
                    self.messages.push(UiMessage {
                        role: UiRole::Assistant,
                        text: std::mem::take(&mut self.streaming),
                    });
                } else if !text.is_empty() {
                    self.messages.push(UiMessage {
                        role: UiRole::Assistant,
                        text,
                    });
                }
                self.turn_active = false;
                self.pending_permission = None;
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
        });
    }

    pub fn push_assistant(&mut self, text: impl Into<String>) {
        self.messages.push(UiMessage {
            role: UiRole::Assistant,
            text: text.into(),
        });
    }

    pub fn push_tool(&mut self, text: impl Into<String>) {
        self.messages.push(UiMessage {
            role: UiRole::Tool,
            text: text.into(),
        });
    }

    pub fn push_system(&mut self, text: impl Into<String>) {
        self.messages.push(UiMessage {
            role: UiRole::System,
            text: text.into(),
        });
    }

    pub fn resolve_permission(&mut self, tool_call_id: &str) -> Option<PermissionPrompt> {
        match &self.pending_permission {
            Some(prompt) if prompt.tool_call_id == tool_call_id => self.pending_permission.take(),
            _ => None,
        }
    }
}
