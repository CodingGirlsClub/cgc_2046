//! 可恢复的会话投影（Plan 004）。
//!
//! 只保存「重开时该看到什么」，不保存可执行通道、live resolver 或视图展开状态：
//! - 已答审批保留原选项与决定；
//! - 未答审批降级为 Warning Notice，绝不作为可点击授权恢复；
//! - 保存时的 `status` 不进入投影，恢复后一律从 idle 开始。
//!
//! 与 `thread_content.data` 并存：旧表继续写原 `ConversationThread`，本投影写新表，
//! 旧版本 reader 完全不知道它存在（add-only）。

use cgc_agent_conversation::conversation::{
    ConversationThread, Entry, NoticeLevel, PlanStep, ThreadCapabilities, Usage,
};
use serde::{Deserialize, Serialize};

/// 投影来源；两个库共用同一结构，避免出现两套同义格式。
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SnapshotSource {
    Acp,
    Native,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct SavedConversation {
    pub thread_id: String,
    /// 单调递增；读取时用于丢弃乱序到达的旧快照。
    pub revision: u64,
    pub source: SnapshotSource,
    pub title: Option<String>,
    pub entries: Vec<Entry>,
    pub plan: Vec<PlanStep>,
    pub usage: Usage,
    pub capabilities: ThreadCapabilities,
}

impl SavedConversation {
    /// 把共享会话模型投影成可持久化的副本。
    pub fn from_thread(thread: &ConversationThread, source: SnapshotSource, revision: u64) -> Self {
        let entries = thread
            .entries
            .iter()
            .map(|entry| match entry {
                // 未答审批只是「当时在等」的历史事实，恢复后不可执行。
                Entry::Permission {
                    title,
                    resolved: None,
                    ..
                } => Entry::Notice {
                    level: NoticeLevel::Warning,
                    text: format!("审批已失效（会话中断）：{title}"),
                },
                other => other.clone(),
            })
            .collect();
        Self {
            thread_id: thread.thread_id.clone(),
            revision,
            source,
            title: thread.title.clone(),
            entries,
            plan: thread.plan.clone(),
            usage: thread.usage.clone(),
            capabilities: thread.capabilities,
        }
    }

    /// 恢复为展示模型：状态从默认（idle）开始，pending 审批为空。
    pub fn into_thread(&self) -> ConversationThread {
        ConversationThread {
            thread_id: self.thread_id.clone(),
            title: self.title.clone(),
            entries: self.entries.clone(),
            capabilities: self.capabilities,
            usage: self.usage.clone(),
            plan: self.plan.clone(),
            ..ConversationThread::default()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use cgc_agent_conversation::conversation::{
        PermissionOption, PermissionOptionKind, ThreadStatus,
    };

    fn thread_with(entries: Vec<Entry>) -> ConversationThread {
        ConversationThread {
            thread_id: "t1".into(),
            entries,
            status: ThreadStatus::AwaitingApproval,
            ..ConversationThread::default()
        }
    }

    #[test]
    fn unanswered_approval_becomes_inert_notice_and_never_restores_as_pending() {
        let thread = thread_with(vec![Entry::Permission {
            request_id: "perm-1".into(),
            title: "允许运行 run_command？".into(),
            tool: Some("run_command".into()),
            tool_call_id: Some("call-1".into()),
            args: None,
            options: vec![PermissionOption {
                id: "allow_once".into(),
                label: "允许一次".into(),
                kind: PermissionOptionKind::AllowOnce,
            }],
            resolved: None,
        }]);
        let snapshot = SavedConversation::from_thread(&thread, SnapshotSource::Native, 3);
        assert!(matches!(
            &snapshot.entries[..],
            [Entry::Notice { level: NoticeLevel::Warning, text }] if text.contains("审批已失效")
        ));
        let restored = snapshot.into_thread();
        assert!(
            restored.pending_permission.is_none(),
            "恢复后不得存在活跃审批"
        );
        assert_eq!(
            restored.status,
            ThreadStatus::Idle,
            "保存时的状态不得驱动新会话"
        );
        assert!(matches!(
            &thread.entries[..],
            [Entry::Permission { resolved: None, .. }]
        ));
    }

    #[test]
    fn answered_permission_keeps_its_decision() {
        let thread = thread_with(vec![Entry::Permission {
            request_id: "perm-2".into(),
            title: "允许运行 run_command？".into(),
            tool: Some("run_command".into()),
            tool_call_id: None,
            args: None,
            options: Vec::new(),
            resolved: Some(true),
        }]);
        let snapshot = SavedConversation::from_thread(&thread, SnapshotSource::Acp, 1);
        assert!(matches!(
            &snapshot.entries[..],
            [Entry::Permission {
                resolved: Some(true),
                ..
            }]
        ));
    }
}
