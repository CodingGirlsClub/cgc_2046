use super::*;
use cgc_platform::registry::install::{install_entry, SystemRunner};
use gpui_kit::component::breadcrumb::{Breadcrumb, BreadcrumbItem};
use state::{PaneTab, SiteTreeSection};

impl RootView {
    pub fn current(&self) -> Option<Route> {
        self.current.as_ref().map(|route_match| route_match.route)
    }

    pub fn current_match(&self) -> Option<&RouteMatch> {
        self.current.as_ref()
    }

    pub fn language(&self) -> Language {
        self.language
    }

    pub fn preference(&self) -> ThemePreference {
        self.preference
    }

    pub fn account_menu_open(&self) -> bool {
        self.account_menu_open
    }

    pub fn toggle_account_menu(&mut self) -> bool {
        self.account_menu_open = !self.account_menu_open;
        self.account_menu_open
    }

    pub fn close_account_menu(&mut self) {
        self.account_menu_open = false;
    }

    pub fn is_signed_in(&self) -> bool {
        self.session.signed_in().is_some()
    }

    pub fn session_state(&self) -> &SessionState {
        self.session.state()
    }

    pub fn select(&mut self, route: Route) {
        self.breadcrumb_menu = None;
        self.current = Some(RouteMatch {
            route,
            params: std::collections::BTreeMap::new(),
        });
    }

    /// 按路径导航（动态路由在此完成参数解析）。
    pub fn navigate(&mut self, path: &str) {
        self.breadcrumb_menu = None;
        self.site_tree_search_focused = false;
        if let crate::routing::RouteSelection::Match(route_match) = self.registry.select(path) {
            let is_learning = route_match.route.id == "courses.learning";
            self.current = Some(route_match);
            self.events_started = false;
            self.detail_started = false;
            if is_learning && self.right_panel_open {
                self.right_panel = RightPanel::Outline;
            }
        }
    }

    pub(in crate::root_view) fn navigate_to_event_detail(
        &mut self,
        event_id: &str,
        cx: &mut Context<Self>,
    ) {
        let path = format!("/events/{event_id}");
        let title = self
            .events
            .items()
            .iter()
            .find(|event| event.id == event_id)
            .map(|event| event.title.clone())
            .unwrap_or_else(|| "活动".to_string());
        self.open_page_tab(&path, title, cx);
    }

    pub fn toggle_language(&mut self) -> Language {
        self.language = self.language.toggle();
        self.language
    }

    pub fn cycle_theme(&mut self) -> ThemePreference {
        self.preference = self.preference.cycle();
        self.preference
    }

    /// 系统外观变化时由 `observe_window_appearance` 调用：只有「跟随系统」才重刷 kit 主题。
    pub fn on_appearance_changed(&mut self, appearance: WindowAppearance, cx: &mut Context<Self>) {
        if self.preference == ThemePreference::System {
            theme::apply(theme::resolve(self.preference, appearance), cx);
            cx.notify();
        }
    }

    pub(in crate::root_view) fn session_token(&self) -> Option<String> {
        self.session
            .signed_in()
            .map(|session| session.token.clone())
    }

    pub(in crate::root_view) fn reset_events(&mut self) {
        self.events_started = false;
        self.enrollments_started = false;
        self.enrollments_rows.clear();
        self.enrollments_state = EnrollmentsListState::Idle;
        self.detail_started = false;
        self.courses_started = false;
        self.course_detail_started = false;
        self.selected_event = None;
    }

    pub(in crate::root_view) fn force_sign_out(&mut self, cx: &mut Context<Self>) {
        self.session.sign_out_local();
        self.workspaces.reset();
        self.workspaces_started = false;
        self.session_checked = false;
        self.reset_workspace_data(cx);
        self.navigate("/");
        cx.notify();
    }

    pub(in crate::root_view) fn start_session_validation(&mut self, cx: &mut Context<Self>) {
        let Some(token) = self.session_token() else {
            return;
        };
        let api = self.session.api_handle();
        let task = cx
            .background_executor()
            .spawn(async move { api.validate(&token) });
        cx.spawn(async move |this, cx| {
            let result = task.await;
            if let Ok(false) = result {
                let _ = this.update(cx, |this, cx| this.force_sign_out(cx));
            }
        })
        .detach();
    }

    pub(in crate::root_view) fn start_workspace_load(&mut self, cx: &mut Context<Self>) {
        self.workspaces.begin_load();
        self.workspaces_started = true;
        let api = self.workspaces.api_handle();
        let token = self.session_token();
        let task = cx
            .background_executor()
            .spawn(async move { api.list_workspaces(token.as_deref()) });
        cx.spawn(async move |this, cx| {
            let result = task.await;
            let _ = this.update(cx, |this, cx| {
                match result {
                    Ok(workspaces) => {
                        this.workspaces.adopt(workspaces);
                        this.restore_workspace_state(cx);
                    }
                    Err(error) if error.is_unauthorized() => this.force_sign_out(cx),
                    Err(error) => this.workspaces.fail(&error),
                }
                cx.notify();
            });
        })
        .detach();
    }

    pub(in crate::root_view) fn switch_workspace(
        &mut self,
        workspace_id: &str,
        cx: &mut Context<Self>,
    ) {
        let previous = self.workspaces.current_id().map(str::to_string);
        if let Some(previous) = previous.as_deref() {
            self.persist_workspace_state(previous);
        }
        if self.workspaces.switch_to(workspace_id) {
            self.reset_workspace_data(cx);
            self.navigate("/workspace");
            self.restore_workspace_state(cx);
            self.workspace_menu_open = false;
            cx.notify();
        }
    }

    pub(in crate::root_view) fn reset_workspace_data(&mut self, cx: &mut Context<Self>) {
        self.reset_events();
        self.events.reset();
        self.detail.reset();
        self.courses.reset();
        self.course_enrollments.clear();
        self.course_detail.reset();
        self.content.reset();
        self.projection.reset();
        self.pending_link = None;
        self.selected_event = None;
        self.selected_tier = None;
        self.age_confirmed = false;
        self.enrolling = false;
        self.enrollment_error = None;
        self.payment = PaymentViewState::Idle;
        self.payment_generation = self.payment_generation.saturating_add(1);
        self.deposit_consent = false;
        self.reset_chat_local(cx);
        self.tabs.clear();
        self.active_tab = None;
        self.site_tree_query.clear();
        self.site_tree_course_open = None;
        self.site_tree_scroll = ScrollHandle::new();
        self.site_tree_scroll_restore = None;
        self.review_event_keys.clear();
    }

    pub(in crate::root_view) fn start_projection_load(
        &mut self,
        cx: &mut Context<Self>,
        course_id: String,
    ) {
        self.projection.begin_load(&course_id);
        let api = self.projection.api_handle();
        let token = self.session_token();
        let epoch = self.workspaces.epoch();
        let task = cx
            .background_executor()
            .spawn(async move { api.get_learning_projection(token.as_deref(), &course_id) });
        cx.spawn(async move |this, cx| {
            let result = task.await;
            let _ = this.update(cx, |this, cx| {
                if !this.workspaces.is_current_epoch(epoch) {
                    return;
                }
                match result {
                    Ok(projection) => {
                        let user_id = this
                            .session
                            .signed_in()
                            .map(|session| session.user_id.clone());
                        if let (Some(user_id), Some(key)) = (
                            user_id,
                            projection.review_dedup_key(
                                this.session
                                    .signed_in()
                                    .map(|session| session.user_id.as_str())
                                    .unwrap_or(""),
                            ),
                        ) {
                            if this.review_event_keys.insert(key.clone()) {
                                this.events_bus.publish(AppEvent::ReviewQueueDue {
                                    user_id,
                                    course_id: projection.course_id.clone(),
                                    dedup_key: key,
                                });
                            }
                        }
                        this.projection.adopt(projection)
                    }
                    Err(error) if error.is_unauthorized() => this.force_sign_out(cx),
                    Err(error) => this.projection.fail(&error),
                }
                cx.notify();
            });
        })
        .detach();
    }

    pub(in crate::root_view) fn start_content_load(
        &mut self,
        cx: &mut Context<Self>,
        course_id: String,
    ) {
        self.content.begin_load(&course_id);
        let api = self.content.api_handle();
        let token = self.session_token();
        let epoch = self.workspaces.epoch();
        let task = cx
            .background_executor()
            .spawn(async move { api.get_course_content(token.as_deref(), &course_id) });
        cx.spawn(async move |this, cx| {
            let result = task.await;
            let _ = this.update(cx, |this, cx| {
                if !this.workspaces.is_current_epoch(epoch) {
                    return;
                }
                match result {
                    Ok(content) => this.content.adopt(content),
                    Err(error) if error.is_unauthorized() => this.force_sign_out(cx),
                    Err(error) => this.content.fail(&error),
                }
                cx.notify();
            });
        })
        .detach();
    }

    pub(in crate::root_view) fn chat_course_context(
        &self,
    ) -> Result<CourseContext, cgc_platform::workspace::ContextError> {
        let detail = self.course_detail.detail();
        let mut provider = CourseContextProvider::from_parts(
            self.session
                .signed_in()
                .map(|session| session.user_id.clone()),
            self.workspaces
                .current()
                .map(|workspace| workspace.id.clone()),
            detail.map(|detail| detail.id.clone()),
            detail
                .and_then(|detail| detail.revision_number)
                .map(|revision| revision.to_string()),
        );
        provider.workspace_epoch = Some(self.workspaces.epoch());
        provider.current()
    }

    pub(in crate::root_view) fn start_chat(&mut self, cx: &mut Context<Self>) {
        if matches!(
            self.chat.phase,
            ChatPhase::Starting | ChatPhase::Ready | ChatPhase::Streaming
        ) {
            return;
        }
        let Some(token) = self.session_token() else {
            return;
        };
        let context = match self.chat_course_context() {
            Ok(context) => context,
            Err(_) => {
                self.chat.phase = ChatPhase::Failed(
                    translate(self.language, Key::AgentChatChatContextRequired).to_string(),
                );
                return;
            }
        };
        let epoch = self.workspaces.epoch();
        let cwd = std::env::temp_dir().join("cgc-desktop-chat");
        let _ = std::fs::create_dir_all(&cwd);
        let course_id = Some(context.course_id.clone());
        let requested_agent = self.chat.selected_agent.clone();
        let load_agent = requested_agent.as_deref().unwrap_or("omp");
        let load_session = self.chat.restore_id.take().or_else(|| {
            course_id
                .as_deref()
                .and_then(|course_id| load_chat_pointer(course_id, load_agent))
        });
        self.chat.course_id = course_id;
        self.chat.session_id = None;
        self.chat.configs.clear();
        self.chat.configs_applied = false;
        self.chat.history_open = load_session.is_some();
        self.chat.streaming_message_open = false;
        self.chat.phase = ChatPhase::Starting;
        self.chat.messages.clear();
        self.chat.auto_prompted = false;
        let task = cx.background_executor().spawn(async move {
            let api = build_learning_host_api();
            let vault = build_learning_host_vault();
            let registry = Registry::builtin().map_err(|error| ChatStartError {
                message: error.diagnostic(),
                detected: Vec::new(),
                node_found: None,
            })?;
            let probe = SystemProbe;
            let node = cgc_platform::agent::detect::detect_node(&probe, &registry.node_required);
            let mut detected = detect_all(&registry, &probe);
            let installed = load_installed_agents();
            for row in &mut detected {
                if let Some(version) = installed.get(&row.entry.id) {
                    row.status = AgentStatus::Ready {
                        version: version.clone(),
                    };
                }
            }
            let guidance = detected
                .iter()
                .map(|agent| {
                    (
                        agent.entry.display_name.clone(),
                        format!("{:?}", agent.status),
                    )
                })
                .collect::<Vec<_>>();
            let managed_node = NodeRuntimeManager::default_manager().installed_runtime();
            let node_found = managed_node
                .is_some()
                .then(|| cgc_platform::agent::node_runtime::NODE_VERSION.to_string())
                .or_else(|| node.found.clone());
            if std::env::var("CGC_NO_AGENT").as_deref() == Ok("1") {
                return Err(ChatStartError {
                    message: "no local agent ready (QA)".to_string(),
                    detected: guidance,
                    node_found,
                });
            }
            let chosen = match requested_agent.as_deref() {
                Some(requested) => detected
                    .iter()
                    .find(|agent| {
                        agent.entry.id == requested
                            && matches!(agent.status, AgentStatus::Ready { .. })
                    })
                    .ok_or_else(|| ChatStartError {
                        message: format!("selected agent not ready: {requested}"),
                        detected: guidance.clone(),
                        node_found: node_found.clone(),
                    })?,
                None => detected
                    .iter()
                    .find(|agent| {
                        agent.entry.id == "omp" && matches!(agent.status, AgentStatus::Ready { .. })
                    })
                    .or_else(|| {
                        detected
                            .iter()
                            .find(|agent| matches!(agent.status, AgentStatus::Ready { .. }))
                    })
                    .ok_or_else(|| ChatStartError {
                        message: "no local agent ready".to_string(),
                        detected: guidance.clone(),
                        node_found: node_found.clone(),
                    })?,
            };
            let lease = issue_lease(api.as_ref(), vault.as_ref(), &token, "cgc-desktop", epoch)
                .map_err(|error| ChatStartError {
                    message: error.diagnostic(),
                    detected: guidance.clone(),
                    node_found: node_found.clone(),
                })?;
            let managed =
                managed_node.or_else(|| std::env::var_os("CGC_MANAGED_NODE").map(NodeRuntime::new));
            let plan = build_launch(&chosen.entry, managed.as_ref(), &cwd).map_err(|error| {
                ChatStartError {
                    message: error.to_string(),
                    detected: guidance.clone(),
                    node_found: node_found.clone(),
                }
            })?;
            let endpoint = mcp_endpoint(std::env::var("CGC_API_URL").ok().as_deref());
            let server = build_mcp_server(&chosen.entry, &lease, &endpoint);
            Ok::<PreparedChat, ChatStartError>(PreparedChat {
                agent_id: chosen.entry.id.clone(),
                agent_name: chosen.entry.display_name.clone(),
                plan,
                lease,
                server,
            })
        });
        cx.spawn(async move |this, cx| {
            let result = task.await;
            let _ = this.update(cx, |this, cx| {
                match result {
                    Ok(prepared) => {
                        let mut config = AcpHostConfig::new(
                            prepared.plan.command_string(),
                            prepared.plan.cwd.clone(),
                        )
                        .with_name("agent")
                        .with_mcp_servers(vec![prepared.server]);
                        if let Some(load_session) = &load_session {
                            config = config.with_load_session(load_session.clone());
                        }
                        match AcpHost::start(config) {
                            Ok(host) => {
                                this.chat.host = Some(host);
                                this.chat.lease = Some(prepared.lease);
                                this.chat.selected_agent = Some(prepared.agent_id.clone());
                                this.chat.agent = prepared.agent_name;
                                this.chat.phase = ChatPhase::Ready;
                                this.chat.poll_generation += 1;
                                let generation = this.chat.poll_generation;
                                this.spawn_chat_poller(cx, generation);
                            }
                            Err(error) => {
                                this.chat.phase = ChatPhase::Failed(error.to_string());
                            }
                        }
                    }
                    Err(error) => {
                        this.chat.guidance = Some(ChatGuidance {
                            detected: error.detected,
                            node_found: error.node_found,
                        });
                        this.chat.phase = ChatPhase::Failed(error.message);
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    pub(in crate::root_view) fn spawn_chat_poller(
        &mut self,
        cx: &mut Context<Self>,
        generation: u64,
    ) {
        cx.spawn(async move |this, cx| loop {
            cx.background_executor()
                .timer(Duration::from_millis(100))
                .await;
            let keep = this
                .update(cx, |this, cx| this.drain_chat_events(generation, cx))
                .unwrap_or(false);
            if !keep {
                break;
            }
        })
        .detach();
    }

    pub(in crate::root_view) fn drain_chat_events(
        &mut self,
        generation: u64,
        cx: &mut Context<Self>,
    ) -> bool {
        if generation != self.chat.poll_generation {
            return false;
        }
        let mut events = Vec::new();
        if let Some(host) = &self.chat.host {
            while let Some(event) = host.try_recv() {
                events.push(event);
            }
        }
        for event in events {
            match event {
                HostEvent::Ready {
                    agent_name,
                    version,
                    session_id,
                } => {
                    self.chat.agent = agent_name;
                    self.chat.version = Some(version);
                    self.chat.session_id = Some(session_id.clone());
                    self.chat.phase = ChatPhase::Ready;
                    if let Some(course_id) = self.chat.course_id.clone() {
                        let agent_id = self
                            .chat
                            .selected_agent
                            .clone()
                            .unwrap_or_else(|| "omp".to_string());
                        save_chat_pointer(&course_id, &agent_id, &session_id);
                    }
                }
                HostEvent::ConfigOptions { options } => {
                    self.chat.configs = options;
                    if !self.chat.configs_applied {
                        self.chat.configs_applied = true;
                        let agent_id = self
                            .chat
                            .selected_agent
                            .clone()
                            .unwrap_or_else(|| "omp".to_string());
                        for config in self.chat.configs.clone() {
                            if let Some(value) = load_chat_pref(&agent_id, &config.id) {
                                if let Some(host) = &self.chat.host {
                                    let _ = host.set_config(config.id.clone(), value);
                                }
                            }
                        }
                    }
                }
                HostEvent::Sessions { sessions } => {
                    self.chat.sessions = sessions;
                    self.chat.show_sessions = true;
                    if std::env::var("CGC_AUTO_RESTORE").as_deref() == Ok("1")
                        && !self.chat.auto_prompted
                        && !self.chat.sessions.is_empty()
                    {
                        self.chat.auto_prompted = true;
                        let session_id = self.chat.sessions[0].session_id.clone();
                        self.restore_chat_session(session_id, cx);
                    }
                }
                HostEvent::Delta(chunk) => {
                    if self.chat.history_open {
                        match self.chat.messages.last_mut() {
                            Some(ChatEntry::Assistant(text)) => text.push_str(&chunk),
                            _ => self.chat.messages.push(ChatEntry::Assistant(chunk)),
                        }
                        continue;
                    }
                    self.chat.phase = ChatPhase::Streaming;
                    if self.chat.streaming_message_open {
                        if let Some(ChatEntry::Assistant(text)) = self.chat.messages.last_mut() {
                            text.push_str(&chunk);
                        }
                    } else {
                        self.chat.messages.push(ChatEntry::Assistant(chunk));
                        self.chat.streaming_message_open = true;
                    }
                }
                HostEvent::ToolCall { title, kind } => {
                    self.chat.phase = ChatPhase::Streaming;
                    self.chat.messages.push(ChatEntry::Tool { title, kind });
                }
                HostEvent::PermissionRequested { request_id, title } => {
                    self.chat.messages.push(ChatEntry::Permission {
                        request_id,
                        title,
                        resolved: None,
                    });
                    if std::env::var("CGC_AUTO_APPROVE").as_deref() == Ok("1") {
                        self.respond_chat_permission(true, cx);
                    }
                }
                HostEvent::TurnEnd { .. } => {
                    self.chat.phase = ChatPhase::Ready;
                    self.chat.streaming_message_open = false;
                }
                HostEvent::Error { message } => {
                    self.chat.phase = ChatPhase::Failed(message);
                }
                HostEvent::Exited => {
                    // 先到的 Error 更具体，不要用通用退出文案覆盖它。
                    if !matches!(self.chat.phase, ChatPhase::Idle | ChatPhase::Failed(_)) {
                        self.chat.phase = ChatPhase::Failed("agent process exited".to_string());
                    }
                    self.chat.host = None;
                }
            }
        }
        if matches!(self.chat.phase, ChatPhase::Ready)
            && std::env::var("CGC_AUTO_HISTORY").as_deref() == Ok("1")
            && !self.chat.show_sessions
        {
            if let Some(host) = &self.chat.host {
                let _ = host.list_sessions();
            }
            self.chat.show_sessions = true;
        }
        // QA/截图：Ready 后自动发一条 prompt。
        if matches!(self.chat.phase, ChatPhase::Ready)
            && !self.chat.auto_prompted
            && std::env::var("CGC_AUTO_CHAT").as_deref() == Ok("1")
        {
            self.chat.auto_prompted = true;
            if let Ok(prompt) = std::env::var("CGC_AUTO_CHAT_PROMPT") {
                if !prompt.trim().is_empty() {
                    self.send_chat_text(prompt, cx);
                }
            }
        }
        cx.notify();
        self.chat.host.is_some()
    }

    pub(in crate::root_view) fn send_chat(&mut self, cx: &mut Context<Self>) {
        let text = self.chat.input.trim().to_string();
        if text.is_empty() {
            return;
        }
        self.chat.input.clear();
        self.send_chat_text(text, cx);
    }

    pub(in crate::root_view) fn send_chat_text(&mut self, text: String, cx: &mut Context<Self>) {
        if !matches!(self.chat.phase, ChatPhase::Ready) {
            return;
        }
        let Some(host) = &self.chat.host else {
            return;
        };
        let prompt = match self.active_tab_context_note() {
            Some(note) => format!("{note}\n\n{text}"),
            None => text.clone(),
        };
        if !host.prompt(prompt) {
            self.chat.phase = ChatPhase::Failed("agent channel closed".to_string());
            return;
        }
        self.chat.history_open = false;
        self.chat.streaming_message_open = false;
        self.chat.messages.push(ChatEntry::User(text));
        self.chat.phase = ChatPhase::Streaming;
        cx.notify();
    }

    pub(in crate::root_view) fn stop_chat_turn(&mut self, cx: &mut Context<Self>) {
        if let Some(host) = &self.chat.host {
            host.stop();
        }
        cx.notify();
    }

    pub(in crate::root_view) fn respond_chat_permission(
        &mut self,
        allow: bool,
        cx: &mut Context<Self>,
    ) {
        let Some((request_id, index)) =
            self.chat
                .messages
                .iter()
                .enumerate()
                .rev()
                .find_map(|(index, entry)| match entry {
                    ChatEntry::Permission {
                        request_id,
                        resolved: None,
                        ..
                    } => Some((request_id.clone(), index)),
                    _ => None,
                })
        else {
            return;
        };
        if let Some(host) = &self.chat.host {
            let _ = host.respond_permission(&request_id, allow);
        }
        if let Some(ChatEntry::Permission { resolved, .. }) = self.chat.messages.get_mut(index) {
            *resolved = Some(allow);
        }
        cx.notify();
    }

    pub(in crate::root_view) fn cycle_chat_config(&mut self, index: usize, cx: &mut Context<Self>) {
        let Some(config) = self.chat.configs.get(index).cloned() else {
            return;
        };
        if config.values.is_empty() {
            return;
        }
        let current = config
            .values
            .iter()
            .position(|(value, _)| value == &config.current)
            .unwrap_or(0);
        let next = (current + 1) % config.values.len();
        let value = config.values[next].0.clone();
        if let Some(host) = &self.chat.host {
            let _ = host.set_config(config.id.clone(), value.clone());
        }
        let agent_id = self
            .chat
            .selected_agent
            .clone()
            .unwrap_or_else(|| "omp".to_string());
        save_chat_pref(&agent_id, &config.id, &value);
        if let Some(entry) = self.chat.configs.get_mut(index) {
            entry.current = value;
        }
        cx.notify();
    }

    pub(in crate::root_view) fn open_chat_history(&mut self, cx: &mut Context<Self>) {
        if let Some(host) = &self.chat.host {
            let _ = host.list_sessions();
        }
        self.chat.show_sessions = true;
        cx.notify();
    }

    pub(in crate::root_view) fn restore_chat_session(
        &mut self,
        session_id: String,
        cx: &mut Context<Self>,
    ) {
        self.chat.restore_id = Some(session_id);
        self.reset_chat_local(cx);
        self.start_chat(cx);
    }

    pub(in crate::root_view) fn install_node_runtime(&mut self, cx: &mut Context<Self>) {
        if matches!(self.chat.phase, ChatPhase::Starting) {
            return;
        }
        self.chat.phase = ChatPhase::Starting;
        let task = cx
            .background_executor()
            .spawn(async { NodeRuntimeManager::default_manager().install(&HttpDownloader) });
        cx.spawn(async move |this, cx| {
            let result = task.await;
            let _ = this.update(cx, |this, cx| {
                match result {
                    Ok(()) => {
                        this.chat.guidance = None;
                        this.chat.phase = ChatPhase::Idle;
                        this.start_chat(cx);
                    }
                    Err(error) => {
                        this.chat.phase = ChatPhase::Failed(error.to_string());
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    fn revoke_chat_lease(&mut self, cx: &mut Context<Self>) {
        let Some(lease) = self.chat.lease.take() else {
            return;
        };
        let Some(session_token) = self.session_token() else {
            return;
        };
        let api = build_learning_host_api();
        cx.background_executor()
            .spawn(async move {
                let _ = api.revoke(&session_token, &lease.token_id);
            })
            .detach();
    }

    pub(in crate::root_view) fn revoke_stale_learning_tokens(&mut self, cx: &mut Context<Self>) {
        let Some(session_token) = self.session_token() else {
            return;
        };
        let api = build_learning_host_api();
        self.chat.phase = ChatPhase::Starting;
        let task = cx.background_executor().spawn(async move {
            let tokens = api
                .list(&session_token)
                .map_err(|error| error.diagnostic())?;
            let mut revoked = 0usize;
            for token in tokens
                .into_iter()
                .filter(|token| token.kind == "LEARNING_HOST")
            {
                if api.revoke(&session_token, &token.id).is_ok() {
                    revoked += 1;
                }
            }
            Ok::<usize, String>(revoked)
        });
        cx.spawn(async move |this, cx| {
            let result = task.await;
            let _ = this.update(cx, |this, cx| {
                match result {
                    Ok(_) => {
                        this.chat.lease = None;
                        this.start_chat(cx);
                    }
                    Err(error) => this.chat.phase = ChatPhase::Failed(error),
                }
                cx.notify();
            });
        })
        .detach();
    }

    pub(in crate::root_view) fn reset_chat_local(&mut self, cx: &mut Context<Self>) {
        self.chat.host.take();
        self.revoke_chat_lease(cx);
        self.chat.lease.take();
        self.chat.poll_generation = self.chat.poll_generation.saturating_add(1);
        self.chat.phase = ChatPhase::Idle;
        self.chat.agent.clear();
        self.chat.version = None;
        self.chat.messages.clear();
        self.chat.input.clear();
        self.chat.focused = false;
        self.chat.auto_prompted = false;
        self.chat.configs.clear();
        self.chat.sessions.clear();
        self.chat.show_sessions = false;
        self.chat.session_id = None;
        self.chat.course_id = None;
        self.chat.configs_applied = false;
        self.chat.history_open = false;
        self.chat.streaming_message_open = false;
        self.chat.guidance = None;
    }

    pub(in crate::root_view) fn start_courses_load(&mut self, cx: &mut Context<Self>, first: bool) {
        if first {
            self.courses.begin_first_load();
        } else {
            self.courses.begin_load_more();
        }
        self.courses_started = true;
        let api = self.courses.api_handle();
        let token = self.session_token();
        let cursor = if first {
            None
        } else {
            self.courses.next_cursor().map(str::to_string)
        };
        let epoch = self.workspaces.epoch();
        let scope = self.workspaces.scope();
        let task = cx.background_executor().spawn(async move {
            api.list_courses(token.as_deref(), scope.as_ref(), cursor.as_deref(), 10)
        });

        cx.spawn(async move |this, cx| {
            let result = task.await;
            let _ = this.update(cx, |this, cx| {
                if !this.workspaces.is_current_epoch(epoch) {
                    return;
                }
                match result {
                    Ok(page) => {
                        this.courses.adopt_page(page);
                        this.load_course_enrollments(cx);
                    }
                    Err(error) if error.is_unauthorized() => this.force_sign_out(cx),
                    Err(error) => this.courses.fail(&error),
                }
                cx.notify();
            });
        })
        .detach();
    }

    pub(in crate::root_view) fn start_course_detail_load(
        &mut self,
        cx: &mut Context<Self>,
        course_id: String,
    ) {
        self.course_detail.begin_load();
        self.course_detail_started = true;
        self.content.reset();
        self.projection.reset();
        self.pending_link = None;
        let api = self.course_detail.api_handle();
        let token = self.session_token();
        let task = cx
            .background_executor()
            .spawn(async move { api.get_course(token.as_deref(), &course_id) });
        cx.spawn(async move |this, cx| {
            let result = task.await;
            let _ = this.update(cx, |this, cx| {
                match result {
                    Ok(detail) => this.course_detail.adopt(detail),
                    Err(error) if error.is_unauthorized() => this.force_sign_out(cx),
                    Err(error) => this.course_detail.fail(&error),
                }
                cx.notify();
            });
        })
        .detach();
    }

    pub(in crate::root_view) fn navigate_to_course_detail(
        &mut self,
        course_id: &str,
        cx: &mut Context<Self>,
    ) {
        let path = format!("/courses/{course_id}");
        let title = self
            .courses
            .items()
            .iter()
            .find(|course| course.id == course_id)
            .map(|course| course.title.clone())
            .unwrap_or_else(|| "课程".to_string());
        self.open_page_tab(&path, title, cx);
    }

    pub(in crate::root_view) fn navigate_to_learning(
        &mut self,
        course_id: &str,
        cx: &mut Context<Self>,
    ) {
        let path = format!("/courses/{course_id}/learn");
        let title = self
            .courses
            .items()
            .iter()
            .find(|course| course.id == course_id)
            .map(|course| format!("{} · 学习", course.title))
            .unwrap_or_else(|| "学习".to_string());
        self.open_page_tab(&path, title, cx);
    }

    pub(in crate::root_view) fn is_settings_shortcut(keystroke: &gpui_kit::Keystroke) -> bool {
        keystroke.key == "," && (keystroke.modifiers.platform || keystroke.modifiers.control)
    }

    /// 打开独立设置窗口（对齐 Zed 的 SettingsWindow）：已存在则激活复用。
    pub fn open_settings_window(&mut self, cx: &mut Context<Self>) {
        if let Some(existing) = cx
            .windows()
            .into_iter()
            .find_map(|window| window.downcast::<SettingsWindowView>())
        {
            let _ = existing.update(cx, |_, window, _| window.activate_window());
            return;
        }
        let Some(signed_in) = self.session.signed_in().cloned() else {
            return;
        };
        let language = self.language;
        let preference = self.preference;
        let email = signed_in.email.clone();
        let user_id = signed_in.user_id.clone();
        let token = signed_in.token.clone();
        let workspace = self
            .workspaces
            .current()
            .map(|workspace| workspace.name.clone());
        let api = self.session.api_handle();
        let title = translate(language, Key::AppSettingsTitle);
        let bounds = WindowBounds::centered(
            Size {
                width: px(620.0),
                height: px(560.0),
            },
            cx,
        );
        let options = WindowOptions {
            titlebar: Some(TitlebarOptions {
                title: Some(title.into()),
                appears_transparent: true,
                traffic_light_position: Some(point(px(12.0), px(12.0))),
            }),
            focus: true,
            show: true,
            is_movable: true,
            app_owns_titlebar_drag: cfg!(target_os = "macos"),
            window_decorations: Some(WindowDecorations::Client),
            window_min_size: Some(Size {
                width: px(480.0),
                height: px(360.0),
            }),
            window_bounds: Some(bounds),
            ..Default::default()
        };
        cx.open_window(options, move |window, cx| {
            theme::apply(theme::resolve(preference, window.appearance()), cx);
            let view = cx.new(|cx| {
                SettingsWindowView::new(
                    language, preference, email, user_id, workspace, token, api, cx,
                )
            });
            let focus = view.read(cx).focus_handle();
            window.focus(&focus, cx);
            view
        })
        .ok();
    }

    pub(in crate::root_view) fn breadcrumb_context(
        &self,
    ) -> Option<(&'static str, Option<String>)> {
        let route_id = self
            .current
            .as_ref()
            .map(|route_match| route_match.route.id)?;
        match route_id {
            "account.workspace" => Some(("account.workspace.overview", None)),
            "events.list" | "events.mine" | "events.participations" => {
                Some(("events.list.title", None))
            }
            "events.detail" => Some((
                "events.list.title",
                self.detail.detail().map(|detail| detail.title.clone()),
            )),
            "courses.catalog" | "courses.learning_home" => Some(("courses.catalog.title", None)),
            "courses.detail" | "courses.learning" => Some((
                "courses.catalog.title",
                self.course_detail
                    .detail()
                    .map(|detail| detail.title.clone()),
            )),
            _ => None,
        }
    }

    pub(in crate::root_view) fn toggle_breadcrumb_menu(&mut self, cx: &mut Context<Self>) {
        self.breadcrumb_menu = if self.breadcrumb_menu.is_some() {
            None
        } else {
            Some(BreadcrumbMenu::Sections)
        };
        self.workspace_menu_open = false;
        cx.notify();
    }

    pub(in crate::root_view) fn render_breadcrumb_bar(
        &mut self,
        language: Language,
        palette: &theme::Palette,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let workspace_switcher = self.render_workspace_switcher(language, palette, cx);
        let mut bar = div()
            .flex()
            .flex_row()
            .items_center()
            .gap(px(4.0))
            .text_size(px(12.0))
            .text_color(palette.ink_3)
            .child(workspace_switcher);
        let context = self.breadcrumb_context();
        let section_label = match context {
            Some((label_key, _)) => translate_registered(language, label_key),
            None => translate(language, Key::AppBreadcrumbSections),
        };
        let selected = self.breadcrumb_menu.is_some();
        let root = cx.entity().downgrade();
        let mut breadcrumb = Breadcrumb::new().child(
            BreadcrumbItem::new(format!("{section_label} ▾"))
                .px(space(1))
                .py(px(2.0))
                .rounded(px(RADIUS_SMALL))
                .bg(if selected { palette.soft } else { palette.card })
                .on_click(move |_, _, cx| {
                    let _ = root.update(cx, |this, cx| this.toggle_breadcrumb_menu(cx));
                }),
        );
        if let Some((_, Some(title))) = context {
            breadcrumb = breadcrumb.child(BreadcrumbItem::new(title));
        }
        bar = bar.child(div().child("›")).child(breadcrumb);
        bar.into_any_element()
    }

    pub(in crate::root_view) fn render_breadcrumb_menu(
        &mut self,
        language: Language,
        palette: &theme::Palette,
        _menu: BreadcrumbMenu,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let current = self
            .current
            .as_ref()
            .map(|route_match| route_match.route.id);
        let rows = [
            ("account.workspace", "/workspace", "account.workspace.title"),
            ("events.list", "/events", "events.list.title"),
            ("courses.catalog", "/courses", "courses.catalog.title"),
            (
                "courses.learning_home",
                "/learning",
                "courses.learning_home.title",
            ),
            (
                "events.participations",
                "/participations",
                "events.participations.title",
            ),
        ]
        .into_iter()
        .map(|(route_id, path, title_key)| {
            let selected = current.is_some_and(|id| {
                id == route_id
                    || id.starts_with(&format!("{route_id}."))
                    || (route_id == "events.list" && id == "events.mine")
            });
            div()
                .id(format!("breadcrumb-{}", route_id))
                .flex()
                .flex_row()
                .items_center()
                .justify_between()
                .px(space(1))
                .py(px(5.0))
                .rounded(px(RADIUS_SMALL))
                .text_size(px(12.0))
                .text_color(palette.ink_2)
                .hover(|style| style.bg(palette.soft))
                .child(translate_registered(language, title_key))
                .child(
                    div()
                        .text_color(palette.accent)
                        .child(if selected { "✓" } else { "" }),
                )
                .on_click(cx.listener(move |this, _, _, cx| {
                    this.breadcrumb_menu = None;
                    this.navigate(path);
                    cx.notify();
                }))
                .into_any_element()
        })
        .collect::<Vec<_>>();
        div()
            .id("breadcrumb-menu")
            .absolute()
            .top(px(44.0))
            .left(px(220.0))
            .w(px(230.0))
            .flex()
            .flex_col()
            .gap(px(1.0))
            .p(space(1))
            .rounded(px(RADIUS_MEDIUM))
            .border_1()
            .border_color(palette.line_strong)
            .bg(palette.card)
            .occlude()
            .children(rows)
            .into_any_element()
    }

    pub(in crate::root_view) fn toggle_agent_panel(&mut self, cx: &mut Context<Self>) {
        self.agent_panel_open = !self.agent_panel_open;
        cx.notify();
    }

    /// 从 Site Tree 打开页面：同一个 path 只保留一个 Tab，并激活它。
    pub(in crate::root_view) fn open_page_tab(
        &mut self,
        path: &str,
        title: impl Into<String>,
        cx: &mut Context<Self>,
    ) {
        let tab = PaneTab::page(path, title);
        self.open_tab(tab, cx);
    }

    /// 从 Outline / Site Tree 打开 issue 卡；同一门课同一张卡只保留一个 Tab。
    pub(in crate::root_view) fn open_issue_tab(
        &mut self,
        course_id: &str,
        issue_id: &str,
        title: impl Into<String>,
        cx: &mut Context<Self>,
    ) {
        let tab = PaneTab::issue(course_id, issue_id, title);
        self.open_tab(tab, cx);
    }

    fn open_tab(&mut self, tab: PaneTab, cx: &mut Context<Self>) {
        self.state.open_tab(tab.clone());
        self.site_tree_search_focused = false;
        self.chat.context_dismissed = false;
        self.navigate(&tab.path);
        self.persist_current_workspace_state();
        cx.notify();
    }

    pub(in crate::root_view) fn activate_tab(&mut self, id: &str, cx: &mut Context<Self>) {
        let Some(tab) = self.tabs.iter().find(|tab| tab.id == id).cloned() else {
            return;
        };
        self.active_tab = Some(tab.id.clone());
        self.site_tree_search_focused = false;
        self.chat.context_dismissed = false;
        self.navigate(&tab.path);
        self.persist_current_workspace_state();
        cx.notify();
    }

    pub(in crate::root_view) fn close_pane_tab(&mut self, id: &str, cx: &mut Context<Self>) {
        let was_active = self.active_tab.as_deref() == Some(id);
        if !self.state.close_tab(id) {
            return;
        }
        if was_active {
            match self
                .active_tab
                .as_deref()
                .and_then(|active| self.tabs.iter().find(|tab| tab.id == active))
                .map(|tab| tab.path.clone())
            {
                Some(path) => self.navigate(&path),
                None => self.navigate("/workspace"),
            }
        }
        self.persist_current_workspace_state();
        cx.notify();
    }

    /// 当前 active Tab 若是 issue 卡，返回课程 id 与 issue id。
    pub(in crate::root_view) fn clear_pane_notice(&mut self, cx: &mut Context<Self>) {
        self.pane_notice = None;
        cx.notify();
    }

    pub(in crate::root_view) fn active_issue_tab(&self) -> Option<(&str, &str)> {
        let active = self.active_tab.as_deref()?;
        let tab = self.tabs.iter().find(|tab| tab.id == active)?;
        let issue_id = tab.issue_id.as_deref()?;
        let course_id = tab
            .path
            .strip_prefix("/courses/")
            .and_then(|rest| rest.strip_suffix("/learn"))?;
        Some((course_id, issue_id))
    }

    pub(in crate::root_view) fn persist_site_tree_scroll(&mut self, cx: &mut Context<Self>) {
        self.persist_current_workspace_state();
        cx.notify();
    }

    pub(in crate::root_view) fn persist_workspace_layout(&mut self, cx: &mut Context<Self>) {
        self.persist_current_workspace_state();
        cx.notify();
    }

    fn persist_current_workspace_state(&self) {
        if let Some(workspace_id) = self.workspaces.current_id() {
            self.persist_workspace_state(workspace_id);
        }
    }

    fn persist_workspace_state(&self, workspace_id: &str) {
        let entry = crate::workspace_state::WorkspaceEntry {
            tabs: self
                .tabs
                .iter()
                .map(|tab| crate::workspace_state::PersistedTab {
                    id: tab.id.clone(),
                    title: tab.title.clone(),
                    path: tab.path.clone(),
                    issue_id: tab.issue_id.clone(),
                })
                .collect(),
            active_tab: self.active_tab.clone(),
            site_tree_events_open: self.site_tree_events_open,
            site_tree_courses_open: self.site_tree_courses_open,
            site_tree_query: self.site_tree_query.clone(),
            right_panel_width: self.right_panel_width,
            agent_panel_width: self.agent_panel_width,
            site_tree_course_open: self.site_tree_course_open.clone(),
            site_tree_scroll_y: self.site_tree_scroll.offset().y.as_f32(),
        };
        crate::workspace_state::save_entry(workspace_id, entry);
    }

    fn restore_workspace_state(&mut self, cx: &mut Context<Self>) {
        let Some(workspace_id) = self.workspaces.current_id().map(str::to_string) else {
            return;
        };
        let Some(entry) = crate::workspace_state::entry(&workspace_id) else {
            return;
        };
        self.site_tree_events_open = entry.site_tree_events_open;
        self.site_tree_courses_open = entry.site_tree_courses_open;
        self.site_tree_query = entry.site_tree_query;
        self.right_panel_width = entry.right_panel_width;
        self.agent_panel_width = entry.agent_panel_width;
        self.site_tree_course_open = entry.site_tree_course_open;
        self.site_tree_scroll = ScrollHandle::new();
        self.site_tree_scroll_restore = Some(entry.site_tree_scroll_y);
        let stored_tab_count = entry.tabs.len();
        self.tabs = entry
            .tabs
            .into_iter()
            .filter(|tab| {
                matches!(
                    self.registry.select(&tab.path),
                    crate::routing::RouteSelection::Match(_)
                )
            })
            .map(|tab| PaneTab {
                id: tab.id,
                title: tab.title,
                path: tab.path,
                issue_id: tab.issue_id,
            })
            .collect();
        if stored_tab_count > self.tabs.len() {
            self.pane_notice = Some(format!(
                "{} 个失效标签已清理",
                stored_tab_count - self.tabs.len()
            ));
        }
        self.active_tab = entry
            .active_tab
            .filter(|active| self.tabs.iter().any(|tab| &tab.id == active))
            .or_else(|| self.tabs.first().map(|tab| tab.id.clone()));
        if let Some(path) = self
            .active_tab
            .as_deref()
            .and_then(|active| self.tabs.iter().find(|tab| tab.id == active))
            .map(|tab| tab.path.clone())
        {
            self.navigate(&path);
        }
        cx.notify();
    }

    pub(in crate::root_view) fn load_course_enrollments(&mut self, cx: &mut Context<Self>) {
        let ids = self
            .courses
            .items()
            .iter()
            .take(20)
            .filter(|course| !self.course_enrollments.contains_key(&course.id))
            .map(|course| course.id.clone())
            .collect::<Vec<_>>();
        if ids.is_empty() {
            return;
        }
        let api = self.courses.api_handle();
        let token = self.session_token();
        let task = cx.background_executor().spawn(async move {
            let mut statuses = std::collections::BTreeMap::new();
            for id in ids {
                // 查询失败不落 None：未知不能当成“未报名”，否则会误导学员。
                if let Ok(status) = api.get_my_enrollment_status(token.as_deref(), &id) {
                    statuses.insert(id, status);
                }
            }
            statuses
        });
        cx.spawn(async move |this, cx| {
            let statuses = task.await;
            let _ = this.update(cx, |this, cx| {
                this.course_enrollments.extend(statuses);
                cx.notify();
            });
        })
        .detach();
    }

    /// Site Tree 的数据按需加载；只有进入已登录工作区后才调用。
    pub(in crate::root_view) fn ensure_navigation_data(&mut self, cx: &mut Context<Self>) {
        if !self.events_started {
            self.start_events_load(cx, true);
        }
        if !self.courses_started {
            self.start_courses_load(cx, true);
        }
    }

    pub(in crate::root_view) fn toggle_site_tree_course(
        &mut self,
        course_id: &str,
        cx: &mut Context<Self>,
    ) {
        if self.site_tree_course_open.as_deref() == Some(course_id) {
            self.site_tree_course_open = None;
        } else {
            self.site_tree_course_open = Some(course_id.to_string());
            if self
                .content
                .content()
                .is_none_or(|content| content.course_id != course_id)
            {
                self.start_content_load(cx, course_id.to_string());
            }
        }
        cx.notify();
    }

    pub(in crate::root_view) fn toggle_site_tree_section(
        &mut self,
        section: SiteTreeSection,
        cx: &mut Context<Self>,
    ) {
        match section {
            SiteTreeSection::Events => {
                self.site_tree_events_open = !self.site_tree_events_open;
                if self.site_tree_events_open && !self.events_started {
                    self.start_events_load(cx, true);
                }
            }
            SiteTreeSection::Courses => {
                self.site_tree_courses_open = !self.site_tree_courses_open;
                if self.site_tree_courses_open {
                    if !self.courses_started {
                        self.start_courses_load(cx, true);
                    }
                    self.load_course_enrollments(cx);
                }
            }
        }
        self.persist_current_workspace_state();
        cx.notify();
    }

    /// 打开指定右栏 panel；已打开且是同一个 panel 时收起（Zed 图标语义）。
    pub(in crate::root_view) fn toggle_right_panel(
        &mut self,
        panel: RightPanel,
        cx: &mut Context<Self>,
    ) {
        let (panel, open) =
            state::toggled_right_panel(self.right_panel, self.right_panel_open, panel);
        self.right_panel = panel;
        self.right_panel_open = open;
        cx.notify();
    }

    pub(in crate::root_view) fn is_agent_panel_shortcut(keystroke: &Keystroke) -> bool {
        keystroke.key.eq_ignore_ascii_case("j")
            && !keystroke.modifiers.shift
            && (keystroke.modifiers.platform || keystroke.modifiers.control)
    }

    pub(in crate::root_view) fn handle_shell_key(
        &mut self,
        event: &KeyDownEvent,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if Self::is_agent_panel_shortcut(&event.keystroke) {
            self.toggle_agent_panel(cx);
            return;
        }
        if (event.keystroke.modifiers.platform || event.keystroke.modifiers.control)
            && event.keystroke.key.eq_ignore_ascii_case("b")
        {
            let panel = if event.keystroke.modifiers.shift {
                RightPanel::Outline
            } else {
                RightPanel::SiteTree
            };
            self.toggle_right_panel(panel, cx);
            return;
        }
        if self.site_tree_search_focused
            && self.right_panel_open
            && self.right_panel == RightPanel::SiteTree
        {
            match event.keystroke.key.as_str() {
                "escape" => self.site_tree_search_focused = false,
                "enter" => self.site_tree_search_focused = false,
                "backspace" => {
                    self.site_tree_query.pop();
                }
                _ => {
                    if let Some(text) = event.keystroke.key_char.as_deref() {
                        if !event.keystroke.modifiers.modified() && !text.is_empty() {
                            self.site_tree_query.push_str(text);
                        }
                    }
                }
            }
            if !self.site_tree_query.trim().is_empty() {
                self.ensure_navigation_data(cx);
            }
            cx.notify();
            return;
        }
        if self.agent_registry_search_focused
            && self
                .current
                .as_ref()
                .is_some_and(|route_match| route_match.route.id == "app.agents")
        {
            match event.keystroke.key.as_str() {
                "escape" | "enter" => self.agent_registry_search_focused = false,
                "backspace" => {
                    self.agent_registry_query.pop();
                }
                _ => {
                    if let Some(text) = event.keystroke.key_char.as_deref() {
                        if !event.keystroke.modifiers.modified() && !text.is_empty() {
                            self.agent_registry_query.push_str(text);
                        }
                    }
                }
            }
            cx.notify();
            return;
        }
        if Self::is_settings_shortcut(&event.keystroke) {
            self.open_settings_window(cx);
            return;
        }
        // 审批卡的键盘等价路径（显式组合键，避免与输入 y/n 冲突）。
        if event.keystroke.modifiers.control
            && event.keystroke.modifiers.shift
            && self
                .current
                .as_ref()
                .is_some_and(|route_match| route_match.route.id == "courses.learning")
        {
            match event.keystroke.key.as_str() {
                "y" => {
                    self.respond_chat_permission(true, cx);
                    return;
                }
                "n" => {
                    self.respond_chat_permission(false, cx);
                    return;
                }
                _ => {}
            }
        }
        if self.chat.focused {
            match event.keystroke.key.as_str() {
                "enter" => self.send_chat(cx),
                "backspace" => {
                    self.chat.input.pop();
                }
                _ => {
                    if let Some(text) = event.keystroke.key_char.as_deref() {
                        if !event.keystroke.modifiers.modified() && !text.is_empty() {
                            self.chat.input.push_str(text);
                        }
                    }
                }
            }
            let focus = self.ensure_key_focus(cx);
            _window.focus(&focus, cx);
            cx.notify();
            return;
        }
        if event.keystroke.key != "enter" {
            return;
        }
        let Some(route_match) = self.current.clone() else {
            return;
        };
        if route_match.route.id != "courses.detail" {
            return;
        }
        let Some(course_id) = route_match.params.get("id").cloned() else {
            return;
        };
        let enrolled = self
            .course_detail
            .detail()
            .and_then(|detail| detail.enrollment_status.as_deref())
            == Some("confirmed");
        if enrolled {
            self.navigate_to_learning(&course_id, cx);
            cx.notify();
        }
    }

    pub(in crate::root_view) fn start_enrollments_load(&mut self, cx: &mut Context<Self>) {
        self.enrollments_started = true;
        self.enrollments_state = EnrollmentsListState::Loading;
        let api = Arc::clone(&self.enrollments_api);
        let token = self.session_token();
        let epoch = self.workspaces.epoch();
        let task = cx
            .background_executor()
            .spawn(async move { api.my_enrollments(token.as_deref()) });
        cx.spawn(async move |this, cx| {
            let result = task.await;
            let _ = this.update(cx, |this, cx| {
                if !this.workspaces.is_current_epoch(epoch) {
                    return;
                }
                match result {
                    Ok(rows) => {
                        this.enrollments_rows = rows;
                        this.enrollments_state = if this.enrollments_rows.is_empty() {
                            EnrollmentsListState::Empty
                        } else {
                            EnrollmentsListState::Ready
                        };
                    }
                    Err(error) if error.is_unauthorized() => this.force_sign_out(cx),
                    Err(error) => {
                        this.enrollments_state = EnrollmentsListState::Failed(error.diagnostic());
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    pub(in crate::root_view) fn start_detail_load(
        &mut self,
        cx: &mut Context<Self>,
        event_id: String,
    ) {
        self.detail.begin_load(&event_id);
        self.detail_started = true;
        self.selected_tier = None;
        self.age_confirmed = false;
        self.enrollment_error = None;
        self.enrolling = false;
        let api = self.detail.api_handle();
        let token = self.session_token();
        let epoch = self.workspaces.epoch();
        let task = cx.background_executor().spawn(async move {
            let detail = api.get_event(token.as_deref(), &event_id)?;
            let enrollment = api
                .get_my_enrollment(token.as_deref(), &event_id)
                .unwrap_or(None);
            Ok::<_, cgc_events::list::EventsError>((detail, enrollment))
        });
        cx.spawn(async move |this, cx| {
            let result = task.await;
            let _ = this.update(cx, |this, cx| {
                if !this.workspaces.is_current_epoch(epoch) {
                    return;
                }
                match result {
                    Ok((detail, enrollment)) => {
                        this.detail.adopt(detail);
                        this.detail.adopt_enrollment(enrollment.clone());
                        if std::env::var("CGC_AUTO_PAY").as_deref() == Ok("1")
                            && enrollment
                                .as_ref()
                                .is_some_and(|enrollment| enrollment.status == "payment_pending")
                        {
                            this.start_payment("wechat_native", cx);
                        }
                    }
                    Err(error) if error.is_unauthorized() => this.force_sign_out(cx),
                    Err(error) => this.detail.fail(&error),
                }
                cx.notify();
            });
        })
        .detach();
    }

    pub(in crate::root_view) fn start_payment(&mut self, provider: &str, cx: &mut Context<Self>) {
        if matches!(
            self.payment,
            PaymentViewState::Creating | PaymentViewState::Qr { .. } | PaymentViewState::Paid
        ) {
            return;
        }
        let Some(enrollment) = self.detail.enrollment().cloned() else {
            return;
        };
        if enrollment.status != "payment_pending" {
            return;
        }
        let deposit = self
            .detail
            .detail()
            .map(|detail| detail.deposit_enabled)
            .unwrap_or(false);
        if deposit && !self.deposit_consent {
            self.payment = PaymentViewState::Failed("deposit_consent".to_string());
            cx.notify();
            return;
        }
        self.payment = PaymentViewState::Creating;
        let api = Arc::clone(&self.orders);
        let token = self.session_token();
        let enrollment_id = enrollment.id.clone();
        let provider = provider.to_string();
        self.payment_generation = self.payment_generation.saturating_add(1);
        let generation = self.payment_generation;
        let task = cx.background_executor().spawn(async move {
            api.create_order(token.as_deref(), &enrollment_id, &provider, deposit)
        });
        cx.spawn(async move |this, cx| {
            let result = task.await;
            let _ = this.update(cx, |this, cx| {
                if this.payment_generation != generation {
                    return;
                }
                match result {
                    Ok(order) => {
                        let url = order.credential.as_deref().and_then(qr_code_url);
                        match url {
                            Some(url) => {
                                this.payment = PaymentViewState::Qr {
                                    url,
                                    order_id: order.id.clone(),
                                    expire_at: order.expire_at.clone(),
                                };
                                let enrollment_id = this
                                    .detail
                                    .enrollment()
                                    .map(|enrollment| enrollment.id.clone())
                                    .unwrap_or_default();
                                let target = this.detail.detail().map(|detail| detail.id.clone());
                                this.poll_payment(order.id, generation, enrollment_id, target, cx);
                            }
                            None => {
                                this.payment =
                                    PaymentViewState::Failed("unsupported_credential".to_string());
                            }
                        }
                    }
                    Err(error) if error.is_unauthorized() => this.force_sign_out(cx),
                    Err(error) => {
                        this.payment =
                            PaymentViewState::Failed(error.code().unwrap_or("generic").to_string());
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    pub(in crate::root_view) fn poll_payment(
        &mut self,
        order_id: String,
        generation: u64,
        enrollment_id: String,
        target_event_id: Option<String>,
        cx: &mut Context<Self>,
    ) {
        let api = Arc::clone(&self.orders);
        let token = self.session_token();
        let bus = Arc::clone(&self.events_bus);
        cx.spawn(async move |this, cx| loop {
            cx.background_executor().timer(Duration::from_secs(2)).await;
            let poll_api = Arc::clone(&api);
            let poll_token = token.clone();
            let poll_id = order_id.clone();
            let result = cx
                .background_executor()
                .spawn(async move { poll_api.order_status(poll_token.as_deref(), &poll_id) })
                .await;
            let keep = this
                .update(cx, |this, cx| {
                    if this.payment_generation != generation {
                        return false;
                    }
                    match result {
                        Ok(order) if order.status == "paid" => {
                            this.payment = PaymentViewState::Paid;
                            (bus).publish(AppEvent::EnrollmentChanged {
                                enrollment_id: enrollment_id.clone(),
                                event_id: target_event_id.clone(),
                                course_id: None,
                            });
                            this.events_started = false;
                            this.events.reset();
                            this.course_detail_started = false;
                            this.course_detail.reset();
                            this.refresh_enrollment(cx);
                            cx.notify();
                            false
                        }
                        Ok(order) if is_terminal_status(&order.status) => {
                            this.payment = PaymentViewState::Terminal(order.status.clone());
                            cx.notify();
                            false
                        }
                        Ok(_) => true,
                        Err(error) if error.is_unauthorized() => {
                            this.force_sign_out(cx);
                            false
                        }
                        Err(error) => {
                            this.payment = PaymentViewState::Failed(error.diagnostic());
                            cx.notify();
                            false
                        }
                    }
                })
                .unwrap_or(false);
            if !keep {
                break;
            }
        })
        .detach();
    }

    pub(in crate::root_view) fn close_payment(&mut self, cx: &mut Context<Self>) {
        self.payment = PaymentViewState::Idle;
        self.payment_generation = self.payment_generation.saturating_add(1);
        cx.notify();
    }

    pub(in crate::root_view) fn cancel_enrollment_action(&mut self, cx: &mut Context<Self>) {
        let Some(enrollment) = self.detail.enrollment().cloned() else {
            return;
        };
        let api = self.detail.api_handle();
        let token = self.session_token();
        let bus = Arc::clone(&self.events_bus);
        let target = self.detail.detail().map(|detail| detail.id.clone());
        let enrollment_id = enrollment.id.clone();
        let task = cx
            .background_executor()
            .spawn(async move { api.cancel_enrollment(token.as_deref(), &enrollment_id) });
        cx.spawn(async move |this, cx| {
            let result = task.await;
            let _ = this.update(cx, |this, cx| {
                match result {
                    Ok(enrollment) => {
                        bus.publish(AppEvent::EnrollmentChanged {
                            enrollment_id: enrollment.id.clone(),
                            event_id: target.clone(),
                            course_id: None,
                        });
                        this.detail.adopt_enrollment(Some(enrollment));
                        this.payment = PaymentViewState::Idle;
                        this.payment_generation = this.payment_generation.saturating_add(1);
                        this.enrollment_error = None;
                    }
                    Err(error) if error.is_unauthorized() => this.force_sign_out(cx),
                    Err(error) if error.is_unauthorized() => this.force_sign_out(cx),
                    Err(_) => {
                        this.enrollment_error = Some("generic".to_string());
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    pub(in crate::root_view) fn refresh_enrollment(&mut self, cx: &mut Context<Self>) {
        let Some(event_id) = self
            .current
            .as_ref()
            .and_then(|route_match| route_match.params.get("id"))
            .cloned()
        else {
            return;
        };
        let api = self.detail.api_handle();
        let token = self.session_token();
        let task = cx
            .background_executor()
            .spawn(async move { api.get_my_enrollment(token.as_deref(), &event_id) });
        cx.spawn(async move |this, cx| {
            let result = task.await;
            let _ = this.update(cx, |this, cx| {
                if let Ok(enrollment) = result {
                    this.detail.adopt_enrollment(enrollment);
                    this.enrollment_error = None;
                    cx.notify();
                }
            });
        })
        .detach();
    }

    pub(in crate::root_view) fn submit_enrollment(&mut self, cx: &mut Context<Self>) {
        if self.enrolling {
            return;
        }
        let Some(detail) = self.detail.detail().cloned() else {
            return;
        };
        let Some(user_id) = self
            .session
            .signed_in()
            .map(|session| session.user_id.clone())
        else {
            return;
        };
        if detail.pricing_enabled
            && !detail.available_price_tiers.is_empty()
            && self.selected_tier.is_none()
        {
            self.enrollment_error = Some("tier_required".to_string());
            cx.notify();
            return;
        }
        if detail.min_age.is_some() && !self.age_confirmed {
            self.enrollment_error = Some("age_required".to_string());
            cx.notify();
            return;
        }
        self.enrolling = true;
        self.enrollment_error = None;
        let request = EnrollmentRequest {
            event_id: detail.id.clone(),
            user_id,
            tier_id: self.selected_tier.clone(),
            age_confirmed: self.age_confirmed,
        };
        let api = self.detail.api_handle();
        let token = self.session_token();
        let task = cx
            .background_executor()
            .spawn(async move { api.create_enrollment(token.as_deref(), &request) });
        cx.spawn(async move |this, cx| {
            let result = task.await;
            let _ = this.update(cx, |this, cx| {
                this.enrolling = false;
                match result {
                    Ok(enrollment) => {
                        this.detail.adopt_enrollment(Some(enrollment));
                        this.enrollment_error = None;
                    }
                    Err(cgc_events::list::EventsError::Domain { code, .. }) => {
                        let suffix = enrollment_error_key(&code).to_string();
                        this.enrollment_error = Some(suffix);
                        if code == "enrollment_duplicate_active" {
                            this.refresh_enrollment(cx);
                        }
                    }
                    Err(_) => {
                        this.enrollment_error = Some("generic".to_string());
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    pub(in crate::root_view) fn retry_detail(&mut self, cx: &mut Context<Self>) {
        self.detail.retry_ready();
        self.detail_started = false;
        if let Some(event_id) = self
            .current
            .as_ref()
            .and_then(|route_match| route_match.params.get("id"))
            .cloned()
        {
            self.start_detail_load(cx, event_id);
        }
        cx.notify();
    }

    pub(in crate::root_view) fn start_events_load(&mut self, cx: &mut Context<Self>, first: bool) {
        if first {
            self.events.begin_first_load();
        } else {
            self.events.begin_load_more();
        }
        self.events_started = true;

        let api = self.events.api_handle();
        let token = self.session_token();
        let filter = self.events.filter();
        let after = if first {
            None
        } else {
            self.events.next_cursor().map(str::to_string)
        };
        let scope = self.workspaces.scope();
        let task = cx.background_executor().spawn(async move {
            api.list_events(
                token.as_deref(),
                scope.as_ref(),
                filter,
                after.as_deref(),
                10,
            )
        });

        cx.spawn(async move |this, cx| {
            let result = task.await;
            let _ = this.update(cx, |this, cx| {
                match result {
                    Ok(page) => this.events.adopt_page(page),
                    Err(error) if error.is_unauthorized() => this.force_sign_out(cx),
                    Err(error) => this.events.fail(&error),
                }
                cx.notify();
            });
        })
        .detach();
    }

    pub(in crate::root_view) fn select_events_filter(
        &mut self,
        filter: StatusFilter,
        cx: &mut Context<Self>,
    ) {
        self.events.set_filter(filter);
        self.events.retry_ready();
        self.start_events_load(cx, true);
    }

    pub(in crate::root_view) fn retry_events(&mut self, cx: &mut Context<Self>) {
        self.events.retry_ready();
        self.start_events_load(cx, true);
    }

    pub(in crate::root_view) fn open_agent_registry(&mut self, cx: &mut Context<Self>) {
        let title = translate(self.language, Key::AgentRegistryTitle).to_string();
        self.agent_registry_search_focused = false;
        self.open_page_tab("/agents", title, cx);
        if !self.agent_registry_started {
            self.start_agent_registry_load(cx);
        }
    }

    pub(in crate::root_view) fn set_agent_registry_filter(
        &mut self,
        filter: AgentRegistryFilter,
        cx: &mut Context<Self>,
    ) {
        self.agent_registry_filter = filter;
        cx.notify();
    }

    pub(in crate::root_view) fn start_agent_registry_load(&mut self, cx: &mut Context<Self>) {
        if self.agent_registry_loading {
            return;
        }
        self.agent_registry_started = true;
        self.agent_registry_loading = true;
        self.agent_registry_error = None;
        let task = cx.background_executor().spawn(async move {
            let registry = Registry::builtin().map_err(|error| error.diagnostic())?;
            let probe = SystemProbe;
            let installed = load_installed_agents();
            let mut rows = detect_all(&registry, &probe);
            for row in &mut rows {
                if let Some(version) = installed.get(&row.entry.id) {
                    row.status = AgentStatus::Ready {
                        version: version.clone(),
                    };
                }
            }
            Ok::<_, String>(rows)
        });
        cx.spawn(async move |this, cx| {
            let result = task.await;
            let _ = this.update(cx, |this, cx| {
                this.agent_registry_loading = false;
                match result {
                    Ok(rows) => this.agent_registry_rows = rows,
                    Err(error) => this.agent_registry_error = Some(error),
                }
                cx.notify();
            });
        })
        .detach();
    }

    pub(in crate::root_view) fn install_agent(&mut self, id: &str, cx: &mut Context<Self>) {
        if self.agent_installing.as_deref() == Some(id) {
            return;
        }
        let Some(entry) = self
            .agent_registry_rows
            .iter()
            .find(|row| row.entry.id == id)
            .map(|row| row.entry.clone())
        else {
            return;
        };
        self.agent_installing = Some(id.to_string());
        self.agent_install_stage = Some("准备运行环境".to_string());
        self.agent_install_error = None;
        let installed_id = id.to_string();
        let installed_version = entry.minimum_version.clone();
        let is_npx = matches!(
            entry.distribution,
            cgc_platform::registry::manifest::Distribution::Npx { .. }
        );
        let task = cx.background_executor().spawn(async move {
            let manager = NodeRuntimeManager::default_manager();
            let mut node = manager.installed_runtime();
            if node.is_none() && is_npx {
                manager
                    .install(&HttpDownloader)
                    .map_err(|error| error.to_string())?;
                node = manager.installed_runtime();
            }
            install_entry(&entry, node.as_ref(), &SystemRunner).map_err(|error| error.to_string())
        });
        cx.spawn(async move |this, cx| {
            let result = task.await;
            let _ = this.update(cx, |this, cx| {
                this.agent_installing = None;
                this.agent_install_stage = None;
                match result {
                    Ok(result) => {
                        this.agent_install_error = None;
                        // 安装命令已经验证过固定版本；直接标记 Ready，避免再用系统
                        // node/npx 探测把托管 runtime 已安装的 agent 误判为不可用。
                        save_installed_agent(
                            &installed_id,
                            &result
                                .version
                                .clone()
                                .unwrap_or_else(|| installed_version.clone()),
                        );
                        if let Some(row) = this
                            .agent_registry_rows
                            .iter_mut()
                            .find(|row| row.entry.id == installed_id)
                        {
                            row.status = AgentStatus::Ready {
                                version: result
                                    .version
                                    .clone()
                                    .unwrap_or_else(|| installed_version.clone()),
                            };
                        }
                    }
                    Err(error) => this.agent_install_error = Some(error.to_string()),
                }
                cx.notify();
            });
        })
        .detach();
    }

    pub(in crate::root_view) fn toggle_chat_agent_menu(&mut self, cx: &mut Context<Self>) {
        self.chat.agent_menu_open = !self.chat.agent_menu_open;
        if self.chat.agent_menu_open && !self.agent_registry_started {
            self.start_agent_registry_load(cx);
        }
        cx.notify();
    }

    pub(in crate::root_view) fn select_chat_agent(
        &mut self,
        id: String,
        display_name: String,
        cx: &mut Context<Self>,
    ) {
        self.site_tree_search_focused = false;
        save_selected_agent(&id);
        self.chat.selected_agent = Some(id);
        self.chat.agent = display_name;
        self.chat.agent_menu_open = false;
        self.chat.phase = ChatPhase::Idle;
        self.chat.host = None;
        self.chat.lease = None;
        self.chat.messages.clear();
        self.chat.session_id = None;
        self.chat.restore_id = None;
        self.chat.configs.clear();
        self.chat.configs_applied = false;
        self.chat.auto_prompted = false;
        self.start_chat(cx);
    }

    pub(in crate::root_view) fn dismiss_chat_context(&mut self, cx: &mut Context<Self>) {
        self.chat.context_dismissed = true;
        cx.notify();
    }

    /// 发消息时给 agent 的当前卡上下文（用户移除芯片后不再注入）。
    fn active_tab_context_note(&self) -> Option<String> {
        if self.chat.context_dismissed {
            return None;
        }
        let active = self.active_tab.as_deref()?;
        let tab = self.tabs.iter().find(|tab| tab.id == active)?;
        tab.issue_id.as_ref()?;
        Some(format!(
            "[当前学习上下文] 正在阅读：{} ({})。回答时优先结合这张 issue 卡。",
            tab.title, tab.id
        ))
    }

    pub(in crate::root_view) fn ensure_key_focus(&mut self, cx: &mut Context<Self>) -> FocusHandle {
        self.key_focus
            .get_or_insert_with(|| cx.focus_handle())
            .clone()
    }

    pub(in crate::root_view) fn submit_login(&mut self, cx: &mut Context<Self>) {
        if self.signing_in {
            return;
        }
        let login = self.login_email.trim().to_string();
        let password = self.login_password.clone();
        if login.is_empty() || password.is_empty() {
            self.login_error = Some(LoginError::Invalid);
            cx.notify();
            return;
        }

        self.signing_in = true;
        self.login_error = None;
        self.session.begin_sign_in();
        cx.notify();

        let api = self.session.api_handle();
        let task = cx
            .background_executor()
            .spawn(async move { api.sign_in(&login, &password) });

        cx.spawn(async move |this, cx| {
            let result = task.await;
            let _ = this.update(cx, |this, cx| {
                this.finish_login(result);
                cx.notify();
            });
        })
        .detach();
    }

    pub(in crate::root_view) fn finish_login(
        &mut self,
        result: Result<SignedInSession, AuthError>,
    ) {
        self.signing_in = false;
        match result {
            Ok(session) => {
                if self.session.adopt_signed_in(session).is_err() {
                    self.login_error = Some(LoginError::Network);
                }
                self.reset_events();
                self.workspaces.reset();
                self.workspaces_started = false;
                self.session_checked = false;
                self.login_password.clear();
                self.navigate("/workspace");
            }
            Err(error) => {
                self.session.fail_sign_in(&error);
                self.login_error = Some(LoginError::from_auth_error(&error));
            }
        }
    }

    pub(in crate::root_view) fn sign_out(&mut self, cx: &mut Context<Self>) {
        let token = self.session.sign_out_local();
        if let Some(token) = token {
            let api = self.session.api_handle();
            cx.background_executor()
                .spawn(async move {
                    let _ = api.revoke(&token);
                })
                .detach();
        }
        self.account_menu_open = false;
        self.workspace_menu_open = false;
        self.workspaces.reset();
        self.workspaces_started = false;
        self.reset_workspace_data(cx);
        self.login_email.clear();
        self.login_password.clear();
        self.login_error = None;
        self.switch_login_mode(LoginMode::Password);
        self.ensure_wechat_login(cx);
        cx.notify();
    }

    pub(in crate::root_view) fn handle_key(
        &mut self,
        event: &KeyDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        match event.keystroke.key.as_str() {
            "tab" => self.cycle_login_field(),
            "enter" => match self.login_mode {
                LoginMode::Password => self.submit_login(cx),
                LoginMode::Reset => {
                    if self.reset_sent {
                        self.submit_reset_password(cx)
                    } else {
                        self.request_password_reset(cx)
                    }
                }
            },
            "backspace" => {
                let buffer = self.field_mut();
                buffer.pop();
            }
            _ => {
                if let Some(text) = event.keystroke.key_char.as_deref() {
                    if !event.keystroke.modifiers.modified() && !text.is_empty() {
                        self.field_mut().push_str(text);
                    }
                }
            }
        }
        let focus = self.ensure_key_focus(cx);
        window.focus(&focus, cx);
        cx.notify();
    }

    pub(in crate::root_view) fn field_mut(&mut self) -> &mut String {
        match self.focused {
            LoginField::Email => &mut self.login_email,
            LoginField::Password => &mut self.login_password,
            LoginField::ResetToken => &mut self.login_reset_token,
            LoginField::NewPassword => &mut self.login_new_password,
        }
    }

    pub(in crate::root_view) fn login_fields(&self) -> Vec<LoginField> {
        match self.login_mode {
            LoginMode::Password => vec![LoginField::Email, LoginField::Password],
            LoginMode::Reset => {
                if self.reset_sent {
                    vec![LoginField::ResetToken, LoginField::NewPassword]
                } else {
                    vec![LoginField::Email]
                }
            }
        }
    }

    pub(in crate::root_view) fn cycle_login_field(&mut self) {
        let fields = self.login_fields();
        let index = fields
            .iter()
            .position(|field| *field == self.focused)
            .unwrap_or(0);
        self.focused = fields[(index + 1) % fields.len()];
    }

    pub(in crate::root_view) fn switch_login_mode(&mut self, mode: LoginMode) {
        self.login_mode = mode;
        self.login_error = None;
        self.login_notice = None;
        self.reset_sent = false;
        // 离开 Password 视图即停止轮询与倒计时；切回时由 render 重新出码。
        self.wechat_generation += 1;
        self.wechat_login = WechatLoginView::Idle;
        self.focused = match mode {
            LoginMode::Password => LoginField::Email,
            LoginMode::Reset => LoginField::Email,
        };
    }

    /// 自动出码条件：密码登录视图且当前没有进行中的扫码。
    pub(in crate::root_view) fn should_auto_start_wechat(&self) -> bool {
        self.login_mode == LoginMode::Password && matches!(self.wechat_login, WechatLoginView::Idle)
    }

    /// 登录视图（Password）挂载时调用；fake 模式下不自动出码。
    pub fn ensure_wechat_login(&mut self, cx: &mut Context<Self>) {
        if self.should_auto_start_wechat() {
            self.start_wechat_login(cx);
        }
    }

    pub(in crate::root_view) fn back_to_password_login(&mut self, cx: &mut Context<Self>) {
        self.switch_login_mode(LoginMode::Password);
        self.ensure_wechat_login(cx);
        cx.notify();
    }

    pub(in crate::root_view) fn start_wechat_login(&mut self, cx: &mut Context<Self>) {
        if self.signing_in {
            return;
        }
        self.wechat_generation += 1;
        let generation = self.wechat_generation;
        self.wechat_login = WechatLoginView::Starting;
        self.login_error = None;
        let api = self.session.api_handle();
        cx.spawn(async move |this, cx| {
            let result = cx
                .background_executor()
                .spawn(async move { api.start_wechat_login() })
                .await;
            let _ = this.update(cx, |this, cx| {
                if generation != this.wechat_generation {
                    return;
                }
                match result {
                    Ok(start) => match start.launch_url {
                        Some(launch_url) => {
                            let expires_at = start.expires_at.clone();
                            let remaining_seconds = remaining_seconds(expires_at.as_deref());
                            this.wechat_login = WechatLoginView::Ready {
                                launch_url,
                                approved: false,
                                expires_at,
                                remaining_seconds,
                            };
                            this.spawn_wechat_poller(
                                cx,
                                generation,
                                start.request_id,
                                start.proof,
                                start.poll_interval_seconds,
                            );
                            this.spawn_wechat_countdown(cx, generation);
                        }
                        None => {
                            this.wechat_login = WechatLoginView::Failed(LoginError::Wechat);
                        }
                    },
                    Err(error) => {
                        this.wechat_login =
                            WechatLoginView::Failed(LoginError::from_auth_error(&error));
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    pub(in crate::root_view) fn spawn_wechat_poller(
        &mut self,
        cx: &mut Context<Self>,
        generation: u64,
        request_id: String,
        proof: String,
        interval_seconds: i64,
    ) {
        let api = self.session.api_handle();
        let interval = Duration::from_secs(interval_seconds.clamp(1, 10) as u64);
        cx.spawn(async move |this, cx| loop {
            cx.background_executor().timer(interval).await;
            let poll_api = api.clone();
            let poll_request = request_id.clone();
            let poll_proof = proof.clone();
            let result = cx
                .background_executor()
                .spawn(async move { poll_api.wechat_login_status(&poll_request, &poll_proof) })
                .await;
            let next_request = request_id.clone();
            let next_proof = proof.clone();
            let keep = this
                .update(cx, |this, cx| {
                    if generation != this.wechat_generation
                        || this.login_mode != LoginMode::Password
                    {
                        return false;
                    }
                    match result {
                        Ok(poll) => match poll.status {
                            WechatLoginStatus::Pending => true,
                            WechatLoginStatus::Approved => {
                                this.consume_wechat_login(cx, generation, next_request, next_proof);
                                false
                            }
                            WechatLoginStatus::Consumed => false,
                            WechatLoginStatus::Cancelled | WechatLoginStatus::Expired => {
                                this.wechat_login = WechatLoginView::Expired;
                                cx.notify();
                                false
                            }
                        },
                        Err(error) => {
                            this.wechat_login =
                                WechatLoginView::Failed(LoginError::from_auth_error(&error));
                            cx.notify();
                            false
                        }
                    }
                })
                .unwrap_or(false);
            if !keep {
                break;
            }
        })
        .detach();
    }

    /// 每秒刷新二维码剩余有效期；归零即显示过期（不依赖下一次轮询）。
    pub(in crate::root_view) fn spawn_wechat_countdown(
        &mut self,
        cx: &mut Context<Self>,
        generation: u64,
    ) {
        cx.spawn(async move |this, cx| loop {
            cx.background_executor().timer(Duration::from_secs(1)).await;
            let keep = this
                .update(cx, |this, cx| {
                    if generation != this.wechat_generation
                        || this.login_mode != LoginMode::Password
                    {
                        return false;
                    }
                    let next = match &mut this.wechat_login {
                        WechatLoginView::Ready {
                            approved: false,
                            remaining_seconds,
                            ..
                        } => {
                            *remaining_seconds = (*remaining_seconds - 1).max(0);
                            Some(*remaining_seconds)
                        }
                        _ => None,
                    };
                    match next {
                        Some(seconds) if seconds > 0 => {
                            cx.notify();
                            true
                        }
                        Some(_) => {
                            this.wechat_login = WechatLoginView::Expired;
                            cx.notify();
                            false
                        }
                        None => false,
                    }
                })
                .unwrap_or(false);
            if !keep {
                break;
            }
        })
        .detach();
    }

    pub(in crate::root_view) fn consume_wechat_login(
        &mut self,
        cx: &mut Context<Self>,
        generation: u64,
        request_id: String,
        proof: String,
    ) {
        if let WechatLoginView::Ready { approved, .. } = &mut self.wechat_login {
            *approved = true;
        }
        self.signing_in = true;
        let api = self.session.api_handle();
        cx.spawn(async move |this, cx| {
            let result = cx
                .background_executor()
                .spawn(async move { api.consume_wechat_login(&request_id, &proof) })
                .await;
            let _ = this.update(cx, |this, cx| {
                if generation != this.wechat_generation {
                    return;
                }
                this.finish_login(result);
                cx.notify();
            });
        })
        .detach();
    }

    pub(in crate::root_view) fn request_password_reset(&mut self, cx: &mut Context<Self>) {
        let email = self.login_email.trim().to_string();
        if email.is_empty() || self.signing_in {
            return;
        }
        self.signing_in = true;
        self.login_error = None;
        let api = self.session.api_handle();
        let task = cx
            .background_executor()
            .spawn(async move { api.request_password_reset(&email) });
        cx.spawn(async move |this, cx| {
            let result = task.await;
            let _ = this.update(cx, |this, cx| {
                this.signing_in = false;
                match result {
                    Ok(true) => {
                        this.reset_sent = true;
                        this.login_notice = Some(Key::AppAuthResetSent);
                        this.focused = LoginField::ResetToken;
                    }
                    Ok(false) => this.login_error = Some(LoginError::Reset),
                    Err(error) => this.login_error = Some(LoginError::from_auth_error(&error)),
                }
                cx.notify();
            });
        })
        .detach();
    }

    pub(in crate::root_view) fn submit_reset_password(&mut self, cx: &mut Context<Self>) {
        let token = self.login_reset_token.trim().to_string();
        let password = self.login_new_password.clone();
        if token.is_empty() || password.len() < 8 || self.signing_in {
            self.login_error = Some(LoginError::Reset);
            return;
        }
        self.signing_in = true;
        self.login_error = None;
        let api = self.session.api_handle();
        let task = cx
            .background_executor()
            .spawn(async move { api.reset_password(&token, &password) });
        cx.spawn(async move |this, cx| {
            let result = task.await;
            let _ = this.update(cx, |this, cx| {
                this.signing_in = false;
                match result {
                    Ok(true) => {
                        this.back_to_password_login(cx);
                        this.login_notice = Some(Key::AppAuthResetSent);
                    }
                    Ok(false) => this.login_error = Some(LoginError::Reset),
                    Err(error) => this.login_error = Some(LoginError::from_auth_error(&error)),
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// 测试用：直接访问会话状态机（生产 UI 只通过按钮/异步回调驱动）。
    #[cfg(test)]
    pub(crate) fn session_mut(&mut self) -> &mut SessionService {
        &mut self.session
    }

    #[cfg(test)]
    pub(crate) fn login_error(&self) -> Option<LoginError> {
        self.login_error
    }
}

impl RootView {
    pub(in crate::root_view) fn revoke_device(&mut self, cx: &mut Context<Self>) {
        if self.revoking {
            return;
        }
        let Some(token) = self
            .session
            .signed_in()
            .map(|session| session.token.clone())
        else {
            return;
        };
        self.revoking = true;
        self.settings_error = None;
        let api = self.session.api_handle();
        let task = cx
            .background_executor()
            .spawn(async move { api.revoke(&token) });
        cx.spawn(async move |this, cx| {
            let result = task.await;
            let _ = this.update(cx, |this, cx| {
                this.revoking = false;
                match result {
                    Ok(()) => {
                        this.session.sign_out_local();
                        this.workspaces.reset();
                        this.workspaces_started = false;
                        this.reset_workspace_data(cx);
                        this.navigate("/");
                    }
                    Err(error) => {
                        this.settings_error = Some(error.diagnostic());
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }
}
