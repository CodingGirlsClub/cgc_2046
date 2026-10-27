//! 视图构造与运行时初始化（B4b 结构拆分第十片：从模块根移出，行为不变）。
//!
//! 子模块可访问父模块私有字段。

use super::*;

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

    pub(super) fn new_inner(
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

    pub(super) fn handle_slash(&mut self, command: SlashCommand, cx: &mut Context<Self>) {
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

    pub(super) fn send(&mut self, window: &mut Window, cx: &mut Context<Self>) {
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

    pub(super) fn model_supports_images(&self) -> bool {
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

    pub(super) fn add_clipboard_image(&mut self, cx: &mut Context<Self>) {
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
    pub(super) fn add_images_from_picker(&mut self, cx: &mut Context<Self>) {
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
    pub(super) fn refresh_provider_credentials(&mut self, cx: &mut Context<Self>, force: bool) {
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
    pub(super) fn add_images_from_paths(
        &mut self,
        paths: &[std::path::PathBuf],
        cx: &mut Context<Self>,
    ) {
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

    pub(super) fn open_image_viewer(
        &mut self,
        name: String,
        image: Arc<RenderImage>,
        cx: &mut Context<Self>,
    ) {
        let focus = cx.focus_handle();
        crate::image_viewer::open(name, image, focus, cx);
    }

    /// 发送一条新消息：记录本轮 prompt 供失败重试，然后跑一个 turn。
    pub(super) fn send_prompt(&mut self, text: String, display: String, cx: &mut Context<Self>) {
        self.refresh_provider_credentials(cx, false);
        self.last_turn = Some((text.clone(), display.clone()));
        self.run_turn(text, display, false, cx);
    }

    /// 重试上一轮失败的请求：不新增用户气泡，直接用同一 prompt 重跑。
    pub(super) fn retry_last_turn(&mut self, cx: &mut Context<Self>) {
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

    pub(super) fn stop(&mut self, cx: &mut Context<Self>) {
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
