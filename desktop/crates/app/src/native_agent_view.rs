//! Native agent 的 GPUI 面板（P1a UI 接入）。
//!
//! 通过 `CGC_NATIVE_AGENT_DEMO=1` 打开独立窗口，不影响现有 ACP 对话路径。
//! 事件经 futures channel → `HostState` 归约 → 面板实时刷新；审批用
//! `UiApprover` 把请求变成 UI 上的三个按钮，用户答复通过 oneshot 回填。

use std::collections::HashMap;
use std::sync::{mpsc as std_mpsc, Arc, Mutex};

use base64::Engine as _;
use cgc_agent_checkpoint::{Checkpoint, CheckpointManager, FileChange};
use cgc_agent_core::{
    run_subagent, Agent, AgentError, ApprovalRequest, Approver, AutoApprover, CancelToken,
    ImageAttachment, SelectedModel, Thread,
};
use cgc_agent_host::{
    parse_slash, AgentEvent, AsyncChannelObserver, HostState, SlashCommand, SubagentCard,
    ToolCallStatus, UiMessage, UiRole, UiToolCall, SLASH_COMMANDS,
};
use cgc_agent_provider::{
    CompletionEvent, EchoProvider, Message as ProviderMessage, Model, ModelLimits,
    OpenAiCompatibleConfig, OpenAiCompatibleProvider, Provider, ProviderId,
    Request as ProviderRequest,
};
use cgc_agent_store::{
    provider_key_account, ActionAuditEntry, AuditLog, CheckpointRecord, PrefsStore, ProviderPrefs,
    SessionStore,
};
use cgc_agent_tools::{
    ActionSink, AgentState, AppAction, ApprovalDecision, ItemStatus, SandboxPolicy,
    SharedAgentState, SubagentEvent, SubagentEventSink, SubagentRequest, SubagentRunner,
    ToolContext, ToolRegistry,
};
use cgc_platform::paths::AppPaths;
use cgc_platform::session::KeychainStore;
use futures::channel::{mpsc, oneshot};
use futures::StreamExt as _;
use gpui_kit::component::button::{Button, ButtonVariants};
use gpui_kit::component::hover_card::HoverCard;
use gpui_kit::component::input::{
    InlineTokenContext, InputEvent, Position, Textarea, TextareaState,
};
use gpui_kit::component::menu::{ContextMenuExt as _, PopupMenu};
use gpui_kit::component::message_scroller::{MessageScroller, MessageScrollerState};
use gpui_kit::component::popover::Popover;
use gpui_kit::component::text::{SelectionFormat, TextView};
use gpui_kit::component::tooltip::Tooltip;
use gpui_kit::component::{Icon, Sizable};
use gpui_kit::InteractiveElement as _;
use gpui_kit::StatefulInteractiveElement as _;
use gpui_kit::*;
use image::GenericImageView as _;

use crate::mention::{self, Mention, SkillEntry};
use crate::safe_markdown::sanitize_markdown;
use crate::theme::{self, space, RADIUS_MEDIUM, RADIUS_SMALL};
use cgc_agent_ui::markdown_text::markdown_to_plain;
use cgc_agent_ui::message_actions::{
    render_action_bar, render_message_menu, ActionBarSpec, ActionCallbacks, ActionGlyph,
    ActionGlyphs, ActionStyle, MenuPayloads,
};
use cgc_agent_ui::message_flow::{self, RowKind, RowView};

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

/// 把审批请求送到 UI；用户点击后通过 oneshot 回填。
struct UiApprover {
    events: mpsc::UnboundedSender<AgentEvent>,
    pending: Arc<Mutex<Option<oneshot::Sender<ApprovalDecision>>>>,
}

impl Approver for UiApprover {
    fn decide(
        &self,
        request: ApprovalRequest,
    ) -> futures::future::BoxFuture<'static, ApprovalDecision> {
        let _ = self.events.unbounded_send(AgentEvent::PermissionRequested {
            tool_call_id: request.tool_call_id,
            tool_name: request.tool_name,
            args: request.args,
        });
        let (sender, receiver) = oneshot::channel();
        if let Ok(mut pending) = self.pending.lock() {
            *pending = Some(sender);
        }
        Box::pin(async move { receiver.await.unwrap_or(ApprovalDecision::Deny) })
    }
}

/// 待发送的图片附件（剪贴板或文件）。
struct PendingImage {
    name: String,
    mime: String,
    data: String,
    preview: Option<Arc<RenderImage>>,
}

/// 与 Zed `language_model::request` 对齐：单图编码后 PNG ≤5MB，最长边 1568px。
const ANTHROPIC_SIZE_LIMIT: u32 = 1568;
const IMAGE_MAX_BYTES: usize = 5 * 1024 * 1024;
const MAX_IMAGE_DOWNSCALE_PASSES: usize = 8;

fn encode_png(image: &image::DynamicImage) -> Option<Vec<u8>> {
    let mut cursor = std::io::Cursor::new(Vec::new());
    image.write_to(&mut cursor, image::ImageFormat::Png).ok()?;
    Some(cursor.into_inner())
}

/// 解码 → 尺寸降采样 → PNG 重编码 → 5MB 内迭代缩放。返回 (png 字节, 预览图)。
fn prepare_clipboard_image(bytes: &[u8]) -> Option<(Vec<u8>, Arc<RenderImage>)> {
    let mut decoded = image::load_from_memory(bytes).ok()?;
    let (width, height) = decoded.dimensions();
    if width > ANTHROPIC_SIZE_LIMIT || height > ANTHROPIC_SIZE_LIMIT {
        let scale = ANTHROPIC_SIZE_LIMIT as f32 / width.max(height) as f32;
        decoded = decoded.resize(
            ((width as f32) * scale).round().max(1.0) as u32,
            ((height as f32) * scale).round().max(1.0) as u32,
            image::imageops::FilterType::Triangle,
        );
    }
    let mut png = encode_png(&decoded)?;
    for _ in 0..MAX_IMAGE_DOWNSCALE_PASSES {
        if png.len() <= IMAGE_MAX_BYTES {
            break;
        }
        let (width, height) = decoded.dimensions();
        if width <= 1 || height <= 1 {
            break;
        }
        decoded = decoded.resize(
            ((width as f32) * 0.85).round().max(1.0) as u32,
            ((height as f32) * 0.85).round().max(1.0) as u32,
            image::imageops::FilterType::Triangle,
        );
        png = encode_png(&decoded)?;
    }
    if png.len() > IMAGE_MAX_BYTES {
        return None;
    }
    let preview = Arc::new(RenderImage::new(vec![image::Frame::new(
        decoded.into_rgba8(),
    )]));
    Some((png, preview))
}

/// 已发送消息里展示用的图片引用（chip + 悬停预览）。
#[derive(Clone)]
struct SentImage {
    name: String,
    preview: Option<Arc<RenderImage>>,
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

fn is_image_path(path: &std::path::Path) -> bool {
    matches!(
        path.extension()
            .and_then(|extension| extension.to_str())
            .map(str::to_ascii_lowercase)
            .as_deref(),
        Some("png" | "jpg" | "jpeg" | "webp" | "gif")
    )
}

/// 独立的图片查看窗口：大图 + 缩放/拖动 + 关闭。
struct ImageViewer {
    name: String,
    image: Arc<RenderImage>,
    focus: FocusHandle,
    base_width: f32,
    base_height: f32,
    fit_zoom: f32,
    zoom: f32,
    offset: Point<Pixels>,
    dragging: bool,
    drag_start: Option<Point<Pixels>>,
    drag_origin: Point<Pixels>,
}

impl ImageViewer {
    fn reset(&mut self) {
        self.zoom = self.fit_zoom;
        self.offset = point(px(0.0), px(0.0));
    }
}

impl Render for ImageViewer {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let palette = theme::palette_from_theme(cx);
        let zoom = self.zoom;
        let width = self.base_width * zoom;
        let height = self.base_height * zoom;
        div()
            .size_full()
            .flex()
            .flex_col()
            .bg(palette.canvas)
            .text_color(palette.ink)
            .track_focus(&self.focus)
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .justify_between()
                    .px(space(2))
                    .py(space(1))
                    .border_b_1()
                    .border_color(palette.line)
                    .child(
                        div()
                            .text_size(px(12.0))
                            .text_color(palette.ink_2)
                            .child(format!("{} · {:.0}%", self.name, (zoom * 100.0).round())),
                    )
                    .child(
                        div()
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap(space(2))
                            .child(
                                div().text_size(px(10.0)).text_color(palette.ink_3).child(
                                    "滚轮缩放 · 拖动平移 · 双击还原 · Cmd+0 还原 · Esc 关闭",
                                ),
                            )
                            .child(
                                div()
                                    .id("native-image-viewer-fit")
                                    .role(Role::Button)
                                    .aria_label("适应窗口")
                                    .px(space(1))
                                    .rounded(px(RADIUS_SMALL))
                                    .text_size(px(12.0))
                                    .text_color(palette.ink_2)
                                    .hover(|style| style.bg(palette.soft))
                                    .child("适应窗口")
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.reset();
                                        cx.notify();
                                    })),
                            )
                            .child(
                                div()
                                    .id("native-image-viewer-close")
                                    .role(Role::Button)
                                    .aria_label("关闭")
                                    .px(space(1))
                                    .rounded(px(RADIUS_SMALL))
                                    .text_size(px(12.0))
                                    .text_color(palette.ink_2)
                                    .hover(|style| style.bg(palette.soft))
                                    .child("关闭")
                                    .on_click(|_, window, _cx| window.remove_window()),
                            ),
                    ),
            )
            .child(
                div()
                    .flex_1()
                    .relative()
                    .overflow_hidden()
                    .on_scroll_wheel(cx.listener(|this, event: &ScrollWheelEvent, _, cx| {
                        let delta = match event.delta {
                            ScrollDelta::Pixels(delta) => {
                                let dy: f32 = delta.y.into();
                                dy / 120.0
                            }
                            ScrollDelta::Lines(delta) => delta.y,
                        };
                        this.zoom = (this.zoom * (1.0 + delta * 0.15)).clamp(0.1, 8.0);
                        cx.notify();
                    }))
                    .on_mouse_down(
                        MouseButton::Left,
                        cx.listener(|this, event: &MouseDownEvent, _, cx| {
                            if event.click_count == 2 {
                                this.reset();
                            } else {
                                this.dragging = true;
                                this.drag_start = Some(event.position);
                                this.drag_origin = this.offset;
                            }
                            cx.notify();
                        }),
                    )
                    .on_mouse_move(cx.listener(|this, event: &MouseMoveEvent, _, cx| {
                        if this.dragging {
                            if let Some(start) = this.drag_start {
                                this.offset = this.drag_origin + (event.position - start);
                                cx.notify();
                            }
                        }
                    }))
                    .on_mouse_up(
                        MouseButton::Left,
                        cx.listener(|this, _, _, cx| {
                            this.dragging = false;
                            this.drag_start = None;
                            cx.notify();
                        }),
                    )
                    .child(
                        div()
                            .absolute()
                            .left(self.offset.x)
                            .top(self.offset.y)
                            .child(img(self.image.clone()).w(px(width)).h(px(height))),
                    ),
            )
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .justify_between()
                    .px(space(2))
                    .py(px(3.0))
                    .border_t_1()
                    .border_color(palette.line)
                    .text_size(px(10.0))
                    .text_color(palette.ink_3)
                    .child("滚轮缩放 · 拖动平移 · 双击还原 · Cmd+0 还原 · Esc 关闭")
                    .child(format!("{:.0}%", (self.zoom * 100.0).round())),
            )
            .on_key_down(cx.listener(|this, event: &KeyDownEvent, window, cx| {
                match event.keystroke.key.as_str() {
                    "escape" => window.remove_window(),
                    "0" if event.keystroke.modifiers.platform => {
                        this.reset();
                        cx.notify();
                    }
                    "=" | "+" if event.keystroke.modifiers.platform => {
                        this.zoom = (this.zoom * 1.2).clamp(0.1, 8.0);
                        cx.notify();
                    }
                    "-" if event.keystroke.modifiers.platform => {
                        this.zoom = (this.zoom / 1.2).clamp(0.1, 8.0);
                        cx.notify();
                    }
                    _ => {}
                }
            }))
    }
}

fn decode_sent_images(images: &[ImageAttachment]) -> Vec<SentImage> {
    images
        .iter()
        .map(|image| SentImage {
            name: if image.name.is_empty() {
                "image.png".to_string()
            } else {
                image.name.clone()
            },
            preview: base64::engine::general_purpose::STANDARD
                .decode(image.data.as_bytes())
                .ok()
                .and_then(|bytes| prepare_clipboard_image(&bytes))
                .map(|(_, preview)| preview),
        })
        .collect()
}

/// 把 thread entries 映射成 UI 状态：图片预览 + 工具调用参数/输出（工具卡片）。
fn apply_thread_entries(
    state: &mut HostState,
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
    for entry in entries {
        match entry {
            cgc_agent_core::Entry::User {
                text,
                images,
                display,
                ..
            } => {
                // 展示文本优先用 display（不含技能/文件注入上下文），旧数据回退到 text。
                state.push_user(display.clone().unwrap_or_else(|| text.clone()));
                let previews = decode_sent_images(images);
                if !previews.is_empty() {
                    restored_images.insert(state.messages.len() - 1, previews);
                }
            }
            cgc_agent_core::Entry::Assistant { text, .. } if !text.is_empty() => {
                state.push_assistant(text)
            }
            cgc_agent_core::Entry::Thinking { text, .. } => state.push_thinking(text),
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
                let status = if *is_error {
                    ToolCallStatus::Failed
                } else {
                    ToolCallStatus::Ok
                };
                state.push_tool_card(
                    tool_use_id.clone(),
                    name,
                    args,
                    status,
                    Some(content.clone()),
                );
            }
            _ => {}
        }
    }
    restored_images
}

pub struct NativeAgentView {
    agent: Option<Agent>,
    provider: Arc<dyn Provider>,
    model: Model,
    registry: Arc<ToolRegistry>,
    agent_state: SharedAgentState,
    app_actions: Arc<Mutex<Vec<AppAction>>>,
    action_audit: Option<AuditLog>,
    subagent_tx: Arc<Mutex<Option<mpsc::UnboundedSender<AgentEvent>>>>,
    context: ToolContext,
    input: Entity<TextareaState>,
    cancel: CancelToken,
    state: HostState,
    /// 当前工作区 scope（ADR-0028：课程页/助手页各一个工作区）。
    scope: crate::agent_scope::AgentScope,
    status: String,
    busy: bool,
    session_store: Option<SessionStore>,
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
    /// 流式思考块是否被用户折叠（默认自动展开）。
    live_thinking_collapsed: bool,
    /// 正在编辑的用户消息（UI message index）。
    editing_user: Option<usize>,
    /// 编辑态输入框；仅在 editing_user 有值时存在。
    user_edit_input: Option<Entity<TextareaState>>,
    /// 虚拟消息列表状态：只渲染可见行，并负责 tail 跟随/滚动条/回到最新按钮。
    message_scroller: Entity<MessageScrollerState>,
    /// 每行的高度签名；与下一帧比对，只 remeasure 变化的那一行。
    message_row_signatures: Vec<u64>,
    approval_mode: ApprovalMode,
    approval_sender: Arc<Mutex<Option<oneshot::Sender<ApprovalDecision>>>>,
    pending_images: Vec<PendingImage>,
    /// 已发送用户消息 index → 图片预览（仅当前进程内显示，不持久化）。
    sent_images: HashMap<usize, Vec<SentImage>>,
    last_input_value: String,
    queued_messages: Vec<QueuedMessage>,
    steer_sender: std_mpsc::Sender<String>,
    _input_subscription: Option<Subscription>,
    _key_interceptor: Option<Subscription>,
}

impl NativeAgentView {
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
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
        let session_store =
            SessionStore::open(paths.data_root.join("agent").join("threads.db")).ok();
        // 工作区按页面 scope 解析（CGC_AGENT_WORKSPACE 优先）；线程按 scope 一条。
        let scope = crate::agent_scope::current()
            .unwrap_or_else(|| crate::agent_scope::resolve(None, None));
        let thread_id = scope_thread_id(&scope);
        let workspace = scope.root.clone();
        let _ = std::fs::create_dir_all(&workspace);
        let restored_thread = session_store.as_ref().and_then(|store| {
            let thread = store.load_thread(&thread_id).ok().flatten()?;
            (thread.model == selected).then_some(thread)
        });
        let mut state = HostState::new();
        let mut restored_images: HashMap<usize, Vec<SentImage>> = HashMap::new();
        let thread = match restored_thread {
            Some(thread) => {
                restored_images = apply_thread_entries(&mut state, &thread.entries);
                state.usage_total = thread.usage_total;
                thread
            }
            None => {
                if let Some(notice) = offline_echo_notice(using_echo) {
                    state.push_system(notice);
                }
                Thread::new(thread_id, selected)
            }
        };
        let restored = !state.messages.is_empty();
        let system_prompt = build_workspace_system_prompt(&workspace);
        let agent = Agent::new(thread, Some(system_prompt));
        let cancel = agent.cancel_token();
        let steer_sender = agent.steer_sender();
        let agent_state: SharedAgentState = Arc::new(Mutex::new(AgentState::default()));
        let action_audit = Some(AuditLog::new(paths.agent_audit_file()));
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
                    if *secondary && this.busy {
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
        let mut view = Self {
            agent: Some(agent),
            provider,
            model,
            registry: Arc::new(
                ToolRegistry::with_agent_state(agent_state.clone())
                    .with_app_actions()
                    .with_subagent(subagent_runner, subagent_sink),
            ),
            agent_state,
            app_actions,
            action_audit,
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
            live_thinking_collapsed: false,
            editing_user: None,
            user_edit_input: None,
            message_scroller: cx.new(|cx| MessageScrollerState::new(0, cx)),
            message_row_signatures: Vec::new(),
            approval_mode: ApprovalMode::Ask,
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
            approval_sender: Arc::new(Mutex::new(None)),
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
                .push_system("命令：/help /clear /stop /tools /checkpoint /settings"),
            SlashCommand::Clear => {
                self.state.messages.clear();
                self.sent_images.clear();
                self.state.streaming.clear();
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
                self.state.push_system(format!("可用工具：{tools}"));
            }
            SlashCommand::Checkpoint => {
                if self.last_checkpoint.is_some() {
                    self.show_checkpoint_panel = true;
                    self.refresh_checkpoint_changes();
                } else {
                    self.state.push_system("当前没有可用的 checkpoint");
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
                    self.state.push_system("请在账号菜单里打开设置");
                }
            }
            SlashCommand::Unknown(name) => self.state.push_system(format!("未知命令：/{name}")),
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
        if self.busy {
            self.queued_messages.push(QueuedMessage { display, prompt });
            self.status = format!(
                "已排队 {} 条，当前 turn 结束后依次发送",
                self.queued_messages.len()
            );
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
                .push_system("已重新读取 Provider API Key，后续请求使用真实模型。");
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
        if let Some(agent) = &mut self.agent {
            agent.set_thread_title_override(title);
        }
        if let (Some(agent), Some(store)) = (self.agent.as_ref(), self.session_store.as_mut()) {
            let _ = store.save_thread(agent.thread());
        }
        cx.notify();
    }

    pub fn regenerate_title(&mut self, cx: &mut Context<Self>) {
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
                            (this.agent.as_ref(), this.session_store.as_mut())
                        {
                            let _ = store.save_thread(agent.thread());
                        }
                    }
                } else {
                    if let Some(agent) = &mut this.agent {
                        agent.set_thread_title(Some(title.clone()));
                    }
                    if let (Some(agent), Some(store)) =
                        (this.agent.as_ref(), this.session_store.as_mut())
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

    /// 从统一线程列表恢复指定 native 线程。
    pub fn open_thread(&mut self, thread_id: &str, cx: &mut Context<Self>) {
        let Some(store) = &self.session_store else {
            return;
        };
        let Ok(Some(thread)) = store.load_thread(thread_id) else {
            return;
        };
        let mut state = HostState::new();
        let restored_images = apply_thread_entries(&mut state, &thread.entries);
        state.usage_total = thread.usage_total;
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
        let bounds = Bounds {
            origin: point(px(260.0), px(160.0)),
            size: size(px(900.0), px(700.0)),
        };
        let focus = cx.focus_handle();
        let image_size = image.size(0);
        let base_width = image_size.width.0 as f32;
        let base_height = image_size.height.0 as f32;
        let fit_zoom = (820.0 / base_width.max(1.0))
            .min(620.0 / base_height.max(1.0))
            .min(1.0);
        let _ = gpui_kit::open_window::<ImageViewer>(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(bounds)),
                ..Default::default()
            },
            cx,
            move |window: &mut Window, cx: &mut App| {
                window.set_window_title("图片预览");
                cx.new(|_| ImageViewer {
                    name,
                    image,
                    focus,
                    base_width,
                    base_height,
                    fit_zoom,
                    zoom: fit_zoom,
                    offset: point(px(0.0), px(0.0)),
                    dragging: false,
                    drag_start: None,
                    drag_origin: point(px(0.0), px(0.0)),
                })
            },
        );
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
            self.state.push_system("没有可重试的请求");
            cx.notify();
            return;
        };
        // 重试 = 重放上一轮：线程侧丢掉失败那轮的 user 条目（prompt 会重新 push，
        // 否则重启恢复后会出现重复用户气泡）；UI 侧丢掉失败 turn 的残留行。
        if let Some(agent) = self.agent.as_mut() {
            agent.thread_mut().truncate_before_last_user();
        }
        if let Some(index) = trim_messages_to_last_user(&mut self.state.messages) {
            self.sent_images
                .retain(|message_index, _| *message_index <= index);
        }
        // Settings 里改过 Key 后重试要能读到新凭据。
        self.refresh_provider_credentials(cx, true);
        self.run_turn(prompt, display, true, cx);
    }

    /// 执行一个 turn；`retry` = 重放上一轮（不重复 push 用户消息、不重拍 checkpoint）。
    fn run_turn(&mut self, text: String, display: String, retry: bool, cx: &mut Context<Self>) {
        if !retry {
            self.reload_latest_session();
            // 本条用户消息即将 push（run_turn 里会 push），ordinal = 现有用户消息数 + 1。
            let ordinal = self
                .state
                .messages
                .iter()
                .filter(|message| message.role == UiRole::User)
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
                let message_index = self.state.messages.len();
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
        let approval_mode = self.approval_mode;
        if !retry {
            self.state.push_user(display);
        }
        self.busy = true;
        self.status = "思考中…".to_string();
        self.cancel.reset();

        let (event_sender, mut event_receiver) = mpsc::unbounded::<AgentEvent>();
        if let Ok(mut slot) = self.subagent_tx.lock() {
            *slot = Some(event_sender.clone());
        }
        // UI 事件循环：把 agent 过程事件实时归约进 HostState。
        cx.spawn(async move |this, cx| {
            while let Some(event) = event_receiver.next().await {
                let turn_finished = matches!(event, AgentEvent::TurnFinished { .. });
                if this
                    .update(cx, |this, cx| {
                        let had_thinking = !this.state.thinking_streaming.is_empty();
                        this.state.apply(event);
                        let thinking_flushed =
                            had_thinking && this.state.thinking_streaming.is_empty();
                        if should_auto_expand_live_thinking(
                            had_thinking,
                            !this.state.thinking_streaming.is_empty(),
                        ) {
                            this.live_thinking_collapsed = false;
                        }
                        if thinking_flushed {
                            transfer_live_thinking_expansion(
                                &this.state.messages,
                                this.live_thinking_collapsed,
                                &mut this.expanded_thinking,
                            );
                        }
                        if turn_finished {
                            this.maybe_generate_thread_title(cx);
                        }
                        cx.notify();
                    })
                    .is_err()
                {
                    break;
                }
            }
        })
        .detach();

        let ui_approver = UiApprover {
            events: event_sender.clone(),
            pending: self.approval_sender.clone(),
        };
        let provider = self.provider.clone();
        let model = self.model.clone();
        let model_tools_supported = self
            .providers
            .iter()
            .find(|provider| provider.id == self.model.provider_id.as_str())
            .map(|provider| provider.model_config(self.model.id.as_str()).supports_tools)
            .unwrap_or(true);
        let registry = if model_tools_supported {
            self.registry.clone()
        } else {
            Arc::new(ToolRegistry::new())
        };
        let context = self.context.clone();
        let task_sender = event_sender.clone();
        let task = cx.background_executor().spawn(async move {
            let auto_approver = AutoApprover;
            let approver: &dyn Approver = match approval_mode {
                ApprovalMode::Ask => &ui_approver,
                ApprovalMode::Auto => &auto_approver,
            };
            let mut observer = AsyncChannelObserver::new(task_sender.clone());
            let result = agent
                .prompt_with_tools_observed(
                    provider.as_ref(),
                    &model,
                    text,
                    registry.as_ref(),
                    &context,
                    approver,
                    &mut observer,
                )
                .await;
            drop(observer);
            drop(task_sender);
            (agent, result)
        });
        let approval_sender = self.approval_sender.clone();
        let subagent_tx = self.subagent_tx.clone();
        cx.spawn(async move |this, cx| {
            let (agent, result) = task.await;
            let _ = this.update(cx, |this, cx| {
                this.agent = Some(agent);
                this.busy = false;
                match result {
                    Ok(_) => {
                        let total = this
                            .agent
                            .as_ref()
                            .map(|agent| agent.thread().usage_total.total())
                            .unwrap_or(0);
                        this.status = format!("完成 · 本会话 {total} tokens");
                    }
                    Err(AgentError::Cancelled) => this.status = "已停止".to_string(),
                    Err(error) => {
                        this.state.apply(AgentEvent::Error {
                            message: error.to_string(),
                        });
                        this.status = format!("错误：{error}");
                    }
                }
                if let (Some(store), Some(agent)) = (&mut this.session_store, &this.agent) {
                    let _ = store.save_thread(agent.thread());
                }
                this.reload_thread_checkpoints();
                if let Ok(mut slot) = subagent_tx.lock() {
                    *slot = None;
                }
                this.drain_app_actions(cx);
                this.refresh_checkpoint_changes();
                if let Ok(mut pending) = approval_sender.lock() {
                    pending.take();
                }
                if !this.queued_messages.is_empty() {
                    let next = this.queued_messages.remove(0);
                    this.send_prompt(next.prompt, next.display, cx);
                }
                cx.notify();
            });
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
        self.cancel.cancel();
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
            if let Some(log) = &self.action_audit {
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
            self.state.push_system(if dispatched {
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
        let paths = self
            .checkpoint_changes
            .iter()
            .map(|change| change.path.clone())
            .collect::<Vec<_>>();
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
        self.checkpoint_changes.retain(|change| change.path != path);
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
        let query = query.to_ascii_lowercase();
        self.workspace_files
            .iter()
            .filter(|path| query.is_empty() || path.to_ascii_lowercase().contains(&query))
            .take(8)
            .cloned()
            .collect()
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
        let Some(message) = self.state.messages.get(message_index) else {
            return;
        };
        if message.role != UiRole::User {
            return;
        }
        let text = message.text.clone();
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
        let Some(ordinal) = user_message_ordinal(&self.state.messages, message_index) else {
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
        if let (Some(manager), Some(store)) = (&self.checkpoint_manager, &self.session_store) {
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
        self.state.messages.retain(|message| {
            !(message.role == UiRole::System && message.text == EMPTY_THREAD_NOTICE)
        });
        self.state.push_user(edited_display.clone());
        self.state.last_error = None;
        self.state.streaming.clear();
        self.last_turn = Some((edited_prompt.clone(), edited_display.clone()));
        let ordinal = self
            .state
            .messages
            .iter()
            .filter(|message| message.role == UiRole::User)
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
        div()
            .flex()
            .flex_col()
            .gap(space(1))
            .child(
                div()
                    .rounded(px(RADIUS_MEDIUM))
                    .border_1()
                    .border_color(palette.line_strong)
                    .bg(palette.view)
                    .px(space(2))
                    .py(space(1))
                    .child(
                        Textarea::new(&input)
                            .appearance(false)
                            .bordered(false)
                            .w_full(),
                    ),
            )
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .justify_end()
                    .gap(space(1))
                    .child(
                        div()
                            .id("native-user-edit-cancel")
                            .role(Role::Button)
                            .aria_label("取消编辑")
                            .px(space(1))
                            .py(px(2.0))
                            .rounded(px(RADIUS_SMALL))
                            .text_size(px(11.0))
                            .text_color(palette.ink_2)
                            .hover(|style| style.bg(palette.soft))
                            .child("取消")
                            .on_click(cx.listener(|this, _, _, cx| this.cancel_edit_user(cx))),
                    )
                    .child(
                        div()
                            .id("native-user-edit-resend")
                            .role(Role::Button)
                            .aria_label("从这里重发")
                            .px(space(2))
                            .py(px(2.0))
                            .rounded(px(RADIUS_SMALL))
                            .bg(palette.accent)
                            .text_color(palette.canvas)
                            .text_size(px(11.0))
                            .child("重发")
                            .on_click(cx.listener(move |this, _, _window, cx| {
                                this.restart_from_user_message(message_index, cx)
                            })),
                    ),
            )
            .children(
                (self.pending_restart_confirm == Some(message_index)).then(|| {
                    div()
                        .flex()
                        .flex_col()
                        .gap(space(1))
                        .p(space(2))
                        .rounded(px(RADIUS_SMALL))
                        .border_1()
                        .border_color(palette.danger)
                        .bg(palette.view)
                        .child(
                            div()
                                .text_size(px(11.0))
                                .text_color(palette.danger)
                                .child("没有可用检查点"),
                        )
                        .child(
                            div()
                                .text_size(px(11.0))
                                .text_color(palette.ink_2)
                                .child("继续只会回滚对话，无法回滚工作区文件。"),
                        )
                        .child(
                            div()
                                .flex()
                                .flex_row()
                                .justify_end()
                                .gap(space(1))
                                .child(
                                    div()
                                        .id("native-restart-cancel")
                                        .role(Role::Button)
                                        .aria_label("取消重发")
                                        .px(space(1))
                                        .py(px(2.0))
                                        .rounded(px(RADIUS_SMALL))
                                        .text_size(px(11.0))
                                        .text_color(palette.ink_2)
                                        .hover(|style| style.bg(palette.soft))
                                        .child("取消")
                                        .on_click(cx.listener(|this, _, _, cx| {
                                            this.pending_restart_confirm = None;
                                            cx.notify();
                                        })),
                                )
                                .child(
                                    div()
                                        .id("native-restart-confirm")
                                        .role(Role::Button)
                                        .aria_label("仍然重发")
                                        .px(space(2))
                                        .py(px(2.0))
                                        .rounded(px(RADIUS_SMALL))
                                        .bg(palette.danger)
                                        .text_color(palette.canvas)
                                        .text_size(px(11.0))
                                        .child("仍然重发")
                                        .on_click(cx.listener(move |this, _, _, cx| {
                                            this.restart_from_user_message(message_index, cx)
                                        })),
                                ),
                        )
                }),
            )
            .into_any_element()
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
        if let Some(store) = &mut self.session_store {
            for (ordinal, _) in &self.available_checkpoints {
                let _ = store.mark_checkpoint_invalid(&thread_id, *ordinal as i64);
            }
        }
        if let (Some(store), Some(agent)) = (&mut self.session_store, &self.agent) {
            let _ = store.save_thread(agent.thread());
        }
        self.state = HostState::new();
        self.state
            .push_system("Native agent：新对话，配置 Provider 后开始。");
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
        Arc::new(
            ToolRegistry::with_agent_state(self.agent_state.clone())
                .with_app_actions()
                .with_subagent(subagent_runner, subagent_sink),
        )
    }

    /// 切换工作区 scope：保存当前线程，载入目标 scope 的线程并重建运行时。
    fn switch_scope(&mut self, scope: crate::agent_scope::AgentScope, cx: &mut Context<Self>) {
        if let (Some(store), Some(agent)) = (&mut self.session_store, &self.agent) {
            let _ = store.save_thread(agent.thread());
        }
        let root = scope.root.clone();
        let thread_id = scope_thread_id(&scope);
        let selected = SelectedModel::new(self.model.provider_id.clone(), self.model.id.clone());
        let thread = self
            .session_store
            .as_ref()
            .and_then(|store| store.load_thread(&thread_id).ok().flatten())
            .filter(|thread| thread.model == selected)
            .unwrap_or_else(|| Thread::new(thread_id.clone(), selected));
        let mut state = HostState::new();
        let restored_images = apply_thread_entries(&mut state, &thread.entries);
        state.usage_total = thread.usage_total;
        if state.messages.is_empty() {
            if let Some(notice) = offline_echo_notice(self.using_echo) {
                state.push_system(notice);
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
        self.live_thinking_collapsed = false;
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
        let Some(store) = &self.session_store else {
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
        let mut state = HostState::new();
        state.usage_total = thread.usage_total;
        let restored_images = apply_thread_entries(&mut state, &thread.entries);
        if state.messages.is_empty() {
            state.push_system(EMPTY_THREAD_NOTICE);
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
                    .push_system("当前工作区不是 git 仓库：检查点不可用，本轮文件改动将无法回滚。");
            }
            return;
        };
        match manager.snapshot(thread_id, ordinal as u64) {
            Ok(checkpoint) => {
                if let Some(store) = &mut self.session_store {
                    let _ = store.save_checkpoint(&checkpoint, ordinal as i64, now_secs());
                }
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
                        .push_system(format!("本轮未创建检查点：{error}（文件改动将无法回滚）"));
                }
            }
        }
    }

    /// 从持久化存储重载当前线程的 checkpoint 列表。
    fn reload_thread_checkpoints(&mut self) {
        self.available_checkpoints.clear();
        self.last_checkpoint = None;
        let (Some(store), Some(agent)) = (&self.session_store, &self.agent) else {
            return;
        };
        let thread_id = agent.thread().id.clone();
        if let Ok(records) = store.list_checkpoints(&thread_id) {
            self.available_checkpoints = checkpoints_from_records(&records);
            self.last_checkpoint = self
                .available_checkpoints
                .last()
                .map(|(_, checkpoint)| checkpoint.clone());
        }
        self.refresh_checkpoint_changes();
    }

    /// 某条 UI 消息可用的 checkpoint（用户消息 ordinal 对应）。
    fn checkpoint_for_message(&self, message_index: usize) -> Option<Checkpoint> {
        let ordinal = user_message_ordinal(&self.state.messages, message_index)?;
        self.available_checkpoints
            .iter()
            .find(|(candidate, _)| *candidate == ordinal)
            .map(|(_, checkpoint)| checkpoint.clone())
    }

    /// 会话回退后，把 `ordinal >= from_ordinal` 的 checkpoint 标记失效。
    fn invalidate_checkpoints_from(&mut self, from_ordinal: usize, thread_id: &str) {
        if let Some(store) = &mut self.session_store {
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
        let Some(ordinal) = user_message_ordinal(&self.state.messages, message_index) else {
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
                if let (Some(store), Some(agent)) = (&mut self.session_store, &self.agent) {
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
        if let Some(store) = &mut self.session_store {
            let _ = store.save_thread(agent.thread());
        }
        self.editing_user = None;
        self.user_edit_input = None;
        self.rebuild_state_from_thread();
        self.state.messages.retain(|message| {
            !(message.role == UiRole::System && message.text == EMPTY_THREAD_NOTICE)
        });
        self.invalidate_checkpoints_from(ordinal, &thread_id);
        self.state
            .push_system("已恢复检查点：文件已回退，可以从这里重新发送消息");
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

    fn resolve_approval(&mut self, decision: ApprovalDecision, cx: &mut Context<Self>) {
        if let Ok(mut pending) = self.approval_sender.lock() {
            if let Some(sender) = pending.take() {
                let _ = sender.send(decision);
            }
        }
        if let Some(prompt) = self.state.pending_permission.clone() {
            self.state.resolve_permission(&prompt.tool_call_id);
        }
        cx.notify();
    }
}

impl NativeAgentView {
    /// 当前是否在跑一个回合。`busy` 在结果回调里落回 false，但事件队列可能还没
    /// 消化完 TurnFinished，用 `turn_active` 补这个窗口（对齐 Zed 的 Generating）。
    fn is_generating(&self) -> bool {
        self.busy || self.state.turn_active
    }

    /// 构建单条历史消息的行元素。
    fn render_message_row_element(
        &self,
        message_index: usize,
        palette: theme::Palette,
        menu_root: &WeakEntity<Self>,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let message = &self.state.messages[message_index];
        let color = match message.role {
            UiRole::User => palette.accent,
            UiRole::Error => palette.danger,
            UiRole::Tool => palette.ink_3,
            UiRole::System => palette.ink_3,
            UiRole::Thinking => palette.ink_3,
            UiRole::Assistant => palette.ink,
        };
        // Copy This Agent Response = 整回合文本（对齐 Zed）；其它角色没有该动作。
        let agent_response = (message.role == UiRole::Assistant)
            .then(|| row_view(&self.state.messages).turn_copy_text(message_index))
            .flatten();
        let payloads = Arc::new(message_menu_payloads(
            message.role,
            &message.text,
            agent_response,
        ));
        let menu_view = menu_root.clone();
        div()
            .id(SharedString::from(format!(
                "native-message-{message_index}"
            )))
            .flex()
            .flex_col()
            .gap(px(2.0))
            // 对齐 Zed：只有 system/error 这类状态消息保留角色标签；
            // user 用卡片区分、assistant 直接 markdown、tool/thinking 自带卡头。
            .children(
                matches!(message.role, UiRole::System | UiRole::Error).then(|| {
                    div()
                        .text_size(px(11.0))
                        .text_color(color)
                        .child(role_label(message.role))
                }),
            )
            .child(match message.role {
                UiRole::Assistant => {
                    let mut column = div()
                        .flex()
                        .flex_col()
                        .gap(space(1))
                        .child(render_assistant_markdown(message_index, &message.text));
                    // 对齐 Zed #61245 + #61362：只在回合末挂操作栏；历史消息的
                    // 操作栏在流式时仍可见，仅底部条在生成/等审批时隐藏。
                    if let Some(plan) = row_view(&self.state.messages).action_plan(
                        message_index,
                        self.is_generating(),
                        self.state.pending_permission.is_some(),
                    ) {
                        column = column.child(self.render_message_actions(
                            &format!("native-message-actions-{message_index}"),
                            row_view(&self.state.messages).turn_copy_text(message_index),
                            plan,
                            palette,
                            cx,
                        ));
                    }
                    column.into_any_element()
                }
                UiRole::User => {
                    if self.editing_user == Some(message_index) {
                        self.render_user_edit_row(message_index, &palette, cx)
                    } else {
                        let edit_index = message_index;
                        let restore_index = message_index;
                        let restore_checkpoint = self.checkpoint_for_message(message_index);
                        div()
                            .flex()
                            .flex_col()
                            .gap(space(1))
                            .child(
                                div()
                                    .id(SharedString::from(format!(
                                        "native-user-card-{edit_index}"
                                    )))
                                    .group("native-user-msg")
                                    .relative()
                                    .w_full()
                                    .px(space(2))
                                    .py(space(2))
                                    .rounded(px(RADIUS_MEDIUM))
                                    .border_1()
                                    .border_color(palette.line)
                                    .bg(palette.view)
                                    .hover(|style| style.border_color(palette.line_strong))
                                    .child(
                                        div().pr(px(28.0)).child(render_user_message_body(
                                            &message.text,
                                            &palette,
                                        )),
                                    )
                                    .children(
                                        (!self.busy && self.editing_user != Some(edit_index)).then(
                                            || {
                                                div()
                                                    .id(SharedString::from(format!(
                                                        "native-edit-user-{edit_index}"
                                                    )))
                                                    .role(Role::Button)
                                                    .aria_label("编辑消息")
                                                    .absolute()
                                                    .top(px(4.0))
                                                    .right(space(1))
                                                    .px(space(1))
                                                    .py(px(1.0))
                                                    .rounded(px(RADIUS_SMALL))
                                                    .bg(palette.card)
                                                    .text_size(px(10.0))
                                                    .text_color(palette.ink_3)
                                                    .invisible()
                                                    .group_hover("native-user-msg", |style| {
                                                        style.visible()
                                                    })
                                                    .hover(|style| style.bg(palette.soft))
                                                    .child("编辑")
                                                    .on_click(cx.listener(
                                                        move |this, _, window, cx| {
                                                            this.begin_edit_user(
                                                                edit_index, window, cx,
                                                            )
                                                        },
                                                    ))
                                            },
                                        ),
                                    )
                                    .into_any_element(),
                            )
                            .children(
                                (!self.busy
                                    && restore_checkpoint.is_some()
                                    && self.editing_user != Some(edit_index))
                                .then(|| {
                                    div()
                                        .id(SharedString::from(format!(
                                            "native-restore-checkpoint-{restore_index}"
                                        )))
                                        .role(Role::Button)
                                        .aria_label("恢复检查点")
                                        .flex()
                                        .flex_row()
                                        .items_center()
                                        .gap(px(3.0))
                                        .self_end()
                                        .text_size(px(10.0))
                                        .text_color(palette.ink_3)
                                        .hover(|style| style.text_color(palette.ink_2))
                                        .child("⟲ 恢复检查点")
                                        .on_click(cx.listener(move |this, _, _window, cx| {
                                            this.restore_to_checkpoint(restore_index, cx)
                                        }))
                                }),
                            )
                            .into_any_element()
                    }
                }
                UiRole::Thinking => {
                    let expanded = self.expanded_thinking.contains(&message_index);
                    let toggle_view = cx.entity().downgrade();
                    let thinking_text = message.text.clone();
                    div()
                        .flex()
                        .flex_col()
                        .gap(px(2.0))
                        .child(
                            div()
                                .id(SharedString::from(format!(
                                    "native-thinking-toggle-{message_index}"
                                )))
                                .flex()
                                .flex_row()
                                .items_center()
                                .gap(px(3.0))
                                .text_size(px(11.0))
                                .text_color(palette.ink_3)
                                .hover(|style| style.text_color(palette.ink_2))
                                .child(if expanded { "▾" } else { "▸" })
                                .child("Thinking")
                                .on_click(move |_, _, cx| {
                                    let _ = toggle_view.update(cx, |this, cx| {
                                        this.toggle_thinking(message_index, cx)
                                    });
                                }),
                        )
                        .children(expanded.then(|| {
                            div()
                                .pl(space(2))
                                .border_l_1()
                                .border_color(palette.line)
                                .child(TextView::markdown(
                                    SharedString::from(format!(
                                        "native-thinking-markdown-{message_index}"
                                    )),
                                    sanitize_markdown(&thinking_text),
                                ))
                        }))
                        .into_any_element()
                }
                UiRole::Tool => match &message.tool {
                    Some(tool) => {
                        let tool_call_id = message.tool_call_id.clone().unwrap_or_default();
                        let expanded = self.expanded_tools.contains(&tool_call_id)
                            || matches!(tool.status, ToolCallStatus::Running);
                        let toggle_view = cx.entity().downgrade();
                        let toggle_id = tool_call_id.clone();
                        render_tool_card(tool, expanded, &palette, move |_, _, cx| {
                            let _ = toggle_view.update(cx, |this, cx| {
                                this.toggle_tool_call(toggle_id.clone(), cx)
                            });
                        })
                    }
                    None => div()
                        .text_size(px(13.0))
                        .child(message.text.clone())
                        .into_any_element(),
                },
                _ => div()
                    .text_size(px(13.0))
                    .child(message.text.clone())
                    .into_any_element(),
            })
            .context_menu(move |menu, _window, _cx| {
                render_native_message_menu(menu, menu_view.clone(), payloads.clone())
            })
            .children(self.sent_images.get(&message_index).map(|images| {
                div().flex().flex_row().flex_wrap().gap(space(1)).children(
                    images.iter().enumerate().map(|(image_index, image)| {
                        let preview = image.preview.clone();
                        let open_weak = cx.entity().downgrade();
                        let open_preview = image.preview.clone();
                        let open_name = image.name.clone();
                        let trigger = div()
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap(px(4.0))
                            .px(space(1))
                            .py(px(1.0))
                            .text_size(px(11.0))
                            .text_color(palette.ink_2)
                            .child(match image.preview.clone() {
                                Some(preview) => img(preview)
                                    .max_w(px(16.0))
                                    .max_h(px(16.0))
                                    .rounded(px(2.0))
                                    .into_any_element(),
                                None => "🖼".into_any_element(),
                            })
                            .child(image.name.clone())
                            .into_any_element();
                        div()
                            .id(SharedString::from(format!(
                                "native-msg-image-{message_index}-{image_index}"
                            )))
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap(px(4.0))
                            .px(space(1))
                            .py(px(1.0))
                            .rounded(px(RADIUS_SMALL))
                            .border_1()
                            .border_color(palette.line)
                            .text_size(px(11.0))
                            .text_color(palette.ink_2)
                            .on_click(move |_, _, cx| {
                                if let Some(preview) = open_preview.clone() {
                                    let name = open_name.clone();
                                    let _ = open_weak.update(cx, |this, cx| {
                                        this.open_image_viewer(name, preview, cx);
                                    });
                                }
                            })
                            .child(
                                HoverCard::new(SharedString::from(format!(
                                    "native-msg-image-hover-{message_index}-{image_index}"
                                )))
                                .anchor(Anchor::BottomCenter)
                                .open_delay(std::time::Duration::from_millis(80))
                                .trigger(trigger)
                                .content(move |_, _, _| {
                                    match preview.clone() {
                                        Some(preview) => div()
                                            .p(px(4.0))
                                            .rounded(px(RADIUS_SMALL))
                                            .border_1()
                                            .border_color(palette.line)
                                            .bg(palette.card)
                                            .child(
                                                img(preview)
                                                    .max_w(px(280.0))
                                                    .max_h(px(180.0))
                                                    .rounded(px(RADIUS_SMALL)),
                                            )
                                            .into_any_element(),
                                        None => div().child("无预览").into_any_element(),
                                    }
                                }),
                            )
                            .into_any_element()
                    }),
                )
            }))
            .into_any_element()
    }

    /// 当前流式思考行（默认展开，可折叠）。
    fn render_live_thinking_row(
        &self,
        palette: theme::Palette,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let thinking_streaming = &self.state.thinking_streaming;
        if thinking_streaming.is_empty() {
            return div().into_any_element();
        }
        let expanded = !self.live_thinking_collapsed;
        let toggle_view = cx.entity().downgrade();
        div()
            .id("native-live-thinking")
            .flex()
            .flex_col()
            .gap(px(2.0))
            .child(
                div()
                    .id("native-live-thinking-toggle")
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap(px(3.0))
                    .text_size(px(11.0))
                    .text_color(palette.accent)
                    .child(if expanded { "▾" } else { "▸" })
                    .child("Thinking…")
                    .on_click(move |_, _, cx| {
                        let _ = toggle_view.update(cx, |this, cx| {
                            this.live_thinking_collapsed = !this.live_thinking_collapsed;
                            cx.notify();
                        });
                    }),
            )
            .children(expanded.then(|| {
                div()
                    .pl(space(2))
                    .border_l_1()
                    .border_color(palette.line)
                    .child(
                        markdown_text_view("native-streaming-thinking", thinking_streaming)
                            .stream_fade(true),
                    )
            }))
            .into_any_element()
    }

    /// 当前流式回复行（markdown 增量渲染）。
    fn render_streaming_row(
        &self,
        palette: theme::Palette,
        menu_root: &WeakEntity<Self>,
    ) -> AnyElement {
        let streaming = &self.state.streaming;
        if streaming.is_empty() {
            return div().into_any_element();
        }
        let streaming_payloads = Arc::new(message_menu_payloads(
            UiRole::Assistant,
            streaming,
            Some(streaming.clone()),
        ));
        let streaming_view = menu_root.clone();
        div()
            .id("native-message-streaming")
            .flex()
            .flex_col()
            .gap(px(2.0))
            .child(
                div()
                    .text_size(px(11.0))
                    .text_color(palette.accent)
                    .child("agent"),
            )
            .child(markdown_text_view("native-streaming-markdown", streaming).stream_fade(true))
            .context_menu(move |menu, _window, _cx| {
                render_native_message_menu(menu, streaming_view.clone(), streaming_payloads.clone())
            })
            .into_any_element()
    }

    /// 失败回调行（带重试）。
    fn render_error_row(&self, palette: theme::Palette, cx: &mut Context<Self>) -> AnyElement {
        let Some(error) = self.state.last_error.clone() else {
            return div().into_any_element();
        };
        let hint = retry_hint_for_error(&error);
        let can_retry = self.state.retry_available() && self.last_turn.is_some();
        div()
            .id("native-agent-error")
            .flex()
            .flex_col()
            .gap(px(4.0))
            .p(space(2))
            .rounded(px(RADIUS_MEDIUM))
            .border_1()
            .border_color(palette.danger)
            .bg(palette.view)
            .child(
                div()
                    .text_size(px(11.0))
                    .text_color(palette.danger)
                    .child("请求失败"),
            )
            .child(
                div()
                    .text_size(px(12.0))
                    .text_color(palette.ink)
                    .child(error),
            )
            .children(hint.map(|hint| {
                div()
                    .text_size(px(11.0))
                    .text_color(palette.ink_3)
                    .child(hint)
            }))
            .children(can_retry.then(|| {
                div()
                    .id("native-agent-retry")
                    .role(Role::Button)
                    .aria_label("重试")
                    .mt(px(2.0))
                    .px(space(2))
                    .py(px(3.0))
                    .rounded(px(RADIUS_SMALL))
                    .bg(palette.accent)
                    .text_color(palette.canvas)
                    .text_size(px(12.0))
                    .hover(|style| style.opacity(0.9))
                    .child("重试")
                    .on_click(cx.listener(|this, _, _, cx| this.retry_last_turn(cx)))
            }))
            .into_any_element()
    }

    /// 一组消息操作按钮（对齐 Zed：默认 40% 透明，hover 提亮）。
    ///
    /// gating 与复制内容来自 `agent_ui::message_flow`，与 ACP 栈共用同一份实现；
    /// 这里只负责 native 的渲染与元素 id。
    fn render_message_actions(
        &self,
        id_prefix: &str,
        copy_text: Option<String>,
        plan: message_flow::ActionPlan,
        palette: theme::Palette,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let view = cx.entity().downgrade();
        let mut callbacks = ActionCallbacks::default();
        if let Some(copy_text) = copy_text {
            callbacks.on_copy = Some(Box::new(move |cx: &mut App| {
                cx.write_to_clipboard(ClipboardItem::new_string(copy_text.clone()));
            }));
        }
        if let Some(user_index) = plan.scroll_to_user {
            let user_view = view.clone();
            callbacks.on_scroll_user = Some(Box::new(move |cx: &mut App| {
                let _ =
                    user_view.update(cx, |this, cx| this.scroll_to_user_message(user_index, cx));
            }));
        }
        if plan.scroll_to_top {
            let top_view = view;
            callbacks.on_scroll_top = Some(Box::new(move |cx: &mut App| {
                let _ = top_view.update(cx, |this, cx| this.scroll_messages_to_top(cx));
            }));
        }
        render_action_bar(ActionBarSpec {
            row_id: SharedString::from(format!("{id_prefix}-row")),
            copy_id: SharedString::from(format!("{id_prefix}-copy")),
            user_id: SharedString::from(format!("{id_prefix}-user")),
            top_id: SharedString::from(format!("{id_prefix}-top")),
            glyphs: native_action_glyphs(),
            style: native_action_style(palette),
            callbacks,
        })
    }

    /// 滚到指定用户消息（再映射到 MessageScroller 的 item index）。
    fn scroll_to_user_message(&mut self, user_index: usize, cx: &mut Context<Self>) {
        let kinds = self.message_row_kinds();
        if let Some(row) = kinds
            .iter()
            .position(|kind| *kind == MessageRowKind::Message(user_index))
        {
            self.message_scroller.update(cx, |state, cx| {
                let _ = state.scroll_to_item(row, cx);
            });
            cx.notify();
        }
    }

    /// 线程末尾兜底操作栏：回合停在工具卡等非 assistant 行时，在底部补一条
    /// （对齐 Zed #61245 的 last-assistant fallback）。
    fn render_trailing_actions(
        &self,
        palette: theme::Palette,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let Some(plan) = row_view(&self.state.messages).trailing_plan(
            self.is_generating(),
            self.state.pending_permission.is_some(),
        ) else {
            return div().into_any_element();
        };
        self.render_message_actions(
            "native-trailing-actions",
            row_view(&self.state.messages).turn_copy_text(plan.assistant_index),
            message_flow::ActionPlan {
                scroll_to_user: plan.scroll_to_user,
                scroll_to_top: true,
            },
            palette,
            cx,
        )
    }

    /// 消息区当前的行序列（历史消息 + 内联子 agent + 流式/错误行 + 兜底操作栏）。
    fn message_row_kinds(&self) -> Vec<MessageRowKind> {
        let mut kinds = build_message_row_kinds(
            &self.state.messages,
            &self.state.subagents,
            !self.state.thinking_streaming.is_empty(),
            !self.state.streaming.is_empty(),
            self.state.last_error.is_some(),
        );
        if row_view(&self.state.messages)
            .trailing_plan(
                self.is_generating(),
                self.state.pending_permission.is_some(),
            )
            .is_some()
        {
            kinds.push(MessageRowKind::TrailingActions);
        }
        kinds
    }

    /// 行数变化时增量增删列表行；行高变化时只 remeasure 对应行。
    fn sync_message_scroller(&mut self, row_kinds: &[MessageRowKind], cx: &mut Context<Self>) {
        let desired = row_kinds.len();
        let current = self.message_scroller.read(cx).item_count();
        let signatures: Vec<u64> = row_kinds
            .iter()
            .map(|kind| self.message_row_signature(*kind))
            .collect();
        if desired > current {
            self.message_scroller
                .update(cx, |state, cx| state.append(desired - current, cx));
            if current == 0 {
                // 首次填充（打开线程/启动恢复）：Tail 跟随可能被开窗时的
                // bounce/scroll 事件打断，显式滚到底并重新开启跟随。
                self.message_scroller
                    .update(cx, |state, cx| state.scroll_to_end(cx));
            }
        } else if desired < current {
            self.message_scroller
                .update(cx, |state, cx| state.splice(desired..current, 0, cx));
        } else if self.message_row_signatures.len() == signatures.len() {
            for (index, (new, old)) in signatures
                .iter()
                .zip(self.message_row_signatures.iter())
                .enumerate()
            {
                if new != old {
                    self.message_scroller.update(cx, |state, cx| {
                        let _ = state.remeasure_items(index..index + 1, cx);
                    });
                }
            }
        }
        self.message_row_signatures = signatures;
    }

    /// 行高签名：只含影响布局的字段，避免流式 token 触发全表重测。
    fn message_row_signature(&self, kind: MessageRowKind) -> u64 {
        use std::hash::{Hash as _, Hasher as _};
        let mut hasher = std::collections::hash_map::DefaultHasher::new();
        match kind {
            MessageRowKind::Message(index) => {
                0u8.hash(&mut hasher);
                if let Some(message) = self.state.messages.get(index) {
                    format!("{:?}", message.role).hash(&mut hasher);
                    message.text.len().hash(&mut hasher);
                    self.expanded_thinking.contains(&index).hash(&mut hasher);
                    (self.editing_user == Some(index)).hash(&mut hasher);
                    message.tool_call_id.hash(&mut hasher);
                    let tool_expanded = message
                        .tool_call_id
                        .as_deref()
                        .is_some_and(|id| self.expanded_tools.contains(id));
                    tool_expanded.hash(&mut hasher);
                    self.sent_images
                        .get(&index)
                        .map(|images| images.len())
                        .hash(&mut hasher);
                }
            }
            MessageRowKind::Subagent(index) => {
                1u8.hash(&mut hasher);
                if let Some(card) = self.state.subagents.get(index) {
                    card.text.len().hash(&mut hasher);
                    card.finished.hash(&mut hasher);
                }
            }
            MessageRowKind::LiveThinking => {
                2u8.hash(&mut hasher);
                self.state.thinking_streaming.len().hash(&mut hasher);
                self.live_thinking_collapsed.hash(&mut hasher);
            }
            MessageRowKind::Streaming => {
                3u8.hash(&mut hasher);
                self.state.streaming.len().hash(&mut hasher);
            }
            MessageRowKind::Error => {
                4u8.hash(&mut hasher);
                self.state
                    .last_error
                    .as_ref()
                    .map(String::len)
                    .hash(&mut hasher);
                self.state.retry_available().hash(&mut hasher);
            }
            MessageRowKind::TrailingActions => {
                5u8.hash(&mut hasher);
            }
        }
        hasher.finish()
    }

    /// 分发一行到对应的渲染函数。
    fn render_message_row(
        &self,
        kind: MessageRowKind,
        menu_root: &WeakEntity<Self>,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let palette = theme::palette_from_theme(cx);
        match kind {
            MessageRowKind::Message(index) => {
                self.render_message_row_element(index, palette, menu_root, cx)
            }
            MessageRowKind::Subagent(index) => self
                .state
                .subagents
                .get(index)
                .map(|card| render_subagent_row(card, &palette))
                .unwrap_or_else(|| div().into_any_element()),
            MessageRowKind::LiveThinking => self.render_live_thinking_row(palette, cx),
            MessageRowKind::Streaming => self.render_streaming_row(palette, menu_root),
            MessageRowKind::Error => self.render_error_row(palette, cx),
            MessageRowKind::TrailingActions => self.render_trailing_actions(palette, cx),
        }
    }
}

impl Render for NativeAgentView {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        // 页面 scope 变化时先切换工作区/线程，再渲染。
        self.ensure_scope(cx);
        let add_menu_root = cx.entity().downgrade();
        let model_supports_images = self.model_supports_images();
        let palette = theme::palette_from_theme(cx);
        let chip_workspace = self.context.workspace().to_path_buf();
        let busy = self.busy;
        let pending = self.state.pending_permission.clone();
        let usage = self.state.usage_total.total();
        let input = self.input.clone();
        let input_focus = self.input.read(cx).focus_handle(cx).clone();
        let input_value = self.input.read(cx).value().to_string();
        let has_input = !input_value.trim().is_empty();
        let slash_open = input_value.trim_start().starts_with('/') && !self.slash_dismissed;
        let slash_matches = self.slash_entries(&input_value);
        let slash_selected = self.slash_index.min(slash_matches.len().saturating_sub(1));
        let mention = trailing_mention(&input_value);
        let mention_matches = mention
            .as_ref()
            .map(|(_, query)| self.mention_matches(query))
            .unwrap_or_default();
        let mention_open = mention.is_some() && !slash_open && !mention_matches.is_empty();
        let mention_selected = self
            .mention_index
            .min(mention_matches.len().saturating_sub(1));
        let can_undo = self.last_checkpoint.is_some() && !busy;
        let change_count = self.checkpoint_changes.len();
        let plan_state = self
            .agent_state
            .lock()
            .map(|state| state.clone())
            .unwrap_or_default();
        let queued_messages = self.queued_messages.clone();
        let show_plan_card = !plan_state.todos.is_empty()
            || !plan_state.plan.is_empty()
            || plan_state.goal.is_some();
        let show_changes = self.show_checkpoint_panel && change_count > 0;
        let changes = self.checkpoint_changes.clone();
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
                            div()
                                .w_full()
                                .max_w(px(850.0))
                                .mx_auto()
                                .child(row)
                                .into_any_element()
                        },
                    )
                    .scrollbar(true)
                    .jump_button(true)
                    .with_jump_button_label("回到最新")
                    .with_list_style(StyleRefinement::default().p(space(3)))
                    .with_row_style(StyleRefinement::default().pb(space(2))),
                ),
            )
            .children(show_changes.then(|| {
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
                                    .on_click(cx.listener(|this, _, _window, cx| {
                                        this.keep_all_changes(cx)
                                    })),
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
                                    .on_click(cx.listener(|this, _, _window, cx| {
                                        this.reject_all_changes(cx)
                                    })),
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
                                    .child(format!("{} {}", change.status, change.path)),
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
            }))
            .children(pending.map(|prompt| {
                let args = serde_json::to_string(&prompt.args).unwrap_or_default();
                let args: String = args.chars().take(400).collect();
                let description = match prompt.tool_name.as_str() {
                    "run_command" => "将在工作区内执行 shell 命令（危险命令已被策略拦截）",
                    "write_file" | "edit_file" => "将修改工作区文件，可在完成后用 Keep/Reject 处理",
                    "read_file" | "list_directory" => "将读取工作区内容",
                    _ => "该操作需要你的确认",
                };
                let pattern_prefix = prompt
                    .args
                    .get("command")
                    .and_then(|value| value.as_str())
                    .and_then(|command| command.split_whitespace().next())
                    .map(str::to_string)
                    .or_else(|| {
                        prompt
                            .args
                            .get("path")
                            .and_then(|value| value.as_str())
                            .and_then(|path| path.rsplit_once('/').map(|(dir, _)| dir.to_string()))
                    })
                    .filter(|prefix| !prefix.is_empty());
                div()
                    .id("native-agent-permission")
                    .flex()
                    .flex_col()
                    .gap(space(1))
                    .mx(space(2))
                    .mb(space(2))
                    .p(space(2))
                    .rounded(px(RADIUS_MEDIUM))
                    .border_1()
                    .border_color(palette.line)
                    .bg(palette.card)
                    .child(
                        div()
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap(space(1))
                            .child(
                                div()
                                    .text_size(px(12.0))
                                    .text_color(palette.ink)
                                    .child("需要审批"),
                            )
                            .child(
                                div()
                                    .px(space(1))
                                    .rounded(px(RADIUS_SMALL))
                                    .bg(palette.soft)
                                    .text_size(px(10.0))
                                    .text_color(palette.accent)
                                    .child(prompt.tool_name.clone()),
                            ),
                    )
                    .child(
                        div()
                            .text_size(px(11.0))
                            .text_color(palette.ink_3)
                            .child(description),
                    )
                    .child(
                        div()
                            .p(space(1))
                            .rounded(px(RADIUS_SMALL))
                            .bg(palette.view)
                            .text_size(px(11.0))
                            .text_color(palette.ink_2)
                            .child(args),
                    )
                    .child(
                        div()
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap(space(2))
                            .child(approval_button("允许一次", true, cx, |this, cx| {
                                this.resolve_approval(ApprovalDecision::AllowOnce, cx);
                            }))
                            .child(approval_button("本会话允许", false, cx, |this, cx| {
                                this.resolve_approval(ApprovalDecision::AllowForSession, cx);
                            }))
                            .children(pattern_prefix.map(|prefix| {
                                div()
                                    .id("native-agent-allow-pattern")
                                    .role(Role::Button)
                                    .aria_label(format!("本会话允许 {prefix} 前缀"))
                                    .px(space(2))
                                    .py(space(1))
                                    .rounded(px(RADIUS_MEDIUM))
                                    .text_size(px(12.0))
                                    .text_color(palette.ink_2)
                                    .hover(|style| style.bg(palette.soft))
                                    .child(format!("允许 `{prefix}` 前缀"))
                                    .on_click(cx.listener(move |this, _, _window, cx| {
                                        this.resolve_approval(
                                            ApprovalDecision::AllowPattern(prefix.clone()),
                                            cx,
                                        );
                                    }))
                            }))
                            .child({
                                div()
                                    .id("native-agent-deny")
                                    .role(Role::Button)
                                    .aria_label("拒绝")
                                    .px(space(2))
                                    .py(space(1))
                                    .rounded(px(RADIUS_MEDIUM))
                                    .text_size(px(12.0))
                                    .text_color(palette.danger)
                                    .hover(|style| style.bg(palette.soft))
                                    .child("拒绝")
                                    .on_click(cx.listener(|this, _, _window, cx| {
                                        this.resolve_approval(ApprovalDecision::Deny, cx);
                                    }))
                            }),
                    )
                    .child(
                        div()
                            .text_size(px(10.0))
                            .text_color(palette.ink_3)
                            .child("允许一次只对本次调用生效；本会话允许会记住该工具的同类请求。"),
                    )
            }))
            .children((!queued_messages.is_empty()).then(|| {
                div()
                    .id("native-agent-queue")
                    .flex()
                    .flex_col()
                    .gap(px(2.0))
                    .mx(space(2))
                    .mb(space(1))
                    .p(space(2))
                    .rounded(px(RADIUS_MEDIUM))
                    .border_1()
                    .border_color(palette.line)
                    .bg(palette.view)
                    .child(
                        div()
                            .text_size(px(10.0))
                            .text_color(palette.ink_3)
                            .child(format!(
                                "排队中 {} 条 · 当前 turn 结束后自动发送",
                                queued_messages.len()
                            )),
                    )
                    .children(queued_messages.iter().enumerate().map(|(index, queued)| {
                        let preview: String = queued.display.chars().take(160).collect();
                        let remove_view = cx.entity().downgrade();
                        div()
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap(space(1))
                            .child(
                                div()
                                    .flex_1()
                                    .text_size(px(11.0))
                                    .text_color(palette.ink_2)
                                    .child(preview),
                            )
                            .child(
                                div()
                                    .id(SharedString::from(format!("native-queue-remove-{index}")))
                                    .role(Role::Button)
                                    .aria_label("取消排队消息")
                                    .px(space(1))
                                    .rounded(px(RADIUS_SMALL))
                                    .text_size(px(11.0))
                                    .text_color(palette.ink_3)
                                    .hover(|style| style.bg(palette.soft))
                                    .child("×")
                                    .on_click(move |_, _, cx| {
                                        let _ = remove_view.update(cx, |this, cx| {
                                            if index < this.queued_messages.len() {
                                                this.queued_messages.remove(index);
                                                cx.notify();
                                            }
                                        });
                                    }),
                            )
                    }))
            }))
            .children(show_plan_card.then(|| {
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
                div()
                    .id("native-agent-plan-card")
                    .flex()
                    .flex_col()
                    .gap(px(3.0))
                    .mx(space(2))
                    .mb(space(1))
                    .p(space(2))
                    .rounded(px(RADIUS_MEDIUM))
                    .border_1()
                    .border_color(palette.line)
                    .bg(palette.card)
                    .child(
                        div()
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap(space(2))
                            .child(div().text_size(px(12.0)).child("计划"))
                            .children((plan_state.goal.is_some()).then(|| {
                                div()
                                    .flex_1()
                                    .text_size(px(11.0))
                                    .text_color(palette.ink_2)
                                    .child(format!(
                                        "目标：{}",
                                        plan_state
                                            .goal
                                            .as_ref()
                                            .map(|goal| goal.objective.clone())
                                            .unwrap_or_default()
                                    ))
                            }))
                            .child(div().text_size(px(10.0)).text_color(palette.ink_3).child(
                                format!(
                                    "计划 {plan_done}/{} · 待办 {todo_done}/{}",
                                    plan_state.plan.len(),
                                    plan_state.todos.len()
                                ),
                            )),
                    )
                    .children(plan_state.plan.iter().take(6).map(|step| {
                        let (glyph, color) = status(step.status);
                        div()
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap(space(1))
                            .child(
                                div()
                                    .w(px(12.0))
                                    .text_size(px(11.0))
                                    .text_color(color)
                                    .child(glyph),
                            )
                            .child(
                                div()
                                    .text_size(px(11.0))
                                    .text_color(palette.ink_2)
                                    .child(step.title.clone()),
                            )
                    }))
                    .children(plan_state.todos.iter().take(5).map(|todo| {
                        let (glyph, color) = status(todo.status);
                        div()
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap(space(1))
                            .child(
                                div()
                                    .w(px(12.0))
                                    .text_size(px(11.0))
                                    .text_color(color)
                                    .child(glyph),
                            )
                            .child(
                                div()
                                    .text_size(px(11.0))
                                    .text_color(palette.ink_2)
                                    .child(todo.content.clone()),
                            )
                    }))
                    .children(
                        (!plan_state.todos.is_empty())
                            .then(|| {
                                div()
                                    .text_size(px(10.0))
                                    .text_color(palette.ink_3)
                                    .child("待办")
                            })
                            .filter(|_| !plan_state.plan.is_empty()),
                    )
            }))
            .child({
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
                let palette_copy = palette;
                let model_id_for_label = current_model_id.clone();
                let model_picker = Popover::new("native-model-picker")
                        .anchor(Anchor::BottomRight)
                    .trigger(
                        Button::new("native-model-trigger")
                            .label(model_id_for_label)
                            .xsmall()
                            .ghost()
                            .tooltip("选择模型"),
                    )
                    .content(move |_, _, cx| {
                        let dismiss = cx.entity().downgrade();
                        let mut rows: Vec<AnyElement> = Vec::new();
                        for provider in &providers_for_menu {
                            rows.push(
                                div()
                                    .px(space(1))
                                    .pt(px(4.0))
                                    .pb(px(2.0))
                                    .text_size(px(9.0))
                                    .text_color(palette_copy.ink_3)
                                    .child(provider.name.clone())
                                    .into_any_element(),
                            );
                            for model in &provider.models {
                                if !provider.model_config(model).enabled {
                                    continue;
                                }
                                let provider_id = provider.id.clone();
                                let model_id = model.clone();
                                let root = model_root.clone();
                                let row_dismiss = dismiss.clone();
                                let selected = provider_id == current_provider_id
                                    && model_id == current_model_id;
                                rows.push(
                                    div()
                                        .id(SharedString::from(format!(
                                            "native-model-{}-{}",
                                            provider_id, model_id
                                        )))
                                        .flex()
                                        .flex_row()
                                        .items_center()
                                        .justify_between()
                                        .gap(space(2))
                                        .px(space(1))
                                        .py(px(3.0))
                                        .rounded(px(RADIUS_MEDIUM))
                                        .text_size(px(11.0))
                                        .text_color(if selected {
                                            palette_copy.accent
                                        } else {
                                            palette_copy.ink_2
                                        })
                                        .hover(|style| style.bg(palette_copy.soft))
                                        .child(model.clone())
                                        .children(selected.then_some("✓"))
                                        .on_click(move |_, window, cx| {
                                            let _ = root.update(cx, |this, cx| {
                                                this.select_model(
                                                    provider_id.clone(),
                                                    model_id.clone(),
                                                    cx,
                                                );
                                            });
                                            let _ = row_dismiss
                                                .update(cx, |state, cx| state.dismiss(window, cx));
                                        })
                                        .into_any_element(),
                                );
                            }
                        }
                        div()
                            .id("native-model-options")
                            .flex()
                            .flex_col()
                            .gap(px(1.0))
                            .w(px(240.0))
                            .max_h(px(280.0))
                            .overflow_y_scroll()
                            .occlude()
                            .children(rows)
                    });
                let current_effort = self
                    .effort_index
                    .min(effort_levels.len().saturating_sub(1));
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
                let effort_levels_for_menu = effort_levels.clone();
                let effort_picker = (thinking_supported && !effort_levels.is_empty()).then(|| {
                    Popover::new("native-thinking-picker")
                        .anchor(Anchor::BottomRight)
                        .trigger(
                            Button::new("native-thinking-trigger")
                                .label(thinking_label)
                                .xsmall()
                                .ghost()
                                .tooltip("推理强度"),
                        )
                        .content(move |_, _, cx| {
                            let dismiss = cx.entity().downgrade();
                            let rows = effort_levels_for_menu
                            .iter()
                            .cloned()
                            .enumerate()
                            .map(|(level_index, label)| {
                                let root = thinking_root.clone();
                                let row_dismiss = dismiss.clone();
                                let selected = level_index == current_effort;
                                div()
                                    .id(SharedString::from(format!("native-thinking-{label}")))
                                    .flex()
                                    .flex_row()
                                    .items_center()
                                    .justify_between()
                                    .gap(space(2))
                                    .px(space(1))
                                    .py(px(3.0))
                                    .rounded(px(RADIUS_MEDIUM))
                                    .text_size(px(11.0))
                                    .text_color(if selected {
                                        palette_copy.accent
                                    } else if thinking_supported {
                                        palette_copy.ink_2
                                    } else {
                                        palette_copy.ink_3
                                    })
                                    .hover(|style| style.bg(palette_copy.soft))
                                    .child(label)
                                    .children(selected.then_some("✓"))
                                    .on_click(move |_, window, cx| {
                                        if !thinking_supported {
                                            return;
                                        }
                                        let _ = root.update(cx, |this, cx| {
                                            if !this.thinking_enabled {
                                                this.set_thinking_enabled(true, cx);
                                            }
                                            this.set_effort_index(level_index, cx);
                                        });
                                        let _ = row_dismiss
                                            .update(cx, |state, cx| state.dismiss(window, cx));
                                    })
                                    .into_any_element()
                            })
                            .collect::<Vec<_>>();
                            let off_root = thinking_root.clone();
                            let off_dismiss = dismiss.clone();
                            let off_selected = !thinking_enabled;
                            let off_row = div()
                                .id("native-thinking-off")
                                .flex()
                                .flex_row()
                                .items_center()
                                .justify_between()
                                .gap(space(2))
                                .px(space(1))
                                .py(px(3.0))
                                .rounded(px(RADIUS_MEDIUM))
                                .text_size(px(11.0))
                                .text_color(if off_selected {
                                    palette_copy.accent
                                } else {
                                    palette_copy.ink_2
                                })
                                .hover(|style| style.bg(palette_copy.soft))
                                .child("Off")
                                .children(off_selected.then_some("✓"))
                                .on_click(move |_, window, cx| {
                                    let _ = off_root.update(cx, |this, cx| {
                                        this.set_thinking_enabled(false, cx);
                                    });
                                    let _ = off_dismiss
                                        .update(cx, |state, cx| state.dismiss(window, cx));
                                })
                                .into_any_element();
                            div()
                                .id("native-thinking-options")
                                .flex()
                                .flex_col()
                                .gap(px(1.0))
                                .w(px(160.0))
                                .occlude()
                                .children(rows)
                                .child(off_row)
                        })
                });
                let current_approval = self.approval_mode;
                let approval_picker = Popover::new("native-approval-picker")
                    .anchor(Anchor::BottomRight)
                    .trigger(
                        Button::new("native-approval-trigger")
                            .label(current_approval.label())
                            .xsmall()
                            .ghost()
                            .tooltip("审批模式"),
                    )
                    .content(move |_, _, cx| {
                        let dismiss = cx.entity().downgrade();
                        let rows = [ApprovalMode::Ask, ApprovalMode::Auto]
                            .into_iter()
                            .map(|mode| {
                                let root = approval_root.clone();
                                let row_dismiss = dismiss.clone();
                                let selected = mode == current_approval;
                                div()
                                    .id(SharedString::from(format!(
                                        "native-approval-{}",
                                        mode.label()
                                    )))
                                    .flex()
                                    .flex_row()
                                    .items_center()
                                    .justify_between()
                                    .gap(space(2))
                                    .px(space(1))
                                    .py(px(3.0))
                                    .rounded(px(RADIUS_MEDIUM))
                                    .text_size(px(11.0))
                                    .text_color(if selected {
                                        palette_copy.accent
                                    } else {
                                        palette_copy.ink_2
                                    })
                                    .hover(|style| style.bg(palette_copy.soft))
                                    .child(match mode {
                                        ApprovalMode::Ask => "Ask（逐次审批）",
                                        ApprovalMode::Auto => "Auto（自动允许）",
                                    })
                                    .children(selected.then_some("✓"))
                                    .on_click(move |_, window, cx| {
                                        let _ = root.update(cx, |this, cx| {
                                            this.set_approval_mode(mode, cx);
                                        });
                                        let _ = row_dismiss
                                            .update(cx, |state, cx| state.dismiss(window, cx));
                                    })
                                    .into_any_element()
                            })
                            .collect::<Vec<_>>();
                        div()
                            .id("native-approval-options")
                            .flex()
                            .flex_col()
                            .gap(px(1.0))
                            .w(px(200.0))
                            .occlude()
                            .children(rows)
                    });

                let send_aria = if busy {
                    if has_input {
                        "发送（排队）"
                    } else {
                        "停止"
                    }
                } else {
                    "发送"
                };
                let send_label = if busy {
                    if has_input {
                        "⏳"
                    } else {
                        "■"
                    }
                } else {
                    "↑"
                };
                let send_bg = if busy && !has_input {
                    palette.danger
                } else if !busy && !has_input {
                    palette.soft
                } else {
                    palette.accent
                };
                let send_fg = if !busy && !has_input {
                    palette.ink_3
                } else {
                    palette.canvas
                };
                let send_tip = if busy {
                    if has_input {
                        "排队发送（⌘↩ 立即打断发送）"
                    } else {
                        "停止生成"
                    }
                } else if has_input {
                    "发送（Enter）"
                } else {
                    "输入内容后可发送"
                };
                let context_window = self.model.limits.context_window.max(1) as u64;
                let used_percent = if context_window == 0 {
                    0
                } else {
                    ((usage as f64 / context_window as f64) * 100.0).round() as u64
                };
                let context_summary = format!(
                    "{used_percent}% · {} / {}",
                    humanize_tokens(usage),
                    humanize_tokens(context_window)
                );
                let usage_total = self.state.usage_total;
                let usage_breakdown = format!(
                    "输入 {} · 输出 {} · 缓存读 {}",
                    humanize_tokens(usage_total.input),
                    humanize_tokens(usage_total.output),
                    humanize_tokens(usage_total.cache_read)
                );
                let context_usage = HoverCard::new("native-context-usage")
                    .anchor(Anchor::BottomCenter)
                    .trigger(
                        div()
                            .text_size(px(10.0))
                            .text_color(palette.ink_3)
                            .child(context_summary.clone()),
                    )
                    .content(move |_, _, _| {
                        div()
                            .w(px(190.0))
                            .p(space(1))
                            .rounded(px(RADIUS_MEDIUM))
                            .border_1()
                            .border_color(palette.line)
                            .bg(palette.card)
                            .child(
                                div()
                                    .text_size(px(10.0))
                                    .text_color(palette.ink_3)
                                    .child("Context"),
                            )
                            .child(
                                div()
                                    .text_size(px(11.0))
                                    .text_color(palette.ink_2)
                                    .child(context_summary.clone()),
                            )
                            .child(
                                div()
                                    .text_size(px(10.0))
                                    .text_color(palette.ink_3)
                                    .child("Tokens"),
                            )
                            .child(
                                div()
                                    .text_size(px(11.0))
                                    .text_color(palette.ink_2)
                                    .child(usage_breakdown.clone()),
                            )
                            .into_any_element()
                    });

                div()
                    .id("native-agent-composer")
                    .relative()
                    .flex()
                    .flex_col()
                    .gap(px(1.0))
                    .mx(space(2))
                    .mb(space(2))
                    .p(space(1))
                    .rounded(px(RADIUS_MEDIUM))
                    .border_1()
                    .border_color(palette.line)
                    .bg(palette.view)
                    .capture_key_down(cx.listener(|this, event: &KeyDownEvent, _window, cx| {
                        if event.keystroke.key == "v" && event.keystroke.modifiers.platform {
                            let has_image = cx
                                .read_from_clipboard()
                                .map(|item| {
                                    item.entries
                                        .iter()
                                        .any(|entry| matches!(entry, ClipboardEntry::Image(_)))
                                })
                                .unwrap_or(false);
                            if has_image {
                                this.add_clipboard_image(cx);
                                cx.stop_propagation();
                                return;
                            }
                        }
                        let value = this.input.read(cx).value().to_string();
                        if trailing_mention(&value).is_some() {
                            match event.keystroke.key.as_str() {
                                "up" => {
                                    this.mention_index = this.mention_index.saturating_sub(1);
                                    cx.stop_propagation();
                                    cx.notify();
                                }
                                "down" => {
                                    this.mention_index += 1;
                                    cx.stop_propagation();
                                    cx.notify();
                                }
                                _ => {}
                            }
                            return;
                        }
                        if !value.trim_start().starts_with('/') || this.slash_dismissed {
                            return;
                        }
                        match event.keystroke.key.as_str() {
                            "up" => {
                                this.slash_index = this.slash_index.saturating_sub(1);
                                cx.stop_propagation();
                                cx.notify();
                            }
                            "down" => {
                                this.slash_index += 1;
                                cx.stop_propagation();
                                cx.notify();
                            }
                            "escape" => {
                                this.slash_dismissed = true;
                                cx.stop_propagation();
                                cx.notify();
                            }
                            _ => {}
                        }
                    }))
                    .children((slash_open && !slash_matches.is_empty()).then(|| {
                        let mut rows: Vec<AnyElement> = Vec::new();
                        let mut last_category = "";
                        for (index, entry) in slash_matches.iter().enumerate() {
                            if entry.category != last_category {
                                last_category = entry.category;
                                rows.push(
                                    div()
                                        .px(space(1))
                                        .pt(px(2.0))
                                        .pb(px(1.0))
                                        .text_size(px(9.0))
                                        .text_color(palette.ink_3)
                                        .child(entry.category)
                                        .into_any_element(),
                                );
                            }
                            let selected = index == slash_selected;
                            let label = entry.label.clone();
                            let click_label = label.clone();
                            let tool = entry.tool.clone();
                            let skill = entry.skill.clone();
                            let scope = entry.scope.clone();
                            let description = entry.description.clone();
                            rows.push(
                                div()
                                    .id(SharedString::from(format!("native-slash-{index}")))
                                    .role(Role::Button)
                                    .aria_label(description.clone())
                                    .flex()
                                    .flex_row()
                                    .items_center()
                                    .gap(space(2))
                                    .px(space(1))
                                    .py(px(3.0))
                                    .rounded(px(RADIUS_SMALL))
                                    .bg(if selected {
                                        palette.soft
                                    } else {
                                        palette.card
                                    })
                                    .text_color(if selected {
                                        palette.accent
                                    } else {
                                        palette.ink_2
                                    })
                                    .child(
                                        div()
                                            .w(px(150.0))
                                            .truncate()
                                            .text_size(px(11.0))
                                            .child(label.clone()),
                                    )
                                    .children(scope.map(|scope| {
                                        div()
                                            .text_size(px(9.0))
                                            .text_color(palette.ink_3)
                                            .child(scope)
                                    }))
                                    .child(div().flex_1())
                                    .on_hover(cx.listener(
                                        move |this, hovered: &bool, _, cx| {
                                            if *hovered && this.slash_index != index {
                                                this.slash_index = index;
                                                cx.notify();
                                            }
                                        },
                                    ))
                                    .on_click(cx.listener(move |this, _, window, cx| {
                                        if let Some(tool) = tool.clone() {
                                            this.input.update(cx, |state, cx| {
                                                state.set_value(
                                                    format!("使用 {tool} 工具："),
                                                    window,
                                                    cx,
                                                )
                                            });
                                            this.slash_dismissed = true;
                                            this.slash_index = 0;
                                            cx.notify();
                                        } else if let Some(skill) = skill.clone() {
                                            this.insert_skill_mention(skill, window, cx);
                                        } else {
                                            this.run_slash_command(&click_label, window, cx);
                                        }
                                    }))
                                    .into_any_element(),
                            );
                        }
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
                        div()
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
                                    .id("native-agent-slash-menu")
                                    .flex()
                                    .flex_col()
                                    .gap(px(1.0))
                                    .w(px(300.0))
                                    .flex_none()
                                    .max_h(px(320.0))
                                    .overflow_y_scroll()
                                    .mx(space(1))
                                    .mt(space(1))
                                    .mb(px(2.0))
                                    .rounded(px(RADIUS_SMALL))
                                    .border_1()
                                    .border_color(palette.line)
                                    .bg(palette.card)
                                    .occlude()
                                    .children(rows),
                            )
                            .children(detail)
                    }))
                    .children(mention_open.then(|| {
                        let query = mention
                            .as_ref()
                            .map(|(_, query)| query.clone())
                            .unwrap_or_default();
                        div()
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
                    }))
                    .children((!self.pending_images.is_empty()).then(|| {
                        let rows = self
                            .pending_images
                            .iter()
                            .enumerate()
                            .map(|(index, image)| {
                                let remove_weak = cx.entity().downgrade();
                                let open_weak = cx.entity().downgrade();
                                let open_preview = image.preview.clone();
                                let open_name = image.name.clone();
                                let preview = image.preview.clone();
                                let trigger = div()
                                    .flex()
                                    .flex_row()
                                    .items_center()
                                    .gap(px(4.0))
                                    .child(match image.preview.clone() {
                                        Some(preview) => img(preview)
                                            .max_w(px(16.0))
                                            .max_h(px(16.0))
                                            .rounded(px(2.0))
                                            .into_any_element(),
                                        None => "🖼".into_any_element(),
                                    })
                                    .child(image.name.clone())
                                    .into_any_element();
                                div()
                                    .id(SharedString::from(format!(
                                        "native-image-chip-{index}"
                                    )))
                                    .flex()
                                    .flex_row()
                                    .items_center()
                                    .gap(px(4.0))
                                    .px(space(1))
                                    .py(px(1.0))
                                    .rounded(px(RADIUS_SMALL))
                                    .border_1()
                                    .border_color(palette.line)
                                    .text_size(px(11.0))
                                    .text_color(palette.ink_2)
                                    .on_click(move |_, _, cx| {
                                        if let Some(preview) = open_preview.clone() {
                                            let name = open_name.clone();
                                            let _ = open_weak.update(cx, |this, cx| {
                                                this.open_image_viewer(name, preview, cx);
                                            });
                                        }
                                    })
                                    .child(
                                        HoverCard::new(SharedString::from(format!(
                                            "native-image-hover-{index}"
                                        )))
                                        .anchor(Anchor::BottomCenter)
                                        .open_delay(std::time::Duration::from_millis(80))
                                        .trigger(trigger)
                                        .content(move |_, _, _| match preview.clone() {
                                            Some(preview) => div()
                                                .p(px(4.0))
                                                .rounded(px(RADIUS_SMALL))
                                                .border_1()
                                                .border_color(palette.line)
                                                .bg(palette.card)
                                                .child(
                                                    img(preview)
                                                        .max_w(px(280.0))
                                                        .max_h(px(180.0))
                                                        .rounded(px(RADIUS_SMALL)),
                                                )
                                                .into_any_element(),
                                            None => div().child("无预览").into_any_element(),
                                        }),
                                    )
                                    .child(
                                        div()
                                            .id(SharedString::from(format!(
                                                "native-image-remove-{index}"
                                            )))
                                            .role(Role::Button)
                                            .aria_label("移除图片")
                                            .px(px(3.0))
                                            .hover(|style| style.bg(palette.soft))
                                            .child("×")
                                            .on_click(move |_, _, cx| {
                                                let _ = remove_weak.update(cx, |this, cx| {
                                                    if index < this.pending_images.len() {
                                                        this.pending_images.remove(index);
                                                    }
                                                    cx.notify();
                                                });
                                            }),
                                    )
                                    .into_any_element()
                            })
                            .collect::<Vec<_>>();
                        div()
                            .flex()
                            .flex_row()
                            .flex_wrap()
                            .gap(space(1))
                            .px(space(1))
                            .pt(px(2.0))
                            .children(rows)
                    }))
                    .child(
                        div()
                            .relative()
                            .px(space(1))
                            .py(px(4.0))
                            .child(
                                Textarea::new(&input)
                                    .appearance(false)
                                    .bordered(false)
                                    .w_full()
                                    .token(move |context, _window, _cx| {
                                        render_mention_chip(context, palette, &chip_workspace)
                                    }),
                            )
                            .children((!has_input).then(|| {
                                // 自定义可换行 placeholder：gpui-base 的 Textarea
                                // placeholder 只按 \n 分行、不做宽度软换行
                                // （shape_line 未传宽度约束），窄面板会直接裁切；
                                // 上游修好前用 absolute overlay 折行并承担点击聚焦。
                                //
                                // 对齐 Textarea 的文字起点，否则光标与 placeholder 错行：
                                // overlay 从 wrapper 的 border box 顶/左起算，
                                //   top  = wrapper padding（py 4）
                                //        + gpui-component Input 多行编辑区 padding（top 8）
                                //   left = wrapper padding（space(1)）
                                //        + Input 编辑区 padding（left 10）
                                // 字号/行高与 Input 一致：text_sm 0.875rem、line_height 1.25rem。
                                let focus = input_focus.clone();
                                div()
                                    .id("native-agent-placeholder")
                                    .absolute()
                                    .top(px(4.0 + 8.0))
                                    .left(space(1) + px(10.0))
                                    .right(space(1) + px(10.0))
                                    .text_size(rems(0.875))
                                    .line_height(rems(1.25))
                                    .text_color(palette.ink_3)
                                    .child(
                                        "给 CGC Agent 发消息… @ 引用上下文，/ 查看命令（Enter 发送，Shift+Enter 换行）",
                                    )
                                    .on_click(move |_, window, cx| {
                                        window.focus(&focus, cx);
                                    })
                            })),
                    )
                    .child(
                        div()
                            .id("native-agent-composer-footer")
                            .flex()
                            .flex_row()
                            .flex_wrap()
                            .items_center()
                            .gap(space(1))
                            .w_full()
                            .min_w(px(0.0))
                            .child(
                                Popover::new("native-agent-add-menu")
                                .anchor(Anchor::BottomLeft)
                                    .trigger(
                                        Button::new("native-agent-add-context")
                                            .label("＋")
                                            .xsmall()
                                            .ghost()
                                            .tooltip("添加上下文"),
                                    )
                                    .content(move |_, _, cx| {
                                        let dismiss = cx.entity().downgrade();
                                        let root = add_menu_root.clone();
                                        let files_root = root.clone();
                                        let files_dismiss = dismiss.clone();
                                        let image_root = root.clone();
                                        let image_dismiss = dismiss;
                                        div()
                                            .w(px(240.0))
                                            .flex()
                                            .flex_col()
                                            .gap(px(1.0))
                                            .child(
                                                div()
                                                    .id("native-add-files")
                                                    .role(Role::Button)
                                                    .flex()
                                                    .flex_row()
                                                    .items_center()
                                                    .gap(space(1))
                                                    .px(space(1))
                                                    .py(px(3.0))
                                                    .rounded(px(RADIUS_MEDIUM))
                                                    .text_size(px(11.0))
                                                    .text_color(palette.ink_2)
                                                    .hover(|style| style.bg(palette.soft))
                                                    .child("📄")
                                                    .child("Files & Directories")
                                                    .on_click(move |_, window, cx| {
                                                        let _ = files_root.update(cx, |this, cx| {
                                                            this.insert_context_marker(window, cx);
                                                        });
                                                        let _ = files_dismiss
                                                            .update(cx, |state, cx| state.dismiss(window, cx));
                                                    }),
                                            )
                                            .children(model_supports_images.then(|| {
                                                div()
                                                    .id("native-add-image-menu")
                                                    .role(Role::Button)
                                                    .flex()
                                                    .flex_row()
                                                    .items_center()
                                                    .gap(space(1))
                                                    .px(space(1))
                                                    .py(px(3.0))
                                                    .rounded(px(RADIUS_MEDIUM))
                                                    .text_size(px(11.0))
                                                    .text_color(palette.ink_2)
                                                    .hover(|style| style.bg(palette.soft))
                                                    .child("🖼")
                                                    .child("Image")
                                                    .on_click(move |_, window, cx| {
                                                        let _ = image_root.update(cx, |this, cx| {
                                                            this.add_images_from_picker(cx);
                                                        });
                                                        let _ = image_dismiss
                                                            .update(cx, |state, cx| state.dismiss(window, cx));
                                                    })
                                            }))
                                            .into_any_element()
                                    }),
                            )
                            .child(div().flex_1())
                            .children((can_undo && change_count > 0).then(|| {
                                div()
                                    .id("native-agent-changes")
                                    .role(Role::Button)
                                    .aria_label("查看变更")
                                    .px(space(1))
                                    .py(px(2.0))
                                    .rounded(px(RADIUS_SMALL))
                                    .text_size(px(11.0))
                                    .text_color(palette.ink_2)
                                    .hover(|style| style.bg(palette.soft))
                                    .child(format!("变更 {change_count}"))
                                    .on_click(cx.listener(|this, _, _window, cx| {
                                        this.toggle_checkpoint_panel(cx)
                                    }))
                            }))
                            .children(can_undo.then(|| {
                                div()
                                    .id("native-agent-undo")
                                    .role(Role::Button)
                                    .aria_label("撤销文件改动")
                                    .px(space(1))
                                    .py(px(2.0))
                                    .rounded(px(RADIUS_SMALL))
                                    .text_size(px(11.0))
                                    .text_color(palette.ink_3)
                                    .hover(|style| style.bg(palette.soft))
                                    .child("撤销")
                                    .on_click(
                                        cx.listener(|this, _, _window, cx| {
                                            this.undo_checkpoint(cx)
                                        }),
                                    )
                            }))
                            .child(approval_picker)
                            .child(model_picker)
                            .children(effort_picker)
                            .child(context_usage)
                            .child(
                                div()
                                    .id(if busy {
                                        "native-agent-stop"
                                    } else {
                                        "native-agent-send"
                                    })
                                    .role(Role::Button)
                                    .aria_label(send_aria)
                                    .px(space(2))
                                    .py(px(3.0))
                                    .rounded(px(RADIUS_SMALL))
                                    .bg(send_bg)
                                    .text_color(send_fg)
                                    .text_size(px(12.0))
                                    .child(send_label)
                                    .tooltip(move |window, cx| {
                                        Tooltip::new(send_tip).build(window, cx)
                                    })
                                    .on_click(cx.listener(move |this, _, window, cx| {
                                        if busy && !has_input {
                                            this.stop(cx);
                                        } else {
                                            this.send(window, cx);
                                        }
                                    })),
                            ),
                    )
            })
    }
}

fn collect_workspace_files(root: &std::path::Path) -> Vec<String> {
    fn walk(dir: &std::path::Path, root: &std::path::Path, out: &mut Vec<String>) {
        if out.len() >= 1000 {
            return;
        }
        let Ok(entries) = std::fs::read_dir(dir) else {
            return;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            let name = entry.file_name().to_string_lossy().to_string();
            if name.starts_with('.')
                || matches!(name.as_str(), "target" | "node_modules" | "dist" | "build")
            {
                continue;
            }
            if path.is_dir() {
                walk(&path, root, out);
            } else if path.is_file() {
                if let Ok(relative) = path.strip_prefix(root) {
                    out.push(relative.to_string_lossy().replace('\\', "/"));
                }
            }
        }
    }
    let mut files = Vec::new();
    walk(root, root, &mut files);
    files.sort();
    files
}

fn trailing_mention(text: &str) -> Option<(usize, String)> {
    let position = text.rfind('@')?;
    if let Some(previous) = text[..position].chars().next_back() {
        if !previous.is_whitespace() {
            return None;
        }
    }
    let query = &text[position + 1..];
    if query.chars().any(char::is_whitespace) {
        return None;
    }
    Some((position, query.to_string()))
}

#[derive(Debug)]
struct SlashEntry {
    category: &'static str,
    label: String,
    description: String,
    tool: Option<String>,
    skill: Option<SkillEntry>,
    scope: Option<String>,
}

/// slash 菜单的匹配打分：名字精确 > 名字前缀 > 名字包含 > 描述包含。
///
/// 技能名匹配必须排在「工具描述里恰好包含同一个词」之前：
/// 例如 `/answer` 想选 `answer-me-with-html`，而 `task` 工具的描述里也有
/// "answer"——按固定类别顺序会让回车选错工具。
fn slash_match_rank(query: &str, name: &str, description: &str) -> Option<u8> {
    if query.is_empty() {
        return Some(0);
    }
    let name = name.to_ascii_lowercase();
    if name == query {
        Some(0)
    } else if name.starts_with(query) {
        Some(1)
    } else if name.contains(query) {
        Some(2)
    } else if description.to_ascii_lowercase().contains(query) {
        Some(3)
    } else {
        None
    }
}

fn slash_entries_for(
    registry: &ToolRegistry,
    skills: &[SkillEntry],
    value: &str,
) -> Vec<SlashEntry> {
    let trimmed = value.trim_start();
    let Some(raw_query) = trimmed.strip_prefix('/') else {
        return Vec::new();
    };
    let query = raw_query.trim().to_ascii_lowercase();

    // 分组内按 (匹配质量, 原始顺序) 排序；分组之间按「该组最好匹配」再按类别优先级。
    let commands: Vec<(u8, usize, SlashEntry)> = SLASH_COMMANDS
        .iter()
        .enumerate()
        .filter_map(|(index, (command, description))| {
            slash_match_rank(&query, command.trim_start_matches('/'), description).map(|rank| {
                (
                    rank,
                    index,
                    SlashEntry {
                        category: "命令",
                        label: (*command).to_string(),
                        description: (*description).to_string(),
                        tool: None,
                        skill: None,
                        scope: None,
                    },
                )
            })
        })
        .collect();
    let tools: Vec<(u8, usize, SlashEntry)> = registry
        .list_descriptions()
        .into_iter()
        .enumerate()
        .filter_map(|(index, (name, description))| {
            slash_match_rank(&query, name, description).map(|rank| {
                (
                    rank,
                    index,
                    SlashEntry {
                        category: "工具",
                        label: name.to_string(),
                        description: description.to_string(),
                        tool: Some(name.to_string()),
                        skill: None,
                        scope: None,
                    },
                )
            })
        })
        .collect();
    let skills_group: Vec<(u8, usize, SlashEntry)> = skills
        .iter()
        .enumerate()
        .filter_map(|(index, skill)| {
            slash_match_rank(&query, &skill.name, &skill.description).map(|rank| {
                (
                    rank,
                    index,
                    SlashEntry {
                        category: "技能",
                        label: skill.name.clone(),
                        description: skill.description.clone(),
                        tool: None,
                        skill: Some(skill.clone()),
                        scope: Some(skill.scope.clone()),
                    },
                )
            })
        })
        .collect();

    let mut groups = [(0usize, commands), (1, tools), (2, skills_group)];
    for (_, group) in groups.iter_mut() {
        group.sort_by_key(|(rank, index, _)| (*rank, *index));
    }
    groups.sort_by_key(|(priority, group)| {
        (
            group.first().map(|(rank, _, _)| *rank).unwrap_or(u8::MAX),
            *priority,
        )
    });
    groups
        .into_iter()
        .flat_map(|(_, group)| group.into_iter().map(|(_, _, entry)| entry))
        .collect()
}
/// 第 `ordinal` 条用户消息（1-based）对应的有效 checkpoint（未失效）。
/// 持久化记录 → (用户消息 ordinal, Checkpoint)：过滤 invalid / 非法 seq，按 ordinal 升序。
fn checkpoints_from_records(records: &[CheckpointRecord]) -> Vec<(usize, Checkpoint)> {
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
fn needs_checkpoint_confirm(
    has_valid_checkpoint: bool,
    pending: Option<usize>,
    message_index: usize,
) -> bool {
    !has_valid_checkpoint && pending != Some(message_index)
}

/// 消息操作栏的单图标按钮（hover 显示 tooltip，样式对齐 Zed 的 muted icon button）。
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

/// 每个 workspace scope 一条 native 线程（ADR-0028）。
fn scope_thread_id(scope: &crate::agent_scope::AgentScope) -> String {
    format!("native-{}", scope.key)
}

fn checkpoint_for_ordinal(
    records: &[cgc_agent_store::CheckpointRecord],
    ordinal: usize,
) -> Option<cgc_agent_store::CheckpointRecord> {
    records
        .iter()
        .find(|record| record.user_entry_seq == ordinal as i64 && record.state != "invalid")
        .cloned()
}

/// 第 `message_index` 条 UI 消息是第几条用户消息（1-based）。
fn user_message_ordinal(
    messages: &[cgc_agent_host::UiMessage],
    message_index: usize,
) -> Option<usize> {
    let message = messages.get(message_index)?;
    if message.role != UiRole::User {
        return None;
    }
    Some(
        messages[..=message_index]
            .iter()
            .filter(|message| message.role == UiRole::User)
            .count(),
    )
}

/// 第 `ordinal` 条用户消息（1-based）在 thread entries 里的下标。
fn thread_user_entry_index(entries: &[cgc_agent_core::Entry], ordinal: usize) -> Option<usize> {
    entries
        .iter()
        .enumerate()
        .filter(|(_, entry)| matches!(entry, cgc_agent_core::Entry::User { .. }))
        .nth(ordinal.checked_sub(1)?)
        .map(|(index, _)| index)
}

/// 流式思考开始（空 → 非空）时自动展开思考块（对齐 Zed 的 streaming thought）。
fn should_auto_expand_live_thinking(was_empty: bool, now_nonempty: bool) -> bool {
    was_empty && now_nonempty
}

/// 思考 flush 成正式 Thinking 消息后，把实时块的展开状态转移到该消息上。
fn transfer_live_thinking_expansion(
    messages: &[cgc_agent_host::UiMessage],
    live_collapsed: bool,
    expanded: &mut std::collections::HashSet<usize>,
) -> Option<usize> {
    let index = messages
        .iter()
        .rposition(|message| message.role == UiRole::Thinking)?;
    if live_collapsed {
        expanded.remove(&index);
    } else {
        expanded.insert(index);
    }
    Some(index)
}

/// 滚动是否已经在底部（GPUI 的 offset.y 越往下越负，max_offset 为正）。
/// 2px 容差避免亚像素/取整导致的“差一点点”抖动。
/// 消息区的行类型：历史消息、内联子 agent、流式思考、流式回复、错误，
/// 以及回合末不是 assistant 时的底部兜底操作栏（Zed 的 last-assistant fallback）。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum MessageRowKind {
    Message(usize),
    Subagent(usize),
    LiveThinking,
    Streaming,
    Error,
    TrailingActions,
}

/// 计算消息区的行序列；子 agent 卡内联到触发它的 tool 消息后面，
/// 其余子 agent 与流式/错误行按旧渲染顺序排在末尾。
fn build_message_row_kinds(
    messages: &[UiMessage],
    subagents: &[SubagentCard],
    has_live_thinking: bool,
    has_streaming: bool,
    has_error: bool,
) -> Vec<MessageRowKind> {
    let mut kinds = Vec::with_capacity(messages.len() + subagents.len() + 3);
    let mut used_subagents = vec![false; subagents.len()];
    for (message_index, message) in messages.iter().enumerate() {
        kinds.push(MessageRowKind::Message(message_index));
        if let Some(tool_call_id) = message.tool_call_id.as_deref() {
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
    if has_live_thinking {
        kinds.push(MessageRowKind::LiveThinking);
    }
    if has_streaming {
        kinds.push(MessageRowKind::Streaming);
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

/// 重试前把 UI 消息裁到最近一条用户消息为止，丢掉失败 turn 残留的部分回复/工具卡。
fn trim_messages_to_last_user(messages: &mut Vec<cgc_agent_host::UiMessage>) -> Option<usize> {
    let index = messages
        .iter()
        .rposition(|message| message.role == UiRole::User)?;
    messages.truncate(index + 1);
    Some(index)
}

fn tool_status_label(status: ToolCallStatus) -> &'static str {
    match status {
        ToolCallStatus::Running => "运行中…",
        ToolCallStatus::Ok => "完成",
        ToolCallStatus::Failed => "失败",
    }
}

/// 工具调用卡片：标题显示状态/名称，展开后展示 raw 参数与 raw 输出。
fn render_tool_card(
    tool: &UiToolCall,
    expanded: bool,
    palette: &theme::Palette,
    on_toggle: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static,
) -> AnyElement {
    let (glyph, status_color) = match tool.status {
        ToolCallStatus::Running => ("◐", palette.accent),
        ToolCallStatus::Ok => ("✓", palette.ink_3),
        ToolCallStatus::Failed => ("✗", palette.danger),
    };
    let args = if tool.args.is_null() {
        String::new()
    } else {
        serde_json::to_string_pretty(&tool.args).unwrap_or_else(|_| tool.args.to_string())
    };
    let content = tool.content.clone().unwrap_or_default();
    let body = expanded.then(|| {
        div()
            .flex()
            .flex_col()
            .gap(px(2.0))
            .px(space(2))
            .pb(space(1))
            .children((!args.is_empty()).then(|| {
                div()
                    .text_size(px(11.0))
                    .text_color(palette.ink)
                    .child(format!("参数\n{args}"))
            }))
            .children(
                (!content.is_empty() || matches!(tool.status, ToolCallStatus::Running)).then(
                    || {
                        div().text_size(px(11.0)).text_color(palette.ink).child(
                            if content.is_empty() {
                                "输出\n（等待输出…）".to_string()
                            } else {
                                format!("输出\n{content}")
                            },
                        )
                    },
                ),
            )
    });
    div()
        .id("native-tool-card")
        .flex()
        .flex_col()
        .gap(px(2.0))
        .rounded(px(RADIUS_SMALL))
        .border_1()
        .border_color(palette.line)
        .bg(palette.view)
        .child(
            div()
                .id("native-tool-card-header")
                .flex()
                .flex_row()
                .items_center()
                .gap(space(1))
                .px(space(2))
                .py(px(3.0))
                .hover(|style| style.bg(palette.soft))
                .child(
                    div()
                        .text_size(px(11.0))
                        .text_color(status_color)
                        .child(glyph),
                )
                .child(
                    div()
                        .font_family(theme::FONT_MONO)
                        .text_size(px(11.0))
                        .text_color(palette.ink_2)
                        .child(tool.name.clone()),
                )
                .child(
                    div()
                        .text_size(px(10.0))
                        .text_color(palette.ink_3)
                        .child(tool_status_label(tool.status)),
                )
                .child(div().flex_1())
                .child(
                    div()
                        .text_size(px(10.0))
                        .text_color(palette.ink_3)
                        .child(if expanded { "▾" } else { "▸" }),
                )
                .on_click(on_toggle),
        )
        .children(body)
        .into_any_element()
}

fn render_subagent_row(
    card: &cgc_agent_host::SubagentCard,
    palette: &theme::Palette,
) -> AnyElement {
    let status = match card.finished {
        None => "运行中…",
        Some(true) => "完成",
        Some(false) => "失败",
    };
    let preview: String = card.text.chars().take(300).collect();
    div()
        .flex()
        .flex_col()
        .gap(px(2.0))
        .p(space(1))
        .rounded(px(RADIUS_SMALL))
        .bg(palette.view)
        .child(
            div()
                .text_size(px(11.0))
                .text_color(palette.ink_2)
                .child(format!("子 agent · {status}：{}", card.task)),
        )
        .children((!preview.is_empty()).then(|| {
            div()
                .text_size(px(11.0))
                .text_color(palette.ink_3)
                .child(preview)
        }))
        .into_any_element()
}

/// 空线程时的引导提示（重发重建状态时需要剔除，避免显示在编辑后的对话顶部）。
const EMPTY_THREAD_NOTICE: &str = "Native agent：配置 Provider 后开始对话。";

fn role_label(role: UiRole) -> &'static str {
    match role {
        UiRole::User => "you",
        UiRole::Assistant => "agent",
        UiRole::Thinking => "thinking",
        UiRole::Tool => "tool",
        UiRole::System => "system",
        UiRole::Error => "error",
    }
}

/// 把 native 的 `UiMessage` 映射到共享消息流（`agent_ui::message_flow`）。
fn ui_row_kind(message: &UiMessage) -> RowKind {
    match message.role {
        UiRole::User => RowKind::User,
        UiRole::Assistant => RowKind::Assistant,
        UiRole::Thinking => RowKind::Thinking,
        UiRole::Tool => RowKind::Tool,
        UiRole::System | UiRole::Error => RowKind::Status,
    }
}

fn ui_assistant_text(message: &UiMessage) -> Option<&str> {
    (message.role == UiRole::Assistant).then_some(message.text.as_str())
}

/// native 消息行的共享只读视图（Stage 1：判定逻辑归 `agent_ui`）。
fn row_view(messages: &[UiMessage]) -> RowView<'_, UiMessage> {
    RowView::new(messages, ui_row_kind, ui_assistant_text)
}

/// 一条消息的三种复制载荷（对齐 Zed 的 Copy / Copy as Markdown /
/// native 侧把一行消息转成共享菜单载荷（user 的 plain 走 mention 展开）。
fn message_menu_payloads(role: UiRole, text: &str, agent_response: Option<String>) -> MenuPayloads {
    let plain = match role {
        UiRole::Assistant => markdown_to_plain(text),
        UiRole::User => mention::display_text(text),
        _ => text.to_string(),
    };
    MenuPayloads {
        plain,
        markdown: text.to_string(),
        agent_response,
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

/// 代码块 Copy 按钮的稳定 id（同内容同 id，不同内容不同 id，避免元素状态串台）。
fn code_block_copy_id(code: &str, lang: Option<&str>) -> String {
    use std::hash::{Hash as _, Hasher as _};
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    code.hash(&mut hasher);
    lang.unwrap_or_default().hash(&mut hasher);
    format!("native-copy-code-{:016x}", hasher.finish())
}

/// 构造 Markdown TextView（代码块右上角 Copy 按钮、文本可选中复制）。
///
/// `id` 决定 element state：流式渲染时复用同一个 id，gpui-base 会对追加的文本
/// 走 `push_str` 增量解析，而不是每帧重新 parse 全文。
fn markdown_text_view(id: impl Into<ElementId>, text: &str) -> TextView {
    TextView::markdown(id, sanitize_markdown(text))
        .selectable(true)
        .selection_format(SelectionFormat::Source)
        .code_block_actions(|code_block, _window, _cx| {
            let code = code_block.code().to_string();
            let id = code_block_copy_id(&code, code_block.lang().as_deref());
            Button::new(SharedString::from(id))
                .label("Copy")
                .xsmall()
                .ghost()
                .tooltip("Copy Code")
                .on_click(move |_, _, cx| {
                    cx.write_to_clipboard(ClipboardItem::new_string(code.clone()));
                })
        })
}

/// agent 回复用 Markdown 渲染。
fn render_assistant_markdown(message_index: usize, text: &str) -> AnyElement {
    markdown_text_view(format!("native-assistant-markdown-{message_index}"), text)
        .into_any_element()
}

/// composer 里的 mention chip：技能 / 文件各一个图标，hover 显示真实路径。
fn render_mention_chip(
    context: &InlineTokenContext,
    palette: theme::Palette,
    workspace: &std::path::Path,
) -> AnyElement {
    let mention = Mention::parse_token_id(context.token().id());
    let (icon, label, tooltip) = match mention {
        Some(mention) => (
            mention.chip_icon_path(),
            mention.chip_label(),
            mention.tooltip(workspace),
        ),
        None => (
            gpui_kit::assets::IconName::Bot.path(),
            context.token().label().to_string(),
            context.token().text().to_string(),
        ),
    };
    let selected = context.is_selected();
    div()
        .id(SharedString::from(format!(
            "native-mention-chip-{}-{}",
            context.token().id(),
            context.range().start
        )))
        .flex()
        .flex_row()
        .items_center()
        .gap(px(2.0))
        .h(context.line_height())
        .max_w(context.available_width())
        .px(px(4.0))
        .rounded(px(RADIUS_SMALL))
        .bg(if selected {
            palette.accent
        } else {
            palette.soft
        })
        .text_color(if selected {
            palette.canvas
        } else {
            palette.ink_2
        })
        .text_size(px(11.0))
        .child(Icon::default().path(icon).small())
        .child(div().truncate().child(label))
        .tooltip(move |window, cx| Tooltip::new(tooltip.clone()).build(window, cx))
        .into_any_element()
}

fn approval_button(
    label: &'static str,
    primary: bool,
    cx: &mut Context<NativeAgentView>,
    action: impl Fn(&mut NativeAgentView, &mut Context<NativeAgentView>) + 'static,
) -> AnyElement {
    let palette = theme::palette_from_theme(cx);
    div()
        .id(label)
        .role(Role::Button)
        .aria_label(label)
        .px(space(2))
        .py(space(1))
        .rounded(px(RADIUS_MEDIUM))
        .bg(if primary {
            palette.accent
        } else {
            palette.soft
        })
        .text_color(if primary { palette.canvas } else { palette.ink })
        .child(label)
        .on_click(cx.listener(move |this, _, _window, cx| action(this, cx)))
        .into_any_element()
}

fn truncate_text(text: &str, max_chars: usize) -> String {
    let mut out = text.chars().take(max_chars).collect::<String>();
    if text.chars().count() > max_chars {
        out.push('…');
    }
    out
}

fn clean_thread_title(raw: &str) -> String {
    raw.trim()
        .trim_matches(|ch| {
            matches!(
                ch,
                '"' | '\'' | '「' | '」' | '《' | '》' | '。' | '.' | '\n'
            )
        })
        .chars()
        .filter(|ch| *ch != '\n' && *ch != '\r')
        .take(40)
        .collect::<String>()
        .trim()
        .to_string()
}

fn humanize_tokens(count: u64) -> String {
    if count >= 1_000_000 {
        format!("{:.1}M", count as f64 / 1_000_000.0).replace(".0M", "M")
    } else if count >= 1_000 {
        format!("{:.1}k", count as f64 / 1_000.0).replace(".0k", "k")
    } else {
        count.to_string()
    }
}

/// 仅在没有可用 Provider 凭据（Echo 回退）时提示离线回显。
/// 认证 / 凭据类错误的额外指引（对齐 Zed 的 credentials 提示）。
fn retry_hint_for_error(error: &str) -> Option<&'static str> {
    let lower = error.to_lowercase();
    let credentials_issue = [
        "401",
        "403",
        "api key",
        "apikey",
        "unauthorized",
        "credential",
    ]
    .iter()
    .any(|needle| lower.contains(needle));
    credentials_issue
        .then_some("去 Settings → AI → LLM Providers 检查 Provider Key，保存后点「重试」。")
}

fn offline_echo_notice(using_echo: bool) -> Option<&'static str> {
    using_echo.then_some(
        "未配置可用的 Provider API Key，当前离线回显模式。请在 Settings → AI → LLM Providers 保存 Key 后重新打开 Agent 面板。",
    )
}

/// 启动时注入的工作区上下文：工作区根 + 规则文件（AGENTS/CLAUDE）。
fn build_workspace_system_prompt(workspace: &std::path::Path) -> String {
    let mut prompt = format!(
        "你运行在用户的本地工作区：{}\n可以读写工作区文件、执行命令；修改前先读相关文件。\n",
        workspace.display()
    );
    for relative in ["AGENTS.md", "CLAUDE.md", "desktop/AGENTS.md"] {
        let path = workspace.join(relative);
        let Ok(content) = std::fs::read_to_string(&path) else {
            continue;
        };
        let content = truncate_text(&content, 20_000);
        prompt.push_str(&format!(
            "\n<workspace_rules source=\"{relative}\">\n{content}\n</workspace_rules>\n"
        ));
    }
    prompt.push_str("\n遵循上述工作区规则；规则与用户指令冲突时以用户当前指令为准。");
    prompt
}

fn now_secs() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_secs() as i64)
        .unwrap_or_default()
}

#[cfg(test)]
mod workspace_prompt_tests {
    use super::{build_workspace_system_prompt, now_secs, offline_echo_notice};

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
            cgc_agent_host::UiRole::Assistant,
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

        let user = super::message_menu_payloads(
            cgc_agent_host::UiRole::User,
            "看 [@a](file://a.md) 这个",
            None,
        );
        assert_eq!(user.plain, "看 @a 这个");
        assert_eq!(user.markdown, "看 [@a](file://a.md) 这个");
        assert!(user.agent_response.is_none(), "用户消息没有 agent response");
    }

    #[test]
    fn ui_message_rows_use_shared_turn_gating_and_copy() {
        use cgc_agent_host::{UiMessage, UiRole};
        use cgc_agent_ui::message_flow::RowKind;
        let message = |role, text: &str| UiMessage {
            role,
            text: text.into(),
            tool_call_id: None,
            tool: None,
        };
        let messages = vec![
            message(UiRole::User, "q1"),
            message(UiRole::Assistant, "a1"),
            message(UiRole::Tool, "read_file"),
            message(UiRole::Assistant, "a2"),
            message(UiRole::User, "q2"),
            message(UiRole::Assistant, "a3"),
        ];
        assert_eq!(super::ui_row_kind(&messages[1]), RowKind::Assistant);
        assert_eq!(
            super::ui_assistant_text(&messages[2]),
            None,
            "tool 行没有 assistant 文本"
        );
        let rows = super::row_view(&messages);
        assert_eq!(
            rows.finalized_turn_end(3),
            Some(true),
            "下一条用户消息前的 assistant 才是回合末"
        );
        assert_eq!(rows.finalized_turn_end(1), Some(false));
        assert_eq!(
            rows.turn_copy_text(3).as_deref(),
            Some("a1\n\na2"),
            "Copy This Agent Response 复制整回合"
        );
        assert_eq!(rows.turn_copy_text(5).as_deref(), Some("a3"));
        assert_eq!(
            rows.action_plan(5, false, false)
                .map(|plan| plan.scroll_to_top),
            Some(true),
            "底部条允许 Scroll to Top"
        );
        assert_eq!(rows.action_plan(5, true, false), None, "生成中隐藏底部条");
    }

    #[test]
    fn code_block_copy_id_is_stable_and_unique() {
        let first = super::code_block_copy_id("fn main() {}", Some("rust"));
        let same = super::code_block_copy_id("fn main() {}", Some("rust"));
        let other = super::code_block_copy_id("fn main() { }", Some("rust"));
        assert_eq!(first, same);
        assert_ne!(first, other);
        assert!(first.starts_with("native-copy-code-"));
    }

    #[test]
    fn apply_thread_entries_builds_tool_cards_with_args() {
        use cgc_agent_core::Entry;
        use cgc_agent_host::{HostState, ToolCallStatus};
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
        let mut state = HostState::new();
        super::apply_thread_entries(&mut state, &entries);
        assert_eq!(state.messages.len(), 3, "user + tool card + thinking");
        let tool = state.messages[1]
            .tool
            .as_ref()
            .expect("structured tool data");
        assert_eq!(tool.args["command"], "echo hi");
        assert_eq!(tool.status, ToolCallStatus::Ok);
        assert_eq!(tool.content.as_deref(), Some("hi"));
        assert_eq!(state.messages[2].role, super::UiRole::Thinking);
        assert_eq!(state.messages[2].text, "想一下");
    }

    #[test]
    fn tool_status_label_covers_all_states() {
        use cgc_agent_host::ToolCallStatus;
        assert_eq!(super::tool_status_label(ToolCallStatus::Running), "运行中…");
        assert_eq!(super::tool_status_label(ToolCallStatus::Ok), "完成");
        assert_eq!(super::tool_status_label(ToolCallStatus::Failed), "失败");
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
    fn user_message_ordinal_and_thread_entry_mapping() {
        use cgc_agent_core::Entry;
        use cgc_agent_host::{UiMessage, UiRole};

        let msg = |role, text: &str| UiMessage {
            role,
            text: text.into(),
            tool_call_id: None,
            tool: None,
        };
        let messages = vec![
            msg(UiRole::User, "q1"),
            msg(UiRole::Assistant, "a1"),
            msg(UiRole::Tool, "t1"),
            msg(UiRole::User, "q2"),
            msg(UiRole::Assistant, "a2"),
            msg(UiRole::User, "q3"),
        ];
        assert_eq!(super::user_message_ordinal(&messages, 0), Some(1));
        assert_eq!(super::user_message_ordinal(&messages, 3), Some(2));
        assert_eq!(super::user_message_ordinal(&messages, 5), Some(3));
        assert_eq!(
            super::user_message_ordinal(&messages, 1),
            None,
            "非用户消息"
        );

        let entries = vec![
            Entry::User {
                text: "q1".into(),
                images: Vec::new(),
                display: Some("q1".into()),
                at: 0,
            },
            Entry::Assistant {
                text: "a1".into(),
                tool_calls: Vec::new(),
                usage: None,
                at: 0,
            },
            Entry::User {
                text: "q2".into(),
                images: Vec::new(),
                display: Some("q2".into()),
                at: 0,
            },
            Entry::User {
                text: "q3".into(),
                images: Vec::new(),
                display: Some("q3".into()),
                at: 0,
            },
        ];
        assert_eq!(super::thread_user_entry_index(&entries, 1), Some(0));
        assert_eq!(super::thread_user_entry_index(&entries, 2), Some(2));
        assert_eq!(super::thread_user_entry_index(&entries, 3), Some(3));
        assert_eq!(super::thread_user_entry_index(&entries, 4), None);
        assert_eq!(super::thread_user_entry_index(&entries, 0), None);
    }

    #[test]
    fn message_row_kinds_keep_inline_subagents_and_tail_rows_in_order() {
        use cgc_agent_host::{SubagentCard, UiMessage, UiRole};

        let message = |role, text: &str, tool_call_id: Option<&str>| UiMessage {
            role,
            text: text.into(),
            tool_call_id: tool_call_id.map(str::to_string),
            tool: None,
        };
        let subagent = |tool_call_id: Option<&str>, text: &str| SubagentCard {
            task: "task".into(),
            text: text.into(),
            finished: Some(true),
            tool_call_id: tool_call_id.map(str::to_string),
        };

        let messages = vec![
            message(UiRole::User, "hi", None),
            message(UiRole::Tool, "tool done", Some("call_1")),
            message(UiRole::Assistant, "answer", None),
        ];
        // 故意让尾部 card 排在前面：正确实现应按 tool_call_id 匹配到 index 1
        let subagents = vec![
            subagent(Some("call_2"), "tail"),
            subagent(Some("call_1"), "inline"),
        ];
        let kinds = super::build_message_row_kinds(&messages, &subagents, true, true, true);
        assert_eq!(
            kinds,
            vec![
                super::MessageRowKind::Message(0),
                super::MessageRowKind::Message(1),
                super::MessageRowKind::Subagent(1),
                super::MessageRowKind::Message(2),
                super::MessageRowKind::LiveThinking,
                super::MessageRowKind::Streaming,
                super::MessageRowKind::Subagent(0),
                super::MessageRowKind::Error,
            ],
            "子 agent 应内联到触发它的 tool 消息后，尾部按 流式→剩余子 agent→错误 排列"
        );

        // 无流式/错误/子 agent 时只有历史消息行
        let kinds = super::build_message_row_kinds(&messages, &[], false, false, false);
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
        let kinds = super::build_message_row_kinds(&messages, &duplicates, false, false, false);
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
    fn live_thinking_auto_expands_and_transfers_state() {
        use cgc_agent_host::{UiMessage, UiRole};
        assert!(super::should_auto_expand_live_thinking(true, true));
        assert!(!super::should_auto_expand_live_thinking(false, true));
        assert!(!super::should_auto_expand_live_thinking(true, false));

        let message = |role, text: &str| UiMessage {
            role,
            text: text.into(),
            tool_call_id: None,
            tool: None,
        };
        let messages = vec![
            message(UiRole::User, "问"),
            message(UiRole::Thinking, "想"),
            message(UiRole::Assistant, "答"),
        ];
        let mut expanded = std::collections::HashSet::new();
        assert_eq!(
            super::transfer_live_thinking_expansion(&messages, false, &mut expanded),
            Some(1),
            "展开状态应转移到第 1 条 Thinking"
        );
        assert!(expanded.contains(&1));
        assert_eq!(
            super::transfer_live_thinking_expansion(&messages, true, &mut expanded),
            Some(1)
        );
        assert!(!expanded.contains(&1), "用户折叠时不应展开");
        let no_thinking = vec![message(UiRole::User, "问")];
        assert_eq!(
            super::transfer_live_thinking_expansion(&no_thinking, false, &mut expanded),
            None
        );
    }

    #[test]
    fn trim_messages_to_last_user_drops_failed_turn_rows() {
        use cgc_agent_host::{UiMessage, UiRole};
        let mut messages = vec![
            UiMessage {
                role: UiRole::User,
                text: "第一问".into(),
                tool_call_id: None,
                tool: None,
            },
            UiMessage {
                role: UiRole::Assistant,
                text: "第一答".into(),
                tool_call_id: None,
                tool: None,
            },
            UiMessage {
                role: UiRole::User,
                text: "第二问".into(),
                tool_call_id: None,
                tool: None,
            },
            UiMessage {
                role: UiRole::Assistant,
                text: "失败前的半截回复".into(),
                tool_call_id: None,
                tool: None,
            },
        ];
        let kept = super::trim_messages_to_last_user(&mut messages);
        assert_eq!(kept, Some(2));
        assert_eq!(messages.len(), 3, "保留到最近一条用户消息");
        assert_eq!(messages.last().unwrap().text, "第二问");
        assert_eq!(super::trim_messages_to_last_user(&mut Vec::new()), None);
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
