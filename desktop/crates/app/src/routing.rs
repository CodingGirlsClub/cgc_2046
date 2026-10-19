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
