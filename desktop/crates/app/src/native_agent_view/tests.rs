//! native 视图单测（B4b 结构拆分第九片）。

use super::*;

use crate::native_context::{build_workspace_system_prompt, now_secs, offline_echo_notice};
use crate::native_panel_host::SubagentCard;
use crate::native_view_model::checkpoints_from_records;

mod workspace_prompt_tests {
    use super::state::NativeThreadState;
    use super::{
        build_workspace_system_prompt, now_secs, offline_echo_notice, NativeComposerGating,
    };

    #[test]
    fn subagent_rows_hidden_without_capability() {
        use super::SubagentCard;
        let cards = vec![SubagentCard {
            task: "t".into(),
            text: "x".into(),
            finished: None,
            tool_call_id: None,
        }];
        assert_eq!(super::subagent_cards_for_rows(true, &cards).len(), 1);
        assert!(
            super::subagent_cards_for_rows(false, &cards).is_empty(),
            "ACP 无 subagent 能力"
        );
    }

    #[test]
    fn checkpoint_panel_visibility_follows_capability_and_changes() {
        assert!(super::checkpoint_panel_visible(true, true, 2));
        assert!(
            !super::checkpoint_panel_visible(false, true, 2),
            "ACP 无 checkpoint 能力"
        );
        assert!(
            !super::checkpoint_panel_visible(true, false, 2),
            "面板未打开"
        );
        assert!(!super::checkpoint_panel_visible(true, true, 0), "无变更");
    }

    #[test]
    fn picker_gating_follows_capabilities() {
        use cgc_agent_ui::conversation::ThreadCapabilities;
        let native = NativeComposerGating::from_capabilities(ThreadCapabilities::native());
        assert!(native.pickers_available(), "native 渲染三个 picker");
        let acp = NativeComposerGating::from_capabilities(ThreadCapabilities::acp());
        assert!(
            !acp.pickers_available(),
            "ACP 走自己的 config options picker"
        );
    }

    #[test]
    fn slash_entries_are_grouped_and_filtered() {
        let registry = cgc_agent_tools::ToolRegistry::with_read_tools();
        let skills = vec![super::SkillEntry {
            name: "demo-skill".to_string(),
            description: "演示技能".to_string(),
            scope: "global".to_string(),
            file_path: std::path::PathBuf::from("/tmp/demo-skill/SKILL.md"),
        }];
        let all = super::slash_entries_for(registry.list_descriptions(), &skills, "/");
        assert!(all.iter().any(|entry| entry.category == "命令"));
        assert!(all.iter().any(|entry| entry.category == "工具"));
        // 技能条目必须带技能文件路径，chip / 发送注入都依赖它。
        assert!(all.iter().any(|entry| {
            entry.category == "技能"
                && entry.scope.as_deref() == Some("global")
                && entry
                    .skill
                    .as_ref()
                    .is_some_and(|skill| skill.file_path.ends_with("demo-skill/SKILL.md"))
        }));
        let filtered = super::slash_entries_for(registry.list_descriptions(), &skills, "/read");
        assert!(filtered.iter().all(|entry| entry.category == "工具"));
        assert!(!filtered.is_empty());
    }

    /// 回归：技能名匹配必须排在「工具描述里恰好包含该词」之前。
    /// 实际用户路径：输入 `/answer` 想选 answer-me-with-html，但 task 工具的描述
    /// 里也有 "answer"，原来的「命令→工具→技能」固定顺序让回车选中了 task。
    #[test]
    fn slash_menu_prefers_skill_name_match_over_tool_description_match() {
        let registry = cgc_agent_tools::ToolRegistry::with_read_tools().with_subagent(
            std::sync::Arc::new(|_, _| Box::pin(async { Ok(String::new()) })),
            std::sync::Arc::new(|_| {}),
        );
        let skills = vec![super::SkillEntry {
            name: "answer-me-with-html".to_string(),
            description: "把答案做成网页".to_string(),
            scope: "global".to_string(),
            file_path: std::path::PathBuf::from("/tmp/answer-me-with-html/SKILL.md"),
        }];

        let entries = super::slash_entries_for(registry.list_descriptions(), &skills, "/answer");
        assert_eq!(
            entries.first().map(|entry| entry.label.as_str()),
            Some("answer-me-with-html"),
            "技能名匹配应排在工具描述匹配之前：{entries:?}"
        );
        assert_eq!(entries[0].category, "技能");
    }

    #[test]
    fn slash_menu_ranks_name_prefix_above_description_match() {
        let registry = cgc_agent_tools::ToolRegistry::with_read_tools().with_subagent(
            std::sync::Arc::new(|_, _| Box::pin(async { Ok(String::new()) })),
            std::sync::Arc::new(|_| {}),
        );
        let entries = super::slash_entries_for(registry.list_descriptions(), &[], "/che");
        let labels = entries
            .iter()
            .map(|entry| entry.label.as_str())
            .collect::<Vec<_>>();
        assert!(
            labels.contains(&"/checkpoint"),
            "命令名前缀匹配应被保留：{labels:?}"
        );
        assert_eq!(
            entries.first().map(|entry| entry.label.as_str()),
            Some("/checkpoint")
        );
    }

    #[test]
    fn message_copy_payloads_cover_assistant_and_user() {
        let assistant = super::message_menu_payloads(
            super::ViewRole::Assistant,
            "## 标题\n**加粗** 和 `code`",
            Some("整回合文本".into()),
        );
        assert_eq!(assistant.markdown, "## 标题\n**加粗** 和 `code`");
        assert_eq!(assistant.plain, "标题\n加粗 和 code");
        assert_eq!(
            assistant.agent_response.as_deref(),
            Some("整回合文本"),
            "Copy This Agent Response 由调用方传入整回合文本"
        );

        let user =
            super::message_menu_payloads(super::ViewRole::User, "看 [@a](file://a.md) 这个", None);
        assert_eq!(user.plain, "看 @a 这个");
        assert_eq!(user.markdown, "看 [@a](file://a.md) 这个");
        assert!(user.agent_response.is_none(), "用户消息没有 agent response");
    }

    #[test]
    fn apply_thread_entries_builds_tool_cards_with_args() {
        use cgc_agent_core::Entry;
        use cgc_agent_provider::ToolUse;
        let entries = vec![
            Entry::User {
                text: "跑一下".into(),
                images: Vec::new(),
                display: None,
                at: 0,
            },
            Entry::Assistant {
                text: String::new(),
                tool_calls: vec![ToolUse {
                    id: "call_1".into(),
                    name: "run_command".into(),
                    args: serde_json::json!({"command": "echo hi"}),
                }],
                usage: None,
                at: 0,
            },
            Entry::ToolResult {
                tool_use_id: "call_1".into(),
                tool_name: "run_command".into(),
                content: "hi".into(),
                is_error: false,
                at: 0,
            },
            Entry::Thinking {
                text: "想一下".into(),
                signature: None,
                at: 0,
            },
        ];
        let mut state = NativeThreadState::new();
        super::apply_thread_entries(&mut state.session.thread, &entries);
        // Stage 2d：恢复的线程 entries 直接投影进共享模型。
        use cgc_agent_ui::conversation::Entry as ConversationEntry;
        assert_eq!(state.session.thread.entries.len(), 3);
        assert!(matches!(
            &state.session.thread.entries[0],
            ConversationEntry::User { text } if text == "跑一下"
        ));
        let ConversationEntry::ToolCall {
            tool_call_id,
            name,
            status,
            args,
            output,
            ..
        } = &state.session.thread.entries[1]
        else {
            panic!("thread tool call");
        };
        assert_eq!(tool_call_id, "call_1");
        assert_eq!(name.as_deref(), Some("run_command"));
        assert_eq!(status, "completed");
        assert!(args.as_deref().unwrap_or_default().contains("echo hi"));
        assert_eq!(output.as_deref(), Some("hi"));
        assert!(matches!(
            &state.session.thread.entries[2],
            ConversationEntry::Thinking { text, .. } if text == "想一下"
        ));
    }

    #[test]
    fn checkpoint_confirm_required_only_without_valid_snapshot() {
        // 有有效快照：静默重发（对齐 Zed）。
        assert!(!super::needs_checkpoint_confirm(true, None, 3));
        // 没有快照：第一次点击先弹确认。
        assert!(super::needs_checkpoint_confirm(false, None, 3));
        assert!(super::needs_checkpoint_confirm(false, Some(2), 3));
        // 已对同一条消息确认过：放行。
        assert!(!super::needs_checkpoint_confirm(false, Some(3), 3));
    }

    #[test]
    fn checkpoints_from_records_filters_invalid_and_sorts_by_ordinal() {
        use cgc_agent_store::CheckpointRecord;

        let record = |seq: i64, state: &str| CheckpointRecord {
            thread_id: "t".into(),
            user_entry_seq: seq,
            ref_name: format!("refs/cgc/checkpoints/{seq}"),
            sha: format!("sha-{seq}"),
            base_head: None,
            created_at: seq,
            state: state.into(),
        };
        let records = vec![
            record(2, "active"),
            record(1, "invalid"),
            record(0, "active"),
            record(3, "active"),
        ];
        let checkpoints = super::checkpoints_from_records(&records);
        assert_eq!(
            checkpoints
                .iter()
                .map(|(ordinal, checkpoint)| (*ordinal, checkpoint.sha.clone()))
                .collect::<Vec<_>>(),
            vec![(2, "sha-2".to_string()), (3, "sha-3".to_string())],
            "过滤 invalid/0 并按 ordinal 升序"
        );
        assert_eq!(checkpoints[0].1.seq, 2, "Checkpoint.seq 与 ordinal 对齐");
        assert_eq!(checkpoints[0].1.ref_name, "refs/cgc/checkpoints/2");
    }

    #[test]
    fn message_row_kinds_keep_inline_subagents_and_tail_rows_in_order() {
        use crate::native_panel_host::SubagentCard;
        use cgc_agent_ui::conversation::Entry as ConversationEntry;

        let subagent = |tool_call_id: Option<&str>, text: &str| SubagentCard {
            task: "task".into(),
            text: text.into(),
            finished: Some(true),
            tool_call_id: tool_call_id.map(str::to_string),
        };

        let messages = vec![
            ConversationEntry::User { text: "hi".into() },
            ConversationEntry::ToolCall {
                tool_call_id: "call_1".into(),
                title: "tool done".into(),
                name: None,
                kind: "tool".into(),
                status: "completed".into(),
                args: None,
                output: None,
                locations: Vec::new(),
                expanded: false,
            },
            ConversationEntry::Assistant {
                text: "answer".into(),
            },
        ];
        // 故意让尾部 card 排在前面：正确实现应按 tool_call_id 匹配到 index 1
        let subagents = vec![
            subagent(Some("call_2"), "tail"),
            subagent(Some("call_1"), "inline"),
        ];
        let kinds = super::build_message_row_kinds(&messages, &subagents, true);
        assert_eq!(
            kinds,
            vec![
                super::MessageRowKind::Message(0),
                super::MessageRowKind::Message(1),
                super::MessageRowKind::Subagent(1),
                super::MessageRowKind::Message(2),
                super::MessageRowKind::Subagent(0),
                super::MessageRowKind::Error,
            ],
            "子 agent 应内联到触发它的 tool 消息后，尾部按 剩余子 agent→错误 排列"
        );

        // 无流式/错误/子 agent 时只有历史消息行
        let kinds = super::build_message_row_kinds(&messages, &[], false);
        assert_eq!(
            kinds,
            vec![
                super::MessageRowKind::Message(0),
                super::MessageRowKind::Message(1),
                super::MessageRowKind::Message(2),
            ]
        );

        // 同一 tool_call_id 的重复子 agent 只内联第一个，其余留在尾部
        let duplicates = vec![subagent(Some("call_1"), "a"), subagent(Some("call_1"), "b")];
        let kinds = super::build_message_row_kinds(&messages, &duplicates, false);
        assert_eq!(
            kinds,
            vec![
                super::MessageRowKind::Message(0),
                super::MessageRowKind::Message(1),
                super::MessageRowKind::Subagent(0),
                super::MessageRowKind::Message(2),
                super::MessageRowKind::Subagent(1),
            ]
        );
    }

    #[test]
    fn thread_ordinal_and_trim_helpers_work_on_model_entries() {
        use cgc_agent_ui::conversation::Entry as ConversationEntry;
        let mut entries = vec![
            ConversationEntry::User { text: "q1".into() },
            ConversationEntry::Assistant { text: "a1".into() },
            ConversationEntry::User { text: "q2".into() },
            ConversationEntry::Thinking {
                text: "t".into(),
                expanded: false,
            },
        ];
        assert_eq!(super::thread_entry_ordinal(&entries, 0), Some(1));
        assert_eq!(super::thread_entry_ordinal(&entries, 1), None);
        assert_eq!(super::thread_entry_ordinal(&entries, 2), Some(2));
        assert_eq!(super::thread_entry_ordinal(&entries, 9), None);
        assert_eq!(super::trim_entries_to_last_user(&mut entries), Some(2));
        assert_eq!(entries.len(), 3, "裁到最近一条用户消息（含）");
        assert!(matches!(entries[2], ConversationEntry::User { .. }));
        assert_eq!(super::trim_entries_to_last_user(&mut Vec::new()), None);
    }

    #[test]
    fn view_row_maps_shared_entries_for_renderer_switch() {
        use cgc_agent_ui::conversation::{Entry as ConversationEntry, NoticeLevel};
        let tool = super::ViewRow::from_entry(&ConversationEntry::ToolCall {
            tool_call_id: "c1".into(),
            title: "run_command".into(),
            name: Some("run_command".into()),
            kind: "tool".into(),
            status: "failed".into(),
            args: Some("{\"command\":\"ls\"}".into()),
            output: Some("boom".into()),
            locations: Vec::new(),
            expanded: false,
        });
        assert_eq!(tool.role, super::ViewRole::Tool);
        let tool_data = tool.tool.expect("tool data");
        assert_eq!(tool_data.name, "run_command");
        assert_eq!(tool_data.args["command"], "ls");
        assert_eq!(tool_data.status, super::ViewToolStatus::Failed);
        assert_eq!(tool_data.content.as_deref(), Some("boom"));

        assert_eq!(
            super::ViewRow::from_entry(&ConversationEntry::Assistant { text: "a".into() }).role,
            super::ViewRole::Assistant
        );
        assert_eq!(
            super::ViewRow::from_entry(&ConversationEntry::Thinking {
                text: "t".into(),
                expanded: false
            })
            .role,
            super::ViewRole::Thinking
        );
        assert_eq!(
            super::ViewRow::from_entry(&ConversationEntry::Permission {
                request_id: "p".into(),
                title: "允许".into(),
                tool: None,
                tool_call_id: None,
                args: None,
                options: Vec::new(),
                resolved: None,
            })
            .role,
            super::ViewRole::System
        );
        assert_eq!(
            super::ViewRow::from_entry(&ConversationEntry::Notice {
                level: NoticeLevel::Error,
                text: "e".into(),
            })
            .role,
            super::ViewRole::Error
        );
        assert_eq!(
            super::ViewRow::from_entry(&ConversationEntry::Compaction {
                status: "completed".into(),
                summary: Some("s".into()),
            })
            .role,
            super::ViewRole::System
        );
    }

    #[test]
    fn retry_hint_only_for_credentials_errors() {
        assert!(super::retry_hint_for_error("api 401: invalid key").is_some());
        assert!(super::retry_hint_for_error("No credentials configured").is_some());
        assert!(super::retry_hint_for_error("API Key 不能为空").is_some());
        assert!(super::retry_hint_for_error("provider 500: internal error").is_none());
        assert!(super::retry_hint_for_error("network timeout").is_none());
    }

    #[test]
    fn offline_notice_only_when_using_echo() {
        assert!(offline_echo_notice(true).is_some());
        assert!(offline_echo_notice(false).is_none());
    }

    #[test]
    fn workspace_prompt_includes_rules_files() {
        let dir = std::env::temp_dir().join(format!(
            "cgc-workspace-prompt-{}-{}",
            std::process::id(),
            now_secs()
        ));
        std::fs::create_dir_all(&dir).expect("dir");
        std::fs::write(dir.join("AGENTS.md"), "root-rule").expect("root rule");
        let prompt = build_workspace_system_prompt(&dir);
        assert!(prompt.contains("root-rule"));
        assert!(prompt.contains("workspace_rules"));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
