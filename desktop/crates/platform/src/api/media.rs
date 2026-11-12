//! 课程材料的受限媒体下载：只允许 HTTPS 公网图片，限制大小与 Content-Type。
//!
//! URL 来自教研内容（`TypedMaterial.url`），属于不可信输入：这里在传输边界
//! 拒绝非 HTTPS、loopback/私网字面量与超限响应，避免把桌面客户端当内网探针。

use std::net::{Ipv4Addr, Ipv6Addr};
use std::time::Duration;

const MEDIA_TIMEOUT: Duration = Duration::from_secs(10);
/// 单张图片上限：与课程讲义插图量级匹配，避免一次下载占满内存。
pub const MAX_IMAGE_BYTES: u64 = 10 * 1024 * 1024;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum MediaError {
    UnsupportedUrl,
    Http(u16),
    Timeout(String),
    Transport(String),
    TooLarge,
    UnsupportedContentType(String),
}

impl std::fmt::Display for MediaError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::UnsupportedUrl => write!(formatter, "unsupported media url"),
            Self::Http(status) => write!(formatter, "media http status {status}"),
            Self::Timeout(reason) => write!(formatter, "media timeout: {reason}"),
            Self::Transport(reason) => write!(formatter, "media transport: {reason}"),
            Self::TooLarge => write!(formatter, "media response too large"),
            Self::UnsupportedContentType(value) => {
                write!(formatter, "unsupported media content-type: {value}")
            }
        }
    }
}

impl std::error::Error for MediaError {}

/// 只接受 `https://` 且 host 不是 loopback/私网字面量。
pub fn is_allowed_media_url(url: &str) -> bool {
    let Some(host) = https_host(url) else {
        return false;
    };
    !is_private_host(host)
}

fn https_host(url: &str) -> Option<&str> {
    let rest = url.strip_prefix("https://")?;
    let authority = rest.split(['/', '?', '#']).next()?;
    // userinfo@host：只取 host 部分；IPv6 字面量（[::1]）直接拒绝。
    let authority = authority.rsplit('@').next()?;
    if authority.is_empty() || authority.starts_with('[') {
        return None;
    }
    let host = authority.split(':').next()?;
    if host.is_empty() {
        return None;
    }
    Some(host)
}

fn is_private_host(host: &str) -> bool {
    let host = host.trim_end_matches('.');
    if host.eq_ignore_ascii_case("localhost") || host.eq_ignore_ascii_case("localhost.localdomain")
    {
        return true;
    }
    if let Ok(ip) = host.parse::<Ipv4Addr>() {
        return ip.is_loopback()
            || ip.is_private()
            || ip.is_link_local()
            || ip.is_unspecified()
            || ip.is_broadcast();
    }
    if let Ok(ip) = host.parse::<Ipv6Addr>() {
        return ip.is_loopback() || ip.is_unspecified() || ip.is_unique_local();
    }
    false
}

/// 下载一张图片：校验 URL → 校验状态码/Content-Type/大小。
pub fn fetch_image(url: &str) -> Result<Vec<u8>, MediaError> {
    if !is_allowed_media_url(url) {
        return Err(MediaError::UnsupportedUrl);
    }
    let config = ureq::Agent::config_builder()
        .timeout_global(Some(MEDIA_TIMEOUT))
        .build();
    let agent: ureq::Agent = config.into();
    let mut response = agent.get(url).call().map_err(map_error)?;
    let status = response.status().as_u16();
    if !(200..300).contains(&status) {
        return Err(MediaError::Http(status));
    }
    let content_type = response
        .headers()
        .get("content-type")
        .and_then(|value| value.to_str().ok())
        .unwrap_or_default()
        .to_ascii_lowercase();
    if !content_type.starts_with("image/") {
        return Err(MediaError::UnsupportedContentType(content_type));
    }
    response
        .body_mut()
        .with_config()
        .limit(MAX_IMAGE_BYTES)
        .read_to_vec()
        .map_err(|error| match error {
            ureq::Error::BodyExceedsLimit(_) => MediaError::TooLarge,
            other => map_error(other),
        })
}

fn map_error(error: ureq::Error) -> MediaError {
    match error {
        ureq::Error::StatusCode(code) => MediaError::Http(code),
        other => {
            let reason = other.to_string();
            if reason.contains("timeout") || reason.contains("timed out") {
                MediaError::Timeout(reason)
            } else {
                MediaError::Transport(reason)
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_https_public_hosts() {
        assert!(is_allowed_media_url("https://cdn.example.com/a.png"));
        assert!(is_allowed_media_url(
            "https://cdn.example.com:8443/a.png?x=1"
        ));
        assert!(is_allowed_media_url("https://172.32.0.1/a.png"));
    }

    #[test]
    fn rejects_unsafe_schemes_and_private_hosts() {
        for url in [
            "http://cdn.example.com/a.png",
            "file:///etc/passwd",
            "data:image/png;base64,AAAA",
            "https://localhost/a.png",
            "https://localhost.localdomain/a.png",
            "https://127.0.0.1/a.png",
            "https://10.1.2.3/a.png",
            "https://172.16.0.1/a.png",
            "https://192.168.1.1/a.png",
            "https://169.254.1.1/a.png",
            "https://0.0.0.0/a.png",
            "https://[::1]/a.png",
            "https://::1/a.png",
            "not a url",
        ] {
            assert!(!is_allowed_media_url(url), "{url} must be rejected");
        }
    }
}
