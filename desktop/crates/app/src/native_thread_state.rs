//! native 轨道的客户端状态（共享 `ConversationThread` 之外的 native 专属辅助态）。
//!
//! Stage 3.1 Phase A：native 运行时已经是进程内 ACP server，客户端只消费
//! `HostEvent`。会话行统一进 `ConversationThread`（见 `crate::agent_ingest`）；
//! 这里只保留 ACP v1 表达不了的 native 辅助态：审批卡渲染所需的 tool name/args、
//! 子 agent 卡（实时进度走 native 辅助通道，Phase B 再收口）。
//!
//! 审批卡的**事实源是共享 `ConversationThread`**（`thread.pending_permission`）：
//! `sync_pending_permission` 用它兜底/清理辅助态，保证「运行时在等审批」时 UI 一定
//! 能渲染出可点的审批卡（真机 bug 2 回归）。工具执行的 `tool_call_update` 不是审批
//! 生命周期事件，不得清除 pending。
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
            HostEvent::ToolCallUpdated { status, .. } => {
                // 工具执行结果不是审批生命周期事件。历史上这里按 tool_call_id 清
                // pending（真机 bug 2：跨回合/乱序的 tool_call_update 会把下一轮
                // 审批卡清掉，运行时却仍在等响应）。pending 只由对应 request 的
                // resolve / TurnEnd / Error / cancel 清除。
                if matches!(status.as_deref(), Some("completed") | Some("failed")) {
                    self.last_tool_call_id = None;
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

    /// 以共享 `ConversationThread` 为审批卡事实源做同步：
    /// - shared 里有未解决审批、辅助态缺失/request_id 不一致 → 重建可渲染的卡
    ///   （两轨同一数据源，避免 native 辅助态被清掉后运行时还在等响应）；
    /// - shared 里没有未解决审批 → 清掉辅助态残留。
    pub fn sync_pending_permission(&mut self) {
        match &self.thread.pending_permission {
            Some(shared) => {
                if self
                    .pending_permission
                    .as_ref()
                    .is_some_and(|pending| pending.request_id == shared.request_id)
                {
                    return;
                }
                if let Some(aux) = self.pending_permission.take() {
                    // 客户端同一时刻只能有一个在途审批：辅助态里有**另一个**
                    // request 说明共享模型里的那条是上一轮遗留（例如 PermissionResolved
                    // 丢在批处理边界）。把遗留行标记为已失效后以新请求为准，
                    // 否则回传会打到旧 request_id，运行时继续等 → turn timeout。
                    let stale_request = shared.request_id.clone();
                    agent_ingest::apply_permission_resolved(&mut self.thread, stale_request, false);
                    self.pending_permission = Some(aux);
                    return;
                }
                let aux = self.pending_permission.take();
                let tool_name = shared
                    .tool
                    .clone()
                    .filter(|name| !name.is_empty())
                    .or_else(|| aux.as_ref().map(|pending| pending.tool_name.clone()))
                    .filter(|name| !name.is_empty())
                    .unwrap_or_else(|| tool_name_from_title(&shared.title));
                let args = shared
                    .args
                    .as_deref()
                    .map(|raw| parse_args(Some(raw)))
                    .filter(|args| !args.is_null())
                    .unwrap_or_else(|| {
                        aux.as_ref()
                            .map(|pending| pending.args.clone())
                            .unwrap_or(serde_json::Value::Null)
                    });
                self.pending_permission = Some(PendingPermission {
                    request_id: shared.request_id.clone(),
                    tool_call_id: shared.tool_call_id.clone(),
                    tool_name,
                    args,
                });
            }
            None => self.pending_permission = None,
        }
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

/// 从共享模型的标题里提取工具名（辅助态缺失时的兜底；标题兜底为空串）。
fn tool_name_from_title(title: &str) -> String {
    const PREFIX: &str = "允许运行 ";
    let trimmed = title.trim();
    let rest = trimmed
        .strip_prefix(PREFIX)
        .unwrap_or(trimmed)
        .trim_end_matches(['？', '?'])
        .trim();
    if rest.is_empty() || rest == title.trim() {
        String::new()
    } else {
        rest.to_string()
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

    /// 回归：ToolCallUpdated 是工具执行结果，不是审批生命周期事件；即使跨越/乱序
    /// 到达（例如上一轮同名工具、或 provider 复用 tool_call_id），也不能清掉
    /// 当前 pending 审批，否则 UI 审批卡消失、运行时还在等响应（真机 bug 2）。
    #[test]
    fn out_of_order_tool_call_update_must_not_clear_pending_permission() {
        let mut state = NativeThreadState::new();
        assert!(state.apply_host_event(&HostEvent::PermissionRequested {
            request_id: "perm-2".to_string(),
            title: "允许运行 run_command？".to_string(),
            tool_call_id: Some("call-1".to_string()),
            tool_name: Some("run_command".to_string()),
            args: Some("{\"command\":\"echo hi\"}".to_string()),
            options: Vec::new(),
        }));
        let pending = state.pending_permission.clone().expect("pending");
        // 乱序/跨回合的 tool_call_update 先到：不得清 pending。
        assert!(state.apply_host_event(&HostEvent::ToolCallUpdated {
            tool_call_id: pending.tool_call_id.clone().unwrap_or_default(),
            title: None,
            status: Some("completed".to_string()),
            output: Some("stale".to_string()),
        }));
        assert!(
            state.pending_permission.is_some(),
            "tool_call_update 不得清除待审批状态"
        );
        // 只有对应 request 的 resolve 才能清。
        let resolved = state
            .resolve_permission(&pending.request_id)
            .expect("resolve");
        assert_eq!(resolved.request_id, "perm-2");
        assert!(state.pending_permission.is_none());
    }

    /// 回归：连续两轮各一次审批（同一工具），第一轮 resolve 后 pending 清空、
    /// 行标记已允许；第二轮请求不得被上一轮状态吞掉，resolve 后正常结束。
    #[test]
    fn consecutive_turns_each_keep_their_own_pending_permission() {
        let mut state = NativeThreadState::new();
        for (turn, request_id) in [(1, "perm-1"), (2, "perm-2")] {
            apply_user_turn(&mut state.thread, format!("第 {turn} 轮"));
            assert!(state.apply_host_event(&HostEvent::PermissionRequested {
                request_id: request_id.to_string(),
                title: "允许运行 run_command？".to_string(),
                tool_call_id: Some(format!("call-{turn}")),
                tool_name: Some("run_command".to_string()),
                args: Some("{\"command\":\"echo hi\"}".to_string()),
                options: Vec::new(),
            }));
            let pending = state
                .pending_permission
                .clone()
                .unwrap_or_else(|| panic!("第 {turn} 轮审批必须可渲染"));
            assert_eq!(pending.request_id, request_id);
            // 用户点击前先到一条本轮工具收尾（乱序防护）：仍不得清 pending。
            assert!(state.apply_host_event(&HostEvent::ToolCallUpdated {
                tool_call_id: format!("call-{turn}"),
                title: None,
                status: Some("completed".to_string()),
                output: Some("ok".to_string()),
            }));
            assert!(
                state.pending_permission.is_some(),
                "第 {turn} 轮 tool_call_update 不得清 pending"
            );
            // UI 回传决定。
            state.resolve_permission(request_id).expect("resolve");
            apply_permission_resolved(&mut state.thread, request_id, true);
            assert!(state.pending_permission.is_none());
            assert!(state.apply_host_event(&HostEvent::TurnEnd {
                cancelled: false,
                stop_reason: "EndTurn".to_string(),
            }));
        }
        let permission_rows = state
            .thread
            .entries
            .iter()
            .filter(|entry| matches!(entry, Entry::Permission { .. }))
            .count();
        assert_eq!(permission_rows, 2, "两轮审批都应留痕");
        assert!(state
            .thread
            .entries
            .iter()
            .all(|entry| !matches!(entry, Entry::Permission { resolved: None, .. })));
    }

    /// 回归：共享模型里有未解决审批、但 native 辅助态缺失时，必须能从
    /// ConversationThread 兜底重建可渲染审批卡（两轨同一数据源）。
    #[test]
    fn pending_permission_recovers_from_shared_thread_model() {
        let mut state = NativeThreadState::new();
        // 只让共享模型看到审批（模拟辅助态在批处理中被清掉的极端情况）。
        assert!(agent_ingest::apply_thread_event(
            &mut state.thread,
            &HostEvent::PermissionRequested {
                request_id: "perm-9".to_string(),
                title: "允许运行 run_command？".to_string(),
                tool_call_id: Some("call-9".to_string()),
                tool_name: Some("run_command".to_string()),
                args: Some("{\"command\":\"ls\"}".to_string()),
                options: Vec::new(),
            }
        ));
        assert!(state.pending_permission.is_none());
        state.sync_pending_permission();
        let pending = state
            .pending_permission
            .clone()
            .expect("审批必须能从共享模型恢复");
        assert_eq!(pending.request_id, "perm-9");
        assert!(pending.tool_name.is_empty() || pending.tool_name == "run_command");
        // 线程里 resolve 后辅助态必须同步清空。
        apply_permission_resolved(&mut state.thread, "perm-9", false);
        state.sync_pending_permission();
        assert!(state.pending_permission.is_none());
    }

    /// 回归（真机 bug 2 的残留机制）：共享模型里残留上一轮未解决的审批、辅助态
    /// 已有新的 request 时，必须以新 request 为准（否则回传打到旧 id，运行时
    /// 继续等审批 → 60s turn timeout）。
    #[test]
    fn stale_shared_pending_does_not_steal_new_permission_request() {
        let mut state = NativeThreadState::new();
        // 上一轮请求只进了共享模型（模拟 resolve 事件丢失）。
        assert!(agent_ingest::apply_thread_event(
            &mut state.thread,
            &HostEvent::PermissionRequested {
                request_id: "perm-1".to_string(),
                title: "允许运行 run_command？".to_string(),
                tool_call_id: Some("call-1".to_string()),
                tool_name: Some("run_command".to_string()),
                args: Some("{\"command\":\"echo hi\"}".to_string()),
                options: Vec::new(),
            }
        ));
        // 新请求走完整 apply_host_event（辅助态 = perm-2）。
        assert!(state.apply_host_event(&HostEvent::PermissionRequested {
            request_id: "perm-2".to_string(),
            title: "允许运行 run_command？".to_string(),
            tool_call_id: Some("call-1".to_string()),
            tool_name: Some("run_command".to_string()),
            args: Some("{\"command\":\"echo hi\"}".to_string()),
            options: Vec::new(),
        }));
        state.sync_pending_permission();
        assert_eq!(
            state
                .pending_permission
                .as_ref()
                .map(|pending| pending.request_id.as_str()),
            Some("perm-2"),
            "必须回传新 request，不能沿用遗留的 perm-1"
        );
        // 共享模型里遗留的 pending 被清掉，且旧行标记为未允许（失效）。
        assert!(state.thread.pending_permission.is_none());
        let stale_row = state
            .thread
            .entries
            .iter()
            .find(|entry| {
                matches!(
                    entry,
                    Entry::Permission { request_id, .. } if request_id == "perm-1"
                )
            })
            .expect("stale row");
        let Entry::Permission { resolved, .. } = stale_row else {
            unreachable!()
        };
        assert_eq!(*resolved, Some(false));
    }
}
