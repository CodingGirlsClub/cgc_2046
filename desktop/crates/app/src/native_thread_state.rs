//! native 轨道的客户端状态（共享 `ConversationThread` 之外的 native 专属辅助态）。
//!
//! Stage 3.1 Phase A：native 运行时已经是进程内 ACP server，客户端只消费
//! `HostEvent`。会话行统一进 `ConversationThread`（见 `crate::agent_ingest`）；
//! 这里只保留 ACP v1 表达不了的 native 辅助态：审批卡渲染所需的 tool name/args、
//! 子 agent 卡（实时进度走 native 辅助通道，Phase B 再收口）。
//!
//! 原来的 `cgc_agent_host::HostState`（`AgentEvent → ThreadEvent` reducer）已删除：
//! 事件映射只在 ACP server 适配层做一次。

use cgc_agent_host::AgentEvent;
use cgc_agent_provider::TokenUsage;
use cgc_platform::acp::connection::HostEvent;

use crate::agent_ingest;

use cgc_agent_ui::conversation::{
    ConversationThread, NoticeLevel, ThreadCapabilities, ThreadEvent,
};

/// 子 agent 卡片状态（P2 实时进度；ACP v1 无对应 update，走 native 辅助通道）。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SubagentCard {
    pub task: String,
    pub text: String,
    /// `None` 表示仍在运行。
    pub finished: Option<bool>,
    /// 触发该子 agent 的 task tool call id。
    pub tool_call_id: Option<String>,
}

/// 待审批请求（native UI 渲染工具名/入参 + 回传 option_id 用）。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PendingPermission {
    pub request_id: String,
    pub tool_call_id: Option<String>,
    pub tool_name: String,
    pub args: serde_json::Value,
}

/// 事件归约出的 native 视图状态。UI 只读它渲染，不反向改 agent 线程。
#[derive(Clone, Debug, PartialEq)]
pub struct NativeThreadState {
    /// 共享会话模型（两轨同一 reducer 产出；对话行的唯一来源）。
    pub thread: ConversationThread,
    pub pending_permission: Option<PendingPermission>,
    /// 会话累计 token（恢复会话时从 native Thread 拷回；ACP 事件不携带累计值）。
    pub usage_total: TokenUsage,
    pub last_error: Option<String>,
    pub subagents: Vec<SubagentCard>,
    /// 最近一次工具调用的 id（子 agent 卡与 task 工具卡配对用）。
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
            thread: ConversationThread::new("native")
                .with_capabilities(ThreadCapabilities::native()),
            pending_permission: None,
            usage_total: TokenUsage::default(),
            last_error: None,
            subagents: Vec::new(),
            last_tool_call_id: None,
        }
    }

    /// 恢复历史时同步 usage 的上下文窗口（与 `thread.usage.used` 搭配）。
    pub fn set_context_size(&mut self, size: u64) {
        self.thread.usage.size = size;
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

    pub fn push_notice(&mut self, text: impl Into<String>) {
        self.thread.apply(ThreadEvent::Notice {
            level: NoticeLevel::Info,
            text: text.into(),
        });
    }

    /// 清理待审批提示；返回被清理的 prompt（供 UI 回传决定）。
    pub fn resolve_permission(&mut self, request_id: &str) -> Option<PendingPermission> {
        let prompt = self.pending_permission.clone()?;
        if prompt.request_id != request_id {
            return None;
        }
        self.pending_permission = None;
        Some(prompt)
    }

    /// 归约一条 ACP 客户端事件（native 轨道）：会话行进共享 ingestion，
    /// native 辅助态只处理审批卡/错误/子 agent 配对所需字段。
    pub fn apply_host_event(&mut self, event: &HostEvent) -> bool {
        let applied = agent_ingest::apply_thread_event(&mut self.thread, event);
        match event {
            HostEvent::ToolCall { call } => {
                self.last_tool_call_id = Some(call.tool_call_id.clone());
            }
            HostEvent::ToolCallUpdated {
                tool_call_id,
                status,
                ..
            } => {
                if matches!(status.as_deref(), Some("completed") | Some("failed")) {
                    self.last_tool_call_id = None;
                    if self.pending_permission.as_ref().is_some_and(|pending| {
                        pending.tool_call_id.as_deref() == Some(tool_call_id)
                    }) {
                        self.pending_permission = None;
                    }
                }
            }
            HostEvent::PermissionRequested {
                request_id,
                tool_call_id,
                tool_name,
                args,
                ..
            } => {
                self.pending_permission = Some(PendingPermission {
                    request_id: request_id.clone(),
                    tool_call_id: tool_call_id.clone(),
                    tool_name: tool_name.clone().unwrap_or_default(),
                    args: parse_args(args.as_deref()),
                });
            }
            HostEvent::TurnEnd { .. } => {
                self.pending_permission = None;
                self.last_tool_call_id = None;
            }
            HostEvent::Error { message } => {
                self.last_error = Some(message.clone());
                self.pending_permission = None;
                self.last_tool_call_id = None;
            }
            _ => {}
        }
        applied
    }

    /// native 辅助通道：子 agent 实时进度（不进 ACP update）。
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

    /// 子 agent 卡与 ACP 工具卡配对：事件来自两条通道，先到的子 agent 卡可能还
    /// 没有 tool_call_id；等 task 工具卡落行后补上（渲染时才能内联在工具卡下）。
    pub fn pair_unlinked_subagents(&mut self) {
        let unlinked = self
            .subagents
            .iter()
            .any(|card| card.tool_call_id.is_none() && card.finished.is_none());
        if !unlinked {
            return;
        }
        let used: Vec<String> = self
            .subagents
            .iter()
            .filter_map(|card| card.tool_call_id.clone())
            .collect();
        for card in self.subagents.iter_mut() {
            if card.tool_call_id.is_some() || card.finished.is_some() {
                continue;
            }
            let candidate = self.thread.entries.iter().find_map(|entry| match entry {
                cgc_agent_ui::conversation::Entry::ToolCall {
                    tool_call_id, name, ..
                } if name.as_deref() == Some("task") && !used.contains(tool_call_id) => {
                    Some(tool_call_id.clone())
                }
                _ => None,
            });
            if let Some(tool_call_id) = candidate {
                card.tool_call_id = Some(tool_call_id);
            }
        }
    }
}

fn parse_args(raw: Option<&str>) -> serde_json::Value {
    let Some(raw) = raw else {
        return serde_json::Value::Null;
    };
    serde_json::from_str(raw).unwrap_or_else(|_| serde_json::Value::String(raw.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agent_ingest::{apply_permission_resolved, apply_user_turn};
    use cgc_agent_ui::conversation::{Entry, ThreadStatus};
    use cgc_platform::acp::connection::{PermissionOptionView, ToolCallView};

    fn tool_call(id: &str, name: &str) -> HostEvent {
        HostEvent::ToolCall {
            call: ToolCallView {
                tool_call_id: id.to_string(),
                title: name.to_string(),
                name: Some(name.to_string()),
                kind: "tool".to_string(),
                status: "in_progress".to_string(),
                args: Some("{}".to_string()),
                output: None,
                locations: Vec::new(),
            },
        }
    }

    fn turn_end() -> HostEvent {
        HostEvent::TurnEnd {
            cancelled: false,
            stop_reason: "EndTurn".to_string(),
        }
    }

    #[test]
    fn text_deltas_merge_and_turn_closes_through_host_events() {
        let mut state = NativeThreadState::new();
        apply_user_turn(&mut state.thread, "问");
        for event in [
            HostEvent::Delta("he".to_string()),
            HostEvent::Delta("llo".to_string()),
            turn_end(),
        ] {
            assert!(state.apply_host_event(&event));
        }
        assert_eq!(
            state.thread.entries,
            vec![
                Entry::User {
                    text: "问".to_string()
                },
                Entry::Assistant {
                    text: "hello".to_string()
                }
            ]
        );
        assert_eq!(state.thread.status, ThreadStatus::Idle);
    }

    #[test]
    fn tool_lifecycle_maps_args_status_and_output() {
        let mut state = NativeThreadState::new();
        assert!(state.apply_host_event(&tool_call("c1", "read_file")));
        assert_eq!(state.last_tool_call_id.as_deref(), Some("c1"));
        assert!(state.apply_host_event(&HostEvent::ToolCallUpdated {
            tool_call_id: "c1".to_string(),
            title: None,
            status: Some("completed".to_string()),
            output: Some("ok".to_string()),
        }));
        assert!(state.last_tool_call_id.is_none());
        let Entry::ToolCall {
            tool_call_id,
            name,
            status,
            output,
            ..
        } = &state.thread.entries[0]
        else {
            panic!("tool entry");
        };
        assert_eq!(tool_call_id, "c1");
        assert_eq!(name.as_deref(), Some("read_file"));
        assert_eq!(status, "completed");
        assert_eq!(output.as_deref(), Some("ok"));
    }

    #[test]
    fn permission_request_sets_pending_and_resolves() {
        let mut state = NativeThreadState::new();
        assert!(state.apply_host_event(&HostEvent::PermissionRequested {
            request_id: "perm-1".to_string(),
            title: "允许运行 run_command？".to_string(),
            tool_call_id: Some("c1".to_string()),
            tool_name: Some("run_command".to_string()),
            args: Some("{\"command\":\"ls\"}".to_string()),
            options: vec![PermissionOptionView {
                option_id: "allow_once".to_string(),
                name: "允许一次".to_string(),
                kind: "allow_once".to_string(),
            }],
        }));
        assert_eq!(state.thread.status, ThreadStatus::AwaitingApproval);
        let pending = state.pending_permission.clone().expect("pending");
        assert_eq!(pending.tool_name, "run_command");
        assert_eq!(pending.args["command"], "ls");
        apply_permission_resolved(&mut state.thread, "perm-1", true);
        assert!(state.resolve_permission("perm-1").is_some());
        assert!(state.pending_permission.is_none());
    }

    #[test]
    fn error_sets_last_error_and_retry_clears_it() {
        let mut state = NativeThreadState::new();
        assert!(!state.begin_retry());
        assert!(state.apply_host_event(&HostEvent::Error {
            message: "boom".to_string()
        }));
        assert_eq!(state.last_error.as_deref(), Some("boom"));
        assert_eq!(state.thread.status, ThreadStatus::Failed);
        assert!(state.begin_retry());
        assert!(state.last_error.is_none());
        assert!(!state.begin_retry());
    }

    #[test]
    fn subagents_track_separately_and_pair_with_task_tool_call() {
        let mut state = NativeThreadState::new();
        // 子 agent 事件先到（辅助通道），此时还没有 task 工具卡。
        state.apply_subagent_event(&AgentEvent::SubagentStarted {
            task: "调研".to_string(),
        });
        state.apply_subagent_event(&AgentEvent::SubagentProgress {
            text: "进行中".to_string(),
        });
        state.pair_unlinked_subagents();
        assert!(state.subagents[0].tool_call_id.is_none());

        // task 工具卡随后经 ACP 落行，补充配对。
        assert!(state.apply_host_event(&tool_call("c9", "task")));
        state.pair_unlinked_subagents();
        assert_eq!(state.subagents[0].tool_call_id.as_deref(), Some("c9"));
        assert_eq!(state.subagents[0].text, "进行中");
        assert_eq!(state.thread.entries.len(), 1, "子 agent 不进对话行");

        state.apply_subagent_event(&AgentEvent::SubagentFinished { ok: true });
        assert_eq!(state.subagents[0].finished, Some(true));
    }

    #[test]
    fn new_state_uses_native_capabilities() {
        assert!(
            NativeThreadState::new()
                .thread
                .capabilities
                .checkpoint_restore
        );
        assert!(!ThreadCapabilities::acp().checkpoint_restore);
    }
}
