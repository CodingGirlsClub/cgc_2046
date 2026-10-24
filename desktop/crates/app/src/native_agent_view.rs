//! Native agent 的 GPUI 面板（P1a UI 接入）。
//!
//! 通过 `CGC_NATIVE_AGENT_DEMO=1` 打开独立窗口，不影响现有 ACP 对话路径。
//! 事件经 futures channel → `HostState` 归约 → 面板实时刷新；审批用
//! `UiApprover` 把请求变成 UI 上的三个按钮，用户答复通过 oneshot 回填。

use std::sync::{mpsc as std_mpsc, Arc, Mutex};

use base64::Engine as _;
use cgc_agent_checkpoint::{Checkpoint, CheckpointManager, FileChange};
use cgc_agent_core::{
    run_subagent, Agent, AgentError, ApprovalRequest, Approver, AutoApprover, CancelToken,
    SelectedModel, Thread,
};
use cgc_agent_host::{
    parse_slash, AgentEvent, AsyncChannelObserver, HostState, SlashCommand, UiRole, SLASH_COMMANDS,
};
use cgc_agent_provider::{
    EchoProvider, Model, ModelLimits, OpenAiCompatibleConfig, OpenAiCompatibleProvider, Provider,
    ProviderId,
};
use cgc_agent_store::{
    provider_key_account, ActionAuditEntry, AuditLog, PrefsStore, ProviderPrefs, SessionStore,
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
use gpui_kit::component::input::{InputEvent, Textarea, TextareaState};
use gpui_kit::component::popover::Popover;
use gpui_kit::component::tooltip::Tooltip;
use gpui_kit::component::Sizable;
use gpui_kit::*;
use image::GenericImageView as _;

use crate::theme::{self, space, RADIUS_MEDIUM, RADIUS_SMALL};

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
    status: String,
    busy: bool,
    session_store: Option<SessionStore>,
    checkpoint_manager: Option<CheckpointManager>,
    last_checkpoint: Option<Checkpoint>,
    checkpoint_changes: Vec<FileChange>,
    show_checkpoint_panel: bool,
    turn_seq: u64,
    providers: Vec<ProviderPrefs>,
    keychain: Option<KeychainStore>,
    effort_index: usize,
    thinking_enabled: bool,
    slash_index: usize,
    slash_dismissed: bool,
    mention_index: usize,
    workspace_files: Vec<String>,
    follow_output: bool,
    messages_scroll: ScrollHandle,
    approval_mode: ApprovalMode,
    approval_sender: Arc<Mutex<Option<oneshot::Sender<ApprovalDecision>>>>,
    pending_images: Vec<PendingImage>,
    hovered_image: Option<usize>,
    queued_messages: Vec<String>,
    steer_sender: std_mpsc::Sender<String>,
    _input_subscription: Option<Subscription>,
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
        let restored_thread = session_store.as_ref().and_then(|store| {
            let latest = store.list_threads(1).ok()?.into_iter().next()?;
            let thread = store.load_thread(&latest.id).ok().flatten()?;
            (thread.model == selected).then_some(thread)
        });
        let mut state = HostState::new();
        let thread = match restored_thread {
            Some(thread) => {
                for entry in &thread.entries {
                    match entry {
                        cgc_agent_core::Entry::User { text, .. } => state.push_user(text),
                        cgc_agent_core::Entry::Assistant { text, .. } if !text.is_empty() => {
                            state.push_assistant(text)
                        }
                        cgc_agent_core::Entry::ToolResult {
                            tool_name,
                            is_error,
                            ..
                        } => state.push_tool(format!(
                            "{tool_name} · {}",
                            if *is_error { "失败" } else { "完成" }
                        )),
                        _ => {}
                    }
                }
                state.usage_total = thread.usage_total;
                thread
            }
            None => {
                state.push_system("未配置可用的 Provider API Key，当前离线回显模式。请在 Settings → AI → LLM Providers 保存 Key 后重新打开 Agent 面板。");
                Thread::new("native-demo", selected)
            }
        };
        let restored = !state.messages.is_empty();
        let agent = Agent::new(thread, None);
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
        let workspace = std::env::var("CGC_AGENT_WORKSPACE")
            .map(std::path::PathBuf::from)
            .unwrap_or_else(|_| std::env::temp_dir().join("cgc-native-agent-demo"));
        let _ = std::fs::create_dir_all(&workspace);
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
        let input = cx.new(|cx| TextareaState::new(window, cx).auto_grow(4, 20));
        let input_subscription = Some(cx.subscribe_in(
            &input,
            window,
            |this, state, event: &InputEvent, window, cx| {
                if let InputEvent::Change = event {
                    let value = this.input.read(cx).value().to_string();
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
                    let candidates = slash_candidates_for(&value);
                    if value.trim_start().starts_with('/')
                        && !this.slash_dismissed
                        && !candidates.is_empty()
                    {
                        let index = this.slash_index.min(candidates.len() - 1);
                        this.run_slash_command(candidates[index].0, window, cx);
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
        Self {
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
            keychain,
            effort_index: 0,
            thinking_enabled: true,
            slash_index: 0,
            slash_dismissed: false,
            mention_index: 0,
            workspace_files,
            follow_output: true,
            messages_scroll: ScrollHandle::new(),
            approval_mode: ApprovalMode::Ask,
            context: ToolContext::new(&workspace)
                .with_sandbox(SandboxPolicy::new(&workspace))
                .with_action_sink(action_sink),
            input,
            cancel,
            state,
            status: if restored {
                "已恢复上次会话".to_string()
            } else {
                "就绪".to_string()
            },
            busy: false,
            session_store,
            checkpoint_manager,
            last_checkpoint: None,
            checkpoint_changes: Vec::new(),
            show_checkpoint_panel: false,
            turn_seq: 0,
            approval_sender: Arc::new(Mutex::new(None)),
            queued_messages: Vec::new(),
            steer_sender,
            pending_images: Vec::new(),
            hovered_image: None,
            _input_subscription: input_subscription,
        }
    }

    fn handle_slash(&mut self, command: SlashCommand, cx: &mut Context<Self>) {
        match command {
            SlashCommand::Help => self
                .state
                .push_system("命令：/help /clear /stop /tools /checkpoint /settings"),
            SlashCommand::Clear => {
                self.state.messages.clear();
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
        let text = self.input.read(cx).value().trim().to_string();
        if text.is_empty() {
            return;
        }
        self.input
            .update(cx, |state, cx| state.set_value("", window, cx));
        if let Some(command) = parse_slash(&text) {
            self.handle_slash(command, cx);
            return;
        }
        if self.busy {
            self.queued_messages.push(text);
            self.status = format!(
                "已排队 {} 条，当前 turn 结束后依次发送",
                self.queued_messages.len()
            );
            cx.notify();
            return;
        }
        self.send_prompt(text, cx);
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

    fn send_prompt(&mut self, text: String, cx: &mut Context<Self>) {
        self.reload_latest_session();
        self.turn_seq += 1;
        if let Some(thread_id) = self.agent.as_ref().map(|agent| agent.thread().id.clone()) {
            self.capture_checkpoint(&thread_id, self.turn_seq);
        }
        let Some(mut agent) = self.agent.take() else {
            return;
        };
        if !self.pending_images.is_empty() {
            agent.set_pending_images(
                self.pending_images
                    .iter()
                    .map(|image| (image.mime.clone(), image.data.clone()))
                    .collect(),
            );
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
        let approval_mode = self.approval_mode;
        self.state.push_user(text.clone());
        let text = self.expand_mentions(&text);
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
                if this
                    .update(cx, |this, cx| {
                        this.state.apply(event);
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
                    this.send_prompt(next, cx);
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
            let next = format!("{}@{} ", &value[..position], path);
            self.input
                .update(cx, |state, cx| state.set_value(next, window, cx));
        }
        self.mention_index = 0;
        cx.notify();
    }

    fn expand_mentions(&self, text: &str) -> String {
        let workspace = self.context.workspace().to_path_buf();
        let mut context = String::new();
        for token in text.split_whitespace() {
            let Some(path) = token.strip_prefix('@') else {
                continue;
            };
            if path.is_empty() || path.starts_with('/') {
                continue;
            }
            let full = workspace.join(path);
            let Ok(metadata) = std::fs::metadata(&full) else {
                continue;
            };
            if !metadata.is_file() || metadata.len() > 256 * 1024 {
                continue;
            }
            if let Ok(content) = std::fs::read_to_string(&full) {
                context.push_str(&format!("[文件: {path}]\n{content}\n\n"));
            }
        }
        if context.is_empty() {
            text.to_string()
        } else {
            format!("{context}{text}")
        }
    }

    fn run_slash_command(
        &mut self,
        command: &'static str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if let Some(command) = parse_slash(command) {
            self.handle_slash(command, cx);
        }
        self.input
            .update(cx, |state, cx| state.set_value("", window, cx));
        self.slash_index = 0;
        self.slash_dismissed = false;
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
        self.status = "输入 @ 引用上下文（文件引用 P1 支持）".to_string();
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
        let model = self.model.clone();
        if let Some(agent) = &mut self.agent {
            agent.replace_thread(Thread::new(
                format!("native-demo-{}", now_secs()),
                SelectedModel::new(model.provider_id.clone(), model.id.clone()),
            ));
        }
        self.state = HostState::new();
        self.state
            .push_system("Native agent：新对话，配置 Provider 后开始。");
        self.last_checkpoint = None;
        self.checkpoint_changes.clear();
        self.show_checkpoint_panel = false;
        self.status = "新对话".to_string();
        cx.notify();
    }

    /// 从 SQLite 拉取其他视图写入的最新会话，保持内联/独立窗口共享同一份历史。
    fn reload_latest_session(&mut self) {
        let Some(agent) = &self.agent else {
            return;
        };
        let Some(store) = &self.session_store else {
            return;
        };
        let Ok(summaries) = store.list_threads(1) else {
            return;
        };
        let Some(summary) = summaries.first() else {
            return;
        };
        let Ok(Some(loaded)) = store.load_thread(&summary.id) else {
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
        for entry in &thread.entries {
            match entry {
                cgc_agent_core::Entry::User { text, .. } => state.push_user(text),
                cgc_agent_core::Entry::Assistant { text, .. } if !text.is_empty() => {
                    state.push_assistant(text)
                }
                cgc_agent_core::Entry::ToolResult {
                    tool_name,
                    is_error,
                    ..
                } => state.push_tool(format!(
                    "{tool_name} · {}",
                    if *is_error { "失败" } else { "完成" }
                )),
                _ => {}
            }
        }
        if state.messages.is_empty() {
            state.push_system("Native agent：配置 Provider 后开始对话。");
        }
        self.state = state;
    }

    fn capture_checkpoint(&mut self, thread_id: &str, seq: u64) {
        let Some(manager) = &self.checkpoint_manager else {
            return;
        };
        match manager.snapshot(thread_id, seq) {
            Ok(checkpoint) => {
                if let Some(store) = &mut self.session_store {
                    let _ = store.save_checkpoint(&checkpoint, seq as i64, now_secs());
                }
                self.last_checkpoint = Some(checkpoint);
            }
            Err(error) => self.status = format!("checkpoint 失败：{error}"),
        }
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

impl Render for NativeAgentView {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let add_menu_root = cx.entity().downgrade();
        let palette = theme::palette_from_theme(cx);
        let busy = self.busy;
        let model_label = format!("{}/{}", self.model.provider_id, self.model.id);
        let status = self.status.clone();
        let messages = self.state.messages.clone();
        let streaming = self.state.streaming.clone();
        let pending = self.state.pending_permission.clone();
        let usage = self.state.usage_total.total();
        let input = self.input.clone();
        let input_focus = self.input.read(cx).focus_handle(cx).clone();
        let input_value = self.input.read(cx).value().to_string();
        let has_input = !input_value.trim().is_empty();
        let slash_open = input_value.trim_start().starts_with('/') && !self.slash_dismissed;
        let slash_matches = slash_candidates_for(&input_value);
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
        let subagents = self.state.subagents.clone();
        let show_changes = self.show_checkpoint_panel && change_count > 0;
        let changes = self.checkpoint_changes.clone();
        let mut rows: Vec<AnyElement> = Vec::new();
        let mut remaining_subagents = subagents.clone();
        for message in messages {
            let color = match message.role {
                UiRole::User => palette.accent,
                UiRole::Error => palette.danger,
                UiRole::Tool => palette.ink_3,
                UiRole::System => palette.ink_3,
                UiRole::Assistant => palette.ink,
            };
            rows.push(
                div()
                    .flex()
                    .flex_col()
                    .gap(px(2.0))
                    .child(
                        div()
                            .text_size(px(11.0))
                            .text_color(color)
                            .child(role_label(message.role)),
                    )
                    .child(div().text_size(px(13.0)).child(message.text))
                    .into_any_element(),
            );
            if let Some(tool_call_id) = &message.tool_call_id {
                if let Some(index) = remaining_subagents
                    .iter()
                    .position(|card| card.tool_call_id.as_deref() == Some(tool_call_id.as_str()))
                {
                    let card = remaining_subagents.remove(index);
                    rows.push(render_subagent_row(&card, &palette));
                }
            }
        }
        if !streaming.is_empty() {
            rows.push(
                div()
                    .flex()
                    .flex_col()
                    .gap(px(2.0))
                    .child(
                        div()
                            .text_size(px(11.0))
                            .text_color(palette.accent)
                            .child("agent"),
                    )
                    .child(div().text_size(px(13.0)).child(format!("{streaming}▌")))
                    .into_any_element(),
            );
        }

        for card in &remaining_subagents {
            rows.push(render_subagent_row(card, &palette));
        }

        if self.follow_output && !rows.is_empty() {
            self.messages_scroll.scroll_to_item(rows.len() - 1);
        }

        div()
            .size_full()
            .flex()
            .flex_col()
            .bg(palette.canvas)
            .text_color(palette.ink)
            .font_family(theme::FONT_SANS)
            .text_size(px(13.0))
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap(px(2.0))
                    .pl(if cfg!(target_os = "macos") {
                        px(84.0)
                    } else {
                        space(3)
                    })
                    .pr(space(3))
                    .pt(if cfg!(target_os = "macos") {
                        px(6.0)
                    } else {
                        space(2)
                    })
                    .pb(space(2))
                    .border_b_1()
                    .border_color(palette.line)
                    .child(div().text_size(px(15.0)).child("Native Agent（P1a）"))
                    .child(
                        div()
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap(space(1))
                            .children(
                                busy.then(|| div().size(px(6.0)).rounded_full().bg(palette.accent)),
                            )
                            .child(
                                div()
                                    .text_size(px(11.0))
                                    .text_color(palette.ink_3)
                                    .child(format!("model: {model_label} · {status}")),
                            ),
                    ),
            )
            .child(
                div()
                    .id("native-agent-messages")
                    .flex_1()
                    .flex()
                    .flex_col()
                    .gap(space(2))
                    .p(space(3))
                    .overflow_y_scroll()
                    .track_scroll(&self.messages_scroll)
                    .children(rows),
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
                    .children(queued_messages.iter().enumerate().map(|(index, text)| {
                        let preview: String = text.chars().take(160).collect();
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
                let thinking_label = if thinking_supported && self.thinking_enabled {
                    effort_levels
                        .get(current_effort)
                        .map(String::as_str)
                        .unwrap_or("Thinking")
                } else if thinking_supported {
                    "Thinking 关"
                } else {
                    "推理 —"
                };
                let effort_levels_for_menu = effort_levels.clone();
                let effort_picker = (thinking_supported && !effort_levels.is_empty()).then(|| {
                    Popover::new("native-thinking-picker")
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
                                            this.set_effort_index(level_index, cx);
                                        });
                                        let _ = row_dismiss
                                            .update(cx, |state, cx| state.dismiss(window, cx));
                                    })
                                    .into_any_element()
                            })
                            .collect::<Vec<_>>();
                            div()
                                .id("native-thinking-options")
                                .flex()
                                .flex_col()
                                .gap(px(1.0))
                                .w(px(160.0))
                                .occlude()
                                .children(rows)
                                .child(
                                    div()
                                        .px(space(1))
                                        .py(px(3.0))
                                        .text_size(px(10.0))
                                        .text_color(palette_copy.ink_3)
                                        .child("该模型未开启 supports_thinking"),
                                )
                        })
                });
                let current_approval = self.approval_mode;
                let approval_picker = Popover::new("native-approval-picker")
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

                let thinking_toggle = thinking_supported.then(|| {
                    let enabled = self.thinking_enabled;
                    div()
                        .id("native-thinking-toggle")
                        .role(Role::Button)
                        .aria_label(if enabled {
                            "关闭 Thinking"
                        } else {
                            "开启 Thinking"
                        })
                        .px(space(1))
                        .py(px(2.0))
                        .rounded(px(RADIUS_SMALL))
                        .text_size(px(11.0))
                        .text_color(if enabled {
                            palette.accent
                        } else {
                            palette.ink_3
                        })
                        .bg(if enabled { palette.soft } else { palette.view })
                        .child(if enabled { "Thinking" } else { "Thinking 关" })
                        .on_click(cx.listener(move |this, _, _window, cx| {
                            this.set_thinking_enabled(!enabled, cx)
                        }))
                });
                let send_label = if busy {
                    if has_input {
                        "排队"
                    } else {
                        "停止"
                    }
                } else {
                    "发送"
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
                let usage_label = format!("{usage} tokens");

                div()
                    .id("native-agent-composer")
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
                    .on_key_down(cx.listener(|this, event: &KeyDownEvent, _window, cx| {
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
                                return;
                            }
                        }
                        let value = this.input.read(cx).value().to_string();
                        if trailing_mention(&value).is_some() {
                            match event.keystroke.key.as_str() {
                                "up" => {
                                    this.mention_index = this.mention_index.saturating_sub(1);
                                    cx.notify();
                                }
                                "down" => {
                                    this.mention_index += 1;
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
                                cx.notify();
                            }
                            "down" => {
                                this.slash_index += 1;
                                cx.notify();
                            }
                            "escape" => {
                                this.slash_dismissed = true;
                                cx.notify();
                            }
                            _ => {}
                        }
                    }))
                    .children((slash_open && !slash_matches.is_empty()).then(|| {
                        div()
                            .id("native-agent-slash-menu")
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
                            .children(slash_matches.iter().enumerate().map(
                                |(index, (command, description))| {
                                    let selected = index == slash_selected;
                                    let command: &'static str = command;
                                    div()
                                        .id(SharedString::from(format!("native-slash-{index}")))
                                        .role(Role::Button)
                                        .aria_label(*description)
                                        .flex()
                                        .flex_row()
                                        .items_center()
                                        .gap(space(2))
                                        .px(space(1))
                                        .py(px(3.0))
                                        .rounded(px(RADIUS_SMALL))
                                        .bg(if selected { palette.soft } else { palette.card })
                                        .text_color(if selected {
                                            palette.accent
                                        } else {
                                            palette.ink_2
                                        })
                                        .child(div().w(px(86.0)).text_size(px(11.0)).child(command))
                                        .child(
                                            div()
                                                .flex_1()
                                                .text_size(px(10.0))
                                                .text_color(palette.ink_3)
                                                .child(*description),
                                        )
                                        .on_click(cx.listener(move |this, _, window, cx| {
                                            this.run_slash_command(command, window, cx);
                                        }))
                                },
                            ))
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
                                let remove_weak_ui = cx.entity().downgrade();
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
                                    .child("🖼")
                                    .child(image.name.clone())
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
                                                    this.hovered_image = None;
                                                    cx.notify();
                                                });
                                            }),
                                    )
                                    .on_hover(move |hovered: &bool, _window, cx| {
                                        let _ = remove_weak_ui.update(cx, |this, cx| {
                                            this.hovered_image =
                                                if *hovered { Some(index) } else { None };
                                            cx.notify();
                                        });
                                    })
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
                    .children(
                        self.hovered_image
                            .and_then(|index| self.pending_images.get(index))
                            .and_then(|image| image.preview.clone())
                            .map(|preview| {
                                div()
                                    .px(space(1))
                                    .pb(px(2.0))
                                    .child(img(preview).max_h(px(160.0)).rounded(px(RADIUS_SMALL)))
                            }),
                    )
                    .child(
                        div()
                            .relative()
                            .px(space(1))
                            .py(px(4.0))
                            .child(
                                Textarea::new(&input)
                                    .appearance(false)
                                    .bordered(false)
                                    .w_full(),
                            )
                            .children((!has_input).then(|| {
                                // 自定义可换行 placeholder：gpui-base 的 Textarea
                                // placeholder 只按 \n 分行、不做宽度软换行
                                // （shape_line 未传宽度约束），窄面板会直接裁切；
                                // 上游修好前用 absolute overlay 折行并承担点击聚焦。
                                let focus = input_focus.clone();
                                div()
                                    .id("native-agent-placeholder")
                                    .absolute()
                                    .top(px(4.0))
                                    .left(px(6.0))
                                    .right(px(6.0))
                                    .text_size(px(13.0))
                                    .line_height(px(20.0))
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
                                            .child(
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
                                                            this.add_clipboard_image(cx);
                                                        });
                                                        let _ = image_dismiss
                                                            .update(cx, |state, cx| state.dismiss(window, cx));
                                                    }),
                                            )
                                            .into_any_element()
                                    }),
                            )
                            .child(
                                div()
                                    .id("native-follow-toggle")
                                    .role(Role::Button)
                                    .aria_label(if self.follow_output {
                                        "暂停跟随输出"
                                    } else {
                                        "跟随输出"
                                    })
                                    .px(space(1))
                                    .py(px(2.0))
                                    .rounded(px(RADIUS_SMALL))
                                    .text_size(px(11.0))
                                    .text_color(if self.follow_output {
                                        palette.accent
                                    } else {
                                        palette.ink_3
                                    })
                                    .hover(|style| style.bg(palette.soft))
                                    .child(if self.follow_output {
                                        "跟随"
                                    } else {
                                        "暂停"
                                    })
                                    .on_click(cx.listener(|this, _, _window, cx| {
                                        this.follow_output = !this.follow_output;
                                        cx.notify();
                                    })),
                            )
                            .child(model_picker)
                            .children(thinking_toggle)
                            .children(effort_picker)
                            .child(approval_picker)
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
                            .child(
                                div()
                                    .text_size(px(10.0))
                                    .text_color(palette.ink_3)
                                    .child(usage_label),
                            )
                            .child(
                                div()
                                    .id(if busy {
                                        "native-agent-stop"
                                    } else {
                                        "native-agent-send"
                                    })
                                    .role(Role::Button)
                                    .aria_label(send_label)
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

fn slash_candidates_for(value: &str) -> Vec<(&'static str, &'static str)> {
    let trimmed = value.trim_start();
    let Some(query) = trimmed.strip_prefix('/') else {
        return Vec::new();
    };
    let query = query.trim().to_ascii_lowercase();
    SLASH_COMMANDS
        .iter()
        .copied()
        .filter(|(command, description)| {
            query.is_empty()
                || command
                    .trim_start_matches('/')
                    .to_ascii_lowercase()
                    .starts_with(&query)
                || description.to_ascii_lowercase().contains(&query)
        })
        .collect()
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

fn role_label(role: UiRole) -> &'static str {
    match role {
        UiRole::User => "you",
        UiRole::Assistant => "agent",
        UiRole::Tool => "tool",
        UiRole::System => "system",
        UiRole::Error => "error",
    }
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

fn now_secs() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_secs() as i64)
        .unwrap_or_default()
}
