//! 桌面端强制升级 / 止损开关响应解析、安全下载链接白名单与进程级 Latch（ADR-0027）。

use std::sync::RwLock;

use serde_json::Value;
use url::Url;

pub const DEFAULT_DOWNLOAD_URL: &str =
    "https://github.com/CodingGirlsClub/cgc_2046/releases/latest";

const DEFAULT_UPGRADE_MESSAGE: &str = "当前桌面客户端版本过旧，请升级至最新版本后继续使用。";

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct UpgradeNotice {
    pub code: String,
    pub message: String,
    pub min_version: Option<String>,
    pub latest_version: Option<String>,
    pub download_url: Option<String>,
}

impl UpgradeNotice {
    pub fn is_kill_switch(&self) -> bool {
        self.code == "desktop_client_disabled"
    }

    pub fn is_blocked(&self) -> bool {
        self.code == "client_version_blocked"
    }

    pub fn fallback_from_message(message: String) -> Self {
        let trimmed = message.trim();
        Self {
            code: "client_upgrade_required".to_string(),
            message: if trimmed.is_empty() {
                DEFAULT_UPGRADE_MESSAGE.to_string()
            } else {
                trimmed.to_string()
            },
            min_version: None,
            latest_version: None,
            download_url: None,
        }
    }

    /// 仅允许 `https://codingirlsclub.com`（及子域）与官方仓库 GitHub Releases URL，
    /// 防止异常响应注入 `http://`、`javascript:` 或钓鱼域名。
    pub fn safe_download_url(&self) -> String {
        self.download_url
            .as_deref()
            .and_then(sanitize_download_url)
            .unwrap_or_else(|| DEFAULT_DOWNLOAD_URL.to_string())
    }
}

/// 校验证书无关的官方下载链接白名单（fail-closed）。
pub fn sanitize_download_url(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }
    let parsed = Url::parse(trimmed).ok()?;
    if parsed.scheme() != "https"
        || !parsed.username().is_empty()
        || parsed.password().is_some()
        || parsed.port().is_some()
    {
        return None;
    }
    let host = parsed.host_str()?.to_ascii_lowercase();
    let allowed_official_domain = host == crate::runtime::OFFICIAL_ROOT_DOMAIN
        || host.ends_with(&format!(".{}", crate::runtime::OFFICIAL_ROOT_DOMAIN));
    let path = parsed.path();
    let allowed_github_repo = host == "github.com"
        && (path == "/CodingGirlsClub/cgc_2046" || path.starts_with("/CodingGirlsClub/cgc_2046/"));

    if allowed_official_domain || allowed_github_repo {
        Some(parsed.into())
    } else {
        None
    }
}

/// 容错解析服务端 `426` 或 `/api/desktop/version` JSON（缺字段或非 JSON 时兜底，绝不 panic）。
pub fn parse_upgrade_notice(body: &str) -> UpgradeNotice {
    if let Ok(value) = serde_json::from_str::<Value>(body) {
        let error = value.get("error").unwrap_or(&value);
        let non_empty = |key: &str| {
            error
                .get(key)
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_string)
        };
        let code = non_empty("code").unwrap_or_else(|| "client_upgrade_required".to_string());
        let message = non_empty("message").unwrap_or_else(|| DEFAULT_UPGRADE_MESSAGE.to_string());
        let min_version = non_empty("min_version").or_else(|| non_empty("min_supported_version"));
        let latest_version = non_empty("latest_version");
        let download_url = non_empty("download_url");
        return UpgradeNotice {
            code,
            message,
            min_version,
            latest_version,
            download_url,
        };
    }

    UpgradeNotice::fallback_from_message(body.to_string())
}

static UPGRADE_NOTICE: RwLock<Option<UpgradeNotice>> = RwLock::new(None);

#[cfg(test)]
pub(crate) static LATCH_TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

pub fn record_upgrade_notice(notice: UpgradeNotice) {
    if let Ok(mut slot) = UPGRADE_NOTICE.write() {
        *slot = Some(notice);
    }
}

pub fn upgrade_notice() -> Option<UpgradeNotice> {
    UPGRADE_NOTICE.read().ok().and_then(|slot| slot.clone())
}

pub fn clear_upgrade_notice() {
    if let Ok(mut slot) = UPGRADE_NOTICE.write() {
        *slot = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_structured_426_payload_and_preserves_kill_switch_kind() {
        let raw = r#"{"error":{"code":"desktop_client_disabled","message":"临时维护中","min_version":"0.2.0","latest_version":"0.3.0","download_url":"https://codingirlsclub.com/releases"}}"#;
        let notice = parse_upgrade_notice(raw);
        assert_eq!(notice.code, "desktop_client_disabled");
        assert!(notice.is_kill_switch());
        assert!(!notice.is_blocked());
        assert_eq!(notice.message, "临时维护中");
        assert_eq!(notice.min_version.as_deref(), Some("0.2.0"));
        assert_eq!(notice.latest_version.as_deref(), Some("0.3.0"));
        assert_eq!(
            notice.safe_download_url(),
            "https://codingirlsclub.com/releases"
        );
    }

    #[test]
    fn falls_back_gracefully_on_non_json_or_empty_body() {
        let plain = parse_upgrade_notice("Upgrade Required");
        assert_eq!(plain.code, "client_upgrade_required");
        assert_eq!(plain.message, "Upgrade Required");
        assert_eq!(plain.safe_download_url(), DEFAULT_DOWNLOAD_URL);

        let empty = parse_upgrade_notice("   ");
        assert_eq!(empty.code, "client_upgrade_required");
        assert_eq!(empty.message, DEFAULT_UPGRADE_MESSAGE);
    }

    #[test]
    fn safe_download_url_enforces_official_https_allowlist() {
        let notice = |url: &str| UpgradeNotice {
            code: "client_upgrade_required".to_string(),
            message: "upgrade".to_string(),
            min_version: None,
            latest_version: None,
            download_url: Some(url.to_string()),
        };

        assert_eq!(
            notice("https://codingirlsclub.com/download").safe_download_url(),
            "https://codingirlsclub.com/download"
        );
        assert_eq!(
            notice("https://dl.codingirlsclub.com/mac.dmg").safe_download_url(),
            "https://dl.codingirlsclub.com/mac.dmg"
        );
        assert_eq!(
            notice("https://github.com/CodingGirlsClub/cgc_2046/releases/tag/desktop-v0.2.0")
                .safe_download_url(),
            "https://github.com/CodingGirlsClub/cgc_2046/releases/tag/desktop-v0.2.0"
        );

        for rejected in [
            "http://codingirlsclub.com/download",
            "javascript:alert(1)",
            "file:///Applications/Evil.app",
            "https://evil.example/payload.dmg",
            "https://codingirlsclub.com.evil.example/dmg",
            "https://codinggirlsclub.com/download",
            "https://github.com/CodingGirlsClub/cgc_2046_fake/releases",
            "https://github.com/other/repo/releases",
            "https://user@codingirlsclub.com/download",
            "https://codingirlsclub.com:8443/download",
        ] {
            assert_eq!(
                notice(rejected).safe_download_url(),
                DEFAULT_DOWNLOAD_URL,
                "must reject untrusted url {rejected}"
            );
        }
    }

    #[test]
    fn process_latch_records_reads_and_clears() {
        let _guard = LATCH_TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        clear_upgrade_notice();
        assert_eq!(upgrade_notice(), None);

        let sample = UpgradeNotice {
            code: "client_version_blocked".to_string(),
            message: "已停用".to_string(),
            min_version: Some("0.2.0".to_string()),
            latest_version: Some("0.3.0".to_string()),
            download_url: None,
        };
        assert!(sample.is_blocked());
        record_upgrade_notice(sample.clone());
        assert_eq!(upgrade_notice(), Some(sample));

        clear_upgrade_notice();
        assert_eq!(upgrade_notice(), None);
    }
}
