//! 运行时模式判定与配置解析：发布形态默认真实后端。
//!
//! 三条规则：
//! 1. 只有显式 `CGC_AUTH=fake` 才使用本地假数据；`CGC_API_URL` 只决定 HTTP 端点。
//! 2. **发布构建可以把默认值编进二进制**（`CGC_DEFAULT_API_URL` / `CGC_DEFAULT_ENV`，
//!    见 `build.rs`）：内测包由用户双击 `.app` 启动，拿不到 shell 环境变量，只能靠编译期
//!    默认值指向真实后端；源码默认值仍是本机开发端点，`cargo run` 行为不变。
//! 3. 运行时覆盖顺序：环境变量 > `~/.cgc2046/settings.json` 的 `api.url` > 编译期默认值。
//!
//! **端点必须过白名单**（[`is_allowed_endpoint`]）：Bearer token、登录密码、下单请求与
//! MCP lease token 都走这条通道，端点一旦被改成站外主机就是把凭据送给第三方；
//! 历史事故是一次 `codinggirlsclub.com` 拼写（官方域是 `codingirlsclub.com`），
//! 该域当时无服务、登录全挂。
//!
//! Session、MCP credential 与各 API builder 共用这里的解析，保持单一真源。

use std::sync::RwLock;

use url::Url;

use crate::paths::AppEnvironment;

/// 本机开发的默认 GraphQL 端点（源码不注入编译期默认值时使用）。
pub const LOCAL_API_URL: &str = "http://localhost:4000/api/graphql";

/// 官方根域：`https://` 下允许它本身与其任意子域（`api.` / `staging-api.` 等）。
pub const OFFICIAL_ROOT_DOMAIN: &str = "codingirlsclub.com";

/// 本机开发允许的 host（只允许 `http://`）。
const LOCAL_HOSTS: &[&str] = &["localhost", "127.0.0.1", "[::1]"];

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

/// 端点白名单：`https://` 只认官方根域及其子域；`http://` 只认本机回环。
///
/// 任何走这条通道的东西（Bearer token、密码、MCP lease token）都受它保护，
/// 所以是 fail-closed：解析失败、主机为空、协议不认识一律拒绝。
pub fn is_allowed_endpoint(endpoint: &str) -> bool {
    let Ok(parsed) = Url::parse(endpoint.trim()) else {
        return false;
    };
    let Some(host) = parsed.host_str() else {
        return false;
    };
    match parsed.scheme() {
        "https" => {
            host == OFFICIAL_ROOT_DOMAIN || host.ends_with(&format!(".{OFFICIAL_ROOT_DOMAIN}"))
        }
        "http" => LOCAL_HOSTS.contains(&host),
        _ => false,
    }
}

/// 纯解析端点：`CGC_API_URL` > `settings.json` 的 `api.url` > 构建默认 > 本机开发端点。
///
/// 空字符串、纯空白、以及不在白名单里的候选都跳过（后者记 warning），
/// 避免把空端点或站外主机传给 HTTP 客户端。
pub fn resolve_api_endpoint(
    env: Option<&str>,
    settings: Option<&str>,
    build_default: Option<&str>,
) -> String {
    for candidate in [env, settings, build_default] {
        let Some(value) = candidate.map(str::trim).filter(|value| !value.is_empty()) else {
            continue;
        };
        if is_allowed_endpoint(value) {
            return value.to_string();
        }
        log::warn!(
            target: "runtime",
            "忽略不在白名单的 API 端点（只允许 https://{OFFICIAL_ROOT_DOMAIN} 与其子域，或本机回环 http）"
        );
    }
    LOCAL_API_URL.to_string()
}

/// 当前进程使用的 GraphQL 端点（每次调用重新解析，手改设置重启即生效）。
pub fn api_endpoint() -> String {
    let env = std::env::var("CGC_API_URL").ok();
    let settings = settings_api_url();
    resolve_api_endpoint(env.as_deref(), settings.as_deref(), BUILD_DEFAULT_API_URL)
}

/// Desktop 的「忘记密码」出口：交给 Web 的账号找回页（小程序优先）。
///
/// 官方域下把 `api.<root>` 映射到站点根域；本地开发回退到 Web dev server。
/// 不在客户端重做重置 UI：小程序码与邮箱折叠只维护一份（Web）。
pub fn forgot_password_url() -> String {
    resolve_site_url(&api_endpoint(), "/forgot-password")
}

/// 额度到期 / 低余额站内提醒的落点：Web「我的 AI 额度」页（Desktop 无独立额度页，
/// 额度管理与充值只维护一份 Web）。
pub fn ai_quota_url() -> String {
    resolve_site_url(&api_endpoint(), "/settings/ai-quota")
}

fn resolve_site_url(api: &str, path: &str) -> String {
    let official_suffix = format!(".{OFFICIAL_ROOT_DOMAIN}");

    match Url::parse(api) {
        Ok(url)
            if url.host_str().is_some_and(|host| {
                host == OFFICIAL_ROOT_DOMAIN || host.ends_with(&official_suffix)
            }) =>
        {
            // Web 只在根域部署（`web/config/deploy.yml` 的 proxy.hosts 仅裸域 + www），
            // 所以 api / staging-api 等官方主机一律收敛到根域，而不是保留一个必然 404 的 API 主机。
            format!("https://{OFFICIAL_ROOT_DOMAIN}{path}")
        }
        _ => format!("http://localhost:3000{path}"),
    }
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

    const PROD: &str = "https://api.codingirlsclub.com/api/graphql";

    #[test]
    fn env_var_wins_over_settings_and_build_default() {
        assert_eq!(
            resolve_api_endpoint(
                Some("https://staging-api.codingirlsclub.com/api/graphql"),
                Some(PROD),
                Some(PROD),
            ),
            "https://staging-api.codingirlsclub.com/api/graphql"
        );
    }

    #[test]
    fn settings_win_over_build_default() {
        assert_eq!(
            resolve_api_endpoint(
                None,
                Some("https://staging-api.codingirlsclub.com/api/graphql"),
                Some(PROD),
            ),
            "https://staging-api.codingirlsclub.com/api/graphql"
        );
    }

    #[test]
    fn build_default_used_when_no_override() {
        assert_eq!(resolve_api_endpoint(None, None, Some(PROD)), PROD);
    }

    #[test]
    fn blank_overrides_are_ignored() {
        assert_eq!(
            resolve_api_endpoint(Some("   "), Some(""), Some(PROD)),
            PROD
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
    fn forgot_password_url_maps_api_host_to_site() {
        assert_eq!(
            resolve_site_url(PROD, "/forgot-password"),
            "https://codingirlsclub.com/forgot-password"
        );
        // 官方子域一律收敛到根域（Web 只部署在根域）；不会保留 API 主机导致 404
        assert_eq!(
            resolve_site_url(
                "https://staging-api.codingirlsclub.com/api/graphql",
                "/forgot-password"
            ),
            "https://codingirlsclub.com/forgot-password"
        );
        // 本地开发：Web dev server，而不是 API 端口
        assert_eq!(
            resolve_site_url(LOCAL_API_URL, "/forgot-password"),
            "http://localhost:3000/forgot-password"
        );
        assert_eq!(
            resolve_site_url(PROD, "/settings/ai-quota"),
            "https://codingirlsclub.com/settings/ai-quota"
        );
        assert_eq!(
            resolve_site_url(LOCAL_API_URL, "/settings/ai-quota"),
            "http://localhost:3000/settings/ai-quota"
        );
    }

    // ── 端点白名单：凭据只发给官方域 ──

    #[test]
    fn accepts_official_domain_and_subdomains() {
        assert!(is_allowed_endpoint(
            "https://codingirlsclub.com/api/graphql"
        ));
        assert!(is_allowed_endpoint(PROD));
        assert!(is_allowed_endpoint(
            "https://staging-api.codingirlsclub.com/api/graphql"
        ));
        // 结尾相似但不同域必须拒绝（历史上就是把官方域错拼成这个）。
        assert!(!is_allowed_endpoint(
            "https://codinggirlsclub.com/api/graphql"
        ));
        assert!(!is_allowed_endpoint(
            "https://codingirlsclub.com.evil.example/api/graphql"
        ));
    }

    #[test]
    fn accepts_local_http_but_not_remote_http() {
        assert!(is_allowed_endpoint(LOCAL_API_URL));
        assert!(is_allowed_endpoint("http://127.0.0.1:4000/api/graphql"));
        assert!(!is_allowed_endpoint(
            "http://codingirlsclub.com/api/graphql"
        ));
        assert!(!is_allowed_endpoint("ftp://codingirlsclub.com/api/graphql"));
        assert!(!is_allowed_endpoint("not a url"));
        assert!(!is_allowed_endpoint(""));
    }

    #[test]
    fn disallowed_override_falls_through_to_next_candidate() {
        // 站外端点被拒后，不能直接把空值交给客户端，要回落到下一个候选。
        assert_eq!(
            resolve_api_endpoint(
                Some("https://coder.example/api/graphql"),
                Some(PROD),
                Some(PROD),
            ),
            PROD
        );
        assert_eq!(
            resolve_api_endpoint(Some("https://coder.example/api/graphql"), None, None),
            LOCAL_API_URL
        );
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
        set_settings_api_url(Some(format!("  {PROD}  ")));
        assert_eq!(settings_api_url().as_deref(), Some(PROD));
        set_settings_api_url(Some("   ".to_string()));
        assert_eq!(settings_api_url(), None);
        set_settings_api_url(None);
        assert_eq!(settings_api_url(), None);
    }
}
