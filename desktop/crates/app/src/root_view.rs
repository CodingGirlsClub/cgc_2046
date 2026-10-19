//! 应用外壳：登录页 / 已登录壳（顶部 header + 内容 + 底部 status bar）。
//!
//! 布局参考 Zed（xerj 取证）：透明 titlebar 与红绿灯同排、右上角账户头像 + 下拉、
//! footer 只放图标（悬停 tooltip）。会话来自 `cgc_platform::session`：未登录时
//! 整个窗口显示登录页（guard），登录成功后进入壳；登出在头像下拉里（同 Zed 的
//! sign out）。网络调用放后台线程，结果回主线程刷新。

use gpui_kit::InteractiveElement;
use gpui_kit::*;

use std::sync::Arc;

use crate::chat_state::{
    clear_chat_pointer, load_chat_pointer, load_chat_pref, save_chat_pointer, save_chat_pref,
};
use crate::formula::render_markdown_with_math;
use crate::safe_markdown::sanitize_markdown;
use cgc_courses::catalog::{
    learning_context, CourseCatalogService, CourseDetailService, CourseSummary, CoursesApi,
    CoursesListState, FakeCoursesApi, HttpCoursesApi,
};
use cgc_courses::content::{CourseContentService, CourseContentState, MaterialKind};
use cgc_courses::projection::{LearningProjectionService, ProjectionState};
use cgc_events::detail::{EventDetail, EventDetailService, PriceMode};
use gpui_kit::component::text::TextView;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use cgc_events::enroll::{enrollment_error_key, EnrollmentRequest};
use cgc_events::enrollments::{
    EnrollmentsApi, FakeEnrollmentsApi, HttpEnrollmentsApi, MyEnrollmentRow,
};
use cgc_events::list::{
    EventListService, EventsApi, FakeEventsApi, HttpEventsApi, ListState, StatusFilter,
};
use cgc_events::orders::{is_terminal_status, parse_rfc3339_epoch, qr_code_url, OrdersApi};
use cgc_platform::acp::connection::{
    AcpHost, AcpHostConfig, ConfigOptionView, HostEvent, SessionSummary,
};
use cgc_platform::agent::detect::{detect_all, AgentStatus, SystemProbe};
use cgc_platform::agent::launch::{build_launch, LaunchPlan, NodeRuntime};
use cgc_platform::agent::node_runtime::{HttpDownloader, NodeRuntimeManager};
use cgc_platform::events::{AppEvent, EventPublisher, MemoryEventBus};
use cgc_platform::mcp::credential::{
    issue_lease, FakeLearningHostApi, HttpLearningHostApi, KeychainVault, LearningHostApi,
    LearningHostLease, MemoryVault, SecretVault,
};
use cgc_platform::mcp::inject::{build_mcp_server, mcp_endpoint, McpServerConfig};
use cgc_platform::registry::manifest::Registry;
use cgc_platform::routes::NavIcon;
use cgc_platform::session::{AuthError, SessionService, SessionState, SignedInSession};
use cgc_platform::workspace::{CourseContext, CourseContextPort, CourseContextProvider};
use cgc_platform::workspace::{
    FakeWorkspaceApi, HttpWorkspaceApi, WorkspaceApi, WorkspaceListState, WorkspaceService,
};
use gpui_kit::assets::IconName as AssetIcon;
use gpui_kit::component::{Icon, Sizable as _};

use crate::i18n::{default_language, translate, translate_registered, Key, Language};
use crate::qr::{encode as encode_qr, render_qr, QrError};
use crate::routing::{Route, RouteMatch, RouteRegistry};
use crate::settings_window::SettingsWindowView;
use crate::theme::{self, space, ThemePreference, RADIUS_LARGE, RADIUS_MEDIUM, RADIUS_SMALL};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum LoginField {
    Email,
    Password,
    Phone,
    Code,
    ResetToken,
    NewPassword,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum LoginMode {
    Password,
    Phone,
    Reset,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum BreadcrumbMenu {
    Sections,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum LoginError {
    Invalid,
    Network,
    Keychain,
    Phone,
    RateLimited,
    Reset,
}

impl LoginError {
    fn from_auth_error(error: &AuthError) -> Self {
        match error {
            AuthError::InvalidCredentials => LoginError::Invalid,
            AuthError::Transport(_) | AuthError::Server(_) => LoginError::Network,
            AuthError::Storage(_) => LoginError::Keychain,
            AuthError::Domain { code, .. } => match code.as_str() {
                "invalid_or_expired_code" | "invalid_phone" | "phone_code_sign_in_failed" => {
                    LoginError::Phone
                }
                "rate_limited" => LoginError::RateLimited,
                "invalid_or_expired_reset_token" => LoginError::Reset,
                _ => LoginError::Network,
            },
        }
    }

    fn key(self) -> Key {
        match self {
            LoginError::Invalid => Key::AppAuthErrorInvalid,
            LoginError::Network => Key::AppAuthErrorNetwork,
            LoginError::Keychain => Key::AppAuthErrorKeychain,
            LoginError::Phone => Key::AppAuthErrorPhone,
            LoginError::RateLimited => Key::AppAuthErrorRateLimited,
            LoginError::Reset => Key::AppAuthErrorReset,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum PaymentViewState {
    Idle,
    Creating,
    Qr {
        url: String,
        order_id: String,
        expire_at: Option<String>,
    },
    Paid,
    Terminal(String),
    Failed(String),
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum EnrollmentsListState {
    Idle,
    Loading,
    Ready,
    Empty,
    Failed(String),
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
enum ChatPhase {
    #[default]
    Idle,
    Starting,
    Ready,
    Streaming,
    Failed(String),
}

#[derive(Clone, Debug)]
enum ChatEntry {
    User(String),
    Assistant(String),
    Tool {
        title: String,
        kind: String,
    },
    Permission {
        request_id: String,
        title: String,
        resolved: Option<bool>,
    },
}

#[derive(Default)]
struct ChatUi {
    phase: ChatPhase,
    agent: String,
    version: Option<String>,
    messages: Vec<ChatEntry>,
    input: String,
    focused: bool,
    host: Option<AcpHost>,
    lease: Option<LearningHostLease>,
    poll_generation: u64,
    auto_prompted: bool,
    configs: Vec<ConfigOptionView>,
    sessions: Vec<SessionSummary>,
    show_sessions: bool,
    session_id: Option<String>,
    course_id: Option<String>,
    restore_id: Option<String>,
    configs_applied: bool,
    history_open: bool,
    streaming_message_open: bool,
    guidance: Option<ChatGuidance>,
}

#[derive(Clone, Debug)]
struct ChatGuidance {
    detected: Vec<(String, String)>,
    node_found: Option<String>,
}

struct ChatStartError {
    message: String,
    detected: Vec<(String, String)>,
    node_found: Option<String>,
}

struct PreparedChat {
    agent_name: String,
    plan: LaunchPlan,
    lease: LearningHostLease,
    server: McpServerConfig,
}

pub struct RootView {
    registry: RouteRegistry,
    current: Option<RouteMatch>,
    language: Language,
    preference: ThemePreference,
    session: SessionService,
    session_checked: bool,
    login_mode: LoginMode,
    login_email: String,
    login_phone: String,
    login_code: String,
    login_reset_token: String,
    login_new_password: String,
    phone_code_sent: bool,
    reset_sent: bool,
    login_notice: Option<Key>,
    login_password: String,
    focused: LoginField,
    login_error: Option<LoginError>,
    signing_in: bool,
    account_menu_open: bool,
    agent_panel_open: bool,
    breadcrumb_menu: Option<BreadcrumbMenu>,
    is_fake_mode: bool,
    key_focus: Option<FocusHandle>,
    events: EventListService,
    events_started: bool,
    enrollments_api: Arc<dyn EnrollmentsApi>,
    enrollments_rows: Vec<MyEnrollmentRow>,
    enrollments_state: EnrollmentsListState,
    enrollments_started: bool,
    detail: EventDetailService,
    detail_started: bool,
    selected_tier: Option<String>,
    age_confirmed: bool,
    enrolling: bool,
    enrollment_error: Option<String>,
    orders: Arc<dyn OrdersApi>,
    payment: PaymentViewState,
    payment_generation: u64,
    deposit_consent: bool,
    events_bus: Arc<MemoryEventBus>,
    chat: ChatUi,
    courses: CourseCatalogService,
    courses_started: bool,
    workspaces: WorkspaceService,
    workspaces_started: bool,
    workspace_menu_open: bool,
    revoking: bool,
    settings_error: Option<String>,
    course_detail: CourseDetailService,
    course_detail_started: bool,
    content: CourseContentService,
    projection: LearningProjectionService,
    pending_link: Option<String>,
    review_event_keys: std::collections::HashSet<String>,
    selected_event: Option<String>,
}

impl RootView {
    /// 生产入口：会话由 `SessionService::from_runtime()` 装配（CGC_AUTH / CGC_API_URL 决定 fake 或真实）。
    pub fn new(registry: RouteRegistry) -> Self {
        Self::with_session(
            registry,
            default_language(),
            theme::preference_from_env(),
            SessionService::from_runtime(),
        )
    }

    pub fn with_session(
        registry: RouteRegistry,
        language: Language,
        preference: ThemePreference,
        session: SessionService,
    ) -> Self {
        let current = initial_route(&registry);
        let is_fake_mode = std::env::var("CGC_AUTH").as_deref() != Ok("http")
            && std::env::var("CGC_API_URL").is_err();
        let events = build_events_service();
        let detail = EventDetailService::new(events.api_handle());
        let courses = build_courses_service();
        let course_detail = CourseDetailService::new(courses.api_handle());
        let content = CourseContentService::new(courses.api_handle());
        let projection = LearningProjectionService::new(courses.api_handle());
        Self {
            registry,
            current,
            language,
            preference,
            session,
            session_checked: false,
            login_mode: LoginMode::Password,
            login_email: String::new(),
            login_phone: String::new(),
            login_code: String::new(),
            login_reset_token: String::new(),
            login_new_password: String::new(),
            phone_code_sent: false,
            reset_sent: false,
            login_notice: None,
            login_password: String::new(),
            focused: LoginField::Email,
            login_error: None,
            signing_in: false,
            account_menu_open: false,
            agent_panel_open: true,
            breadcrumb_menu: None,
            is_fake_mode,
            key_focus: None,
            events,
            events_started: false,
            enrollments_api: build_enrollments_api(),
            enrollments_rows: Vec::new(),
            enrollments_state: EnrollmentsListState::Idle,
            enrollments_started: false,
            detail,
            detail_started: false,
            selected_tier: None,
            age_confirmed: false,
            enrolling: false,
            enrollment_error: None,
            orders: build_orders_api(),
            payment: PaymentViewState::Idle,
            payment_generation: 0,
            deposit_consent: false,
            events_bus: Arc::new(MemoryEventBus::new()),
            chat: ChatUi::default(),
            courses,
            courses_started: false,
            course_detail,
            course_detail_started: false,
            content,
            projection,
            pending_link: None,
            review_event_keys: std::collections::HashSet::new(),
            workspaces: build_workspace_service(),
            workspaces_started: false,
            workspace_menu_open: std::env::var("CGC_WORKSPACE_MENU").as_deref() == Ok("open"),
            revoking: false,
            settings_error: None,
            selected_event: None,
        }
    }

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
        if let crate::routing::RouteSelection::Match(route_match) = self.registry.select(path) {
            self.current = Some(route_match);
            self.events_started = false;
            self.detail_started = false;
        }
    }

    fn navigate_to_event_detail(&mut self, event_id: &str) {
        let Some(route) = self.registry.find("events.detail") else {
            return;
        };
        let mut params = std::collections::BTreeMap::new();
        params.insert("id", event_id.to_string());
        self.current = Some(RouteMatch { route, params });
        self.detail_started = false;
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

    fn session_token(&self) -> Option<String> {
        self.session
            .signed_in()
            .map(|session| session.token.clone())
    }

    fn reset_events(&mut self) {
        self.events_started = false;
        self.enrollments_started = false;
        self.enrollments_rows.clear();
        self.enrollments_state = EnrollmentsListState::Idle;
        self.detail_started = false;
        self.courses_started = false;
        self.course_detail_started = false;
        self.selected_event = None;
    }

    fn force_sign_out(&mut self, cx: &mut Context<Self>) {
        self.session.sign_out_local();
        self.workspaces.reset();
        self.workspaces_started = false;
        self.session_checked = false;
        self.reset_workspace_data();
        self.navigate("/");
        cx.notify();
    }

    fn start_session_validation(&mut self, cx: &mut Context<Self>) {
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

    fn start_workspace_load(&mut self, cx: &mut Context<Self>) {
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
                    Ok(workspaces) => this.workspaces.adopt(workspaces),
                    Err(error) if error.is_unauthorized() => this.force_sign_out(cx),
                    Err(error) => this.workspaces.fail(&error),
                }
                cx.notify();
            });
        })
        .detach();
    }

    fn switch_workspace(&mut self, workspace_id: &str, cx: &mut Context<Self>) {
        if self.workspaces.switch_to(workspace_id) {
            self.reset_workspace_data();
            self.navigate("/");
            self.workspace_menu_open = false;
            cx.notify();
        }
    }

    fn reset_workspace_data(&mut self) {
        self.reset_events();
        self.events.reset();
        self.detail.reset();
        self.courses.reset();
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
        self.reset_chat_local();
        self.review_event_keys.clear();
    }

    fn start_projection_load(&mut self, cx: &mut Context<Self>, course_id: String) {
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

    fn start_content_load(&mut self, cx: &mut Context<Self>, course_id: String) {
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

    fn chat_course_context(&self) -> Result<CourseContext, cgc_platform::workspace::ContextError> {
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

    fn start_chat(&mut self, cx: &mut Context<Self>) {
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
        let load_session = self
            .chat
            .restore_id
            .take()
            .or_else(|| course_id.as_deref().and_then(load_chat_pointer));
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
            let detected = detect_all(&registry, &probe);
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
            let chosen = detected
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
                })?;
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

    fn spawn_chat_poller(&mut self, cx: &mut Context<Self>, generation: u64) {
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

    fn drain_chat_events(&mut self, generation: u64, cx: &mut Context<Self>) -> bool {
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
                        save_chat_pointer(&course_id, "omp", &session_id);
                    }
                }
                HostEvent::ConfigOptions { options } => {
                    self.chat.configs = options;
                    if !self.chat.configs_applied {
                        self.chat.configs_applied = true;
                        for config in self.chat.configs.clone() {
                            if let Some(value) = load_chat_pref("omp", &config.id) {
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
                    if !matches!(self.chat.phase, ChatPhase::Idle) {
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

    fn send_chat(&mut self, cx: &mut Context<Self>) {
        let text = self.chat.input.trim().to_string();
        if text.is_empty() {
            return;
        }
        self.chat.input.clear();
        self.send_chat_text(text, cx);
    }

    fn send_chat_text(&mut self, text: String, cx: &mut Context<Self>) {
        if !matches!(self.chat.phase, ChatPhase::Ready) {
            return;
        }
        let Some(host) = &self.chat.host else {
            return;
        };
        if !host.prompt(text.clone()) {
            self.chat.phase = ChatPhase::Failed("agent channel closed".to_string());
            return;
        }
        self.chat.history_open = false;
        self.chat.streaming_message_open = false;
        self.chat.messages.push(ChatEntry::User(text));
        self.chat.phase = ChatPhase::Streaming;
        cx.notify();
    }

    fn stop_chat_turn(&mut self, cx: &mut Context<Self>) {
        if let Some(host) = &self.chat.host {
            host.stop();
        }
        cx.notify();
    }

    fn respond_chat_permission(&mut self, allow: bool, cx: &mut Context<Self>) {
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

    fn cycle_chat_config(&mut self, index: usize, cx: &mut Context<Self>) {
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
        save_chat_pref("omp", &config.id, &value);
        if let Some(entry) = self.chat.configs.get_mut(index) {
            entry.current = value;
        }
        cx.notify();
    }

    fn open_chat_history(&mut self, cx: &mut Context<Self>) {
        if let Some(host) = &self.chat.host {
            let _ = host.list_sessions();
        }
        self.chat.show_sessions = true;
        cx.notify();
    }

    fn restore_chat_session(&mut self, session_id: String, cx: &mut Context<Self>) {
        self.chat.restore_id = Some(session_id);
        self.reset_chat_local();
        self.start_chat(cx);
    }

    fn install_node_runtime(&mut self, cx: &mut Context<Self>) {
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

    fn reset_chat_local(&mut self) {
        self.chat.host.take();
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

    fn start_courses_load(&mut self, cx: &mut Context<Self>, first: bool) {
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
                    Ok(page) => this.courses.adopt_page(page),
                    Err(error) if error.is_unauthorized() => this.force_sign_out(cx),
                    Err(error) => this.courses.fail(&error),
                }
                cx.notify();
            });
        })
        .detach();
    }

    fn start_course_detail_load(&mut self, cx: &mut Context<Self>, course_id: String) {
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

    fn navigate_to_course_detail(&mut self, course_id: &str) {
        self.navigate(&format!("/courses/{course_id}"));
    }

    fn navigate_to_learning(&mut self, course_id: &str) {
        self.navigate(&format!("/courses/{course_id}/learn"));
    }

    fn is_settings_shortcut(keystroke: &gpui_kit::Keystroke) -> bool {
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

    fn breadcrumb_context(&self) -> Option<(bool, Option<String>)> {
        let route_id = self
            .current
            .as_ref()
            .map(|route_match| route_match.route.id)?;
        match route_id {
            "events.list" | "events.mine" => Some((false, None)),
            "events.detail" => Some((
                false,
                self.detail.detail().map(|detail| detail.title.clone()),
            )),
            "courses.catalog" => Some((true, None)),
            "courses.detail" | "courses.learning" => Some((
                true,
                self.course_detail
                    .detail()
                    .map(|detail| detail.title.clone()),
            )),
            _ => None,
        }
    }

    fn toggle_breadcrumb_menu(&mut self, cx: &mut Context<Self>) {
        self.breadcrumb_menu = if self.breadcrumb_menu.is_some() {
            None
        } else {
            Some(BreadcrumbMenu::Sections)
        };
        self.workspace_menu_open = false;
        cx.notify();
    }

    fn render_breadcrumb_bar(
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
            Some((true, _)) => translate_registered(language, "courses.catalog.title"),
            Some((false, _)) => translate_registered(language, "events.list.title"),
            None => translate(language, Key::AppBreadcrumbSections),
        };
        let selected = self.breadcrumb_menu.is_some();
        bar = bar
            .child(div().child("›"))
            .child(
                div()
                    .id("breadcrumb-section")
                    .role(Role::Button)
                    .aria_label(section_label)
                    .px(space(1))
                    .py(px(2.0))
                    .rounded(px(RADIUS_SMALL))
                    .text_color(if selected {
                        palette.ink
                    } else {
                        palette.ink_2
                    })
                    .bg(if selected {
                        palette.soft
                    } else {
                        palette.card
                    })
                    .hover(|style| style.bg(palette.soft))
                    .child(format!("{section_label} ▾"))
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.toggle_breadcrumb_menu(cx);
                    })),
            );
        if let Some((_, Some(title))) = context {
            bar = bar
                .child(div().child("›"))
                .child(div().text_color(palette.ink_2).child(title));
        }
        bar.into_any_element()
    }

    fn render_breadcrumb_menu(
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
            ("events.list", "events.list.title", false),
            ("courses.catalog", "courses.catalog.title", true),
        ]
        .into_iter()
        .map(|(route_id, title_key, _courses)| {
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
                    if route_id == "events.list" {
                        this.navigate("/events");
                    } else {
                        this.navigate("/courses");
                    }
                    cx.notify();
                }))
                .into_any_element()
        })
        .collect::<Vec<_>>();
        div()
            .id("breadcrumb-menu")
            .absolute()
            .top(px(72.0))
            .left(px(230.0))
            .w(px(220.0))
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

    fn toggle_agent_panel(&mut self, cx: &mut Context<Self>) {
        self.agent_panel_open = !self.agent_panel_open;
        cx.notify();
    }

    fn is_agent_panel_shortcut(keystroke: &Keystroke) -> bool {
        keystroke.key.eq_ignore_ascii_case("j")
            && !keystroke.modifiers.shift
            && (keystroke.modifiers.platform || keystroke.modifiers.control)
    }

    fn render_agent_panel(
        &mut self,
        language: Language,
        palette: &theme::Palette,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let learning = self
            .current
            .as_ref()
            .is_some_and(|route_match| route_match.route.id == "courses.learning");
        div()
            .id("agent-panel-dock")
            .w(px(440.0))
            .flex_none()
            .h_full()
            .p(space(2))
            .border_l_1()
            .border_color(palette.line)
            .bg(palette.canvas)
            .child(if learning {
                self.render_chat_panel(language, palette, cx)
            } else {
                div()
                    .flex()
                    .flex_col()
                    .gap(space(2))
                    .text_size(px(12.0))
                    .text_color(palette.ink_3)
                    .child(translate(language, Key::AgentChatPanelTitle))
                    .child(translate(language, Key::CoursesLearningContextRequired))
                    .into_any_element()
            })
            .into_any_element()
    }

    fn handle_shell_key(
        &mut self,
        event: &KeyDownEvent,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if Self::is_agent_panel_shortcut(&event.keystroke) {
            self.toggle_agent_panel(cx);
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
            self.navigate_to_learning(&course_id);
            cx.notify();
        }
    }

    fn start_enrollments_load(&mut self, cx: &mut Context<Self>) {
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

    fn start_detail_load(&mut self, cx: &mut Context<Self>, event_id: String) {
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

    fn start_payment(&mut self, provider: &str, cx: &mut Context<Self>) {
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

    fn poll_payment(
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

    fn close_payment(&mut self, cx: &mut Context<Self>) {
        self.payment = PaymentViewState::Idle;
        self.payment_generation = self.payment_generation.saturating_add(1);
        cx.notify();
    }

    fn cancel_enrollment_action(&mut self, cx: &mut Context<Self>) {
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

    fn refresh_enrollment(&mut self, cx: &mut Context<Self>) {
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

    fn submit_enrollment(&mut self, cx: &mut Context<Self>) {
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

    fn retry_detail(&mut self, cx: &mut Context<Self>) {
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

    fn start_events_load(&mut self, cx: &mut Context<Self>, first: bool) {
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

    fn select_events_filter(&mut self, filter: StatusFilter, cx: &mut Context<Self>) {
        self.events.set_filter(filter);
        self.events.retry_ready();
        self.start_events_load(cx, true);
    }

    fn retry_events(&mut self, cx: &mut Context<Self>) {
        self.events.retry_ready();
        self.start_events_load(cx, true);
    }

    fn ensure_key_focus(&mut self, cx: &mut Context<Self>) -> FocusHandle {
        self.key_focus
            .get_or_insert_with(|| cx.focus_handle())
            .clone()
    }

    fn login_error_key(&self) -> Option<Key> {
        self.login_error.map(LoginError::key)
    }

    fn submit_login(&mut self, cx: &mut Context<Self>) {
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

    fn finish_login(&mut self, result: Result<SignedInSession, AuthError>) {
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
            }
            Err(error) => {
                self.session.fail_sign_in(&error);
                self.login_error = Some(LoginError::from_auth_error(&error));
            }
        }
    }

    fn sign_out(&mut self, cx: &mut Context<Self>) {
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
        self.reset_workspace_data();
        self.login_email.clear();
        self.login_password.clear();
        self.login_error = None;
        cx.notify();
    }

    #[allow(clippy::too_many_arguments)]
    fn login_input(
        &self,
        language: Language,
        palette: &theme::Palette,
        id: &str,
        field: LoginField,
        placeholder: Key,
        value: String,
        masked: bool,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let focused = self.focused == field;
        let empty = value.is_empty();
        let display = if empty {
            translate(language, placeholder).to_string()
        } else if masked {
            "•".repeat(value.chars().count().max(1))
        } else {
            value
        };
        let empty = empty || display.is_empty();
        div()
            .id(id.to_string())
            .h(px(34.0))
            .flex()
            .items_center()
            .px(space(2))
            .rounded(px(RADIUS_MEDIUM))
            .border_1()
            .border_color(if focused {
                palette.accent
            } else {
                palette.line_strong
            })
            .bg(palette.view)
            .text_color(if empty { palette.ink_3 } else { palette.ink })
            .child(display)
            .role(Role::TextInput)
            .aria_label(translate(language, placeholder))
            .on_mouse_down(
                MouseButton::Left,
                cx.listener(move |this, _, window, cx| {
                    this.focused = field;
                    let focus = this.ensure_key_focus(cx);
                    window.focus(&focus, cx);
                    cx.notify();
                }),
            )
            .into_any_element()
    }

    fn login_feedback(&self, language: Language, palette: &theme::Palette) -> Vec<AnyElement> {
        let mut elements = Vec::new();
        if let Some(key) = self.login_notice {
            elements.push(
                div()
                    .text_size(px(12.0))
                    .text_color(palette.accent)
                    .child(translate(language, key))
                    .into_any_element(),
            );
        }
        if let Some(key) = self.login_error.map(LoginError::key) {
            elements.push(
                div()
                    .text_size(px(12.0))
                    .text_color(palette.danger)
                    .child(translate(language, key))
                    .into_any_element(),
            );
        }
        elements
    }

    fn render_phone_login_card(
        &mut self,
        language: Language,
        palette: &theme::Palette,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let phone = self.login_phone.clone();
        let code = self.login_code.clone();
        let sent = self.phone_code_sent;
        let signing_in = self.signing_in;
        let phone_input = self.login_input(
            language,
            palette,
            "login-phone",
            LoginField::Phone,
            Key::AppAuthPhonePhone,
            phone,
            false,
            cx,
        );
        let code_input = self.login_input(
            language,
            palette,
            "login-code",
            LoginField::Code,
            Key::AppAuthPhoneCode,
            code,
            false,
            cx,
        );
        let card = div()
            .w(px(360.0))
            .flex()
            .flex_col()
            .gap(space(2))
            .p(space(5))
            .rounded(px(RADIUS_LARGE))
            .border_1()
            .border_color(palette.line)
            .bg(palette.card)
            .child(
                div()
                    .text_size(px(22.0))
                    .text_color(palette.ink)
                    .child(translate(language, Key::AppName)),
            )
            .child(
                div()
                    .text_size(px(12.0))
                    .text_color(palette.ink_3)
                    .child(translate(language, Key::AppAuthPhoneTitle)),
            )
            .child(phone_input)
            .children(sent.then_some(code_input))
            .children(self.login_feedback(language, palette))
            .child(
                div()
                    .flex()
                    .flex_row()
                    .gap(space(1))
                    .child(
                        div()
                            .id("phone-send-code")
                            .role(Role::Button)
                            .aria_label(translate(language, Key::AppAuthPhoneSendCode))
                            .flex_1()
                            .h(px(34.0))
                            .flex()
                            .items_center()
                            .justify_center()
                            .rounded(px(RADIUS_MEDIUM))
                            .bg(palette.soft)
                            .text_color(palette.ink_2)
                            .child(translate(language, Key::AppAuthPhoneSendCode))
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.request_phone_code(cx);
                            })),
                    )
                    .child(
                        div()
                            .id("phone-submit")
                            .role(Role::Button)
                            .aria_label(translate(language, Key::AppAuthPhoneSubmit))
                            .flex_1()
                            .h(px(34.0))
                            .flex()
                            .items_center()
                            .justify_center()
                            .rounded(px(RADIUS_MEDIUM))
                            .bg(if signing_in {
                                palette.soft
                            } else {
                                palette.accent
                            })
                            .text_color(if signing_in {
                                palette.ink_3
                            } else {
                                palette.ink
                            })
                            .child(translate(language, Key::AppAuthPhoneSubmit))
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.submit_phone_login(cx);
                            })),
                    ),
            )
            .child(
                div()
                    .id("phone-back")
                    .role(Role::Link)
                    .aria_label(translate(language, Key::AppAuthBack))
                    .text_size(px(12.0))
                    .text_color(palette.ink_3)
                    .child(translate(language, Key::AppAuthBack))
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.switch_login_mode(LoginMode::Password);
                        cx.notify();
                    })),
            );
        card.into_any_element()
    }

    fn render_reset_login_card(
        &mut self,
        language: Language,
        palette: &theme::Palette,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let email = self.login_email.clone();
        let token = self.login_reset_token.clone();
        let new_password = self.login_new_password.clone();
        let reset_sent = self.reset_sent;
        let signing_in = self.signing_in;
        let email_input = self.login_input(
            language,
            palette,
            "reset-email",
            LoginField::Email,
            Key::AppAuthResetEmail,
            email,
            false,
            cx,
        );
        let token_input = self.login_input(
            language,
            palette,
            "reset-token",
            LoginField::ResetToken,
            Key::AppAuthResetToken,
            token,
            false,
            cx,
        );
        let password_input = self.login_input(
            language,
            palette,
            "reset-password",
            LoginField::NewPassword,
            Key::AppAuthResetNewPassword,
            new_password,
            true,
            cx,
        );
        let mut card = div()
            .w(px(360.0))
            .flex()
            .flex_col()
            .gap(space(2))
            .p(space(5))
            .rounded(px(RADIUS_LARGE))
            .border_1()
            .border_color(palette.line)
            .bg(palette.card)
            .child(
                div()
                    .text_size(px(22.0))
                    .text_color(palette.ink)
                    .child(translate(language, Key::AppName)),
            )
            .child(
                div()
                    .text_size(px(12.0))
                    .text_color(palette.ink_3)
                    .child(translate(language, Key::AppAuthResetTitle)),
            );
        if reset_sent {
            card = card
                .child(translate(language, Key::AppAuthResetSent))
                .child(token_input)
                .child(password_input)
                .child(
                    div()
                        .id("reset-submit")
                        .h(px(34.0))
                        .flex()
                        .items_center()
                        .justify_center()
                        .rounded(px(RADIUS_MEDIUM))
                        .bg(if signing_in {
                            palette.soft
                        } else {
                            palette.accent
                        })
                        .text_color(if signing_in {
                            palette.ink_3
                        } else {
                            palette.ink
                        })
                        .child(translate(language, Key::AppAuthResetSubmit))
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.submit_reset_password(cx);
                        })),
                );
        } else {
            card = card.child(email_input).child(
                div()
                    .id("reset-request")
                    .role(Role::Button)
                    .aria_label(translate(language, Key::AppAuthResetRequest))
                    .h(px(34.0))
                    .flex()
                    .items_center()
                    .justify_center()
                    .rounded(px(RADIUS_MEDIUM))
                    .bg(if signing_in {
                        palette.soft
                    } else {
                        palette.accent
                    })
                    .text_color(if signing_in {
                        palette.ink_3
                    } else {
                        palette.ink
                    })
                    .child(translate(language, Key::AppAuthResetRequest))
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.request_password_reset(cx);
                    })),
            );
        }
        card = card.children(self.login_feedback(language, palette)).child(
            div()
                .id("reset-back")
                .text_size(px(12.0))
                .text_color(palette.ink_3)
                .child(translate(language, Key::AppAuthBack))
                .on_click(cx.listener(|this, _, _, cx| {
                    this.switch_login_mode(LoginMode::Password);
                    cx.notify();
                })),
        );
        card.into_any_element()
    }

    fn handle_key(&mut self, event: &KeyDownEvent, window: &mut Window, cx: &mut Context<Self>) {
        match event.keystroke.key.as_str() {
            "tab" => self.cycle_login_field(),
            "enter" => match self.login_mode {
                LoginMode::Password => self.submit_login(cx),
                LoginMode::Phone => {
                    if self.phone_code_sent {
                        self.submit_phone_login(cx)
                    } else {
                        self.request_phone_code(cx)
                    }
                }
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

    fn field_mut(&mut self) -> &mut String {
        match self.focused {
            LoginField::Email => &mut self.login_email,
            LoginField::Password => &mut self.login_password,
            LoginField::Phone => &mut self.login_phone,
            LoginField::Code => &mut self.login_code,
            LoginField::ResetToken => &mut self.login_reset_token,
            LoginField::NewPassword => &mut self.login_new_password,
        }
    }

    fn login_fields(&self) -> Vec<LoginField> {
        match self.login_mode {
            LoginMode::Password => vec![LoginField::Email, LoginField::Password],
            LoginMode::Phone => vec![LoginField::Phone, LoginField::Code],
            LoginMode::Reset => {
                if self.reset_sent {
                    vec![LoginField::ResetToken, LoginField::NewPassword]
                } else {
                    vec![LoginField::Email]
                }
            }
        }
    }

    fn cycle_login_field(&mut self) {
        let fields = self.login_fields();
        let index = fields
            .iter()
            .position(|field| *field == self.focused)
            .unwrap_or(0);
        self.focused = fields[(index + 1) % fields.len()];
    }

    fn switch_login_mode(&mut self, mode: LoginMode) {
        self.login_mode = mode;
        self.login_error = None;
        self.login_notice = None;
        self.phone_code_sent = false;
        self.reset_sent = false;
        self.focused = match mode {
            LoginMode::Password => LoginField::Email,
            LoginMode::Phone => LoginField::Phone,
            LoginMode::Reset => LoginField::Email,
        };
    }

    fn request_phone_code(&mut self, cx: &mut Context<Self>) {
        let phone = self.login_phone.trim().to_string();
        if phone.is_empty() || self.signing_in {
            return;
        }
        self.signing_in = true;
        self.login_error = None;
        let api = self.session.api_handle();
        let task = cx.background_executor().spawn(async move {
            api.request_phone_code(&phone, cgc_platform::session::PhoneCodePurpose::Login)
        });
        cx.spawn(async move |this, cx| {
            let result = task.await;
            let _ = this.update(cx, |this, cx| {
                this.signing_in = false;
                match result {
                    Ok(sent) if sent.sent => {
                        this.phone_code_sent = true;
                        this.login_notice = Some(Key::AppAuthPhoneCodeSent);
                        this.focused = LoginField::Code;
                    }
                    Ok(_) => this.login_error = Some(LoginError::Phone),
                    Err(error) => this.login_error = Some(LoginError::from_auth_error(&error)),
                }
                cx.notify();
            });
        })
        .detach();
    }

    fn submit_phone_login(&mut self, cx: &mut Context<Self>) {
        let phone = self.login_phone.trim().to_string();
        let code = self.login_code.trim().to_string();
        if phone.is_empty() || code.is_empty() || self.signing_in {
            return;
        }
        self.signing_in = true;
        self.login_error = None;
        let api = self.session.api_handle();
        let task = cx
            .background_executor()
            .spawn(async move { api.sign_in_with_phone_code(&phone, &code) });
        cx.spawn(async move |this, cx| {
            let result = task.await;
            let _ = this.update(cx, |this, cx| {
                this.finish_login(result);
                cx.notify();
            });
        })
        .detach();
    }

    fn request_password_reset(&mut self, cx: &mut Context<Self>) {
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

    fn submit_reset_password(&mut self, cx: &mut Context<Self>) {
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
                        this.switch_login_mode(LoginMode::Password);
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

impl Render for RootView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let mode = theme::resolve(self.preference, window.appearance());
        let palette = theme::palette(mode);
        let language = self.language;
        let account_menu = self.account_menu_open;
        let signing_in = self.signing_in;
        let login_error_key = self.login_error_key();
        let is_signed_in = self.is_signed_in();
        let email = self
            .session
            .signed_in()
            .and_then(|session| session.email.clone())
            .unwrap_or_default();
        let avatar_glyph = email
            .chars()
            .next()
            .map(|c| c.to_uppercase().to_string())
            .unwrap_or_else(|| "C".to_string());

        let theme_label = translate(language, self.preference.label_key());
        let language_label = translate(
            language,
            match language {
                Language::Zh => Key::AppLangZh,
                Language::En => Key::AppLangEn,
            },
        );
        let theme_tooltip = translate(language, Key::AppThemeToggle);
        let language_tooltip = translate(language, Key::AppLanguageToggle);
        let account_tooltip = translate(language, Key::AppAccountMenu);
        let sign_out_label = translate(language, Key::AppAuthSignOut);
        let signed_in_as = translate(language, Key::AppAuthSignedInAs);

        let theme_icon = match self.preference {
            ThemePreference::Light => AssetIcon::Sun,
            ThemePreference::Dark => AssetIcon::Moon,
            ThemePreference::System => AssetIcon::Monitor,
        };
        let language_icon = AssetIcon::Languages;

        if is_signed_in {
            if !self.session_checked {
                self.session_checked = true;
                self.start_session_validation(cx);
            }
            if !self.workspaces_started
                && matches!(self.workspaces.state(), WorkspaceListState::Idle)
            {
                self.start_workspace_load(cx);
            }
            let workspaces_ready = !matches!(
                self.workspaces.state(),
                WorkspaceListState::Idle | WorkspaceListState::Loading
            );
            let current_id = self
                .current
                .as_ref()
                .map(|route_match| route_match.route.id);
            if workspaces_ready
                && current_id == Some("events.list")
                && !self.events_started
                && matches!(self.events.state(), ListState::Idle)
            {
                self.start_events_load(cx, true);
            }
            if workspaces_ready
                && current_id == Some("events.mine")
                && !self.enrollments_started
                && matches!(self.enrollments_state, EnrollmentsListState::Idle)
            {
                self.start_enrollments_load(cx);
            }
            if workspaces_ready
                && current_id == Some("events.detail")
                && !self.detail_started
                && matches!(self.detail.state(), ListState::Idle)
            {
                if let Some(event_id) = self
                    .current
                    .as_ref()
                    .and_then(|route_match| route_match.params.get("id"))
                    .cloned()
                {
                    self.start_detail_load(cx, event_id);
                }
            }
            if workspaces_ready
                && current_id == Some("courses.catalog")
                && !self.courses_started
                && matches!(self.courses.state(), CoursesListState::Idle)
            {
                self.start_courses_load(cx, true);
            }
            if workspaces_ready
                && matches!(
                    current_id,
                    Some("courses.detail") | Some("courses.learning")
                )
                && !self.course_detail_started
                && matches!(self.course_detail.state(), CoursesListState::Idle)
            {
                if let Some(course_id) = self
                    .current
                    .as_ref()
                    .and_then(|route_match| route_match.params.get("id"))
                    .cloned()
                {
                    self.start_course_detail_load(cx, course_id);
                }
            }
            if current_id == Some("courses.learning")
                && matches!(self.course_detail.state(), CoursesListState::Ready)
                && std::env::var("CGC_AUTO_CHAT").as_deref() == Ok("1")
                && matches!(self.chat.phase, ChatPhase::Idle)
            {
                self.start_chat(cx);
            }
            if current_id != Some("courses.learning") && self.chat.host.is_some() {
                self.reset_chat_local();
            }

            if workspaces_ready
                && current_id == Some("courses.learning")
                && matches!(self.course_detail.state(), CoursesListState::Ready)
                && matches!(self.content.state(), CourseContentState::Idle)
            {
                if let Some(course_id) = self
                    .current
                    .as_ref()
                    .and_then(|route_match| route_match.params.get("id"))
                    .cloned()
                {
                    self.start_content_load(cx, course_id);
                }
            }
            if workspaces_ready
                && current_id == Some("courses.learning")
                && matches!(self.course_detail.state(), CoursesListState::Ready)
                && matches!(self.projection.state(), ProjectionState::Idle)
            {
                if let Some(course_id) = self
                    .current
                    .as_ref()
                    .and_then(|route_match| route_match.params.get("id"))
                    .cloned()
                {
                    self.start_projection_load(cx, course_id);
                }
            }
        }

        let key_focus = self.ensure_key_focus(cx);
        if is_signed_in
            && self
                .current
                .as_ref()
                .is_some_and(|route_match| route_match.route.id == "courses.detail")
        {
            window.focus(&key_focus, cx);
        }
        if !is_signed_in {
            window.focus(&key_focus, cx);
        }
        let login_email = self.login_email.clone();
        let login_password = self.login_password.clone();
        let focused = self.focused;
        let login_notice = self.login_notice;
        let is_fake_mode = self.is_fake_mode;

        let mut root = div();
        if !is_signed_in {
            let email_border = if focused == LoginField::Email {
                palette.accent
            } else {
                palette.line_strong
            };
            let password_border = if focused == LoginField::Password {
                palette.accent
            } else {
                palette.line_strong
            };
            let email_display = if login_email.is_empty() {
                div()
                    .text_color(palette.ink_3)
                    .child(translate(language, Key::AppAuthEmail))
                    .into_any_element()
            } else {
                div()
                    .text_color(palette.ink)
                    .child(login_email)
                    .into_any_element()
            };
            let password_display = if login_password.is_empty() {
                div()
                    .text_color(palette.ink_3)
                    .child(translate(language, Key::AppAuthPassword))
                    .into_any_element()
            } else {
                div()
                    .text_color(palette.ink)
                    .child("•".repeat(login_password.chars().count().max(1)))
                    .into_any_element()
            };

            let password_card = div()
                .w(px(360.0))
                .flex()
                .flex_col()
                .gap(space(2))
                .p(space(5))
                .rounded(px(RADIUS_LARGE))
                .border_1()
                .border_color(palette.line)
                .bg(palette.card)
                .child(
                    div()
                        .text_size(px(22.0))
                        .text_color(palette.ink)
                        .child(translate(language, Key::AppName)),
                )
                .child(
                    div()
                        .text_size(px(12.0))
                        .text_color(palette.ink_3)
                        .child(translate(language, Key::AppAuthSubmit)),
                )
                .child(
                    div()
                        .id("login-email")
                        .h(px(34.0))
                        .flex()
                        .items_center()
                        .px(space(2))
                        .rounded(px(RADIUS_MEDIUM))
                        .border_1()
                        .border_color(email_border)
                        .bg(palette.view)
                        .role(Role::TextInput)
                        .aria_label(translate(language, Key::AppAuthEmail))
                        .child(email_display)
                        .on_mouse_down(
                            MouseButton::Left,
                            cx.listener(|this, _, window, cx| {
                                this.focused = LoginField::Email;
                                let focus = this.ensure_key_focus(cx);
                                window.focus(&focus, cx);
                                cx.notify();
                            }),
                        ),
                )
                .child(
                    div()
                        .id("login-password")
                        .h(px(34.0))
                        .flex()
                        .items_center()
                        .px(space(2))
                        .rounded(px(RADIUS_MEDIUM))
                        .border_1()
                        .border_color(password_border)
                        .bg(palette.view)
                        .role(Role::TextInput)
                        .aria_label(translate(language, Key::AppAuthPassword))
                        .child(password_display)
                        .on_mouse_down(
                            MouseButton::Left,
                            cx.listener(|this, _, window, cx| {
                                this.focused = LoginField::Password;
                                let focus = this.ensure_key_focus(cx);
                                window.focus(&focus, cx);
                                cx.notify();
                            }),
                        ),
                )
                .children(login_error_key.map(|key| {
                    div()
                        .text_size(px(12.0))
                        .text_color(palette.danger)
                        .child(translate(language, key))
                        .into_any_element()
                }))
                .child(
                    div()
                        .id("login-submit")
                        .h(px(36.0))
                        .flex()
                        .items_center()
                        .justify_center()
                        .rounded(px(RADIUS_MEDIUM))
                        .bg(if signing_in {
                            palette.soft
                        } else {
                            palette.accent
                        })
                        .text_color(if signing_in {
                            palette.ink_3
                        } else {
                            palette.ink
                        })
                        .role(Role::Button)
                        .aria_label(translate(language, Key::AppAuthSubmit))
                        .child(translate(language, Key::AppAuthSubmit))
                        .on_click(cx.listener(|this, _, _, cx| this.submit_login(cx))),
                )
                .children(if is_fake_mode {
                    Some(
                        div()
                            .text_size(px(11.0))
                            .text_color(palette.ink_3)
                            .child(translate(language, Key::AppAuthFakeHint))
                            .into_any_element(),
                    )
                } else {
                    None
                })
                .children(login_notice.map(|key| {
                    div()
                        .text_size(px(12.0))
                        .text_color(palette.accent)
                        .child(translate(language, key))
                        .into_any_element()
                }))
                .child(
                    div()
                        .flex()
                        .flex_row()
                        .justify_between()
                        .text_size(px(12.0))
                        .child(
                            div()
                                .id("login-mode-phone")
                                .role(Role::Link)
                                .aria_label(translate(language, Key::AppAuthModePhone))
                                .text_color(palette.accent)
                                .child(translate(language, Key::AppAuthModePhone))
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.switch_login_mode(LoginMode::Phone);
                                    cx.notify();
                                })),
                        )
                        .child(
                            div()
                                .id("login-forgot")
                                .role(Role::Link)
                                .aria_label(translate(language, Key::AppAuthForgot))
                                .text_color(palette.ink_3)
                                .child(translate(language, Key::AppAuthForgot))
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.switch_login_mode(LoginMode::Reset);
                                    cx.notify();
                                })),
                        ),
                );

            let login_card = match self.login_mode {
                LoginMode::Password => password_card.into_any_element(),
                LoginMode::Phone => self.render_phone_login_card(language, &palette, cx),
                LoginMode::Reset => self.render_reset_login_card(language, &palette, cx),
            };
            root = root
                .size_full()
                .flex()
                .flex_col()
                .bg(palette.canvas)
                .text_color(palette.ink)
                .font_family(theme::FONT_SANS)
                .text_size(px(14.0))
                .track_focus(&key_focus)
                .on_key_down(cx.listener(Self::handle_key))
                .child(
                    div()
                        .flex_1()
                        .w_full()
                        .flex()
                        .items_center()
                        .justify_center()
                        .child(login_card),
                )
                .child(self.render_footer(
                    language,
                    false,
                    theme_icon,
                    theme_label,
                    theme_tooltip,
                    language_icon,
                    language_label,
                    language_tooltip,
                    &palette,
                    cx,
                ));
            root
        } else {
            root = root
                .size_full()
                .flex()
                .flex_col()
                .bg(palette.canvas)
                .text_color(palette.ink)
                .font_family(theme::FONT_SANS)
                .text_size(px(14.0))
                .track_focus(&key_focus)
                .on_key_down(cx.listener(Self::handle_shell_key))
                .child(
                    div()
                        .flex()
                        .flex_row()
                        .items_center()
                        .h(px(44.0))
                        .pl(if cfg!(target_os = "macos") {
                            px(84.0)
                        } else {
                            space(3)
                        })
                        .pr(space(2))
                        .gap(space(1))
                        .bg(palette.frame)
                        .border_b_1()
                        .border_color(palette.line)
                        .child(
                            div()
                                .id("titlebar-drag")
                                .flex()
                                .items_center()
                                .h_full()
                                .pr(space(2))
                                .on_mouse_down(MouseButton::Left, |_, window, _| {
                                    window.start_window_move();
                                })
                                .child(
                                    div()
                                        .text_size(px(15.0))
                                        .text_color(palette.ink)
                                        .child(translate(language, Key::AppName)),
                                ),
                        )
                        .child(div().w(px(1.0)).h(px(14.0)).bg(palette.line))
                        .child(div().flex_1())
                        .child(
                            div().relative().flex().items_center().child(
                                div()
                                    .id("account-menu-toggle")
                                    .size(px(26.0))
                                    .rounded_full()
                                    .flex()
                                    .items_center()
                                    .justify_center()
                                    .bg(palette.accent)
                                    .text_size(px(12.0))
                                    .text_color(hsla_white())
                                    .child(avatar_glyph)
                                    .tooltip(move |_, cx| {
                                        cx.new(|_| TooltipText {
                                            text: account_tooltip.into(),
                                        })
                                        .into()
                                    })
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.toggle_account_menu();
                                        cx.notify();
                                    })),
                            ),
                        ),
                )
                .child(self.render_breadcrumb_bar(language, &palette, cx))
                .child(
                    div()
                        .flex()
                        .flex_row()
                        .flex_1()
                        .min_h(px(0.0))
                        .w_full()
                        .child(
                            div()
                                .id("content-scroll")
                                .flex_1()
                                .min_w(px(0.0))
                                .p(space(6))
                                .overflow_y_scroll()
                                .child(
                                    if matches!(self.workspaces.state(), WorkspaceListState::Empty)
                                    {
                                        self.render_workspace_empty(language, &palette)
                                    } else {
                                        match self
                                            .current
                                            .as_ref()
                                            .map(|route_match| route_match.route.id)
                                        {
                                            Some("events.list") => {
                                                self.render_events_list(language, &palette, cx)
                                            }
                                            Some("events.detail") => {
                                                self.render_detail(language, &palette, cx)
                                            }
                                            Some("events.mine") => {
                                                self.render_enrollments_list(language, &palette, cx)
                                            }
                                            Some("app.settings") => {
                                                self.render_settings(language, &palette, cx)
                                            }
                                            Some("courses.catalog") => {
                                                self.render_courses_list(language, &palette, cx)
                                            }
                                            Some("courses.detail") => {
                                                self.render_course_detail(language, &palette, cx)
                                            }
                                            Some("courses.learning") => {
                                                self.render_course_learning(language, &palette, cx)
                                            }
                                            _ => self.render_content(language, &palette, cx),
                                        }
                                    },
                                ),
                        )
                        .children(
                            self.agent_panel_open
                                .then(|| self.render_agent_panel(language, &palette, cx)),
                        ),
                )
                .child(self.render_footer(
                    language,
                    true,
                    theme_icon,
                    theme_label,
                    theme_tooltip,
                    language_icon,
                    language_label,
                    language_tooltip,
                    &palette,
                    cx,
                ));
            if self.workspace_menu_open {
                root = root.child(self.render_workspace_menu(language, &palette, cx));
            }
            if let Some(menu) = self.breadcrumb_menu {
                root = root.child(self.render_breadcrumb_menu(language, &palette, menu, cx));
            }
            if account_menu {
                root = root.child(self.render_account_menu(
                    language,
                    &palette,
                    &email,
                    signed_in_as,
                    sign_out_label,
                    cx,
                ));
            }
            root
        }
    }
}

impl RootView {
    /// 账户下拉：必须挂在根级最后绘制，否则会被后续 content/footer 覆盖（表现为“半透明”）。
    fn render_account_menu(
        &self,
        language: Language,
        palette: &theme::Palette,
        email: &str,
        signed_in_as: &str,
        sign_out_label: &str,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        div()
            .id("account-menu")
            .absolute()
            .top(px(52.0))
            .right(space(2))
            .w(px(220.0))
            .flex()
            .flex_col()
            .gap(px(2.0))
            .p(space(1))
            .rounded(px(RADIUS_MEDIUM))
            .border_1()
            .border_color(palette.line_strong)
            .bg(palette.card)
            .occlude()
            .text_color(palette.ink)
            .child(
                div()
                    .px(space(1))
                    .py(px(4.0))
                    .text_size(px(10.0))
                    .text_color(palette.ink_3)
                    .child(format!("{signed_in_as} {email}")),
            )
            .child(
                div()
                    .id("account-settings")
                    .role(Role::Button)
                    .aria_label(translate(language, Key::AppSettingsTitle))
                    .px(space(1))
                    .py(px(6.0))
                    .rounded(px(RADIUS_SMALL))
                    .text_color(palette.ink_2)
                    .hover(|style| style.bg(palette.soft))
                    .child(
                        div()
                            .flex()
                            .justify_between()
                            .child(translate(language, Key::AppSettingsTitle))
                            .child(if cfg!(target_os = "macos") {
                                "⌘,"
                            } else {
                                "Ctrl+,"
                            }),
                    )
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.open_settings_window(cx);
                        this.account_menu_open = false;
                        cx.notify();
                    })),
            )
            .child(
                div()
                    .id("account-sign-out")
                    .px(space(1))
                    .py(px(6.0))
                    .rounded(px(RADIUS_SMALL))
                    .text_color(palette.ink_2)
                    .hover(|style| style.bg(palette.soft))
                    .child(sign_out_label.to_string())
                    .on_click(cx.listener(|this, _, _, cx| this.sign_out(cx))),
            )
            .into_any_element()
    }

    fn render_content(
        &self,
        language: Language,
        palette: &theme::Palette,
        _cx: &mut Context<Self>,
    ) -> AnyElement {
        match &self.current {
            Some(route_match) => div()
                .flex()
                .flex_col()
                .gap(space(2))
                .child(
                    div()
                        .text_size(px(24.0))
                        .text_color(palette.ink)
                        .child(translate_registered(language, route_match.route.title_key)),
                )
                .child(
                    div()
                        .text_color(palette.ink_3)
                        .child(translate(language, Key::AppPlaceholderBody)),
                )
                .into_any_element(),
            None => div()
                .flex()
                .flex_col()
                .items_center()
                .justify_center()
                .gap(space(2))
                .child(
                    div()
                        .text_size(px(22.0))
                        .text_color(palette.ink)
                        .child(translate(language, Key::AppEmptyTitle)),
                )
                .child(
                    div()
                        .text_color(palette.ink_3)
                        .child(translate(language, Key::AppEmptyBody)),
                )
                .into_any_element(),
        }
    }

    fn render_enrollments_list(
        &mut self,
        language: Language,
        palette: &theme::Palette,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let body: AnyElement = match &self.enrollments_state {
            EnrollmentsListState::Idle | EnrollmentsListState::Loading => div()
                .text_color(palette.ink_3)
                .child(translate(language, Key::EventsMineLoading))
                .into_any_element(),
            EnrollmentsListState::Failed(message) => div()
                .flex()
                .flex_col()
                .gap(space(1))
                .child(div().text_color(palette.danger).child(message.clone()))
                .child(
                    div()
                        .id("enrollments-retry")
                        .px(space(2))
                        .py(px(5.0))
                        .rounded(px(RADIUS_MEDIUM))
                        .bg(palette.accent)
                        .text_color(palette.canvas)
                        .child(translate(language, Key::EventsMineRetry))
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.enrollments_started = false;
                            this.enrollments_state = EnrollmentsListState::Idle;
                            cx.notify();
                        })),
                )
                .into_any_element(),
            EnrollmentsListState::Empty => div()
                .text_color(palette.ink_3)
                .child(translate(language, Key::EventsMineEmpty))
                .into_any_element(),
            EnrollmentsListState::Ready => {
                let rows = self
                    .enrollments_rows
                    .iter()
                    .map(|row| {
                        let starts = row
                            .starts_at
                            .as_deref()
                            .map(|value| value.chars().take(10).collect::<String>())
                            .unwrap_or_default();
                        let target = row.target_title.clone().unwrap_or_default();
                        let event_id = row.event_id.clone();
                        let course_id = row.course_id.clone();
                        let row_id = row.id.clone();
                        div()
                            .id(format!("enrollment-row-{row_id}"))
                            .flex()
                            .flex_row()
                            .items_center()
                            .justify_between()
                            .gap(space(2))
                            .px(space(2))
                            .py(space(1))
                            .border_b_1()
                            .border_color(palette.line)
                            .hover(|style| style.bg(palette.soft))
                            .child(
                                div()
                                    .flex()
                                    .flex_col()
                                    .gap(px(2.0))
                                    .child(div().text_color(palette.ink).child(target))
                                    .child(
                                        div()
                                            .text_size(px(11.0))
                                            .text_color(palette.ink_3)
                                            .child(starts),
                                    ),
                            )
                            .child(
                                div()
                                    .px(px(6.0))
                                    .py(px(2.0))
                                    .rounded(px(RADIUS_SMALL))
                                    .bg(palette.soft)
                                    .text_size(px(11.0))
                                    .text_color(palette.ink_2)
                                    .child(enroll_status_label(language, &row.status)),
                            )
                            .on_click(cx.listener(move |this, _, _, cx| {
                                if let Some(event_id) = &event_id {
                                    this.navigate(&format!("/events/{event_id}"));
                                } else if let Some(course_id) = &course_id {
                                    this.navigate(&format!("/courses/{course_id}"));
                                }
                                cx.notify();
                            }))
                            .into_any_element()
                    })
                    .collect::<Vec<_>>();
                div().flex().flex_col().children(rows).into_any_element()
            }
        };

        div()
            .flex()
            .flex_col()
            .gap(space(2))
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .justify_between()
                    .child(
                        div()
                            .text_size(px(24.0))
                            .text_color(palette.ink)
                            .child(translate_registered(language, "events.mine.title")),
                    )
                    .child(
                        div()
                            .id("enrollments-back")
                            .text_size(px(12.0))
                            .text_color(palette.ink_3)
                            .child(translate(language, Key::EventsDetailBack))
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.navigate("/events");
                                cx.notify();
                            })),
                    ),
            )
            .child(body)
            .into_any_element()
    }

    fn render_detail(
        &mut self,
        language: Language,
        palette: &theme::Palette,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let state = self.detail.state().clone();
        let detail = self.detail.detail().cloned();

        let back = div()
            .id("detail-back")
            .child(translate(language, Key::EventsDetailBack))
            .text_color(palette.ink_3)
            .text_size(px(12.0))
            .on_click(cx.listener(|this, _, _, cx| {
                this.navigate("/events");
                cx.notify();
            }));

        let body: AnyElement = match state {
            ListState::Idle | ListState::Loading => div()
                .text_color(palette.ink_3)
                .child(translate(language, Key::EventsDetailLoading))
                .into_any_element(),
            ListState::Failed(message) => {
                let not_found = message == "not found";
                div()
                    .flex()
                    .flex_col()
                    .gap(space(1))
                    .child(div().text_color(palette.danger).child(if not_found {
                        translate(language, Key::EventsDetailNotFound)
                    } else {
                        translate(language, Key::EventsDetailError)
                    }))
                    .children((!not_found).then(|| {
                        div()
                            .id("detail-retry")
                            .px(space(2))
                            .py(px(5.0))
                            .rounded(px(RADIUS_MEDIUM))
                            .bg(palette.accent)
                            .text_color(white())
                            .child(translate(language, Key::EventsDetailRetry))
                            .on_click(cx.listener(|this, _, _, cx| this.retry_detail(cx)))
                            .into_any_element()
                    }))
                    .into_any_element()
            }
            ListState::Empty => div()
                .text_color(palette.ink_3)
                .child(translate(language, Key::EventsDetailNotFound))
                .into_any_element(),
            ListState::Ready => match detail {
                Some(detail) => {
                    let starts = detail
                        .starts_at
                        .as_deref()
                        .map(|value| value.chars().take(10).collect::<String>())
                        .unwrap_or_default();
                    let venue = detail
                        .venue
                        .as_deref()
                        .and_then(cgc_events::detail::venue_city)
                        .unwrap_or_default();
                    let (price_label, price_detail) = match detail.price_mode() {
                        PriceMode::Free => (
                            translate(language, Key::EventsDetailFree).to_string(),
                            String::new(),
                        ),
                        PriceMode::Paid {
                            min_amount_cents,
                            tiers,
                        } => (
                            translate(language, Key::EventsDetailPaid).to_string(),
                            format!("¥{:.2} 起 · {tiers} 档", min_amount_cents as f64 / 100.0),
                        ),
                        PriceMode::Deposit { amount_cents } => (
                            translate(language, Key::EventsDetailDeposit).to_string(),
                            format!("押金 ¥{:.2}（可退）", amount_cents as f64 / 100.0),
                        ),
                    };
                    let capacity = detail
                        .capacity
                        .map(|capacity| {
                            format!("{}/{}", detail.confirmed_count.unwrap_or(0), capacity)
                        })
                        .unwrap_or_else(|| "—".to_string());

                    div()
                        .flex()
                        .flex_col()
                        .gap(space(2))
                        .child(
                            div()
                                .text_size(px(24.0))
                                .text_color(palette.ink)
                                .child(detail.title.clone()),
                        )
                        .child(
                            div()
                                .text_size(px(12.0))
                                .text_color(palette.ink_3)
                                .child(format!(
                                    "{starts} · {} · {}",
                                    translate(language, Key::EventsDetailVenue),
                                    if venue.is_empty() {
                                        "—".to_string()
                                    } else {
                                        venue
                                    }
                                )),
                        )
                        .children(detail.description.clone().map(|description| {
                            div()
                                .text_color(palette.ink_2)
                                .child(description)
                                .into_any_element()
                        }))
                        .child(
                            div()
                                .flex()
                                .flex_row()
                                .items_center()
                                .gap(space(2))
                                .child(
                                    div()
                                        .px(space(1))
                                        .py(px(3.0))
                                        .rounded(px(RADIUS_SMALL))
                                        .bg(palette.soft)
                                        .text_color(palette.ink_2)
                                        .text_size(px(12.0))
                                        .child(translate(
                                            language,
                                            status_key(detail.status.as_str()),
                                        )),
                                )
                                .child(
                                    div()
                                        .px(space(1))
                                        .py(px(3.0))
                                        .rounded(px(RADIUS_SMALL))
                                        .bg(palette.soft)
                                        .text_color(palette.ink_2)
                                        .text_size(px(12.0))
                                        .child(format!("{price_label} {price_detail}")),
                                )
                                .child(div().text_size(px(12.0)).text_color(palette.ink_3).child(
                                    format!(
                                        "{} {capacity}",
                                        translate(language, Key::EventsDetailCapacity)
                                    ),
                                )),
                        )
                        .child(self.render_enrollment_area(language, palette, &detail, cx))
                        .into_any_element()
                }
                None => div()
                    .text_color(palette.ink_3)
                    .child(translate(language, Key::EventsDetailNotFound))
                    .into_any_element(),
            },
        };

        div()
            .flex()
            .flex_col()
            .gap(space(2))
            .child(back)
            .child(body)
            .into_any_element()
    }

    fn render_chat_panel(
        &mut self,
        language: Language,
        palette: &theme::Palette,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let phase = self.chat.phase.clone();
        let messages = self.chat.messages.clone();
        let input = self.chat.input.clone();
        let agent_label = if self.chat.agent.is_empty() {
            "agent".to_string()
        } else {
            self.chat.agent.clone()
        };
        let body: AnyElement = match &phase {
            ChatPhase::Idle => div()
                .flex()
                .flex_row()
                .items_center()
                .gap(space(2))
                .child(
                    div()
                        .text_size(px(12.0))
                        .text_color(palette.ink_3)
                        .child(format!("{agent_label} · 本机运行")),
                )
                .child(
                    div()
                        .id("chat-start")
                        .role(Role::Button)
                        .aria_label(translate(language, Key::AgentChatChatStart))
                        .role(Role::Button)
                        .aria_label(translate(language, Key::AgentChatChatStart))
                        .px(space(2))
                        .py(px(5.0))
                        .rounded(px(RADIUS_MEDIUM))
                        .bg(palette.accent)
                        .text_color(palette.canvas)
                        .child(translate(language, Key::AgentChatChatStart))
                        .on_click(cx.listener(|this, _, _, cx| this.start_chat(cx))),
                )
                .into_any_element(),
            ChatPhase::Starting => div()
                .text_size(px(12.0))
                .text_color(palette.ink_3)
                .child(translate(language, Key::AgentChatChatStarting))
                .into_any_element(),
            ChatPhase::Failed(message) => {
                let guidance =
                    self.chat.guidance.clone().map(|guidance| {
                        let detected_rows = guidance
                            .detected
                            .iter()
                            .map(|(name, status)| {
                                div()
                                    .text_size(px(11.0))
                                    .text_color(palette.ink_2)
                                    .child(format!("{name}：{status}"))
                                    .into_any_element()
                            })
                            .collect::<Vec<_>>();
                        let node_ready = guidance
                            .node_found
                            .as_deref()
                            .is_some_and(version_at_least_24);
                        let install = (!node_ready).then(|| {
                            div()
                                .id("chat-install-node")
                                .px(space(2))
                                .py(px(4.0))
                                .rounded(px(RADIUS_MEDIUM))
                                .bg(palette.accent)
                                .text_color(palette.canvas)
                                .child(translate(language, Key::AgentChatChatInstallNode))
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.install_node_runtime(cx);
                                }))
                                .into_any_element()
                        });
                        div()
                            .flex()
                            .flex_col()
                            .gap(space(1))
                            .child(
                                div()
                                    .text_size(px(12.0))
                                    .text_color(palette.ink_2)
                                    .child(translate(language, Key::AgentChatChatAgentGuidance)),
                            )
                            .children(detected_rows)
                            .child(div().text_size(px(11.0)).text_color(palette.ink_3).child(
                                format!(
                                    "Node runtime: {} (required 24.x)",
                                    guidance
                                        .node_found
                                        .clone()
                                        .unwrap_or_else(|| "missing".to_string())
                                ),
                            ))
                            .children(install)
                            .child(
                                div()
                                    .text_size(px(11.0))
                                    .text_color(palette.ink_3)
                                    .child(translate(language, Key::AgentChatChatLoginHint)),
                            )
                            .into_any_element()
                    });
                div()
                    .flex()
                    .flex_col()
                    .gap(space(1))
                    .child(
                        div()
                            .text_size(px(12.0))
                            .text_color(palette.danger)
                            .child(format!(
                                "{}：{message}",
                                translate(language, Key::AgentChatChatFailed)
                            )),
                    )
                    .children(guidance)
                    .child(
                        div()
                            .id("chat-retry")
                            .role(Role::Button)
                            .aria_label(translate(language, Key::AgentChatChatRetry))
                            .role(Role::Button)
                            .aria_label(translate(language, Key::AgentChatChatRetry))
                            .role(Role::Button)
                            .aria_label(translate(language, Key::AgentChatChatRetry))
                            .px(space(2))
                            .py(px(5.0))
                            .rounded(px(RADIUS_MEDIUM))
                            .bg(palette.accent)
                            .text_color(palette.canvas)
                            .child(translate(language, Key::AgentChatChatRetry))
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.chat.phase = ChatPhase::Idle;
                                this.start_chat(cx);
                            })),
                    )
                    .into_any_element()
            }
            ChatPhase::Ready | ChatPhase::Streaming => {
                let rows = messages
                    .iter()
                    .map(|entry| match entry {
                        ChatEntry::User(text) => div()
                            .flex()
                            .flex_col()
                            .gap(px(1.0))
                            .text_size(px(11.0))
                            .text_color(palette.ink_3)
                            .child("你".to_string())
                            .child(
                                div()
                                    .text_size(px(13.0))
                                    .text_color(palette.ink)
                                    .child(text.clone()),
                            )
                            .into_any_element(),
                        ChatEntry::Assistant(text) => div()
                            .flex()
                            .flex_col()
                            .gap(px(1.0))
                            .text_size(px(11.0))
                            .text_color(palette.ink_3)
                            .child(agent_label.clone())
                            .child(
                                TextView::markdown(
                                    format!("chat-markdown-{}", text.len()),
                                    sanitize_markdown(text),
                                )
                                .into_any_element(),
                            )
                            .into_any_element(),
                        ChatEntry::Tool { title, kind } => div()
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap(space(1))
                            .px(space(1))
                            .py(px(3.0))
                            .rounded(px(RADIUS_SMALL))
                            .border_1()
                            .border_color(palette.line)
                            .text_size(px(12.0))
                            .text_color(palette.ink_2)
                            .child("🔧")
                            .child(title.clone())
                            .child(
                                div()
                                    .text_size(px(10.0))
                                    .text_color(palette.ink_3)
                                    .child(kind.clone()),
                            )
                            .into_any_element(),
                        ChatEntry::Permission {
                            request_id,
                            title,
                            resolved,
                        } => {
                            let status = match resolved {
                                Some(true) => "已允许",
                                Some(false) => "已拒绝",
                                None => "等待你的决定",
                            };
                            let buttons: Vec<AnyElement> = if resolved.is_none() {
                                vec![
                                    div()
                                        .id(format!("perm-allow-{request_id}"))
                                        .role(Role::Button)
                                        .aria_label("允许")
                                        .px(space(1))
                                        .py(px(3.0))
                                        .rounded(px(RADIUS_SMALL))
                                        .bg(palette.accent)
                                        .text_color(palette.canvas)
                                        .child("允许")
                                        .on_click(cx.listener(|this, _, _, cx| {
                                            this.respond_chat_permission(true, cx);
                                        }))
                                        .into_any_element(),
                                    div()
                                        .id(format!("perm-deny-{request_id}"))
                                        .role(Role::Button)
                                        .aria_label("拒绝")
                                        .px(space(1))
                                        .py(px(3.0))
                                        .rounded(px(RADIUS_SMALL))
                                        .bg(palette.soft)
                                        .text_color(palette.ink_2)
                                        .child("拒绝")
                                        .on_click(cx.listener(|this, _, _, cx| {
                                            this.respond_chat_permission(false, cx);
                                        }))
                                        .into_any_element(),
                                ]
                            } else {
                                Vec::new()
                            };
                            div()
                                .flex()
                                .flex_col()
                                .gap(space(1))
                                .p(space(1))
                                .rounded(px(RADIUS_SMALL))
                                .border_1()
                                .border_color(palette.line_strong)
                                .text_size(px(12.0))
                                .text_color(palette.ink)
                                .child(format!("需要你的同意 · {title}"))
                                .child(
                                    div()
                                        .text_size(px(10.0))
                                        .text_color(palette.ink_3)
                                        .child(status),
                                )
                                .child(
                                    div()
                                        .text_size(px(10.0))
                                        .text_color(palette.ink_3)
                                        .child("Ctrl+Shift+Y 允许 · Ctrl+Shift+N 拒绝"),
                                )
                                .children(buttons)
                                .into_any_element()
                        }
                    })
                    .collect::<Vec<_>>();
                let streaming = phase == ChatPhase::Streaming;
                let status = if streaming {
                    translate(language, Key::AgentChatChatThinking).to_string()
                } else {
                    String::new()
                };
                div()
                    .flex_1()
                    .min_h(px(0.0))
                    .flex()
                    .flex_col()
                    .gap(space(2))
                    .child(
                        div()
                            .id("chat-messages")
                            .flex_1()
                            .min_h(px(120.0))
                            .overflow_y_scroll()
                            .flex()
                            .flex_col()
                            .gap(space(2))
                            .children(rows),
                    )
                    .children((!status.is_empty()).then(|| {
                        div()
                            .text_size(px(11.0))
                            .text_color(palette.ink_3)
                            .child(status)
                            .into_any_element()
                    }))
                    .child(
                        div()
                            .id("chat-input")
                            .role(Role::TextInput)
                            .aria_label(translate(language, Key::AgentChatChatInputHint))
                            .h(px(34.0))
                            .flex()
                            .items_center()
                            .px(space(2))
                            .rounded(px(RADIUS_MEDIUM))
                            .border_1()
                            .border_color(if self.chat.focused {
                                palette.accent
                            } else {
                                palette.line
                            })
                            .bg(palette.view)
                            .text_size(px(13.0))
                            .text_color(if input.is_empty() {
                                palette.ink_3
                            } else {
                                palette.ink
                            })
                            .child(if input.is_empty() {
                                translate(language, Key::AgentChatChatInputHint).to_string()
                            } else {
                                input.clone()
                            })
                            .on_mouse_down(
                                MouseButton::Left,
                                cx.listener(|this, _, window, cx| {
                                    this.chat.focused = true;
                                    let focus = this.ensure_key_focus(cx);
                                    window.focus(&focus, cx);
                                    cx.notify();
                                }),
                            ),
                    )
                    .child(
                        div()
                            .flex()
                            .flex_row()
                            .gap(space(1))
                            .child(
                                div()
                                    .id("chat-send")
                                    .role(Role::Button)
                                    .aria_label(translate(language, Key::AgentChatChatSend))
                                    .role(Role::Button)
                                    .aria_label(translate(language, Key::AgentChatChatSend))
                                    .role(Role::Button)
                                    .aria_label(translate(language, Key::AgentChatChatSend))
                                    .px(space(2))
                                    .py(px(4.0))
                                    .rounded(px(RADIUS_MEDIUM))
                                    .bg(if streaming {
                                        palette.soft
                                    } else {
                                        palette.accent
                                    })
                                    .text_color(if streaming {
                                        palette.ink_3
                                    } else {
                                        palette.canvas
                                    })
                                    .child(translate(language, Key::AgentChatChatSend))
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.chat.focused = true;
                                        this.send_chat(cx);
                                    })),
                            )
                            .child(
                                div()
                                    .id("chat-new")
                                    .role(Role::Button)
                                    .aria_label(translate(language, Key::AgentChatChatNew))
                                    .role(Role::Button)
                                    .aria_label(translate(language, Key::AgentChatChatNew))
                                    .role(Role::Button)
                                    .aria_label(translate(language, Key::AgentChatChatNew))
                                    .px(space(2))
                                    .py(px(4.0))
                                    .rounded(px(RADIUS_MEDIUM))
                                    .bg(palette.soft)
                                    .text_color(palette.ink_2)
                                    .child(translate(language, Key::AgentChatChatNew))
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        if let Some(course_id) = this.chat.course_id.clone() {
                                            clear_chat_pointer(&course_id);
                                        }
                                        this.reset_chat_local();
                                        this.start_chat(cx);
                                    })),
                            )
                            .children(streaming.then(|| {
                                div()
                                    .id("chat-stop")
                                    .role(Role::Button)
                                    .aria_label(translate(language, Key::AgentChatChatStop))
                                    .role(Role::Button)
                                    .aria_label(translate(language, Key::AgentChatChatStop))
                                    .role(Role::Button)
                                    .aria_label(translate(language, Key::AgentChatChatStop))
                                    .px(space(2))
                                    .py(px(4.0))
                                    .rounded(px(RADIUS_MEDIUM))
                                    .bg(palette.soft)
                                    .text_color(palette.ink_2)
                                    .child(translate(language, Key::AgentChatChatStop))
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.stop_chat_turn(cx);
                                    }))
                                    .into_any_element()
                            })),
                    )
                    .into_any_element()
            }
        };
        let version = self
            .chat
            .version
            .as_deref()
            .map(|version| format!(" · {version}"))
            .unwrap_or_default();
        let config_rows = self
            .chat
            .configs
            .iter()
            .take(2)
            .enumerate()
            .map(|(index, config)| {
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap(space(1))
                    .text_size(px(11.0))
                    .text_color(palette.ink_3)
                    .child(format!("{}：{}", config.name, config.current))
                    .child(
                        div()
                            .id(format!("chat-config-{index}"))
                            .px(space(1))
                            .py(px(2.0))
                            .rounded(px(RADIUS_SMALL))
                            .bg(palette.soft)
                            .text_color(palette.ink_2)
                            .child(translate(language, Key::AgentChatChatConfig))
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.cycle_chat_config(index, cx);
                            })),
                    )
                    .into_any_element()
            })
            .collect::<Vec<_>>();
        let history_rows = if self.chat.show_sessions {
            if self.chat.sessions.is_empty() {
                vec![div()
                    .text_size(px(11.0))
                    .text_color(palette.ink_3)
                    .child(translate(language, Key::AgentChatChatNoHistory))
                    .into_any_element()]
            } else {
                self.chat
                    .sessions
                    .iter()
                    .take(10)
                    .map(|session| {
                        let session_id = session.session_id.clone();
                        let title = session.title.clone().unwrap_or_else(|| {
                            let short = session.session_id.chars().take(10).collect::<String>();
                            format!("{short}…")
                        });
                        div()
                            .id(format!("chat-restore-{}", session.session_id))
                            .w_full()
                            .px(space(1))
                            .py(px(3.0))
                            .rounded(px(RADIUS_SMALL))
                            .text_size(px(11.0))
                            .text_color(palette.ink_2)
                            .hover(|style| style.bg(palette.soft))
                            .child(title)
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.restore_chat_session(session_id.clone(), cx);
                            }))
                            .into_any_element()
                    })
                    .collect()
            }
        } else {
            Vec::new()
        };
        let status_color = match &phase {
            ChatPhase::Ready | ChatPhase::Streaming => palette.accent,
            ChatPhase::Failed(_) => palette.danger,
            _ => palette.ink_3,
        };
        let thread_sidebar = self.chat.show_sessions.then(|| {
            div()
                .w(px(170.0))
                .flex_none()
                .flex()
                .flex_col()
                .gap(space(1))
                .pr(space(1))
                .border_r_1()
                .border_color(palette.line)
                .child(
                    div()
                        .flex()
                        .flex_row()
                        .items_center()
                        .justify_between()
                        .text_size(px(11.0))
                        .text_color(palette.ink_3)
                        .child(translate(language, Key::AgentChatChatThreads))
                        .child(
                            div()
                                .id("chat-hide-history")
                                .px(space(1))
                                .rounded(px(RADIUS_SMALL))
                                .hover(|style| style.bg(palette.soft))
                                .child("×")
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.chat.show_sessions = false;
                                    cx.notify();
                                })),
                        ),
                )
                .child(
                    div()
                        .id("chat-thread-list")
                        .flex()
                        .flex_col()
                        .gap(px(2.0))
                        .overflow_y_scroll()
                        .children(history_rows),
                )
                .into_any_element()
        });
        let toolbar = div()
            .flex()
            .flex_row()
            .items_center()
            .gap(space(1))
            .child(div().size(px(6.0)).rounded_full().bg(status_color))
            .child(
                div()
                    .text_size(px(15.0))
                    .text_color(palette.ink)
                    .child(translate_registered(language, "agent_chat.panel.title")),
            )
            .child(
                div()
                    .text_size(px(11.0))
                    .text_color(palette.ink_3)
                    .child(format!("{agent_label}{version}")),
            )
            .child(div().flex_1())
            .child(
                div()
                    .id("chat-new-toolbar")
                    .role(Role::Button)
                    .aria_label(translate(language, Key::AgentChatChatNew))
                    .px(space(1))
                    .py(px(3.0))
                    .rounded(px(RADIUS_SMALL))
                    .text_size(px(11.0))
                    .text_color(palette.accent)
                    .hover(|style| style.bg(palette.soft))
                    .child(translate(language, Key::AgentChatChatNew))
                    .on_click(cx.listener(|this, _, _, cx| {
                        if let Some(course_id) = this.chat.course_id.clone() {
                            clear_chat_pointer(&course_id);
                        }
                        this.reset_chat_local();
                        this.start_chat(cx);
                    })),
            )
            .child(
                div()
                    .id("chat-history-toolbar")
                    .role(Role::Button)
                    .aria_label(translate(language, Key::AgentChatChatHistory))
                    .px(space(1))
                    .py(px(3.0))
                    .rounded(px(RADIUS_SMALL))
                    .text_size(px(11.0))
                    .text_color(if self.chat.show_sessions {
                        palette.ink
                    } else {
                        palette.accent
                    })
                    .bg(if self.chat.show_sessions {
                        palette.soft
                    } else {
                        palette.card
                    })
                    .child(translate(language, Key::AgentChatChatHistory))
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.open_chat_history(cx);
                    })),
            );
        div()
            .flex()
            .flex_row()
            .items_stretch()
            .gap(space(1))
            .h_full()
            .p(space(2))
            .rounded(px(RADIUS_MEDIUM))
            .border_1()
            .border_color(palette.line)
            .bg(palette.card)
            .children(thread_sidebar)
            .child(
                div()
                    .flex()
                    .flex_1()
                    .min_w(px(0.0))
                    .flex_col()
                    .gap(space(1))
                    .child(toolbar)
                    .children(config_rows)
                    .child(body),
            )
            .into_any_element()
    }

    fn render_learning_projection(
        &mut self,
        language: Language,
        palette: &theme::Palette,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        match self.projection.state().clone() {
            ProjectionState::Idle | ProjectionState::Empty => div().into_any_element(),
            ProjectionState::Loading => div()
                .text_size(px(11.0))
                .text_color(palette.ink_3)
                .child(translate(language, Key::CoursesLearningProjectionTitle))
                .into_any_element(),
            ProjectionState::Failed(_) => div()
                .flex()
                .flex_row()
                .items_center()
                .gap(space(1))
                .text_size(px(11.0))
                .text_color(palette.ink_3)
                .child(translate(language, Key::CoursesLearningProjectionError))
                .child(
                    div()
                        .id("projection-retry")
                        .px(space(1))
                        .py(px(2.0))
                        .rounded(px(RADIUS_SMALL))
                        .bg(palette.soft)
                        .text_color(palette.ink_2)
                        .child(translate(language, Key::CoursesLearningProjectionRetry))
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.projection.retry_ready();
                            cx.notify();
                        })),
                )
                .into_any_element(),
            ProjectionState::Ready => {
                let Some(projection) = self.projection.projection().cloned() else {
                    return div().into_any_element();
                };
                let progress = projection.progress.clone();
                let next = projection.next_action.clone();
                let stale = projection.stale_revision;
                let review_count = projection.review_queue.len();
                let objectives = projection
                    .objectives
                    .iter()
                    .take(4)
                    .map(|objective| {
                        let status = match objective.mastery.as_str() {
                            "mastered" => "✓",
                            "learning" => "◐",
                            _ => "○",
                        };
                        div()
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap(space(1))
                            .text_size(px(11.0))
                            .text_color(palette.ink_2)
                            .child(format!("{status} {}", objective.title))
                            .children(objective.locked.then(|| {
                                div()
                                    .text_size(px(10.0))
                                    .text_color(palette.ink_3)
                                    .child(translate(
                                        language,
                                        Key::CoursesLearningProjectionLocked,
                                    ))
                                    .into_any_element()
                            }))
                            .into_any_element()
                    })
                    .collect::<Vec<_>>();
                div()
                    .mt(space(2))
                    .flex()
                    .flex_col()
                    .gap(space(1))
                    .p(space(2))
                    .rounded(px(RADIUS_MEDIUM))
                    .border_1()
                    .border_color(palette.line)
                    .bg(palette.card)
                    .child(
                        div()
                            .text_size(px(13.0))
                            .text_color(palette.ink)
                            .child(translate(language, Key::CoursesLearningProjectionTitle)),
                    )
                    .children(progress.map(|progress| {
                        div()
                            .text_size(px(12.0))
                            .text_color(palette.ink_2)
                            .child(format!(
                                "{} / {}",
                                progress.mastered_required, progress.total_required
                            ))
                            .into_any_element()
                    }))
                    .children(next.map(|next| {
                        div()
                            .text_size(px(12.0))
                            .text_color(palette.accent)
                            .child(next.reason)
                            .into_any_element()
                    }))
                    .children(stale.then(|| {
                        div()
                            .text_size(px(11.0))
                            .text_color(palette.danger)
                            .child(translate(language, Key::CoursesLearningProjectionStale))
                            .into_any_element()
                    }))
                    .children((review_count > 0).then(|| {
                        div()
                            .text_size(px(11.0))
                            .text_color(palette.ink_3)
                            .child(format!("待复习 {review_count}"))
                            .into_any_element()
                    }))
                    .children(objectives)
                    .into_any_element()
            }
        }
    }

    fn render_course_materials(
        &mut self,
        language: Language,
        palette: &theme::Palette,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        match self.content.state().clone() {
            CourseContentState::Idle | CourseContentState::Loading => div()
                .mt(space(2))
                .text_size(px(12.0))
                .text_color(palette.ink_3)
                .child(translate(language, Key::CoursesLearningContentLoading))
                .into_any_element(),
            CourseContentState::Failed(message) => div()
                .mt(space(2))
                .flex()
                .flex_col()
                .gap(space(1))
                .child(
                    div()
                        .text_size(px(12.0))
                        .text_color(palette.danger)
                        .child(message),
                )
                .child(
                    div()
                        .id("course-content-retry")
                        .px(space(2))
                        .py(px(5.0))
                        .rounded(px(RADIUS_MEDIUM))
                        .bg(palette.accent)
                        .text_color(palette.canvas)
                        .child(translate(language, Key::CoursesLearningContentRetry))
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.content.retry_ready();
                            cx.notify();
                        })),
                )
                .into_any_element(),
            CourseContentState::Empty => div()
                .mt(space(2))
                .text_size(px(12.0))
                .text_color(palette.ink_3)
                .child(translate(language, Key::CoursesLearningContentEmpty))
                .into_any_element(),
            CourseContentState::Ready => {
                let Some(content) = self.content.content().cloned() else {
                    return div()
                        .text_color(palette.ink_3)
                        .child(translate(language, Key::CoursesLearningContentEmpty))
                        .into_any_element();
                };
                let mut materials = Vec::new();
                for issue in &content.document.issues {
                    for material in issue
                        .story_materials
                        .iter()
                        .chain(issue.objective_materials.iter())
                    {
                        if !matches!(material.kind, MaterialKind::Text | MaterialKind::Markdown) {
                            continue;
                        }
                        let Some(body) = material.body.as_deref() else {
                            continue;
                        };
                        if body.trim().is_empty() {
                            continue;
                        }
                        let view_handle = cx.entity().downgrade();
                        materials.push(
                            TextView::markdown(
                                format!("course-material-{}", materials.len()),
                                sanitize_markdown(body),
                            )
                            .on_link_click(move |url, _, _, cx| {
                                if crate::safe_markdown::is_safe_link(url) {
                                    let url = url.to_string();
                                    let _ = view_handle.update(cx, |this, cx| {
                                        this.pending_link = Some(url);
                                        cx.notify();
                                    });
                                }
                            })
                            .into_any_element(),
                        );
                        materials.extend(render_markdown_with_math(
                            body,
                            &format!("course-math-{}", materials.len()),
                            14.0,
                            2.0,
                            palette.ink,
                        ));
                    }
                }
                if materials.is_empty() {
                    return div()
                        .text_color(palette.ink_3)
                        .child(translate(language, Key::CoursesLearningContentEmpty))
                        .into_any_element();
                }
                let confirm = self.pending_link.clone().map(|url| {
                    div()
                        .flex()
                        .flex_row()
                        .items_center()
                        .gap(space(1))
                        .p(space(1))
                        .rounded(px(RADIUS_MEDIUM))
                        .bg(palette.soft)
                        .text_size(px(12.0))
                        .child(div().text_color(palette.ink_2).child(format!(
                            "{} {url}",
                            translate(language, Key::CoursesRenderOpenLink)
                        )))
                        .child(
                            div()
                                .id("open-external-link")
                                .px(space(1))
                                .py(px(2.0))
                                .rounded(px(RADIUS_SMALL))
                                .bg(palette.accent)
                                .text_color(palette.canvas)
                                .child(translate(language, Key::CoursesRenderOpen))
                                .on_click(cx.listener(move |this, _, _, cx| {
                                    if let Some(url) = this.pending_link.take() {
                                        cx.open_url(&url);
                                    }
                                    cx.notify();
                                })),
                        )
                        .child(
                            div()
                                .id("cancel-external-link")
                                .px(space(1))
                                .py(px(2.0))
                                .rounded(px(RADIUS_SMALL))
                                .text_color(palette.ink_3)
                                .child(translate(language, Key::CoursesRenderCancel))
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.pending_link = None;
                                    cx.notify();
                                })),
                        )
                        .into_any_element()
                });
                div()
                    .mt(space(2))
                    .flex()
                    .flex_col()
                    .gap(space(2))
                    .children(confirm)
                    .children(materials)
                    .into_any_element()
            }
        }
    }

    fn revoke_device(&mut self, cx: &mut Context<Self>) {
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
                        this.reset_workspace_data();
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

    fn render_settings(
        &mut self,
        language: Language,
        palette: &theme::Palette,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let email = self
            .session
            .signed_in()
            .and_then(|session| session.email.clone())
            .unwrap_or_else(|| "—".to_string());
        let user_id = self
            .session
            .signed_in()
            .map(|session| session.user_id.clone())
            .unwrap_or_default();
        let workspace = self
            .workspaces
            .current()
            .map(|workspace| workspace.name.clone())
            .unwrap_or_else(|| "—".to_string());
        let error = self.settings_error.clone().map(|message| {
            div()
                .text_size(px(12.0))
                .text_color(palette.danger)
                .child(message)
                .into_any_element()
        });
        let revoke = div()
            .id("settings-revoke-device")
            .role(Role::Button)
            .aria_label(translate(language, Key::AppSettingsRevokeDevice))
            .px(space(2))
            .py(px(6.0))
            .rounded(px(RADIUS_MEDIUM))
            .bg(if self.revoking {
                palette.soft
            } else {
                palette.danger
            })
            .text_color(if self.revoking {
                palette.ink_3
            } else {
                palette.canvas
            })
            .child(if self.revoking {
                translate(language, Key::AppSettingsRevoking)
            } else {
                translate(language, Key::AppSettingsRevokeDevice)
            })
            .on_click(cx.listener(|this, _, _, cx| this.revoke_device(cx)));

        div()
            .flex()
            .flex_col()
            .gap(space(3))
            .child(
                div()
                    .text_size(px(24.0))
                    .text_color(palette.ink)
                    .child(translate(language, Key::AppSettingsTitle)),
            )
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap(space(1))
                    .p(space(2))
                    .rounded(px(RADIUS_LARGE))
                    .border_1()
                    .border_color(palette.line)
                    .bg(palette.card)
                    .child(
                        div()
                            .text_size(px(12.0))
                            .text_color(palette.ink_3)
                            .child(translate(language, Key::AppSettingsAccount)),
                    )
                    .child(
                        div()
                            .text_size(px(14.0))
                            .text_color(palette.ink)
                            .child(format!("{email} · {user_id}")),
                    )
                    .child(
                        div()
                            .text_size(px(12.0))
                            .text_color(palette.ink_3)
                            .child(format!(
                                "{} {workspace}",
                                translate(language, Key::AppSettingsWorkspace)
                            )),
                    )
                    .child(
                        div()
                            .text_size(px(11.0))
                            .text_color(palette.ink_3)
                            .child(format!(
                                "{} {}",
                                translate(language, Key::AppSettingsBuild),
                                crate::build_info::about_line()
                            )),
                    ),
            )
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap(space(1))
                    .child(
                        div()
                            .text_size(px(12.0))
                            .text_color(palette.ink_3)
                            .child(translate(language, Key::AppSettingsRevokeHint)),
                    )
                    .children(error)
                    .child(revoke),
            )
            .into_any_element()
    }

    fn render_workspace_empty(
        &mut self,
        language: Language,
        palette: &theme::Palette,
    ) -> AnyElement {
        div()
            .flex()
            .flex_col()
            .gap(space(2))
            .child(
                div()
                    .text_size(px(24.0))
                    .text_color(palette.ink)
                    .child(translate(language, Key::AppSettingsTitle)),
            )
            .child(
                div()
                    .text_size(px(14.0))
                    .text_color(palette.ink)
                    .child(translate(language, Key::AppWorkspaceEmptyTitle)),
            )
            .child(
                div()
                    .text_size(px(12.0))
                    .text_color(palette.ink_3)
                    .child(translate(language, Key::AppWorkspaceEmptyGuidance)),
            )
            .into_any_element()
    }

    fn render_workspace_switcher(
        &mut self,
        language: Language,
        palette: &theme::Palette,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let label = self
            .workspaces
            .current()
            .map(|workspace| workspace.name.clone())
            .unwrap_or_else(|| translate(language, Key::AppWorkspaceSwitch).to_string());
        div()
            .id("workspace-menu-toggle")
            .role(Role::Button)
            .aria_label(translate(language, Key::AppWorkspaceSwitch))
            .flex()
            .items_center()
            .gap(px(4.0))
            .px(space(1))
            .py(px(2.0))
            .rounded(px(RADIUS_SMALL))
            .hover(|style| style.bg(palette.soft))
            .child(
                div()
                    .text_size(px(12.0))
                    .text_color(palette.ink_2)
                    .child(label),
            )
            .child(
                Icon::default()
                    .path(AssetIcon::ChevronDown.path())
                    .text_color(palette.ink_3)
                    .with_size(px(12.0)),
            )
            .on_click(cx.listener(|this, _, _, cx| {
                this.workspace_menu_open = !this.workspace_menu_open;
                this.breadcrumb_menu = None;
                cx.notify();
            }))
            .into_any_element()
    }

    /// 工作台下拉（根级 overlay，避免被内容区覆盖）。
    fn render_workspace_menu(
        &mut self,
        language: Language,
        palette: &theme::Palette,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let state = self.workspaces.state().clone();
        let current = self.workspaces.current().cloned();
        let workspaces = self.workspaces.workspaces().to_vec();
        let body: AnyElement = match state {
            WorkspaceListState::Idle | WorkspaceListState::Loading => div()
                .px(space(1))
                .py(px(4.0))
                .text_size(px(12.0))
                .text_color(palette.ink_3)
                .child(translate(language, Key::AppWorkspaceLoading))
                .into_any_element(),
            WorkspaceListState::Failed(_) => div()
                .px(space(1))
                .py(px(4.0))
                .text_size(px(12.0))
                .text_color(palette.danger)
                .child(translate(language, Key::AppWorkspaceError))
                .into_any_element(),
            WorkspaceListState::Empty => div()
                .px(space(1))
                .py(px(4.0))
                .text_size(px(12.0))
                .text_color(palette.ink_3)
                .child(translate(language, Key::AppWorkspaceEmpty))
                .into_any_element(),
            WorkspaceListState::Ready => div()
                .flex()
                .flex_col()
                .children(workspaces.iter().map(|workspace| {
                    let selected = current
                        .as_ref()
                        .is_some_and(|current| current.id == workspace.id);
                    let workspace_id = workspace.id.clone();
                    let roles = workspace
                        .my_role_names
                        .iter()
                        .map(|role| workspace_role_label(language, role))
                        .collect::<Vec<_>>()
                        .join(" · ");
                    div()
                        .id(format!("workspace-option-{}", workspace.id))
                        .flex()
                        .flex_col()
                        .gap(px(2.0))
                        .px(space(1))
                        .py(px(6.0))
                        .rounded(px(RADIUS_SMALL))
                        .hover(|style| style.bg(palette.soft))
                        .child(
                            div()
                                .flex()
                                .flex_row()
                                .items_center()
                                .justify_between()
                                .child(div().text_color(palette.ink).child(workspace.name.clone()))
                                .child(div().text_color(palette.accent).child(if selected {
                                    "✓"
                                } else {
                                    ""
                                })),
                        )
                        .children((!roles.is_empty()).then(|| {
                            div()
                                .text_size(px(11.0))
                                .text_color(palette.ink_3)
                                .child(roles)
                                .into_any_element()
                        }))
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.switch_workspace(&workspace_id, cx);
                            this.workspace_menu_open = false;
                            cx.notify();
                        }))
                        .into_any_element()
                }))
                .into_any_element(),
        };
        div()
            .id("workspace-menu")
            .absolute()
            .top(px(72.0))
            .left(px(120.0))
            .w(px(260.0))
            .flex()
            .flex_col()
            .gap(px(2.0))
            .p(space(1))
            .rounded(px(RADIUS_MEDIUM))
            .border_1()
            .border_color(palette.line_strong)
            .bg(palette.card)
            .occlude()
            .child(
                div()
                    .px(space(1))
                    .py(px(3.0))
                    .text_size(px(10.0))
                    .text_color(palette.ink_3)
                    .child(translate(language, Key::AppWorkspaceSwitch)),
            )
            .child(body)
            .into_any_element()
    }

    fn render_enrollment_area(
        &mut self,
        language: Language,
        palette: &theme::Palette,
        detail: &EventDetail,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        if let Some(enrollment) = self.detail.enrollment().cloned() {
            let status = div()
                .flex()
                .flex_row()
                .items_center()
                .gap(space(1))
                .text_size(px(12.0))
                .text_color(palette.ink_2)
                .child(enroll_status_label(language, enrollment.status.as_str()));
            if enrollment.status != "payment_pending" {
                let paid_notice = matches!(self.payment, PaymentViewState::Paid).then(|| {
                    div()
                        .text_size(px(12.0))
                        .text_color(palette.accent)
                        .child(translate(language, Key::EventsPayPaid))
                        .into_any_element()
                });
                let check_in = (detail.deposit_enabled && enrollment.status == "confirmed")
                    .then(|| enrollment.check_in_code.clone())
                    .flatten()
                    .map(|code| {
                        let content = format!("cgc2046:checkin:{}:{code}", detail.id);
                        let qr = encode_qr(&content)
                            .map(|matrix| render_qr(&matrix, black(), white(), px(160.0)))
                            .unwrap_or_else(|_| {
                                div()
                                    .text_color(palette.danger)
                                    .child(translate(language, Key::EventsPayFailed))
                                    .into_any_element()
                            });
                        div()
                            .flex()
                            .flex_col()
                            .gap(px(4.0))
                            .child(
                                div()
                                    .text_size(px(12.0))
                                    .text_color(palette.ink_3)
                                    .child(translate(language, Key::EventsCheckinTitle)),
                            )
                            .child(qr)
                            .child(div().text_size(px(12.0)).text_color(palette.ink_2).child(
                                format!("{} {code}", translate(language, Key::EventsCheckinCode)),
                            ))
                            .into_any_element()
                    });
                return div()
                    .mt(space(2))
                    .flex()
                    .flex_col()
                    .gap(px(2.0))
                    .text_size(px(12.0))
                    .text_color(palette.ink_2)
                    .child(enroll_status_label(language, enrollment.status.as_str()))
                    .children(paid_notice)
                    .children(check_in)
                    .into_any_element();
            }

            let payment_body: AnyElement = match self.payment.clone() {
                PaymentViewState::Idle | PaymentViewState::Failed(_) => {
                    let deposit = detail.deposit_enabled;
                    let consent = self.deposit_consent;
                    let failed = match &self.payment {
                        PaymentViewState::Failed(message) => Some(message.clone()),
                        _ => None,
                    };
                    div()
                        .flex()
                        .flex_col()
                        .gap(space(1))
                        .child(
                            div()
                                .text_size(px(12.0))
                                .text_color(palette.ink_3)
                                .child(translate(language, Key::EventsPayChooseChannel)),
                        )
                        .child(
                            div()
                                .flex()
                                .flex_row()
                                .gap(space(1))
                                .child(
                                    div()
                                        .id("pay-wechat")
                                        .px(space(2))
                                        .py(px(5.0))
                                        .rounded(px(RADIUS_MEDIUM))
                                        .bg(palette.accent)
                                        .text_color(palette.canvas)
                                        .child(translate(language, Key::EventsPayWechat))
                                        .on_click(cx.listener(|this, _, _, cx| {
                                            this.start_payment("wechat_native", cx);
                                        })),
                                )
                                .child(
                                    div()
                                        .id("pay-alipay")
                                        .px(space(2))
                                        .py(px(5.0))
                                        .rounded(px(RADIUS_MEDIUM))
                                        .bg(palette.soft)
                                        .text_color(palette.ink_2)
                                        .child(translate(language, Key::EventsPayAlipay))
                                        .on_click(cx.listener(|this, _, _, cx| {
                                            this.start_payment("alipay_qr", cx);
                                        })),
                                ),
                        )
                        .children((deposit).then(|| {
                            div()
                                .id("pay-deposit-consent")
                                .flex()
                                .flex_row()
                                .items_center()
                                .gap(px(4.0))
                                .text_size(px(12.0))
                                .text_color(palette.ink_2)
                                .child(if consent { "☑" } else { "☐" })
                                .child(translate(language, Key::EventsPayDepositConsent))
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.deposit_consent = !this.deposit_consent;
                                    cx.notify();
                                }))
                                .into_any_element()
                        }))
                        .children(failed.map(|message| {
                            let text = if message == "deposit_consent" {
                                translate(language, Key::EventsPayDepositConsent)
                            } else {
                                translate(language, Key::EventsPayFailed)
                            };
                            div()
                                .text_size(px(12.0))
                                .text_color(palette.danger)
                                .child(text)
                                .into_any_element()
                        }))
                        .into_any_element()
                }
                PaymentViewState::Creating => div()
                    .text_size(px(12.0))
                    .text_color(palette.ink_3)
                    .child(translate(language, Key::EventsPayCreating))
                    .into_any_element(),
                PaymentViewState::Qr { url, expire_at, .. } => {
                    let qr_element: AnyElement = match encode_qr(&url) {
                        Ok(matrix) => render_qr(&matrix, black(), white(), px(200.0)),
                        Err(QrError::Empty | QrError::TooLong | QrError::Encode(_)) => div()
                            .text_color(palette.danger)
                            .child(translate(language, Key::EventsPayFailed))
                            .into_any_element(),
                    };
                    let remaining = expire_at
                        .as_deref()
                        .and_then(payment_remaining_secs)
                        .map(|seconds| format!("{:02}:{:02}", seconds / 60, seconds % 60));
                    div()
                        .flex()
                        .flex_col()
                        .items_start()
                        .gap(space(1))
                        .child(qr_element)
                        .child(
                            div()
                                .text_size(px(12.0))
                                .text_color(palette.ink_2)
                                .child(translate(language, Key::EventsPayScanHint)),
                        )
                        .children(remaining.map(|remaining| {
                            div()
                                .text_size(px(12.0))
                                .text_color(palette.ink_3)
                                .child(format!(
                                    "{} {remaining}",
                                    translate(language, Key::EventsPayRemaining)
                                ))
                                .into_any_element()
                        }))
                        .child(
                            div()
                                .id("pay-close")
                                .px(space(1))
                                .py(px(3.0))
                                .rounded(px(RADIUS_SMALL))
                                .bg(palette.soft)
                                .text_size(px(12.0))
                                .text_color(palette.ink_2)
                                .child(translate(language, Key::EventsPayClose))
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.close_payment(cx);
                                })),
                        )
                        .into_any_element()
                }
                PaymentViewState::Terminal(status) => div()
                    .text_size(px(12.0))
                    .text_color(palette.danger)
                    .child(terminal_status_label(language, &status))
                    .into_any_element(),
                PaymentViewState::Paid => div()
                    .text_size(px(12.0))
                    .text_color(palette.accent)
                    .child(translate(language, Key::EventsPayPaid))
                    .into_any_element(),
            };

            let cancel = div()
                .id("enroll-cancel")
                .px(space(1))
                .py(px(3.0))
                .rounded(px(RADIUS_SMALL))
                .bg(palette.soft)
                .text_size(px(12.0))
                .text_color(palette.ink_3)
                .child(translate(language, Key::EventsEnrollCancel))
                .on_click(cx.listener(|this, _, _, cx| {
                    this.cancel_enrollment_action(cx);
                }));
            return div()
                .mt(space(2))
                .flex()
                .flex_col()
                .gap(space(1))
                .child(status)
                .child(payment_body)
                .child(cancel)
                .into_any_element();
        }

        if detail.enrollment_policy == "invite_only" {
            return div()
                .mt(space(2))
                .text_size(px(12.0))
                .text_color(palette.ink_3)
                .child(translate(language, Key::EventsEnrollInviteRequired))
                .into_any_element();
        }
        if detail.status != "open" {
            return div()
                .mt(space(2))
                .text_size(px(12.0))
                .text_color(palette.danger)
                .child(translate(language, Key::EventsEnrollErrorNotOpen))
                .into_any_element();
        }

        let selected_tier = self.selected_tier.clone();
        let tier_chips: Vec<AnyElement> = detail
            .available_price_tiers
            .iter()
            .map(|tier| {
                let selected = selected_tier.as_deref() == Some(tier.id.as_str());
                let tier_id = tier.id.clone();
                div()
                    .id(format!("enroll-tier-{}", tier.id))
                    .px(space(1))
                    .py(px(3.0))
                    .rounded(px(RADIUS_SMALL))
                    .text_size(px(12.0))
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
                    .child(format!(
                        "{} ¥{:.2}",
                        tier.name,
                        tier.amount_cents as f64 / 100.0
                    ))
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.selected_tier = Some(tier_id.clone());
                        cx.notify();
                    }))
                    .into_any_element()
            })
            .collect();

        let age_confirm = detail.min_age.map(|min_age| {
            let checked = self.age_confirmed;
            div()
                .id("enroll-age-confirm")
                .flex()
                .flex_row()
                .items_center()
                .gap(px(4.0))
                .text_size(px(12.0))
                .text_color(palette.ink_2)
                .child(if checked { "☑" } else { "☐" })
                .child(format!(
                    "{} ({min_age}+)",
                    translate(language, Key::EventsEnrollAgeConfirm)
                ))
                .on_click(cx.listener(|this, _, _, cx| {
                    this.age_confirmed = !this.age_confirmed;
                    cx.notify();
                }))
                .into_any_element()
        });

        let error = self.enrollment_error.as_deref().map(|suffix| {
            div()
                .text_size(px(12.0))
                .text_color(palette.danger)
                .child(enroll_error_label(language, suffix))
                .into_any_element()
        });

        let submit = div()
            .id("events-enroll-button")
            .px(space(2))
            .py(px(6.0))
            .rounded(px(RADIUS_MEDIUM))
            .bg(if self.enrolling {
                palette.soft
            } else {
                palette.accent
            })
            .text_color(if self.enrolling {
                palette.ink_3
            } else {
                palette.canvas
            })
            .child(if self.enrolling {
                translate(language, Key::EventsEnrollEnrolling)
            } else {
                translate(language, Key::EventsEnrollButton)
            })
            .on_click(cx.listener(|this, _, _, cx| {
                this.submit_enrollment(cx);
            }));

        div()
            .mt(space(2))
            .flex()
            .flex_col()
            .gap(space(1))
            .children((detail.pricing_enabled && !tier_chips.is_empty()).then(|| {
                div()
                    .flex()
                    .flex_col()
                    .gap(px(4.0))
                    .child(
                        div()
                            .text_size(px(12.0))
                            .text_color(palette.ink_3)
                            .child(translate(language, Key::EventsEnrollTier)),
                    )
                    .children(tier_chips)
                    .into_any_element()
            }))
            .children(age_confirm)
            .children(error)
            .child(submit)
            .into_any_element()
    }

    fn render_courses_list(
        &mut self,
        language: Language,
        palette: &theme::Palette,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let state = self.courses.state().clone();
        let items = self.courses.items().to_vec();
        let has_more = self.courses.has_more();

        let body: AnyElement = match state {
            CoursesListState::Idle | CoursesListState::Loading => div()
                .text_color(palette.ink_3)
                .child(translate(language, Key::CoursesCatalogLoading))
                .into_any_element(),
            CoursesListState::Failed(message) => div()
                .flex()
                .flex_col()
                .gap(space(1))
                .child(div().text_color(palette.danger).child(message))
                .child(
                    div()
                        .id("courses-retry")
                        .px(space(2))
                        .py(px(5.0))
                        .rounded(px(RADIUS_MEDIUM))
                        .bg(palette.accent)
                        .text_color(white())
                        .child(translate(language, Key::CoursesCatalogRetry))
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.courses.retry_ready();
                            this.start_courses_load(cx, true);
                        })),
                )
                .into_any_element(),
            CoursesListState::Empty => div()
                .text_color(palette.ink_3)
                .child(translate(language, Key::CoursesCatalogEmpty))
                .into_any_element(),
            CoursesListState::Ready => {
                let rows = items
                    .iter()
                    .map(|course| course_row(course, language, palette, cx))
                    .collect::<Vec<_>>();
                let load_more = has_more.then(|| {
                    div()
                        .id("courses-load-more")
                        .mt(space(2))
                        .px(space(2))
                        .py(px(5.0))
                        .rounded(px(RADIUS_MEDIUM))
                        .border_1()
                        .border_color(palette.line_strong)
                        .text_color(palette.ink_2)
                        .child(translate(language, Key::CoursesCatalogLoadMore))
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.start_courses_load(cx, false);
                        }))
                        .into_any_element()
                });
                div()
                    .flex()
                    .flex_col()
                    .children(rows)
                    .children(load_more)
                    .into_any_element()
            }
        };

        div()
            .flex()
            .flex_col()
            .gap(space(2))
            .child(
                div()
                    .text_size(px(24.0))
                    .text_color(palette.ink)
                    .child(translate_registered(language, "courses.catalog.title")),
            )
            .child(body)
            .into_any_element()
    }

    fn render_course_detail(
        &mut self,
        language: Language,
        palette: &theme::Palette,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let state = self.course_detail.state().clone();
        let detail = self.course_detail.detail().cloned();
        let course_id = self
            .current
            .as_ref()
            .and_then(|route_match| route_match.params.get("id"))
            .cloned()
            .unwrap_or_default();

        let back = div()
            .id("course-detail-back")
            .text_size(px(12.0))
            .text_color(palette.ink_3)
            .child(translate(language, Key::CoursesDetailBack))
            .on_click(cx.listener(|this, _, _, cx| {
                this.navigate("/courses");
                cx.notify();
            }));

        let body: AnyElement = match state {
            CoursesListState::Idle | CoursesListState::Loading => div()
                .text_color(palette.ink_3)
                .child(translate(language, Key::CoursesDetailLoading))
                .into_any_element(),
            CoursesListState::Failed(message) => {
                let not_found = message == "not found";
                div()
                    .flex()
                    .flex_col()
                    .gap(space(1))
                    .child(div().text_color(palette.danger).child(if not_found {
                        translate(language, Key::CoursesDetailNotFound)
                    } else {
                        translate(language, Key::CoursesDetailError)
                    }))
                    .children((!not_found).then(|| {
                        div()
                            .id("course-detail-retry")
                            .px(space(2))
                            .py(px(5.0))
                            .rounded(px(RADIUS_MEDIUM))
                            .bg(palette.accent)
                            .text_color(white())
                            .child(translate(language, Key::CoursesDetailRetry))
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.course_detail.retry_ready();
                                this.course_detail_started = false;
                                cx.notify();
                            }))
                            .into_any_element()
                    }))
                    .into_any_element()
            }
            CoursesListState::Empty => div()
                .text_color(palette.ink_3)
                .child(translate(language, Key::CoursesDetailNotFound))
                .into_any_element(),
            CoursesListState::Ready => match detail {
                Some(detail) => {
                    let enrolled = detail.enrollment_status.as_deref() == Some("confirmed");
                    let action = if enrolled {
                        let target = course_id.clone();
                        div()
                            .flex()
                            .flex_col()
                            .gap(px(4.0))
                            .child(
                                div()
                                    .id("course-start-learning")
                                    .px(space(2))
                                    .py(px(6.0))
                                    .rounded(px(RADIUS_MEDIUM))
                                    .bg(palette.accent)
                                    .text_color(white())
                                    .child(translate(language, Key::CoursesDetailEnrolled))
                                    .on_click(cx.listener(move |this, _, _, cx| {
                                        this.navigate_to_learning(&target);
                                        cx.notify();
                                    })),
                            )
                            .child(
                                div()
                                    .text_size(px(11.0))
                                    .text_color(palette.ink_3)
                                    .child(translate(language, Key::CoursesLearningKeyboardHint)),
                            )
                            .into_any_element()
                    } else {
                        div()
                            .px(space(2))
                            .py(px(6.0))
                            .rounded(px(RADIUS_MEDIUM))
                            .bg(palette.soft)
                            .text_color(palette.ink_3)
                            .child(translate(language, Key::CoursesDetailNotEnrolled))
                            .into_any_element()
                    };

                    div()
                        .flex()
                        .flex_col()
                        .gap(space(2))
                        .child(
                            div()
                                .text_size(px(24.0))
                                .text_color(palette.ink)
                                .child(detail.title.clone()),
                        )
                        .children(detail.description.clone().map(|description| {
                            div()
                                .text_color(palette.ink_2)
                                .child(description)
                                .into_any_element()
                        }))
                        .child(
                            div()
                                .flex()
                                .flex_row()
                                .items_center()
                                .gap(space(2))
                                .child(
                                    div()
                                        .px(space(1))
                                        .py(px(3.0))
                                        .rounded(px(RADIUS_SMALL))
                                        .bg(palette.soft)
                                        .text_size(px(12.0))
                                        .text_color(palette.ink_2)
                                        .child(status_label(language, detail.status.as_str())),
                                )
                                .child(
                                    div()
                                        .px(space(1))
                                        .py(px(3.0))
                                        .rounded(px(RADIUS_SMALL))
                                        .bg(palette.soft)
                                        .text_size(px(12.0))
                                        .text_color(palette.ink_2)
                                        .child(if detail.pricing_enabled {
                                            translate(language, Key::EventsDetailPaid)
                                        } else {
                                            translate(language, Key::EventsDetailFree)
                                        }),
                                ),
                        )
                        .child(action)
                        .into_any_element()
                }
                None => div()
                    .text_color(palette.ink_3)
                    .child(translate(language, Key::CoursesDetailNotFound))
                    .into_any_element(),
            },
        };

        div()
            .flex()
            .flex_col()
            .gap(space(2))
            .child(back)
            .child(body)
            .into_any_element()
    }

    fn render_course_learning(
        &mut self,
        language: Language,
        palette: &theme::Palette,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let state = self.course_detail.state().clone();
        let detail = self.course_detail.detail().cloned();
        let course_id = self
            .current
            .as_ref()
            .and_then(|route_match| route_match.params.get("id"))
            .cloned()
            .unwrap_or_default();
        let user_id = self
            .session
            .signed_in()
            .map(|session| session.user_id.clone());

        let back = div()
            .id("course-learning-back")
            .text_size(px(12.0))
            .text_color(palette.ink_3)
            .child(translate(language, Key::CoursesDetailBack))
            .on_click(cx.listener(move |this, _, _, cx| {
                this.navigate(&format!("/courses/{course_id}"));
                cx.notify();
            }));

        let body: AnyElement = match state {
            CoursesListState::Idle | CoursesListState::Loading => div()
                .text_color(palette.ink_3)
                .child(translate(language, Key::CoursesLearningLoading))
                .into_any_element(),
            CoursesListState::Failed(message) => div()
                .flex()
                .flex_col()
                .gap(space(1))
                .child(div().text_color(palette.danger).child(message))
                .child(
                    div()
                        .id("course-learning-retry")
                        .px(space(2))
                        .py(px(5.0))
                        .rounded(px(RADIUS_MEDIUM))
                        .bg(palette.accent)
                        .text_color(white())
                        .child(translate(language, Key::CoursesLearningRetry))
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.course_detail.retry_ready();
                            this.course_detail_started = false;
                            cx.notify();
                        })),
                )
                .into_any_element(),
            CoursesListState::Empty => div()
                .text_color(palette.ink_3)
                .child(translate(language, Key::CoursesDetailNotFound))
                .into_any_element(),
            CoursesListState::Ready => match detail {
                Some(detail) => match learning_context(user_id, &detail) {
                    Ok(context) => div()
                        .flex()
                        .flex_col()
                        .gap(space(2))
                        .child(
                            div()
                                .text_size(px(24.0))
                                .text_color(palette.ink)
                                .child(detail.title.clone()),
                        )
                        .child(
                            div()
                                .flex()
                                .flex_row()
                                .gap(space(2))
                                .text_size(px(12.0))
                                .text_color(palette.ink_3)
                                .child(format!(
                                    "{} {}",
                                    translate(language, Key::CoursesLearningWorkspace),
                                    context.workspace_id
                                ))
                                .child(format!(
                                    "{} {}",
                                    translate(language, Key::CoursesLearningRevision),
                                    context.course_revision_id
                                )),
                        )
                        .child(self.render_learning_projection(language, palette, cx))
                        .child(self.render_course_materials(language, palette, cx))
                        .into_any_element(),
                    Err(_) => div()
                        .px(space(2))
                        .py(px(6.0))
                        .rounded(px(RADIUS_MEDIUM))
                        .bg(palette.soft)
                        .text_color(palette.danger)
                        .child(translate(language, Key::CoursesLearningContextRequired))
                        .into_any_element(),
                },
                None => div()
                    .text_color(palette.ink_3)
                    .child(translate(language, Key::CoursesDetailNotFound))
                    .into_any_element(),
            },
        };

        div()
            .flex()
            .flex_col()
            .gap(space(2))
            .child(back)
            .child(body)
            .into_any_element()
    }

    fn render_events_list(
        &mut self,
        language: Language,
        palette: &theme::Palette,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let filter = self.events.filter();
        let state = self.events.state().clone();
        let items = self.events.items().to_vec();
        let has_more = self.events.has_more();
        let selected = self.selected_event.clone();

        let filters = StatusFilter::ALL
            .iter()
            .map(|candidate| {
                let candidate = *candidate;
                let active = candidate == filter;
                div()
                    .id(format!("events-filter-{:?}", candidate).to_lowercase())
                    .px(space(1))
                    .py(px(3.0))
                    .rounded(px(RADIUS_MEDIUM))
                    .text_size(px(12.0))
                    .text_color(if active {
                        palette.canvas
                    } else {
                        palette.ink_2
                    })
                    .bg(if active { palette.accent } else { palette.soft })
                    .child(translate(language, filter_key(candidate)))
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.select_events_filter(candidate, cx);
                    }))
                    .into_any_element()
            })
            .collect::<Vec<_>>();

        let body: AnyElement = match state {
            ListState::Idle | ListState::Loading => div()
                .text_color(palette.ink_3)
                .child(translate(language, Key::EventsListLoading))
                .into_any_element(),
            ListState::Failed(message) => div()
                .flex()
                .flex_col()
                .gap(space(1))
                .child(div().text_color(palette.danger).child(message))
                .child(
                    div()
                        .id("events-retry")
                        .px(space(2))
                        .py(px(5.0))
                        .rounded(px(RADIUS_MEDIUM))
                        .bg(palette.accent)
                        .text_color(white())
                        .child(translate(language, Key::EventsListRetry))
                        .on_click(cx.listener(|this, _, _, cx| this.retry_events(cx))),
                )
                .into_any_element(),
            ListState::Empty => div()
                .text_color(palette.ink_3)
                .child(translate(language, Key::EventsListEmpty))
                .into_any_element(),
            ListState::Ready => {
                let rows = items
                    .iter()
                    .map(|event| {
                        let event = event.clone();
                        let starts = event
                            .starts_at
                            .as_deref()
                            .map(|value| value.chars().take(10).collect::<String>())
                            .unwrap_or_default();
                        let price = if event.pricing_enabled {
                            translate(language, Key::EventsListPaid)
                        } else {
                            translate(language, Key::EventsListFree)
                        };
                        div()
                            .id(format!("event-row-{}", event.id))
                            .flex()
                            .flex_row()
                            .items_center()
                            .justify_between()
                            .gap(space(2))
                            .px(space(2))
                            .py(space(1))
                            .border_b_1()
                            .border_color(palette.line)
                            .hover(|style| style.bg(palette.soft))
                            .child(
                                div()
                                    .flex()
                                    .flex_col()
                                    .gap(px(2.0))
                                    .child(div().text_color(palette.ink).child(event.title.clone()))
                                    .child(
                                        div()
                                            .text_size(px(11.0))
                                            .text_color(palette.ink_3)
                                            .child(format!("{starts} · {price}")),
                                    ),
                            )
                            .child(
                                div()
                                    .flex()
                                    .items_center()
                                    .gap(space(1))
                                    .child(
                                        div()
                                            .px(px(6.0))
                                            .py(px(2.0))
                                            .rounded(px(RADIUS_SMALL))
                                            .bg(palette.soft)
                                            .text_size(px(11.0))
                                            .text_color(palette.ink_2)
                                            .child(translate(
                                                language,
                                                status_key(event.status.as_str()),
                                            )),
                                    )
                                    .child(
                                        div().text_size(px(11.0)).text_color(palette.ink_3).child(
                                            match (event.confirmed_count, event.capacity) {
                                                (Some(confirmed), Some(capacity)) => {
                                                    format!("{confirmed}/{capacity}")
                                                }
                                                (Some(confirmed), None) => {
                                                    format!("{confirmed}/∞")
                                                }
                                                _ => String::new(),
                                            },
                                        ),
                                    ),
                            )
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.navigate_to_event_detail(&event.id);
                                cx.notify();
                            }))
                            .into_any_element()
                    })
                    .collect::<Vec<_>>();

                let detail_notice = selected.map(|title| {
                    div()
                        .mt(space(2))
                        .text_size(px(12.0))
                        .text_color(palette.ink_3)
                        .child(format!(
                            "{title} — {}",
                            translate(language, Key::EventsListDetail)
                        ))
                        .into_any_element()
                });

                let load_more = has_more.then(|| {
                    div()
                        .id("events-load-more")
                        .mt(space(2))
                        .px(space(2))
                        .py(px(5.0))
                        .rounded(px(RADIUS_MEDIUM))
                        .border_1()
                        .border_color(palette.line_strong)
                        .text_color(palette.ink_2)
                        .child(translate(language, Key::EventsListLoadMore))
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.start_events_load(cx, false);
                        }))
                        .into_any_element()
                });

                div()
                    .flex()
                    .flex_col()
                    .children(rows)
                    .children(load_more)
                    .children(detail_notice)
                    .into_any_element()
            }
        };

        div()
            .flex()
            .flex_col()
            .gap(space(2))
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .justify_between()
                    .child(
                        div()
                            .text_size(px(24.0))
                            .text_color(palette.ink)
                            .child(translate_registered(language, "events.list.title")),
                    )
                    .child(
                        div()
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap(space(1))
                            .children(filters),
                    ),
            )
            .child(body)
            .into_any_element()
    }

    #[allow(clippy::too_many_arguments)]
    fn render_footer(
        &self,
        language: Language,
        include_nav: bool,
        theme_icon: AssetIcon,
        theme_label: &'static str,
        theme_tooltip: &'static str,
        language_icon: AssetIcon,
        language_label: &'static str,
        language_tooltip: &'static str,
        palette: &theme::Palette,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        // 左侧：一级导航图标；右侧：主题/语言工具。版本号只放设置/关于，不进 footer。
        let shortcut = if cfg!(target_os = "macos") {
            "⌘J"
        } else {
            "Ctrl+J"
        };
        let agent_toggle = include_nav.then(|| {
            div()
                .id("agent-panel-toggle")
                .role(Role::Button)
                .aria_label(translate(language, Key::AgentChatPanelTitle))
                .size(px(22.0))
                .rounded(px(RADIUS_MEDIUM))
                .flex()
                .items_center()
                .justify_center()
                .text_color(if self.agent_panel_open {
                    palette.accent
                } else {
                    palette.ink_3
                })
                .hover(|style| style.bg(palette.soft))
                .child(
                    Icon::default()
                        .path(nav_icon(NavIcon::Companion).path())
                        .text_color(if self.agent_panel_open {
                            palette.accent
                        } else {
                            palette.ink_3
                        })
                        .small(),
                )
                .tooltip(move |_, cx| {
                    cx.new(|_| TooltipText {
                        text: format!(
                            "{} · {shortcut}",
                            translate(language, Key::AgentChatPanelTitle)
                        )
                        .into(),
                    })
                    .into()
                })
                .on_click(cx.listener(|this, _, _, cx| {
                    this.toggle_agent_panel(cx);
                }))
                .into_any_element()
        });
        div()
            .flex()
            .flex_row()
            .items_center()
            .h(px(30.0))
            .px(space(2))
            .bg(palette.frame)
            .border_t_1()
            .border_color(palette.line)
            .text_size(px(12.0))
            .children(agent_toggle)
            .child(div().flex_1())
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap(px(2.0))
                    .child(
                        div()
                            .id("theme-toggle")
                            .size(px(22.0))
                            .rounded(px(RADIUS_MEDIUM))
                            .flex()
                            .items_center()
                            .justify_center()
                            .text_color(palette.ink_3)
                            .hover(|style| style.bg(palette.soft))
                            .child(
                                Icon::default()
                                    .path(theme_icon.path())
                                    .text_color(palette.ink_3)
                                    .small(),
                            )
                            .tooltip(move |_, cx| {
                                cx.new(|_| TooltipText {
                                    text: format!("{theme_tooltip} · {theme_label}").into(),
                                })
                                .into()
                            })
                            .on_click(cx.listener(|this, _, window, cx| {
                                let preference = this.cycle_theme();
                                let mode = theme::resolve(preference, window.appearance());
                                theme::apply(mode, cx);
                                cx.notify();
                            })),
                    )
                    .child(
                        div()
                            .id("language-toggle")
                            .size(px(22.0))
                            .rounded(px(RADIUS_MEDIUM))
                            .flex()
                            .items_center()
                            .justify_center()
                            .text_color(palette.ink_3)
                            .hover(|style| style.bg(palette.soft))
                            .child(
                                Icon::default()
                                    .path(language_icon.path())
                                    .text_color(palette.ink_3)
                                    .small(),
                            )
                            .tooltip(move |_, cx| {
                                cx.new(|_| TooltipText {
                                    text: format!("{language_tooltip} · {language_label}").into(),
                                })
                                .into()
                            })
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.toggle_language();
                                cx.notify();
                            })),
                    ),
            )
            .into_any_element()
    }
}

/// 悬停 tooltip 的内容视图（footer 图标按钮使用）。
struct TooltipText {
    text: SharedString,
}

impl Render for TooltipText {
    fn render(&mut self, _window: &mut Window, _cx: &mut Context<Self>) -> impl IntoElement {
        div()
            .px(px(8.0))
            .py(px(4.0))
            .rounded(px(4.0))
            .bg(rgba(0x1f_20_22_f2))
            .text_color(hsla_white())
            .text_size(px(11.0))
            .child(self.text.clone())
    }
}

fn initial_route(registry: &RouteRegistry) -> Option<RouteMatch> {
    if let Ok(path) = std::env::var("CGC_START_PATH") {
        if let crate::routing::RouteSelection::Match(route_match) = registry.select(&path) {
            return Some(route_match);
        }
    }
    if let Ok(route_id) = std::env::var("CGC_START_ROUTE") {
        if let Some(route) = registry.find(&route_id) {
            return Some(RouteMatch {
                route,
                params: std::collections::BTreeMap::new(),
            });
        }
    }
    registry.routes().first().copied().map(|route| RouteMatch {
        route,
        params: std::collections::BTreeMap::new(),
    })
}

fn build_courses_service() -> CourseCatalogService {
    let use_http =
        std::env::var("CGC_AUTH").as_deref() == Ok("http") || std::env::var("CGC_API_URL").is_ok();
    let api: Arc<dyn CoursesApi> = if use_http {
        Arc::new(HttpCoursesApi::from_env())
    } else {
        Arc::new(FakeCoursesApi::with_seed(15))
    };
    CourseCatalogService::new(api)
}

fn status_label(language: Language, status: &str) -> &'static str {
    translate(
        language,
        match status {
            "open" => Key::EventsStatusOpen,
            "closed" => Key::EventsStatusClosed,
            "cancelled" => Key::EventsStatusCancelled,
            _ => Key::EventsStatusDraft,
        },
    )
}

fn course_row(
    course: &CourseSummary,
    language: Language,
    palette: &theme::Palette,
    cx: &mut Context<RootView>,
) -> AnyElement {
    let starts = course
        .starts_at
        .as_deref()
        .map(|value| value.chars().take(10).collect::<String>())
        .unwrap_or_default();
    let price = if course.pricing_enabled {
        translate(language, Key::EventsListPaid)
    } else {
        translate(language, Key::EventsListFree)
    };
    let course_id = course.id.clone();
    div()
        .id(format!("course-row-{}", course.id))
        .flex()
        .flex_row()
        .items_center()
        .justify_between()
        .gap(space(2))
        .px(space(2))
        .py(space(1))
        .border_b_1()
        .border_color(palette.line)
        .hover(|style| style.bg(palette.soft))
        .child(
            div()
                .flex()
                .flex_col()
                .gap(px(2.0))
                .child(div().text_color(palette.ink).child(course.title.clone()))
                .child(
                    div()
                        .text_size(px(11.0))
                        .text_color(palette.ink_3)
                        .child(format!("{starts} · {price}")),
                ),
        )
        .child(
            div()
                .px(px(6.0))
                .py(px(2.0))
                .rounded(px(RADIUS_SMALL))
                .bg(palette.soft)
                .text_size(px(11.0))
                .text_color(palette.ink_2)
                .child(status_label(language, course.status.as_str())),
        )
        .on_click(cx.listener(move |this, _, _, cx| {
            this.navigate_to_course_detail(&course_id);
            cx.notify();
        }))
        .into_any_element()
}

fn build_learning_host_api() -> Arc<dyn LearningHostApi> {
    let use_http =
        std::env::var("CGC_AUTH").as_deref() == Ok("http") || std::env::var("CGC_API_URL").is_ok();
    if use_http {
        Arc::new(HttpLearningHostApi::from_env())
    } else {
        Arc::new(FakeLearningHostApi::default())
    }
}

fn build_learning_host_vault() -> Arc<dyn SecretVault> {
    let use_http =
        std::env::var("CGC_AUTH").as_deref() == Ok("http") || std::env::var("CGC_API_URL").is_ok();
    if use_http {
        Arc::new(KeychainVault::from_env())
    } else {
        Arc::new(MemoryVault::default())
    }
}

fn build_enrollments_api() -> Arc<dyn EnrollmentsApi> {
    let use_http =
        std::env::var("CGC_AUTH").as_deref() == Ok("http") || std::env::var("CGC_API_URL").is_ok();
    if use_http {
        Arc::new(HttpEnrollmentsApi::from_env())
    } else {
        Arc::new(FakeEnrollmentsApi)
    }
}

fn build_orders_api() -> Arc<dyn OrdersApi> {
    let use_http =
        std::env::var("CGC_AUTH").as_deref() == Ok("http") || std::env::var("CGC_API_URL").is_ok();
    if use_http {
        Arc::new(cgc_events::orders::HttpOrdersApi::from_env())
    } else {
        Arc::new(cgc_events::orders::FakeOrdersApi::demo())
    }
}

fn build_workspace_service() -> WorkspaceService {
    let use_http =
        std::env::var("CGC_AUTH").as_deref() == Ok("http") || std::env::var("CGC_API_URL").is_ok();
    let api: Arc<dyn WorkspaceApi> = if use_http {
        Arc::new(HttpWorkspaceApi::from_env())
    } else if std::env::var("CGC_WORKSPACE_EMPTY").as_deref() == Ok("1") {
        Arc::new(FakeWorkspaceApi::empty())
    } else {
        Arc::new(FakeWorkspaceApi::demo())
    };
    WorkspaceService::new(api)
}

fn workspace_role_label(language: Language, role: &str) -> &'static str {
    translate(
        language,
        match role {
            "owner" => Key::AppWorkspaceRoleOwner,
            "admin" => Key::AppWorkspaceRoleAdmin,
            "tutor" => Key::AppWorkspaceRoleTutor,
            "volunteer" => Key::AppWorkspaceRoleVolunteer,
            _ => Key::AppWorkspaceRoleLearner,
        },
    )
}

fn build_events_service() -> EventListService {
    let use_http =
        std::env::var("CGC_AUTH").as_deref() == Ok("http") || std::env::var("CGC_API_URL").is_ok();
    let api: Arc<dyn EventsApi> = if use_http {
        Arc::new(HttpEventsApi::from_env())
    } else {
        Arc::new(FakeEventsApi::with_seed(23))
    };
    EventListService::new(api)
}

fn status_key(status: &str) -> Key {
    match status {
        "open" => Key::EventsStatusOpen,
        "closed" => Key::EventsStatusClosed,
        "cancelled" => Key::EventsStatusCancelled,
        _ => Key::EventsStatusDraft,
    }
}

fn filter_key(filter: StatusFilter) -> Key {
    match filter {
        StatusFilter::All => Key::EventsFilterAll,
        StatusFilter::Open => Key::EventsFilterOpen,
        StatusFilter::Closed => Key::EventsFilterClosed,
        StatusFilter::Cancelled => Key::EventsFilterCancelled,
    }
}

fn version_at_least_24(version: &str) -> bool {
    version
        .split('.')
        .next()
        .and_then(|major| major.parse::<u64>().ok())
        .is_some_and(|major| major >= 24)
}

fn terminal_status_label(language: Language, status: &str) -> &'static str {
    translate(
        language,
        match status {
            "expired" => Key::EventsPayTerminalExpired,
            "cancelled" => Key::EventsPayTerminalCancelled,
            "refunded" => Key::EventsPayTerminalRefunded,
            "forfeited" => Key::EventsPayTerminalForfeited,
            "refunding" => Key::EventsPayTerminalRefunding,
            "refund_failed" => Key::EventsPayTerminalRefundFailed,
            _ => Key::EventsPayFailed,
        },
    )
}

fn payment_remaining_secs(expire_at: &str) -> Option<u64> {
    let expires = parse_rfc3339_epoch(expire_at)?;
    let now = SystemTime::now().duration_since(UNIX_EPOCH).ok()?.as_secs() as i64;
    u64::try_from(expires - now).ok()
}

fn enroll_status_label(language: Language, status: &str) -> &'static str {
    translate(
        language,
        match status {
            "confirmed" => Key::EventsEnrollStatusConfirmed,
            "pending" => Key::EventsEnrollStatusPending,
            "payment_pending" => Key::EventsEnrollStatusPaymentPending,
            "cancelled" => Key::EventsEnrollStatusCancelled,
            "rejected" => Key::EventsEnrollStatusRejected,
            "expired" => Key::EventsEnrollStatusExpired,
            _ => Key::EventsEnrollStatusPending,
        },
    )
}

fn enroll_error_label(language: Language, suffix: &str) -> &'static str {
    translate(
        language,
        match suffix {
            "duplicate" => Key::EventsEnrollErrorDuplicate,
            "not_open" => Key::EventsEnrollErrorNotOpen,
            "full" => Key::EventsEnrollErrorFull,
            "invite_required" => Key::EventsEnrollErrorInviteRequired,
            "tier_required" => Key::EventsEnrollErrorTierRequired,
            "tier_unavailable" => Key::EventsEnrollErrorTierUnavailable,
            "age_required" => Key::EventsEnrollErrorAgeRequired,
            "auth" => Key::EventsEnrollErrorAuth,
            _ => Key::EventsEnrollErrorGeneric,
        },
    )
}

fn nav_icon(icon: NavIcon) -> AssetIcon {
    match icon {
        NavIcon::Home => AssetIcon::House,
        NavIcon::Workspace => AssetIcon::LayoutDashboard,
        NavIcon::Events => AssetIcon::CalendarDays,
        NavIcon::Courses => AssetIcon::BookOpen,
        NavIcon::Companion => AssetIcon::BotMessageSquare,
    }
}

fn hsla_white() -> Hsla {
    rgba(0xff_ff_ff_ff).into()
}

#[cfg(test)]
mod tests {
    use super::RootView;
    use crate::i18n::{translate, Key, Language};
    use crate::registration::build_registry;
    use crate::theme::ThemePreference;
    use cgc_platform::session::{
        AuthError, FakeAuthApi, MemoryStore, SessionService, SignedInSession,
    };

    fn fake_signed_in() -> SignedInSession {
        SignedInSession {
            token: "fake-desktop-token".to_string(),
            user_id: "u-1".to_string(),
            email: Some("demo@example.com".to_string()),
            is_platform_admin: false,
        }
    }

    fn view() -> RootView {
        let session = SessionService::new(
            Box::new(FakeAuthApi::demo()),
            Box::new(MemoryStore::default()),
        );
        RootView::with_session(
            build_registry().expect("registry builds"),
            Language::Zh,
            ThemePreference::System,
            session,
        )
    }

    #[test]
    fn breadcrumb_sections_follow_route() {
        let mut view = view();
        view.navigate("/events");
        assert!(view
            .breadcrumb_context()
            .is_some_and(|(courses, _)| !courses));
        view.navigate("/courses/00dcc9a9-3876-4018-ab52-bcf1f0e4e05c/learn");
        assert!(view
            .breadcrumb_context()
            .is_some_and(|(courses, _)| courses));
    }

    #[test]
    fn settings_shortcut_is_cmd_or_ctrl_comma() {
        let mac = gpui_kit::Keystroke {
            modifiers: gpui_kit::Modifiers {
                platform: true,
                ..Default::default()
            },
            key: ",".to_string(),
            key_char: None,
        };
        assert!(RootView::is_settings_shortcut(&mac));

        let windows = gpui_kit::Keystroke {
            modifiers: gpui_kit::Modifiers {
                control: true,
                ..Default::default()
            },
            key: ",".to_string(),
            key_char: None,
        };
        assert!(RootView::is_settings_shortcut(&windows));

        let plain = gpui_kit::Keystroke {
            modifiers: gpui_kit::Modifiers::default(),
            key: ",".to_string(),
            key_char: Some(",".to_string()),
        };
        assert!(!RootView::is_settings_shortcut(&plain));
    }

    #[test]
    fn starts_on_home_signed_out() {
        let view = view();
        assert_eq!(view.current().map(|route| route.id), Some("app.home"));
        assert_eq!(view.language(), Language::Zh);
        assert_eq!(view.preference(), ThemePreference::System);
        assert!(
            !view.is_signed_in(),
            "fresh session must show the login page"
        );
    }

    #[test]
    fn fake_login_switches_guard_to_signed_in_and_back() {
        let mut view = view();
        view.session_mut()
            .sign_in("demo@example.com", "demo")
            .expect("fake login");
        assert!(view.is_signed_in());

        view.session_mut().sign_out_local();
        assert!(
            !view.is_signed_in(),
            "sign out must return to the login page"
        );
    }

    #[test]
    fn finish_login_success_enters_shell() {
        let mut view = view();
        view.finish_login(Ok(fake_signed_in()));
        assert!(view.is_signed_in());
        assert!(view.login_error().is_none());
    }

    #[test]
    fn finish_login_invalid_credentials_shows_error() {
        let mut view = view();
        view.finish_login(Err(AuthError::InvalidCredentials));
        assert!(!view.is_signed_in());
        assert!(view.login_error().is_some());
    }

    #[test]
    fn bad_credentials_keep_signed_out() {
        let mut view = view();
        assert!(view
            .session_mut()
            .sign_in("demo@example.com", "nope")
            .is_err());
        assert!(!view.is_signed_in());
    }

    #[test]
    fn toggling_language_changes_labels() {
        let mut view = view();
        let before = translate(view.language(), Key::AppEmptyTitle);
        view.toggle_language();
        let after = translate(view.language(), Key::AppEmptyTitle);
        assert_ne!(before, after);
        view.toggle_language();
        assert_eq!(translate(view.language(), Key::AppEmptyTitle), before);
    }

    #[test]
    fn cycling_theme_visits_all_preferences() {
        let mut view = view();
        assert_eq!(view.cycle_theme(), ThemePreference::Light);
        assert_eq!(view.cycle_theme(), ThemePreference::Dark);
        assert_eq!(view.cycle_theme(), ThemePreference::System);
    }

    #[test]
    fn account_menu_toggles_and_closes() {
        let mut view = view();
        assert!(!view.account_menu_open());
        assert!(view.toggle_account_menu());
        view.close_account_menu();
        assert!(!view.account_menu_open());
    }

    #[test]
    fn navigate_to_event_detail_captures_id_param() {
        let mut view = view();
        view.navigate("/events/evt-007");
        assert_eq!(view.current().map(|route| route.id), Some("events.detail"));
        assert_eq!(
            view.current_match()
                .and_then(|route_match| route_match.params.get("id"))
                .map(String::as_str),
            Some("evt-007")
        );
    }

    #[test]
    fn selecting_a_registered_route_updates_current() {
        let mut view = view();
        let events = view
            .registry
            .routes()
            .iter()
            .find(|route| route.id == "events.list")
            .copied()
            .expect("events route registered");
        view.select(events);
        assert_eq!(view.current().map(|route| route.id), Some("events.list"));
    }
}
