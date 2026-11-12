//! 学习状态变更检测：native 与 ACP 两条轨共用。
//!
//! `submit_learning_attempt` 成功后需要重拉学习投影，否则卡片掌握态停留在
//! 提交前。工具名/标题匹配与 tool_call_id 关联只应有一份实现，避免两轨漂移。

use cgc_platform::acp::connection::HostEvent;
use std::collections::HashSet;

#[derive(Default)]
pub(crate) struct LearningMutationTracker {
    submit_tool_ids: HashSet<String>,
    changed: bool,
}

impl LearningMutationTracker {
    /// 观察一条 host 事件；只认 `submit_learning_attempt` 的 completed。
    pub(crate) fn observe(&mut self, event: &HostEvent) {
        match event {
            HostEvent::ToolCall { call } => {
                let is_submit = call
                    .name
                    .as_deref()
                    .is_some_and(|name| name.contains("submit_learning_attempt"))
                    || call.title.contains("submit_learning_attempt");
                if is_submit {
                    self.submit_tool_ids.insert(call.tool_call_id.clone());
                }
            }
            HostEvent::ToolCallUpdated {
                tool_call_id,
                status,
                ..
            } if matches!(status.as_deref(), Some("completed"))
                && self.submit_tool_ids.remove(tool_call_id) =>
            {
                self.changed = true;
            }
            _ => {}
        }
    }

    /// 取走一次“需要刷新”的信号；同一批事件只刷新一次。
    pub(crate) fn take_changed(&mut self) -> bool {
        std::mem::take(&mut self.changed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use cgc_platform::acp::connection::ToolCallView;

    fn tool_call(id: &str, name: &str) -> HostEvent {
        HostEvent::ToolCall {
            call: ToolCallView {
                tool_call_id: id.into(),
                title: "tool".into(),
                name: Some(name.into()),
                kind: "other".into(),
                status: "pending".into(),
                args: None,
                output: None,
                locations: Vec::new(),
            },
        }
    }

    fn completed(id: &str) -> HostEvent {
        HostEvent::ToolCallUpdated {
            tool_call_id: id.into(),
            title: None,
            status: Some("completed".into()),
            output: None,
        }
    }

    #[test]
    fn successful_submit_marks_once() {
        let mut tracker = LearningMutationTracker::default();
        tracker.observe(&tool_call(
            "call-1",
            "mcp_cgc-2046-learning_submit_learning_attempt",
        ));
        assert!(!tracker.take_changed());
        tracker.observe(&completed("call-1"));
        assert!(tracker.take_changed());
        assert!(!tracker.take_changed(), "signal must be consumed once");
    }

    #[test]
    fn non_submit_or_failed_calls_do_not_mark() {
        let mut tracker = LearningMutationTracker::default();
        tracker.observe(&tool_call("call-1", "run_command"));
        tracker.observe(&completed("call-1"));
        assert!(!tracker.take_changed());

        tracker.observe(&tool_call(
            "call-2",
            "mcp_cgc-2046-learning_submit_learning_attempt",
        ));
        tracker.observe(&HostEvent::ToolCallUpdated {
            tool_call_id: "call-2".into(),
            title: None,
            status: Some("failed".into()),
            output: None,
        });
        assert!(!tracker.take_changed());
    }

    #[test]
    fn interleaved_calls_keep_id_correlation() {
        let mut tracker = LearningMutationTracker::default();
        tracker.observe(&tool_call(
            "submit",
            "mcp_cgc-2046-learning_submit_learning_attempt",
        ));
        tracker.observe(&tool_call("read", "read_file"));
        tracker.observe(&completed("read"));
        assert!(!tracker.take_changed());
        tracker.observe(&completed("submit"));
        assert!(tracker.take_changed());
    }
}
