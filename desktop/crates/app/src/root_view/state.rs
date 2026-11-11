use super::*;
use cgc_courses::notes::CourseNotesService;
use gpui_kit::component::tree::TreeState;
use std::collections::{BTreeMap, BTreeSet};
use std::sync::{Arc, Mutex};

/// 行内编辑中的笔记；只存在当前会话。
#[derive(Clone)]
pub(in crate::root_view) struct NoteEditState {
    pub(in crate::root_view) note_id: String,
    pub(in crate::root_view) input: gpui_kit::Entity<gpui_kit::component::input::InputState>,
}

/// 课程级 Notes 面板筛选。
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(in crate::root_view) enum NotesFilter {
    #[default]
    All,
    Notes,
    Retro,
}

/// 媒体（课程图片）的加载状态；只在内存缓存，不落盘。
pub(in crate::root_view) enum MediaState {
    Loading,
    Ready(Arc<RenderImage>),
    Failed,
}

/// 右侧 Dock 的互斥 panel。图标在 footer/header 切换，同一时间只显示一个。
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(in crate::root_view) enum RightPanel {
    #[default]
    SiteTree,
    Outline,
    Notes,
    Notifications,
}

/// 状态栏可隐藏的按钮（右键菜单 Hide Button）。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(in crate::root_view) enum StatusBarButton {
    History,
    Agent,
    Navigation,
    Outline,
}

/// 右侧 Dock 的持久化记忆；通知面板打开期间保持不变。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(in crate::root_view) struct PanelMemory {
    pub(in crate::root_view) panel: RightPanel,
    pub(in crate::root_view) open: bool,
}

impl Default for PanelMemory {
    fn default() -> Self {
        Self {
            panel: RightPanel::SiteTree,
            open: true,
        }
    }
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

/// 中心 Pane 的一个 Tab：身份就是完整地址（含 `?issue=` 这类定位参数）。
#[derive(Clone, Debug, PartialEq, Eq)]
pub(in crate::root_view) struct PaneTab {
    pub id: String,
    pub title: String,
    pub path: String,
}

impl PaneTab {
    pub(in crate::root_view) fn page(path: &str, title: impl Into<String>) -> Self {
        Self {
            id: format!("page:{path}"),
            title: title.into(),
            path: path.to_string(),
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

/// 路由切换后 active tab 的归属：同路径保留当前 tab，否则取第一个同路径 tab。
pub(in crate::root_view) fn active_tab_for_path(
    tabs: &[PaneTab],
    current: Option<&str>,
    path: &str,
) -> Option<String> {
    if let Some(current) = current {
        if tabs.iter().any(|tab| tab.id == current && tab.path == path) {
            return Some(current.to_string());
        }
    }
    tabs.iter()
        .find(|tab| tab.path == path)
        .map(|tab| tab.id.clone())
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
    /// 当前工作区面路径；无工作区时返回 None（站点级页面自行兜底）。
    pub(in crate::root_view) fn workspace_path(&self, suffix: &str) -> Option<String> {
        self.workspaces
            .current()
            .map(|workspace| crate::routing::workspace_path(&workspace.slug, suffix))
    }

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
    /// 最近使用的工作区 slug（启动时读本地状态；测试可注入空值）。
    pub(in crate::root_view) last_workspace_slug: Option<String>,
    /// 列表缓存所属的数据面；详情页等无 scope 的路由不改变它。
    pub(in crate::root_view) events_scope: Option<crate::routing::ListScope>,
    pub(in crate::root_view) courses_scope: Option<crate::routing::ListScope>,
    pub(in crate::root_view) language: Language,
    pub(in crate::root_view) preference: ThemePreference,
    pub(in crate::root_view) theme_name: String,
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
    pub(in crate::root_view) agent_panel_open: bool,
    pub(in crate::root_view) right_panel: RightPanel,
    pub(in crate::root_view) right_panel_open: bool,
    /// 通知面板不覆盖右侧 Dock 的记忆。
    pub(in crate::root_view) panel_memory: PanelMemory,
    pub(in crate::root_view) right_panel_width: f32,
    pub(in crate::root_view) agent_panel_width: f32,
    /// 只有显式拖宽或开合面板才创建覆盖；导航保存保留默认继承。
    pub(in crate::root_view) workspace_layout_overridden: bool,
    /// 面板停靠侧；右键菜单 Dock Left / Dock Right 修改。
    pub(in crate::root_view) agent_panel_side: crate::preferences::PanelSide,
    pub(in crate::root_view) dock_side: crate::preferences::PanelSide,
    /// Window & Layout / Panels 的显示偏好快照；设置窗口写入后由 apply 刷新。
    pub(in crate::root_view) display_preferences: crate::preferences::Preferences,
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
    pub(in crate::root_view) site_tree_search_input:
        Option<Entity<gpui_kit::component::input::InputState>>,
    pub(in crate::root_view) site_tree_search_subscription: Option<Subscription>,
    pub(in crate::root_view) site_tree_search_language: Option<Language>,
    pub(in crate::root_view) site_tree_search_focused: bool,
    pub(in crate::root_view) site_tree_course_open: Option<String>,
    pub(in crate::root_view) site_tree_scroll: ScrollHandle,
    pub(in crate::root_view) site_tree_scroll_restore: Option<f32>,
    /// Outline 目录树；课程内容加载后惰性创建。
    pub(in crate::root_view) outline_tree: Option<Entity<TreeState>>,
    pub(in crate::root_view) outline_tree_subscription: Option<Subscription>,
    /// 当前树对应的 (course_id, revision)；变化时才重建 items。
    pub(in crate::root_view) outline_tree_key: Option<(String, Option<i64>)>,
    /// 按业务 id 保存的展开节点，跨重启恢复。
    pub(in crate::root_view) outline_expanded: BTreeSet<String>,
    /// 课程图片下载/解码结果（URL → 状态）；上限见 `media::MEDIA_CACHE_LIMIT`。
    pub(in crate::root_view) media_cache: BTreeMap<String, MediaState>,
    /// 正在下载的 URL，防止每帧重复发起请求。
    pub(in crate::root_view) media_loading: BTreeSet<String>,
    /// 已完成的课程材料 key（`course:revision:issue:material`）。
    pub(in crate::root_view) completed_materials: BTreeSet<String>,
    /// 每个 Issue 当前展开的材料 key（同一 Issue 单开）。
    pub(in crate::root_view) expanded_material: BTreeMap<String, String>,
    /// 每个 Issue 当前选中的 objective；按 issue scope 记忆，跨 tab 保留。
    pub(in crate::root_view) selected_objective: BTreeMap<String, String>,
    /// 选中的 objective 的 rubric / 任务材料折叠状态。
    pub(in crate::root_view) expanded_objective_rubric: BTreeSet<String>,
    pub(in crate::root_view) expanded_objective_materials: BTreeSet<String>,
    /// objective 行的持久焦点句柄（`track_focus`）：Tab 可聚焦、Enter/Space 激活。
    pub(in crate::root_view) objective_row_focus: std::collections::HashMap<String, FocusHandle>,
    /// 材料动作行的持久焦点句柄（key: `scope:index`），覆盖展开/打开/重试。
    pub(in crate::root_view) material_action_focus: std::collections::HashMap<String, FocusHandle>,
    /// 点击后等待图片下载完成再打开 Viewer：URL → 窗口标题。
    pub(in crate::root_view) pending_image_opens: BTreeMap<String, String>,
    pub(in crate::root_view) key_focus: Option<FocusHandle>,
    pub(in crate::root_view) key_interceptor: Option<Subscription>,
    pub(in crate::root_view) events: EventListService,
    pub(in crate::root_view) events_started: bool,
    /// 列表请求代次：迟到响应只有代次与 scope 都匹配时才允许落地（R2）。
    pub(in crate::root_view) events_load_serial: u64,
    pub(in crate::root_view) enrollments_api: Arc<dyn EnrollmentsApi>,
    pub(in crate::root_view) enrollments_rows: Vec<MyEnrollmentRow>,
    pub(in crate::root_view) learning_runs: Vec<MyLearningRunRow>,
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
    /// 进入编辑时的标题快照：提交时值没变就不写 override（点进来又点走不算重命名）。
    pub(in crate::root_view) agent_panel_title_original: Option<String>,
    pub(in crate::root_view) agent_panel_title_subscription: Option<Subscription>,
    /// native 面板事件订阅：标题生成中/失败/完成时重绘 header。
    pub(in crate::root_view) native_agent_view_subscription: Option<Subscription>,
    pub(in crate::root_view) agent_panel_editing_title: bool,
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
    pub(in crate::root_view) courses_load_serial: u64,
    /// Site Tree 专用缓存：恒为本工作区数据面，与中心列表（可能是公开面）互不覆盖。
    pub(in crate::root_view) nav_events: EventListService,
    pub(in crate::root_view) nav_events_started: bool,
    pub(in crate::root_view) nav_events_serial: u64,
    pub(in crate::root_view) nav_courses: CourseCatalogService,
    pub(in crate::root_view) nav_courses_started: bool,
    pub(in crate::root_view) nav_courses_serial: u64,
    /// 账号代数：登录/登出时递增；跨账号的在途响应必须丢弃（切台由 workspace epoch 管）。
    pub(in crate::root_view) session_epoch: u64,
    pub(in crate::root_view) course_enrollments: std::collections::BTreeMap<String, Option<String>>,
    /// M2：报名状态查询在途的课程 id，避免快速翻页时重复查询尚未落缓存的课程。
    pub(in crate::root_view) course_enrollments_inflight: std::collections::HashSet<String>,
    /// 分页请求失败：列表仍保留（Ready），仅在「加载更多」旁显示行内失败提示。
    pub(in crate::root_view) enrollments_load_more_failed: bool,
    /// R11：登录后已消费显式深链，首次工作区恢复必须保留当前路由，不被旧 active tab 覆盖。
    pub(in crate::root_view) deep_link_keep_route: bool,
    pub(in crate::root_view) workspaces: WorkspaceService,
    pub(in crate::root_view) workspaces_started: bool,
    pub(in crate::root_view) revoking: bool,
    pub(in crate::root_view) settings_error: Option<String>,
    pub(in crate::root_view) course_detail: CourseDetailService,
    pub(in crate::root_view) course_detail_started: bool,
    pub(in crate::root_view) content: CourseContentService,
    /// 课程 Notes：服务端真源的内存快照；切换课程/重载时整体替换。
    pub(in crate::root_view) notes: CourseNotesService,
    pub(in crate::root_view) notes_started: bool,
    pub(in crate::root_view) notes_load_serial: u64,
    /// 行内编辑中的笔记（不落盘；离开页面即丢弃）。
    pub(in crate::root_view) note_edit: Option<NoteEditState>,
    /// 等待二次确认删除的笔记 id。
    pub(in crate::root_view) note_pending_delete: Option<String>,
    /// 展开全文的笔记 id。
    pub(in crate::root_view) expanded_notes: BTreeSet<String>,
    /// 课程级 Notes 面板当前选中的筛选。
    pub(in crate::root_view) notes_filter: NotesFilter,
    /// 当前选区来源材料（material.id）；由材料正文 mouse-down 记录。
    pub(in crate::root_view) selection_material_id: Option<String>,
    /// Notes 操作的一次性提示（已加入/重复/失败）。
    pub(in crate::root_view) notes_notice: Option<String>,
    /// 已触发过 Retro 检查的 `course:revision:issue`，避免每次投影刷新重复请求。
    pub(in crate::root_view) retro_checked: BTreeSet<String>,
    pub(in crate::root_view) projection: LearningProjectionService,
    /// 提交成功时投影仍在加载：当前请求结束后需要再拉一次。
    pub(in crate::root_view) projection_refresh_pending: bool,
    /// 页面选区浮层：解释/总结/复制。
    pub(in crate::root_view) selection_popover: Option<super::SelectionPopover>,
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
    pub(in crate::root_view) agent_authorization_tail:
        Option<super::agent_session::AuthorizationTail>,
    pub(in crate::root_view) agent_authorization_error: Option<McpError>,
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
        Self::with_session_from(registry, language, preference, session, None)
    }

    pub(in crate::root_view) fn with_session_from(
        registry: RouteRegistry,
        language: Language,
        preference: ThemePreference,
        session: SessionService,
        start_path: Option<&str>,
    ) -> Self {
        let last_workspace_slug = if start_path.is_some() {
            None
        } else {
            crate::workspace_state::last_workspace()
        };
        let current = initial_route(&registry, start_path, last_workspace_slug.as_deref());
        let layout_preferences = crate::preferences::load();
        let events = build_events_service();
        let nav_events = build_events_service();
        let detail = EventDetailService::new(events.api_handle());
        let courses = build_courses_service();
        let nav_courses = build_courses_service();
        let course_detail = CourseDetailService::new(courses.api_handle());
        let content = CourseContentService::new(courses.api_handle());
        let notes = build_notes_service();
        let projection = LearningProjectionService::new(courses.api_handle());
        Self {
            registry,
            current,
            last_workspace_slug,
            events_scope: None,
            courses_scope: None,
            language,
            preference,
            theme_name: theme::load_selected_theme()
                .unwrap_or_else(|| theme::DEFAULT_THEME_NAME.to_string()),
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
            agent_panel_open: true,
            right_panel: RightPanel::SiteTree,
            right_panel_open: true,
            panel_memory: PanelMemory::default(),
            right_panel_width: layout_preferences.dock_width as f32,
            agent_panel_width: layout_preferences.agent_panel_width as f32,
            workspace_layout_overridden: false,
            agent_panel_side: layout_preferences.agent_panel_side,
            dock_side: layout_preferences.dock_side,
            display_preferences: layout_preferences,
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
            site_tree_search_input: None,
            site_tree_search_subscription: None,
            site_tree_search_language: None,
            site_tree_search_focused: false,
            site_tree_course_open: None,
            site_tree_scroll: ScrollHandle::new(),
            site_tree_scroll_restore: None,
            outline_tree: None,
            outline_tree_subscription: None,
            outline_tree_key: None,
            outline_expanded: BTreeSet::new(),
            media_cache: BTreeMap::new(),
            media_loading: BTreeSet::new(),
            completed_materials: BTreeSet::new(),
            expanded_material: BTreeMap::new(),
            selected_objective: BTreeMap::new(),
            expanded_objective_rubric: BTreeSet::new(),
            expanded_objective_materials: BTreeSet::new(),
            objective_row_focus: std::collections::HashMap::new(),
            material_action_focus: std::collections::HashMap::new(),
            pending_image_opens: BTreeMap::new(),
            key_focus: None,
            key_interceptor: None,
            events,
            events_started: false,
            events_load_serial: 0,
            enrollments_api: build_enrollments_api(),
            enrollments_rows: Vec::new(),
            learning_runs: Vec::new(),
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
            agent_panel_title_original: None,
            agent_panel_title_subscription: None,
            native_agent_view_subscription: None,
            agent_panel_editing_title: false,
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
            courses_load_serial: 0,
            nav_events,
            nav_events_started: false,
            nav_events_serial: 0,
            nav_courses,
            nav_courses_started: false,
            nav_courses_serial: 0,
            session_epoch: 0,
            course_enrollments: std::collections::BTreeMap::new(),
            course_enrollments_inflight: std::collections::HashSet::new(),
            enrollments_load_more_failed: false,
            deep_link_keep_route: false,
            course_detail,
            course_detail_started: false,
            content,
            notes,
            notes_started: false,
            notes_load_serial: 0,
            note_edit: None,
            note_pending_delete: None,
            expanded_notes: BTreeSet::new(),
            notes_filter: NotesFilter::All,
            selection_material_id: None,
            notes_notice: None,
            retro_checked: BTreeSet::new(),
            projection,
            projection_refresh_pending: false,
            selection_popover: None,
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
            agent_authorization_tail: None,
            agent_authorization_error: None,
            store_writer: None,
            review_event_keys: std::collections::HashSet::new(),
            workspaces: build_workspace_service(),
            workspaces_started: false,
            revoking: false,
            settings_error: None,
            selected_event: None,
        }
    }
}

/// R4：只有「工作区列表从空变非空 + 当前是公开列表 + 存在无归属课程」才补查。
pub(in crate::root_view) fn should_backfill_public_ownership(
    had_accessible_workspaces: bool,
    has_accessible_workspaces: bool,
    scope: Option<crate::routing::ListScope>,
    has_unowned_public_course: bool,
) -> bool {
    !had_accessible_workspaces
        && has_accessible_workspaces
        && scope == Some(crate::routing::ListScope::Public)
        && has_unowned_public_course
}

/// R11：本次是否已消费显式深链；是则首次工作区恢复必须保留当前路由。
pub(in crate::root_view) fn should_keep_initial_route(deep_link_consumed: bool) -> bool {
    deep_link_consumed
}

/// R15：报名重复错误必须触发权威状态刷新（与活动分支同口径）。
pub(in crate::root_view) fn enrollment_error_needs_refresh(code: &str) -> bool {
    code == "enrollment_duplicate_active"
}

/// M2：该课程既未缓存也未在途时才应发起报名状态查询。
pub(in crate::root_view) fn should_query_course_enrollment(
    course_id: &str,
    cached: &std::collections::BTreeMap<String, Option<String>>,
    inflight: &std::collections::HashSet<String>,
) -> bool {
    !cached.contains_key(course_id) && !inflight.contains(course_id)
}

#[cfg(test)]
mod tests {
    use super::{
        active_tab_for_path, close_tab, open_or_focus_tab, toggled_right_panel, PaneTab, RightPanel,
    };

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
    fn issue_tab_identity_lives_in_its_address() {
        let card = PaneTab::page("/w/2046/courses/course-1/learn?issue=issue-1", "Card");
        let lesson = PaneTab::page("/w/2046/courses/course-1/learn", "Course");
        assert_eq!(card.id, "page:/w/2046/courses/course-1/learn?issue=issue-1");
        assert_ne!(
            card.path, lesson.path,
            "cards and the lesson are distinct pages"
        );
        assert_eq!(
            crate::routing::issue_of(&card.path),
            Some("issue-1"),
            "the card id is read back from the address"
        );
    }

    #[test]
    fn navigating_keeps_a_matching_active_tab_and_clears_a_stale_one() {
        let issue_a = PaneTab::page("/w/2046/courses/course-1/learn?issue=issue-1", "Card A");
        let issue_b = PaneTab::page("/w/2046/courses/course-1/learn?issue=issue-2", "Card B");
        let event = PaneTab::page("/w/2046/events/event-1", "Event");
        let tabs = vec![issue_a.clone(), issue_b.clone(), event.clone()];

        assert_eq!(
            active_tab_for_path(&tabs, Some(issue_b.id.as_str()), &issue_b.path),
            Some(issue_b.id.clone()),
            "same-address card keeps the user's current card"
        );
        assert_eq!(
            active_tab_for_path(&tabs, Some(event.id.as_str()), &issue_a.path),
            Some(issue_a.id.clone()),
            "a different active tab moves to the tab for the new address"
        );
        assert_eq!(
            active_tab_for_path(&tabs, Some(issue_a.id.as_str()), "/settings"),
            None,
            "no matching tab must clear stale context"
        );
    }

    #[test]
    fn stage2_backfill_requires_workspaces_and_public_scope() {
        assert!(super::should_backfill_public_ownership(
            false,
            true,
            Some(crate::routing::ListScope::Public),
            true
        ));
        assert!(!super::should_backfill_public_ownership(
            true,
            true,
            Some(crate::routing::ListScope::Public),
            true
        ));
        assert!(!super::should_backfill_public_ownership(
            false,
            true,
            Some(crate::routing::ListScope::Workspace),
            true
        ));
        assert!(!super::should_backfill_public_ownership(
            false,
            true,
            Some(crate::routing::ListScope::Public),
            false
        ));
    }

    #[test]
    fn stage2_deep_link_consumption_keeps_initial_route() {
        assert!(super::should_keep_initial_route(true));
        assert!(!super::should_keep_initial_route(false));
    }

    #[test]
    fn stage2_enrollment_query_skips_cached_and_inflight_courses() {
        let mut cached = std::collections::BTreeMap::new();
        cached.insert("crs-cached".to_string(), None);
        let mut inflight = std::collections::HashSet::new();
        inflight.insert("crs-inflight".to_string());
        assert!(!super::should_query_course_enrollment(
            "crs-cached",
            &cached,
            &inflight
        ));
        assert!(!super::should_query_course_enrollment(
            "crs-inflight",
            &cached,
            &inflight
        ));
        assert!(super::should_query_course_enrollment(
            "crs-new", &cached, &inflight
        ));
    }

    #[test]
    fn stage2_duplicate_enrollment_error_requires_refresh() {
        assert!(super::enrollment_error_needs_refresh(
            "enrollment_duplicate_active"
        ));
        assert!(!super::enrollment_error_needs_refresh(
            "enrollment_capacity_full"
        ));
    }
}
