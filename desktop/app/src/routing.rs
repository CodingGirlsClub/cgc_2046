//! 可追加的路由注册表（脊柱 AD-9 的注册式 seam 的最小实现）。
//!
//! app 只做聚合；feature 通过各自的 `routes()` 注册模块向这里追加条目，
//! 不修改中央表。1.4 会把它扩展成完整的注册 seam 与 CI 检查。

/// 路由的稳定标识；重复注册视为编程错误，由 `register` 返回错误。
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct RouteId(pub &'static str);

/// 一条路由：id、路径与标题的词表 key。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Route {
    pub id: RouteId,
    pub path: &'static str,
    pub title_key: &'static str,
}

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
}

#[derive(Clone, Debug, Default)]
pub struct RouteRegistry {
    routes: Vec<Route>,
}

impl RouteRegistry {
    pub fn new() -> Self {
        Self { routes: Vec::new() }
    }

    /// 追加一条路由；id 或 path 重复时拒绝，保持注册表无冲突。
    pub fn register(&mut self, route: Route) -> Result<(), DuplicateRoute> {
        if self.routes.iter().any(|r| r.id == route.id) {
            return Err(DuplicateRoute::Id(route.id.0));
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

    const HOME: Route = Route {
        id: RouteId("home"),
        path: "/",
        title_key: "app.nav.home",
    };

    #[test]
    fn normal_startup_resolves_home() {
        let mut registry = RouteRegistry::new();
        registry.register(HOME).expect("home registers");
        assert_eq!(registry.select("/"), RouteSelection::Route(HOME));
    }

    #[test]
    fn register_keeps_insertion_order() {
        let mut registry = RouteRegistry::new();
        let second = Route {
            id: RouteId("second"),
            path: "/second",
            title_key: "app.nav.second",
        };
        registry.register(HOME).expect("home registers");
        registry.register(second).expect("second registers");
        assert_eq!(registry.routes(), &[HOME, second]);
    }

    #[test]
    fn duplicate_route_id_is_rejected() {
        let mut registry = RouteRegistry::new();
        registry.register(HOME).expect("home registers");
        let dup = Route {
            path: "/home",
            ..HOME
        };
        assert_eq!(registry.register(dup), Err(DuplicateRoute::Id("home")));
    }

    #[test]
    fn duplicate_path_is_rejected() {
        let mut registry = RouteRegistry::new();
        registry.register(HOME).expect("home registers");
        let dup = Route {
            id: RouteId("home-2"),
            ..HOME
        };
        assert_eq!(registry.register(dup), Err(DuplicateRoute::Path("/")));
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
