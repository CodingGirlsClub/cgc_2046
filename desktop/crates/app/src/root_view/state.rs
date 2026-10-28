use super::*;
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

/// 右侧 Dock 的互斥 panel。图标在 footer/header 切换，同一时间只显示一个。
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(in crate::root_view) enum RightPanel {
    #[default]
    SiteTree,
    Outline,
    Notifications,
}

/// 纯状态转移：点当前 panel 图标收起，点另一个切换；便于单测钉住互斥语义。
pub(in crate::root_view) fn toggled_right_panel(
    current: RightPanel,
    open: bool,
    requested: RightPanel,
) -> (RightPanel, bool) {
    if open && current == requested {
        (current, false)
    } else {
        (requested, true)
    }
}

/// 中心 Pane 的一个 Tab。page tab 以 path 唯一；issue tab 以课程+卡唯一。
#[derive(Clone, Debug, PartialEq, Eq)]
pub(in crate::root_view) struct PaneTab {
    pub id: String,
    pub title: String,
    pub path: String,
    pub issue_id: Option<String>,
}

impl PaneTab {
    pub(in crate::root_view) fn page(path: &str, title: impl Into<String>) -> Self {
        Self {
            id: format!("page:{path}"),
            title: title.into(),
            path: path.to_string(),
            issue_id: None,
        }
    }

    pub(in crate::root_view) fn issue(
        course_id: &str,
        issue_id: &str,
        title: impl Into<String>,
    ) -> Self {
        Self {
            id: format!("issue:{course_id}:{issue_id}"),
            title: title.into(),
            path: format!("/courses/{course_id}/learn"),
            issue_id: Some(issue_id.to_string()),
        }
    }
}

/// 打开/聚焦一个 Tab：同 id 只保留一个，并返回 active id。
pub(in crate::root_view) fn open_or_focus_tab(
    tabs: &mut Vec<PaneTab>,
    tab: PaneTab,
    active: &mut Option<String>,
) {
    if !tabs.iter().any(|existing| existing.id == tab.id) {
        tabs.push(tab.clone());
    }
    *active = Some(tab.id);
}

/// 关闭 Tab 后选择相邻项：优先右侧，其次左侧；没有则 None。
pub(in crate::root_view) fn close_tab(
    tabs: &mut Vec<PaneTab>,
    active: &mut Option<String>,
    id: &str,
) -> Option<PaneTab> {
    let index = tabs.iter().position(|tab| tab.id == id)?;
    let removed = tabs.remove(index);
    if active.as_deref() == Some(id) {
        *active = tabs
            .get(index)
            .or_else(|| index.checked_sub(1).and_then(|previous| tabs.get(previous)))
            .map(|tab| tab.id.clone());
    }
    Some(removed)
}

impl ShellState {
    pub(in crate::root_view) fn open_tab(&mut self, tab: PaneTab) {
        open_or_focus_tab(&mut self.tabs, tab, &mut self.active_tab);
    }

    pub(in crate::root_view) fn close_tab(&mut self, id: &str) -> bool {
        close_tab(&mut self.tabs, &mut self.active_tab, id).is_some()
    }
}

/// Site Tree 的展开状态；数据实例只在对应 section 展开时渲染。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(in crate::root_view) enum SiteTreeSection {
    Events,
    Courses,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(in crate::root_view) enum AgentRegistryFilter {
    #[default]
    All,
    Installed,
    NotInstalled,
}

/// native agent 请求高亮的文件行区间（最小渲染：主窗口内容区顶部提示）。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NativeAgentHighlight {
    pub path: String,
    pub start_line: u32,
    pub end_line: u32,
    pub workspace: std::path::PathBuf,
    pub preview: Vec<(u32, String)>,
    pub error: Option<String>,
}

pub struct ShellState {
    pub(in crate::root_view) registry: RouteRegistry,
    pub(in crate::root_view) current: Option<RouteMatch>,
    pub(in crate::root_view) language: Language,
    pub(in crate::root_view) preference: ThemePreference,
    pub(in crate::root_view) theme_name: String,
    pub(in crate::root_view) theme_menu_open: bool,
    pub(in crate::root_view) session: SessionService,
    pub(in crate::root_view) session_checked: bool,
    pub(in crate::root_view) login_mode: LoginMode,
    pub(in crate::root_view) login_email: String,
    pub(in crate::root_view) login_reset_token: String,
    pub(in crate::root_view) login_new_password: String,
    pub(in crate::root_view) reset_sent: bool,
    pub(in crate::root_view) login_notice: Option<Key>,
    pub(in crate::root_view) login_password: String,
    pub(in crate::root_view) focused: LoginField,
    pub(in crate::root_view) login_error: Option<LoginError>,
    pub(in crate::root_view) signing_in: bool,
    pub(in crate::root_view) wechat_login: WechatLoginView,
    pub(in crate::root_view) wechat_generation: u64,
    pub(in crate::root_view) account_menu_open: bool,
    pub(in crate::root_view) agent_panel_open: bool,
    pub(in crate::root_view) right_panel: RightPanel,
    pub(in crate::root_view) right_panel_open: bool,
    pub(in crate::root_view) right_panel_width: f32,
    pub(in crate::root_view) agent_panel_width: f32,
    pub(in crate::root_view) resize_drag: Option<(ResizeSide, f32, f32)>,
    pub(in crate::root_view) tabs: Vec<PaneTab>,
    pub(in crate::root_view) active_tab: Option<String>,
    pub(in crate::root_view) pane_notice: Option<String>,
    pub(in crate::root_view) window_handle: Option<AnyWindowHandle>,
    pub(in crate::root_view) window_opening: bool,
    pub(in crate::root_view) close_to_tray: Arc<std::sync::atomic::AtomicBool>,
    pub(in crate::root_view) tray_hint_shown: Arc<std::sync::atomic::AtomicBool>,
    pub(in crate::root_view) notification_items: Vec<cgc_platform::notifications::Notification>,
    pub(in crate::root_view) notification_next_cursor: Option<String>,
    pub(in crate::root_view) notification_filter: crate::notification_center::NotificationFilter,
    pub(in crate::root_view) notification_loading: bool,
    pub(in crate::root_view) notification_loaded: bool,
    pub(in crate::root_view) notification_error: Option<String>,
    pub(in crate::root_view) notification_scroll: ScrollHandle,
    pub(in crate::root_view) notification_seen: BTreeMap<String, String>,
    pub(in crate::root_view) notification_started: bool,
    pub(in crate::root_view) notification_responses: Arc<Mutex<Vec<SystemNotificationResponse>>>,
    pub(in crate::root_view) site_tree_events_open: bool,
    pub(in crate::root_view) site_tree_courses_open: bool,
    pub(in crate::root_view) site_tree_query: String,
    pub(in crate::root_view) site_tree_search_focused: bool,
    pub(in crate::root_view) site_tree_course_open: Option<String>,
    pub(in crate::root_view) site_tree_scroll: ScrollHandle,
    pub(in crate::root_view) site_tree_scroll_restore: Option<f32>,
    pub(in crate::root_view) breadcrumb_menu: Option<BreadcrumbMenu>,
    pub(in crate::root_view) key_focus: Option<FocusHandle>,
    pub(in crate::root_view) key_interceptor: Option<Subscription>,
    pub(in crate::root_view) events: EventListService,
    pub(in crate::root_view) events_started: bool,
    pub(in crate::root_view) enrollments_api: Arc<dyn EnrollmentsApi>,
    pub(in crate::root_view) enrollments_rows: Vec<MyEnrollmentRow>,
    pub(in crate::root_view) enrollments_state: EnrollmentsListState,
    pub(in crate::root_view) enrollments_started: bool,
    pub(in crate::root_view) detail: EventDetailService,
    pub(in crate::root_view) detail_started: bool,
    pub(in crate::root_view) selected_tier: Option<String>,
    pub(in crate::root_view) age_confirmed: bool,
    pub(in crate::root_view) enrolling: bool,
    pub(in crate::root_view) enrollment_error: Option<String>,
    pub(in crate::root_view) orders: Arc<dyn OrdersApi>,
    pub(in crate::root_view) payment: PaymentViewState,
    pub(in crate::root_view) payment_generation: u64,
    pub(in crate::root_view) deposit_consent: bool,
    pub(in crate::root_view) events_bus: Arc<MemoryEventBus>,
    pub(in crate::root_view) agent_panel_title_input: Option<Entity<InputState>>,
    pub(in crate::root_view) agent_panel_title_subscription: Option<Subscription>,
    pub(in crate::root_view) agent_panel_editing_title: bool,
    pub(in crate::root_view) agent_panel_title_hovered: bool,
    pub(in crate::root_view) history_sidebar:
        Option<crate::root_view::history_sidebar::HistorySidebar>,
    pub(in crate::root_view) history_dirty_seen: u64,
    pub(in crate::root_view) history_cleared_seen: u64,
    pub(in crate::root_view) chat: ChatUi,
    pub(in crate::root_view) agent_registry_rows: Vec<DetectedAgent>,
    pub(in crate::root_view) agent_registry_started: bool,
    pub(in crate::root_view) agent_registry_loading: bool,
    pub(in crate::root_view) agent_registry_error: Option<String>,
    pub(in crate::root_view) agent_installing: Option<String>,
    pub(in crate::root_view) agent_install_stage: Option<String>,
    pub(in crate::root_view) agent_auto_install_attempted: bool,
    pub(in crate::root_view) agent_install_error: Option<String>,
    pub(in crate::root_view) agent_registry_query: String,
    pub(in crate::root_view) chat_input: Option<Entity<gpui_kit::component::input::TextareaState>>,
    pub(in crate::root_view) chat_input_subscription: Option<Subscription>,
    pub(in crate::root_view) chat_input_pending_clear: bool,
    pub(in crate::root_view) agent_registry_search_focused: bool,
    pub(in crate::root_view) agent_registry_filter: AgentRegistryFilter,
    pub(in crate::root_view) courses: CourseCatalogService,
    pub(in crate::root_view) courses_started: bool,
    pub(in crate::root_view) course_enrollments: std::collections::BTreeMap<String, Option<String>>,
    pub(in crate::root_view) workspaces: WorkspaceService,
    pub(in crate::root_view) workspaces_started: bool,
    pub(in crate::root_view) workspace_menu_open: bool,
    pub(in crate::root_view) revoking: bool,
    pub(in crate::root_view) settings_error: Option<String>,
    pub(in crate::root_view) course_detail: CourseDetailService,
    pub(in crate::root_view) course_detail_started: bool,
    pub(in crate::root_view) content: CourseContentService,
    pub(in crate::root_view) projection: LearningProjectionService,
    pub(in crate::root_view) pending_link: Option<String>,
    pub(in crate::root_view) native_agent_highlight: Option<NativeAgentHighlight>,
    pub(in crate::root_view) native_chat_mode: bool,
    pub(in crate::root_view) native_agent_view:
        Option<gpui_kit::Entity<crate::native_agent_view::NativeAgentView>>,
    pub(in crate::root_view) native_runtime: Option<crate::native_runtime::NativeRuntimeHandle>,
    pub(in crate::root_view) native_scope: Option<crate::agent_scope::AgentScope>,
    pub(in crate::root_view) page_context: crate::page_context::PageContextState,
    pub(in crate::root_view) agent_mcp: Option<crate::native_panel_host::McpContext>,
    pub(in crate::root_view) agent_lease_pending: Option<u64>,
    pub(in crate::root_view) agent_authorization_serial: u64,
    /// 单后台 writer：SQLite 写不在 UI 线程执行。
    pub(in crate::root_view) store_writer: Option<cgc_agent_store::StoreWriter>,
    pub(in crate::root_view) review_event_keys: std::collections::HashSet<String>,
    pub(in crate::root_view) selected_event: Option<String>,
}

impl ShellState {
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
            theme_name: theme::load_selected_theme()
                .unwrap_or_else(|| theme::DEFAULT_THEME_NAME.to_string()),
            theme_menu_open: false,
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
            right_panel: RightPanel::SiteTree,
            right_panel_open: true,
            right_panel_width: 288.0,
            agent_panel_width: 380.0,
            resize_drag: None,
            tabs: Vec::new(),
            active_tab: None,
            pane_notice: None,
            window_handle: None,
            window_opening: false,
            close_to_tray: Arc::new(std::sync::atomic::AtomicBool::new(true)),
            tray_hint_shown: Arc::new(std::sync::atomic::AtomicBool::new(false)),
            notification_items: Vec::new(),
            notification_next_cursor: None,
            notification_filter: crate::notification_center::NotificationFilter::All,
            notification_loading: false,
            notification_loaded: false,
            notification_error: None,
            notification_scroll: ScrollHandle::new(),
            notification_seen: crate::notifications::load_seen(),
            notification_started: false,
            notification_responses: Arc::new(Mutex::new(Vec::new())),
            site_tree_events_open: false,
            site_tree_courses_open: false,
            site_tree_query: String::new(),
            site_tree_search_focused: false,
            site_tree_course_open: None,
            site_tree_scroll: ScrollHandle::new(),
            site_tree_scroll_restore: None,
            breadcrumb_menu: None,
            key_focus: None,
            key_interceptor: None,
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
            chat: ChatUi {
                selected_agent: load_selected_agent(),
                ..ChatUi::default()
            },
            agent_panel_title_input: None,
            agent_panel_title_subscription: None,
            agent_panel_editing_title: false,
            agent_panel_title_hovered: false,
            history_sidebar: None,
            history_dirty_seen: 0,
            history_cleared_seen: 0,
            agent_registry_rows: Vec::new(),
            agent_registry_started: false,
            agent_registry_loading: false,
            agent_registry_error: None,
            agent_installing: None,
            agent_install_stage: None,
            agent_auto_install_attempted: false,
            agent_install_error: None,
            agent_registry_query: String::new(),
            agent_registry_search_focused: false,
            chat_input: None,
            chat_input_subscription: None,
            chat_input_pending_clear: false,
            agent_registry_filter: AgentRegistryFilter::default(),
            courses,
            courses_started: false,
            course_enrollments: std::collections::BTreeMap::new(),
            course_detail,
            course_detail_started: false,
            content,
            projection,
            pending_link: None,
            native_agent_highlight: None,
            native_chat_mode: crate::chat_state::load_native_chat_mode().unwrap_or(true),
            native_agent_view: None,
            native_runtime: None,
            native_scope: None,
            page_context: Default::default(),
            agent_mcp: None,
            agent_lease_pending: None,
            agent_authorization_serial: 0,
            store_writer: None,
            review_event_keys: std::collections::HashSet::new(),
            workspaces: build_workspace_service(),
            workspaces_started: false,
            workspace_menu_open: std::env::var("CGC_WORKSPACE_MENU").as_deref() == Ok("open"),
            revoking: false,
            settings_error: None,
            selected_event: None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{close_tab, open_or_focus_tab, toggled_right_panel, PaneTab, RightPanel};

    #[test]
    fn right_panel_toggle_closes_same_and_switches_other() {
        assert_eq!(
            toggled_right_panel(RightPanel::SiteTree, true, RightPanel::SiteTree),
            (RightPanel::SiteTree, false)
        );
        assert_eq!(
            toggled_right_panel(RightPanel::SiteTree, true, RightPanel::Outline),
            (RightPanel::Outline, true)
        );
        assert_eq!(
            toggled_right_panel(RightPanel::Outline, false, RightPanel::SiteTree),
            (RightPanel::SiteTree, true)
        );
        assert_eq!(
            toggled_right_panel(RightPanel::SiteTree, true, RightPanel::Notifications),
            (RightPanel::Notifications, true)
        );
    }

    #[test]
    fn pane_tabs_dedupe_and_close_to_neighbor() {
        let mut tabs = Vec::new();
        let mut active = None;
        let first = PaneTab::page("/events", "Events");
        let second = PaneTab::page("/courses", "Courses");
        open_or_focus_tab(&mut tabs, first.clone(), &mut active);
        open_or_focus_tab(&mut tabs, second.clone(), &mut active);
        open_or_focus_tab(&mut tabs, first.clone(), &mut active);
        assert_eq!(tabs.len(), 2);
        assert_eq!(active.as_deref(), Some("page:/events"));

        let removed = close_tab(&mut tabs, &mut active, "page:/events").expect("removed");
        assert_eq!(removed.id, "page:/events");
        assert_eq!(tabs.len(), 1);
        assert_eq!(active.as_deref(), Some("page:/courses"));

        assert!(close_tab(&mut tabs, &mut active, "page:/courses").is_some());
        assert!(tabs.is_empty());
        assert!(active.is_none());
    }

    #[test]
    fn pane_issue_tab_keeps_course_learning_path() {
        let tab = PaneTab::issue("course-1", "issue-1", "Card");
        assert_eq!(tab.id, "issue:course-1:issue-1");
        assert_eq!(tab.path, "/courses/course-1/learn");
        assert_eq!(tab.issue_id.as_deref(), Some("issue-1"));
    }
}
