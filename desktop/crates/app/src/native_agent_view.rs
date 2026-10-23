//! Native agent 的 GPUI 面板（P1a UI 接入）。
//!
//! 通过 `CGC_NATIVE_AGENT_DEMO=1` 打开独立窗口，不影响现有 ACP 对话路径。
//! 事件经 futures channel → `HostState` 归约 → 面板实时刷新；审批用
//! `UiApprover` 把请求变成 UI 上的三个按钮，用户答复通过 oneshot 回填。

use std::sync::{mpsc as std_mpsc, Arc, Mutex};

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
    ActionSink, AgentState, AppAction, ApprovalDecision, SandboxPolicy, SharedAgentState,
    SubagentEvent, SubagentEventSink, SubagentRequest, SubagentRunner, ToolContext, ToolRegistry,
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

use crate::theme::{self, space, RADIUS_MEDIUM, RADIUS_SMALL};

/// 推理档位（映射到 OpenAI-compatible 的 reasoning_effort）。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ThinkingLevel {
    Off,
    Low,
    Medium,
    High,
}

impl ThinkingLevel {
    fn label(self) -> &'static str {
        match self {
            Self::Off => "推理 Off",
            Self::Low => "推理 Low",
            Self::Medium => "推理 Medium",
            Self::High => "推理 High",
        }
    }

    fn reasoning_effort(self) -> Option<&'static str> {
        match self {
            Self::Off => None,
            Self::Low => Some("low"),
            Self::Medium => Some("medium"),
            Self::High => Some("high"),
        }
    }
}

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

pub struct NativeAgentView {
    agent: Option<Agent>,
    provider: Arc<dyn Provider>,
    model: Model,
    registry: Arc<ToolRegistry>,
    agent_state: SharedAgentState,
    last_agent_summary: Option<String>,
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
    thinking_level: ThinkingLevel,
    thinking_enabled: bool,
    approval_mode: ApprovalMode,
    approval_sender: Arc<Mutex<Option<oneshot::Sender<ApprovalDecision>>>>,
    follow_up_sender: std_mpsc::Sender<String>,
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
        let model = Model::new(
            ProviderId::new(provider_id),
            provider_name,
            model_id.clone(),
            model_id,
            ModelLimits::new(64_000, 8_000),
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
                state.push_system("Native agent demo：离线模式回显；配置环境变量后接真实模型。");
                Thread::new("native-demo", selected)
            }
        };
        let restored = !state.messages.is_empty();
        let agent = Agent::new(thread, None);
        let cancel = agent.cancel_token();
        let follow_up_sender = agent.follow_up_sender();
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
        let input = cx.new(|cx| {
            TextareaState::new(window, cx).placeholder(
                "给 CGC Agent 发消息… @ 引用上下文，/ 查看命令（Enter 发送，Shift+Enter 换行）",
            )
        });
        let input_subscription = Some(cx.subscribe_in(
            &input,
            window,
            |this, state, event: &InputEvent, window, cx| {
                if let InputEvent::PressEnter { secondary, shift } = event {
                    if *shift {
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
            last_agent_summary: None,
            app_actions,
            action_audit,
            subagent_tx,
            providers,
            keychain,
            thinking_level: ThinkingLevel::Off,
            thinking_enabled: true,
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
            follow_up_sender,
            steer_sender,
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
            let _ = self.follow_up_sender.send(text);
            self.status = "已排队 follow-up，当前 turn 结束后执行".to_string();
            cx.notify();
            return;
        }
        self.reload_latest_session();
        self.turn_seq += 1;
        if let Some(thread_id) = self.agent.as_ref().map(|agent| agent.thread().id.clone()) {
            self.capture_checkpoint(&thread_id, self.turn_seq);
        }
        let Some(mut agent) = self.agent.take() else {
            return;
        };
        agent.set_reasoning_effort(if self.thinking_enabled {
            self.thinking_level.reasoning_effort().map(str::to_string)
        } else {
            None
        });
        let approval_mode = self.approval_mode;
        self.state.push_user(text.clone());
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
        let registry = self.registry.clone();
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
                this.refresh_agent_state_summary();
                this.refresh_checkpoint_changes();
                if let Ok(mut pending) = approval_sender.lock() {
                    pending.take();
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

    fn refresh_agent_state_summary(&mut self) {
        let summary = self
            .agent_state
            .lock()
            .ok()
            .and_then(|state| state.summary());
        if summary != self.last_agent_summary {
            match &summary {
                Some(summary) => self.state.push_system(summary.clone()),
                None => self.state.push_system("目标/计划/待办已清空"),
            }
            self.last_agent_summary = summary;
        }
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
        let model = Model::new(
            ProviderId::new(provider.id.clone()),
            provider.name.clone(),
            model_id.clone(),
            model_id,
            ModelLimits::new(64_000, 8_000),
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

    fn set_thinking_enabled(&mut self, enabled: bool, cx: &mut Context<Self>) {
        self.thinking_enabled = enabled;
        if enabled && self.thinking_level == ThinkingLevel::Off {
            self.thinking_level = ThinkingLevel::Medium;
        }
        self.status = if enabled {
            format!("Thinking 开 · {}", self.thinking_level.label())
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

    fn set_thinking_level(&mut self, level: ThinkingLevel, cx: &mut Context<Self>) {
        self.thinking_level = level;
        self.status = format!("推理档位：{}", level.label());
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
        self.last_agent_summary = None;
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
        self.last_agent_summary = None;
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
        let palette = theme::palette_from_theme(cx);
        let busy = self.busy;
        let model_label = format!("{}/{}", self.model.provider_id, self.model.id);
        let status = self.status.clone();
        let messages = self.state.messages.clone();
        let streaming = self.state.streaming.clone();
        let pending = self.state.pending_permission.clone();
        let usage = self.state.usage_total.total();
        let input = self.input.clone();
        let input_value = self.input.read(cx).value().to_string();
        let has_input = !input_value.trim().is_empty();
        let slash_hint = input_value.trim_start().starts_with('/');
        let can_undo = self.last_checkpoint.is_some() && !busy;
        let change_count = self.checkpoint_changes.len();
        let subagents = self.state.subagents.clone();
        let show_changes = self.show_checkpoint_panel && change_count > 0;
        let changes = self.checkpoint_changes.clone();
        let mut rows: Vec<AnyElement> = Vec::new();
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
                            .text_size(px(11.0))
                            .text_color(palette.ink_3)
                            .child(format!("model: {model_label} · {status}")),
                    ),
            )
            .children(slash_hint.then(|| {
                div()
                    .id("native-agent-slash-hint")
                    .flex()
                    .flex_row()
                    .flex_wrap()
                    .gap(space(2))
                    .px(space(3))
                    .py(space(1))
                    .border_t_1()
                    .border_color(palette.line)
                    .children(SLASH_COMMANDS.iter().map(|(command, description)| {
                        div()
                            .text_size(px(11.0))
                            .text_color(palette.ink_3)
                            .child(format!("{command} {description}"))
                    }))
            }))
            .child(
                div()
                    .id("native-agent-messages")
                    .flex_1()
                    .flex()
                    .flex_col()
                    .gap(space(2))
                    .p(space(3))
                    .overflow_y_scroll()
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
                            .text_size(px(12.0))
                            .child(format!("本轮文件变更（{change_count}）")),
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
            .children((!subagents.is_empty()).then(|| {
                div()
                    .id("native-agent-subagents")
                    .flex()
                    .flex_col()
                    .gap(space(1))
                    .px(space(3))
                    .py(space(2))
                    .border_t_1()
                    .border_color(palette.line)
                    .bg(palette.view)
                    .children(subagents.into_iter().map(|card| {
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
                            .child(
                                div()
                                    .text_size(px(12.0))
                                    .text_color(palette.ink_2)
                                    .child(format!("子 agent · {status}：{}", card.task)),
                            )
                            .children((!preview.is_empty()).then(|| {
                                div()
                                    .text_size(px(11.0))
                                    .text_color(palette.ink_3)
                                    .child(preview)
                            }))
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
            .child({
                let current_provider_id = self.model.provider_id.as_str().to_string();
                let current_model_id = self.model.id.as_str().to_string();
                let thinking_supported = self.providers.iter().any(|provider| {
                    provider.id == current_provider_id && provider.supports_thinking
                });
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
                let thinking_label = if thinking_supported && self.thinking_enabled {
                    self.thinking_level.label()
                } else if thinking_supported {
                    "Thinking 关"
                } else {
                    "推理 —"
                };
                let current_level = self.thinking_level;
                let effort_picker = thinking_supported.then(|| {
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
                            let rows = [
                                (ThinkingLevel::Off, "Off"),
                                (ThinkingLevel::Low, "Low"),
                                (ThinkingLevel::Medium, "Medium"),
                                (ThinkingLevel::High, "High"),
                            ]
                            .into_iter()
                            .map(|(level, label)| {
                                let root = thinking_root.clone();
                                let row_dismiss = dismiss.clone();
                                let selected = level == current_level;
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
                                            this.set_thinking_level(level, cx);
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
                    .child(
                        div().px(space(1)).py(px(4.0)).child(
                            Textarea::new(&input)
                                .appearance(false)
                                .bordered(false)
                                .h(px(40.0))
                                .w_full(),
                        ),
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
                                div()
                                    .id("native-agent-add-context")
                                    .role(Role::Button)
                                    .aria_label("添加上下文")
                                    .size(px(24.0))
                                    .rounded(px(RADIUS_SMALL))
                                    .flex()
                                    .items_center()
                                    .justify_center()
                                    .text_size(px(14.0))
                                    .text_color(palette.ink_3)
                                    .hover(|style| style.bg(palette.soft))
                                    .child("＋")
                                    .tooltip(|window, cx| {
                                        Tooltip::new("添加上下文（@）").build(window, cx)
                                    })
                                    .on_click(cx.listener(|this, _, window, cx| {
                                        this.insert_context_marker(window, cx)
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
