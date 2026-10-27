//! Native agent 的 GPUI 面板（P1a UI 接入）。
//!
//! 通过 `CGC_NATIVE_AGENT_DEMO=1` 打开独立窗口，不影响现有 ACP 对话路径。
//!
//! Stage 3.1 Phase A：native 运行时由进程内 ACP server 包装，面板经 `AcpHost`
//! （与外部 ACP agent 完全相同的客户端路径）消费 `HostEvent` 并归约到共享
//! `ConversationThread`；native 专属能力（附件 / queue / steer / checkpoint /
//! 模型选择）仍留在本视图与 native 运行时，不经 ACP。

use std::collections::HashMap;
use std::sync::{mpsc as std_mpsc, Arc, Mutex};

use base64::Engine as _;
use cgc_agent_checkpoint::{Checkpoint, CheckpointManager, FileChange};
use cgc_agent_core::{run_subagent, Agent, CancelToken, SelectedModel, Thread};
use cgc_agent_host::{
    parse_slash, AgentEvent, ContextSizeHandle, NativeAcpServer, NativeAcpServerConfig,
    SlashCommand,
};
use cgc_agent_provider::{
    CompletionEvent, EchoProvider, Message as ProviderMessage, Model, ModelLimits,
    OpenAiCompatibleConfig, OpenAiCompatibleProvider, Provider, ProviderId,
    Request as ProviderRequest,
};
use cgc_agent_store::{
    provider_key_account, ActionAuditEntry, AuditLog, PrefsStore, ProviderPrefs,
};
use cgc_agent_tools::{
    ActionSink, AgentState, AppAction, ItemStatus, SandboxPolicy, SharedAgentState, SubagentEvent,
    SubagentEventSink, SubagentRequest, SubagentRunner, ToolContext, ToolRegistry,
};
use cgc_platform::acp::connection::{AcpHost, AcpHostConfig, HostEvent};
use cgc_platform::paths::AppPaths;
use cgc_platform::session::KeychainStore;
use futures::channel::mpsc;
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

use crate::agent_ingest;
use crate::attachment::{decode_sent_images, is_image_path, prepare_clipboard_image, SentImage};
use crate::mention::{self, Mention, SkillEntry};
use crate::native_context::{
    build_workspace_system_prompt, clean_thread_title, collect_workspace_files, humanize_tokens,
    mention_matches, now_secs, offline_echo_notice, retry_hint_for_error, slash_entries_for,
    trailing_mention, truncate_text, SlashEntry,
};
use crate::native_panel_host::SubagentCard;
use crate::native_runtime::{NativeRuntimeConfig, NativeRuntimeHandle};
use crate::native_session::NativeSessionStore;
use crate::native_thread_state::NativeThreadState;
use crate::native_view_model::{
    build_message_row_kinds, checkpoint_for_ordinal, checkpoints_from_records,
    needs_checkpoint_confirm, subagent_cards_for_rows, thread_entry_ordinal,
    thread_user_entry_index, trim_entries_to_last_user, MessageRowKind, ViewRole, ViewRow,
    ViewTool, ViewToolStatus,
};
use crate::theme::{self, space, RADIUS_MEDIUM, RADIUS_SMALL};
use cgc_agent_ui::command_menu::{
    render_command_menu, CommandMenuItem, CommandMenuSpec, CommandMenuStyle,
};
use cgc_agent_ui::conversation::{Entry as ConversationEntry, ThreadEvent, Usage};
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

/// 审批模式：Ask = 逐次审批；Auto = 自动允许。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ApprovalMode {
    Ask,
    Auto,
}

impl ApprovalMode {
    fn label(self) -> &'static str {
        match self {
            Self::Ask => "Ask",
            Self::Auto => "Auto",
        }
    }
}

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

/// B3b：Keep 单个文件 = 从变更列表移除该路径。
fn keep_change_by_path(changes: &mut Vec<FileChange>, path: &str) {
    changes.retain(|change| change.path != path);
}

/// B3b：Reject all = 按变更列表顺序收集待回退路径。
fn paths_for_restore_all(changes: &[FileChange]) -> Vec<String> {
    changes.iter().map(|change| change.path.clone()).collect()
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

/// queue 状态文案（发送侧）：纯函数，legacy/shared composer 共用。
fn queued_status_text(count: usize) -> String {
    format!("已排队 {count} 条，当前 turn 结束后依次发送")
}

/// queue 提示面板标题（composer 侧）：纯函数，legacy/shared composer 共用。
fn queued_panel_header_text(count: usize) -> String {
    format!("排队中 {count} 条 · 当前 turn 结束后自动发送")
}

impl NativeAgentView {
    fn composer_draft(&self, cx: &mut Context<Self>) -> ComposerDraft {
        let input_value = self.input.read(cx).value().to_string();
        ComposerDraft {
            busy: self.busy,
            has_input: composer_has_input(&input_value),
            usage: self.state.usage_total.total(),
            model_supports_images: self.model_supports_images(),
            input: self.input.clone(),
            input_focus: self.input.read(cx).focus_handle(cx).clone(),
            input_value,
        }
    }
}

/// 排队等待发送的消息：`display` 用于界面展示，`prompt` 已解析好技能/文件上下文。
#[derive(Clone)]
struct QueuedMessage {
    display: String,
    prompt: String,
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
    state: &mut NativeThreadState,
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
    state.thread.entries.clear();
    for entry in entries {
        match entry {
            cgc_agent_core::Entry::User {
                text,
                images,
                display,
                ..
            } => {
                let index = state.thread.entries.len();
                state.thread.entries.push(ConversationEntry::User {
                    text: display.clone().unwrap_or_else(|| text.clone()),
                });
                let previews = decode_sent_images(images);
                if !previews.is_empty() {
                    restored_images.insert(index, previews);
                }
            }
            cgc_agent_core::Entry::Assistant { text, .. } if !text.is_empty() => state
                .thread
                .entries
                .push(ConversationEntry::Assistant { text: text.clone() }),
            cgc_agent_core::Entry::Thinking { text, .. } => {
                state.thread.entries.push(ConversationEntry::Thinking {
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
                state.thread.entries.push(ConversationEntry::ToolCall {
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
                state.thread.entries.push(ConversationEntry::Compaction {
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
mod panels;
mod render;
mod rows;
mod runtime_ops;
mod session;
mod turn;

pub struct NativeAgentView {
    agent: Option<Agent>,
    provider: Arc<dyn Provider>,
    model: Model,
    registry: Arc<ToolRegistry>,
    host: crate::native_panel_host::NativePanelHost,
    app_actions: Arc<Mutex<Vec<AppAction>>>,
    subagent_tx: Arc<Mutex<Option<mpsc::UnboundedSender<AgentEvent>>>>,
    context: ToolContext,
    input: Entity<TextareaState>,
    cancel: CancelToken,
    state: NativeThreadState,
    /// native ACP server 的上下文窗口句柄（usage_update.size 用）。
    acp_context_size: Option<ContextSizeHandle>,
    /// turn 期间 Agent 交给它的运行时句柄（turn 结束后取回）。
    runtime: NativeRuntimeHandle,
    /// ACP 事件轮询世代号；换连接时递增，旧轮询自动退出。
    acp_poller_generation: u64,
    acp_poller_running: bool,
    /// 子 agent 辅助事件泵是否已启动。
    subagent_pump_started: bool,
    /// turn 结束后等 runtime 把 Agent 交回（cancel 宽限期内的竞态）。
    awaiting_agent: bool,
    pending_turn_end: Option<TurnEndState>,
    /// 当前工作区 scope（ADR-0028：课程页/助手页各一个工作区）。
    scope: crate::agent_scope::AgentScope,
    status: String,
    busy: bool,
    session_store: NativeSessionStore,
    checkpoint_manager: Option<CheckpointManager>,
    last_checkpoint: Option<Checkpoint>,
    /// 当前线程持久化的 checkpoint（user 消息 ordinal → checkpoint）。
    available_checkpoints: Vec<(usize, Checkpoint)>,
    checkpoint_changes: Vec<FileChange>,
    show_checkpoint_panel: bool,
    /// checkpoint 不可用/失败是否已经给过一次可见提示。
    checkpoint_notice_reported: bool,
    /// 无可用 checkpoint 时，编辑重发需要二次确认的消息 index。
    pending_restart_confirm: Option<usize>,
    providers: Vec<ProviderPrefs>,
    /// 当前 provider 是否为 Echo 回退（没有可用的 base URL / API Key）。
    using_echo: bool,
    keychain: Option<KeychainStore>,
    effort_index: usize,
    thinking_enabled: bool,
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
    approval_mode: ApprovalMode,
    pending_images: Vec<PendingImage>,
    /// 已发送用户消息 index → 图片预览（仅当前进程内显示，不持久化）。
    sent_images: HashMap<usize, Vec<SentImage>>,
    last_input_value: String,
    queued_messages: Vec<QueuedMessage>,
    steer_sender: std_mpsc::Sender<String>,
    _input_subscription: Option<Subscription>,
    _key_interceptor: Option<Subscription>,
}

/// turn 收尾原因（来自 ACP TurnEnd / Error / Exited 事件）。
enum TurnEndState {
    Completed,
    Cancelled,
    Failed(String),
}

impl NativeAgentView {
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        Self::new_inner(window, cx, None)
    }

    /// B4a-3b-2：controller 经 host 接线（注入 agent_state/audit）。
    pub(crate) fn new_with_host(
        window: &mut Window,
        cx: &mut Context<Self>,
        host: crate::native_panel_host::NativePanelHost,
    ) -> Self {
        Self::new_inner(window, cx, Some(host))
    }

    fn new_inner(
        window: &mut Window,
        cx: &mut Context<Self>,
        host_override: Option<crate::native_panel_host::NativePanelHost>,
    ) -> Self {
        let injected_host = host_override.is_some();
        let paths = cgc_platform::paths::AppPaths::from_env();
        let prefs = PrefsStore::new(paths.agent_prefs_file()).load();
        let active = prefs.active_provider();
        let env_model = std::env::var("CGC_AGENT_MODEL")
            .ok()
            .filter(|model| !model.is_empty());
        let env_base_url = std::env::var("CGC_AGENT_BASE_URL")
            .ok()
            .filter(|base_url| !base_url.is_empty());
        let env_api_key = std::env::var("CGC_AGENT_API_KEY")
            .ok()
            .filter(|api_key| !api_key.is_empty());
        let keychain = Some(KeychainStore::from_env());
        let provider_id = active
            .map(|provider| provider.id.clone())
            .filter(|id| !id.is_empty())
            .unwrap_or_else(|| "custom".to_string());
        let base_url = env_base_url.or_else(|| active.map(|provider| provider.base_url.clone()));
        let api_key = env_api_key.or_else(|| {
            active.and_then(|provider| {
                keychain
                    .as_ref()
                    .and_then(|keychain| keychain.load_secret(&provider_key_account(&provider.id)))
            })
        });
        let model_id = env_model
            .or_else(|| {
                prefs
                    .selected_model
                    .as_ref()
                    .map(|selected| selected.model_id.as_str().to_string())
            })
            .or_else(|| active.and_then(|provider| provider.primary_model().map(str::to_string)))
            .unwrap_or_else(|| "echo".to_string());
        let provider_name = std::env::var("CGC_AGENT_PROVIDER_NAME")
            .ok()
            .or_else(|| active.map(|provider| provider.name.clone()))
            .filter(|name| !name.is_empty())
            .unwrap_or_else(|| "OpenAI Compatible".to_string());
        let model_id = match active {
            Some(provider) if !provider.model_config(&model_id).enabled => provider
                .models
                .iter()
                .find(|id| provider.model_config(id).enabled)
                .cloned()
                .unwrap_or(model_id),
            _ => model_id,
        };
        let model_config = active
            .map(|provider| provider.model_config(&model_id))
            .unwrap_or_default();
        let model = Model::new(
            ProviderId::new(provider_id),
            provider_name,
            model_id.clone(),
            model_id,
            ModelLimits::new(model_config.context_window, model_config.max_output_tokens),
        );
        let using_echo = !matches!(
            (&base_url, &api_key),
            (Some(base_url), Some(api_key)) if !base_url.is_empty() && !api_key.is_empty()
        );
        let provider: Arc<dyn Provider> = match (&base_url, &api_key) {
            (Some(base_url), Some(api_key)) if !base_url.is_empty() && !api_key.is_empty() => {
                Arc::new(OpenAiCompatibleProvider::new(OpenAiCompatibleConfig::new(
                    base_url.clone(),
                    api_key.clone(),
                    vec![model.clone()],
                )))
            }
            _ => Arc::new(EchoProvider::new(model.clone())),
        };
        let selected = SelectedModel::new(model.provider_id.clone(), model.id.clone());
        let providers = prefs.providers.clone();
        let session_store = NativeSessionStore::open(&paths.data_root);
        // 全局 assistant scope（CGC_AGENT_WORKSPACE 优先）；所有页面共用一条线程。
        let scope =
            crate::agent_scope::current().unwrap_or_else(|| crate::agent_scope::resolve(None));
        let thread_id = scope_thread_id(&scope);
        let workspace = scope.root.clone();
        let _ = std::fs::create_dir_all(&workspace);
        let restored_thread = session_store
            .load_thread(&thread_id)
            .filter(|thread| thread.model == selected);
        let mut state = NativeThreadState::new();
        let mut restored_images: HashMap<usize, Vec<SentImage>> = HashMap::new();
        let thread = match restored_thread {
            Some(thread) => {
                restored_images = apply_thread_entries(&mut state, &thread.entries);
                state.usage_total = thread.usage_total;
                thread
            }
            None => {
                if let Some(notice) = offline_echo_notice(using_echo) {
                    state.push_notice(notice);
                }
                Thread::new(thread_id.clone(), selected)
            }
        };
        state.set_context_size(model_config.context_window as u64);
        state.thread.thread_id = thread_id.clone();
        state.thread.usage = Usage {
            used: state.usage_total.total(),
            size: model_config.context_window as u64,
            cost: None,
        };
        let restored = !state.thread.entries.is_empty();
        let system_prompt = build_workspace_system_prompt(&workspace);
        let agent = Agent::new(thread, Some(system_prompt));
        let cancel = agent.cancel_token();
        let steer_sender = agent.steer_sender();
        let (agent_state, mut host): (SharedAgentState, _) = match host_override {
            Some(host) => (host.agent_state.clone(), host),
            None => {
                let state: SharedAgentState = Arc::new(Mutex::new(AgentState::default()));
                let mut host = crate::native_panel_host::NativePanelHost::new(state.clone());
                // 3.4c：默认入口也解析 MCP 注入（env 优先；lease 由 controller 接线补）。
                host.set_mcp_lease(
                    None,
                    std::env::var("CGC_API_URL").ok().as_deref(),
                    std::env::var("CGC_WORKSPACE_ID").ok().as_deref(),
                );
                (state, host)
            }
        };
        debug_assert!(host.has_agent_state());
        if !injected_host {
            host.set_action_audit(Some(AuditLog::new(paths.agent_audit_file())));
        }
        let app_actions: Arc<Mutex<Vec<AppAction>>> = Arc::new(Mutex::new(Vec::new()));
        let action_sink: ActionSink = {
            let app_actions = app_actions.clone();
            Arc::new(move |action: AppAction| {
                if let Ok(mut actions) = app_actions.lock() {
                    actions.push(action);
                }
            })
        };
        let checkpoint_manager = CheckpointManager::open(&workspace)
            .or_else(|_| CheckpointManager::initialize(&workspace))
            .ok();
        let subagent_tx: Arc<Mutex<Option<mpsc::UnboundedSender<AgentEvent>>>> =
            Arc::new(Mutex::new(None));
        let subagent_sink: SubagentEventSink = {
            let subagent_tx = subagent_tx.clone();
            Arc::new(move |event: SubagentEvent| {
                let agent_event = match event {
                    SubagentEvent::Started { task } => AgentEvent::SubagentStarted { task },
                    SubagentEvent::TextDelta { text } => AgentEvent::SubagentProgress { text },
                    SubagentEvent::Finished { ok } => AgentEvent::SubagentFinished { ok },
                };
                if let Ok(slot) = subagent_tx.lock() {
                    if let Some(sender) = slot.as_ref() {
                        let _ = sender.unbounded_send(agent_event);
                    }
                }
            })
        };
        let subagent_runner: SubagentRunner = {
            let provider = provider.clone();
            let model = model.clone();
            let workspace = workspace.clone();
            Arc::new(move |request: SubagentRequest, events: SubagentEventSink| {
                let provider = provider.clone();
                let model = model.clone();
                let workspace = workspace.clone();
                Box::pin(async move {
                    run_subagent(
                        provider,
                        model,
                        request.task,
                        request.system_prompt,
                        workspace,
                        events,
                    )
                    .await
                    .map_err(|error| error.to_string())
                })
            })
        };
        let workspace_files = collect_workspace_files(&workspace);
        let skills = mention::load_skills(&workspace);
        let input = cx.new(|cx| TextareaState::new(window, cx).auto_grow(4, 20));
        // Textarea 把 up/down 绑定成 MoveUp/MoveDown，在 action 阶段消费；
        // 用 keystroke interceptor 在 action dispatch 之前接管菜单导航。
        let interceptor_weak = cx.entity().downgrade();
        let key_interceptor = cx.intercept_keystrokes(move |event, window, cx| {
            let key = event.keystroke.key.as_str();
            if !matches!(key, "up" | "down" | "escape") {
                return;
            }
            let _ = interceptor_weak.update(cx, |this, cx| {
                let focused = this.input.read(cx).focus_handle(cx).is_focused(window);
                if !focused {
                    return;
                }
                let value = this.input.read(cx).value().to_string();
                if value.trim_start().starts_with('/') && !this.slash_dismissed {
                    match key {
                        "up" => this.slash_index = this.slash_index.saturating_sub(1),
                        "down" => this.slash_index += 1,
                        "escape" => this.slash_dismissed = true,
                        _ => {}
                    }
                    cx.stop_propagation();
                    cx.notify();
                    return;
                }
                if trailing_mention(&value).is_some() {
                    match key {
                        "up" => this.mention_index = this.mention_index.saturating_sub(1),
                        "down" => this.mention_index += 1,
                        _ => {}
                    }
                    cx.stop_propagation();
                    cx.notify();
                }
            });
        });
        let input_subscription = Some(cx.subscribe_in(
            &input,
            window,
            |this, state, event: &InputEvent, window, cx| {
                if let InputEvent::Change = event {
                    let value = this.input.read(cx).value().to_string();
                    if value != this.last_input_value {
                        let previous = this.last_input_value.clone();
                        this.last_input_value = value.clone();
                        if let Some(inserted) = inserted_segment(&previous, &value) {
                            let image_paths: Vec<std::path::PathBuf> = cx
                                .read_from_clipboard()
                                .map(|item| {
                                    item.entries
                                        .iter()
                                        .filter_map(|entry| match entry {
                                            ClipboardEntry::ExternalPaths(paths) => {
                                                Some(paths.paths().to_vec())
                                            }
                                            _ => None,
                                        })
                                        .flatten()
                                        .filter(|path| is_image_path(path))
                                        .collect()
                                })
                                .unwrap_or_default();
                            let inserted_matches_file = image_paths.iter().any(|path| {
                                path.file_name()
                                    .and_then(|name| name.to_str())
                                    .map(|name| inserted.contains(name))
                                    .unwrap_or(false)
                                    || inserted.contains(path.to_string_lossy().as_ref())
                            });
                            if inserted_matches_file {
                                this.add_images_from_paths(&image_paths, cx);
                                this.input.update(cx, |state, cx| {
                                    state.set_value(previous.clone(), window, cx)
                                });
                                this.last_input_value = previous;
                                cx.notify();
                                return;
                            }
                        }
                    }
                    this.slash_dismissed = false;
                    this.slash_index = 0;
                    this.mention_index = 0;
                    let _ = value;
                    cx.notify();
                    return;
                }
                if let InputEvent::PressEnter { secondary, shift } = event {
                    if *shift {
                        return;
                    }
                    let value = this.input.read(cx).value().to_string();
                    if let Some((token_start, query)) = trailing_mention(&value) {
                        let matches = this.mention_matches(&query);
                        if !matches.is_empty() {
                            let index = this.mention_index.min(matches.len() - 1);
                            let path = matches[index].clone();
                            let next = format!("{}@{} ", &value[..token_start], path);
                            this.input
                                .update(cx, |state, cx| state.set_value(next, window, cx));
                            this.mention_index = 0;
                            cx.notify();
                            return;
                        }
                    }
                    let entries = this.slash_entries(&value);
                    if value.trim_start().starts_with('/')
                        && !this.slash_dismissed
                        && !entries.is_empty()
                    {
                        let index = this.slash_index.min(entries.len() - 1);
                        this.run_slash_entry(entries, index, window, cx);
                        return;
                    }
                    if *secondary && this.busy && this.state.thread.capabilities.steer_available() {
                        // ⌘↩：生成中立即打断并发送。
                        this.steer(window, cx);
                    } else {
                        this.send(window, cx);
                    }
                    state.update(cx, |state, cx| state.set_value("", window, cx));
                    cx.notify();
                }
            },
        ));
        let mut registry = ToolRegistry::with_agent_state(agent_state.clone())
            .with_app_actions()
            .with_subagent(subagent_runner, subagent_sink);
        // 3.4c：native MCP 只读工具注入（无 lease/injection → 0 个，fail-closed）。
        let _mcp_tools =
            crate::native_panel_host::register_mcp_tools_for_host(&mut registry, &host);
        let mut view = Self {
            agent: Some(agent),
            provider,
            model,
            registry: Arc::new(registry),
            host,
            app_actions,
            subagent_tx,
            providers,
            using_echo,
            keychain,
            effort_index: 0,
            thinking_enabled: true,
            slash_index: 0,
            slash_dismissed: false,
            mention_index: 0,
            workspace_files,
            skills,
            last_turn: None,
            expanded_tools: std::collections::HashSet::new(),
            expanded_thinking: std::collections::HashSet::new(),
            editing_user: None,
            user_edit_input: None,
            message_scroller: cx.new(|cx| MessageScrollerState::new(0, cx)),
            message_row_signatures: Vec::new(),
            approval_mode: ApprovalMode::Ask,
            runtime: NativeRuntimeHandle::new(),
            acp_context_size: None,
            acp_poller_generation: 0,
            acp_poller_running: false,
            subagent_pump_started: false,
            awaiting_agent: false,
            pending_turn_end: None,
            context: ToolContext::new(&workspace)
                .with_sandbox(SandboxPolicy::new(&workspace))
                .with_action_sink(action_sink),
            input,
            cancel,
            state,
            scope,
            status: if restored {
                "已恢复上次会话".to_string()
            } else {
                "就绪".to_string()
            },
            busy: false,
            session_store,
            checkpoint_manager,
            last_checkpoint: None,
            available_checkpoints: Vec::new(),
            checkpoint_changes: Vec::new(),
            show_checkpoint_panel: false,
            checkpoint_notice_reported: false,
            pending_restart_confirm: None,
            queued_messages: Vec::new(),
            steer_sender,
            pending_images: Vec::new(),
            sent_images: restored_images,
            last_input_value: String::new(),
            _input_subscription: input_subscription,
            _key_interceptor: Some(key_interceptor),
        };
        view.reload_thread_checkpoints();
        view
    }

    fn handle_slash(&mut self, command: SlashCommand, cx: &mut Context<Self>) {
        match command {
            SlashCommand::Help => self
                .state
                .push_notice("命令：/help /clear /stop /tools /checkpoint /settings"),
            SlashCommand::Clear => {
                self.state.thread.entries.clear();
                self.state.thread.status = cgc_agent_ui::conversation::ThreadStatus::Idle;
                self.state.thread.pending_permission = None;
                self.sent_images.clear();
                self.state.last_error = None;
                self.status = "对话显示已清空".to_string();
            }
            SlashCommand::Stop => self.stop(cx),
            SlashCommand::Tools => {
                let tools = self
                    .registry
                    .schemas()
                    .iter()
                    .map(|schema| schema.name.clone())
                    .collect::<Vec<_>>()
                    .join(" / ");
                self.state.push_notice(format!("可用工具：{tools}"));
            }
            SlashCommand::Checkpoint => {
                if self.last_checkpoint.is_some() {
                    self.show_checkpoint_panel = true;
                    self.refresh_checkpoint_changes();
                } else {
                    self.state.push_notice("当前没有可用的 checkpoint");
                }
            }
            SlashCommand::Settings => {
                let mut opened = false;
                for window in cx.windows() {
                    if let Some(root) = window.downcast::<crate::root_view::RootView>() {
                        let _ = root.update(cx, |root, _window, cx| {
                            root.open_settings_window(cx);
                        });
                        opened = true;
                        break;
                    }
                }
                if !opened {
                    self.state.push_notice("请在账号菜单里打开设置");
                }
            }
            SlashCommand::Unknown(name) => self.state.push_notice(format!("未知命令：/{name}")),
        }
        cx.notify();
    }

    fn send(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let content = self.input.read(cx).content();
        let text = content.text().trim().to_string();
        if text.is_empty() {
            return;
        }
        self.input
            .update(cx, |state, cx| state.set_value("", window, cx));
        if let Some(command) = parse_slash(&text) {
            self.handle_slash(command, cx);
            return;
        }
        // 气泡保留原始 mention 链接（渲染时转 chip，编辑时可重建 token）；
        // 真正发给 agent 的 prompt 前置技能/文件上下文。
        let display = text.clone();
        let prompt = mention::resolve_prompt(&content, self.context.workspace());
        // Stage 3.5a：课程页上下文（course/revision/unit）对两轨同一段文本；
        // 用户 dismiss 后不带，换页/新会话恢复。
        let prompt = crate::page_context::attach_to_prompt(&prompt);
        if self.busy {
            self.queued_messages.push(QueuedMessage { display, prompt });
            self.status = queued_status_text(self.queued_messages.len());
            cx.notify();
            return;
        }
        self.send_prompt(prompt, display, cx);
    }

    fn model_supports_images(&self) -> bool {
        self.providers
            .iter()
            .find(|provider| provider.id == self.model.provider_id.as_str())
            .map(|provider| {
                provider
                    .model_config(self.model.id.as_str())
                    .supports_images
            })
            .unwrap_or(false)
    }

    fn add_clipboard_image(&mut self, cx: &mut Context<Self>) {
        self.refresh_provider_credentials(cx, false);
        if !self.model_supports_images() {
            self.status = "当前模型不支持图片输入".to_string();
            cx.notify();
            return;
        }
        let Some(item) = cx.read_from_clipboard() else {
            self.status = "读取剪贴板失败".to_string();
            cx.notify();
            return;
        };
        let Some(image) = item.entries.iter().find_map(|entry| match entry {
            ClipboardEntry::Image(image) => Some(image),
            _ => None,
        }) else {
            self.status = "剪贴板里没有图片".to_string();
            cx.notify();
            return;
        };
        let Some((png, preview)) = prepare_clipboard_image(&image.bytes) else {
            self.status = "图片无法处理（格式不支持或超过 5MB）".to_string();
            cx.notify();
            return;
        };
        let data = base64::engine::general_purpose::STANDARD.encode(&png);
        let index = self.pending_images.len() + 1;
        self.pending_images.push(PendingImage {
            name: format!("pasted-image-{index}.png"),
            mime: "image/png".to_string(),
            data,
            preview: Some(preview),
        });
        self.status = "已添加图片附件".to_string();
        cx.notify();
    }

    /// 对齐 Zed：＋ → Image 打开系统文件选择器（多选），再加载为附件。
    fn add_images_from_picker(&mut self, cx: &mut Context<Self>) {
        self.refresh_provider_credentials(cx, false);
        if !self.model_supports_images() {
            self.status = "当前模型不支持图片输入".to_string();
            cx.notify();
            return;
        }
        let paths_receiver = cx.prompt_for_paths(PathPromptOptions {
            files: true,
            directories: false,
            multiple: true,
            prompt: Some("Select Images".into()),
        });
        cx.spawn(async move |this, cx| {
            let Ok(Ok(Some(paths))) = paths_receiver.await else {
                return;
            };
            let mut loaded = Vec::new();
            for path in paths {
                let Ok(bytes) = std::fs::read(&path) else {
                    continue;
                };
                let Some((png, preview)) = prepare_clipboard_image(&bytes) else {
                    continue;
                };
                let name = path
                    .file_name()
                    .and_then(|name| name.to_str())
                    .unwrap_or("image.png")
                    .to_string();
                let data = base64::engine::general_purpose::STANDARD.encode(&png);
                loaded.push((name, data, preview));
            }
            let _ = this.update(cx, |this, cx| {
                if loaded.is_empty() {
                    this.status = "未能加载所选图片（格式不支持或超过 5MB）".to_string();
                } else {
                    for (name, data, preview) in loaded {
                        this.pending_images.push(PendingImage {
                            name,
                            mime: "image/png".to_string(),
                            data,
                            preview: Some(preview),
                        });
                    }
                    this.status = "已添加图片附件".to_string();
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// Settings 保存 Key 后，已打开的面板不会重建；发送前重载一次凭据。
    fn refresh_provider_credentials(&mut self, cx: &mut Context<Self>, force: bool) {
        if !force && !self.using_echo {
            return;
        }
        let was_echo = self.using_echo;
        let prefs = PrefsStore::new(AppPaths::from_env().agent_prefs_file()).load();
        self.providers = prefs.providers.clone();
        let Some(active) = prefs.active_provider() else {
            return;
        };
        if active.base_url.is_empty() {
            return;
        }
        let Some(api_key) = self
            .keychain
            .as_ref()
            .and_then(|keychain| keychain.load_secret(&provider_key_account(&active.id)))
        else {
            return;
        };
        if api_key.is_empty() {
            return;
        }
        self.provider = Arc::new(OpenAiCompatibleProvider::new(OpenAiCompatibleConfig::new(
            active.base_url.clone(),
            api_key,
            vec![self.model.clone()],
        )));
        self.using_echo = false;
        if was_echo {
            self.status = "已读取 Provider API Key，使用真实模型".to_string();
            self.state
                .push_notice("已重新读取 Provider API Key，后续请求使用真实模型。");
        }
        cx.notify();
    }

    /// 从文件路径加载图片附件（粘贴文件、文件选择器共用）。
    fn add_images_from_paths(&mut self, paths: &[std::path::PathBuf], cx: &mut Context<Self>) {
        let mut added = 0;
        for path in paths {
            let Ok(bytes) = std::fs::read(path) else {
                continue;
            };
            let Some((png, preview)) = prepare_clipboard_image(&bytes) else {
                continue;
            };
            let name = path
                .file_name()
                .and_then(|name| name.to_str())
                .unwrap_or("image.png")
                .to_string();
            let data = base64::engine::general_purpose::STANDARD.encode(&png);
            self.pending_images.push(PendingImage {
                name,
                mime: "image/png".to_string(),
                data,
                preview: Some(preview),
            });
            added += 1;
        }
        if added > 0 {
            self.status = "已添加图片附件".to_string();
        } else {
            self.status = "未能加载图片（格式不支持或超过 5MB）".to_string();
        }
        cx.notify();
    }

    fn open_image_viewer(&mut self, name: String, image: Arc<RenderImage>, cx: &mut Context<Self>) {
        let focus = cx.focus_handle();
        crate::image_viewer::open(name, image, focus, cx);
    }

    /// 发送一条新消息：记录本轮 prompt 供失败重试，然后跑一个 turn。
    fn send_prompt(&mut self, text: String, display: String, cx: &mut Context<Self>) {
        self.refresh_provider_credentials(cx, false);
        self.last_turn = Some((text.clone(), display.clone()));
        self.run_turn(text, display, false, cx);
    }

    /// 重试上一轮失败的请求：不新增用户气泡，直接用同一 prompt 重跑。
    fn retry_last_turn(&mut self, cx: &mut Context<Self>) {
        if !self.state.begin_retry() {
            return;
        }
        let Some((prompt, display)) = self.last_turn.clone() else {
            self.state.push_notice("没有可重试的请求");
            cx.notify();
            return;
        };
        // 重试 = 重放上一轮：线程侧丢掉失败那轮的 user 条目（prompt 会重新 push，
        // 否则重启恢复后会出现重复用户气泡）；UI 侧丢掉失败 turn 的残留行。
        if let Some(agent) = self.agent.as_mut() {
            agent.thread_mut().truncate_before_last_user();
        }
        if let Some(index) = trim_entries_to_last_user(&mut self.state.thread.entries) {
            self.sent_images
                .retain(|entry_index, _| *entry_index <= index);
        }
        // Settings 里改过 Key 后重试要能读到新凭据。
        self.refresh_provider_credentials(cx, true);
        self.run_turn(prompt, display, true, cx);
    }

    fn stop(&mut self, cx: &mut Context<Self>) {
        // 双保险：ACP session/cancel 经 server 触发 runtime 的 cancel 回调；
        // 直接 cancel 本地 token 保证即使连接未建立也能立即停。
        self.cancel.cancel();
        if let Some(host) = &self.host.acp_host {
            let _ = host.stop();
        }
        self.status = "正在停止…".to_string();
        cx.notify();
    }
}

/// 每个 workspace scope 一条 native 线程（ADR-0028）。
fn scope_thread_id(scope: &crate::agent_scope::AgentScope) -> String {
    format!("native-{}", scope.key)
}

/// 滚动是否已经在底部（GPUI 的 offset.y 越往下越负，max_offset 为正）。
/// 2px 容差避免亚像素/取整导致的“差一点点”抖动。
/// 用户消息正文：普通文本 + mention chip（与 composer 的 chip 对齐）。
fn render_user_message_body(text: &str, palette: &theme::Palette) -> AnyElement {
    let palette = *palette;
    let segments = mention::display_segments(text);
    div()
        .flex()
        .flex_row()
        .flex_wrap()
        .items_center()
        .gap(px(2.0))
        .children(segments.into_iter().enumerate().map(|(index, segment)| {
            match segment {
                mention::DisplaySegment::Text(text) => div()
                    .text_size(px(13.0))
                    .text_color(palette.ink)
                    .child(text)
                    .into_any_element(),
                mention::DisplaySegment::Mention {
                    label,
                    kind,
                    target,
                } => {
                    let icon = match kind {
                        mention::MentionKind::Skill => gpui_kit::assets::IconName::Sparkle,
                        mention::MentionKind::File => gpui_kit::assets::IconName::FileText,
                    };
                    let chip = div()
                        .flex()
                        .flex_row()
                        .items_center()
                        .gap(px(2.0))
                        .px(px(4.0))
                        .py(px(1.0))
                        .rounded(px(RADIUS_SMALL))
                        .border_1()
                        .border_color(palette.line)
                        .bg(palette.soft)
                        .child(Icon::new(icon).xsmall().text_color(palette.ink_3))
                        .child(
                            div()
                                .text_size(px(12.0))
                                .text_color(palette.ink_2)
                                .child(label),
                        );
                    HoverCard::new(SharedString::from(format!("native-mention-chip-{index}")))
                        .anchor(Anchor::TopCenter)
                        .open_delay(std::time::Duration::from_millis(200))
                        .trigger(chip)
                        .content(move |_, _, _| {
                            div()
                                .p(px(4.0))
                                .rounded(px(RADIUS_SMALL))
                                .border_1()
                                .border_color(palette.line)
                                .bg(palette.card)
                                .text_size(px(11.0))
                                .text_color(palette.ink_2)
                                .child(target.clone())
                                .into_any_element()
                        })
                        .into_any_element()
                }
            }
        }))
        .into_any_element()
}

fn tool_status_label(status: ViewToolStatus) -> &'static str {
    match status {
        ViewToolStatus::Running => "运行中…",
        ViewToolStatus::Ok => "完成",
        ViewToolStatus::Failed => "失败",
    }
}

/// 工具调用卡片：标题显示状态/名称，展开后展示 raw 参数与 raw 输出。
/// P8：工具卡状态 → (glyph, 文案)，纯函数可单测。
fn tool_row_status_parts(status: ViewToolStatus) -> (&'static str, &'static str) {
    match status {
        ViewToolStatus::Running => ("◐", tool_status_label(status)),
        ViewToolStatus::Ok => ("✓", tool_status_label(status)),
        ViewToolStatus::Failed => ("✗", tool_status_label(status)),
    }
}

fn render_tool_card(
    tool: &ViewTool,
    expanded: bool,
    palette: &theme::Palette,
    on_toggle: impl Fn(&mut App) + 'static,
) -> AnyElement {
    let (glyph, status_label) = tool_row_status_parts(tool.status);
    let args = if tool.args.is_null() || !expanded {
        None
    } else {
        Some(serde_json::to_string_pretty(&tool.args).unwrap_or_else(|_| tool.args.to_string()))
    };
    let content = tool.content.clone().unwrap_or_default();
    let output = expanded.then(|| {
        if content.is_empty() {
            if matches!(tool.status, ViewToolStatus::Running) {
                "（等待输出…）".to_string()
            } else {
                String::new()
            }
        } else {
            content
        }
    });
    let status_color = match tool.status {
        ViewToolStatus::Running => palette.accent,
        ViewToolStatus::Ok => palette.ink_3,
        ViewToolStatus::Failed => palette.danger,
    };
    render_tool_row(ToolRowSpec {
        row_id: SharedString::from("native-tool-card"),
        header_id: SharedString::from("native-tool-card-header"),
        name: tool.name.clone(),
        status_label: status_label.to_string(),
        glyph,
        status_color,
        args,
        output: output.filter(|text| !text.is_empty()),
        expanded,
        style: native_row_palette(palette),
        on_toggle: Box::new(move |cx: &mut App| on_toggle(cx)),
    })
}

/// B3c：native `SubagentCard` → 共享 `agent_ui::subagent_row` 的 adapter。
/// 只映射数据，不重排行顺序（顺序由 `message_row_kinds` 决定）。
fn render_subagent_row(card: &SubagentCard, palette: &theme::Palette) -> AnyElement {
    cgc_agent_ui::subagent_row::render_subagent_row(cgc_agent_ui::subagent_row::SubagentRowSpec {
        task: card.task.clone(),
        text: card.text.clone(),
        finished: card.finished,
        style: cgc_agent_ui::subagent_row::SubagentRowStyle {
            view: palette.view,
            ink_2: palette.ink_2,
            ink_3: palette.ink_3,
            radius: RADIUS_SMALL,
        },
    })
}

/// 空线程时的引导提示（重发重建状态时需要剔除，避免显示在编辑后的对话顶部）。
const EMPTY_THREAD_NOTICE: &str = "Native agent：配置 Provider 后开始对话。";

fn role_label(role: ViewRole) -> &'static str {
    match role {
        ViewRole::User => "you",
        ViewRole::Assistant => "agent",
        ViewRole::Thinking => "thinking",
        ViewRole::Tool => "tool",
        ViewRole::System => "system",
        ViewRole::Error => "error",
    }
}

/// 把 native 的本地 `ViewRow` 映射到共享消息流（`agent_ui::message_flow`）。
fn message_menu_payloads(
    role: ViewRole,
    text: &str,
    agent_response: Option<String>,
) -> MenuPayloads {
    let plain = match role {
        ViewRole::Assistant => markdown_to_plain(text),
        ViewRole::User => mention::display_text(text),
        _ => text.to_string(),
    };
    MenuPayloads {
        plain,
        markdown: text.to_string(),
        agent_response,
    }
}

/// native 主题 → 共享消息行样式。
fn native_composer_style(palette: theme::Palette) -> cgc_agent_ui::composer::ComposerStyle {
    cgc_agent_ui::composer::ComposerStyle {
        view: palette.view,
        line: palette.line,
        accent: palette.accent,
        danger: palette.danger,
        canvas: palette.canvas,
        radius: RADIUS_MEDIUM,
        padding: 4.0,
        gap: 1.0,
    }
}

/// P8：native 主题 → 共享 message_row 的行调色板（共享层不依赖 app theme）。
fn native_row_palette(palette: &theme::Palette) -> RowPalette {
    RowPalette {
        ink: palette.ink,
        ink_2: palette.ink_2,
        ink_3: palette.ink_3,
        line: palette.line,
        line_strong: palette.line_strong,
        view: palette.view,
        card: palette.card,
        canvas: palette.canvas,
        accent: palette.accent,
        danger: palette.danger,
        soft: palette.soft,
        radius: RADIUS_MEDIUM,
        radius_small: RADIUS_SMALL,
        mono_font: theme::FONT_MONO.into(),
    }
}

fn native_message_style(palette: theme::Palette) -> MessageStyle {
    MessageStyle {
        ink_2: palette.ink_2,
        ink_3: palette.ink_3,
        line: palette.line,
        radius: RADIUS_MEDIUM,
    }
}

/// native 主题 → 共享 picker 样式。
fn native_picker_style(palette: theme::Palette) -> PickerStyle {
    PickerStyle {
        accent: palette.accent,
        ink_2: palette.ink_2,
        ink_3: palette.ink_3,
        soft: palette.soft,
        card: palette.card,
        radius: RADIUS_MEDIUM,
    }
}

/// native 主题 → 共享 slash 菜单样式（选中 = soft 背景 + accent 文本）。
fn native_command_menu_style(palette: theme::Palette) -> CommandMenuStyle {
    CommandMenuStyle {
        card: palette.card,
        line: palette.line,
        soft: palette.soft,
        accent: palette.accent,
        canvas: palette.canvas,
        ink: palette.ink,
        ink_2: palette.ink_2,
        ink_3: palette.ink_3,
        selected_bg: palette.soft,
        selected_text: palette.accent,
        radius: RADIUS_SMALL,
        padding: 0.0,
    }
}

/// P9：native → 共享 `message_actions::ActionBarSpec` 的 id 组装（纯函数，可单测）。
fn native_action_bar_ids(prefix: &str) -> (SharedString, SharedString, SharedString, SharedString) {
    (
        SharedString::from(format!("{prefix}-row")),
        SharedString::from(format!("{prefix}-copy")),
        SharedString::from(format!("{prefix}-user")),
        SharedString::from(format!("{prefix}-top")),
    )
}

/// P9：native → 共享 action bar spec（纯组装；回调由调用方注入）。
fn native_action_bar_spec(
    prefix: &str,
    style: ActionStyle,
    glyphs: ActionGlyphs,
    callbacks: ActionCallbacks,
) -> ActionBarSpec {
    let (row_id, copy_id, user_id, top_id) = native_action_bar_ids(prefix);
    ActionBarSpec {
        row_id,
        copy_id,
        user_id,
        top_id,
        glyphs,
        style,
        callbacks,
    }
}

fn native_action_glyphs() -> ActionGlyphs {
    ActionGlyphs {
        copy: ActionGlyph::Named(gpui_kit::assets::IconName::Copy),
        user: ActionGlyph::Named(gpui_kit::assets::IconName::User),
        top: ActionGlyph::Named(gpui_kit::assets::IconName::ArrowUp),
    }
}

fn native_action_style(palette: theme::Palette) -> ActionStyle {
    ActionStyle {
        icon_color: palette.ink_3,
        hover_bg: palette.soft,
        button_size: 22.0,
        radius: RADIUS_SMALL,
        gap: 4.0,
    }
}

/// native 的消息右键菜单：滚动回调注入到共享菜单渲染。
fn render_native_message_menu(
    menu: PopupMenu,
    view: WeakEntity<NativeAgentView>,
    payloads: Arc<MenuPayloads>,
) -> PopupMenu {
    let top_view = view.clone();
    let bottom_view = view;
    render_message_menu(
        menu,
        (*payloads).clone(),
        Box::new(move |cx| {
            let _ = top_view.update(cx, |this, cx| this.scroll_messages_to_top(cx));
        }),
        Box::new(move |cx| {
            let _ = bottom_view.update(cx, |this, cx| this.scroll_messages_to_bottom(cx));
        }),
    )
}

/// composer 里的 mention chip：技能 / 文件各一个图标，hover 显示真实路径。
#[cfg(test)]
mod workspace_prompt_tests {
    use super::{
        build_workspace_system_prompt, composer_has_input, now_secs, offline_echo_notice,
        queued_panel_header_text, queued_status_text, NativeComposerGating,
    };

    #[test]
    fn queue_hint_texts_include_count() {
        assert_eq!(
            queued_status_text(2),
            "已排队 2 条，当前 turn 结束后依次发送"
        );
        assert_eq!(
            queued_panel_header_text(3),
            "排队中 3 条 · 当前 turn 结束后自动发送"
        );
    }

    #[test]
    fn checkpoint_keep_and_restore_paths_from_fake_changes() {
        use cgc_agent_checkpoint::FileChange;
        let mut changes = vec![
            FileChange {
                path: "a.rs".into(),
                status: "M".into(),
            },
            FileChange {
                path: "b.rs".into(),
                status: "A".into(),
            },
        ];
        assert_eq!(super::checkpoint_change_label(&changes[0]), "M a.rs");
        assert_eq!(super::paths_for_restore_all(&changes), vec!["a.rs", "b.rs"]);
        super::keep_change_by_path(&mut changes, "a.rs");
        assert_eq!(changes.len(), 1);
        assert_eq!(changes[0].path, "b.rs");
    }

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
    fn action_bar_ids_follow_shared_prefix_convention() {
        let (row, copy, user, top) = super::native_action_bar_ids("native-message-actions-7");
        assert_eq!(row.as_ref(), "native-message-actions-7-row");
        assert_eq!(copy.as_ref(), "native-message-actions-7-copy");
        assert_eq!(user.as_ref(), "native-message-actions-7-user");
        assert_eq!(top.as_ref(), "native-message-actions-7-top");
        // trailing 兜底栏同样走同一组装函数
        let (row, ..) = super::native_action_bar_ids("native-trailing-actions");
        assert_eq!(row.as_ref(), "native-trailing-actions-row");
    }

    #[test]
    fn tool_row_status_parts_map_glyph_and_label() {
        assert_eq!(
            super::tool_row_status_parts(super::ViewToolStatus::Running),
            ("◐", "运行中…")
        );
        assert_eq!(
            super::tool_row_status_parts(super::ViewToolStatus::Ok),
            ("✓", "完成")
        );
        assert_eq!(
            super::tool_row_status_parts(super::ViewToolStatus::Failed),
            ("✗", "失败")
        );
    }

    #[test]
    fn scope_key_maps_to_native_thread_id() {
        let scope = crate::agent_scope::AgentScope {
            key: "assistant-local".into(),
            root: std::path::PathBuf::from("/tmp/ws"),
        };
        assert_eq!(super::scope_thread_id(&scope), "native-assistant-local");
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
    fn composer_has_input_trims_whitespace() {
        assert!(!composer_has_input("   \n\t "));
        assert!(composer_has_input("hi"));
        assert!(composer_has_input("  hi "));
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
        let all = super::slash_entries_for(&registry, &skills, "/");
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
        let filtered = super::slash_entries_for(&registry, &skills, "/read");
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

        let entries = super::slash_entries_for(&registry, &skills, "/answer");
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
        let entries = super::slash_entries_for(&registry, &[], "/che");
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

    /// 回归（真机 bug 1）：Permission 行必须反映 resolved 状态，不能永远是
    /// 「等待审批」；文案与 ACP 轨一致（已允许 / 已拒绝 / 等待审批）。
    #[test]
    fn permission_row_text_reflects_resolved_state() {
        use cgc_agent_ui::conversation::Entry as ConversationEntry;

        let row = |resolved: Option<bool>| {
            super::ViewRow::from_entry(&ConversationEntry::Permission {
                request_id: "perm-1".into(),
                title: "允许运行 run_command？".into(),
                tool: Some("run_command".into()),
                tool_call_id: Some("call-1".into()),
                args: None,
                options: Vec::new(),
                resolved,
            })
            .text
        };
        assert_eq!(row(None), "等待审批：允许运行 run_command？");
        assert_eq!(row(Some(true)), "已允许：允许运行 run_command？");
        assert_eq!(row(Some(false)), "已拒绝：允许运行 run_command？");
    }

    #[test]
    fn apply_thread_entries_builds_tool_cards_with_args() {
        use crate::native_thread_state::NativeThreadState;
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
        super::apply_thread_entries(&mut state, &entries);
        // Stage 2d：恢复的线程 entries 直接投影进共享模型。
        use cgc_agent_ui::conversation::Entry as ConversationEntry;
        assert_eq!(state.thread.entries.len(), 3);
        assert!(matches!(
            &state.thread.entries[0],
            ConversationEntry::User { text } if text == "跑一下"
        ));
        let ConversationEntry::ToolCall {
            tool_call_id,
            name,
            status,
            args,
            output,
            ..
        } = &state.thread.entries[1]
        else {
            panic!("thread tool call");
        };
        assert_eq!(tool_call_id, "call_1");
        assert_eq!(name.as_deref(), Some("run_command"));
        assert_eq!(status, "completed");
        assert!(args.as_deref().unwrap_or_default().contains("echo hi"));
        assert_eq!(output.as_deref(), Some("hi"));
        assert!(matches!(
            &state.thread.entries[2],
            ConversationEntry::Thinking { text, .. } if text == "想一下"
        ));
    }

    #[test]
    fn tool_status_label_covers_all_states() {
        assert_eq!(
            super::tool_status_label(super::ViewToolStatus::Running),
            "运行中…"
        );
        assert_eq!(super::tool_status_label(super::ViewToolStatus::Ok), "完成");
        assert_eq!(
            super::tool_status_label(super::ViewToolStatus::Failed),
            "失败"
        );
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
    fn checkpoint_for_ordinal_skips_invalid_and_matches_seq() {
        use cgc_agent_store::CheckpointRecord;
        let record = |seq: i64, state: &str| CheckpointRecord {
            thread_id: "t".into(),
            user_entry_seq: seq,
            ref_name: format!("refs/cgc/{seq}"),
            sha: "abc".into(),
            base_head: None,
            created_at: 0,
            state: state.into(),
        };
        let records = vec![record(1, "valid"), record(2, "invalid"), record(3, "valid")];
        assert_eq!(
            super::checkpoint_for_ordinal(&records, 1).map(|r| r.user_entry_seq),
            Some(1)
        );
        assert!(
            super::checkpoint_for_ordinal(&records, 2).is_none(),
            "失效 checkpoint 跳过"
        );
        assert_eq!(
            super::checkpoint_for_ordinal(&records, 3).map(|r| r.user_entry_seq),
            Some(3)
        );
        assert!(super::checkpoint_for_ordinal(&records, 4).is_none());
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
