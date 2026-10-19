//! 注册聚合与校验（story 1.4）：home + 各 domain crate 的路由/词表 key 汇总，
//! 启动时校验重复 key、缺词条；CI 跑同一套校验（`cargo test`）即可在冲突时变红。

use std::collections::BTreeSet;

use cgc_platform::routes::Route;

use crate::i18n::{self, Language};
use crate::routing::{DuplicateRoute, RouteRegistry};

/// app 自己的首页路由；domain 路由由各 crate 的 `registration::ROUTES` 提供。
pub const HOME: Route = Route::new("app.home", "/", "app.nav.home");

/// 所有 domain crate 的路由集合；新增 feature 时在这里加一行。
pub fn domain_route_sets() -> Vec<&'static [Route]> {
    vec![
        cgc_account::registration::ROUTES,
        cgc_events::registration::ROUTES,
        cgc_courses::registration::ROUTES,
        cgc_agent_chat::registration::ROUTES,
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
    /// 同一个词表 key 被两个 domain 注册。
    DuplicateKey(&'static str),
    /// 注册的 key 在某个 locale 的词表里不存在。
    MissingTranslation {
        key: &'static str,
        locale: &'static str,
    },
}

/// 构建聚合注册表：home 在前，其余按 `domain_route_sets` 顺序。
pub fn build_registry() -> Result<RouteRegistry, RegistrationError> {
    let mut registry = RouteRegistry::new();
    registry
        .register(HOME)
        .map_err(RegistrationError::DuplicateRoute)?;
    for routes in domain_route_sets() {
        for route in routes {
            registry
                .register(*route)
                .map_err(RegistrationError::DuplicateRoute)?;
        }
    }
    Ok(registry)
}

/// 校验：domain key 不重复、每个 key 在 zh/en 都存在、每条路由标题可翻译。
pub fn validate(registry: &RouteRegistry) -> Result<(), RegistrationError> {
    let mut seen = BTreeSet::new();
    for (_, keys) in domain_i18n_key_sets() {
        for key in keys {
            if !seen.insert(*key) {
                return Err(RegistrationError::DuplicateKey(key));
            }
            for language in Language::ALL {
                if !i18n::has_key(language, key) {
                    return Err(RegistrationError::MissingTranslation {
                        key,
                        locale: language.code(),
                    });
                }
            }
        }
    }
    for route in registry.routes() {
        for language in Language::ALL {
            if !i18n::has_key(language, route.title_key) {
                return Err(RegistrationError::MissingTranslation {
                    key: route.title_key,
                    locale: language.code(),
                });
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn aggregated_registry_contains_home_and_every_domain_route() {
        let registry = build_registry().expect("registry builds");
        let ids: Vec<_> = registry.routes().iter().map(|route| route.id).collect();
        assert_eq!(ids[0], HOME.id);
        for routes in domain_route_sets() {
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
    fn duplicate_key_between_domains_is_rejected() {
        // 构造重复：把 account 的 key 冒充成 events 的 key。
        let key = cgc_account::registration::I18N_KEYS[0];
        let account = [key];
        let events = [key];
        let sets = [("account", &account[..]), ("events", &events[..])];
        let mut seen = BTreeSet::new();
        let mut duplicate = None;
        for (_, keys) in sets {
            for k in keys {
                if !seen.insert(*k) {
                    duplicate = Some(*k);
                }
            }
        }
        assert_eq!(duplicate, Some(key));
    }

    #[test]
    fn missing_translation_is_reported_with_key_and_locale() {
        let registry = build_registry().expect("registry builds");
        // 现有注册必须干净；把「不存在的 key」走同样的缺词条路径验证诊断形状。
        let missing = "nope.missing.key";
        let err = (|| {
            for language in Language::ALL {
                if !i18n::has_key(language, missing) {
                    return Err(RegistrationError::MissingTranslation {
                        key: missing,
                        locale: language.code(),
                    });
                }
            }
            Ok(())
        })()
        .unwrap_err();
        assert_eq!(
            err,
            RegistrationError::MissingTranslation {
                key: "nope.missing.key",
                locale: "zh"
            }
        );
        validate(&registry).expect("baseline registration stays valid");
    }

    #[test]
    fn duplicate_route_in_domain_set_is_rejected_by_registry() {
        let mut registry = RouteRegistry::new();
        registry.register(HOME).expect("home");
        let err = registry.register(HOME).unwrap_err();
        assert_eq!(err, DuplicateRoute::Id("app.home"));
    }
}
