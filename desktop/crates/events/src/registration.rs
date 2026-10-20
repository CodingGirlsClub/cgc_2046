//! 本 domain crate 的路由与词表 key 注册（脊柱 AD-9：app 只做聚合）。

use cgc_platform::routes::{NavIcon, Route};

/// 本 feature 贡献的路由；顺序即导航顺序（详情为动态路由，不进 footer 导航）。
pub const ROUTES: &[Route] = &[
    Route::new(
        "events.list",
        "/events",
        "events.list.title",
        NavIcon::Events,
    ),
    Route::new(
        "events.mine",
        "/events/mine",
        "events.mine.title",
        NavIcon::Events,
    ),
    Route::new(
        "events.participations",
        "/participations",
        "events.participations.title",
        NavIcon::Events,
    ),
    Route::new(
        "events.detail",
        "/events/:id",
        "events.detail.title",
        NavIcon::Events,
    ),
];

/// 本 feature 贡献的词表 key；key 命名规则 `feature.domain.key`。
pub const I18N_KEYS: &[&str] = &[
    "events.list.title",
    "events.detail.title",
    "events.mine.title",
    "events.participations.title",
];
