use cgc_agent_provider::TokenUsage;
use serde::{Deserialize, Serialize};

use crate::events::AgentEvent;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum UiRole {
    User,
    Assistant,
    /// 思考（reasoning）折叠块，只展示，不进入 provider messages。
    Thinking,
    Tool,
    System,
    Error,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum ToolCallStatus {
    Running,
    Ok,
    Failed,
}

/// 工具调用卡片的结构化数据：参数（raw input）与输出（raw output）。
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct UiToolCall {
    pub name: String,
    pub args: serde_json::Value,
    pub status: ToolCallStatus,
    pub content: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct UiMessage {
    pub role: UiRole,
    pub text: String,
    /// 工具相关消息关联的 tool call id（用于 subagent 卡片内联）。
    #[serde(default)]
    pub tool_call_id: Option<String>,
    /// Tool 角色消息的结构化调用详情；旧数据为 None，渲染退回纯文本。
    #[serde(default)]
    pub tool: Option<UiToolCall>,
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
    /// 正在流式输出的思考内容；在 assistant/tool/结束/错误时固化进 messages。
    #[serde(default)]
    pub thinking_streaming: String,
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
                self.thinking_streaming.clear();
                self.last_error = None;
            }
            AgentEvent::FollowUpStarted { text } => {
                self.flush_thinking();
                if !self.streaming.is_empty() {
                    self.messages.push(UiMessage {
                        role: UiRole::Assistant,
                        text: std::mem::take(&mut self.streaming),
                        tool_call_id: None,
                        tool: None,
                    });
                }
                self.push_user(text);
            }
            AgentEvent::SteerStarted { text } => {
                self.flush_thinking();
                if !self.streaming.is_empty() {
                    self.messages.push(UiMessage {
                        role: UiRole::Assistant,
                        text: std::mem::take(&mut self.streaming),
                        tool_call_id: None,
                        tool: None,
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
            AgentEvent::ThinkingDelta { text } => self.thinking_streaming.push_str(&text),
            AgentEvent::ToolCallStarted {
                tool_call_id,
                tool_name,
                args,
            } => {
                self.flush_thinking();
                self.last_tool_call_id = Some(tool_call_id.clone());
                self.push_tool_call_started(tool_call_id, tool_name, args);
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
                self.finish_tool_call(tool_call_id, tool_name, ok, content);
            }
            AgentEvent::UsageUpdated { total, .. } => self.usage_total = total,
            AgentEvent::TurnFinished { text, .. } => {
                self.flush_thinking();
                if !self.streaming.is_empty() {
                    self.messages.push(UiMessage {
                        role: UiRole::Assistant,
                        text: std::mem::take(&mut self.streaming),
                        tool_call_id: None,
                        tool: None,
                    });
                } else if !text.is_empty() {
                    self.messages.push(UiMessage {
                        role: UiRole::Assistant,
                        text,
                        tool_call_id: None,
                        tool: None,
                    });
                }
                self.turn_active = false;
                self.pending_permission = None;
                self.last_tool_call_id = None;
            }
            AgentEvent::Error { message } => {
                self.flush_thinking();
                // 保留出错前已经吐出的部分回复，别让用户丢失已看到的内容。
                if !self.streaming.is_empty() {
                    self.messages.push(UiMessage {
                        role: UiRole::Assistant,
                        text: std::mem::take(&mut self.streaming),
                        tool_call_id: None,
                        tool: None,
                    });
                }
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
            tool: None,
        });
    }

    pub fn push_thinking(&mut self, text: impl Into<String>) {
        self.messages.push(UiMessage {
            role: UiRole::Thinking,
            text: text.into(),
            tool_call_id: None,
            tool: None,
        });
    }

    /// 把流式思考固化成一条 Thinking 消息（幂等：空缓冲时不做事）。
    fn flush_thinking(&mut self) {
        if self.thinking_streaming.is_empty() {
            return;
        }
        let text = std::mem::take(&mut self.thinking_streaming);
        self.push_thinking(text);
    }

    pub fn push_assistant(&mut self, text: impl Into<String>) {
        self.messages.push(UiMessage {
            role: UiRole::Assistant,
            text: text.into(),
            tool_call_id: None,
            tool: None,
        });
    }

    pub fn push_tool(&mut self, text: impl Into<String>) {
        self.messages.push(UiMessage {
            role: UiRole::Tool,
            text: text.into(),
            tool_call_id: None,
            tool: None,
        });
    }

    pub fn push_system(&mut self, text: impl Into<String>) {
        self.messages.push(UiMessage {
            role: UiRole::System,
            text: text.into(),
            tool_call_id: None,
            tool: None,
        });
    }

    /// 工具调用结束后的卡片数据（restore / 直接构造用）。
    pub fn push_tool_card(
        &mut self,
        tool_call_id: impl Into<String>,
        name: impl Into<String>,
        args: serde_json::Value,
        status: ToolCallStatus,
        content: Option<String>,
    ) {
        let name = name.into();
        self.messages.push(UiMessage {
            role: UiRole::Tool,
            text: name.clone(),
            tool_call_id: Some(tool_call_id.into()),
            tool: Some(UiToolCall {
                name,
                args,
                status,
                content,
            }),
        });
    }

    fn push_tool_call_started(
        &mut self,
        tool_call_id: String,
        tool_name: String,
        args: serde_json::Value,
    ) {
        self.messages.push(UiMessage {
            role: UiRole::Tool,
            text: tool_name.clone(),
            tool_call_id: Some(tool_call_id),
            tool: Some(UiToolCall {
                name: tool_name,
                args,
                status: ToolCallStatus::Running,
                content: None,
            }),
        });
    }

    fn finish_tool_call(
        &mut self,
        tool_call_id: String,
        tool_name: String,
        ok: bool,
        content: String,
    ) {
        let status = if ok {
            ToolCallStatus::Ok
        } else {
            ToolCallStatus::Failed
        };
        if let Some(message) = self
            .messages
            .iter_mut()
            .rev()
            .find(|message| message.tool_call_id.as_deref() == Some(tool_call_id.as_str()))
        {
            if let Some(tool) = message.tool.as_mut() {
                tool.status = status;
                tool.content = Some(content);
                message.text = tool.name.clone();
                return;
            }
        }
        // 没有对应的 started 事件（例如只回放 finish）时，补一张已结束的卡片。
        self.push_tool_card(
            tool_call_id,
            tool_name,
            serde_json::Value::Null,
            status,
            Some(content),
        );
    }

    /// 失败后可以重试：有错误且当前没有 turn 在跑。
    pub fn retry_available(&self) -> bool {
        !self.turn_active && self.last_error.is_some()
    }

    /// 进入重试：清掉错误标记；没有可重试的错误时返回 false。
    ///
    /// 重试不新增用户消息，因此 UI 不会出现重复气泡。
    pub fn begin_retry(&mut self) -> bool {
        if !self.retry_available() {
            return false;
        }
        self.last_error = None;
        true
    }

    pub fn resolve_permission(&mut self, tool_call_id: &str) -> Option<PermissionPrompt> {
        match &self.pending_permission {
            Some(prompt) if prompt.tool_call_id == tool_call_id => self.pending_permission.take(),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{AgentEvent, HostState};

    fn failed_turn_state() -> HostState {
        let mut state = HostState::new();
        state.apply(AgentEvent::TurnStarted {
            thread_id: "thread-1".into(),
        });
        state.push_user("hi");
        state.apply(AgentEvent::Error {
            message: "provider 500".into(),
        });
        state
    }

    #[test]
    fn thinking_flushes_before_assistant_and_tool_cards() {
        let mut state = HostState::new();
        state.apply(AgentEvent::TurnStarted {
            thread_id: "t".into(),
        });
        state.apply(AgentEvent::ThinkingDelta {
            text: "先想".into(),
        });
        state.apply(AgentEvent::ToolCallStarted {
            tool_call_id: "c1".into(),
            tool_name: "read_file".into(),
            args: serde_json::json!({"path": "a.txt"}),
        });
        assert_eq!(state.messages.len(), 2, "thinking + tool card");
        assert_eq!(state.messages[0].role, super::UiRole::Thinking);
        assert_eq!(state.messages[0].text, "先想");
        assert_eq!(state.messages[1].role, super::UiRole::Tool);
        assert!(state.thinking_streaming.is_empty(), "固化后缓冲清空");

        state.apply(AgentEvent::ThinkingDelta {
            text: "再想".into(),
        });
        state.apply(AgentEvent::TurnFinished {
            text: "答复".into(),
            stop_reason: cgc_agent_provider::StopReason::EndTurn,
        });
        let roles: Vec<_> = state.messages.iter().map(|message| message.role).collect();
        assert_eq!(
            roles,
            vec![
                super::UiRole::Thinking,
                super::UiRole::Tool,
                super::UiRole::Thinking,
                super::UiRole::Assistant
            ],
            "thinking 固定在 assistant/tool 之前"
        );
        assert_eq!(state.messages[3].text, "答复");
        assert!(state.thinking_streaming.is_empty());
    }

    #[test]
    fn error_preserves_partial_streaming_reply() {
        let mut state = HostState::new();
        state.apply(AgentEvent::TurnStarted {
            thread_id: "thread-1".into(),
        });
        state.apply(AgentEvent::TextDelta {
            text: "已经生成一半".into(),
        });
        state.apply(AgentEvent::Error {
            message: "stream broke".into(),
        });
        assert!(state.streaming.is_empty(), "流式缓冲应清空");
        assert_eq!(state.messages.len(), 1, "部分回复应固化成 assistant 消息");
        assert_eq!(state.messages[0].role, super::UiRole::Assistant);
        assert_eq!(state.messages[0].text, "已经生成一半");
    }

    #[test]
    fn retry_clears_error_without_touching_messages() {
        let mut state = failed_turn_state();
        let messages_before = state.messages.clone();
        assert!(state.retry_available(), "失败后应可重试");
        assert!(state.begin_retry(), "第一次重试应成功");
        assert!(state.last_error.is_none(), "重试后错误应清空");
        assert_eq!(state.messages, messages_before, "重试不应新增/删除用户消息");
        assert!(!state.begin_retry(), "没有错误时不可重复重试");
    }

    #[test]
    fn tool_call_started_and_finished_merge_into_one_card() {
        let mut state = HostState::new();
        state.apply(AgentEvent::ToolCallStarted {
            tool_call_id: "call_1".into(),
            tool_name: "run_command".into(),
            args: serde_json::json!({"command": "echo hi"}),
        });
        let running = state.messages.last().expect("started card");
        assert_eq!(running.role, super::UiRole::Tool);
        let tool = running.tool.as_ref().expect("structured tool data");
        assert_eq!(tool.status, super::ToolCallStatus::Running);
        assert_eq!(tool.content, None);
        assert_eq!(tool.args["command"], "echo hi");

        state.apply(AgentEvent::ToolCallFinished {
            tool_call_id: "call_1".into(),
            tool_name: "run_command".into(),
            ok: true,
            content: "hi".into(),
        });
        assert_eq!(state.messages.len(), 1, "finished 应合并进同一张卡片");
        let tool = state.messages[0].tool.as_ref().expect("tool data");
        assert_eq!(tool.status, super::ToolCallStatus::Ok);
        assert_eq!(tool.content.as_deref(), Some("hi"));
        assert_eq!(tool.args["command"], "echo hi");
        assert_eq!(state.messages[0].tool_call_id.as_deref(), Some("call_1"));
    }

    #[test]
    fn tool_call_finished_without_start_still_renders_card() {
        let mut state = HostState::new();
        state.apply(AgentEvent::ToolCallFinished {
            tool_call_id: "orphan".into(),
            tool_name: "read_file".into(),
            ok: false,
            content: "denied".into(),
        });
        assert_eq!(state.messages.len(), 1);
        let tool = state.messages[0].tool.as_ref().expect("tool data");
        assert_eq!(tool.status, super::ToolCallStatus::Failed);
        assert_eq!(tool.content.as_deref(), Some("denied"));
    }

    #[test]
    fn retry_not_available_while_turn_active() {
        let mut state = failed_turn_state();
        state.apply(AgentEvent::TurnStarted {
            thread_id: "thread-1".into(),
        });
        assert!(!state.retry_available(), "turn 运行中不可重试");
        assert!(!state.begin_retry());
        state.apply(AgentEvent::Error {
            message: "第二次失败".into(),
        });
        assert!(state.retry_available(), "turn 结束后可重试");
    }
}
