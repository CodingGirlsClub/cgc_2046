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
mod rows;

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

    pub fn is_empty_thread(&self) -> bool {
        self.agent
            .as_ref()
            .map(|agent| agent.thread().entries.is_empty())
            .unwrap_or(true)
    }

    pub fn current_thread_id(&self) -> Option<String> {
        self.agent.as_ref().map(|agent| agent.thread().id.clone())
    }

    pub fn display_title(&self) -> String {
        self.agent
            .as_ref()
            .and_then(|agent| agent.thread().display_title())
            .unwrap_or_else(|| "新对话".to_string())
    }

    pub fn set_title_override(&mut self, title: Option<String>, cx: &mut Context<Self>) {
        self.host.set_title_override(title.clone());
        if let Some(agent) = &mut self.agent {
            agent.set_thread_title_override(title);
        }
        if let Some(agent) = self.agent.as_ref() {
            let _ = self.session_store.save_thread(agent.thread());
        }
        cx.notify();
    }

    pub fn regenerate_title(&mut self, cx: &mut Context<Self>) {
        self.host.set_title_override(None);
        if let Some(agent) = &mut self.agent {
            agent.set_thread_title(None);
            agent.set_thread_title_override(None);
        }
        self.generate_thread_title(cx);
    }

    /// 用当前模型生成会话标题（异步、失败回退首条用户消息）。
    fn generate_thread_title(&mut self, cx: &mut Context<Self>) {
        let Some(agent) = &self.agent else {
            return;
        };
        let mut user_text = String::new();
        let mut assistant_text = String::new();
        for entry in &agent.thread().entries {
            match entry {
                cgc_agent_core::Entry::User { text, .. } if user_text.is_empty() => {
                    user_text = text.clone();
                }
                cgc_agent_core::Entry::Assistant { text, .. } if !text.is_empty() => {
                    assistant_text = text.clone();
                }
                _ => {}
            }
        }
        if user_text.is_empty() {
            return;
        }
        let provider = self.provider.clone();
        let model = self.model.clone();
        cx.notify();
        cx.spawn(async move |this, cx| {
            let request = ProviderRequest::new(vec![
                ProviderMessage::system(
                    "你是会话标题生成器。用不超过 12 个汉字概括对话主题，只输出标题本身，不要引号、句号或解释。",
                ),
                ProviderMessage::user(format!(
                    "用户: {}

助手: {}",
                    truncate_text(&user_text, 1200),
                    truncate_text(&assistant_text, 1600)
                )),
            ]);
            let mut generated = String::new();
            let mut failed = false;
            match provider.stream(&model, request).await {
                Ok(mut stream) => {
                    while let Some(event) = stream.next().await {
                        match event {
                            Ok(CompletionEvent::Text(text)) => generated.push_str(&text),
                            Ok(_) => {}
                            Err(error) => {
                                failed = true;
                                generated = error.to_string();
                                break;
                            }
                        }
                    }
                }
                Err(error) => {
                    failed = true;
                    generated = error.to_string();
                }
            }
            let fallback = clean_thread_title(&truncate_text(&user_text, 30));
            let title = clean_thread_title(&generated);
            let _ = this.update(cx, |this, cx| {
                if failed || title.is_empty() {
                    if !fallback.is_empty() {
                        if let Some(agent) = &mut this.agent {
                            agent.set_thread_title(Some(fallback.clone()));
                        }
                        if let (Some(agent), Some(store)) =
                            (this.agent.as_ref(), this.session_store.session_mut())
                        {
                            let _ = store.save_thread(agent.thread());
                        }
                    }
                } else {
                    if let Some(agent) = &mut this.agent {
                        agent.set_thread_title(Some(title.clone()));
                    }
                    if let (Some(agent), Some(store)) =
                        (this.agent.as_ref(), this.session_store.session_mut())
                    {
                        let _ = store.save_thread(agent.thread());
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    fn maybe_generate_thread_title(&mut self, cx: &mut Context<Self>) {
        let has_title = self
            .agent
            .as_ref()
            .and_then(|agent| agent.thread().title.clone())
            .map(|title| !title.trim().is_empty())
            .unwrap_or(false);
        if has_title {
            return;
        }
        self.generate_thread_title(cx);
    }

    /// 当前 model 的 context window（用于共享模型的 usage 百分比）。
    fn model_context_size(&self) -> u64 {
        self.providers
            .iter()
            .find(|provider| provider.id == self.model.provider_id.as_str())
            .map(|provider| provider.model_config(self.model.id.as_str()).context_window as u64)
            .unwrap_or(0)
    }

    /// 从统一线程列表恢复指定 native 线程。
    pub fn open_thread(&mut self, thread_id: &str, cx: &mut Context<Self>) {
        let Some(store) = self.session_store.session() else {
            return;
        };
        let Ok(Some(thread)) = store.load_thread(thread_id) else {
            return;
        };
        let mut state = NativeThreadState::new();
        let restored_images = apply_thread_entries(&mut state, &thread.entries);
        state.usage_total = thread.usage_total;
        state.thread.thread_id = thread.id.clone();
        state.set_context_size(self.model_context_size());
        state.thread.usage = Usage {
            used: thread.usage_total.total(),
            size: self.model_context_size(),
            cost: None,
        };
        self.state = state;
        self.sent_images = restored_images;
        let prompt = build_workspace_system_prompt(self.context.workspace());
        self.agent = Some(Agent::new(thread, Some(prompt)));
        self.editing_user = None;
        self.user_edit_input = None;
        self.reload_thread_checkpoints();
        self.status = "已恢复线程".to_string();
        self.busy = false;
        self.checkpoint_changes.clear();
        self.show_checkpoint_panel = false;
        self.scroll_messages_to_bottom(cx);
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

    /// 执行一个 turn；`retry` = 重放上一轮（不重复 push 用户消息、不重拍 checkpoint）。
    ///
    /// Phase A：Agent 与 per-turn 配置交给进程内 ACP server 的运行时出口，
    /// 过程事件经 ACP 客户端回到 `drain_acp_events` 再归约进共享会话模型。
    fn run_turn(&mut self, text: String, display: String, retry: bool, cx: &mut Context<Self>) {
        if !retry {
            self.reload_latest_session();
            // 本条用户消息即将 push（run_turn 里会 push），ordinal = 现有用户消息数 + 1。
            let ordinal = self
                .state
                .thread
                .entries
                .iter()
                .filter(|entry| matches!(entry, ConversationEntry::User { .. }))
                .count()
                + 1;
            if let Some(thread_id) = self.agent.as_ref().map(|agent| agent.thread().id.clone()) {
                self.capture_checkpoint(&thread_id, ordinal);
            }
        }
        self.scroll_messages_to_bottom(cx);
        let Some(mut agent) = self.agent.take() else {
            return;
        };
        if !retry && !self.pending_images.is_empty() {
            agent.set_pending_images(
                self.pending_images
                    .iter()
                    .map(|image| (image.name.clone(), image.mime.clone(), image.data.clone()))
                    .collect(),
            );
            let sent: Vec<SentImage> = self
                .pending_images
                .iter()
                .map(|image| SentImage {
                    name: image.name.clone(),
                    preview: image.preview.clone(),
                })
                .collect();
            if !sent.is_empty() {
                let message_index = self.state.thread.entries.len();
                self.sent_images.insert(message_index, sent);
            }
            self.pending_images.clear();
        }
        let model_config = self
            .providers
            .iter()
            .find(|provider| provider.id == self.model.provider_id.as_str())
            .map(|provider| provider.model_config(self.model.id.as_str()))
            .unwrap_or_default();
        let effort_index = self
            .effort_index
            .min(model_config.reasoning_efforts.len().saturating_sub(1));
        let effort = if self.thinking_enabled && model_config.supports_thinking {
            model_config.effort_at(effort_index).map(str::to_string)
        } else {
            None
        };
        agent.set_reasoning_effort(effort);
        // 记录 UI 展示文本（不含注入上下文），restore 时用户气泡不会显示上下文前缀。
        agent.set_pending_user_display(Some(display.clone()));
        if !retry {
            crate::agent_ingest::apply_user_turn(&mut self.state.thread, display.clone());
        }
        self.busy = true;
        self.status = "思考中…".to_string();
        self.cancel.reset();
        self.ensure_subagent_pump(cx);
        if !self.ensure_acp_host() {
            self.busy = false;
            self.agent = Some(agent);
            cx.notify();
            return;
        }
        let context_size = self.model_context_size();
        if let Some(handle) = &self.acp_context_size {
            handle.store(context_size, std::sync::atomic::Ordering::Relaxed);
        }
        let model_tools_supported = self
            .providers
            .iter()
            .find(|provider| provider.id == self.model.provider_id.as_str())
            .map(|provider| provider.model_config(self.model.id.as_str()).supports_tools)
            .unwrap_or(true);
        self.runtime.put_config(NativeRuntimeConfig {
            provider: self.provider.clone(),
            model: self.model.clone(),
            registry: if model_tools_supported {
                self.registry.clone()
            } else {
                Arc::new(ToolRegistry::new())
            },
            context: self.context.clone(),
            context_size,
            auto_approve: self.approval_mode == ApprovalMode::Auto,
        });
        self.runtime.put_agent(agent);
        self.ensure_acp_poller(cx);
        let prompted = self
            .host
            .acp_host
            .as_ref()
            .map(|host| host.prompt(text))
            .unwrap_or(false);
        if !prompted {
            self.finish_turn(TurnEndState::Failed("agent channel closed".to_string()), cx);
        }
        cx.notify();
    }

    /// 建立 native 的进程内 ACP 连接（client 侧与外部 ACP agent 完全同一条路径）。
    fn ensure_acp_host(&mut self) -> bool {
        if self.host.acp_connected() {
            return true;
        }
        let server = NativeAcpServer::new(Box::new(self.runtime.clone())).with_config(
            NativeAcpServerConfig {
                agent_name: "cgc-native".to_string(),
                version: env!("CARGO_PKG_VERSION").to_string(),
            },
        );
        self.acp_context_size = Some(server.context_size_handle());
        let cwd = self.context.workspace().to_path_buf();
        match AcpHost::start_in_process(AcpHostConfig::new("", cwd).with_name("cgc-native"), server)
        {
            Ok(host) => {
                self.host.set_acp_host(Some(host));
                true
            }
            Err(error) => {
                self.state.last_error = Some(error.to_string());
                self.state
                    .push_notice(format!("启动进程内 ACP 连接失败：{error}"));
                self.status = format!("错误：{error}");
                false
            }
        }
    }

    /// 启动 ACP 客户端事件轮询（50ms 批量 drain，与 ACP 面板同一消费方式）。
    fn ensure_acp_poller(&mut self, cx: &mut Context<Self>) {
        if self.acp_poller_running {
            return;
        }
        self.acp_poller_running = true;
        self.acp_poller_generation += 1;
        let generation = self.acp_poller_generation;
        cx.spawn(async move |this, cx| loop {
            cx.background_executor()
                .timer(std::time::Duration::from_millis(50))
                .await;
            let keep = this
                .update(cx, |this, cx| this.drain_acp_events(generation, cx))
                .unwrap_or(false);
            if !keep {
                break;
            }
        })
        .detach();
    }

    /// 消费一批 ACP 客户端事件：会话行统一走 `agent_ingest`，native 辅助态更新
    /// 审批卡 / 子 agent 配对；turn 收尾事件触发完成逻辑。
    fn drain_acp_events(&mut self, generation: u64, cx: &mut Context<Self>) -> bool {
        if generation != self.acp_poller_generation {
            return false;
        }
        self.retrieve_awaiting_agent(cx);
        let mut events = Vec::new();
        if let Some(host) = &self.host.acp_host {
            while let Some(event) = host.try_recv() {
                events.push(event);
            }
        }
        if events.is_empty() {
            return self.host.acp_connected() || self.awaiting_agent;
        }
        let old_len = self.state.thread.entries.len();
        let mut finished = None;
        for event in events {
            // Stage 3.2b（路线 A）：settings 级规则只作用于 native。决定性 allow/deny
            // 且请求里有对应 kind 的 option 时自动回传、不弹卡，并在会话里补一条
            // system Notice；否则（ask/confirm、无匹配 option）照常走共享权限卡。
            // Auto 模式由 runtime 内 AutoApprover 决定，不叠加规则。
            if self.approval_mode == ApprovalMode::Ask {
                if let Some(auto) = crate::approval_rules::auto_permission_for_event(
                    &crate::approval_rules::ApprovalRules::load(),
                    &event,
                ) {
                    if let Some(host) = &self.host.acp_host {
                        let _ = host.respond_permission_option(&auto.request_id, &auto.option_id);
                    }
                    agent_ingest::apply_notice(&mut self.state.thread, auto.notice);
                    cx.notify();
                    continue;
                }
            }
            self.state.apply_host_event(&event);
            match &event {
                HostEvent::PermissionRequested { .. } => {
                    // Auto 模式在 runtime 内已放行，不应出现审批请求；防御性按
                    // agent 提供的第一个 allow 选项回传。
                    if self.approval_mode == ApprovalMode::Auto {
                        let option_id = self
                            .state
                            .thread
                            .pending_permission
                            .as_ref()
                            .and_then(|request| {
                                request.options.iter().find(|option| option.kind.is_allow())
                            })
                            .map(|option| option.id.clone());
                        if let Some(option_id) = option_id {
                            self.resolve_permission_option(&option_id, cx);
                        }
                    }
                }
                HostEvent::TurnEnd {
                    cancelled,
                    stop_reason,
                } => {
                    let cancelled = *cancelled || stop_reason.eq_ignore_ascii_case("cancelled");
                    finished = Some(if cancelled {
                        TurnEndState::Cancelled
                    } else {
                        TurnEndState::Completed
                    });
                }
                HostEvent::Error { message } => {
                    finished = Some(TurnEndState::Failed(message.clone()));
                }
                HostEvent::Exited => {
                    self.host.set_acp_host(None);
                    self.acp_poller_running = false;
                    finished = Some(TurnEndState::Failed("agent connection exited".to_string()));
                }
                _ => {}
            }
        }
        // 新出现的 thinking 行默认展开（对齐旧行为）。
        for (index, entry) in self.state.thread.entries.iter().enumerate() {
            if index >= old_len && matches!(entry, ConversationEntry::Thinking { .. }) {
                self.expanded_thinking.insert(index);
            }
        }
        self.state.pair_unlinked_subagents();
        self.state.sync_pending_permission();
        if self.busy {
            if let Some(state) = finished {
                self.finish_turn(state, cx);
            }
        }
        cx.notify();
        self.host.acp_connected() || self.awaiting_agent
    }

    /// cancel 宽限期内 client 可能先收到合成 TurnEnd，而 server 稍后才把 Agent
    /// 交回 runtime slot；这里轮询补取，再补做 turn 收尾（保存线程等）。
    fn retrieve_awaiting_agent(&mut self, cx: &mut Context<Self>) {
        if !self.awaiting_agent {
            return;
        }
        let Some(agent) = self.runtime.take_agent() else {
            return;
        };
        self.agent = Some(agent);
        self.awaiting_agent = false;
        let state = self
            .pending_turn_end
            .take()
            .unwrap_or(TurnEndState::Completed);
        self.apply_turn_end(state, cx);
    }

    /// turn 收尾：取回 Agent、保存线程、checkpoint / 子 agent / 队列收口。
    fn finish_turn(&mut self, state: TurnEndState, cx: &mut Context<Self>) {
        if let Some(agent) = self.runtime.take_agent() {
            self.agent = Some(agent);
        }
        if self.agent.is_none() {
            // turn 还在 server 侧收尾（Agent 尚未交回）：保持 busy（用户输入继续
            // 进 queue，避免丢消息），由 drain 轮询在 Agent 回到 slot 后再收尾。
            self.awaiting_agent = true;
            self.pending_turn_end = Some(state);
            cx.notify();
            return;
        }
        self.apply_turn_end(state, cx);
    }

    /// Agent 已取回后的 turn 收尾（状态、持久化、checkpoint、队列）。
    fn apply_turn_end(&mut self, state: TurnEndState, cx: &mut Context<Self>) {
        self.busy = false;
        match &state {
            TurnEndState::Completed => {
                let total = self
                    .agent
                    .as_ref()
                    .map(|agent| agent.thread().usage_total.total())
                    .unwrap_or(0);
                if let Some(agent) = &self.agent {
                    self.state.usage_total = agent.thread().usage_total;
                }
                self.status = format!("完成 · 本会话 {total} tokens");
            }
            TurnEndState::Cancelled => self.status = "已停止".to_string(),
            TurnEndState::Failed(message) => {
                self.state.last_error = Some(message.clone());
                // HostEvent::Error 已由共用 ingestion 落过 Failed 行；这里只补
                // 合成失败（channel closed / 连接退出）缺失的那一行，避免重复。
                if !matches!(
                    self.state.thread.status,
                    cgc_agent_ui::conversation::ThreadStatus::Failed
                ) {
                    self.state
                        .thread
                        .apply(cgc_agent_ui::conversation::ThreadEvent::Failed(
                            message.clone(),
                        ));
                }
                self.status = format!("错误：{message}");
            }
        }
        if let (Some(store), Some(agent)) = (self.session_store.session_mut(), &self.agent) {
            let _ = store.save_thread(agent.thread());
        }
        self.reload_thread_checkpoints();
        self.drain_app_actions(cx);
        self.refresh_checkpoint_changes();
        if matches!(state, TurnEndState::Completed) {
            self.maybe_generate_thread_title(cx);
        }
        if !self.queued_messages.is_empty() {
            let next = self.queued_messages.remove(0);
            self.send_prompt(next.prompt, next.display, cx);
        }
        cx.notify();
    }

    /// 子 agent 实时进度是 ACP v1 表达不了的 native 专属事件，走独立辅助通道。
    fn ensure_subagent_pump(&mut self, cx: &mut Context<Self>) {
        if self.subagent_pump_started {
            return;
        }
        self.subagent_pump_started = true;
        let (sender, mut receiver) = mpsc::unbounded::<AgentEvent>();
        if let Ok(mut slot) = self.subagent_tx.lock() {
            *slot = Some(sender);
        }
        cx.spawn(async move |this, cx| {
            while let Some(event) = receiver.next().await {
                let updated = this.update(cx, |this, cx| {
                    this.state.apply_subagent_event(&event);
                    this.state.pair_unlinked_subagents();
                    cx.notify();
                });
                if updated.is_err() {
                    break;
                }
            }
        })
        .detach();
    }

    fn steer(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let text = self.input.read(cx).value().trim().to_string();
        if text.is_empty() {
            return;
        }
        if self.steer_sender.send(text).is_ok() {
            self.input
                .update(cx, |state, cx| state.set_value("", window, cx));
            self.status = "已插入 steer，当前生成将被中断".to_string();
        } else {
            self.status = "steer 发送失败".to_string();
        }
        cx.notify();
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

    fn drain_app_actions(&mut self, cx: &mut Context<Self>) {
        let actions = self
            .app_actions
            .lock()
            .map(|mut actions| std::mem::take(&mut *actions))
            .unwrap_or_default();
        for action in actions {
            let summary = action.summary();
            let mut dispatched = false;
            let workspace = self.context.workspace().to_path_buf();
            for window in cx.windows() {
                if let Some(root) = window.downcast::<crate::root_view::RootView>() {
                    let _ = root.update(cx, |root, _window, cx| {
                        root.apply_native_agent_action(action.clone(), workspace.clone(), cx);
                    });
                    dispatched = true;
                    break;
                }
            }
            if let Some(log) = &self.host.action_audit {
                let action_name = match &action {
                    AppAction::OpenPage { .. } => "open_page",
                    AppAction::HighlightRange { .. } => "highlight_range",
                };
                let _ = log.append(&ActionAuditEntry {
                    at: now_secs(),
                    action: action_name.to_string(),
                    detail: summary.clone(),
                    dispatched,
                });
            }
            self.state.push_notice(if dispatched {
                format!("已执行：{summary}")
            } else {
                summary
            });
        }
    }

    fn keep_all_changes(&mut self, cx: &mut Context<Self>) {
        self.checkpoint_changes.clear();
        self.status = "已全部保留本轮改动".to_string();
        cx.notify();
    }

    fn reject_all_changes(&mut self, cx: &mut Context<Self>) {
        let paths = paths_for_restore_all(&self.checkpoint_changes);
        for path in &paths {
            self.restore_checkpoint_file(path.clone(), cx);
        }
        self.status = format!("已回退 {} 个文件", paths.len());
        self.checkpoint_changes.clear();
        cx.notify();
    }

    fn refresh_checkpoint_changes(&mut self) {
        self.checkpoint_changes = match (&self.checkpoint_manager, &self.last_checkpoint) {
            (Some(manager), Some(checkpoint)) => {
                manager.changed_files(checkpoint).unwrap_or_default()
            }
            _ => Vec::new(),
        };
    }

    fn toggle_checkpoint_panel(&mut self, cx: &mut Context<Self>) {
        self.show_checkpoint_panel = !self.show_checkpoint_panel;
        cx.notify();
    }

    fn keep_checkpoint_file(&mut self, path: String, cx: &mut Context<Self>) {
        keep_change_by_path(&mut self.checkpoint_changes, &path);
        cx.notify();
    }

    fn restore_checkpoint_file(&mut self, path: String, cx: &mut Context<Self>) {
        let Some(checkpoint) = self.last_checkpoint.clone() else {
            return;
        };
        let Some(manager) = &self.checkpoint_manager else {
            return;
        };
        if !manager.is_valid(&checkpoint).unwrap_or(false) {
            self.status = "checkpoint 已失配（HEAD 有变化），请重新初始化".to_string();
            cx.notify();
            return;
        }
        match manager.restore_file(&checkpoint, &path) {
            Ok(()) => {
                self.status = format!("已回退 {path}");
                self.refresh_checkpoint_changes();
            }
            Err(error) => self.status = format!("回退失败：{error}"),
        }
        cx.notify();
    }

    /// 切换到指定 provider 的指定模型；模型变化时换新 thread。
    fn select_model(&mut self, provider_id: String, model_id: String, cx: &mut Context<Self>) {
        self.host.set_selected_model(SelectedModel::new(
            ProviderId::new(provider_id.clone()),
            cgc_agent_provider::ModelId::new(model_id.clone()),
        ));
        let Some(provider) = self
            .providers
            .iter()
            .find(|provider| provider.id == provider_id)
            .cloned()
        else {
            return;
        };
        let api_key = self
            .keychain
            .as_ref()
            .and_then(|keychain| keychain.load_secret(&provider_key_account(&provider.id)));
        let model_config = provider.model_config(&model_id);
        let model = Model::new(
            ProviderId::new(provider.id.clone()),
            provider.name.clone(),
            model_id.clone(),
            model_id,
            ModelLimits::new(model_config.context_window, model_config.max_output_tokens),
        );
        self.provider = match api_key.filter(|key| !key.is_empty()) {
            Some(api_key) => Arc::new(OpenAiCompatibleProvider::new(OpenAiCompatibleConfig::new(
                provider.base_url.clone(),
                api_key,
                vec![model.clone()],
            ))),
            None => Arc::new(EchoProvider::new(model.clone())),
        };
        let changed = self.model != model;
        self.model = model;
        if changed {
            if let Some(agent) = &mut self.agent {
                agent.replace_thread(Thread::new(
                    format!("native-demo-{}", now_secs()),
                    SelectedModel::new(self.model.provider_id.clone(), self.model.id.clone()),
                ));
            }
            self.rebuild_state_from_thread();
        }
        let store = PrefsStore::new(AppPaths::from_env().agent_prefs_file());
        let mut prefs = store.load();
        prefs.selected_provider = Some(provider.id);
        prefs.selected_model = Some(SelectedModel::new(
            self.model.provider_id.clone(),
            self.model.id.clone(),
        ));
        let _ = store.save(&prefs);
        self.status = format!("模型：{}", self.model.id.as_str());
        cx.notify();
    }

    fn mention_matches(&self, query: &str) -> Vec<String> {
        mention_matches(&self.workspace_files, query)
    }

    fn insert_mention(&mut self, path: String, window: &mut Window, cx: &mut Context<Self>) {
        let value = self.input.read(cx).value().to_string();
        if let Some((position, _)) = trailing_mention(&value) {
            let mention = Mention::File { path };
            self.insert_mention_chip(mention, &value[..position], window, cx);
        }
        self.mention_index = 0;
        cx.notify();
    }

    fn insert_skill_mention(
        &mut self,
        skill: SkillEntry,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let mention = Mention::skill(&skill);
        self.insert_mention_chip(mention, "", window, cx);
        self.slash_dismissed = true;
        self.slash_index = 0;
        cx.notify();
    }

    /// 把 mention 作为原子 chip 写进输入框（链接文本 + inline token），光标落到末尾。
    fn insert_mention_chip(
        &mut self,
        mention: Mention,
        prefix: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let content = mention.content_at(prefix, " ");
        let text = content.text().to_string();
        let end = Position::new(
            text.matches('\n').count() as u32,
            text.rsplit('\n').next().unwrap_or_default().chars().count() as u32,
        );
        self.input.update(cx, |state, cx| {
            state.set_value(content, window, cx);
            state.set_cursor_position(end, window, cx);
        });
        self.mention_index = 0;
        cx.notify();
    }

    fn slash_entries(&self, value: &str) -> Vec<SlashEntry> {
        slash_entries_for(self.registry.as_ref(), &self.skills, value)
    }

    fn run_slash_entry(
        &mut self,
        entries: Vec<SlashEntry>,
        index: usize,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(entry) = entries.get(index) else {
            return;
        };
        if let Some(tool) = entry.tool.clone() {
            let text = format!("使用 {tool} 工具：");
            self.input
                .update(cx, |state, cx| state.set_value(text.clone(), window, cx));
            self.slash_dismissed = true;
            self.slash_index = 0;
            cx.notify();
            return;
        }
        if let Some(skill) = entry.skill.clone() {
            self.insert_skill_mention(skill, window, cx);
            return;
        }
        self.run_slash_command(&entry.label, window, cx);
    }

    fn run_slash_command(&mut self, command: &str, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(command) = parse_slash(command) {
            self.handle_slash(command, cx);
        }
        self.input
            .update(cx, |state, cx| state.set_value("", window, cx));
        self.slash_index = 0;
        self.slash_dismissed = false;
        cx.notify();
    }

    /// 进入某条用户消息的行内编辑态（预填展示文本）。
    fn begin_edit_user(
        &mut self,
        message_index: usize,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.busy {
            self.status = "生成中，稍后再编辑".to_string();
            cx.notify();
            return;
        }
        let Some(ConversationEntry::User { text }) = self.state.thread.entries.get(message_index)
        else {
            return;
        };
        let text = text.clone();
        let skills = self.skills.clone();
        let input = cx.new(|cx| {
            let mut state = TextareaState::new(window, cx).auto_grow(1, 8);
            let content = mention::content_with_mentions(&text, |scope, name| {
                skills
                    .iter()
                    .find(|skill| skill.name == name && skill.scope == scope)
                    .map(|skill| skill.file_path.clone())
            });
            state.set_value(content, window, cx);
            state
        });
        self.pending_restart_confirm = None;
        self.user_edit_input = Some(input);
        self.editing_user = Some(message_index);
        cx.notify();
    }

    fn cancel_edit_user(&mut self, cx: &mut Context<Self>) {
        self.editing_user = None;
        self.user_edit_input = None;
        self.pending_restart_confirm = None;
        cx.notify();
    }

    /// 从某条用户消息重发（Zed 的 restart from this point）：回滚 checkpoint、
    /// 截断线程到该消息之前，然后用编辑后的文本重跑这一轮。
    fn restart_from_user_message(&mut self, message_index: usize, cx: &mut Context<Self>) {
        if self.busy {
            self.status = "生成中，稍后再试".to_string();
            cx.notify();
            return;
        }
        let Some(input) = self.user_edit_input.clone() else {
            return;
        };
        let content = input.read(cx).content();
        let edited_display = content.text().trim().to_string();
        if edited_display.is_empty() {
            self.status = "消息不能为空".to_string();
            cx.notify();
            return;
        }
        let edited_prompt = mention::resolve_prompt(&content, self.context.workspace());
        let Some(ordinal) = thread_entry_ordinal(&self.state.thread.entries, message_index) else {
            return;
        };
        let has_valid_checkpoint = self
            .available_checkpoints
            .iter()
            .find(|(candidate, _)| *candidate == ordinal)
            .map(|(_, checkpoint)| {
                self.checkpoint_manager
                    .as_ref()
                    .and_then(|manager| manager.is_valid(checkpoint).ok())
                    .unwrap_or(false)
            })
            .unwrap_or(false);
        if needs_checkpoint_confirm(
            has_valid_checkpoint,
            self.pending_restart_confirm,
            message_index,
        ) {
            self.pending_restart_confirm = Some(message_index);
            cx.notify();
            return;
        }
        self.pending_restart_confirm = None;
        let Some(agent) = self.agent.as_mut() else {
            return;
        };
        let thread_id = agent.thread().id.clone();
        let Some(entry_index) = thread_user_entry_index(&agent.thread().entries, ordinal) else {
            self.status = "找不到对应的线程消息".to_string();
            cx.notify();
            return;
        };
        // checkpoint 回滚（尽力而为；失败只提示，不阻断重发）。
        let mut note = String::new();
        if let (Some(manager), Some(store)) =
            (&self.checkpoint_manager, self.session_store.session())
        {
            if let Ok(records) = store.list_checkpoints(&thread_id) {
                if let Some(record) = checkpoint_for_ordinal(&records, ordinal) {
                    let checkpoint = Checkpoint {
                        thread_id: record.thread_id,
                        seq: record.user_entry_seq.max(0) as u64,
                        ref_name: record.ref_name,
                        sha: record.sha,
                        base_head: record.base_head,
                    };
                    match manager.is_valid(&checkpoint) {
                        Ok(true) => match manager.restore(&checkpoint) {
                            Ok(()) => note = " · 已回滚到该消息的 checkpoint".to_string(),
                            Err(error) => note = format!(" · checkpoint 回滚失败：{error}"),
                        },
                        Ok(false) => note = " · checkpoint 已失配，未回滚文件".to_string(),
                        Err(error) => note = format!(" · checkpoint 校验失败：{error}"),
                    }
                }
            }
        }
        agent.thread_mut().entries.truncate(entry_index);
        self.editing_user = None;
        self.user_edit_input = None;
        self.rebuild_state_from_thread();
        self.invalidate_checkpoints_from(ordinal + 1, &thread_id);
        // 截断到空历史时 rebuild 会补一条引导提示；重发场景不需要它。
        self.state.thread.entries.retain(|entry| {
            !matches!(entry, ConversationEntry::Notice { text, .. } if text == EMPTY_THREAD_NOTICE)
        });
        self.state.thread.apply(ThreadEvent::TurnStarted {
            user_text: edited_display.clone(),
        });
        self.state.last_error = None;
        self.last_turn = Some((edited_prompt.clone(), edited_display.clone()));
        let ordinal = self
            .state
            .thread
            .entries
            .iter()
            .filter(|entry| matches!(entry, ConversationEntry::User { .. }))
            .count();
        self.capture_checkpoint(&thread_id, ordinal);
        self.status = format!("从该消息重发{note}");
        self.run_turn(edited_prompt, edited_display, true, cx);
    }

    /// 编辑态行内编辑器。
    fn render_user_edit_row(
        &self,
        message_index: usize,
        palette: &theme::Palette,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let Some(input) = self.user_edit_input.clone() else {
            return div().into_any_element();
        };
        let view = cx.entity().downgrade();
        let cancel_view = view.clone();
        let resend_view = view.clone();
        let confirm_cancel_view = view.clone();
        let confirm_resend_view = view;
        shared_render_user_edit_row(UserEditRowSpec {
            input,
            cancel_id: SharedString::from("native-user-edit-cancel"),
            resend_id: SharedString::from("native-user-edit-resend"),
            confirm_cancel_id: SharedString::from("native-restart-cancel"),
            confirm_resend_id: SharedString::from("native-restart-confirm"),
            pending_confirm: user_edit_confirm_visible(self.pending_restart_confirm, message_index),
            style: native_row_palette(palette),
            on_cancel: Box::new(move |cx| {
                let _ = cancel_view.update(cx, |this, cx| this.cancel_edit_user(cx));
            }),
            on_resend: Box::new(move |cx| {
                let _ = resend_view.update(cx, |this, cx| {
                    this.restart_from_user_message(message_index, cx)
                });
            }),
            on_confirm_cancel: Box::new(move |cx| {
                let _ = confirm_cancel_view.update(cx, |this, cx| {
                    this.pending_restart_confirm = None;
                    cx.notify();
                });
            }),
            on_confirm_resend: Box::new(move |cx| {
                let _ = confirm_resend_view.update(cx, |this, cx| {
                    this.restart_from_user_message(message_index, cx)
                });
            }),
        })
    }

    /// 展开/折叠一条思考块。
    fn toggle_thinking(&mut self, message_index: usize, cx: &mut Context<Self>) {
        if !self.expanded_thinking.remove(&message_index) {
            self.expanded_thinking.insert(message_index);
        }
        cx.notify();
    }

    /// 展开/折叠某张工具调用卡片。
    fn toggle_tool_call(&mut self, tool_call_id: String, cx: &mut Context<Self>) {
        if !self.expanded_tools.remove(&tool_call_id) {
            self.expanded_tools.insert(tool_call_id);
        }
        cx.notify();
    }

    /// 当前滚动位置是否已在底部。
    /// 消息区滚动到顶部（同时停止自动跟随输出）。
    fn scroll_messages_to_top(&mut self, cx: &mut Context<Self>) {
        self.message_scroller.update(cx, |state, cx| {
            let _ = state.scroll_to_item(0, cx);
        });
        cx.notify();
    }

    /// 回到最新：恢复 tail 跟随并滚到列表末尾。
    fn scroll_messages_to_bottom(&mut self, cx: &mut Context<Self>) {
        self.message_scroller
            .update(cx, |state, cx| state.scroll_to_end(cx));
        cx.notify();
    }

    fn set_thinking_enabled(&mut self, enabled: bool, cx: &mut Context<Self>) {
        self.thinking_enabled = enabled;
        self.status = if enabled {
            "Thinking 开".to_string()
        } else {
            "Thinking 关".to_string()
        };
        cx.notify();
    }

    fn insert_context_marker(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let current = self.input.read(cx).value().to_string();
        let next = if current.trim().is_empty() {
            "@".to_string()
        } else if current.ends_with(char::is_whitespace) {
            format!("{current}@")
        } else {
            format!("{current} @")
        };
        self.input
            .update(cx, |state, cx| state.set_value(next, window, cx));
        self.status = "输入 @ 引用工作区文件".to_string();
        cx.notify();
    }

    fn set_effort_index(&mut self, index: usize, cx: &mut Context<Self>) {
        self.effort_index = index;
        self.status = format!("推理档位索引：{index}");
        cx.notify();
    }

    fn set_approval_mode(&mut self, mode: ApprovalMode, cx: &mut Context<Self>) {
        self.approval_mode = mode;
        self.status = format!("审批模式：{}", mode.label());
        cx.notify();
    }

    /// Agent Panel 里点「新对话」：开一个新的 native 会话（不动外部 ACP 会话）。
    pub fn start_new_thread(&mut self, cx: &mut Context<Self>) {
        if self.busy {
            return;
        }
        let thread_id = scope_thread_id(&self.scope);
        let model = self.model.clone();
        if let Some(agent) = &mut self.agent {
            agent.replace_thread(Thread::new(
                thread_id.clone(),
                SelectedModel::new(model.provider_id.clone(), model.id.clone()),
            ));
        }
        // 新会话复用 scope 线程 id，旧 checkpoint 记录必须作废。
        for (ordinal, _) in &self.available_checkpoints {
            let _ = self
                .session_store
                .mark_checkpoint_invalid(&thread_id, *ordinal as i64);
        }
        if let (Some(store), Some(agent)) = (self.session_store.session_mut(), &self.agent) {
            let _ = store.save_thread(agent.thread());
        }
        self.state = NativeThreadState::new();
        self.state
            .push_notice("Native agent：新对话，配置 Provider 后开始。");
        self.last_checkpoint = None;
        self.available_checkpoints.clear();
        self.checkpoint_changes.clear();
        self.show_checkpoint_panel = false;
        self.pending_restart_confirm = None;
        self.status = "新对话".to_string();
        cx.notify();
    }

    /// 渲染前同步全局 scope；变化时切换工作区与线程。
    fn ensure_scope(&mut self, cx: &mut Context<Self>) {
        if self.busy {
            return;
        }
        let Some(current) = crate::agent_scope::current() else {
            return;
        };
        if current == self.scope {
            return;
        }
        self.switch_scope(current, cx);
    }

    fn action_sink_for(&self) -> ActionSink {
        let app_actions = self.app_actions.clone();
        Arc::new(move |action: AppAction| {
            if let Ok(mut actions) = app_actions.lock() {
                actions.push(action);
            }
        })
    }

    fn build_registry_for(&self, workspace: &std::path::Path) -> Arc<ToolRegistry> {
        let provider = self.provider.clone();
        let model = self.model.clone();
        let workspace = workspace.to_path_buf();
        let subagent_runner: SubagentRunner =
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
            });
        let subagent_tx = self.subagent_tx.clone();
        let subagent_sink: SubagentEventSink = Arc::new(move |event: SubagentEvent| {
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
        });
        let mut registry = ToolRegistry::with_agent_state(self.host.agent_state.clone())
            .with_app_actions()
            .with_subagent(subagent_runner, subagent_sink);
        let _mcp_tools =
            crate::native_panel_host::register_mcp_tools_for_host(&mut registry, &self.host);
        Arc::new(registry)
    }

    /// 切换工作区 scope：保存当前线程，载入目标 scope 的线程并重建运行时。
    fn switch_scope(&mut self, scope: crate::agent_scope::AgentScope, cx: &mut Context<Self>) {
        if let (Some(store), Some(agent)) = (self.session_store.session_mut(), &self.agent) {
            let _ = store.save_thread(agent.thread());
        }
        let root = scope.root.clone();
        let thread_id = scope_thread_id(&scope);
        let selected = SelectedModel::new(self.model.provider_id.clone(), self.model.id.clone());
        let thread = self
            .session_store
            .load_thread(&thread_id)
            .filter(|thread| thread.model == selected)
            .unwrap_or_else(|| Thread::new(thread_id.clone(), selected));
        let mut state = NativeThreadState::new();
        let restored_images = apply_thread_entries(&mut state, &thread.entries);
        state.usage_total = thread.usage_total;
        state.thread.thread_id = thread.id.clone();
        state.set_context_size(self.model_context_size());
        state.thread.usage = Usage {
            used: thread.usage_total.total(),
            size: self.model_context_size(),
            cost: None,
        };
        if state.thread.entries.is_empty() {
            if let Some(notice) = offline_echo_notice(self.using_echo) {
                state.push_notice(notice);
            }
        }
        self.state = state;
        self.sent_images = restored_images;
        self.workspace_files = collect_workspace_files(&root);
        self.skills = mention::load_skills(&root);
        self.scope = scope;
        self.checkpoint_manager = CheckpointManager::open(&root)
            .or_else(|_| CheckpointManager::initialize(&root))
            .ok();
        self.context = ToolContext::new(&root)
            .with_sandbox(SandboxPolicy::new(&root))
            .with_action_sink(self.action_sink_for());
        self.agent = Some(Agent::new(
            thread,
            Some(build_workspace_system_prompt(&root)),
        ));
        self.registry = self.build_registry_for(&root);
        self.expanded_tools.clear();
        self.expanded_thinking.clear();
        self.editing_user = None;
        self.user_edit_input = None;
        self.last_turn = None;
        self.queued_messages.clear();
        self.checkpoint_changes.clear();
        self.show_checkpoint_panel = false;
        self.pending_restart_confirm = None;
        self.checkpoint_notice_reported = false;
        self.available_checkpoints.clear();
        self.last_checkpoint = None;
        self.pending_images.clear();
        self.busy = false;
        self.status = format!("已切换工作区：{}", root.display());
        self.reload_thread_checkpoints();
        cx.notify();
    }

    /// 从 SQLite 拉取当前 scope 线程的最新内容，保持内联/独立窗口共享同一份历史。
    fn reload_latest_session(&mut self) {
        let Some(agent) = &self.agent else {
            return;
        };
        let Some(store) = self.session_store.session() else {
            return;
        };
        let thread_id = agent.thread().id.clone();
        let Ok(Some(loaded)) = store.load_thread(&thread_id) else {
            return;
        };
        if loaded.model != agent.thread().model || &loaded == agent.thread() {
            return;
        }
        if loaded.updated_at < agent.thread().updated_at {
            return;
        }
        if let Some(agent) = &mut self.agent {
            agent.replace_thread(loaded);
        }
        self.rebuild_state_from_thread();
    }

    fn rebuild_state_from_thread(&mut self) {
        let Some(agent) = &self.agent else {
            return;
        };
        let thread = agent.thread();
        let mut state = NativeThreadState::new();
        state.usage_total = thread.usage_total;
        let restored_images = apply_thread_entries(&mut state, &thread.entries);
        state.thread.thread_id = thread.id.clone();
        state.set_context_size(self.model_context_size());
        state.thread.usage = Usage {
            used: thread.usage_total.total(),
            size: self.model_context_size(),
            cost: None,
        };
        if state.thread.entries.is_empty() {
            state.push_notice(EMPTY_THREAD_NOTICE);
        }
        self.state = state;
        self.sent_images = restored_images;
    }

    /// 为第 `ordinal` 条用户消息（1-based）拍 checkpoint 并持久化。
    /// 用消息 ordinal 而不是进程内计数器作 key：重启/恢复线程后仍能对上。
    fn capture_checkpoint(&mut self, thread_id: &str, ordinal: usize) {
        let Some(manager) = &self.checkpoint_manager else {
            if !self.checkpoint_notice_reported {
                self.checkpoint_notice_reported = true;
                self.state
                    .push_notice("当前工作区不是 git 仓库：检查点不可用，本轮文件改动将无法回滚。");
            }
            return;
        };
        match manager.snapshot(thread_id, ordinal as u64) {
            Ok(checkpoint) => {
                let _ = self
                    .session_store
                    .save_checkpoint(&checkpoint, ordinal as i64, now_secs());
                self.last_checkpoint = Some(checkpoint.clone());
                self.available_checkpoints
                    .retain(|(existing, _)| *existing != ordinal);
                self.available_checkpoints.push((ordinal, checkpoint));
                self.available_checkpoints
                    .sort_by_key(|(ordinal, _)| *ordinal);
            }
            Err(error) => {
                self.status = format!("checkpoint 失败：{error}");
                if !self.checkpoint_notice_reported {
                    self.checkpoint_notice_reported = true;
                    self.state
                        .push_notice(format!("本轮未创建检查点：{error}（文件改动将无法回滚）"));
                }
            }
        }
    }

    /// 从持久化存储重载当前线程的 checkpoint 列表。
    fn reload_thread_checkpoints(&mut self) {
        self.available_checkpoints.clear();
        self.last_checkpoint = None;
        let Some(agent) = self.agent.as_ref() else {
            return;
        };
        if !self.session_store.is_available() {
            return;
        }
        let thread_id = agent.thread().id.clone();
        let records = self.session_store.list_checkpoints(&thread_id);
        self.available_checkpoints = checkpoints_from_records(&records);
        self.last_checkpoint = self
            .available_checkpoints
            .last()
            .map(|(_, checkpoint)| checkpoint.clone());
        self.refresh_checkpoint_changes();
    }

    /// 某条 UI 消息可用的 checkpoint（用户消息 ordinal 对应）。
    fn checkpoint_for_message(&self, message_index: usize) -> Option<Checkpoint> {
        // 渲染行与模型 entries 1:1，优先用模型 ordinal；旧路径作为兜底。
        let ordinal = thread_entry_ordinal(&self.state.thread.entries, message_index)?;
        self.available_checkpoints
            .iter()
            .find(|(candidate, _)| *candidate == ordinal)
            .map(|(_, checkpoint)| checkpoint.clone())
    }

    /// 会话回退后，把 `ordinal >= from_ordinal` 的 checkpoint 标记失效。
    fn invalidate_checkpoints_from(&mut self, from_ordinal: usize, thread_id: &str) {
        if let Some(store) = self.session_store.session_mut() {
            for (ordinal, _) in self
                .available_checkpoints
                .iter()
                .filter(|(ordinal, _)| *ordinal >= from_ordinal)
            {
                let _ = store.mark_checkpoint_invalid(thread_id, *ordinal as i64);
            }
        }
        self.available_checkpoints
            .retain(|(ordinal, _)| *ordinal < from_ordinal);
        self.last_checkpoint = self
            .available_checkpoints
            .last()
            .map(|(_, checkpoint)| checkpoint.clone());
        self.refresh_checkpoint_changes();
    }

    /// Zed 的 Restore Checkpoint：回退工作区文件，并把会话截断到该消息之前。
    fn restore_to_checkpoint(&mut self, message_index: usize, cx: &mut Context<Self>) {
        if self.busy {
            self.status = "生成中，稍后再恢复".to_string();
            cx.notify();
            return;
        }
        let Some(checkpoint) = self.checkpoint_for_message(message_index) else {
            return;
        };
        let Some(ordinal) = thread_entry_ordinal(&self.state.thread.entries, message_index) else {
            return;
        };
        let Some(manager) = &self.checkpoint_manager else {
            self.status = "当前工作区没有 checkpoint 能力".to_string();
            cx.notify();
            return;
        };
        match manager.is_valid(&checkpoint) {
            Ok(true) => {}
            Ok(false) => {
                if let (Some(store), Some(agent)) = (self.session_store.session_mut(), &self.agent)
                {
                    let _ = store.mark_checkpoint_invalid(&agent.thread().id, ordinal as i64);
                }
                self.reload_thread_checkpoints();
                self.status = "检查点已失效（工作区 HEAD 已变化）".to_string();
                cx.notify();
                return;
            }
            Err(error) => {
                self.status = format!("检查点校验失败：{error}");
                cx.notify();
                return;
            }
        }
        if let Err(error) = manager.restore(&checkpoint) {
            self.status = format!("回退失败：{error}");
            cx.notify();
            return;
        }
        let Some(agent) = self.agent.as_mut() else {
            return;
        };
        let thread_id = agent.thread().id.clone();
        if let Some(entry_index) = thread_user_entry_index(&agent.thread().entries, ordinal) {
            agent.thread_mut().entries.truncate(entry_index);
        }
        if let Some(store) = self.session_store.session_mut() {
            let _ = store.save_thread(agent.thread());
        }
        self.editing_user = None;
        self.user_edit_input = None;
        self.rebuild_state_from_thread();
        self.state.thread.entries.retain(|entry| {
            !matches!(entry, ConversationEntry::Notice { text, .. } if text == EMPTY_THREAD_NOTICE)
        });
        self.invalidate_checkpoints_from(ordinal, &thread_id);
        self.state
            .push_notice("已恢复检查点：文件已回退，可以从这里重新发送消息");
        self.status = "已恢复检查点".to_string();
        cx.notify();
    }

    fn undo_checkpoint(&mut self, cx: &mut Context<Self>) {
        let Some(checkpoint) = self.last_checkpoint.clone() else {
            return;
        };
        let Some(manager) = &self.checkpoint_manager else {
            return;
        };
        if !manager.is_valid(&checkpoint).unwrap_or(false) {
            self.status = "checkpoint 已失配（HEAD 有变化），请重新初始化".to_string();
            cx.notify();
            return;
        }
        match manager.restore(&checkpoint) {
            Ok(()) => {
                self.last_checkpoint = None;
                self.status = "已回退到本轮前".to_string();
            }
            Err(error) => self.status = format!("回退失败：{error}"),
        }
        cx.notify();
    }

    /// 共享权限卡的按钮回调：按 ACP `option_id` 精确回传，随后按共享模型把
    /// Permission 行标记 resolved（不再经过 native 专属 ApprovalDecision）。
    fn resolve_permission_option(&mut self, option_id: &str, cx: &mut Context<Self>) {
        self.state.sync_pending_permission();
        let Some(pending) = self.state.thread.pending_permission.clone() else {
            return;
        };
        let allowed = agent_ingest::permission_option_allowed(&pending.options, option_id);
        if let Some(host) = &self.host.acp_host {
            let _ = host.respond_permission_option(&pending.request_id, option_id);
        }
        self.state.resolve_permission(&pending.request_id);
        agent_ingest::apply_permission_resolved(
            &mut self.state.thread,
            pending.request_id,
            allowed,
        );
        cx.notify();
    }
}

impl NativeAgentView {
    /// 当前是否在跑一个回合。`busy` 在结果回调里落回 false，但事件队列可能还没
    fn is_generating(&self) -> bool {
        self.busy || self.state.thread.is_generating()
    }

    /// Phase B2b-3b：native composer 的 legacy 渲染（render 内联链纯搬迁，行为不变）。
    /// Phase B2b-3d-2a：slash 菜单（legacy 与 shared composer 共用）。
    fn render_slash_menu(&mut self, cx: &mut Context<Self>) -> Option<AnyElement> {
        let input_value = self.input.read(cx).value().to_string();
        let slash_open = input_value.trim_start().starts_with('/') && !self.slash_dismissed;
        let slash_matches = self.slash_entries(&input_value);
        let slash_selected = self.slash_index.min(slash_matches.len().saturating_sub(1));
        if !(slash_open && !slash_matches.is_empty()) {
            return None;
        }
        let palette = theme::palette_from_theme(cx);
        let items: Vec<CommandMenuItem> = slash_matches
            .iter()
            .enumerate()
            .map(|(index, entry)| CommandMenuItem {
                id: SharedString::from(format!("native-slash-{index}")),
                label: entry.label.clone(),
                description: entry.description.clone(),
                scope: entry.scope.clone(),
                group: entry.category.to_string(),
                selected: index == slash_selected,
            })
            .collect();
        let entries = slash_matches.clone();
        let hover_root = cx.entity().downgrade();
        let click_root = cx.entity().downgrade();
        let menu = render_command_menu(CommandMenuSpec {
            menu_id: SharedString::from("native-agent-slash-menu"),
            items,
            style: native_command_menu_style(palette),
            label_width: 150.0,
            width: Some(300.0),
            max_height: 320.0,
            row_height: None,
            on_hover: Some(Box::new(move |index, cx| {
                let _ = hover_root.update(cx, |this, cx| {
                    if this.slash_index != index {
                        this.slash_index = index;
                        cx.notify();
                    }
                });
            })),
            on_click: Box::new(move |index, window, cx| {
                let _ = click_root.update(cx, |this, cx| {
                    this.run_slash_entry(entries.clone(), index, window, cx);
                });
            }),
        });
        let detail = slash_matches.get(slash_selected).map(|entry| {
            div()
                .id("native-slash-detail")
                .w(px(280.0))
                .flex_1()
                .min_w(px(0.0))
                .max_h(px(320.0))
                .overflow_y_scroll()
                .p(space(1))
                .mt(space(1))
                .rounded(px(RADIUS_SMALL))
                .border_1()
                .border_color(palette.line)
                .bg(palette.view)
                .child(
                    div()
                        .text_size(px(9.0))
                        .text_color(palette.ink_3)
                        .child(entry.category),
                )
                .child(
                    div()
                        .flex()
                        .flex_row()
                        .items_center()
                        .gap(space(1))
                        .child(
                            div()
                                .text_size(px(11.0))
                                .text_color(palette.ink)
                                .child(entry.label.clone()),
                        )
                        .children(entry.scope.clone().map(|scope| {
                            div()
                                .text_size(px(9.0))
                                .text_color(palette.ink_3)
                                .child(scope)
                        })),
                )
                .child(
                    div()
                        .line_height(px(16.0))
                        .text_size(px(10.0))
                        .text_color(palette.ink_3)
                        .child(entry.description.clone()),
                )
        });
        let element = div()
            .absolute()
            .left(space(1))
            .right(space(1))
            .bottom(px(132.0))
            .flex()
            .flex_row()
            .items_start()
            .gap(space(2))
            .child(
                div()
                    .flex_none()
                    .mx(space(1))
                    .mt(space(1))
                    .mb(px(2.0))
                    .child(menu),
            )
            .children(detail);
        Some(element.into_any_element())
    }

    /// Phase B2b-3d-2b：@mention 菜单（legacy 与 shared composer 共用）。
    fn render_mention_menu(&mut self, cx: &mut Context<Self>) -> Option<AnyElement> {
        let input_value = self.input.read(cx).value().to_string();
        let mention = trailing_mention(&input_value);
        let mention_matches = mention
            .as_ref()
            .map(|(_, query)| self.mention_matches(query))
            .unwrap_or_default();
        let slash_open = input_value.trim_start().starts_with('/') && !self.slash_dismissed;
        if !(mention.is_some() && !slash_open && !mention_matches.is_empty()) {
            return None;
        }
        let mention_selected = self
            .mention_index
            .min(mention_matches.len().saturating_sub(1));
        let palette = theme::palette_from_theme(cx);
        let query = mention
            .as_ref()
            .map(|(_, query)| query.clone())
            .unwrap_or_default();
        let element = div()
            .id("native-agent-mention-menu")
            .flex()
            .flex_col()
            .gap(px(1.0))
            .mx(space(1))
            .mt(space(1))
            .mb(px(2.0))
            .rounded(px(RADIUS_SMALL))
            .border_1()
            .border_color(palette.line)
            .bg(palette.card)
            .occlude()
            .child(
                div()
                    .px(space(1))
                    .py(px(2.0))
                    .text_size(px(9.0))
                    .text_color(palette.ink_3)
                    .child(format!("@{query} 匹配文件")),
            )
            .children(mention_matches.iter().enumerate().map(|(index, path)| {
                let selected = index == mention_selected;
                let path = path.clone();
                div()
                    .id(SharedString::from(format!("native-mention-{index}")))
                    .role(Role::Button)
                    .aria_label(path.clone())
                    .px(space(1))
                    .py(px(3.0))
                    .rounded(px(RADIUS_SMALL))
                    .bg(if selected { palette.soft } else { palette.card })
                    .text_size(px(11.0))
                    .text_color(if selected {
                        palette.accent
                    } else {
                        palette.ink_2
                    })
                    .child(path.clone())
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.insert_mention(path.clone(), window, cx);
                    }))
            }))
            .into_any_element();
        Some(element)
    }

    /// Phase B2b-3c/3d：native 主 composer 的共享版（flag=1 时使用）。
    /// 共享 send/stop + 附件 chips + attach + slash/mention 菜单 + queue 提示；
    /// context chip 为 ACP 面板能力，native 本就没有，不在此渲染。
    /// B3a：native 模型 / 推理强度 / 审批模式 picker（legacy 与 shared composer 共用）。
    /// capability gated：config options 不可用时三个 picker 都不渲染。
    fn native_composer_pickers(
        &self,
        palette: theme::Palette,
        cx: &mut Context<Self>,
    ) -> NativeComposerPickers {
        let gating = NativeComposerGating::from_capabilities(self.state.thread.capabilities);
        if !gating.pickers_available() {
            return NativeComposerPickers::default();
        }
        let current_provider_id = self.model.provider_id.as_str().to_string();
        let current_model_id = self.model.id.as_str().to_string();
        let current_model_config = self
            .providers
            .iter()
            .find(|provider| provider.id == self.model.provider_id.as_str())
            .map(|provider| provider.model_config(self.model.id.as_str()))
            .unwrap_or_default();
        let thinking_supported = current_model_config.supports_thinking;
        let effort_levels = current_model_config.reasoning_efforts.clone();
        let providers_for_menu = self.providers.clone();
        let model_root = cx.entity().downgrade();
        let thinking_root = cx.entity().downgrade();
        let approval_root = cx.entity().downgrade();
        let model_id_for_label = current_model_id.clone();
        let model_groups: Vec<PickerGroup> = providers_for_menu
            .iter()
            .filter_map(|provider| {
                let items: Vec<PickerItem> = provider
                    .models
                    .iter()
                    .filter(|model| provider.model_config(model).enabled)
                    .map(|model| {
                        PickerItem::new(
                            format!("native-model-{}-{}", provider.id, model),
                            model.clone(),
                        )
                        .selected(provider.id == current_provider_id && *model == current_model_id)
                    })
                    .collect();
                (!items.is_empty()).then(|| PickerGroup::titled(provider.name.clone(), items))
            })
            .collect();
        let model_targets: Vec<(String, String)> = providers_for_menu
            .iter()
            .flat_map(|provider| {
                provider
                    .models
                    .iter()
                    .filter(|model| provider.model_config(model).enabled)
                    .map(|model| (provider.id.clone(), model.clone()))
                    .collect::<Vec<_>>()
            })
            .collect();
        let model_picker = render_picker_popover(PickerPopoverSpec {
            popover_id: SharedString::from("native-model-picker"),
            trigger_id: SharedString::from("native-model-trigger"),
            trigger_label: model_id_for_label,
            trigger_tooltip: "选择模型".to_string(),
            trigger_max_width: None,
            anchor: Some(Anchor::BottomRight),
            groups: model_groups,
            style: native_picker_style(palette),
            width: 240.0,
            list_max_height: Some(280.0),
            search: None,
            on_select: Box::new(move |index, _window, cx| {
                let Some((provider_id, model_id)) = model_targets.get(index).cloned() else {
                    return;
                };
                let _ = model_root.update(cx, |this, cx| {
                    this.select_model(provider_id, model_id, cx);
                });
            }),
        });
        let current_effort = self.effort_index.min(effort_levels.len().saturating_sub(1));
        let thinking_enabled = self.thinking_enabled;
        let thinking_label = if thinking_supported {
            if thinking_enabled {
                effort_levels
                    .get(current_effort)
                    .map(String::as_str)
                    .unwrap_or("Thinking")
            } else {
                "Off"
            }
        } else {
            "推理 —"
        };
        let effort_picker = (thinking_supported && !effort_levels.is_empty()).then(|| {
            let levels_len = effort_levels.len();
            let mut items: Vec<PickerItem> = effort_levels
                .iter()
                .enumerate()
                .map(|(level_index, label)| {
                    PickerItem::new(format!("native-thinking-{label}"), label.clone())
                        .selected(thinking_enabled && level_index == current_effort)
                })
                .collect();
            items.push(PickerItem::new("native-thinking-off", "Off").selected(!thinking_enabled));
            let root = thinking_root.clone();
            render_picker_popover(PickerPopoverSpec {
                popover_id: SharedString::from("native-thinking-picker"),
                trigger_id: SharedString::from("native-thinking-trigger"),
                trigger_label: thinking_label.to_string(),
                trigger_tooltip: "推理强度".to_string(),
                trigger_max_width: None,
                anchor: Some(Anchor::BottomRight),
                groups: vec![PickerGroup::flat(items)],
                style: native_picker_style(palette),
                width: 160.0,
                list_max_height: None,
                search: None,
                on_select: Box::new(move |index, _window, cx| {
                    let _ = root.update(cx, |this, cx| {
                        if index < levels_len {
                            if !this.thinking_enabled {
                                this.set_thinking_enabled(true, cx);
                            }
                            this.set_effort_index(index, cx);
                        } else {
                            this.set_thinking_enabled(false, cx);
                        }
                    });
                }),
            })
        });
        let current_approval = self.approval_mode;
        let approval_picker = {
            let modes = [ApprovalMode::Ask, ApprovalMode::Auto];
            let items: Vec<PickerItem> = modes
                .iter()
                .map(|mode| {
                    let label = match mode {
                        ApprovalMode::Ask => "Ask（逐次审批）",
                        ApprovalMode::Auto => "Auto（自动允许）",
                    };
                    PickerItem::new(format!("native-approval-{}", mode.label()), label)
                        .selected(*mode == current_approval)
                })
                .collect();
            let root = approval_root.clone();
            render_picker_popover(PickerPopoverSpec {
                popover_id: SharedString::from("native-approval-picker"),
                trigger_id: SharedString::from("native-approval-trigger"),
                trigger_label: current_approval.label().to_string(),
                trigger_tooltip: "审批模式".to_string(),
                trigger_max_width: None,
                anchor: Some(Anchor::BottomRight),
                groups: vec![PickerGroup::flat(items)],
                style: native_picker_style(palette),
                width: 200.0,
                list_max_height: None,
                search: None,
                on_select: Box::new(move |index, _window, cx| {
                    let Some(mode) = modes.get(index).copied() else {
                        return;
                    };
                    let _ = root.update(cx, |this, cx| {
                        this.set_approval_mode(mode, cx);
                    });
                }),
            })
        };
        NativeComposerPickers {
            model: Some(model_picker),
            thinking: effort_picker,
            approval: Some(approval_picker),
        }
    }

    /// B3b：本轮文件变更面板（capability gated，legacy/shared 视图共用同一渲染）。
    fn render_checkpoint_panel(
        &mut self,
        palette: theme::Palette,
        change_count: usize,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let changes = self.checkpoint_changes.clone();
        div()
            .id("native-agent-checkpoint-panel")
            .flex()
            .flex_col()
            .gap(space(1))
            .px(space(3))
            .py(space(2))
            .border_t_1()
            .border_color(palette.line)
            .bg(palette.view)
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap(space(1))
                    .child(
                        div()
                            .flex_1()
                            .text_size(px(12.0))
                            .child(format!("本轮文件变更（{change_count}）")),
                    )
                    .child(
                        div()
                            .id("native-keep-all")
                            .role(Role::Button)
                            .aria_label("全部保留")
                            .px(space(1))
                            .py(px(2.0))
                            .rounded(px(RADIUS_SMALL))
                            .text_size(px(10.0))
                            .text_color(palette.ink_2)
                            .hover(|style| style.bg(palette.soft))
                            .child("全部保留")
                            .on_click(
                                cx.listener(|this, _, _window, cx| this.keep_all_changes(cx)),
                            ),
                    )
                    .child(
                        div()
                            .id("native-reject-all")
                            .role(Role::Button)
                            .aria_label("全部回退")
                            .px(space(1))
                            .py(px(2.0))
                            .rounded(px(RADIUS_SMALL))
                            .text_size(px(10.0))
                            .text_color(palette.danger)
                            .hover(|style| style.bg(palette.soft))
                            .child("全部回退")
                            .on_click(
                                cx.listener(|this, _, _window, cx| this.reject_all_changes(cx)),
                            ),
                    ),
            )
            .children(changes.into_iter().map(|change| {
                let path = change.path.clone();
                let restore_path = change.path.clone();
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap(space(2))
                    .child(
                        div()
                            .flex_1()
                            .text_size(px(12.0))
                            .child(checkpoint_change_label(&change)),
                    )
                    .child(
                        div()
                            .id("checkpoint-keep")
                            .role(Role::Button)
                            .aria_label("保留")
                            .px(space(1))
                            .py(px(2.0))
                            .rounded(px(RADIUS_MEDIUM))
                            .bg(palette.soft)
                            .child("保留")
                            .on_click(cx.listener(move |this, _, _window, cx| {
                                this.keep_checkpoint_file(path.clone(), cx)
                            })),
                    )
                    .child(
                        div()
                            .id("checkpoint-restore")
                            .role(Role::Button)
                            .aria_label("回退")
                            .px(space(1))
                            .py(px(2.0))
                            .rounded(px(RADIUS_MEDIUM))
                            .bg(palette.accent)
                            .text_color(palette.canvas)
                            .child("回退")
                            .on_click(cx.listener(move |this, _, _window, cx| {
                                this.restore_checkpoint_file(restore_path.clone(), cx)
                            })),
                    )
            }))
            .into_any_element()
    }
}

impl Render for NativeAgentView {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        // 页面 scope 变化时先切换工作区/线程，再渲染。
        self.ensure_scope(cx);
        let _add_menu_root = cx.entity().downgrade();
        let draft = self.composer_draft(cx);
        let palette = theme::palette_from_theme(cx);
        let _chip_workspace = self.context.workspace().to_path_buf();
        let pending = self.state.thread.pending_permission.clone();
        let _model_supports_images = draft.model_supports_images;
        let busy = draft.busy;
        let _usage = draft.usage;
        let _input = draft.input.clone();
        let _input_focus = draft.input_focus.clone();
        let input_value = draft.input_value.clone();
        let _has_input = draft.has_input;
        let slash_open = input_value.trim_start().starts_with('/') && !self.slash_dismissed;
        let slash_matches = self.slash_entries(&input_value);
        let _slash_selected = self.slash_index.min(slash_matches.len().saturating_sub(1));
        let mention = trailing_mention(&input_value);
        let mention_matches = mention
            .as_ref()
            .map(|(_, query)| self.mention_matches(query))
            .unwrap_or_default();
        let _mention_open = mention.is_some() && !slash_open && !mention_matches.is_empty();
        let _mention_selected = self
            .mention_index
            .min(mention_matches.len().saturating_sub(1));
        let _can_undo = self.state.thread.capabilities.checkpoint_available()
            && self.last_checkpoint.is_some()
            && !busy;
        let change_count = self.checkpoint_changes.len();
        let plan_state = self
            .host
            .agent_state
            .lock()
            .map(|state| state.clone())
            .unwrap_or_default();
        let queued_messages = self.queued_messages.clone();
        let show_plan_card = self.state.thread.capabilities.plan_available()
            && (!plan_state.todos.is_empty()
                || !plan_state.plan.is_empty()
                || plan_state.goal.is_some());
        let show_changes = checkpoint_panel_visible(
            self.state.thread.capabilities.checkpoint_available(),
            self.show_checkpoint_panel,
            change_count,
        );
        let row_kinds = self.message_row_kinds();
        self.sync_message_scroller(&row_kinds, cx);
        let row_kinds = Arc::new(row_kinds);
        let weak_view = cx.entity().downgrade();
        let message_menu_root = cx.entity().downgrade();

        div()
            .size_full()
            .flex()
            .flex_col()
            .bg(palette.canvas)
            .text_color(palette.ink)
            .font_family(theme::FONT_SANS)
            .text_size(px(13.0))
            .child(
                div().flex_1().min_h(px(0.0)).child(
                    MessageScroller::new(
                        "native-agent-messages",
                        self.message_scroller.clone(),
                        move |index, _window, cx| {
                            let Some(kind) = row_kinds.get(index).copied() else {
                                return div().into_any_element();
                            };
                            let menu_root = message_menu_root.clone();
                            let row = weak_view
                                .update(cx, |view, cx| {
                                    view.render_message_row(kind, &menu_root, cx)
                                })
                                .unwrap_or_else(|_| div().into_any_element());
                            div().w_full().child(row).into_any_element()
                        },
                    )
                    .scrollbar(true)
                    .jump_button(true)
                    .with_jump_button_label("回到最新")
                    .with_list_style(StyleRefinement::default().p(space(2)))
                    .with_row_style(StyleRefinement::default().pb(space(2))),
                ),
            )
            .children(show_changes.then(|| self.render_checkpoint_panel(palette, change_count, cx)))
            .children(pending.map(|request| {
                let view = cx.entity().downgrade();
                let on_select: PermissionSelectCallback =
                    Arc::new(move |option_id: &str, cx: &mut App| {
                        let _ = view
                            .update(cx, |this, cx| this.resolve_permission_option(option_id, cx));
                    });
                render_permission_card(PermissionCardSpec {
                    id: SharedString::from("native-agent-permission"),
                    model: PermissionCardModel::from_request(&request),
                    hint: None,
                    style: crate::permission_ui::card_style(&palette),
                    on_select: Some(on_select),
                })
            }))
            .children(
                (!queued_messages.is_empty() && self.state.thread.capabilities.queue_available())
                    .then(|| {
                        use cgc_agent_ui::queue_panel::{
                            queue_preview, render_queue_panel, QueuePanelItem, QueuePanelSpec,
                            QueuePanelStyle,
                        };
                        let items = queued_messages
                            .iter()
                            .enumerate()
                            .map(|(index, queued)| {
                                let remove_view = cx.entity().downgrade();
                                QueuePanelItem {
                                    preview: queue_preview(&queued.display, 160),
                                    remove_id: SharedString::from(format!(
                                        "native-queue-remove-{index}"
                                    )),
                                    on_remove: Box::new(move |cx: &mut App| {
                                        let _ = remove_view.update(cx, |this, cx| {
                                            if index < this.queued_messages.len() {
                                                this.queued_messages.remove(index);
                                                cx.notify();
                                            }
                                        });
                                    }),
                                }
                            })
                            .collect();
                        render_queue_panel(QueuePanelSpec {
                            row_id: SharedString::from("native-agent-queue"),
                            header: queued_panel_header_text(queued_messages.len()),
                            items,
                            style: QueuePanelStyle {
                                line: palette.line,
                                view: palette.view,
                                ink_2: palette.ink_2,
                                ink_3: palette.ink_3,
                                soft: palette.soft,
                                radius: RADIUS_MEDIUM,
                            },
                        })
                    }),
            )
            .children(show_plan_card.then(|| {
                use cgc_agent_ui::plan_card::{
                    render_plan_card, PlanCardSpec, PlanCardStyle, PlanStepView, PlanTodoView,
                };
                let status = |status: ItemStatus| match status {
                    ItemStatus::Completed => ("✓", palette.ink_3),
                    ItemStatus::InProgress => ("◐", palette.accent),
                    ItemStatus::Blocked => ("!", palette.danger),
                    ItemStatus::Pending => ("○", palette.ink_3),
                };
                let plan_done = plan_state
                    .plan
                    .iter()
                    .filter(|step| step.status == ItemStatus::Completed)
                    .count();
                let todo_done = plan_state
                    .todos
                    .iter()
                    .filter(|todo| todo.status == ItemStatus::Completed)
                    .count();
                let steps = plan_state
                    .plan
                    .iter()
                    .map(|step| {
                        let (glyph, color) = status(step.status);
                        PlanStepView {
                            title: step.title.clone(),
                            glyph,
                            color,
                        }
                    })
                    .collect();
                let todos = plan_state
                    .todos
                    .iter()
                    .map(|todo| {
                        let (glyph, color) = status(todo.status);
                        PlanTodoView {
                            content: todo.content.clone(),
                            glyph,
                            color,
                        }
                    })
                    .collect();
                render_plan_card(PlanCardSpec {
                    row_id: SharedString::from("native-agent-plan-card"),
                    goal: plan_state.goal.as_ref().map(|goal| goal.objective.clone()),
                    plan_done,
                    plan_total: plan_state.plan.len(),
                    todo_done,
                    todo_total: plan_state.todos.len(),
                    steps,
                    todos,
                    style: PlanCardStyle {
                        line: palette.line,
                        card: palette.card,
                        ink_2: palette.ink_2,
                        ink_3: palette.ink_3,
                        radius: RADIUS_MEDIUM,
                    },
                })
            }))
            .child({
                // B4b-b'1：两条 composer 渲染路径已合一，这是唯一实现
                // （附件/queue/slash/mention/pickers/checkpoint/usage 均在）。
                self.render_native_composer_legacy(&draft, cx)
            })
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
