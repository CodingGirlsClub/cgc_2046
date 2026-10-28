//! 运行时模式判定与配置解析：发布形态默认真实后端。
//!
//! 三条规则：
//! 1. 只有显式 `CGC_AUTH=fake` 才使用本地假数据；`CGC_API_URL` 只决定 HTTP 端点。
//! 2. **发布构建可以把默认值编进二进制**（`CGC_DEFAULT_API_URL` / `CGC_DEFAULT_ENV`，
//!    见 `build.rs`）：内测包由用户双击 `.app` 启动，拿不到 shell 环境变量，只能靠编译期
//!    默认值指向真实后端；源码默认值仍是本机开发端点，`cargo run` 行为不变。
//! 3. 运行时覆盖顺序：环境变量 > `~/.cgc2046/settings.json` 的 `api.url` > 编译期默认值。
//!
//! Session、MCP credential 与各 API builder 共用这里的解析，保持单一真源。

use std::sync::RwLock;

use crate::paths::AppEnvironment;

/// 本机开发的默认 GraphQL 端点（源码不注入编译期默认值时使用）。
pub const LOCAL_API_URL: &str = "http://localhost:4000/api/graphql";

/// 发布构建注入的默认环境；未注入 = `None`，与历史行为一致（默认 dev）。
const BUILD_DEFAULT_ENV: Option<&str> = option_env!("CGC_DEFAULT_ENV");

/// 发布构建注入的默认 GraphQL 端点；未注入 = `None`，回退 [`LOCAL_API_URL`]。
const BUILD_DEFAULT_API_URL: Option<&str> = option_env!("CGC_DEFAULT_API_URL");

/// 用户设置文件的 `api.url`（启动时注入一次，之后只读）。
static SETTINGS_API_URL: RwLock<Option<String>> = RwLock::new(None);

/// 纯判定：只有精确的 `fake` 才启用假数据。
pub fn is_fake_auth(value: Option<&str>) -> bool {
    value == Some("fake")
}

/// 读 `CGC_AUTH`；未设置或其它值一律走真实后端。
pub fn use_fake_backend() -> bool {
    is_fake_auth(std::env::var("CGC_AUTH").ok().as_deref())
}

/// 发布构建注入的默认环境；本地构建返回 `None`。
pub fn build_default_environment() -> Option<&'static str> {
    BUILD_DEFAULT_ENV
}

/// 解析运行环境：显式 `CGC_ENV` > 发布构建默认值 > 开发。
///
/// 非法显式值不覆盖发布构建默认值（写了错别字不会把内测包退回 dev 数据根）。
pub fn resolve_environment(explicit: Option<&str>, build_default: Option<&str>) -> AppEnvironment {
    explicit
        .and_then(AppEnvironment::parse)
        .or_else(|| build_default.and_then(AppEnvironment::parse))
        .unwrap_or(AppEnvironment::Dev)
}

/// 注入用户设置里的 `api.url`；空白或 `None` 视为未设置。
pub fn set_settings_api_url(url: Option<String>) {
    let value = url
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty());
    if let Ok(mut slot) = SETTINGS_API_URL.write() {
        *slot = value;
    }
}

/// 当前生效的用户设置 `api.url`。
pub fn settings_api_url() -> Option<String> {
    SETTINGS_API_URL.read().ok().and_then(|slot| slot.clone())
}

/// 纯解析端点：`CGC_API_URL` > `settings.json` 的 `api.url` > 构建默认 > 本机开发端点。
///
/// 空字符串与纯空白都当未设置处理，避免把空端点传给 HTTP 客户端。
pub fn resolve_api_endpoint(
    env: Option<&str>,
    settings: Option<&str>,
    build_default: Option<&str>,
) -> String {
    [env, settings, build_default]
        .into_iter()
        .flatten()
        .map(str::trim)
        .find(|value| !value.is_empty())
        .unwrap_or(LOCAL_API_URL)
        .to_string()
}

/// 当前进程使用的 GraphQL 端点（每次调用重新解析，手改设置重启即生效）。
pub fn api_endpoint() -> String {
    let env = std::env::var("CGC_API_URL").ok();
    let settings = settings_api_url();
    resolve_api_endpoint(env.as_deref(), settings.as_deref(), BUILD_DEFAULT_API_URL)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unset_http_and_empty_use_real_backend() {
        assert!(!is_fake_auth(None));
        assert!(!is_fake_auth(Some("http")));
        assert!(!is_fake_auth(Some("")));
    }

    #[test]
    fn only_explicit_fake_enables_demo_data() {
        assert!(is_fake_auth(Some("fake")));
    }

    // ── 发布构建默认值解析（内测包默认连生产，本地开发不改行为） ──

    #[test]
    fn env_var_wins_over_settings_and_build_default() {
        assert_eq!(
            resolve_api_endpoint(
                Some("https://env.example/api/graphql"),
                Some("https://settings.example/api/graphql"),
                Some("https://build.example/api/graphql"),
            ),
            "https://env.example/api/graphql"
        );
    }

    #[test]
    fn settings_win_over_build_default() {
        assert_eq!(
            resolve_api_endpoint(
                None,
                Some("https://settings.example/api/graphql"),
                Some("https://build.example/api/graphql"),
            ),
            "https://settings.example/api/graphql"
        );
    }

    #[test]
    fn build_default_used_when_no_override() {
        assert_eq!(
            resolve_api_endpoint(None, None, Some("https://build.example/api/graphql")),
            "https://build.example/api/graphql"
        );
    }

    #[test]
    fn blank_overrides_are_ignored() {
        assert_eq!(
            resolve_api_endpoint(
                Some("   "),
                Some(""),
                Some("https://build.example/api/graphql")
            ),
            "https://build.example/api/graphql"
        );
        // 全部空白 → 回退本机开发端点，不能得到空字符串。
        assert_eq!(
            resolve_api_endpoint(Some(" "), Some(""), None),
            LOCAL_API_URL
        );
    }

    #[test]
    fn falls_back_to_local_endpoint() {
        assert_eq!(resolve_api_endpoint(None, None, None), LOCAL_API_URL);
    }

    #[test]
    fn environment_prefers_explicit_then_build_default() {
        assert_eq!(
            resolve_environment(Some("prod"), Some("staging")),
            AppEnvironment::Prod
        );
        assert_eq!(
            resolve_environment(None, Some("staging")),
            AppEnvironment::Staging
        );
        // 非法显式值不能盖住发布构建默认值。
        assert_eq!(
            resolve_environment(Some("bogus"), Some("prod")),
            AppEnvironment::Prod
        );
        assert_eq!(resolve_environment(None, None), AppEnvironment::Dev);
    }

    #[test]
    fn settings_api_url_ignores_blank_and_round_trips() {
        set_settings_api_url(Some("  https://settings.example/api/graphql  ".to_string()));
        assert_eq!(
            settings_api_url().as_deref(),
            Some("https://settings.example/api/graphql")
        );
        set_settings_api_url(Some("   ".to_string()));
        assert_eq!(settings_api_url(), None);
        set_settings_api_url(None);
        assert_eq!(settings_api_url(), None);
    }
}
