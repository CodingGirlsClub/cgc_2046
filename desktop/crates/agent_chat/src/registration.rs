//! 本 domain crate 的路由与词表 key 注册（脊柱 AD-9：app 只做聚合）。

use cgc_platform::routes::Route;

/// 本 feature 贡献的路由；顺序即导航顺序。
pub const ROUTES: &[Route] = &[Route::new(
    "agent_chat.panel",
    "/companion",
    "agent_chat.panel.title",
)];

/// 本 feature 贡献的词表 key；key 命名规则 `feature.domain.key`。
pub const I18N_KEYS: &[&str] = &["agent_chat.panel.title"];
