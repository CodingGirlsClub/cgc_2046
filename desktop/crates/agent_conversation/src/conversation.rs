//! 共享会话模型（Stage 2）：`ConversationThread` / `Entry` / `ThreadEvent` / reducer。
//!
//! 两轨（native、external ACP）各自把运行时事件映射成 [`ThreadEvent`]，由同一份
//! reducer 更新模型；UI 只读模型，不再各自维护 `ChatEntry` / `UiMessage` 两套渲染路径。
//! 运行时能力（provider/tools/checkpoint 存储/MCP）留在各自 crate，不在这里合并。
//!
//! 与 Zed 的对应：`ConversationThread` ≈ `acp_thread::AcpThread`（客户端会话模型），
//! 能力位 ≈ Zed 的 `AcpThread` 能力判断；UI 渲染仍由 `message_flow` / `message_row` /
//! `message_actions` 承担，本模块不依赖 gpui。

use serde::{Deserialize, Serialize};

use crate::message_flow::{RowKind, RowView};

/// 线程状态（决定底部操作栏/输入框是否可发送、审批态提示等）。
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ThreadStatus {
    #[default]
    Idle,
    Generating,
    AwaitingApproval,
    Failed,
}

/// 双轨能力位：模型字段照常存在，UI 按位决定是否显示入口（编辑/恢复/steer/queue）。
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ThreadCapabilities {
    pub checkpoint_restore: bool,
    pub steer: bool,
    pub queue: bool,
    pub subagent: bool,
    pub config_options: bool,
    pub plan: bool,
    pub usage: bool,
}

impl ThreadCapabilities {
    /// native 轨道：Git checkpoint / steer / queue / subagent / plan / usage 都有。
    pub const fn native() -> Self {
        Self {
            checkpoint_restore: true,
            steer: true,
            queue: true,
            subagent: true,
            config_options: true,
            plan: true,
            usage: true,
        }
    }

    /// external ACP 轨道：无 checkpoint/truncate、无 steer/queue/subagent；config 由
    /// session config options 决定，plan/usage 取决于 agent 是否发送对应 update。
    pub const fn acp() -> Self {
        Self {
            checkpoint_restore: false,
            steer: false,
            queue: false,
            subagent: false,
            config_options: true,
            plan: true,
            usage: true,
        }
    }
}

impl ThreadCapabilities {
    /// 以下访问器供 UI gating 使用（不在视图里直接读字段，便于未来扩展能力位语义）。
    pub fn checkpoint_available(&self) -> bool {
        self.checkpoint_restore
    }

    pub fn steer_available(&self) -> bool {
        self.steer
    }

    pub fn queue_available(&self) -> bool {
        self.queue
    }

    pub fn subagent_available(&self) -> bool {
        self.subagent
    }

    pub fn plan_available(&self) -> bool {
        self.plan
    }

    pub fn usage_available(&self) -> bool {
        self.usage
    }

    pub fn config_available(&self) -> bool {
        self.config_options
    }
}

/// 上下文用量（ACP `usage_update` / native `UsageUpdated`）。
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Usage {
    pub used: u64,
    pub size: u64,
    pub cost: Option<String>,
}

impl Usage {
    /// 0..=100 的百分比；`size == 0` 时返回 `None`（UI 不显示）。
    pub fn percent(&self) -> Option<u64> {
        (self.size > 0).then(|| (self.used.saturating_mul(100)) / self.size)
    }
}

/// 计划步骤（ACP `Plan` 每次全量替换；native 来自 plan/todo 工具）。
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PlanStep {
    pub content: String,
    pub priority: String,
    pub status: String,
}

/// 审批选项类别（ACP `PermissionOptionKind` 的协议无关形态）。
///
/// 只影响 UI 样式与「允许/拒绝」语义判断；具体语义（一次/本会话/前缀）由
/// `label` 与 `id` 表达，运行时按 `id` 回传。
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PermissionOptionKind {
    AllowOnce,
    AllowAlways,
    RejectOnce,
    RejectAlways,
    Other,
}

impl PermissionOptionKind {
    pub fn is_allow(self) -> bool {
        matches!(self, Self::AllowOnce | Self::AllowAlways)
    }

    pub fn is_reject(self) -> bool {
        matches!(self, Self::RejectOnce | Self::RejectAlways)
    }
}

/// 一个审批选项（ACP 形状：`option_id` + 展示名 + kind，顺序由请求方决定）。
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PermissionOption {
    pub id: String,
    pub label: String,
    pub kind: PermissionOptionKind,
}

/// 待审批请求（ACP 形状：`{ id, tool, args, options }`；批准逻辑在运行时）。
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PermissionRequest {
    pub request_id: String,
    pub title: String,
    /// 发起审批的工具名（native 为 `run_command` 等；ACP agent 可能不给）。
    pub tool: Option<String>,
    pub tool_call_id: Option<String>,
    pub args: Option<String>,
    /// 请求方提供的选项（顺序即 UI 渲染顺序；两轨都原样透传）。
    pub options: Vec<PermissionOption>,
}

/// checkpoint 摘要（native 有，ACP 恒 `None`）。
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct CheckpointInfo {
    pub id: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NoticeLevel {
    Info,
    Warning,
    Error,
}

/// 模型行；UI 渲染的原子单位。
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Entry {
    User {
        text: String,
    },
    Assistant {
        text: String,
    },
    Thinking {
        text: String,
        expanded: bool,
    },
    ToolCall {
        tool_call_id: String,
        title: String,
        name: Option<String>,
        kind: String,
        status: String,
        args: Option<String>,
        output: Option<String>,
        locations: Vec<String>,
        expanded: bool,
    },
    Permission {
        request_id: String,
        title: String,
        tool: Option<String>,
        tool_call_id: Option<String>,
        args: Option<String>,
        options: Vec<PermissionOption>,
        resolved: Option<bool>,
    },
    Notice {
        level: NoticeLevel,
        text: String,
    },
    Compaction {
        status: String,
        summary: Option<String>,
    },
}

impl Entry {
    pub fn row_kind(&self) -> RowKind {
        match self {
            Entry::User { .. } => RowKind::User,
            Entry::Assistant { .. } => RowKind::Assistant,
            Entry::Thinking { .. } => RowKind::Thinking,
            Entry::ToolCall { .. } => RowKind::Tool,
            Entry::Permission { .. } => RowKind::Permission,
            Entry::Notice { .. } | Entry::Compaction { .. } => RowKind::Status,
        }
    }

    pub fn assistant_text(&self) -> Option<&str> {
        match self {
            Entry::Assistant { text } => Some(text),
            _ => None,
        }
    }

    pub fn toggle_thinking(&mut self) {
        if let Entry::Thinking { expanded, .. } = self {
            *expanded = !*expanded;
        }
    }

    pub fn toggle_tool(&mut self) {
        if let Entry::ToolCall { expanded, .. } = self {
            *expanded = !*expanded;
        }
    }
}

fn entry_row_kind(entry: &Entry) -> RowKind {
    entry.row_kind()
}

fn entry_assistant_text(entry: &Entry) -> Option<&str> {
    entry.assistant_text()
}

/// 客户端会话模型；线程级状态 + 有序 entries + 能力位/用量/计划/审批。
///
/// Stage 3.3 起可直接 serde 序列化（ACP transcript 存本地 `conversations.db`）；
/// `#[serde(default)]` 保证后续字段扩展时旧记录可读（缺字段回落默认）。
#[derive(Clone, Debug, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct ConversationThread {
    pub thread_id: String,
    pub title: Option<String>,
    pub entries: Vec<Entry>,
    pub status: ThreadStatus,
    pub capabilities: ThreadCapabilities,
    pub usage: Usage,
    pub plan: Vec<PlanStep>,
    pub checkpoint: Option<CheckpointInfo>,
    pub pending_permission: Option<PermissionRequest>,
}

impl ConversationThread {
    pub fn new(thread_id: impl Into<String>) -> Self {
        Self {
            thread_id: thread_id.into(),
            ..Self::default()
        }
    }

    pub fn with_capabilities(mut self, capabilities: ThreadCapabilities) -> Self {
        self.capabilities = capabilities;
        self
    }

    /// 交给 `message_flow` 的只读行视图（操作栏 gating / 整回合复制 / scroll target）。
    pub fn row_view(&self) -> RowView<'_, Entry> {
        RowView::new(&self.entries, entry_row_kind, entry_assistant_text)
    }

    pub fn is_generating(&self) -> bool {
        matches!(
            self.status,
            ThreadStatus::Generating | ThreadStatus::AwaitingApproval
        )
    }

    /// 统一 reducer：两轨的 ingestion 都只调用它。
    pub fn apply(&mut self, event: ThreadEvent) {
        match event {
            ThreadEvent::Loaded {
                entries,
                capabilities,
                usage,
            } => {
                self.entries = entries;
                self.capabilities = capabilities;
                self.usage = usage;
                self.status = ThreadStatus::Idle;
                self.pending_permission = None;
            }
            ThreadEvent::TurnStarted { user_text } => {
                self.entries.push(Entry::User { text: user_text });
                self.status = ThreadStatus::Generating;
            }
            ThreadEvent::TextDelta(text) => {
                self.status = ThreadStatus::Generating;
                match self.entries.last_mut() {
                    Some(Entry::Assistant { text: last }) => last.push_str(&text),
                    _ => self.entries.push(Entry::Assistant { text }),
                }
            }
            ThreadEvent::ThinkingDelta(text) => {
                self.status = ThreadStatus::Generating;
                match self.entries.last_mut() {
                    Some(Entry::Thinking { text: last, .. }) => last.push_str(&text),
                    _ => self.entries.push(Entry::Thinking {
                        text,
                        expanded: true,
                    }),
                }
            }
            ThreadEvent::ToolCallStarted {
                tool_call_id,
                title,
                name,
                kind,
                status,
                args,
                output,
                locations,
            } => {
                self.status = ThreadStatus::Generating;
                self.entries.push(Entry::ToolCall {
                    tool_call_id,
                    title,
                    name,
                    kind,
                    status,
                    args,
                    output,
                    locations,
                    expanded: false,
                });
            }
            ThreadEvent::ToolCallUpdated {
                tool_call_id,
                title,
                status,
                output,
            } => {
                let Some(Entry::ToolCall {
                    title: entry_title,
                    status: entry_status,
                    output: entry_output,
                    ..
                }) = self.entries.iter_mut().find(|entry| {
                    matches!(entry, Entry::ToolCall { tool_call_id: id, .. } if id == &tool_call_id)
                }) else {
                    return;
                };
                if let Some(title) = title {
                    *entry_title = title;
                }
                if let Some(status) = status {
                    *entry_status = status;
                }
                if let Some(output) = output {
                    *entry_output = Some(output);
                }
            }
            ThreadEvent::PermissionRequested {
                request_id,
                title,
                tool,
                tool_call_id,
                args,
                options,
            } => {
                // native/ACP 都可能对同一次审批重复发事件（工具执行与 UI 各一次）：
                // 同一个未解决的审批只保留一条 entry，避免重复「等待审批」行。
                let duplicate = self.entries.iter().rev().any(|entry| match entry {
                    Entry::Permission {
                        resolved: None,
                        tool_call_id: pending_tool,
                        title: pending_title,
                        ..
                    } => pending_tool == &tool_call_id && pending_title == &title,
                    _ => false,
                });
                if duplicate {
                    return;
                }
                self.status = ThreadStatus::AwaitingApproval;
                self.entries.push(Entry::Permission {
                    request_id: request_id.clone(),
                    title: title.clone(),
                    tool: tool.clone(),
                    tool_call_id: tool_call_id.clone(),
                    args: args.clone(),
                    options: options.clone(),
                    resolved: None,
                });
                self.pending_permission = Some(PermissionRequest {
                    request_id,
                    title,
                    tool,
                    tool_call_id,
                    args,
                    options,
                });
            }
            ThreadEvent::PermissionResolved {
                request_id,
                allowed,
            } => {
                for entry in &mut self.entries {
                    if let Entry::Permission {
                        request_id: id,
                        resolved,
                        ..
                    } = entry
                    {
                        if id == &request_id {
                            *resolved = Some(allowed);
                        }
                    }
                }
                if self
                    .pending_permission
                    .as_ref()
                    .is_some_and(|pending| pending.request_id == request_id)
                {
                    self.pending_permission = None;
                    self.status = ThreadStatus::Generating;
                }
            }
            ThreadEvent::PlanUpdated(steps) => self.plan = steps,
            ThreadEvent::UsageUpdated { used, size, cost } => {
                self.usage = Usage { used, size, cost };
            }
            ThreadEvent::TitleUpdated(title) => self.title = title,
            ThreadEvent::Notice { level, text } => {
                self.entries.push(Entry::Notice { level, text });
            }
            ThreadEvent::CompactionUpdated { status, summary } => {
                self.entries.push(Entry::Compaction { status, summary });
            }
            ThreadEvent::TurnFinished { .. } => {
                self.status = ThreadStatus::Idle;
                self.pending_permission = None;
                for entry in &mut self.entries {
                    if let Entry::Thinking { expanded, .. } = entry {
                        *expanded = false;
                    }
                }
            }
            ThreadEvent::Failed(message) => {
                self.status = ThreadStatus::Failed;
                self.pending_permission = None;
                self.entries.push(Entry::Notice {
                    level: NoticeLevel::Error,
                    text: message,
                });
            }
        }
    }
}

/// 统一 reducer 输入：协议无关，native/ACP 各自映射。
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ThreadEvent {
    Loaded {
        entries: Vec<Entry>,
        capabilities: ThreadCapabilities,
        usage: Usage,
    },
    TurnStarted {
        user_text: String,
    },
    TextDelta(String),
    ThinkingDelta(String),
    ToolCallStarted {
        tool_call_id: String,
        title: String,
        name: Option<String>,
        kind: String,
        status: String,
        args: Option<String>,
        output: Option<String>,
        locations: Vec<String>,
    },
    ToolCallUpdated {
        tool_call_id: String,
        title: Option<String>,
        status: Option<String>,
        output: Option<String>,
    },
    PermissionRequested {
        request_id: String,
        title: String,
        tool: Option<String>,
        tool_call_id: Option<String>,
        args: Option<String>,
        options: Vec<PermissionOption>,
    },
    PermissionResolved {
        request_id: String,
        allowed: bool,
    },
    PlanUpdated(Vec<PlanStep>),
    UsageUpdated {
        used: u64,
        size: u64,
        cost: Option<String>,
    },
    TitleUpdated(Option<String>),
    Notice {
        level: NoticeLevel,
        text: String,
    },
    CompactionUpdated {
        status: String,
        summary: Option<String>,
    },
    TurnFinished {
        cancelled: bool,
    },
    Failed(String),
}

#[cfg(test)]
mod tests {
    use super::{
        ConversationThread, Entry, NoticeLevel, PlanStep, ThreadCapabilities, ThreadEvent,
        ThreadStatus,
    };
    use crate::message_flow::RowKind;

    fn started_thread() -> ConversationThread {
        ConversationThread::new("t").with_capabilities(ThreadCapabilities::acp())
    }

    /// 两轨 ingestion 都把事件归一到同一序列：模型输出必须完全一致。
    #[test]
    fn native_and_acp_events_produce_same_entries() {
        let events = vec![
            ThreadEvent::TurnStarted {
                user_text: "fix it".into(),
            },
            ThreadEvent::ThinkingDelta("look".into()),
            ThreadEvent::TextDelta("I will ".into()),
            ThreadEvent::ToolCallStarted {
                tool_call_id: "call-1".into(),
                title: "Edit file".into(),
                name: Some("edit_file".into()),
                kind: "Edit".into(),
                status: "in_progress".into(),
                args: Some("{\"path\":\"a.rs\"}".into()),
                output: None,
                locations: vec!["a.rs:3".into()],
            },
            ThreadEvent::ToolCallUpdated {
                tool_call_id: "call-1".into(),
                title: None,
                status: Some("completed".into()),
                output: Some("ok".into()),
            },
            ThreadEvent::TextDelta("done".into()),
            ThreadEvent::PermissionRequested {
                request_id: "perm-1".into(),
                title: "approve".into(),
                tool: Some("run_command".into()),
                tool_call_id: Some("call-1".into()),
                args: None,
                options: vec![
                    super::PermissionOption {
                        id: "allow_once".into(),
                        label: "允许一次".into(),
                        kind: super::PermissionOptionKind::AllowOnce,
                    },
                    super::PermissionOption {
                        id: "deny".into(),
                        label: "拒绝".into(),
                        kind: super::PermissionOptionKind::RejectOnce,
                    },
                ],
            },
            ThreadEvent::PermissionResolved {
                request_id: "perm-1".into(),
                allowed: true,
            },
            ThreadEvent::PlanUpdated(vec![PlanStep {
                content: "verify".into(),
                priority: "high".into(),
                status: "completed".into(),
            }]),
            ThreadEvent::UsageUpdated {
                used: 1200,
                size: 64_000,
                cost: None,
            },
            ThreadEvent::TitleUpdated(Some("Fix".into())),
            ThreadEvent::CompactionUpdated {
                status: "completed".into(),
                summary: Some("compacted".into()),
            },
            ThreadEvent::TurnFinished { cancelled: false },
        ];
        let mut native = started_thread();
        let mut acp = started_thread();
        for event in events.clone() {
            native.apply(event.clone());
            acp.apply(event);
        }
        assert_eq!(native.entries, acp.entries);
        assert_eq!(native.entries.len(), 7);
        assert_eq!(native.entries[0].row_kind(), RowKind::User);
        assert_eq!(native.entries[1].row_kind(), RowKind::Thinking);
        assert_eq!(native.entries[2].row_kind(), RowKind::Assistant);
        assert_eq!(native.entries[3].row_kind(), RowKind::Tool);
        assert_eq!(native.entries[4].row_kind(), RowKind::Assistant);
        assert_eq!(native.entries[5].row_kind(), RowKind::Permission);
        assert_eq!(native.entries[6].row_kind(), RowKind::Status);
        assert_eq!(native.status, ThreadStatus::Idle);
        assert_eq!(native.usage.percent(), Some(1));
        assert_eq!(native.title.as_deref(), Some("Fix"));
        assert_eq!(native.plan.len(), 1);
        let Entry::ToolCall {
            status,
            output,
            expanded,
            ..
        } = &native.entries[3]
        else {
            panic!("tool entry");
        };
        assert_eq!(status, "completed");
        assert_eq!(output.as_deref(), Some("ok"));
        assert!(!expanded);
        let Entry::Thinking { expanded, .. } = &native.entries[1] else {
            panic!("thinking entry");
        };
        assert!(!expanded, "回合结束折叠 thinking");
        let Entry::Permission { resolved, .. } = &native.entries[5] else {
            panic!("permission entry");
        };
        assert_eq!(*resolved, Some(true));
    }

    #[test]
    fn text_after_tool_starts_a_new_assistant_entry() {
        let mut thread = started_thread();
        thread.apply(ThreadEvent::TurnStarted {
            user_text: "q".into(),
        });
        thread.apply(ThreadEvent::TextDelta("before ".into()));
        thread.apply(ThreadEvent::ToolCallStarted {
            tool_call_id: "c".into(),
            title: "t".into(),
            name: None,
            kind: "Read".into(),
            status: "in_progress".into(),
            args: None,
            output: None,
            locations: Vec::new(),
        });
        thread.apply(ThreadEvent::TextDelta("after".into()));
        assert_eq!(thread.entries.len(), 4);
        assert_eq!(thread.entries[1].assistant_text(), Some("before "));
        assert_eq!(thread.entries[3].assistant_text(), Some("after"));
    }

    #[test]
    fn tool_updates_merge_by_id_and_ignore_unknown_ids() {
        let mut thread = started_thread();
        thread.apply(ThreadEvent::ToolCallStarted {
            tool_call_id: "c1".into(),
            title: "Read".into(),
            name: Some("read_file".into()),
            kind: "Read".into(),
            status: "pending".into(),
            args: Some("{\"path\":\"a\"}".into()),
            output: None,
            locations: Vec::new(),
        });
        thread.apply(ThreadEvent::ToolCallStarted {
            tool_call_id: "c2".into(),
            title: "Write".into(),
            name: None,
            kind: "Edit".into(),
            status: "pending".into(),
            args: None,
            output: None,
            locations: Vec::new(),
        });
        thread.apply(ThreadEvent::ToolCallUpdated {
            tool_call_id: "c2".into(),
            title: Some("Write done".into()),
            status: Some("completed".into()),
            output: Some("ok".into()),
        });
        thread.apply(ThreadEvent::ToolCallUpdated {
            tool_call_id: "missing".into(),
            title: Some("ignored".into()),
            status: Some("failed".into()),
            output: None,
        });
        assert_eq!(thread.entries.len(), 2);
        let Entry::ToolCall {
            title,
            status,
            output,
            args,
            ..
        } = &thread.entries[1]
        else {
            panic!("tool entry");
        };
        assert_eq!(title, "Write done");
        assert_eq!(status, "completed");
        assert_eq!(output.as_deref(), Some("ok"));
        assert!(args.is_none());
        let Entry::ToolCall {
            status: first_status,
            ..
        } = &thread.entries[0]
        else {
            panic!("tool entry");
        };
        assert_eq!(first_status, "pending");
    }

    fn native_permission_options() -> Vec<super::PermissionOption> {
        use super::{PermissionOption, PermissionOptionKind};
        vec![
            PermissionOption {
                id: "allow_once".into(),
                label: "允许一次".into(),
                kind: PermissionOptionKind::AllowOnce,
            },
            PermissionOption {
                id: "allow_session".into(),
                label: "本会话允许".into(),
                kind: PermissionOptionKind::AllowAlways,
            },
            PermissionOption {
                id: "allow_pattern:ls".into(),
                label: "本会话允许 ls 前缀".into(),
                kind: PermissionOptionKind::AllowAlways,
            },
            PermissionOption {
                id: "deny".into(),
                label: "拒绝".into(),
                kind: PermissionOptionKind::RejectOnce,
            },
        ]
    }

    /// 3.2：审批请求必须把 ACP 形状的 options（id/label/kind，顺序保持）带进
    /// 共享模型（pending + 历史 Entry），两轨 UI 才能共用同一张权限卡。
    #[test]
    fn permission_request_carries_options_into_pending_and_entry() {
        let mut thread = started_thread();
        let options = native_permission_options();
        thread.apply(ThreadEvent::PermissionRequested {
            request_id: "p1".into(),
            title: "允许运行 run_command？".into(),
            tool: Some("run_command".into()),
            tool_call_id: Some("c1".into()),
            args: Some("{\"command\":\"ls\"}".into()),
            options: options.clone(),
        });

        let pending = thread.pending_permission.as_ref().expect("pending");
        assert_eq!(pending.request_id, "p1");
        assert_eq!(pending.tool.as_deref(), Some("run_command"));
        assert_eq!(pending.options, options, "options 顺序与内容原样保留");
        assert!(pending.options[0].kind.is_allow());
        assert!(pending.options[1].kind.is_allow());
        assert!(pending.options[3].kind.is_reject());
        assert!(!pending.options[3].kind.is_allow());

        let Entry::Permission {
            options: entry_options,
            tool,
            resolved,
            ..
        } = &thread.entries[0]
        else {
            panic!("permission entry");
        };
        assert_eq!(entry_options, &options);
        assert_eq!(tool.as_deref(), Some("run_command"));
        assert_eq!(*resolved, None);

        // resolve 之后 options 仍在历史行里（复盘/审计用）。
        thread.apply(ThreadEvent::PermissionResolved {
            request_id: "p1".into(),
            allowed: true,
        });
        let Entry::Permission {
            options: entry_options,
            resolved,
            ..
        } = &thread.entries[0]
        else {
            panic!("permission entry");
        };
        assert_eq!(entry_options, &options);
        assert_eq!(*resolved, Some(true));
    }

    #[test]
    fn permission_request_blocks_and_resolution_clears_pending() {
        let mut thread = started_thread();
        thread.apply(ThreadEvent::TurnStarted {
            user_text: "q".into(),
        });
        thread.apply(ThreadEvent::PermissionRequested {
            request_id: "p1".into(),
            title: "approve".into(),
            tool: Some("run_command".into()),
            tool_call_id: Some("c1".into()),
            args: Some("{}".into()),
            options: native_permission_options(),
        });
        assert_eq!(thread.status, ThreadStatus::AwaitingApproval);
        assert!(thread.is_generating());
        assert!(thread.pending_permission.is_some());
        thread.apply(ThreadEvent::PermissionResolved {
            request_id: "p1".into(),
            allowed: false,
        });
        assert_eq!(thread.status, ThreadStatus::Generating);
        assert!(thread.pending_permission.is_none());
        let Entry::Permission { resolved, .. } = &thread.entries[1] else {
            panic!("permission entry");
        };
        assert_eq!(*resolved, Some(false));
    }

    #[test]
    fn finished_and_failed_turns_set_status_and_collapse_thinking() {
        let mut thread = started_thread();
        thread.apply(ThreadEvent::TurnStarted {
            user_text: "q".into(),
        });
        thread.apply(ThreadEvent::ThinkingDelta("hmm".into()));
        thread.apply(ThreadEvent::TurnFinished { cancelled: true });
        assert_eq!(thread.status, ThreadStatus::Idle);
        let Entry::Thinking { expanded, .. } = &thread.entries[1] else {
            panic!("thinking");
        };
        assert!(!expanded);

        thread.apply(ThreadEvent::Failed("boom".into()));
        assert_eq!(thread.status, ThreadStatus::Failed);
        let Entry::Notice { level, text } = thread.entries.last().expect("notice") else {
            panic!("notice entry");
        };
        assert_eq!(*level, NoticeLevel::Error);
        assert_eq!(text, "boom");
    }

    #[test]
    fn loaded_replaces_entries_and_capabilities() {
        let mut thread = started_thread();
        thread.apply(ThreadEvent::Loaded {
            entries: vec![Entry::User { text: "old".into() }],
            capabilities: ThreadCapabilities::native(),
            usage: super::Usage {
                used: 10,
                size: 100,
                cost: Some("$0.01".into()),
            },
        });
        assert_eq!(thread.entries.len(), 1);
        assert!(thread.capabilities.checkpoint_restore);
        assert_eq!(thread.usage.percent(), Some(10));
        assert_eq!(thread.status, ThreadStatus::Idle);
    }

    #[test]
    fn row_view_reuses_message_flow_turn_rules() {
        let mut thread = started_thread();
        thread.apply(ThreadEvent::TurnStarted {
            user_text: "q1".into(),
        });
        thread.apply(ThreadEvent::TextDelta("a1".into()));
        thread.apply(ThreadEvent::TurnStarted {
            user_text: "q2".into(),
        });
        thread.apply(ThreadEvent::TextDelta("a2".into()));
        let view = thread.row_view();
        assert_eq!(view.finalized_turn_end(1), Some(true));
        assert_eq!(view.turn_copy_text(1).as_deref(), Some("a1"));
        assert_eq!(
            view.action_plan(3, false, false).map(|p| p.scroll_to_user),
            Some(Some(2))
        );
    }

    #[test]
    fn duplicate_permission_requests_are_deduped() {
        let mut thread = started_thread();
        thread.apply(ThreadEvent::PermissionRequested {
            request_id: "p1".into(),
            title: "允许运行 run_command？".into(),
            tool: Some("run_command".into()),
            tool_call_id: Some("c1".into()),
            args: None,
            options: native_permission_options(),
        });
        thread.apply(ThreadEvent::PermissionRequested {
            request_id: "p2".into(),
            title: "允许运行 run_command？".into(),
            tool: Some("run_command".into()),
            tool_call_id: Some("c1".into()),
            args: None,
            options: native_permission_options(),
        });
        assert_eq!(thread.entries.len(), 1, "同一次审批只保留一行");
        assert_eq!(thread.status, ThreadStatus::AwaitingApproval);
        thread.apply(ThreadEvent::PermissionResolved {
            request_id: "p1".into(),
            allowed: true,
        });
        // 解决后再次重复请求（不同轮）仍允许新增一行。
        thread.apply(ThreadEvent::PermissionRequested {
            request_id: "p3".into(),
            title: "允许运行 run_command？".into(),
            tool: Some("run_command".into()),
            tool_call_id: Some("c1".into()),
            args: None,
            options: native_permission_options(),
        });
        assert_eq!(thread.entries.len(), 2);
    }

    #[test]
    fn capability_accessors_follow_track() {
        let native = super::ThreadCapabilities::native();
        assert!(native.checkpoint_available());
        assert!(native.steer_available());
        assert!(native.queue_available());
        assert!(native.subagent_available());
        assert!(native.plan_available());
        assert!(native.usage_available());
        assert!(native.config_available());

        let acp = super::ThreadCapabilities::acp();
        assert!(!acp.checkpoint_available());
        assert!(!acp.steer_available());
        assert!(!acp.queue_available());
        assert!(!acp.subagent_available());
        assert!(acp.plan_available());
        assert!(acp.usage_available());
        assert!(acp.config_available());
    }
}
