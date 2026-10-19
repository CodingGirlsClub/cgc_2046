//! 本 domain crate 的路由与词表 key 注册（脊柱 AD-9：app 只做聚合）。

use cgc_platform::routes::{NavIcon, Route};

/// 本 feature 贡献的路由；详情/学习页是动态路由，不进 footer 导航。
pub const ROUTES: &[Route] = &[
    Route::new(
        "courses.catalog",
        "/courses",
        "courses.catalog.title",
        NavIcon::Courses,
    ),
    Route::new(
        "courses.detail",
        "/courses/:id",
        "courses.detail.title",
        NavIcon::Courses,
    ),
    Route::new(
        "courses.learning",
        "/courses/:id/learn",
        "courses.learning.title",
        NavIcon::Courses,
    ),
];

/// 本 feature 贡献的词表 key。
pub const I18N_KEYS: &[&str] = &[
    "courses.catalog.title",
    "courses.detail.title",
    "courses.learning.title",
];
