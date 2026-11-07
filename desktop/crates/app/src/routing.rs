//! 可追加的路由注册表（脊柱 AD-9 的注册式 seam）。
//!
//! story 3.2 起支持**动态段**（`/events/:id`）：
//! - 静态路由优先于动态路由（`/events/new` 不会命中 `/events/:id`）；
//! - 动态形状按「段数 + 静态段位置」去重，`/events/:id` 与 `/events/:slug` 视为冲突；
//! - 命中结果带参数表（`RouteMatch.params`），供详情页取 id。
//!
//! app 只做聚合；domain crate 通过各自的 `registration::ROUTES` 注册条目。

use std::collections::BTreeMap;

pub use cgc_platform::routes::Route;

/// 一次成功匹配：路由 + 动态段参数（`id` → "evt-001"）。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RouteMatch {
    pub route: Route,
    pub params: BTreeMap<&'static str, String>,
}

/// 路由选择结果：命中或落回空态页。
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RouteSelection {
    Match(RouteMatch),
    Fallback,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DuplicateRoute {
    Id(&'static str),
    Path(&'static str),
    /// 两个动态路由形状相同（段数/静态段位置一致），无法确定匹配优先级。
    AmbiguousPath(&'static str),
}

#[derive(Clone, Debug, Default)]
pub struct RouteRegistry {
    routes: Vec<Route>,
}

impl RouteRegistry {
    pub fn new() -> Self {
        Self { routes: Vec::new() }
    }

    /// 追加一条路由；重复 id/path 或动态形状冲突时拒绝。
    pub fn register(&mut self, route: Route) -> Result<(), DuplicateRoute> {
        if self.routes.iter().any(|existing| existing.id == route.id) {
            return Err(DuplicateRoute::Id(route.id));
        }
        if self
            .routes
            .iter()
            .any(|existing| existing.path == route.path)
        {
            return Err(DuplicateRoute::Path(route.path));
        }
        if route.has_dynamic_segment() {
            let shape = dynamic_shape(route.path);
            if self
                .routes
                .iter()
                .filter(|existing| existing.has_dynamic_segment())
                .any(|existing| dynamic_shape(existing.path) == shape)
            {
                return Err(DuplicateRoute::AmbiguousPath(route.path));
            }
        }
        self.routes.push(route);
        Ok(())
    }

    pub fn routes(&self) -> &[Route] {
        &self.routes
    }

    pub fn find(&self, id: &str) -> Option<Route> {
        self.routes.iter().copied().find(|route| route.id == id)
    }

    /// 按路径解析：静态精确命中优先，其次动态形状；未知路径落回空态页。
    pub fn select(&self, path: &str) -> RouteSelection {
        self.select_with_diagnostic(path).0
    }

    pub fn select_with_diagnostic(&self, path: &str) -> (RouteSelection, Option<&'static str>) {
        if let Some(route) = self.routes.iter().find(|route| route.path == path) {
            return (
                RouteSelection::Match(RouteMatch {
                    route: *route,
                    params: BTreeMap::new(),
                }),
                None,
            );
        }

        let segments: Vec<&str> = path
            .split('/')
            .filter(|segment| !segment.is_empty())
            .collect();
        let mut best: Option<(usize, RouteMatch)> = None;
        for route in self
            .routes
            .iter()
            .filter(|route| route.has_dynamic_segment())
        {
            let pattern: Vec<&str> = route
                .path
                .split('/')
                .filter(|segment| !segment.is_empty())
                .collect();
            if pattern.len() != segments.len() {
                continue;
            }

            let mut params = BTreeMap::new();
            let mut static_segments = 0;
            let mut matched = true;
            for (pattern_segment, value) in pattern.iter().zip(segments.iter()) {
                if let Some(name) = pattern_segment.strip_prefix(':') {
                    if value.is_empty() {
                        matched = false;
                        break;
                    }
                    params.insert(name, (*value).to_string());
                } else if pattern_segment == value {
                    static_segments += 1;
                } else {
                    matched = false;
                    break;
                }
            }
            if !matched {
                continue;
            }

            let candidate = RouteMatch {
                route: *route,
                params,
            };
            match &best {
                Some((best_static, _)) if *best_static >= static_segments => {}
                _ => best = Some((static_segments, candidate)),
            }
        }

        match best {
            Some((_, route_match)) => (RouteSelection::Match(route_match), None),
            None => (
                RouteSelection::Fallback,
                Some("unknown route, fallback to empty state"),
            ),
        }
    }
}

/// 工作区面的路由 id：这些页面必须挂在 `/w/<slug>` 下，数据按工作区隔离。
const WORKSPACE_ROUTES: &[&str] = &[
    "account.workspace",
    "events.list",
    "events.detail",
    "courses.catalog",
    "courses.detail",
    "courses.learning",
];

/// 列表页的数据面：工作区隔离，或全平台公开。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ListScope {
    Workspace,
    Public,
}

/// 只有列表页需要决定数据面；详情页按 id 读取，由后端策略裁决可见性。
pub(crate) fn offering_list_scope(route_id: &str) -> Option<ListScope> {
    match route_id {
        "account.workspace" | "events.list" | "courses.catalog" => Some(ListScope::Workspace),
        "events.public_list" | "courses.public_list" => Some(ListScope::Public),
        _ => None,
    }
}

/// 缓存所属的数据面与目标列表页不同 → 必须重载；缓存尚未建立（None）不重载。
pub(crate) fn list_scope_needs_reload(cached: Option<ListScope>, next: ListScope) -> bool {
    cached.is_some_and(|cached| cached != next)
}

/// 站点级条目按其所属工作区定位；无访问权时保留站点级路径，不借用当前台。
pub(crate) fn offering_path(
    workspaces: &[cgc_platform::workspace::WorkspaceSummary],
    workspace_id: Option<&str>,
    suffix: &str,
) -> String {
    match workspaces
        .iter()
        .find(|workspace| Some(workspace.id.as_str()) == workspace_id && workspace.can_access)
    {
        Some(workspace) => workspace_path(&workspace.slug, suffix),
        None => suffix.to_string(),
    }
}

/// 路由 slug 与当前工作区的关系；副作用由调用方执行。
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum WorkspaceRouteAction {
    Keep,
    Switch { id: String, slug: String },
    Inaccessible,
}

pub(crate) fn route_workspace_action(
    route_slug: Option<&str>,
    current_slug: Option<&str>,
    workspaces: &[cgc_platform::workspace::WorkspaceSummary],
) -> WorkspaceRouteAction {
    let Some(slug) = route_slug else {
        return WorkspaceRouteAction::Keep;
    };
    if current_slug == Some(slug) {
        return WorkspaceRouteAction::Keep;
    }
    match workspaces
        .iter()
        .find(|workspace| workspace.slug == slug && workspace.can_access)
    {
        Some(workspace) => WorkspaceRouteAction::Switch {
            id: workspace.id.clone(),
            slug: slug.to_string(),
        },
        None => WorkspaceRouteAction::Inaccessible,
    }
}

/// 去掉 `/w/<slug>` 前缀，得到站点级相对路径；概览返回 `/`。
pub(crate) fn without_workspace_prefix(path: &str) -> &str {
    let Some(slug) = workspace_slug(path) else {
        return path;
    };
    let Some(rest) = path
        .strip_prefix("/w/")
        .and_then(|rest| rest.strip_prefix(slug))
    else {
        return path;
    };
    if rest.is_empty() {
        "/"
    } else if rest.starts_with('/') {
        rest
    } else {
        path
    }
}

/// 工作区面路径：`slug` + 以 `/` 开头的后缀；空后缀得到概览。
pub(crate) fn workspace_path(slug: &str, suffix: &str) -> String {
    debug_assert!(suffix.is_empty() || suffix.starts_with('/'));
    format!("/w/{slug}{suffix}")
}

/// `/w/<slug>` 前缀里的工作区 slug；站点级路径返回 `None`。
pub(crate) fn workspace_slug(path: &str) -> Option<&str> {
    let mut segments = path.split('/').filter(|segment| !segment.is_empty());
    if segments.next()? != "w" {
        return None;
    }
    let slug = segments.next()?;
    is_safe_slug(slug).then_some(slug)
}

/// slug 来自 URL/深链，拒绝路径穿越与非法字符，避免把任意段当成工作区。
pub(crate) fn is_safe_slug(slug: &str) -> bool {
    !slug.is_empty()
        && slug != "."
        && slug != ".."
        && slug
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || ch == '-' || ch == '_')
}

/// 当前路由是否属于工作区面（决定空工作区时是否阻断渲染与加载）。
pub(crate) fn requires_workspace(route_id: &str) -> bool {
    WORKSPACE_ROUTES.contains(&route_id)
}

/// 恢复 tab 时的归属校验：站点级 tab 全局保留，工作区 tab 必须属于当前 slug。
pub(crate) fn tab_belongs_to(path: &str, current_slug: Option<&str>) -> bool {
    match workspace_slug(path) {
        None => true,
        Some(slug) => current_slug == Some(slug),
    }
}

/// `/` 的落点：上次工作区概览；没有记录则落到跨工作区的「我的学习」。
pub(crate) fn home_target(last_slug: Option<&str>) -> String {
    match last_slug.filter(|slug| is_safe_slug(slug)) {
        Some(slug) => format!("/w/{slug}"),
        None => "/learning".to_string(),
    }
}

fn dynamic_shape(path: &str) -> String {
    path.split('/')
        .filter(|segment| !segment.is_empty())
        .map(|segment| {
            if segment.starts_with(':') {
                ":"
            } else {
                segment
            }
        })
        .collect::<Vec<_>>()
        .join("/")
}

#[cfg(test)]
mod tests {
    use super::*;
    use cgc_platform::routes::NavIcon;

    const HOME: Route = Route::new("home", "/", "app.nav.home", NavIcon::Home);
    const EVENTS: Route = Route::new(
        "events.list",
        "/events",
        "events.list.title",
        NavIcon::Events,
    );
    const EVENT_DETAIL: Route = Route::new(
        "events.detail",
        "/events/:id",
        "events.detail.title",
        NavIcon::Events,
    );
    const EVENT_NEW: Route = Route::new(
        "events.new",
        "/events/new",
        "events.detail.title",
        NavIcon::Events,
    );

    fn registry() -> RouteRegistry {
        let mut registry = RouteRegistry::new();
        registry.register(HOME).expect("home");
        registry.register(EVENTS).expect("events");
        registry.register(EVENT_NEW).expect("events new");
        registry.register(EVENT_DETAIL).expect("event detail");
        registry
    }

    #[test]
    fn workspace_slug_is_parsed_only_from_the_w_prefix() {
        assert_eq!(workspace_slug("/w/2046"), Some("2046"));
        assert_eq!(workspace_slug("/w/2046/events"), Some("2046"));
        assert_eq!(workspace_slug("/w/2046/"), Some("2046"));
        assert_eq!(workspace_slug("/learning"), None);
        assert_eq!(workspace_slug("/w"), None);
        assert_eq!(workspace_slug("/w/"), None);
        assert_eq!(workspace_slug("/w/../events"), None);
        assert_eq!(workspace_slug("/w/2046 x/events"), None);
    }

    #[test]
    fn workspace_routes_are_explicit() {
        for route in [
            "account.workspace",
            "events.list",
            "events.detail",
            "courses.catalog",
            "courses.detail",
            "courses.learning",
        ] {
            assert!(
                requires_workspace(route),
                "{route} must require a workspace"
            );
        }
        for route in [
            "app.home",
            "courses.learning_home",
            "events.participations",
            "events.public_list",
            "events.public_detail",
            "courses.public_list",
            "courses.public_detail",
            "app.agents",
            "app.settings",
        ] {
            assert!(!requires_workspace(route), "{route} must be site-level");
        }
    }

    #[test]
    fn tabs_belong_to_a_workspace_only_when_paths_match() {
        assert!(tab_belongs_to("/learning", Some("a")));
        assert!(tab_belongs_to("/w/a/events", Some("a")));
        assert!(!tab_belongs_to("/w/b/events", Some("a")));
        assert!(!tab_belongs_to("/w/a/events", None));
    }

    #[test]
    fn workspace_paths_never_double_the_slash() {
        assert_eq!(workspace_path("2046", ""), "/w/2046");
        assert_eq!(workspace_path("2046", "/events"), "/w/2046/events");
        assert_eq!(
            workspace_path("2046", "/courses/c-1/learn"),
            "/w/2046/courses/c-1/learn"
        );
    }

    #[test]
    fn list_pages_declare_their_data_scope() {
        assert_eq!(
            offering_list_scope("events.public_list"),
            Some(ListScope::Public)
        );
        assert_eq!(
            offering_list_scope("courses.public_list"),
            Some(ListScope::Public)
        );
        assert_eq!(
            offering_list_scope("events.list"),
            Some(ListScope::Workspace)
        );
        assert_eq!(
            offering_list_scope("courses.catalog"),
            Some(ListScope::Workspace)
        );
        assert_eq!(
            offering_list_scope("account.workspace"),
            Some(ListScope::Workspace)
        );
        assert_eq!(offering_list_scope("events.detail"), None);
        assert_eq!(offering_list_scope("app.home"), None);
    }

    #[test]
    fn home_target_prefers_last_workspace() {
        assert_eq!(home_target(Some("2046")), "/w/2046");
        assert_eq!(home_target(None), "/learning");
        assert_eq!(home_target(Some("2046 x")), "/learning");
    }

    #[test]
    fn route_slug_decides_switch_or_inaccessible() {
        use cgc_platform::workspace::WorkspaceSummary;

        let workspaces = vec![
            WorkspaceSummary {
                id: "ws-a".into(),
                slug: "a".into(),
                name: "A".into(),
                my_role_names: vec![],
                member_count: None,
                can_access: true,
            },
            WorkspaceSummary {
                id: "ws-b".into(),
                slug: "b".into(),
                name: "B".into(),
                my_role_names: vec![],
                member_count: None,
                can_access: false,
            },
        ];
        assert_eq!(
            route_workspace_action(None, Some("a"), &workspaces),
            WorkspaceRouteAction::Keep
        );
        assert_eq!(
            route_workspace_action(Some("a"), Some("a"), &workspaces),
            WorkspaceRouteAction::Keep
        );
        assert_eq!(
            route_workspace_action(Some("a"), Some("b"), &workspaces),
            WorkspaceRouteAction::Switch {
                id: "ws-a".into(),
                slug: "a".into(),
            }
        );
        assert_eq!(
            route_workspace_action(Some("b"), Some("a"), &workspaces),
            WorkspaceRouteAction::Inaccessible
        );
        assert_eq!(
            route_workspace_action(Some("missing"), Some("a"), &workspaces),
            WorkspaceRouteAction::Inaccessible
        );
    }

    #[test]
    fn cached_list_scope_reloads_when_the_face_changes() {
        assert!(list_scope_needs_reload(
            Some(ListScope::Workspace),
            ListScope::Public
        ));
        assert!(list_scope_needs_reload(
            Some(ListScope::Public),
            ListScope::Workspace
        ));
        assert!(!list_scope_needs_reload(
            Some(ListScope::Workspace),
            ListScope::Workspace
        ));
        assert!(!list_scope_needs_reload(None, ListScope::Workspace));
        assert!(!list_scope_needs_reload(None, ListScope::Public));
    }

    #[test]
    fn workspace_prefix_is_stripped_for_relative_parsing() {
        assert_eq!(
            without_workspace_prefix("/w/2046/courses/c-1/learn"),
            "/courses/c-1/learn"
        );
        assert_eq!(without_workspace_prefix("/w/2046"), "/");
        assert_eq!(without_workspace_prefix("/learning"), "/learning");
        assert_eq!(
            without_workspace_prefix("/w/2046%20x/events"),
            "/w/2046%20x/events"
        );
    }

    #[test]
    fn normal_startup_resolves_home() {
        let selection = registry().select("/");
        assert_eq!(
            selection,
            RouteSelection::Match(RouteMatch {
                route: HOME,
                params: BTreeMap::new(),
            })
        );
    }

    #[test]
    fn dynamic_route_captures_param() {
        let selection = registry().select("/events/evt-123");
        let RouteSelection::Match(found) = selection else {
            panic!("expected a match");
        };
        assert_eq!(found.route.id, "events.detail");
        assert_eq!(found.params.get("id").map(String::as_str), Some("evt-123"));
    }

    #[test]
    fn static_route_wins_over_dynamic() {
        let selection = registry().select("/events/new");
        let RouteSelection::Match(found) = selection else {
            panic!("expected a match");
        };
        assert_eq!(found.route.id, "events.new");
        assert!(found.params.is_empty());
    }

    #[test]
    fn duplicate_route_id_is_rejected() {
        let mut registry = RouteRegistry::new();
        registry.register(HOME).expect("home");
        let dup = Route::new("home", "/home", "app.nav.home", NavIcon::Home);
        assert_eq!(registry.register(dup), Err(DuplicateRoute::Id("home")));
    }

    #[test]
    fn duplicate_path_is_rejected() {
        let mut registry = RouteRegistry::new();
        registry.register(HOME).expect("home");
        let dup = Route::new("home-2", "/", "app.nav.home", NavIcon::Home);
        assert_eq!(registry.register(dup), Err(DuplicateRoute::Path("/")));
    }

    #[test]
    fn ambiguous_dynamic_shape_is_rejected() {
        let mut registry = RouteRegistry::new();
        registry.register(EVENT_DETAIL).expect("detail");
        let ambiguous = Route::new(
            "events.detail-slug",
            "/events/:slug",
            "events.detail.title",
            NavIcon::Events,
        );
        assert_eq!(
            registry.register(ambiguous),
            Err(DuplicateRoute::AmbiguousPath("/events/:slug"))
        );
    }

    #[test]
    fn unknown_path_falls_back_with_diagnostic() {
        let registry = RouteRegistry::new();
        let (selection, diagnostic) = registry.select_with_diagnostic("/nope");
        assert_eq!(selection, RouteSelection::Fallback);
        assert!(
            diagnostic.is_some(),
            "unknown path must produce a diagnostic"
        );
    }
}
