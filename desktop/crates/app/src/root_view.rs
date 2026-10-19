//! 应用外壳：登录页 / 已登录壳（顶部 header + 内容 + 底部 status bar）。
//!
//! 布局参考 Zed（xerj 取证）：透明 titlebar 与红绿灯同排、右上角账户头像 + 下拉、
//! footer 只放图标（悬停 tooltip）。会话来自 `cgc_platform::session`：未登录时
//! 整个窗口显示登录页（guard），登录成功后进入壳；登出在头像下拉里（同 Zed 的
//! sign out）。网络调用放后台线程，结果回主线程刷新。

use gpui_kit::*;

use std::sync::Arc;

use crate::safe_markdown::sanitize_markdown;
use cgc_courses::catalog::{
    learning_context, CourseCatalogService, CourseDetailService, CourseSummary, CoursesApi,
    CoursesListState, FakeCoursesApi, HttpCoursesApi,
};
use cgc_courses::content::{CourseContentService, CourseContentState, MaterialKind};
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
use cgc_platform::events::{AppEvent, EventPublisher, MemoryEventBus};
use cgc_platform::routes::NavIcon;
use cgc_platform::session::{AuthError, SessionService, SessionState, SignedInSession};
use cgc_platform::workspace::{
    FakeWorkspaceApi, HttpWorkspaceApi, WorkspaceApi, WorkspaceListState, WorkspaceService,
};
use gpui_kit::assets::IconName as AssetIcon;
use gpui_kit::component::{Icon, Sizable as _};

use crate::i18n::{default_language, translate, translate_registered, Key, Language};
use crate::qr::{encode as encode_qr, render_qr, QrError};
use crate::routing::{Route, RouteMatch, RouteRegistry};
use crate::theme::{self, space, ThemePreference, RADIUS_LARGE, RADIUS_MEDIUM, RADIUS_SMALL};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum LoginField {
    Email,
    Password,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum LoginError {
    Invalid,
    Network,
    Keychain,
}

impl LoginError {
    fn from_auth_error(error: &AuthError) -> Self {
        match error {
            AuthError::InvalidCredentials => LoginError::Invalid,
            AuthError::Transport(_) | AuthError::Server(_) => LoginError::Network,
            AuthError::Storage(_) => LoginError::Keychain,
        }
    }

    fn key(self) -> Key {
        match self {
            LoginError::Invalid => Key::AppAuthErrorInvalid,
            LoginError::Network => Key::AppAuthErrorNetwork,
            LoginError::Keychain => Key::AppAuthErrorKeychain,
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

pub struct RootView {
    registry: RouteRegistry,
    current: Option<RouteMatch>,
    language: Language,
    preference: ThemePreference,
    session: SessionService,
    session_checked: bool,
    login_email: String,
    login_password: String,
    focused: LoginField,
    login_error: Option<LoginError>,
    signing_in: bool,
    account_menu_open: bool,
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
    pending_link: Option<String>,
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
        Self {
            registry,
            current,
            language,
            preference,
            session,
            session_checked: false,
            login_email: String::new(),
            login_password: String::new(),
            focused: LoginField::Email,
            login_error: None,
            signing_in: false,
            account_menu_open: false,
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
            courses,
            courses_started: false,
            course_detail,
            course_detail_started: false,
            content,
            pending_link: None,
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
        self.current = Some(RouteMatch {
            route,
            params: std::collections::BTreeMap::new(),
        });
    }

    /// 按路径导航（动态路由在此完成参数解析）。
    pub fn navigate(&mut self, path: &str) {
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
        self.pending_link = None;
        self.selected_event = None;
        self.selected_tier = None;
        self.age_confirmed = false;
        self.enrolling = false;
        self.enrollment_error = None;
        self.payment = PaymentViewState::Idle;
        self.payment_generation = self.payment_generation.saturating_add(1);
        self.deposit_consent = false;
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

    fn handle_shell_key(
        &mut self,
        event: &KeyDownEvent,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) {
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

    fn handle_key(&mut self, event: &KeyDownEvent, window: &mut Window, cx: &mut Context<Self>) {
        match event.keystroke.key.as_str() {
            "tab" => {
                self.focused = match self.focused {
                    LoginField::Email => LoginField::Password,
                    LoginField::Password => LoginField::Email,
                };
            }
            "enter" => self.submit_login(cx),
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
        }
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
        let is_fake_mode = self.is_fake_mode;

        let workspace_switcher = self.render_workspace_switcher(language, &palette, cx);

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

            let login_card = div()
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
                });

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
                        .child(workspace_switcher)
                        .child(div().w(px(1.0)).h(px(14.0)).bg(palette.line))
                        .child(div().text_color(palette.ink_3).child(match &self.current {
                            Some(route_match) => {
                                translate_registered(language, route_match.route.title_key)
                            }
                            None => translate(language, Key::AppNavLabel),
                        }))
                        .child(div().flex_1())
                        .child({
                            let account_menu = account_menu.then(|| {
                                div()
                                    .id("account-menu")
                                    .absolute()
                                    .top(px(34.0))
                                    .right_0()
                                    .w(px(200.0))
                                    .flex()
                                    .flex_col()
                                    .gap(px(2.0))
                                    .p(space(1))
                                    .rounded(px(RADIUS_MEDIUM))
                                    .border_1()
                                    .border_color(palette.line_strong)
                                    .bg(palette.card)
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
                                            .px(space(1))
                                            .py(px(6.0))
                                            .rounded(px(RADIUS_SMALL))
                                            .text_color(palette.ink_2)
                                            .hover(|style| style.bg(palette.soft))
                                            .child(translate(language, Key::AppSettingsTitle))
                                            .on_click(cx.listener(|this, _, _, cx| {
                                                this.navigate("/settings");
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
                                            .child(sign_out_label)
                                            .on_click(
                                                cx.listener(|this, _, _, cx| this.sign_out(cx)),
                                            ),
                                    )
                                    .into_any_element()
                            });

                            div()
                                .relative()
                                .flex()
                                .items_center()
                                .child(
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
                                )
                                .children(account_menu)
                        }),
                )
                .child(div().flex_1().w_full().p(space(6)).child(
                    if matches!(self.workspaces.state(), WorkspaceListState::Empty) {
                        self.render_workspace_empty(language, &palette)
                    } else {
                        match self
                            .current
                            .as_ref()
                            .map(|route_match| route_match.route.id)
                        {
                            Some("events.list") => self.render_events_list(language, &palette, cx),
                            Some("events.detail") => self.render_detail(language, &palette, cx),
                            Some("events.mine") => {
                                self.render_enrollments_list(language, &palette, cx)
                            }
                            Some("app.settings") => self.render_settings(language, &palette, cx),
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
                ))
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
            root
        }
    }
}

impl RootView {
    fn render_nav_items(
        &self,
        language: Language,
        palette: &theme::Palette,
        cx: &mut Context<Self>,
    ) -> Vec<AnyElement> {
        let current_id = self
            .current
            .as_ref()
            .map(|route_match| route_match.route.id);
        self.registry
            .routes()
            .iter()
            .filter(|route| {
                !route.has_dynamic_segment()
                    && (route.path == "/" || route.path.trim_matches('/').split('/').count() == 1)
            })
            .map(|route| {
                let route = *route;
                let selected = current_id.is_some_and(|id| {
                    id == route.id
                        || id
                            .strip_prefix(route.id)
                            .is_some_and(|rest| rest.starts_with('.'))
                });
                let label = translate_registered(language, route.title_key);
                div()
                    .id(format!("footer-nav-{}", route.id))
                    .size(px(22.0))
                    .rounded(px(RADIUS_MEDIUM))
                    .flex()
                    .items_center()
                    .justify_center()
                    .text_color(if selected {
                        palette.accent
                    } else {
                        palette.ink_3
                    })
                    .hover(|style| style.bg(palette.soft))
                    .child(
                        Icon::default()
                            .path(nav_icon(route.icon).path())
                            .text_color(if selected {
                                palette.accent
                            } else {
                                palette.ink_3
                            })
                            .small(),
                    )
                    .tooltip(move |_, cx| cx.new(|_| TooltipText { text: label.into() }).into())
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.select(route);
                        cx.notify();
                    }))
                    .into_any_element()
            })
            .collect()
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
                        let body = sanitize_markdown(body);
                        materials.push(
                            TextView::markdown(
                                format!("course-material-{}", materials.len()),
                                body,
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
        let menu_open = self.workspace_menu_open;
        let state = self.workspaces.state().clone();
        let current = self.workspaces.current().cloned();
        let workspaces = self.workspaces.workspaces().to_vec();
        let label = current
            .as_ref()
            .map(|workspace| workspace.name.clone())
            .unwrap_or_else(|| translate(language, Key::AppWorkspaceSwitch).to_string());

        let options = workspaces
            .iter()
            .map(|workspace| {
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
                let members = workspace
                    .member_count
                    .map(|count| {
                        format!("{} {count}", translate(language, Key::AppWorkspaceMembers))
                    })
                    .unwrap_or_default();
                let meta = [roles, members]
                    .into_iter()
                    .filter(|part| !part.is_empty())
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
                    .children((!meta.is_empty()).then(|| {
                        div()
                            .text_size(px(11.0))
                            .text_color(palette.ink_3)
                            .child(meta)
                            .into_any_element()
                    }))
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.switch_workspace(&workspace_id, cx);
                    }))
                    .into_any_element()
            })
            .collect::<Vec<_>>();

        let panel_body: AnyElement = match state {
            WorkspaceListState::Idle | WorkspaceListState::Loading => div()
                .px(space(1))
                .py(px(4.0))
                .text_size(px(12.0))
                .text_color(palette.ink_3)
                .child(translate(language, Key::AppWorkspaceLoading))
                .into_any_element(),
            WorkspaceListState::Failed(_) => div()
                .flex()
                .flex_col()
                .gap(space(1))
                .px(space(1))
                .py(px(4.0))
                .child(
                    div()
                        .text_size(px(12.0))
                        .text_color(palette.danger)
                        .child(translate(language, Key::AppWorkspaceError)),
                )
                .child(
                    div()
                        .id("workspace-retry")
                        .px(space(1))
                        .py(px(3.0))
                        .rounded(px(RADIUS_SMALL))
                        .bg(palette.accent)
                        .text_color(white())
                        .child(translate(language, Key::AppWorkspaceRetry))
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.workspaces.retry_ready();
                            this.workspaces_started = false;
                            cx.notify();
                        })),
                )
                .into_any_element(),
            WorkspaceListState::Empty => div()
                .px(space(1))
                .py(px(4.0))
                .text_size(px(12.0))
                .text_color(palette.ink_3)
                .child(translate(language, Key::AppWorkspaceEmpty))
                .into_any_element(),
            WorkspaceListState::Ready => {
                div().flex().flex_col().children(options).into_any_element()
            }
        };

        let panel = menu_open.then(|| {
            div()
                .id("workspace-menu")
                .absolute()
                .top(px(30.0))
                .left_0()
                .w(px(260.0))
                .flex()
                .flex_col()
                .gap(px(2.0))
                .p(space(1))
                .rounded(px(RADIUS_MEDIUM))
                .border_1()
                .border_color(palette.line_strong)
                .bg(palette.card)
                .child(
                    div()
                        .px(space(1))
                        .py(px(3.0))
                        .text_size(px(10.0))
                        .text_color(palette.ink_3)
                        .child(translate(language, Key::AppWorkspaceSwitch)),
                )
                .child(panel_body)
                .into_any_element()
        });

        div()
            .relative()
            .flex()
            .items_center()
            .child(
                div()
                    .id("workspace-menu-toggle")
                    .flex()
                    .items_center()
                    .gap(px(4.0))
                    .px(space(1))
                    .py(px(3.0))
                    .rounded(px(RADIUS_SMALL))
                    .hover(|style| style.bg(palette.soft))
                    .child(
                        div()
                            .text_size(px(13.0))
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
                        cx.notify();
                    })),
            )
            .children(panel)
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
        div()
            .flex()
            .flex_row()
            .items_center()
            .h(px(30.0))
            .px(space(2))
            .gap(px(2.0))
            .bg(palette.frame)
            .border_t_1()
            .border_color(palette.line)
            .text_size(px(12.0))
            .children(if include_nav {
                self.render_nav_items(language, palette, cx)
            } else {
                Vec::new()
            })
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
            )
            .child(div().flex_1())
            .child(
                div()
                    .text_color(palette.ink_3)
                    .child(concat!("v", env!("CARGO_PKG_VERSION"))),
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
