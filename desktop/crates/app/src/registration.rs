//! 注册聚合与校验（story 1.4）：home + 各 domain crate 的路由/词表 key 汇总，
//! 启动时校验重复 key、缺词条；CI 跑同一套校验（`cargo test`）即可在冲突时变红。

use std::collections::BTreeMap;

use cgc_platform::routes::Route;

use crate::i18n::{self, Language};
use crate::routing::{DuplicateRoute, RouteRegistry};

/// app 自己的首页路由；domain 路由由各 crate 的 `registration::ROUTES` 提供。
pub const HOME: Route = Route::new("app.home", "/", "app.nav.home", "⌂");

/// 所有 domain crate 的路由集合；新增 feature 时在这里加一行。
pub fn domain_route_sets() -> Vec<(&'static str, &'static [Route])> {
    vec![
        ("account", cgc_account::registration::ROUTES),
        ("events", cgc_events::registration::ROUTES),
        ("courses", cgc_courses::registration::ROUTES),
        ("agent_chat", cgc_agent_chat::registration::ROUTES),
    ]
}

/// 所有 domain crate 的词表 key 集合（带 owner 名，便于冲突定位）。
pub fn domain_i18n_key_sets() -> Vec<(&'static str, &'static [&'static str])> {
    vec![
        ("account", cgc_account::registration::I18N_KEYS),
        ("events", cgc_events::registration::I18N_KEYS),
        ("courses", cgc_courses::registration::I18N_KEYS),
        ("agent_chat", cgc_agent_chat::registration::I18N_KEYS),
    ]
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RegistrationError {
    DuplicateRoute(DuplicateRoute),
    /// 同一个词表 key 出现在两处；owner 是 domain 名或 `route:<id>`。
    DuplicateKey {
        key: &'static str,
        first_owner: &'static str,
        second_owner: &'static str,
    },
    /// 注册的 key 在某个 locale 的词表里不存在。
    MissingTranslation {
        key: &'static str,
        locale: &'static str,
    },
}

/// 构建聚合注册表：home 在前，其余按 `domain_route_sets` 顺序。
pub fn build_registry() -> Result<RouteRegistry, RegistrationError> {
    build_registry_with(&domain_route_sets())
}

pub(crate) fn build_registry_with(
    sets: &[(&'static str, &'static [Route])],
) -> Result<RouteRegistry, RegistrationError> {
    let mut registry = RouteRegistry::new();
    registry
        .register(HOME)
        .map_err(RegistrationError::DuplicateRoute)?;
    for (_, routes) in sets {
        for route in *routes {
            registry
                .register(*route)
                .map_err(RegistrationError::DuplicateRoute)?;
        }
    }
    Ok(registry)
}

/// 校验：词表 key 不重复、每个 key 在 zh/en 都存在、每条路由标题可翻译且不重复。
pub fn validate(registry: &RouteRegistry) -> Result<(), RegistrationError> {
    validate_with(registry, &domain_i18n_key_sets())
}

pub(crate) fn validate_with(
    registry: &RouteRegistry,
    key_sets: &[(&'static str, &'static [&'static str])],
) -> Result<(), RegistrationError> {
    // owner map：domain key 与 route title key 放进同一张表，才能查出跨注册源的重复。
    let mut owners: BTreeMap<&'static str, &'static str> = BTreeMap::new();

    for (owner, keys) in key_sets {
        for key in *keys {
            if let Some(first_owner) = owners.insert(key, owner) {
                return Err(RegistrationError::DuplicateKey {
                    key,
                    first_owner,
                    second_owner: owner,
                });
            }
            ensure_translated(key)?;
        }
    }

    // route 标题 key 与所属 domain 的 I18N_KEYS 是同一个 key 属正常；只查 route 之间重复。
    let mut route_owners: BTreeMap<&'static str, &'static str> = BTreeMap::new();
    for route in registry.routes() {
        ensure_translated(route.title_key)?;
        let owner = route.id;
        if let Some(first_owner) = route_owners.insert(route.title_key, owner) {
            return Err(RegistrationError::DuplicateKey {
                key: route.title_key,
                first_owner,
                second_owner: owner,
            });
        }
    }
    Ok(())
}

fn ensure_translated(key: &'static str) -> Result<(), RegistrationError> {
    for language in Language::ALL {
        if !i18n::has_key(language, key) {
            return Err(RegistrationError::MissingTranslation {
                key,
                locale: language.code(),
            });
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const DUP_PATH_A: &[Route] = &[Route::new(
        "a.one",
        "/workspace",
        "account.workspace.title",
        "▤",
    )];
    const DUP_PATH_B: &[Route] = &[Route::new("b.one", "/workspace", "events.list.title", "▦")];

    #[test]
    fn aggregated_registry_contains_home_and_every_domain_route() {
        let registry = build_registry().expect("registry builds");
        let ids: Vec<_> = registry.routes().iter().map(|route| route.id).collect();
        assert_eq!(ids[0], HOME.id);
        for (_, routes) in domain_route_sets() {
            for route in routes {
                assert!(ids.contains(&route.id), "missing route {}", route.id);
            }
        }
    }

    #[test]
    fn aggregated_registration_passes_i18n_validation() {
        let registry = build_registry().expect("registry builds");
        validate(&registry).expect("registered keys exist in every locale");
    }

    #[test]
    fn duplicate_route_path_across_domains_is_reported() {
        let sets = [("a", DUP_PATH_A), ("b", DUP_PATH_B)];
        let err = build_registry_with(&sets).unwrap_err();
        assert_eq!(
            err,
            RegistrationError::DuplicateRoute(DuplicateRoute::Path("/workspace"))
        );
    }

    #[test]
    fn duplicate_key_across_domains_is_reported_with_owners() {
        const ACCOUNT_KEYS: &[&str] = &["account.workspace.title"];
        const EVENTS_KEYS: &[&str] = &["account.workspace.title"];
        let registry = build_registry().expect("registry builds");
        let sets = [("account", ACCOUNT_KEYS), ("events", EVENTS_KEYS)];
        let err = validate_with(&registry, &sets).unwrap_err();
        assert_eq!(
            err,
            RegistrationError::DuplicateKey {
                key: "account.workspace.title",
                first_owner: "account",
                second_owner: "events",
            }
        );
    }

    #[test]
    fn missing_translation_is_reported_with_key_and_locale() {
        const MISSING_KEYS: &[&str] = &["nope.missing.key"];
        let registry = RouteRegistry::new();
        let sets = [("ghost", MISSING_KEYS)];
        let err = validate_with(&registry, &sets).unwrap_err();
        assert_eq!(
            err,
            RegistrationError::MissingTranslation {
                key: "nope.missing.key",
                locale: "zh",
            }
        );
    }

    #[test]
    fn duplicate_route_title_key_is_reported() {
        const TITLE_A: &[Route] = &[Route::new("a.one", "/a", "account.workspace.title", "▤")];
        const TITLE_B: &[Route] = &[Route::new("b.one", "/b", "account.workspace.title", "▤")];
        let sets = [("a", TITLE_A), ("b", TITLE_B)];
        let registry = build_registry_with(&sets).expect("registry builds");
        let err = validate_with(&registry, &[]).unwrap_err();
        assert_eq!(
            err,
            RegistrationError::DuplicateKey {
                key: "account.workspace.title",
                first_owner: "a.one",
                second_owner: "b.one",
            }
        );
    }

    #[test]
    fn baseline_registration_stays_valid() {
        let registry = build_registry().expect("registry builds");
        validate(&registry).expect("baseline valid");
    }
}
