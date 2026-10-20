//! 运行时模式判定：发布形态默认真实后端。
//!
//! 只有显式 `CGC_AUTH=fake` 才使用本地假数据；`CGC_API_URL` 只决定 HTTP 端点。
//! Session、MCP credential 与各 API builder 共用这里的判定，保持单一真源。

/// 纯判定：只有精确的 `fake` 才启用假数据。
pub fn is_fake_auth(value: Option<&str>) -> bool {
    value == Some("fake")
}

/// 读 `CGC_AUTH`；未设置或其它值一律走真实后端。
pub fn use_fake_backend() -> bool {
    is_fake_auth(std::env::var("CGC_AUTH").ok().as_deref())
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
}
