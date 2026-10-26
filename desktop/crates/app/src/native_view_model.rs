//! B4b 准备：native 面板的视图模型（纯数据 + 转换，不依赖 GPUI）。
//!
//! `native_agent_view.rs` 只做渲染；行模型（entry → ViewRow）、消息行交错序列、
//! checkpoint 列表/ordinal 映射都在这里，便于删除旧视图后复用。

use cgc_agent_checkpoint::Checkpoint;
use cgc_agent_store::CheckpointRecord;
use cgc_agent_ui::conversation::Entry as ConversationEntry;

use crate::native_panel_host::SubagentCard;

/// native 渲染行（app 内视图模型，不再依赖 agent_host 的 UI 类型）。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ViewRole {
    User,
    Assistant,
    Thinking,
    Tool,
    System,
    Error,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ViewToolStatus {
    Running,
    Ok,
    Failed,
}

#[derive(Clone, Debug, PartialEq)]
pub(crate) struct ViewTool {
    pub(crate) name: String,
    pub(crate) args: serde_json::Value,
    pub(crate) status: ViewToolStatus,
    pub(crate) content: Option<String>,
}

#[derive(Clone, Debug, PartialEq)]
pub(crate) struct ViewRow {
    pub(crate) role: ViewRole,
    pub(crate) text: String,
    pub(crate) tool_call_id: Option<String>,
    pub(crate) tool: Option<ViewTool>,
}

impl ViewRow {
    pub(crate) fn from_entry(entry: &ConversationEntry) -> Self {
        match entry {
            ConversationEntry::User { text } => Self {
                role: ViewRole::User,
                text: text.clone(),
                tool_call_id: None,
                tool: None,
            },
            ConversationEntry::Assistant { text } => Self {
                role: ViewRole::Assistant,
                text: text.clone(),
                tool_call_id: None,
                tool: None,
            },
            ConversationEntry::Thinking { text, .. } => Self {
                role: ViewRole::Thinking,
                text: text.clone(),
                tool_call_id: None,
                tool: None,
            },
            ConversationEntry::ToolCall {
                tool_call_id,
                title,
                name,
                status,
                args,
                output,
                ..
            } => Self {
                role: ViewRole::Tool,
                text: output.clone().unwrap_or_default(),
                tool_call_id: Some(tool_call_id.clone()),
                tool: Some(ViewTool {
                    name: name.clone().unwrap_or_else(|| title.clone()),
                    args: args
                        .as_deref()
                        .and_then(|args| serde_json::from_str(args).ok())
                        .unwrap_or(serde_json::Value::Null),
                    status: match status.as_str() {
                        "completed" => ViewToolStatus::Ok,
                        "failed" => ViewToolStatus::Failed,
                        _ => ViewToolStatus::Running,
                    },
                    content: output.clone(),
                }),
            },
            ConversationEntry::Permission {
                title, resolved, ..
            } => Self {
                role: ViewRole::System,
                text: match resolved {
                    None => format!("等待审批：{title}"),
                    Some(true) => format!("已允许：{title}"),
                    Some(false) => format!("已拒绝：{title}"),
                },
                tool_call_id: None,
                tool: None,
            },
            ConversationEntry::Notice { level, text } => Self {
                role: if matches!(level, cgc_agent_ui::conversation::NoticeLevel::Error) {
                    ViewRole::Error
                } else {
                    ViewRole::System
                },
                text: text.clone(),
                tool_call_id: None,
                tool: None,
            },
            ConversationEntry::Compaction { status, summary } => Self {
                role: ViewRole::System,
                text: match summary {
                    Some(summary) => format!("上下文压缩（{status}）：{summary}"),
                    None => format!("上下文压缩（{status}）"),
                },
                tool_call_id: None,
                tool: None,
            },
        }
    }
}

/// 第 `index` 条模型 entry 的用户消息 ordinal（1-based）。
pub(crate) fn thread_entry_ordinal(entries: &[ConversationEntry], index: usize) -> Option<usize> {
    if !matches!(entries.get(index)?, ConversationEntry::User { .. }) {
        return None;
    }
    Some(
        entries[..=index]
            .iter()
            .filter(|entry| matches!(entry, ConversationEntry::User { .. }))
            .count(),
    )
}

/// 重试/编辑重发前把模型裁到最近一条用户消息。
pub(crate) fn trim_entries_to_last_user(entries: &mut Vec<ConversationEntry>) -> Option<usize> {
    let index = entries
        .iter()
        .rposition(|entry| matches!(entry, ConversationEntry::User { .. }))?;
    entries.truncate(index + 1);
    Some(index)
}

pub(crate) fn checkpoints_from_records(records: &[CheckpointRecord]) -> Vec<(usize, Checkpoint)> {
    let mut checkpoints: Vec<(usize, Checkpoint)> = records
        .iter()
        .filter(|record| record.state != "invalid" && record.user_entry_seq > 0)
        .map(|record| {
            (
                record.user_entry_seq as usize,
                Checkpoint {
                    thread_id: record.thread_id.clone(),
                    seq: record.user_entry_seq.max(0) as u64,
                    ref_name: record.ref_name.clone(),
                    sha: record.sha.clone(),
                    base_head: record.base_head.clone(),
                },
            )
        })
        .collect();
    checkpoints.sort_by_key(|(ordinal, _)| *ordinal);
    checkpoints
}

/// 无可用 checkpoint 时，编辑重发必须先二次确认。
pub(crate) fn needs_checkpoint_confirm(
    has_valid_checkpoint: bool,
    pending: Option<usize>,
    message_index: usize,
) -> bool {
    !has_valid_checkpoint && pending != Some(message_index)
}

pub(crate) fn checkpoint_for_ordinal(
    records: &[cgc_agent_store::CheckpointRecord],
    ordinal: usize,
) -> Option<cgc_agent_store::CheckpointRecord> {
    records
        .iter()
        .find(|record| record.user_entry_seq == ordinal as i64 && record.state != "invalid")
        .cloned()
}

/// 第 `message_index` 条 UI 消息是第几条用户消息（1-based）。
/// 第 `ordinal` 条用户消息（1-based）在 thread entries 里的下标。
pub(crate) fn thread_user_entry_index(
    entries: &[cgc_agent_core::Entry],
    ordinal: usize,
) -> Option<usize> {
    entries
        .iter()
        .enumerate()
        .filter(|(_, entry)| matches!(entry, cgc_agent_core::Entry::User { .. }))
        .nth(ordinal.checked_sub(1)?)
        .map(|(index, _)| index)
}

/// 消息区的行类型：历史消息、内联子 agent、流式思考、流式回复、错误，
/// 以及回合末不是 assistant 时的底部兜底操作栏（Zed 的 last-assistant fallback）。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum MessageRowKind {
    Message(usize),
    Subagent(usize),
    Error,
    TrailingActions,
}

/// 计算消息区的行序列；子 agent 卡内联到触发它的 tool 消息后面，
/// 其余子 agent 与流式/错误行按旧渲染顺序排在末尾。
/// B3c：capability gating —— 无 subagent 能力时行序列不注入子 agent 行
/// （ACP 走自己的 subagent 展示，native 版不硬塞）。
pub(crate) fn subagent_cards_for_rows(
    subagent_available: bool,
    cards: &[SubagentCard],
) -> &[SubagentCard] {
    if subagent_available {
        cards
    } else {
        &[]
    }
}

pub(crate) fn build_message_row_kinds(
    entries: &[ConversationEntry],
    subagents: &[SubagentCard],
    has_error: bool,
) -> Vec<MessageRowKind> {
    let mut kinds = Vec::with_capacity(entries.len() + subagents.len() + 3);
    let mut used_subagents = vec![false; subagents.len()];
    for (message_index, entry) in entries.iter().enumerate() {
        kinds.push(MessageRowKind::Message(message_index));
        let tool_call_id = match entry {
            ConversationEntry::ToolCall { tool_call_id, .. } => Some(tool_call_id.as_str()),
            _ => None,
        };
        if let Some(tool_call_id) = tool_call_id {
            if let Some(subagent_index) = subagents
                .iter()
                .enumerate()
                .find(|(index, card)| {
                    !used_subagents[*index] && card.tool_call_id.as_deref() == Some(tool_call_id)
                })
                .map(|(index, _)| index)
            {
                used_subagents[subagent_index] = true;
                kinds.push(MessageRowKind::Subagent(subagent_index));
            }
        }
    }
    for (index, used) in used_subagents.into_iter().enumerate() {
        if !used {
            kinds.push(MessageRowKind::Subagent(index));
        }
    }
    if has_error {
        kinds.push(MessageRowKind::Error);
    }
    kinds
}

#[cfg(test)]
mod tests {
    use super::*;
    use cgc_agent_ui::conversation::{Entry as ConversationEntry, NoticeLevel};

    fn subagent(tool_call_id: Option<&str>) -> SubagentCard {
        SubagentCard {
            task: "task".into(),
            text: "running".into(),
            finished: Some(true),
            tool_call_id: tool_call_id.map(str::to_string),
        }
    }

    #[test]
    fn entry_to_row_maps_roles_and_tool_payload() {
        let user = ViewRow::from_entry(&ConversationEntry::User { text: "hi".into() });
        assert_eq!(user.role, ViewRole::User);
        assert_eq!(user.text, "hi");

        let assistant = ViewRow::from_entry(&ConversationEntry::Assistant { text: "a".into() });
        assert_eq!(assistant.role, ViewRole::Assistant);

        let tool = ViewRow::from_entry(&ConversationEntry::ToolCall {
            tool_call_id: "call-1".into(),
            title: "tool".into(),
            name: Some("read_file".into()),
            kind: "tool".into(),
            status: "completed".into(),
            args: Some(r#"{"path":"a.rs"}"#.into()),
            output: Some("content".into()),
            locations: Vec::new(),
            expanded: false,
        });
        assert_eq!(tool.role, ViewRole::Tool);
        assert_eq!(tool.tool_call_id.as_deref(), Some("call-1"));
        let payload = tool.tool.expect("tool payload");
        assert_eq!(payload.name, "read_file");
        assert_eq!(payload.status, ViewToolStatus::Ok);
        assert_eq!(payload.args["path"], "a.rs");

        let permission = ViewRow::from_entry(&ConversationEntry::Permission {
            request_id: "p".into(),
            title: "edit".into(),
            tool: Some("edit".into()),
            tool_call_id: None,
            args: None,
            options: Vec::new(),
            resolved: Some(false),
        });
        assert_eq!(permission.role, ViewRole::System);
        assert!(permission.text.contains("已拒绝"));

        let notice = ViewRow::from_entry(&ConversationEntry::Notice {
            level: NoticeLevel::Error,
            text: "boom".into(),
        });
        assert_eq!(notice.role, ViewRole::Error);
    }

    #[test]
    fn message_rows_interleave_subagent_after_triggering_tool() {
        let entries = vec![
            ConversationEntry::User { text: "q".into() },
            ConversationEntry::ToolCall {
                tool_call_id: "call-1".into(),
                title: "tool".into(),
                name: Some("task".into()),
                kind: "tool".into(),
                status: "running".into(),
                args: None,
                output: None,
                locations: Vec::new(),
                expanded: false,
            },
            ConversationEntry::Assistant { text: "a".into() },
        ];
        let subagents = vec![
            subagent(Some("call-1")),
            subagent(None), // 尾部未匹配的子 agent
        ];
        let kinds = build_message_row_kinds(&entries, &subagents, true);
        assert_eq!(
            kinds,
            vec![
                MessageRowKind::Message(0),
                MessageRowKind::Message(1),
                MessageRowKind::Subagent(0),
                MessageRowKind::Message(2),
                MessageRowKind::Subagent(1),
                MessageRowKind::Error,
            ]
        );
    }

    #[test]
    fn subagent_gating_hides_rows_without_capability() {
        let cards = vec![subagent(None)];
        assert_eq!(subagent_cards_for_rows(true, &cards).len(), 1);
        assert!(subagent_cards_for_rows(false, &cards).is_empty());
    }

    #[test]
    fn checkpoint_records_filter_invalid_and_sort() {
        let record = |seq: i64, state: &str| CheckpointRecord {
            thread_id: "t".into(),
            user_entry_seq: seq,
            ref_name: format!("refs/{seq}"),
            sha: format!("sha{seq}"),
            base_head: None,
            created_at: 1,
            state: state.into(),
        };
        let records = vec![
            record(2, "active"),
            record(1, "invalid"),
            record(0, "active"),
            record(1, "active"),
        ];
        let checkpoints = checkpoints_from_records(&records);
        assert_eq!(
            checkpoints
                .iter()
                .map(|(ordinal, _)| *ordinal)
                .collect::<Vec<_>>(),
            vec![1, 2],
            "invalid 与非法 seq 过滤并按 ordinal 排序"
        );
        assert_eq!(
            checkpoint_for_ordinal(&records, 2).map(|record| record.sha),
            Some("sha2".to_string())
        );
        let active = checkpoint_for_ordinal(&records, 1).expect("active seq1");
        assert_eq!(active.state, "active", "invalid 记录被跳过");
        assert_eq!(active.sha, "sha1");
    }

    #[test]
    fn ordinals_and_trim_follow_user_turns() {
        let mut entries = vec![
            ConversationEntry::User { text: "q1".into() },
            ConversationEntry::Assistant { text: "a1".into() },
            ConversationEntry::User { text: "q2".into() },
            ConversationEntry::Thinking {
                text: "t".into(),
                expanded: false,
            },
        ];
        assert_eq!(thread_entry_ordinal(&entries, 0), Some(1));
        assert_eq!(thread_entry_ordinal(&entries, 1), None);
        assert_eq!(thread_entry_ordinal(&entries, 2), Some(2));
        assert_eq!(trim_entries_to_last_user(&mut entries), Some(2));
        assert_eq!(entries.len(), 3);
    }
}
