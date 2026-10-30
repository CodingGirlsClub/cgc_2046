//! UI drafts and attachments. Runtime construction is exclusively a RootView responsibility.

use super::*;

impl NativeAgentView {
    pub(crate) fn new(
        window: &mut Window,
        cx: &mut Context<Self>,
        runtime: NativeRuntimeHandle,
        page_context: crate::page_context::PageContextState,
        writer: Option<cgc_agent_store::StoreWriter>,
    ) -> Self {
        let runtime_for_events = runtime.clone();
        let mut events = runtime.subscribe();
        cx.spawn(async move |this, cx| loop {
            while let Some(event) = events.next().await {
                let applied = this.update(cx, |this, cx| this.apply_runtime_event(&event, cx));
                if applied.is_err() {
                    // 实体在构造期尚未挂到窗口，首帧前 update 会失败；此时重新订阅，
                    // 不要把订阅永久丢掉（真机：卡在「正在载入会话…」）。
                    break;
                }
            }
            cx.background_executor()
                .timer(std::time::Duration::from_millis(50))
                .await;
            events = runtime_for_events.subscribe();
        })
        .detach();
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
            |this, _state, event: &InputEvent, window, cx| {
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
                    if *secondary
                        && this.is_generating()
                        && this.state.session.thread.capabilities.steer_available()
                    {
                        // ⌘↩：生成中立即打断并发送。
                        this.steer(window, cx);
                    } else {
                        this.send(window, cx);
                    }
                    cx.notify();
                }
            },
        ));
        let seeded_snapshot = runtime.latest_snapshot();
        Self {
            runtime,
            snapshot: seeded_snapshot,
            writer,
            initial_snapshot_requested: false,
            page_context,
            slash_index: 0,
            slash_dismissed: false,
            mention_index: 0,
            workspace_files: Vec::new(),
            skills: Vec::new(),
            last_turn: None,
            expanded_tools: Default::default(),
            expanded_thinking: Default::default(),
            editing_user: None,
            user_edit_input: None,
            edit_serial: 0,
            edit_original: None,
            user_edit_subscription: None,
            user_edit_key_subscription: None,
            message_scroller: cx.new(|cx| MessageScrollerState::new(0, cx)),
            message_row_signatures: Vec::new(),
            input,
            state: NativeThreadState::new(),
            status: "正在载入会话…".into(),
            show_checkpoint_panel: false,
            pending_restart_confirm: None,
            pending_images: Vec::new(),
            sent_images: HashMap::new(),
            last_input_value: String::new(),
            _input_subscription: input_subscription,
            _key_interceptor: Some(key_interceptor),
        }
    }

    pub(super) fn handle_slash(&mut self, command: SlashCommand, cx: &mut Context<Self>) {
        match command {
            SlashCommand::Help => self
                .state
                .push_notice("命令：/help /clear /stop /tools /checkpoint /settings"),
            SlashCommand::Clear => {
                self.state.session.thread.entries.clear();
                self.state.session.thread.status = cgc_agent_ui::conversation::ThreadStatus::Idle;
                self.state.session.thread.pending_permission = None;
                self.sent_images.clear();
                self.state.session.last_error = None;
                self.status = "对话显示已清空".to_string();
            }
            SlashCommand::Stop => self.stop(cx),
            SlashCommand::Tools => {
                let tools = self
                    .metadata()
                    .schemas
                    .iter()
                    .map(|schema| schema.name.clone())
                    .collect::<Vec<_>>()
                    .join(" / ");
                self.state.push_notice(format!("可用工具：{tools}"));
            }
            SlashCommand::Checkpoint => {
                if !self.metadata().checkpoints.is_empty() {
                    self.show_checkpoint_panel = true;
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
        if let Some(command) = parse_slash(&text) {
            self.input
                .update(cx, |state, cx| state.set_value("", window, cx));
            self.handle_slash(command, cx);
            return;
        }
        if !self.ensure_model_configured(true, cx) {
            return;
        }
        self.input
            .update(cx, |state, cx| state.set_value("", window, cx));
        let prompt = mention::resolve_prompt(&content, &self.metadata().workspace);
        let (prompt, context) = self.page_context.freeze(self.conversation_scope(), prompt);
        let images = self
            .pending_images
            .drain(..)
            .map(|image| cgc_agent_core::ImageAttachment {
                name: image.name,
                mime_type: image.mime,
                data: image.data,
            })
            .collect();
        let submission = self
            .state
            .session
            .submission(text, prompt, context, images, false);
        self.state.session.queue_mode = QueueMode::Auto;
        self.state.session.queue.push(submission);
        self.dispatch_queued(cx);
    }

    pub(super) fn model_supports_images(&self) -> bool {
        self.snapshot.as_ref().is_some_and(|snapshot| {
            snapshot
                .providers
                .iter()
                .find(|provider| provider.id == snapshot.model.provider_id.as_str())
                .is_some_and(|provider| {
                    provider
                        .model_config(snapshot.model.id.as_str())
                        .supports_images
                })
        })
    }

    pub(super) fn ensure_model_configured(&mut self, notify: bool, cx: &mut Context<Self>) -> bool {
        if self.metadata().model_setup.allows_send() {
            return true;
        }
        if notify {
            self.state.push_notice(
                "还没有连接模型。请先在 Settings → AI → LLM Providers 配置 Provider；DeepSeek API Key 可在 platform.deepseek.com 获取。"
                    .to_string(),
            );
            cx.notify();
        }
        false
    }

    pub(super) fn open_model_settings(&mut self, cx: &mut Context<Self>) {
        let opened = crate::root_view::root_weak()
            .and_then(|root| {
                root.update(cx, |root, cx| root.open_settings_ai_window(cx))
                    .ok()
            })
            .is_some();
        if !opened {
            self.state.push_notice("请在账号菜单里打开设置");
            cx.notify();
        }
    }

    pub(super) fn add_clipboard_image(&mut self, cx: &mut Context<Self>) {
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

    /// 重试上一轮失败的请求：不新增用户气泡，直接用同一 prompt 重跑。
    pub(super) fn retry_last_turn(&mut self, cx: &mut Context<Self>) {
        if !self.ensure_model_configured(true, cx) {
            return;
        }
        if !self.state.session.begin_retry() {
            return;
        }
        let Some((prompt, display, context)) = self.last_turn.clone() else {
            self.state.push_notice("没有可重试的请求");
            cx.notify();
            return;
        };
        // 重试 = 重放上一轮：线程侧丢掉失败那轮的 user 条目（prompt 会重新 push，
        // 否则重启恢复后会出现重复用户气泡）；UI 侧丢掉失败 turn 的残留行。
        if let Some(index) = trim_entries_to_last_user(&mut self.state.session.thread.entries) {
            self.sent_images
                .retain(|entry_index, _| *entry_index <= index);
        }
        let submission = self
            .state
            .session
            .submission(display, prompt, context, Vec::new(), true);
        self.state.session.queue_mode = QueueMode::Auto;
        self.state.session.queue.insert(0, submission);
        self.dispatch_queued(cx);
    }

    pub(super) fn stop(&mut self, cx: &mut Context<Self>) {
        self.runtime.stop();
        self.state.session.stop();
        self.status = "正在停止…".to_string();
        cx.notify();
    }
}
