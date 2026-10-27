//! Native-only presentation state; protocol lifecycle belongs to ConversationSession.
use crate::{
    agent_ingest, conversation_session::ConversationSession, native_panel_host::SubagentCard,
};
use cgc_agent_host::AgentEvent;
use cgc_agent_provider::TokenUsage;
use cgc_platform::acp::connection::HostEvent;

pub struct NativeThreadState {
    pub session: ConversationSession,
    pub usage_total: TokenUsage,
    pub subagents: Vec<SubagentCard>,
    pub last_tool_call_id: Option<String>,
}

impl Default for NativeThreadState {
    fn default() -> Self {
        Self::new()
    }
}

impl NativeThreadState {
    pub fn new() -> Self {
        Self {
            session: ConversationSession::native(),
            usage_total: TokenUsage::default(),
            subagents: Vec::new(),
            last_tool_call_id: None,
        }
    }
    pub fn retry_available(&self) -> bool {
        self.session.last_error.is_some()
    }
    pub fn push_notice(&mut self, text: impl Into<String>) {
        agent_ingest::apply_notice(&mut self.session.thread, text);
    }
    pub fn ingest(&mut self, generation: u64, event: &HostEvent) -> bool {
        if !self.session.ingest(generation, event) {
            return false;
        }
        match event {
            HostEvent::ToolCall { call } => {
                self.last_tool_call_id = Some(call.tool_call_id.clone())
            }
            HostEvent::ToolCallUpdated {
                tool_call_id,
                status,
                ..
            } if self.last_tool_call_id.as_ref() == Some(tool_call_id)
                && matches!(status.as_deref(), Some("completed") | Some("failed")) =>
            {
                self.last_tool_call_id = None
            }
            HostEvent::TurnEnd { .. } | HostEvent::Error { .. } | HostEvent::Exited => {
                self.last_tool_call_id = None
            }
            _ => {}
        }
        true
    }
    pub fn apply_subagent_event(&mut self, event: &AgentEvent) {
        match event {
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
            _ => {}
        }
    }
    pub fn pair_unlinked_subagents(&mut self) {
        for index in 0..self.subagents.len() {
            if self.subagents[index].tool_call_id.is_some()
                || self.subagents[index].finished.is_some()
            {
                continue;
            }
            let candidate = self
                .session
                .thread
                .entries
                .iter()
                .find_map(|entry| match entry {
                    cgc_agent_ui::conversation::Entry::ToolCall {
                        tool_call_id, name, ..
                    } if name.as_deref() == Some("task")
                        && !self
                            .subagents
                            .iter()
                            .any(|card| card.tool_call_id.as_ref() == Some(tool_call_id)) =>
                    {
                        Some(tool_call_id.clone())
                    }
                    _ => None,
                });
            self.subagents[index].tool_call_id = candidate;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use cgc_platform::acp::connection::ToolCallView;
    #[test]
    fn progress_arriving_before_tool_is_paired_without_inventing_transcript_rows() {
        let mut state = NativeThreadState::new();
        state.apply_subagent_event(&AgentEvent::SubagentStarted {
            task: "inspect".into(),
        });
        state.apply_subagent_event(&AgentEvent::SubagentProgress {
            text: "finding".into(),
        });
        state.pair_unlinked_subagents();
        assert!(state.subagents[0].tool_call_id.is_none());
        state.ingest(
            0,
            &HostEvent::ToolCall {
                call: ToolCallView {
                    tool_call_id: "task-1".into(),
                    name: Some("task".into()),
                    title: "inspect".into(),
                    ..Default::default()
                },
            },
        );
        state.pair_unlinked_subagents();
        state.apply_subagent_event(&AgentEvent::SubagentFinished { ok: true });
        assert_eq!(state.subagents[0].tool_call_id.as_deref(), Some("task-1"));
        assert_eq!(state.subagents[0].text, "finding");
        assert_eq!(state.subagents[0].finished, Some(true));
        assert!(
            matches!(&state.session.thread.entries[..], [cgc_agent_ui::conversation::Entry::ToolCall { tool_call_id, .. }] if tool_call_id == "task-1")
        );
    }
}
