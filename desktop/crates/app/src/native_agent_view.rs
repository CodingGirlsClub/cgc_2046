//! Native agent 的 GPUI 面板（P1a UI 接入）。
//!
//! 通过 `CGC_NATIVE_AGENT_DEMO=1` 打开独立窗口，不影响现有 ACP 对话路径。
//! 事件经 futures channel → `HostState` 归约 → 面板实时刷新；审批用
//! `UiApprover` 把请求变成 UI 上的三个按钮，用户答复通过 oneshot 回填。

use std::sync::{Arc, Mutex};

use cgc_agent_checkpoint::{Checkpoint, CheckpointManager, FileChange};
use cgc_agent_core::{
    Agent, AgentError, ApprovalRequest, Approver, CancelToken, SelectedModel, Thread,
};
use cgc_agent_host::{AgentEvent, AsyncChannelObserver, HostState, UiRole};
use cgc_agent_provider::{
    EchoProvider, Model, ModelId, ModelLimits, OpenAiCompatibleConfig, OpenAiCompatibleProvider,
    Provider, ProviderId,
};
use cgc_agent_store::{AgentPrefs, PrefsStore, ProviderPrefs, SessionStore};
use cgc_agent_tools::{ApprovalDecision, SandboxPolicy, ToolContext, ToolRegistry};
use cgc_platform::session::KeychainStore;
use futures::channel::{mpsc, oneshot};
use futures::StreamExt as _;
use gpui_kit::component::input::{InputEvent, Textarea, TextareaState};
use gpui_kit::*;

use crate::theme::{self, space, RADIUS_MEDIUM};

/// API key 在系统钥匙串里的 account。
const PROVIDER_KEY_ACCOUNT: &str = "native_agent_provider_api_key";

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
    context: ToolContext,
    input: Entity<TextareaState>,
    cancel: CancelToken,
    state: HostState,
    status: String,
    busy: bool,
    prefs_store: PrefsStore,
    session_store: Option<SessionStore>,
    keychain: Option<KeychainStore>,
    settings_open: bool,
    base_url_input: Entity<TextareaState>,
    model_input: Entity<TextareaState>,
    api_key_input: Entity<TextareaState>,
    checkpoint_manager: Option<CheckpointManager>,
    last_checkpoint: Option<Checkpoint>,
    checkpoint_changes: Vec<FileChange>,
    show_checkpoint_panel: bool,
    turn_seq: u64,
    approval_sender: Arc<Mutex<Option<oneshot::Sender<ApprovalDecision>>>>,
    _input_subscription: Option<Subscription>,
}

impl NativeAgentView {
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let paths = cgc_platform::paths::AppPaths::from_env();
        let prefs_store = PrefsStore::new(paths.agent_prefs_file());
        let prefs = prefs_store.load();
        let env_model = std::env::var("CGC_AGENT_MODEL")
            .ok()
            .filter(|model| !model.is_empty());
        let env_base_url = std::env::var("CGC_AGENT_BASE_URL")
            .ok()
            .filter(|base_url| !base_url.is_empty());
        let env_api_key = std::env::var("CGC_AGENT_API_KEY")
            .ok()
            .filter(|api_key| !api_key.is_empty());
        let prefs_provider = prefs.provider.clone().filter(ProviderPrefs::is_complete);
        let keychain = Some(KeychainStore::from_env());
        let stored_api_key = if env_api_key.is_none() && prefs_provider.is_some() {
            keychain
                .as_ref()
                .and_then(|keychain| keychain.load_secret(PROVIDER_KEY_ACCOUNT))
        } else {
            None
        };
        let base_url = env_base_url.clone().or_else(|| {
            prefs_provider
                .as_ref()
                .map(|provider| provider.base_url.clone())
        });
        let api_key = env_api_key.clone().or(stored_api_key);
        let model_id = env_model
            .clone()
            .or_else(|| {
                prefs_provider
                    .as_ref()
                    .map(|provider| provider.model_id.clone())
            })
            .or_else(|| {
                prefs
                    .selected_model
                    .as_ref()
                    .map(|selected| selected.model_id.as_str().to_string())
            })
            .unwrap_or_else(|| "echo".to_string());
        let provider_name = std::env::var("CGC_AGENT_PROVIDER_NAME")
            .ok()
            .or_else(|| {
                prefs_provider
                    .as_ref()
                    .map(|provider| provider.provider_name.clone())
            })
            .unwrap_or_else(|| "OpenAI Compatible".to_string());
        let model = Model::new(
            ProviderId::new("custom"),
            provider_name.clone(),
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
        if env_model.is_some() || env_base_url.is_some() {
            let _ = prefs_store.save(&AgentPrefs {
                selected_model: Some(SelectedModel::new(
                    model.provider_id.clone(),
                    model.id.clone(),
                )),
                provider: base_url.as_ref().map(|base_url| ProviderPrefs {
                    base_url: base_url.clone(),
                    provider_name: provider_name.clone(),
                    model_id: model.id.as_str().to_string(),
                }),
            });
        }
        let selected = SelectedModel::new(model.provider_id.clone(), model.id.clone());
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
        let workspace = std::env::var("CGC_AGENT_WORKSPACE")
            .map(std::path::PathBuf::from)
            .unwrap_or_else(|_| std::env::temp_dir().join("cgc-native-agent-demo"));
        let _ = std::fs::create_dir_all(&workspace);
        let checkpoint_manager = CheckpointManager::open(&workspace)
            .or_else(|_| CheckpointManager::initialize(&workspace))
            .ok();
        let base_url_input = cx.new(|cx| {
            let mut state =
                TextareaState::new(window, cx).placeholder("https://api.deepseek.com/v1");
            if let Some(base_url) = &base_url {
                state.set_value(base_url.clone(), window, cx);
            }
            state
        });
        let model_input = cx.new(|cx| {
            let mut state = TextareaState::new(window, cx).placeholder("deepseek-chat");
            state.set_value(model.id.as_str().to_string(), window, cx);
            state
        });
        let api_key_input =
            cx.new(|cx| TextareaState::new(window, cx).placeholder("API Key（保存到系统钥匙串）"));
        let input = cx.new(|cx| {
            TextareaState::new(window, cx).placeholder("问 native agent 一个问题，回车发送…")
        });
        let input_subscription = Some(cx.subscribe_in(
            &input,
            window,
            |this, state, event: &InputEvent, window, cx| {
                if let InputEvent::PressEnter { shift, .. } = event {
                    if !shift {
                        this.send(cx);
                        state.update(cx, |state, cx| state.set_value("", window, cx));
                        cx.notify();
                    }
                }
            },
        ));
        Self {
            agent: Some(agent),
            provider,
            model,
            registry: Arc::new(ToolRegistry::with_builtin_tools()),
            context: ToolContext::new(&workspace).with_sandbox(SandboxPolicy::new(&workspace)),
            input,
            cancel,
            state,
            status: if restored {
                "已恢复上次会话".to_string()
            } else {
                "就绪".to_string()
            },
            busy: false,
            prefs_store,
            session_store,
            keychain,
            settings_open: false,
            base_url_input,
            model_input,
            api_key_input,
            checkpoint_manager,
            last_checkpoint: None,
            checkpoint_changes: Vec::new(),
            show_checkpoint_panel: false,
            turn_seq: 0,
            approval_sender: Arc::new(Mutex::new(None)),
            _input_subscription: input_subscription,
        }
    }

    fn send(&mut self, cx: &mut Context<Self>) {
        if self.busy {
            return;
        }
        let text = self.input.read(cx).value().trim().to_string();
        if text.is_empty() {
            return;
        }
        self.turn_seq += 1;
        if let Some(thread_id) = self.agent.as_ref().map(|agent| agent.thread().id.clone()) {
            self.capture_checkpoint(&thread_id, self.turn_seq);
        }
        let Some(mut agent) = self.agent.take() else {
            return;
        };
        self.state.push_user(text.clone());
        self.busy = true;
        self.status = "思考中…".to_string();
        self.cancel.reset();

        let (event_sender, mut event_receiver) = mpsc::unbounded::<AgentEvent>();
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

        let approver = UiApprover {
            events: event_sender.clone(),
            pending: self.approval_sender.clone(),
        };
        let provider = self.provider.clone();
        let model = self.model.clone();
        let registry = self.registry.clone();
        let context = self.context.clone();
        let task_sender = event_sender.clone();
        let task = cx.background_executor().spawn(async move {
            let mut observer = AsyncChannelObserver::new(task_sender.clone());
            let result = agent
                .prompt_with_tools_observed(
                    provider.as_ref(),
                    &model,
                    text,
                    registry.as_ref(),
                    &context,
                    &approver,
                    &mut observer,
                )
                .await;
            drop(observer);
            drop(task_sender);
            (agent, result)
        });
        let approval_sender = self.approval_sender.clone();
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
                this.refresh_checkpoint_changes();
                if let Ok(mut pending) = approval_sender.lock() {
                    pending.take();
                }
                cx.notify();
            });
        })
        .detach();
    }

    fn stop(&mut self, cx: &mut Context<Self>) {
        self.cancel.cancel();
        self.status = "正在停止…".to_string();
        cx.notify();
    }

    fn toggle_settings(&mut self, cx: &mut Context<Self>) {
        self.settings_open = !self.settings_open;
        cx.notify();
    }

    fn save_provider_settings(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let base_url = self.base_url_input.read(cx).value().trim().to_string();
        let model_id = self.model_input.read(cx).value().trim().to_string();
        let provider_name = std::env::var("CGC_AGENT_PROVIDER_NAME")
            .ok()
            .unwrap_or_else(|| "OpenAI Compatible".to_string());
        let api_key = self.api_key_input.read(cx).value().trim().to_string();
        if base_url.is_empty() || model_id.is_empty() {
            self.status = "base_url 与 model 不能为空".to_string();
            cx.notify();
            return;
        }
        let prefs = AgentPrefs {
            selected_model: Some(SelectedModel::new(
                ProviderId::new("custom"),
                ModelId::new(model_id.clone()),
            )),
            provider: Some(ProviderPrefs {
                base_url,
                provider_name,
                model_id,
            }),
        };
        match self.prefs_store.save(&prefs) {
            Ok(()) => self.status = "Provider 配置已保存；重启 demo 窗口生效".to_string(),
            Err(error) => self.status = format!("保存失败：{error}"),
        }
        if !api_key.is_empty() {
            if let Some(keychain) = &self.keychain {
                match keychain.save_secret(PROVIDER_KEY_ACCOUNT, &api_key) {
                    Ok(()) => {
                        self.api_key_input
                            .update(cx, |state, cx| state.set_value("", window, cx));
                        self.status =
                            "Provider 配置与 API Key 已保存；重启 demo 窗口生效".to_string();
                    }
                    Err(error) => self.status = format!("API Key 保存失败：{error}"),
                }
            }
        }
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
        let settings_open = self.settings_open;
        let base_url_input = self.base_url_input.clone();
        let model_input = self.model_input.clone();
        let api_key_input = self.api_key_input.clone();
        let can_undo = self.last_checkpoint.is_some() && !busy;
        let change_count = self.checkpoint_changes.len();
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
                    .px(space(3))
                    .py(space(2))
                    .border_b_1()
                    .border_color(palette.line)
                    .child(div().text_size(px(15.0)).child("Native Agent（P1a）"))
                    .child(
                        div()
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap(space(2))
                            .child(div().text_size(px(11.0)).text_color(palette.ink_3).child(
                                format!("model: {model_label} · usage: {usage} tokens · {status}"),
                            ))
                            .child(
                                div()
                                    .id("native-agent-settings")
                                    .role(Role::Button)
                                    .aria_label("Provider 设置")
                                    .px(space(2))
                                    .py(px(2.0))
                                    .rounded(px(RADIUS_MEDIUM))
                                    .bg(palette.soft)
                                    .text_color(palette.ink)
                                    .child("Provider 设置")
                                    .on_click(
                                        cx.listener(|this, _, _window, cx| {
                                            this.toggle_settings(cx)
                                        }),
                                    ),
                            ),
                    ),
            )
            .children(settings_open.then(|| {
                div()
                    .id("native-agent-provider-settings")
                    .flex()
                    .flex_col()
                    .gap(space(1))
                    .px(space(3))
                    .py(space(2))
                    .border_b_1()
                    .border_color(palette.line)
                    .bg(palette.view)
                    .child(
                        div()
                            .text_size(px(12.0))
                            .child("Provider 设置（OpenAI-compatible）"),
                    )
                    .child(settings_field("Base URL", &base_url_input, &palette))
                    .child(settings_field("Model", &model_input, &palette))
                    .child(settings_field("API Key", &api_key_input, &palette))
                    .child(
                        div()
                            .id("native-agent-settings-save")
                            .role(Role::Button)
                            .aria_label("保存 Provider 设置")
                            .px(space(3))
                            .py(space(1))
                            .rounded(px(RADIUS_MEDIUM))
                            .bg(palette.accent)
                            .text_color(palette.canvas)
                            .child("保存")
                            .on_click(cx.listener(|this, _, window, cx| {
                                this.save_provider_settings(window, cx)
                            })),
                    )
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
            .children(pending.map(|prompt| {
                let args = serde_json::to_string(&prompt.args).unwrap_or_default();
                div()
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
                            .child(format!("需要审批：{} {}", prompt.tool_name, args)),
                    )
                    .child(
                        div()
                            .flex()
                            .flex_row()
                            .gap(space(2))
                            .child(approval_button("允许一次", true, cx, |this, cx| {
                                this.resolve_approval(ApprovalDecision::AllowOnce, cx);
                            }))
                            .child(approval_button("本会话允许", true, cx, |this, cx| {
                                this.resolve_approval(ApprovalDecision::AllowForSession, cx);
                            }))
                            .child(approval_button("拒绝", false, cx, |this, cx| {
                                this.resolve_approval(ApprovalDecision::Deny, cx);
                            })),
                    )
            }))
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap(space(2))
                    .p(space(2))
                    .border_t_1()
                    .border_color(palette.line)
                    .child(
                        div()
                            .flex_1()
                            .rounded(px(RADIUS_MEDIUM))
                            .border_1()
                            .border_color(palette.line)
                            .bg(palette.view)
                            .px(space(1))
                            .py(px(4.0))
                            .child(
                                Textarea::new(&input)
                                    .appearance(false)
                                    .bordered(false)
                                    .h(px(36.0))
                                    .w_full(),
                            ),
                    )
                    .children((can_undo && change_count > 0).then(|| {
                        div()
                            .id("native-agent-changes")
                            .role(Role::Button)
                            .aria_label("查看变更")
                            .px(space(2))
                            .py(space(1))
                            .rounded(px(RADIUS_MEDIUM))
                            .bg(palette.soft)
                            .text_color(palette.ink)
                            .child(format!("变更 ({change_count})"))
                            .on_click(
                                cx.listener(|this, _, _window, cx| {
                                    this.toggle_checkpoint_panel(cx)
                                }),
                            )
                    }))
                    .children(can_undo.then(|| {
                        div()
                            .id("native-agent-undo")
                            .role(Role::Button)
                            .aria_label("撤销文件改动")
                            .px(space(2))
                            .py(space(1))
                            .rounded(px(RADIUS_MEDIUM))
                            .bg(palette.soft)
                            .text_color(palette.ink)
                            .child("撤销文件改动")
                            .on_click(cx.listener(|this, _, _window, cx| this.undo_checkpoint(cx)))
                    }))
                    .child(
                        div()
                            .id(if busy {
                                "native-agent-stop"
                            } else {
                                "native-agent-send"
                            })
                            .role(Role::Button)
                            .aria_label(if busy { "停止" } else { "发送" })
                            .px(space(3))
                            .py(space(1))
                            .rounded(px(RADIUS_MEDIUM))
                            .bg(if busy { palette.danger } else { palette.accent })
                            .text_color(palette.canvas)
                            .child(if busy { "停止" } else { "发送" })
                            .on_click(cx.listener(move |this, _, _window, cx| {
                                if busy {
                                    this.stop(cx);
                                } else {
                                    this.send(cx);
                                }
                            })),
                    ),
            )
    }
}

fn settings_field(
    label: &'static str,
    input: &Entity<TextareaState>,
    palette: &crate::theme::Palette,
) -> AnyElement {
    div()
        .flex()
        .flex_row()
        .items_center()
        .gap(space(2))
        .child(
            div()
                .w(px(90.0))
                .text_size(px(12.0))
                .text_color(palette.ink_3)
                .child(label),
        )
        .child(
            div()
                .flex_1()
                .child(Textarea::new(input).h(px(30.0)).w_full()),
        )
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
