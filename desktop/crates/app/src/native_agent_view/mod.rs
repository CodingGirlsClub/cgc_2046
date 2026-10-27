//! Native agent 的 GPUI 面板（P1a UI 接入）。
//!
//! 通过 `CGC_NATIVE_AGENT_DEMO=1` 打开独立窗口，不影响现有 ACP 对话路径。
//!
//! Stage 3.1 Phase A：native 运行时由进程内 ACP server 包装，面板经 `AcpHost`
//! （与外部 ACP agent 完全相同的客户端路径）消费 `HostEvent` 并归约到共享
//! `ConversationThread`；native 专属能力（附件 / queue / steer / checkpoint /
//! 模型选择）仍留在本视图与 native 运行时，不经 ACP。

use std::collections::HashMap;
use std::sync::Arc;

use base64::Engine as _;
use cgc_agent_checkpoint::{Checkpoint, FileChange};
use cgc_agent_host::{parse_slash, NativeAcpServer, NativeAcpServerConfig, SlashCommand};
use cgc_agent_tools::ItemStatus;
use cgc_platform::acp::connection::{AcpHost, AcpHostConfig, HostEvent};
use futures::StreamExt as _;
use gpui_kit::component::button::{Button, ButtonVariants};
use gpui_kit::component::hover_card::HoverCard;
use gpui_kit::component::input::{InputEvent, Position, Textarea, TextareaState};
use gpui_kit::component::menu::{ContextMenuExt as _, PopupMenu};
use gpui_kit::component::message_scroller::{MessageScroller, MessageScrollerState};
use gpui_kit::component::popover::Popover;
use gpui_kit::component::{Icon, Sizable};
use gpui_kit::InteractiveElement as _;
use gpui_kit::StatefulInteractiveElement as _;
use gpui_kit::*;

use crate::attachment::{decode_sent_images, is_image_path, prepare_clipboard_image, SentImage};
use crate::conversation_session::{ConnectionPhase, QueueMode};
use crate::mention::{self, Mention, SkillEntry};
use crate::native_context::{
    collect_workspace_files, humanize_tokens, mention_matches, retry_hint_for_error,
    slash_entries_for, trailing_mention, SlashEntry,
};
use crate::native_panel_host::SubagentCard;
use crate::native_runtime::{
    ApprovalMode, CheckpointAction, NativeRuntimeEvent, NativeRuntimeHandle, NativeRuntimeSnapshot,
    PreparedNativeTurn, RuntimeChange, RuntimePhase,
};
use crate::native_view_model::{
    build_message_row_kinds, needs_checkpoint_confirm, subagent_cards_for_rows,
    thread_entry_ordinal, trim_entries_to_last_user, MessageRowKind, ViewRole, ViewRow, ViewTool,
    ViewToolStatus,
};
use crate::theme::{self, space, RADIUS_MEDIUM, RADIUS_SMALL};
use cgc_agent_ui::command_menu::{
    render_command_menu, CommandMenuItem, CommandMenuSpec, CommandMenuStyle,
};
use cgc_agent_ui::conversation::Entry as ConversationEntry;
use cgc_agent_ui::markdown_text::markdown_to_plain;
use cgc_agent_ui::message_actions::{
    render_action_bar, render_message_menu, ActionBarSpec, ActionCallbacks, ActionGlyph,
    ActionGlyphs, ActionStyle, MenuPayloads,
};
use cgc_agent_ui::message_flow;
use cgc_agent_ui::permission_card::{
    render_permission_card, PermissionCardModel, PermissionCardSpec, PermissionSelectCallback,
};

use cgc_agent_ui::message_row::{
    render_assistant_row, render_error_row as shared_render_error_row, render_status_row,
    render_thinking_row, render_tool_row, render_user_edit_row as shared_render_user_edit_row,
    render_user_row, user_edit_confirm_visible, AssistantRowSpec, ErrorRowSpec, MessageStyle,
    RowPalette, StatusRowSpec, ThinkingRowSpec, ToolRowSpec, UserEditRowSpec, UserRowSpec,
};
use cgc_agent_ui::picker::{
    render_picker_popover, PickerGroup, PickerItem, PickerPopoverSpec, PickerStyle,
};

/// 待发送的图片附件（剪贴板或文件）。
struct PendingImage {
    name: String,
    mime: String,
    data: String,
    preview: Option<Arc<RenderImage>>,
}

/// B3a：native composer 三个 picker 的渲染产物（capability 不可用时为空）。
#[derive(Default)]
struct NativeComposerPickers {
    model: Option<AnyElement>,
    thinking: Option<AnyElement>,
    approval: Option<AnyElement>,
}

/// picker 的 capability gating（native-only；ACP 轨用自己的 config options picker）。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct NativeComposerGating {
    config_options: bool,
    /// native 轨道标记：ACP 无 checkpoint 能力，用它区分两轨（后续如加显式
    /// track 能力位可替换）。
    native_only: bool,
}

impl NativeComposerGating {
    fn from_capabilities(capabilities: cgc_agent_ui::conversation::ThreadCapabilities) -> Self {
        Self {
            config_options: capabilities.config_available(),
            native_only: capabilities.checkpoint_available(),
        }
    }

    fn pickers_available(&self) -> bool {
        self.config_options && self.native_only
    }
}

/// B3b：checkpoint 面板显隐（capability + 手动开关 + 有变更）。
fn checkpoint_panel_visible(
    checkpoint_available: bool,
    show_panel: bool,
    change_count: usize,
) -> bool {
    checkpoint_available && show_panel && change_count > 0
}

/// B3b：单条变更的展示文案（`M path`），fake checkpoint 单测覆盖。
fn checkpoint_change_label(change: &FileChange) -> String {
    format!("{} {}", change.status, change.path)
}

/// composer 渲染的前置值快照（B2b-3a：纯搬迁第一步，收敛 render 里的局部变量）。
struct ComposerDraft {
    busy: bool,
    has_input: bool,
    usage: u64,
    model_supports_images: bool,
    input: Entity<TextareaState>,
    input_focus: gpui_kit::FocusHandle,
    input_value: String,
}

fn composer_has_input(value: &str) -> bool {
    !value.trim().is_empty()
}

/// queue 提示面板标题（composer 侧）：纯函数，legacy/shared composer 共用。
fn queued_panel_header_text(count: usize) -> String {
    format!("排队中 {count} 条 · 当前 turn 结束后自动发送")
}

impl NativeAgentView {
    fn composer_draft(&self, cx: &mut Context<Self>) -> ComposerDraft {
        let input_value = self.input.read(cx).value().to_string();
        ComposerDraft {
            busy: self.is_generating(),
            has_input: composer_has_input(&input_value),
            usage: self.state.usage_total.total(),
            model_supports_images: self.model_supports_images(),
            input: self.input.clone(),
            input_focus: self.input.read(cx).focus_handle(cx).clone(),
            input_value,
        }
    }
}

fn inserted_segment(previous: &str, current: &str) -> Option<String> {
    if current.len() <= previous.len() {
        return None;
    }
    let a = previous.as_bytes();
    let b = current.as_bytes();
    let mut prefix = 0;
    while prefix < a.len() && prefix < b.len() && a[prefix] == b[prefix] {
        prefix += 1;
    }
    let mut suffix = 0;
    while suffix < a.len().saturating_sub(prefix)
        && suffix < b.len().saturating_sub(prefix)
        && a[a.len() - 1 - suffix] == b[b.len() - 1 - suffix]
    {
        suffix += 1;
    }
    String::from_utf8(b[prefix..b.len() - suffix].to_vec()).ok()
}

/// 把 thread entries 映射成 UI 状态：图片预览 + 工具调用参数/输出（工具卡片）。
fn apply_thread_entries(
    thread: &mut cgc_agent_ui::conversation::ConversationThread,
    entries: &[cgc_agent_core::Entry],
) -> HashMap<usize, Vec<SentImage>> {
    let mut restored_images: HashMap<usize, Vec<SentImage>> = HashMap::new();
    let mut tool_args: HashMap<String, (String, serde_json::Value)> = HashMap::new();
    for entry in entries {
        if let cgc_agent_core::Entry::Assistant { tool_calls, .. } = entry {
            for call in tool_calls {
                tool_args.insert(call.id.clone(), (call.name.clone(), call.args.clone()));
            }
        }
    }
    thread.entries.clear();
    for entry in entries {
        match entry {
            cgc_agent_core::Entry::User {
                text,
                images,
                display,
                ..
            } => {
                let index = thread.entries.len();
                thread.entries.push(ConversationEntry::User {
                    text: display.clone().unwrap_or_else(|| text.clone()),
                });
                let previews = decode_sent_images(images);
                if !previews.is_empty() {
                    restored_images.insert(index, previews);
                }
            }
            cgc_agent_core::Entry::Assistant { text, .. } if !text.is_empty() => thread
                .entries
                .push(ConversationEntry::Assistant { text: text.clone() }),
            cgc_agent_core::Entry::Thinking { text, .. } => {
                thread.entries.push(ConversationEntry::Thinking {
                    text: text.clone(),
                    expanded: false,
                })
            }
            cgc_agent_core::Entry::ToolResult {
                tool_use_id,
                tool_name,
                content,
                is_error,
                ..
            } => {
                let (name, args) = tool_args
                    .get(tool_use_id)
                    .cloned()
                    .unwrap_or_else(|| (tool_name.clone(), serde_json::Value::Null));
                thread.entries.push(ConversationEntry::ToolCall {
                    tool_call_id: tool_use_id.clone(),
                    title: tool_name.clone(),
                    name: Some(name),
                    kind: "tool".to_string(),
                    status: if *is_error { "failed" } else { "completed" }.to_string(),
                    args: (!args.is_null()).then(|| args.to_string()),
                    output: Some(content.clone()),
                    locations: Vec::new(),
                    expanded: false,
                });
            }
            cgc_agent_core::Entry::Compaction { summary, .. } => {
                thread.entries.push(ConversationEntry::Compaction {
                    status: "completed".to_string(),
                    summary: Some(summary.clone()),
                })
            }
            _ => {}
        }
    }
    restored_images
}

mod composer;
mod input;
mod panel;
mod panels;
mod render;
mod rows;
mod runtime_ops;
mod session;
mod state;
mod turn;
mod view_ops;
mod widgets;

pub use state::NativeThreadState;
pub(crate) use widgets::*;

pub struct NativeAgentView {
    runtime: NativeRuntimeHandle,
    snapshot: Option<Arc<NativeRuntimeSnapshot>>,
    page_context: crate::page_context::PageContextState,
    input: Entity<TextareaState>,
    state: NativeThreadState,
    status: String,
    show_checkpoint_panel: bool,
    /// 无可用 checkpoint 时，编辑重发需要二次确认的消息 index。
    pending_restart_confirm: Option<usize>,
    slash_index: usize,
    slash_dismissed: bool,
    mention_index: usize,
    workspace_files: Vec<String>,
    skills: Vec<SkillEntry>,
    /// 最近一轮的 prompt / 展示文本，供失败后重试重放。
    last_turn: Option<(String, String)>,
    /// 已展开的工具调用卡片 id。
    expanded_tools: std::collections::HashSet<String>,
    /// 已展开的思考折叠块（UI message index）。
    expanded_thinking: std::collections::HashSet<usize>,
    /// 正在编辑的用户消息（UI message index）。
    editing_user: Option<usize>,
    /// 编辑态输入框；仅在 editing_user 有值时存在。
    user_edit_input: Option<Entity<TextareaState>>,
    /// 虚拟消息列表状态：只渲染可见行，并负责 tail 跟随/滚动条/回到最新按钮。
    message_scroller: Entity<MessageScrollerState>,
    /// 每行的高度签名；与下一帧比对，只 remeasure 变化的那一行。
    message_row_signatures: Vec<u64>,
    pending_images: Vec<PendingImage>,
    /// 已发送用户消息 index → 图片预览（仅当前进程内显示，不持久化）。
    sent_images: HashMap<usize, Vec<SentImage>>,
    last_input_value: String,
    _input_subscription: Option<Subscription>,
    _key_interceptor: Option<Subscription>,
}

/// 每个 workspace scope 一条 native 线程（ADR-0028）。
#[cfg(test)]
mod tests;
