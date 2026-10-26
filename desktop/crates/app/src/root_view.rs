//! 应用外壳：登录页 / 已登录壳（顶部 header + 内容 + 底部 status bar）。
//!
//! 布局参考 Zed（xerj 取证）：透明 titlebar 与红绿灯同排、右上角账户头像 + 下拉、
//! footer 只放图标（悬停 tooltip）。会话来自 `cgc_platform::session`：未登录时
//! 整个窗口显示登录页（guard），登录成功后进入壳；登出在头像下拉里（同 Zed 的
//! sign out）。网络调用放后台线程，结果回主线程刷新。

use gpui_kit::InteractiveElement;
use gpui_kit::*;

use std::sync::{Arc, OnceLock};

use crate::chat_state::{
    load_chat_pref, load_installed_agents, load_selected_agent, save_chat_pref,
    save_installed_agent, save_selected_agent,
};
use crate::formula::render_markdown_with_math;
use cgc_agent_ui::conversation::ConversationThread;
use cgc_agent_ui::safe_markdown::sanitize_markdown;
use cgc_courses::catalog::{
    learning_context, CourseCatalogService, CourseDetailService, CourseSummary, CoursesApi,
    CoursesListState, FakeCoursesApi, HttpCoursesApi,
};
use cgc_courses::content::{CourseContentService, CourseContentState, MaterialKind};
use cgc_courses::projection::{LearningProjectionService, ProjectionState};
use cgc_events::detail::{EventDetail, EventDetailService, PriceMode};
use cgc_platform::paths::AppPaths;
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
    AcpHost, AcpHostConfig, CommandView, ConfigOptionView, HostEvent, SessionSummary,
};
use cgc_platform::agent::detect::{detect_all, AgentStatus, DetectedAgent, SystemProbe};
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
use cgc_platform::workspace::{
    FakeWorkspaceApi, HttpWorkspaceApi, WorkspaceApi, WorkspaceListState, WorkspaceService,
};
use gpui_kit::assets::IconName as AssetIcon;
use gpui_kit::component::{
    avatar::Avatar,
    badge::Badge,
    empty::{Empty, EmptyDescription, EmptyHeader, EmptyTitle},
    input::{InputEvent, InputState, TextareaState},
    kbd::Kbd,
    spinner::Spinner,
    status_bar::StatusBar,
    tag::Tag,
    tooltip::Tooltip,
    Icon, Sizable as _, Size as KitSize,
};

use crate::i18n::{default_language, translate, translate_registered, Key, Language};
use crate::qr::{encode as encode_qr, render_qr, QrError};
use crate::routing::{Route, RouteMatch, RouteRegistry};
use crate::settings_window::SettingsWindowView;
use crate::theme::{self, space, ThemePreference, RADIUS_LARGE, RADIUS_MEDIUM, RADIUS_SMALL};

mod agent_icons;
mod controller;
mod history_actions;
pub(crate) use history_actions::notify_history_changed;
pub use history_actions::register_history_root;
mod history_sidebar;
mod screens;
mod state;
pub(crate) use screens::surface as shared_surface;

use state::{AgentRegistryFilter, RightPanel, ShellState, SiteTreeSection};

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
    KeychainLinux,
    RateLimited,
    Reset,
    Wechat,
}

impl LoginError {
    fn from_auth_error(error: &AuthError) -> Self {
        match error {
            AuthError::InvalidCredentials => LoginError::Invalid,
            AuthError::Transport(_) | AuthError::Server(_) => LoginError::Network,
            AuthError::Storage(reason)
                if reason.contains("secret-tool") || reason.contains("libsecret") =>
            {
                LoginError::KeychainLinux
            }
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
            LoginError::KeychainLinux => Key::AppAuthErrorKeychainLinux,
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

#[derive(Default)]
struct ChatUi {
    title_override: Option<String>,
    auto_start_queued: bool,
    npx_cache_retry: bool,
    /// 统一历史列表（native threads.db + ACP conversations.db，按 updated_at 倒序）。
    history: Vec<crate::acp_history::HistoryEntry>,
    /// 从本地 history 打开 ACP 会话时，agent 回放的 thread（Ready 后替换本地内容）。
    replay: Option<ReplayState>,
    /// 外部 agent 无法恢复历史（load 失败 / 无回放）：展示本地记录 + 新建会话入口。
    resumed_without_history: bool,
    /// ACP transcript 防抖保存的世代号。
    acp_save_generation: u64,
    phase: ChatPhase,
    agent: String,
    selected_agent: Option<String>,
    version: Option<String>,
    thread: ConversationThread,
    chat_scroll: ScrollHandle,
    input: String,
    focused: bool,
    host: Option<AcpHost>,
    lease: Option<LearningHostLease>,
    poll_generation: u64,
    auto_prompted: bool,
    configs: Vec<ConfigOptionView>,
    commands: Vec<CommandView>,
    config_search: String,
    config_search_input: Option<Entity<InputState>>,
    config_search_subscription: Option<Subscription>,
    config_search_placeholder_language: Option<Language>,
    config_scroll: ScrollHandle,
    slash_selection: usize,
    slash_dismissed: bool,
    sessions: Vec<SessionSummary>,
    opened_from_history: bool,
    session_id: Option<String>,
    restore_id: Option<String>,
    configs_applied: bool,
    history_open: bool,
    guidance: Option<ChatGuidance>,
    load_retry_available: bool,
}

/// 从本地历史打开 ACP 会话时的回放状态：agent 通过 `session/load` 回放的历史
/// 先收在独立 thread 里，Ready 后按 `resume_decision` 决定替换本地内容或降级提示。
struct ReplayState {
    thread: ConversationThread,
    saw_events: bool,
    has_local_content: bool,
}

#[derive(Clone, Debug)]
struct ChatGuidance {
    detected: Vec<(String, String)>,
    node_found: Option<String>,
}

const SLASH_CORE_COMMANDS: &[&str] = &[
    "plan",
    "mcp",
    "skills",
    "status",
    "review",
    "review-branch",
    "review-commit",
    "compact",
    "goal",
    "rename",
    "logout",
];

#[derive(Clone, Debug, PartialEq, Eq)]
struct SlashCandidate {
    command_index: usize,
    group: &'static str,
    score: i32,
}

fn slash_query(input: &str) -> Option<&str> {
    let rest = input.strip_prefix('/')?;
    if rest.contains(char::is_whitespace) {
        return None;
    }
    Some(rest)
}

fn fuzzy_score(query: &str, name: &str) -> Option<i32> {
    if query.is_empty() {
        return Some(0);
    }
    let query = query.to_lowercase();
    let name = name.to_lowercase();
    if name == query {
        return Some(2000);
    }
    if name.starts_with(&query) {
        return Some(1000 - name.len() as i32);
    }
    if let Some(position) = name.find(&query) {
        return Some(600 - position as i32 - name.len() as i32);
    }
    let mut chars = name.chars();
    let mut gaps = 0;
    for expected in query.chars() {
        let mut found = false;
        for ch in chars.by_ref() {
            if ch == expected {
                found = true;
                break;
            }
            gaps += 1;
            if gaps > 12 {
                return None;
            }
        }
        if !found {
            return None;
        }
    }
    Some(300 - gaps - name.len() as i32)
}

fn slash_group(name: &str) -> &'static str {
    if SLASH_CORE_COMMANDS.contains(&name) {
        "Commands"
    } else {
        "Skills"
    }
}

fn group_order(group: &str) -> u8 {
    match group {
        "Commands" => 0,
        "Skills" => 1,
        _ => 2,
    }
}

fn slash_candidates(commands: &[CommandView], input: &str) -> Vec<SlashCandidate> {
    let Some(query) = slash_query(input) else {
        return Vec::new();
    };
    let mut candidates = commands
        .iter()
        .enumerate()
        .filter_map(|(command_index, command)| {
            fuzzy_score(query, &command.name).map(|score| SlashCandidate {
                command_index,
                group: slash_group(&command.name),
                score,
            })
        })
        .collect::<Vec<_>>();
    candidates.sort_by(|left, right| {
        right
            .score
            .cmp(&left.score)
            .then_with(|| group_order(left.group).cmp(&group_order(right.group)))
            .then_with(|| {
                commands[left.command_index]
                    .name
                    .cmp(&commands[right.command_index].name)
            })
    });
    candidates
}

struct ChatStartError {
    message: String,
    detected: Vec<(String, String)>,
    node_found: Option<String>,
}

struct PreparedChat {
    agent_id: String,
    agent_name: String,
    plan: LaunchPlan,
    lease: LearningHostLease,
    server: McpServerConfig,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ResizeSide {
    Left,
    Right,
}

struct ResizeGhost;

impl Render for ResizeGhost {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div()
    }
}

pub struct RootView {
    state: ShellState,
}

impl std::ops::Deref for RootView {
    type Target = ShellState;

    fn deref(&self) -> &Self::Target {
        &self.state
    }
}

impl std::ops::DerefMut for RootView {
    fn deref_mut(&mut self) -> &mut Self::Target {
        &mut self.state
    }
}

impl RootView {
    /// 启动时恢复历史侧栏开关（main 读取 preferences 后传入；默认关闭）。
    pub fn set_history_sidebar_persisted(&mut self, open: bool) {
        if open {
            self.history_sidebar =
                Some(crate::root_view::history_sidebar::HistorySidebar::default());
        }
    }

    pub fn new(registry: RouteRegistry) -> Self {
        Self {
            state: ShellState::new(registry),
        }
    }

    pub fn with_session(
        registry: RouteRegistry,
        language: Language,
        preference: ThemePreference,
        session: SessionService,
    ) -> Self {
        Self {
            state: ShellState::with_session(registry, language, preference, session),
        }
    }

    pub fn set_chat_input(&mut self, input: Entity<TextareaState>) {
        self.state.chat_input = Some(input);
    }

    /// ACP 当前 agent 的展示名（未连接时用已选 agent id）。
    pub(in crate::root_view) fn acp_agent_label(&self) -> String {
        if !self.chat.agent.trim().is_empty() {
            self.chat.agent.clone()
        } else {
            self.chat
                .selected_agent
                .clone()
                .unwrap_or_else(|| "Agent".to_string())
        }
    }

    /// 没有标题时的默认标题：New {agent} Thread。
    fn new_thread_title_for(&self, agent: &str) -> String {
        match self.language {
            Language::Zh => format!("新建 {agent} 对话"),
            Language::En => format!("New {agent} Thread"),
        }
    }

    /// B4a-3b-2：native 面板接线唯一入口（host 注入在 controller 创建时完成）。
    fn native_panel_view(&self) -> Option<&Entity<crate::native_agent_view::NativeAgentView>> {
        self.native_agent_view.as_ref()
    }

    fn new_thread_title(&self) -> String {
        let agent = self.acp_agent_label();
        self.new_thread_title_for(&agent)
    }

    pub(in crate::root_view) fn agent_panel_title(&self, cx: &App) -> String {
        if self.native_chat_mode && RootView::native_agent_enabled() {
            if let Some(view) = self.native_panel_view() {
                let view = view.read(cx);
                if view.is_empty_thread() {
                    return self.new_thread_title_for("CGC Agent");
                }
                return view.display_title();
            }
            return self.new_thread_title_for("CGC Agent");
        }
        self.chat
            .title_override
            .clone()
            .or_else(|| crate::acp_history::thread_display_title(&self.chat.thread))
            .or_else(|| {
                self.chat.session_id.as_ref().and_then(|session_id| {
                    self.chat
                        .sessions
                        .iter()
                        .find(|session| &session.session_id == session_id)
                        .and_then(|session| session.title.clone())
                })
            })
            .unwrap_or_else(|| self.new_thread_title())
    }

    fn ensure_agent_panel_title_input(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Entity<InputState> {
        if let Some(input) = &self.agent_panel_title_input {
            return input.clone();
        }
        let title = self.agent_panel_title(cx);
        let input = cx.new(|cx| InputState::new(window, cx).default_value(title));
        self.agent_panel_title_subscription = Some(cx.subscribe_in(
            &input,
            window,
            |this, _input, event: &InputEvent, window, cx| {
                if let InputEvent::PressEnter { .. } = event {
                    if this.agent_panel_editing_title {
                        this.commit_agent_panel_title(window, cx);
                    }
                }
            },
        ));
        self.agent_panel_title_input = Some(input.clone());
        input
    }

    pub(in crate::root_view) fn start_edit_agent_panel_title(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let title = self.agent_panel_title(cx);
        let input = self.ensure_agent_panel_title_input(window, cx);
        input.update(cx, |state, cx| state.set_value(title, window, cx));
        let focus = input.read(cx).focus_handle(cx);
        window.focus(&focus, cx);
        self.agent_panel_editing_title = true;
        cx.notify();
    }

    pub(in crate::root_view) fn commit_agent_panel_title(
        &mut self,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(input) = self.agent_panel_title_input.clone() else {
            return;
        };
        let raw = input.read(cx).value().trim().to_string();
        let title = if raw.is_empty() { None } else { Some(raw) };
        if self.native_chat_mode && RootView::native_agent_enabled() {
            if let Some(view) = self.native_panel_view() {
                view.update(cx, |view, cx| view.set_title_override(title.clone(), cx));
            }
        } else {
            self.chat.title_override = title.clone();
            if let Some(session_id) = self.chat.session_id.clone() {
                // Stage 3.3：用户重命名写 conversations.db 的 title_override，
                // 列表展示 override 优先，agent 生成标题更新不会覆盖它。
                if let Ok(store) = crate::acp_history::open_conversation_store() {
                    let thread_id = crate::acp_history::acp_thread_id(&session_id);
                    let _ = store.set_title_override(&thread_id, title.as_deref());
                }
                self.chat.history = self.load_unified_history();
            }
        }
        self.agent_panel_editing_title = false;
        cx.notify();
    }

    pub(in crate::root_view) fn cancel_agent_panel_title(
        &mut self,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.agent_panel_editing_title = false;
        cx.notify();
    }

    pub(in crate::root_view) fn regenerate_agent_panel_title(&mut self, cx: &mut Context<Self>) {
        if self.native_chat_mode && RootView::native_agent_enabled() {
            if let Some(view) = self.native_panel_view() {
                view.update(cx, |view, cx| view.regenerate_title(cx));
            }
        } else {
            self.chat.title_override = None;
            if let Some(session_id) = self.chat.session_id.clone() {
                if let Ok(store) = crate::acp_history::open_conversation_store() {
                    let thread_id = crate::acp_history::acp_thread_id(&session_id);
                    let _ = store.set_title_override(&thread_id, None);
                }
                self.chat.history = self.load_unified_history();
            }
        }
        cx.notify();
    }

    pub fn set_config_search_input(&mut self, input: Entity<InputState>) {
        self.state.chat.config_search_input = Some(input);
    }
}

impl Render for RootView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.refresh_agent_scope();
        self.refresh_page_context();
        self.refresh_history_if_dirty(cx);
        let mode = theme::resolve(self.preference, window.appearance());
        let _ = mode;
        let palette = theme::palette_from_theme(cx);
        let language = self.language;
        let account_menu = self.account_menu_open;
        let is_signed_in = self.is_signed_in();
        if is_signed_in && self.pending_link.as_deref() == Some("/settings") {
            self.pending_link = None;
            self.open_settings_window(cx);
        }
        self.clamp_open_panel_widths(window.viewport_size().width.as_f32());
        if self.key_interceptor.is_none() {
            let root = cx.entity().downgrade();
            let subscription = cx.intercept_keystrokes(move |event, window, cx| {
                let keystroke = event.keystroke.clone();
                let handled = root
                    .update(cx, |this, cx| {
                        this.handle_slash_keystroke(&keystroke, window, cx)
                    })
                    .unwrap_or(false);
                if handled {
                    cx.stop_propagation();
                }
            });
            self.key_interceptor = Some(subscription);
        }
        if self.chat_input_pending_clear {
            self.chat_input_pending_clear = false;
            if let Some(input) = self.chat_input.clone() {
                input.update(cx, |input, cx| input.set_value("", window, cx));
            }
        }
        if let Some(input) = self.chat_input.clone() {
            if self.chat_input_subscription.is_none() {
                let subscription = cx.subscribe_in(
                    &input,
                    window,
                    |this, state, event: &InputEvent, window, cx| match event {
                        InputEvent::Change => {
                            this.chat.focused = true;
                            this.chat.input = state.read(cx).value().to_string();
                            this.chat.slash_selection = 0;
                            this.chat.slash_dismissed = false;
                            this.chat_input_pending_clear = false;
                            cx.notify();
                        }
                        InputEvent::PressEnter { shift, .. } if !shift => {
                            this.chat.input = state.read(cx).value().to_string();
                            this.send_chat(cx);
                            state.update(cx, |state, cx| state.set_value("", window, cx));
                            cx.notify();
                        }
                        InputEvent::Focus => {
                            this.chat.focused = true;
                            cx.notify();
                        }
                        InputEvent::Blur => {
                            this.chat.focused = false;
                            cx.notify();
                        }
                        _ => {}
                    },
                );
                self.chat_input_subscription = Some(subscription);
            }
        }
        if let Some(input) = self.chat.config_search_input.clone() {
            if self.chat.config_search_subscription.is_none() {
                let subscription = cx.subscribe_in(
                    &input,
                    window,
                    |this, state, event: &InputEvent, _window, cx| {
                        if let InputEvent::Change = event {
                            this.chat.config_search = state.read(cx).value().to_string();
                            cx.notify();
                        }
                    },
                );
                self.chat.config_search_subscription = Some(subscription);
            }
            if self.chat.config_search_placeholder_language != Some(language) {
                let placeholder = translate(language, Key::AgentChatChatSelectOption);
                input.update(cx, |input, cx| {
                    input.set_placeholder(placeholder, window, cx);
                });
                self.chat.config_search_placeholder_language = Some(language);
            }
        }
        if is_signed_in
            && self
                .current
                .as_ref()
                .is_some_and(|route_match| route_match.route.id == "app.agents")
            && !self.agent_registry_started
        {
            self.start_agent_registry_load(cx);
        }
        // HITL：没有可靠 GUI 自动化时，允许 QA 通过环境变量触发一次安装。
        if is_signed_in
            && self
                .current
                .as_ref()
                .is_some_and(|route_match| route_match.route.id == "app.agents")
            && !self.agent_auto_install_attempted
            && !self.agent_registry_rows.is_empty()
        {
            self.agent_auto_install_attempted = true;
            if let Ok(id) = std::env::var("CGC_AUTO_INSTALL_AGENT") {
                if !id.trim().is_empty() {
                    self.install_agent(id.trim(), cx);
                }
            }
        }
        let email = self
            .session
            .signed_in()
            .and_then(|session| session.email.clone())
            .unwrap_or_default();
        let language_label = translate(
            language,
            match language {
                Language::Zh => Key::AppLangZh,
                Language::En => Key::AppLangEn,
            },
        );
        let language_tooltip = translate(language, Key::AppLanguageToggle);
        let account_tooltip = translate(language, Key::AppAccountMenu);
        let sign_out_label = translate(language, Key::AppAuthSignOut);
        let signed_in_as = translate(language, Key::AppAuthSignedInAs);

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
                self.reset_chat_local(cx);
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
                    &mut screens::ScreenContext::new(&mut self.state),
                    language,
                    &palette,
                    cx,
                ),
                LoginMode::Reset => screens::render_reset_login_card(
                    &mut screens::ScreenContext::new(&mut self.state),
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
                    language_icon,
                    language_label,
                    language_tooltip,
                    &palette,
                    cx,
                ));
            root
        } else {
            root =
                root.size_full()
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
                                            .flex()
                                            .flex_row()
                                            .items_center()
                                            .gap(px(6.0))
                                            .child(
                                                img(app_icon()).w(px(18.0)).h(px(18.0)).flex_none(),
                                            )
                                            .child(
                                                div()
                                                    .text_size(px(15.0))
                                                    .text_color(palette.ink)
                                                    .child(translate(language, Key::AppName)),
                                            ),
                                    ),
                            )
                            .child(div().w(px(1.0)).h(px(14.0)).bg(palette.line))
                            .child(self.render_breadcrumb_bar(language, &palette, cx))
                            .child(div().flex_1())
                            .child(self.render_notifications_bell(language, &palette, cx))
                            .child(
                                div()
                                    .id("account-toggle-wrap")
                                    .relative()
                                    .flex()
                                    .items_center()
                                    .tooltip(move |window, cx| {
                                        Tooltip::new(account_tooltip).build(window, cx)
                                    })
                                    .child(
                                        Avatar::new()
                                            .name(email.clone())
                                            .with_size(KitSize::Small)
                                            .on_mouse_down(
                                                MouseButton::Left,
                                                cx.listener(|this, _, _, cx| {
                                                    this.toggle_account_menu();
                                                    cx.notify();
                                                }),
                                            ),
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
                            .children(
                                self.history_sidebar
                                    .is_some()
                                    .then(|| self.render_history_sidebar(window, cx)),
                            )
                            .children(self.agent_panel_open.then(|| {
                                screens::render_agent_panel(
                                    &mut screens::ScreenContext::new(&mut self.state),
                                    language,
                                    &palette,
                                    window,
                                    cx,
                                )
                            }))
                            .children(self.agent_panel_open.then(|| {
                                render_panel_resize_handle(ResizeSide::Left, &palette, cx)
                            }))
                            .child(
                                div()
                                    .flex()
                                    .flex_col()
                                    .flex_1()
                                    .min_w(px(0.0))
                                    .min_h(px(0.0))
                                    .children(Some(screens::render_pane_tabs(
                                        &mut screens::ScreenContext::new(&mut self.state),
                                        &palette,
                                        cx,
                                    )))
                                    .child(
                                        div()
                                            .id("content-scroll")
                                            .flex_1()
                                            .min_w(px(0.0))
                                            .p(space(6))
                                            .overflow_y_scroll()
                                            .child(
                                                if matches!(
                                                    self.workspaces.state(),
                                                    WorkspaceListState::Empty
                                                ) {
                                                    self.render_workspace_empty(language, &palette)
                                                } else {
                                                    match self
                                                        .current
                                                        .as_ref()
                                                        .map(|route_match| route_match.route.id)
                                                    {
                                                        Some("account.workspace") => {
                                                            screens::render_workspace_overview(
                                                                &mut screens::ScreenContext::new(
                                                                    &mut self.state,
                                                                ),
                                                                language,
                                                                &palette,
                                                                cx,
                                                            )
                                                        }
                                                        Some("events.list") => {
                                                            screens::render_events_list(
                                                                &mut screens::ScreenContext::new(
                                                                    &mut self.state,
                                                                ),
                                                                language,
                                                                &palette,
                                                                cx,
                                                            )
                                                        }
                                                        Some("events.detail") => {
                                                            screens::render_detail(
                                                                &mut screens::ScreenContext::new(
                                                                    &mut self.state,
                                                                ),
                                                                language,
                                                                &palette,
                                                                cx,
                                                            )
                                                        }
                                                        Some("events.mine") => {
                                                            screens::render_enrollments_list(
                                                                &mut screens::ScreenContext::new(
                                                                    &mut self.state,
                                                                ),
                                                                language,
                                                                &palette,
                                                                cx,
                                                            )
                                                        }
                                                        Some("app.settings") => {
                                                            screens::render_settings(
                                                                &mut screens::ScreenContext::new(
                                                                    &mut self.state,
                                                                ),
                                                                language,
                                                                &palette,
                                                                cx,
                                                            )
                                                        }
                                                        Some("app.agents") => {
                                                            screens::render_agent_registry(
                                                                &mut screens::ScreenContext::new(
                                                                    &mut self.state,
                                                                ),
                                                                language,
                                                                &palette,
                                                                cx,
                                                            )
                                                        }
                                                        Some("courses.catalog") => {
                                                            screens::render_courses_list(
                                                                &mut screens::ScreenContext::new(
                                                                    &mut self.state,
                                                                ),
                                                                language,
                                                                &palette,
                                                                cx,
                                                            )
                                                        }
                                                        Some("courses.learning_home") => {
                                                            screens::render_learning_home(
                                                                &mut screens::ScreenContext::new(
                                                                    &mut self.state,
                                                                ),
                                                                language,
                                                                &palette,
                                                                cx,
                                                            )
                                                        }
                                                        Some("events.participations") => {
                                                            screens::render_participations(
                                                                &mut screens::ScreenContext::new(
                                                                    &mut self.state,
                                                                ),
                                                                language,
                                                                &palette,
                                                                cx,
                                                            )
                                                        }
                                                        Some("courses.detail") => {
                                                            screens::render_course_detail(
                                                                &mut screens::ScreenContext::new(
                                                                    &mut self.state,
                                                                ),
                                                                language,
                                                                &palette,
                                                                cx,
                                                            )
                                                        }
                                                        Some("courses.learning") => {
                                                            let active_issue = self
                                                                .active_issue_tab()
                                                                .map(|(course_id, issue_id)| {
                                                                    (
                                                                        course_id.to_string(),
                                                                        issue_id.to_string(),
                                                                    )
                                                                });
                                                            match active_issue {
                                                    Some((course_id, issue_id)) => {
                                                        screens::render_issue_card(
                                                            &mut screens::ScreenContext::new(
                                                                &mut self.state,
                                                            ),
                                                            &course_id,
                                                            &issue_id,
                                                            language,
                                                            &palette,
                                                        )
                                                    }
                                                    None => screens::render_course_learning(
                                                        &mut screens::ScreenContext::new(
                                                            &mut self.state,
                                                        ),
                                                        language,
                                                        &palette,
                                                        cx,
                                                    ),
                                                }
                                                        }
                                                        _ => self
                                                            .render_content(language, &palette, cx),
                                                    }
                                                },
                                            ),
                                    ),
                            )
                            .children(self.right_panel_open.then(|| {
                                render_panel_resize_handle(ResizeSide::Right, &palette, cx)
                            }))
                            .children(self.right_panel_open.then(|| {
                                screens::render_right_dock(
                                    &mut screens::ScreenContext::new(&mut self.state),
                                    language,
                                    &palette,
                                    window,
                                    cx,
                                )
                            })),
                    )
                    .child(self.render_footer(
                        language,
                        true,
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
            if self.theme_menu_open {
                root = root.child(self.render_theme_menu(&palette, cx));
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
    /// 窗口变窄或恢复旧宽度时，保证两侧 panel 不会把中心压到 320px 以下。
    fn clamp_open_panel_widths(&mut self, viewport: f32) {
        if !self.agent_panel_open || !self.right_panel_open {
            return;
        }
        let available = (viewport - 320.0).max(500.0);
        let mut excess = self.agent_panel_width + self.right_panel_width - available;
        if excess <= 0.0 {
            return;
        }
        let right_shrink = (self.right_panel_width - 240.0).max(0.0).min(excess);
        self.right_panel_width -= right_shrink;
        excess -= right_shrink;
        if excess > 0.0 {
            let agent_shrink = (self.agent_panel_width - 260.0).max(0.0).min(excess);
            self.agent_panel_width -= agent_shrink;
        }
    }

    fn render_theme_menu(&self, palette: &theme::Palette, cx: &mut Context<Self>) -> AnyElement {
        let rows = theme::available_themes(cx)
            .into_iter()
            .map(|(name, _mode)| {
                let selected = self.theme_name == name;
                let root = cx.entity().downgrade();
                div()
                    .id(SharedString::from(format!("theme-menu-{name}")))
                    .px(space(1))
                    .py(px(4.0))
                    .rounded(px(RADIUS_SMALL))
                    .text_size(px(11.0))
                    .text_color(if selected {
                        palette.accent
                    } else {
                        palette.ink_2
                    })
                    .hover(|style| style.bg(palette.soft))
                    .child(if selected {
                        format!("{name} ✓")
                    } else {
                        name.clone()
                    })
                    .on_click(move |_, _, cx| {
                        let _ = root.update(cx, |this, cx| {
                            this.select_theme(name.clone(), cx);
                        });
                    })
            });
        div()
            .id("theme-menu")
            .absolute()
            .bottom(px(36.0))
            .right(space(2))
            .w(px(240.0))
            .max_h(px(420.0))
            .overflow_y_scroll()
            .flex()
            .flex_col()
            .gap(px(1.0))
            .p(space(1))
            .rounded(px(RADIUS_MEDIUM))
            .border_1()
            .border_color(palette.line_strong)
            .bg(palette.card)
            .occlude()
            .text_color(palette.ink)
            .children(rows)
            .into_any_element()
    }

    fn render_notifications_bell(
        &self,
        language: Language,
        palette: &theme::Palette,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let unread = self.notification_unread_count();
        let active = self.right_panel_open && self.right_panel == RightPanel::Notifications;
        let icon = if unread > 0 {
            AssetIcon::BellDot
        } else {
            AssetIcon::Bell
        };
        let label = translate(language, Key::AppNotificationsTitle);
        let tooltip = label.to_string();
        div()
            .id("notifications-toggle")
            .role(Role::Button)
            .aria_label(label)
            .size(px(26.0))
            .mr(px(7.0))
            .rounded(px(RADIUS_MEDIUM))
            .flex()
            .items_center()
            .justify_center()
            .text_color(if active {
                palette.accent
            } else {
                palette.ink_3
            })
            .hover(|style| style.bg(palette.soft))
            .tooltip(move |window, cx| Tooltip::new(tooltip.clone()).build(window, cx))
            .on_click(cx.listener(|this, _, _, cx| this.toggle_notifications(cx)))
            .child(
                Badge::new()
                    .count(unread)
                    .max(9)
                    .with_size(gpui_kit::component::Size::Small)
                    .child(
                        Icon::default()
                            .path(icon.path())
                            .text_color(if active {
                                palette.accent
                            } else {
                                palette.ink_3
                            })
                            .small(),
                    ),
            )
            .into_any_element()
    }

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
                            .child(shortcut_kbd(if cfg!(target_os = "macos") {
                                "cmd-,"
                            } else {
                                "ctrl-,"
                            })),
                    )
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.open_settings_window(cx);
                        this.account_menu_open = false;
                        cx.notify();
                    })),
            )
            .children(Self::native_agent_enabled().then(|| {
                div()
                    .id("account-native-agent")
                    .role(Role::Button)
                    .aria_label("Native Agent")
                    .px(space(1))
                    .py(px(6.0))
                    .rounded(px(RADIUS_SMALL))
                    .text_color(palette.ink_2)
                    .hover(|style| style.bg(palette.soft))
                    .child("Native Agent（Beta）")
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.open_native_agent_window(cx);
                        this.account_menu_open = false;
                        cx.notify();
                    }))
            }))
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
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let content = match &self.current {
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
        };
        match &self.native_agent_highlight {
            Some(highlight) => {
                let header = div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .justify_between()
                    .gap(space(2))
                    .child(
                        div()
                            .text_size(px(12.0))
                            .text_color(palette.ink_2)
                            .child(format!(
                                "Agent 高亮：{}:{}-{}",
                                highlight.path, highlight.start_line, highlight.end_line
                            )),
                    )
                    .child(
                        div()
                            .id("native-agent-highlight-close")
                            .role(Role::Button)
                            .aria_label("关闭高亮")
                            .text_size(px(11.0))
                            .text_color(palette.ink_3)
                            .child("关闭")
                            .on_click(
                                cx.listener(|this, _, _, cx| this.clear_native_agent_highlight(cx)),
                            ),
                    );
                let body = if let Some(error) = &highlight.error {
                    div()
                        .text_size(px(11.0))
                        .text_color(palette.danger)
                        .child(format!("无法读取文件：{error}"))
                        .into_any_element()
                } else {
                    div()
                        .flex()
                        .flex_col()
                        .gap(px(1.0))
                        .children(highlight.preview.iter().map(|(line_number, text)| {
                            let highlighted = *line_number >= highlight.start_line
                                && *line_number <= highlight.end_line;
                            let row = div()
                                .flex()
                                .flex_row()
                                .gap(space(1))
                                .text_size(px(11.0))
                                .child(
                                    div()
                                        .w(px(36.0))
                                        .text_color(palette.ink_3)
                                        .child(format!("{line_number}")),
                                )
                                .child(
                                    div()
                                        .text_color(if highlighted {
                                            palette.ink
                                        } else {
                                            palette.ink_2
                                        })
                                        .child(text.clone()),
                                );
                            if highlighted {
                                row.bg(palette.soft)
                            } else {
                                row
                            }
                        }))
                        .into_any_element()
                };
                div()
                    .flex()
                    .flex_col()
                    .gap(space(1))
                    .p(space(2))
                    .rounded(px(RADIUS_MEDIUM))
                    .border_1()
                    .border_color(palette.line)
                    .bg(palette.card)
                    .child(header)
                    .child(body)
                    .child(content)
                    .into_any_element()
            }
            None => content,
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
                Empty::new()
                    .header(
                        EmptyHeader::new()
                            .title(
                                EmptyTitle::new()
                                    .child(translate(language, Key::AppWorkspaceEmptyTitle)),
                            )
                            .description(
                                EmptyDescription::new()
                                    .child(translate(language, Key::AppWorkspaceEmptyGuidance)),
                            ),
                    )
                    .text_color(palette.ink),
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
            WorkspaceListState::Idle | WorkspaceListState::Loading => {
                render_loading_state(language, Key::AppWorkspaceLoading, palette).into_any_element()
            }
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
        let palette = *palette;
        let agent_toggle = include_nav.then(|| {
            div()
                .id("agent-panel-toggle")
                .role(Role::Button)
                .aria_label("Agent")
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
                .tooltip(move |window, cx| {
                    Tooltip::new(format!("Agent · {shortcut}")).build(window, cx)
                })
                .on_click(cx.listener(|this, _, _, cx| {
                    this.toggle_agent_panel(cx);
                }))
                .into_any_element()
        });
        let history_toggle = include_nav.then(|| {
            let active = self.history_sidebar.is_some();
            div()
                .id("chat-history-toggle")
                .role(Role::Button)
                .aria_label("历史对话")
                .tab_index(0isize)
                .size(px(22.0))
                .rounded(px(RADIUS_SMALL))
                .flex()
                .items_center()
                .justify_center()
                .text_color(if active {
                    palette.accent
                } else {
                    palette.ink_3
                })
                .hover(|style| style.bg(palette.soft))
                .child(
                    Icon::default()
                        .path(AssetIcon::Clock.path())
                        .text_color(if active {
                            palette.accent
                        } else {
                            palette.ink_3
                        })
                        .small(),
                )
                .tooltip(move |window, cx| Tooltip::new("历史对话").build(window, cx))
                .on_click(cx.listener(|this, _, _, cx| {
                    this.toggle_history_sidebar(cx);
                }))
                .into_any_element()
        });
        let panel_toggle = |id: &'static str,
                            label: SharedString,
                            icon: AssetIcon,
                            active: bool,
                            panel: RightPanel| {
            let tooltip = label.clone();
            div()
                .id(id)
                .role(Role::Button)
                .aria_label(label.clone())
                .tab_index(0isize)
                .size(px(22.0))
                .rounded(px(RADIUS_SMALL))
                .flex()
                .items_center()
                .justify_center()
                .text_color(if active {
                    palette.accent
                } else {
                    palette.ink_3
                })
                .hover(|style| style.bg(palette.soft))
                .child(
                    Icon::default()
                        .path(icon.path())
                        .text_color(if active {
                            palette.accent
                        } else {
                            palette.ink_3
                        })
                        .small(),
                )
                .tooltip(move |window, cx| Tooltip::new(tooltip.clone()).build(window, cx))
                .on_click(cx.listener(move |this, _, _, cx| {
                    this.toggle_right_panel(panel, cx);
                }))
                .into_any_element()
        };
        let site_tree_active = self.right_panel_open && self.right_panel == RightPanel::SiteTree;
        let outline_active = self.right_panel_open && self.right_panel == RightPanel::Outline;
        let site_tree_toggle = panel_toggle(
            "site-tree-toggle",
            translate(language, Key::WorkspaceSiteTreeTitle).into(),
            AssetIcon::ListTree,
            site_tree_active,
            RightPanel::SiteTree,
        );
        let outline_toggle = panel_toggle(
            "outline-toggle",
            translate(language, Key::WorkspaceOutlineTitle).into(),
            AssetIcon::FileText,
            outline_active,
            RightPanel::Outline,
        );
        div()
            .id("status-bar")
            .role(Role::Toolbar)
            .aria_label("Status bar")
            .tab_group()
            .child(
                StatusBar::new()
                    .left(
                        div()
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap(px(4.0))
                            .min_w_0()
                            .overflow_x_hidden()
                            .children(history_toggle)
                            .children(agent_toggle)
                            .child(site_tree_toggle)
                            .child(outline_toggle),
                    )
                    .right(
                        div()
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap(px(4.0))
                            .flex_shrink_0()
                            .overflow_x_hidden()
                            .child(
                                div()
                                    .id("theme-menu-toggle")
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
                                            .path(AssetIcon::Palette.path())
                                            .text_color(palette.ink_3)
                                            .small(),
                                    )
                                    .tooltip(move |window, cx| {
                                        Tooltip::new("主题").build(window, cx)
                                    })
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.toggle_theme_menu(cx);
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
                                    .tooltip(move |window, cx| {
                                        Tooltip::new(format!(
                                            "{language_tooltip} · {language_label}"
                                        ))
                                        .build(window, cx)
                                    })
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.toggle_language();
                                        cx.notify();
                                    })),
                            ),
                    )
                    .bg(palette.frame)
                    .border_t_0()
                    .w_full(),
            )
            .into_any_element()
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
            this.navigate_to_course_detail(&course_id, cx);
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

fn event_status_tag(status: &str, label: gpui_kit::SharedString) -> Tag {
    let tag = match status {
        "cancelled" => Tag::danger(),
        "ended" => Tag::secondary(),
        "published" | "confirmed" => Tag::success(),
        _ => Tag::secondary(),
    };
    tag.child(label)
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

fn app_icon() -> Arc<Image> {
    static ICON: OnceLock<Arc<Image>> = OnceLock::new();
    ICON.get_or_init(|| {
        Arc::new(Image::from_bytes(
            ImageFormat::Png,
            include_bytes!("../icons/128x128.png").to_vec(),
        ))
    })
    .clone()
}

pub fn main_window_options() -> WindowOptions {
    WindowOptions {
        // 参考 Zed build_window_options：透明 titlebar + 自绘 header，
        // 红绿灯位置由 gpui 负责；Linux/Wayland 用 client side decorations。
        titlebar: Some(TitlebarOptions {
            title: None,
            appears_transparent: true,
            traffic_light_position: Some(point(px(12.0), px(12.0))),
        }),
        app_owns_titlebar_drag: cfg!(target_os = "macos"),
        window_decorations: Some(WindowDecorations::Client),
        window_min_size: Some(Size {
            width: px(800.0),
            height: px(560.0),
        }),
        ..Default::default()
    }
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

fn render_panel_resize_handle(
    side: ResizeSide,
    palette: &theme::Palette,
    cx: &mut Context<RootView>,
) -> AnyElement {
    let root = cx.entity().downgrade();
    let id = match side {
        ResizeSide::Left => "agent-panel-resize-handle",
        ResizeSide::Right => "right-dock-resize-handle",
    };
    div()
        .id(id)
        .relative()
        .w(px(5.0))
        .flex_none()
        .h_full()
        .cursor_col_resize()
        .group(id)
        // Keep the 5 px drag target while painting only a 1 px separator.
        .child(
            div()
                .absolute()
                .left(px(2.0))
                .w(px(1.0))
                .h_full()
                .bg(palette.line)
                .group_hover(id, |style| style.bg(palette.accent)),
        )
        .on_drag(side, move |_, position, _, cx| {
            let _ = root.update(cx, |this, cx| {
                let width = match side {
                    ResizeSide::Left => this.agent_panel_width,
                    ResizeSide::Right => this.right_panel_width,
                };
                // on_drag 的 position 是元素内偏移，不是窗口坐标；这里只记录
                // 起始宽度，第一次 drag_move 时再用真实的窗口坐标初始化。
                let _ = position;
                this.resize_drag = Some((side, f32::NAN, width));
                cx.notify();
            });
            cx.new(|_| ResizeGhost)
        })
        .on_drag_move(
            cx.listener(move |this, event: &DragMoveEvent<ResizeSide>, window, cx| {
                let Some((drag_side, start_x, start_width)) = this.resize_drag else {
                    return;
                };
                if drag_side != side {
                    return;
                }
                let current = event.event.position.x.as_f32();
                if !start_x.is_finite() {
                    this.resize_drag = Some((drag_side, current, start_width));
                    return;
                }
                let delta = match side {
                    ResizeSide::Left => current - start_x,
                    ResizeSide::Right => start_x - current,
                };
                let viewport = window.viewport_size().width.as_f32();
                let other = match side {
                    ResizeSide::Left => this.right_panel_width,
                    ResizeSide::Right => this.agent_panel_width,
                };
                let max = (viewport - other - 320.0).max(260.0);
                match side {
                    ResizeSide::Left => {
                        this.agent_panel_width = (start_width + delta).clamp(260.0, max)
                    }
                    ResizeSide::Right => {
                        this.right_panel_width = (start_width + delta).clamp(240.0, max)
                    }
                }
                cx.spawn(async move |this, cx| {
                    cx.background_executor()
                        .timer(std::time::Duration::from_millis(250))
                        .await;
                    let _ = this.update(cx, |this, cx| this.persist_workspace_layout(cx));
                })
                .detach();
                cx.notify();
            }),
        )
        .on_mouse_up(
            MouseButton::Left,
            cx.listener(|this, _, _, cx| {
                this.resize_drag = None;
                this.persist_workspace_layout(cx);
            }),
        )
        .into_any_element()
}

fn render_loading_state(language: Language, key: Key, palette: &theme::Palette) -> AnyElement {
    div()
        .flex()
        .flex_row()
        .items_center()
        .gap(px(8.0))
        .text_size(px(12.0))
        .text_color(palette.ink_3)
        .child(Spinner::new())
        .child(translate(language, key))
        .into_any_element()
}

fn shortcut_kbd(stroke: &str) -> Kbd {
    Kbd::new(gpui_kit::Keystroke::parse(stroke).expect("valid shortcut"))
}

#[cfg(test)]
mod tests {
    use super::{
        fuzzy_score, slash_candidates, slash_query, CommandView, LoginError, LoginMode, RootView,
        WechatLoginView,
    };
    use crate::i18n::{translate, Key, Language};
    use crate::registration::build_registry;
    use crate::theme::ThemePreference;
    use cgc_agent_ui::conversation::{ConversationThread, Entry as ConversationEntry};
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
    fn shortcut_kbd_parses_settings_shortcuts() {
        for stroke in ["cmd-,", "ctrl-,"] {
            assert!(gpui_kit::Keystroke::parse(stroke).is_ok(), "{stroke}");
        }
    }

    #[test]
    fn slash_candidates_filter_fuzzily_and_group_commands_before_skills() {
        let commands = vec![
            CommandView {
                name: "review".into(),
                description: "Review changes".into(),
                requires_argument: false,
            },
            CommandView {
                name: "review-branch".into(),
                description: "Review branch".into(),
                requires_argument: false,
            },
            CommandView {
                name: "answer-me-with-html".into(),
                description: "Skill".into(),
                requires_argument: false,
            },
            CommandView {
                name: "plan".into(),
                description: "Plan".into(),
                requires_argument: false,
            },
        ];
        let filtered = slash_candidates(&commands, "/rev");
        assert_eq!(
            filtered
                .iter()
                .map(|candidate| commands[candidate.command_index].name.as_str())
                .collect::<Vec<_>>(),
            vec!["review", "review-branch"]
        );
        assert!(filtered
            .iter()
            .all(|candidate| candidate.group == "Commands"));

        let all = slash_candidates(&commands, "/");
        assert_eq!(all[0].group, "Commands");
        assert_eq!(all.last().unwrap().group, "Skills");
        assert!(fuzzy_score("rvw", "review").is_some());
        assert!(fuzzy_score("xyz", "review").is_none());
        assert!(slash_query("/review arg").is_none());
    }

    #[test]
    fn copied_agent_response_excludes_thinking_and_previous_turns() {
        let thread = ConversationThread {
            entries: vec![
                ConversationEntry::User {
                    text: "first".into(),
                },
                ConversationEntry::Assistant {
                    text: "answer one".into(),
                },
                ConversationEntry::Thinking {
                    text: "private reasoning".into(),
                    expanded: false,
                },
                ConversationEntry::Assistant {
                    text: "answer two".into(),
                },
                ConversationEntry::User {
                    text: "second".into(),
                },
                ConversationEntry::Assistant {
                    text: "answer three".into(),
                },
            ],
            ..Default::default()
        };
        let view = thread.row_view();
        assert_eq!(
            view.turn_copy_text(3).as_deref(),
            Some("answer one\n\nanswer two")
        );
        assert_eq!(view.turn_copy_text(5).as_deref(), Some("answer three"));
        assert!(!view
            .turn_copy_text(3)
            .unwrap_or_default()
            .contains("private reasoning"));
        assert_eq!(
            ConversationThread::default().row_view().turn_copy_text(0),
            None
        );
        assert_eq!(
            view.turn_copy_text(99),
            None,
            "越界由调用方忽略，不再返回最后一条"
        );
    }

    #[test]
    fn acp_rows_use_shared_turn_gating() {
        let thread = ConversationThread {
            entries: vec![
                ConversationEntry::User { text: "q1".into() },
                ConversationEntry::Assistant { text: "a1".into() },
                ConversationEntry::ToolCall {
                    tool_call_id: "call-1".into(),
                    title: "read_file".into(),
                    name: Some("read_file".into()),
                    kind: "Read".into(),
                    status: "completed".into(),
                    args: Some("{\"path\":\"a.rs\"}".into()),
                    output: Some("ok".into()),
                    locations: Vec::new(),
                    expanded: false,
                },
                ConversationEntry::Assistant { text: "a2".into() },
                ConversationEntry::User { text: "q2".into() },
                ConversationEntry::Assistant { text: "a3".into() },
            ],
            ..Default::default()
        };
        let view = thread.row_view();
        assert_eq!(view.finalized_turn_end(3), Some(true));
        assert_eq!(
            view.finalized_turn_end(1),
            Some(false),
            "工具调用之后还有回复，不是回合末"
        );
        assert_eq!(view.turn_copy_text(3).as_deref(), Some("a1\n\na2"));
        let plan = view.action_plan(5, false, false).expect("底部条");
        assert_eq!(plan.scroll_to_user, Some(4));
        assert!(plan.scroll_to_top);
        assert_eq!(
            view.action_plan(5, true, false),
            None,
            "流式生成中隐藏底部条"
        );
        assert!(view.finalized_turn_end(5).is_none(), "线程末尾交给底部兜底");
    }

    #[test]
    fn stale_session_load_errors_are_detected() {
        assert!(RootView::is_stale_session_error(
            "acp connection: Internal error: \"session/load: Internal error: no rollout found for thread id abc\""
        ));
        assert!(RootView::is_stale_session_error(
            "no rollout found for thread id abc"
        ));
        assert!(!RootView::is_stale_session_error("agent process exited"));
        assert!(!RootView::is_stale_session_error(
            "managed node runtime missing"
        ));
        assert!(RootView::should_retry_stale_session(
            true,
            "session/load: no rollout found"
        ));
        assert!(!RootView::should_retry_stale_session(
            false,
            "session/load: no rollout found"
        ));
        assert!(!RootView::should_retry_stale_session(
            true,
            "agent process exited"
        ));
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
    fn threads_sidebar_shortcut_is_alt_cmd_or_alt_ctrl_j() {
        let mac = gpui_kit::Keystroke {
            modifiers: gpui_kit::Modifiers {
                platform: true,
                alt: true,
                ..Default::default()
            },
            key: "j".to_string(),
            key_char: None,
        };
        assert!(RootView::is_threads_sidebar_shortcut(&mac));

        let windows = gpui_kit::Keystroke {
            modifiers: gpui_kit::Modifiers {
                control: true,
                alt: true,
                ..Default::default()
            },
            key: "j".to_string(),
            key_char: None,
        };
        assert!(RootView::is_threads_sidebar_shortcut(&windows));

        // 不带 alt 的 Cmd/Ctrl+J 仍是 Agent Panel 快捷键（Zed 把两者分开）。
        let agent_panel = gpui_kit::Keystroke {
            modifiers: gpui_kit::Modifiers {
                platform: true,
                ..Default::default()
            },
            key: "j".to_string(),
            key_char: None,
        };
        assert!(!RootView::is_threads_sidebar_shortcut(&agent_panel));
        assert!(RootView::is_agent_panel_shortcut(&agent_panel));

        let shift = gpui_kit::Keystroke {
            modifiers: gpui_kit::Modifiers {
                platform: true,
                alt: true,
                shift: true,
                ..Default::default()
            },
            key: "j".to_string(),
            key_char: None,
        };
        assert!(!RootView::is_threads_sidebar_shortcut(&shift));
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
    fn missing_linux_secret_tool_has_actionable_error() {
        let missing = LoginError::from_auth_error(&AuthError::Storage(
            "cannot persist session: secret-tool is not installed".to_string(),
        ));
        assert_eq!(missing.key(), Key::AppAuthErrorKeychainLinux);
        let generic = LoginError::from_auth_error(&AuthError::Storage(
            "OS keychain is not available on this platform".to_string(),
        ));
        assert_eq!(generic.key(), Key::AppAuthErrorKeychain);
    }

    #[test]
    fn pending_deep_link_is_consumed_after_login() {
        let mut view = view();
        view.pending_link = Some("/workspace".to_string());
        view.finish_login(Ok(fake_signed_in()));
        assert_eq!(
            view.current().map(|route| route.id),
            Some("account.workspace")
        );
        assert!(view.pending_link.is_none());
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

    /// 回归：从 native（CGC Agent）切到外部 ACP agent 时，Agent Panel 必须离开
    /// native 视图。只写 chat_state 而不同步内存态，会让 ACP 会话在后台建出来
    /// 却看不见（面板停在 native 视图）。
    #[test]
    fn selecting_external_agent_leaves_native_chat_mode() {
        let state_file =
            std::env::temp_dir().join(format!("cgc-chat-state-select-{}.json", std::process::id()));
        let _ = std::fs::remove_file(&state_file);
        // 隔离 chat_state 读写：测试不写本机真实状态，也不受已有登录/模式影响。
        std::env::set_var("CGC_CHAT_STATE_FILE", &state_file);

        let mut view = view();
        view.native_chat_mode = true;
        assert!(view.native_chat_mode, "前置条件：面板先处在 native 模式");

        view.reset_chat_for_external_agent("claude_code", "Claude Code");

        assert_eq!(view.chat.selected_agent.as_deref(), Some("claude_code"));
        assert!(
            !view.native_chat_mode,
            "Agent Panel 仍停在 native 视图：ACP 会话建出来也看不见"
        );
        assert_eq!(
            crate::chat_state::load_native_chat_mode(),
            Some(false),
            "持久化模式也要落回 ACP"
        );

        std::env::remove_var("CGC_CHAT_STATE_FILE");
        let _ = std::fs::remove_file(&state_file);
    }
}
