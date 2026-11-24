//! 轻量桌面客户端版本检查（ADR-0027 Phase 1）。
//!
//! 从 `runtime::api_endpoint()` 推导 `/api/desktop/version` 并发起无鉴权 GET 请求：
//! - 支持后端未升级（404）或离线场景：静默降级为无更新，不阻塞启动；
//! - 支持非强制更新提示（`update_available: true`）；
//! - 遇到强升 / 停用 / kill_switch（HTTP 426 或 `upgrade_required: true`）时写进程级 Latch。

use std::time::Duration;

use serde_json::Value;

use crate::api::upgrade::{
    parse_upgrade_notice, record_upgrade_notice, sanitize_download_url, UpgradeNotice,
    DEFAULT_DOWNLOAD_URL,
};

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum UpdateCheckOutcome {
    UpToDate,
    UpdateAvailable {
        latest_version: String,
        download_url: String,
        release_notes: Option<String>,
    },
    UpgradeRequired(UpgradeNotice),
}

/// 由 GraphQL 端点推导版本检查端点：`…/api/graphql` → `…/api/desktop/version`。
pub fn desktop_version_endpoint(api_url: Option<&str>) -> String {
    let resolved = crate::runtime::api_endpoint();
    let base = api_url.unwrap_or(resolved.as_str()).trim_end_matches('/');
    if let Some(prefix) = base.strip_suffix("/api/graphql") {
        return format!("{prefix}/api/desktop/version");
    }
    if let Some(prefix) = base.strip_suffix("/graphql") {
        return format!("{prefix}/api/desktop/version");
    }
    format!("{base}/api/desktop/version")
}

/// 启动时发起一次轻量版本检查；`404` 视同旧后端尚未支持该端点并静默返回 `UpToDate`。
pub fn check_for_update(
    api_url: Option<&str>,
    current_version: &str,
    timeout: Duration,
) -> Result<UpdateCheckOutcome, String> {
    let endpoint = desktop_version_endpoint(api_url);
    if !crate::runtime::is_allowed_endpoint(&endpoint) {
        return Err("Update endpoint is not trusted".to_string());
    }

    let config = ureq::Agent::config_builder()
        .timeout_global(Some(timeout))
        .max_redirects(0)
        .http_status_as_error(false)
        .build();
    let agent: ureq::Agent = config.into();
    let response = agent
        .get(&endpoint)
        .header(
            crate::runtime::CLIENT_HEADER_NAME,
            crate::runtime::CLIENT_HEADER_VALUE,
        )
        .header(crate::runtime::CLIENT_VERSION_HEADER, current_version)
        .header(
            crate::runtime::CLIENT_PLATFORM_HEADER,
            crate::runtime::client_platform(),
        )
        .call()
        .map_err(|error| error.to_string())?;

    let status = response.status().as_u16();
    if status == 404 {
        return Ok(UpdateCheckOutcome::UpToDate);
    }

    let mut body = response.into_body();
    let text = body.read_to_string().map_err(|error| error.to_string())?;

    if status == 426 {
        let notice = parse_upgrade_notice(&text);
        record_upgrade_notice(notice.clone());
        return Ok(UpdateCheckOutcome::UpgradeRequired(notice));
    }

    if !(200..300).contains(&status) {
        return Err(format!("http status {status}"));
    }

    let payload: Value =
        serde_json::from_str(&text).map_err(|error| format!("invalid json: {error}"))?;

    if payload.get("upgrade_required").and_then(Value::as_bool) == Some(true) {
        let notice = parse_upgrade_notice(&text);
        record_upgrade_notice(notice.clone());
        return Ok(UpdateCheckOutcome::UpgradeRequired(notice));
    }

    let update_available = payload
        .get("update_available")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let latest_version = payload
        .get("latest_version")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string);

    if update_available {
        if let Some(latest_version) = latest_version {
            let download_url = payload
                .get("download_url")
                .and_then(Value::as_str)
                .and_then(sanitize_download_url)
                .unwrap_or_else(|| DEFAULT_DOWNLOAD_URL.to_string());
            let release_notes = payload
                .get("release_notes")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(str::to_string);
            return Ok(UpdateCheckOutcome::UpdateAvailable {
                latest_version,
                download_url,
                release_notes,
            });
        }
    }

    Ok(UpdateCheckOutcome::UpToDate)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::upgrade::{clear_upgrade_notice, upgrade_notice, LATCH_TEST_LOCK};
    use std::io::{Read, Write};
    use std::net::TcpListener;

    fn spawn_version_mock(
        status: u16,
        body: &'static str,
    ) -> (String, std::sync::mpsc::Receiver<String>) {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let addr = listener.local_addr().expect("addr");
        let (sender, receiver) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept");
            let mut request = Vec::new();
            let mut buffer = [0u8; 2048];
            while !request.windows(4).any(|w| w == b"\r\n\r\n") {
                let read = stream.read(&mut buffer).expect("read");
                if read == 0 {
                    break;
                }
                request.extend_from_slice(&buffer[..read]);
            }
            let _ = sender.send(String::from_utf8_lossy(&request).to_string());
            let response = format!(
                "HTTP/1.1 {status} OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
            stream.write_all(response.as_bytes()).expect("write");
        });
        (format!("http://{addr}/api/graphql"), receiver)
    }

    #[test]
    fn derives_version_endpoint_from_graphql_url() {
        assert_eq!(
            desktop_version_endpoint(Some("https://api.codingirlsclub.com/api/graphql")),
            "https://api.codingirlsclub.com/api/desktop/version"
        );
        assert_eq!(
            desktop_version_endpoint(Some("http://127.0.0.1:4000/graphql")),
            "http://127.0.0.1:4000/api/desktop/version"
        );
        assert_eq!(
            desktop_version_endpoint(Some("https://api.codingirlsclub.com/")),
            "https://api.codingirlsclub.com/api/desktop/version"
        );
    }

    #[test]
    fn rejects_untrusted_endpoint_fail_closed() {
        let error = check_for_update(
            Some("https://evil.example/api/graphql"),
            "0.1.0",
            Duration::from_secs(2),
        )
        .expect_err("untrusted endpoint must fail");
        assert!(error.contains("not trusted"));
    }

    #[test]
    fn handles_up_to_date_and_404_gracefully_with_client_headers() {
        let (endpoint, received) = spawn_version_mock(
            200,
            r#"{"latest_version":"0.1.0","update_available":false,"upgrade_required":false}"#,
        );
        let outcome = check_for_update(Some(&endpoint), "0.1.0", Duration::from_secs(2))
            .expect("check succeeded");
        assert_eq!(outcome, UpdateCheckOutcome::UpToDate);
        let raw_req = received
            .recv()
            .expect("request captured")
            .to_ascii_lowercase();
        assert!(raw_req.starts_with("get /api/desktop/version http/1.1"));
        assert!(raw_req.contains("x-cgc-client: desktop"));
        assert!(raw_req.contains("x-cgc-client-version: 0.1.0"));
        assert!(raw_req.contains("x-cgc-client-platform:"));

        let (endpoint_404, _) = spawn_version_mock(404, "not found");
        let outcome_404 = check_for_update(Some(&endpoint_404), "0.1.0", Duration::from_secs(2))
            .expect("404 degrades to UpToDate");
        assert_eq!(outcome_404, UpdateCheckOutcome::UpToDate);
    }

    #[test]
    fn parses_update_available_and_sanitizes_download_url() {
        let (endpoint, _) = spawn_version_mock(
            200,
            r#"{"latest_version":"0.2.0","download_url":"https://codingirlsclub.com/releases","release_notes":"修复崩溃","update_available":true,"upgrade_required":false}"#,
        );
        let outcome = check_for_update(Some(&endpoint), "0.1.0", Duration::from_secs(2))
            .expect("check succeeded");
        assert_eq!(
            outcome,
            UpdateCheckOutcome::UpdateAvailable {
                latest_version: "0.2.0".to_string(),
                download_url: "https://codingirlsclub.com/releases".to_string(),
                release_notes: Some("修复崩溃".to_string()),
            }
        );

        let (bad_url_endpoint, _) = spawn_version_mock(
            200,
            r#"{"latest_version":"0.2.0","download_url":"https://evil.example/bad.dmg","update_available":true,"upgrade_required":false}"#,
        );
        let sanitized = check_for_update(Some(&bad_url_endpoint), "0.1.0", Duration::from_secs(2))
            .expect("sanitized fallback");
        assert_eq!(
            sanitized,
            UpdateCheckOutcome::UpdateAvailable {
                latest_version: "0.2.0".to_string(),
                download_url: DEFAULT_DOWNLOAD_URL.to_string(),
                release_notes: None,
            }
        );
    }

    #[test]
    fn sets_process_latch_on_upgrade_required_200_and_426() {
        let _guard = LATCH_TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        clear_upgrade_notice();

        let (endpoint_200, _) = spawn_version_mock(
            200,
            r#"{"code":"client_upgrade_required","message":"请升级","min_supported_version":"0.2.0","latest_version":"0.3.0","download_url":"https://codingirlsclub.com/dl","upgrade_required":true}"#,
        );
        let outcome = check_for_update(Some(&endpoint_200), "0.1.0", Duration::from_secs(2))
            .expect("200 upgrade_required");
        match outcome {
            UpdateCheckOutcome::UpgradeRequired(notice) => {
                assert_eq!(notice.min_version.as_deref(), Some("0.2.0"));
                assert_eq!(upgrade_notice(), Some(notice));
            }
            other => panic!("unexpected outcome: {other:?}"),
        }

        clear_upgrade_notice();

        let (endpoint_426, _) = spawn_version_mock(
            426,
            r#"{"error":{"code":"desktop_client_disabled","message":"暂停服务"}}"#,
        );
        let outcome_426 = check_for_update(Some(&endpoint_426), "0.1.0", Duration::from_secs(2))
            .expect("426 upgrade_required");
        match outcome_426 {
            UpdateCheckOutcome::UpgradeRequired(notice) => {
                assert!(notice.is_kill_switch());
                assert_eq!(upgrade_notice(), Some(notice));
            }
            other => panic!("unexpected outcome: {other:?}"),
        }

        clear_upgrade_notice();
    }

    #[test]
    fn returns_err_on_500_without_touching_latch() {
        let _guard = LATCH_TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        clear_upgrade_notice();

        let (endpoint, _) = spawn_version_mock(500, "internal error");
        let err = check_for_update(Some(&endpoint), "0.1.0", Duration::from_secs(2))
            .expect_err("500 must fail");
        assert!(err.contains("500"));
        assert_eq!(upgrade_notice(), None);
    }
}
