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
use cgc_platform::session::{
    AuthError, SessionService, SessionState, SignedInSession, WechatLoginStatus,
};
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

mod screens;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum LoginField {
    Email,
    Password,
    ResetToken,
    NewPassword,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum LoginMode {
    Password,
    Reset,
}

/// 登录页左侧的扫码状态。二维码常驻，不随模式切换消失。
#[derive(Clone, Debug, PartialEq, Eq)]
enum WechatLoginView {
    Idle,
    Starting,
    Ready {
        launch_url: String,
        approved: bool,
        expires_at: Option<String>,
        remaining_seconds: i64,
    },
    Expired,
    Failed(LoginError),
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
    RateLimited,
    Reset,
    Wechat,
}

impl LoginError {
    fn from_auth_error(error: &AuthError) -> Self {
        match error {
            AuthError::InvalidCredentials => LoginError::Invalid,
            AuthError::Transport(_) | AuthError::Server(_) => LoginError::Network,
            AuthError::Storage(_) => LoginError::Keychain,
            AuthError::Domain { code, .. } => match code.as_str() {
                "rate_limited" => LoginError::RateLimited,
                "invalid_or_expired_reset_token" => LoginError::Reset,
                "mini_web_login_expired"
                | "mini_web_login_cancelled"
                | "mini_web_login_consumed"
                | "mini_web_login_not_approved"
                | "mini_web_login_invalid"
                | "mini_web_login_account_conflict"
                | "mini_web_login_phone_required"
                | "mini_web_login_unavailable"
                | "mini_web_login_failed" => LoginError::Wechat,
                _ => LoginError::Network,
            },
        }
    }

    fn key(self) -> Key {
        match self {
            LoginError::Invalid => Key::AppAuthErrorInvalid,
            LoginError::Network => Key::AppAuthErrorNetwork,
            LoginError::Keychain => Key::AppAuthErrorKeychain,
            LoginError::RateLimited => Key::AppAuthErrorRateLimited,
            LoginError::Reset => Key::AppAuthErrorReset,
            LoginError::Wechat => Key::AppAuthErrorWechat,
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
    login_reset_token: String,
    login_new_password: String,
    reset_sent: bool,
    login_notice: Option<Key>,
    login_password: String,
    focused: LoginField,
    login_error: Option<LoginError>,
    signing_in: bool,
    wechat_login: WechatLoginView,
    wechat_generation: u64,
    account_menu_open: bool,
    agent_panel_open: bool,
    breadcrumb_menu: Option<BreadcrumbMenu>,
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
            login_reset_token: String::new(),
            login_new_password: String::new(),
            reset_sent: false,
            login_notice: None,
            login_password: String::new(),
            focused: LoginField::Email,
            login_error: None,
            signing_in: false,
            wechat_login: WechatLoginView::Idle,
            wechat_generation: 0,
            account_menu_open: false,
            agent_panel_open: true,
            breadcrumb_menu: None,
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
            self.navigate("/workspace");
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

    fn breadcrumb_context(&self) -> Option<(&'static str, Option<String>)> {
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
            Some((label_key, _)) => translate_registered(language, label_key),
            None => translate(language, Key::AppBreadcrumbSections),
        };
        let selected = self.breadcrumb_menu.is_some();
        bar = bar.child(div().child("›")).child(
            div()
                .id("breadcrumb-section")
                .role(Role::Button)
                .aria_label(section_label)
                .px(space(1))
                .py(px(2.0))
                .rounded(px(RADIUS_SMALL))
                .text_color(if selected { palette.ink } else { palette.ink_2 })
                .bg(if selected { palette.soft } else { palette.card })
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

    fn toggle_agent_panel(&mut self, cx: &mut Context<Self>) {
        self.agent_panel_open = !self.agent_panel_open;
        cx.notify();
    }

    fn is_agent_panel_shortcut(keystroke: &Keystroke) -> bool {
        keystroke.key.eq_ignore_ascii_case("j")
            && !keystroke.modifiers.shift
            && (keystroke.modifiers.platform || keystroke.modifiers.control)
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
                self.navigate("/workspace");
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
        self.switch_login_mode(LoginMode::Password);
        self.ensure_wechat_login(cx);
        cx.notify();
    }

    fn handle_key(&mut self, event: &KeyDownEvent, window: &mut Window, cx: &mut Context<Self>) {
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

    fn field_mut(&mut self) -> &mut String {
        match self.focused {
            LoginField::Email => &mut self.login_email,
            LoginField::Password => &mut self.login_password,
            LoginField::ResetToken => &mut self.login_reset_token,
            LoginField::NewPassword => &mut self.login_new_password,
        }
    }

    fn login_fields(&self) -> Vec<LoginField> {
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
    fn should_auto_start_wechat(&self) -> bool {
        self.login_mode == LoginMode::Password && matches!(self.wechat_login, WechatLoginView::Idle)
    }

    /// 登录视图（Password）挂载时调用；fake 模式下不自动出码。
    pub fn ensure_wechat_login(&mut self, cx: &mut Context<Self>) {
        if self.should_auto_start_wechat() {
            self.start_wechat_login(cx);
        }
    }

    fn back_to_password_login(&mut self, cx: &mut Context<Self>) {
        self.switch_login_mode(LoginMode::Password);
        self.ensure_wechat_login(cx);
        cx.notify();
    }

    fn start_wechat_login(&mut self, cx: &mut Context<Self>) {
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

    fn spawn_wechat_poller(
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
    fn spawn_wechat_countdown(&mut self, cx: &mut Context<Self>, generation: u64) {
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

    fn consume_wechat_login(
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
}

impl Render for RootView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let mode = theme::resolve(self.preference, window.appearance());
        let palette = theme::palette(mode);
        let language = self.language;
        let account_menu = self.account_menu_open;
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
                && matches!(current_id, Some("events.list") | Some("account.workspace"))
                && !self.events_started
                && matches!(self.events.state(), ListState::Idle)
            {
                self.start_events_load(cx, true);
            }
            if workspaces_ready
                && matches!(
                    current_id,
                    Some("events.mine")
                        | Some("events.participations")
                        | Some("account.workspace")
                        | Some("courses.learning_home")
                )
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
        let mut root = div();
        if !is_signed_in {
            let login_card = match self.login_mode {
                LoginMode::Password => screens::render_login_split(
                    &mut screens::ScreenContext::new(self),
                    language,
                    &palette,
                    cx,
                ),
                LoginMode::Reset => screens::render_reset_login_card(
                    &mut screens::ScreenContext::new(self),
                    language,
                    &palette,
                    cx,
                ),
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
                        .child(self.render_breadcrumb_bar(language, &palette, cx))
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
                                            Some("account.workspace") => {
                                                screens::render_workspace_overview(
                                                    &mut screens::ScreenContext::new(self),
                                                    language,
                                                    &palette,
                                                    cx,
                                                )
                                            }
                                            Some("events.list") => screens::render_events_list(
                                                &mut screens::ScreenContext::new(self),
                                                language,
                                                &palette,
                                                cx,
                                            ),
                                            Some("events.detail") => screens::render_detail(
                                                &mut screens::ScreenContext::new(self),
                                                language,
                                                &palette,
                                                cx,
                                            ),
                                            Some("events.mine") => {
                                                screens::render_enrollments_list(
                                                    &mut screens::ScreenContext::new(self),
                                                    language,
                                                    &palette,
                                                    cx,
                                                )
                                            }
                                            Some("app.settings") => screens::render_settings(
                                                &mut screens::ScreenContext::new(self),
                                                language,
                                                &palette,
                                                cx,
                                            ),
                                            Some("courses.catalog") => {
                                                screens::render_courses_list(
                                                    &mut screens::ScreenContext::new(self),
                                                    language,
                                                    &palette,
                                                    cx,
                                                )
                                            }
                                            Some("courses.learning_home") => {
                                                screens::render_learning_home(
                                                    &mut screens::ScreenContext::new(self),
                                                    language,
                                                    &palette,
                                                    cx,
                                                )
                                            }
                                            Some("events.participations") => {
                                                screens::render_participations(
                                                    &mut screens::ScreenContext::new(self),
                                                    language,
                                                    &palette,
                                                    cx,
                                                )
                                            }
                                            Some("courses.detail") => {
                                                screens::render_course_detail(
                                                    &mut screens::ScreenContext::new(self),
                                                    language,
                                                    &palette,
                                                    cx,
                                                )
                                            }
                                            Some("courses.learning") => {
                                                screens::render_course_learning(
                                                    &mut screens::ScreenContext::new(self),
                                                    language,
                                                    &palette,
                                                    cx,
                                                )
                                            }
                                            _ => self.render_content(language, &palette, cx),
                                        }
                                    },
                                ),
                        )
                        .children(
                            (self.agent_panel_open
                                && self.current.as_ref().is_some_and(|route_match| {
                                    route_match.route.id == "courses.learning"
                                }))
                            .then(|| {
                                screens::render_agent_panel(
                                    &mut screens::ScreenContext::new(self),
                                    language,
                                    &palette,
                                    cx,
                                )
                            }),
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
            .flex()
            .flex_row()
            .items_center()
            .gap(px(1.0))
            .child(
                div()
                    .id("workspace-overview-link")
                    .role(Role::Link)
                    .aria_label(translate(language, Key::AccountWorkspaceTitle))
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
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.workspace_menu_open = false;
                        this.breadcrumb_menu = None;
                        this.navigate("/workspace");
                        cx.notify();
                    })),
            )
            .child(
                div()
                    .id("workspace-menu-toggle")
                    .role(Role::Button)
                    .aria_label(translate(language, Key::AppWorkspaceSwitch))
                    .px(px(3.0))
                    .py(px(3.0))
                    .rounded(px(RADIUS_SMALL))
                    .hover(|style| style.bg(palette.soft))
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
                    })),
            )
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
            .top(px(44.0))
            .left(px(130.0))
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
                .tab_index(0isize)
                .size(px(22.0))
                .rounded(px(RADIUS_SMALL))
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
            .id("status-bar")
            .role(Role::Toolbar)
            .aria_label("Status bar")
            .tab_group()
            .flex()
            .flex_row()
            .items_center()
            .w_full()
            .justify_between()
            // 对齐 Zed `crates/workspace/src/status_bar.rs:116`：`p(DynamicSpacing::Base04)` 四边 4px，
            // 高度由 22px 条目 + 上下各 4px 撑出 30px（不写死 `h()`）；左右两组 gap(Base08) = 8px，
            // 组内 gap_1 = 4px。整条没有上边框，靠比画布亮一级的背景做分隔。
            .px(px(4.0))
            .py(px(4.0))
            .gap(px(8.0))
            .bg(palette.frame)
            .text_size(px(12.0))
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap(px(4.0))
                    .min_w_0()
                    .overflow_x_hidden()
                    .children(agent_toggle),
            )
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap(px(4.0))
                    .flex_shrink_0()
                    .overflow_x_hidden()
                    .child(
                        div()
                            .id("theme-toggle")
                            .tab_index(0isize)
                            .size(px(22.0))
                            .rounded(px(RADIUS_SMALL))
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
                            .tab_index(0isize)
                            .size(px(22.0))
                            .rounded(px(RADIUS_SMALL))
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
    if let crate::routing::RouteSelection::Match(route_match) = registry.select("/workspace") {
        return Some(route_match);
    }
    registry.routes().first().copied().map(|route| RouteMatch {
        route,
        params: std::collections::BTreeMap::new(),
    })
}

fn build_courses_service() -> CourseCatalogService {
    let use_http = !cgc_platform::runtime::use_fake_backend();
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

fn now_epoch_seconds() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs() as i64)
        .unwrap_or(0)
}

/// 二维码剩余秒数；服务端少了 expiresAt 时按 10 分钟兜底（与后端有效期一致）。
fn remaining_seconds(expires_at: Option<&str>) -> i64 {
    expires_at
        .and_then(parse_rfc3339_epoch)
        .map(|deadline| (deadline - now_epoch_seconds()).max(0))
        .unwrap_or(600)
}

fn build_learning_host_api() -> Arc<dyn LearningHostApi> {
    let use_http = !cgc_platform::runtime::use_fake_backend();
    if use_http {
        Arc::new(HttpLearningHostApi::from_env())
    } else {
        Arc::new(FakeLearningHostApi::default())
    }
}

fn build_learning_host_vault() -> Arc<dyn SecretVault> {
    let use_http = !cgc_platform::runtime::use_fake_backend();
    if use_http {
        Arc::new(KeychainVault::from_env())
    } else {
        Arc::new(MemoryVault::default())
    }
}

fn build_enrollments_api() -> Arc<dyn EnrollmentsApi> {
    let use_http = !cgc_platform::runtime::use_fake_backend();
    if use_http {
        Arc::new(HttpEnrollmentsApi::from_env())
    } else {
        Arc::new(FakeEnrollmentsApi)
    }
}

fn build_orders_api() -> Arc<dyn OrdersApi> {
    let use_http = !cgc_platform::runtime::use_fake_backend();
    if use_http {
        Arc::new(cgc_events::orders::HttpOrdersApi::from_env())
    } else {
        Arc::new(cgc_events::orders::FakeOrdersApi::demo())
    }
}

fn build_workspace_service() -> WorkspaceService {
    let use_http = !cgc_platform::runtime::use_fake_backend();
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
    let use_http = !cgc_platform::runtime::use_fake_backend();
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
    use super::{LoginMode, RootView, WechatLoginView};
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
        assert_eq!(
            view.breadcrumb_context().map(|(label, _)| label),
            Some("events.list.title")
        );
        view.navigate("/courses/00dcc9a9-3876-4018-ab52-bcf1f0e4e05c/learn");
        assert_eq!(
            view.breadcrumb_context().map(|(label, _)| label),
            Some("courses.catalog.title")
        );
        view.navigate("/workspace");
        assert_eq!(
            view.breadcrumb_context().map(|(label, _)| label),
            Some("account.workspace.overview")
        );
    }

    #[test]
    fn workspace_is_default_landing_and_login_target() {
        let mut view = view();
        assert_eq!(
            view.current().map(|route| route.id),
            Some("account.workspace")
        );
        view.finish_login(Ok(fake_signed_in()));
        assert_eq!(
            view.current().map(|route| route.id),
            Some("account.workspace")
        );
    }

    #[test]
    fn learning_and_participation_routes_are_registered() {
        let registry = build_registry().expect("registry builds");
        assert!(registry.find("courses.learning_home").is_some());
        assert!(registry.find("events.participations").is_some());
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
    fn starts_on_workspace_route_signed_out() {
        let view = view();
        assert_eq!(
            view.current().map(|route| route.id),
            Some("account.workspace")
        );
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

    #[test]
    fn auto_start_only_in_password_view_when_idle() {
        let mut view = view();
        view.login_mode = LoginMode::Password;
        view.wechat_login = WechatLoginView::Idle;
        assert!(view.should_auto_start_wechat());

        view.wechat_login = WechatLoginView::Starting;
        assert!(!view.should_auto_start_wechat());

        view.wechat_login = WechatLoginView::Idle;
        view.login_mode = LoginMode::Reset;
        assert!(!view.should_auto_start_wechat());
    }

    #[test]
    fn switching_login_views_resets_scan_state_and_stops_the_poller() {
        let mut view = view();
        let generation = view.wechat_generation;

        // 切视图：扫码状态归零、轮询代数前进。
        view.switch_login_mode(LoginMode::Reset);
        assert_eq!(view.login_mode, LoginMode::Reset);
        assert_eq!(view.wechat_login, WechatLoginView::Idle);
        assert_eq!(view.wechat_generation, generation + 1);

        // 回到密码视图：同样重置，等待 render 重新出码。
        view.wechat_login = WechatLoginView::Expired;
        view.switch_login_mode(LoginMode::Password);
        assert_eq!(view.login_mode, LoginMode::Password);
        assert_eq!(view.wechat_login, WechatLoginView::Idle);
        assert_eq!(view.wechat_generation, generation + 2);
    }
}
