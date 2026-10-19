//! 可追加的路由注册表（脊柱 AD-9/AD-10 的注册式 seam）。
//!
//! app 只做聚合；domain crate 通过各自的 `registration::ROUTES` 注册条目，
//! 不修改中央表。注册时拒绝重复 id/path 与 v1 尚不支持的动态段（`:`），
//! 避免「动态路由遮蔽」在未定义规则时悄悄出现。

pub use cgc_platform::routes::Route;

/// 路由选择结果：命中某条路由，或落回空态页。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RouteSelection {
    Route(Route),
    Fallback,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DuplicateRoute {
    Id(&'static str),
    Path(&'static str),
    /// 动态段（`:`）在 v1 未支持：拒绝而不是让遮蔽规则缺失。
    DynamicPath(&'static str),
}

#[derive(Clone, Debug, Default)]
pub struct RouteRegistry {
    routes: Vec<Route>,
}

impl RouteRegistry {
    pub fn new() -> Self {
        Self { routes: Vec::new() }
    }

    /// 追加一条路由；id 或 path 重复、或路径含动态段时拒绝。
    pub fn register(&mut self, route: Route) -> Result<(), DuplicateRoute> {
        if route.has_dynamic_segment() {
            return Err(DuplicateRoute::DynamicPath(route.path));
        }
        if self.routes.iter().any(|r| r.id == route.id) {
            return Err(DuplicateRoute::Id(route.id));
        }
        if self.routes.iter().any(|r| r.path == route.path) {
            return Err(DuplicateRoute::Path(route.path));
        }
        self.routes.push(route);
        Ok(())
    }

    pub fn routes(&self) -> &[Route] {
        &self.routes
    }

    /// 按路径解析；未知路径落回空态页。
    pub fn select(&self, path: &str) -> RouteSelection {
        self.select_with_diagnostic(path).0
    }

    /// 同 `select`，额外返回给调用方记录用的诊断信息（未知路径时非空）。
    pub fn select_with_diagnostic(&self, path: &str) -> (RouteSelection, Option<&'static str>) {
        match self.routes.iter().find(|r| r.path == path) {
            Some(route) => (RouteSelection::Route(*route), None),
            None => (
                RouteSelection::Fallback,
                Some("unknown route, fallback to empty state"),
            ),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const HOME: Route = Route::new("home", "/", "app.nav.home");

    #[test]
    fn normal_startup_resolves_home() {
        let mut registry = RouteRegistry::new();
        registry.register(HOME).expect("home registers");
        assert_eq!(registry.select("/"), RouteSelection::Route(HOME));
    }

    #[test]
    fn register_keeps_insertion_order() {
        let mut registry = RouteRegistry::new();
        let second = Route::new("second", "/second", "app.nav.second");
        registry.register(HOME).expect("home registers");
        registry.register(second).expect("second registers");
        assert_eq!(registry.routes(), &[HOME, second]);
    }

    #[test]
    fn duplicate_route_id_is_rejected() {
        let mut registry = RouteRegistry::new();
        registry.register(HOME).expect("home registers");
        let dup = Route::new("home", "/home", "app.nav.home");
        assert_eq!(registry.register(dup), Err(DuplicateRoute::Id("home")));
    }

    #[test]
    fn duplicate_path_is_rejected() {
        let mut registry = RouteRegistry::new();
        registry.register(HOME).expect("home registers");
        let dup = Route::new("home-2", "/", "app.nav.home");
        assert_eq!(registry.register(dup), Err(DuplicateRoute::Path("/")));
    }

    #[test]
    fn dynamic_path_is_rejected_until_supported() {
        let mut registry = RouteRegistry::new();
        let dynamic = Route::new("events.detail", "/events/:id", "events.list.title");
        assert_eq!(
            registry.register(dynamic),
            Err(DuplicateRoute::DynamicPath("/events/:id"))
        );
    }

    #[test]
    fn unknown_path_falls_back_with_diagnostic() {
        let registry = RouteRegistry::new();
        let (selection, diagnostic) = registry.select_with_diagnostic("/nope");
        assert_eq!(selection, RouteSelection::Fallback);
        assert!(
            diagnostic.is_some(),
            "unknown path must produce a diagnostic to log"
        );
    }

    #[test]
    fn empty_registry_has_no_routes() {
        let registry = RouteRegistry::new();
        assert!(registry.routes().is_empty());
    }
}
