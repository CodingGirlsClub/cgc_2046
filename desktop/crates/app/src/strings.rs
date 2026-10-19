//! 占位文案 key。真实词表与运行时切换在 1.3（i18n 基座）落地；
//! 在此之前 UI 只展示 key，避免在代码里写死中文或英文（脊柱 AD-24）。

pub const APP_NAME_KEY: &str = "app.name";
pub const NAV_HOME_KEY: &str = "app.nav.home";
pub const EMPTY_TITLE_KEY: &str = "app.empty.title";
pub const EMPTY_BODY_KEY: &str = "app.empty.body";
