//! 两个 HTTP Provider 适配器共用的传输辅助。

use futures::channel::mpsc;
use serde_json::Value;

use crate::error::{ProviderError, ProviderErrorCategory};
use crate::event::CompletionEvent;

/// 阻塞式送入；返回 `false` 表示消费者已放弃，worker 应尽快退出。
pub(crate) fn send_blocking(
    sender: &mut mpsc::Sender<Result<CompletionEvent, ProviderError>>,
    event: Result<CompletionEvent, ProviderError>,
) -> bool {
    use futures::SinkExt as _;
    futures::executor::block_on(sender.send(event)).is_ok()
}

pub(crate) fn map_ureq_error(error: ureq::Error) -> ProviderError {
    match error {
        ureq::Error::StatusCode(status) => ProviderError::api(status, "http status error"),
        ureq::Error::Timeout(_) => ProviderError::transport("request timed out"),
        ureq::Error::Io(error) => ProviderError::transport(error.to_string()),
        other => ProviderError::transport(other.to_string()),
    }
}

pub(crate) fn truncate(text: &str, max_chars: usize) -> String {
    text.chars().take(max_chars).collect()
}

/// 解析 OpenAI / CGC Gateway 的 HTTP 或 SSE 错误载荷：
/// - HTTP 426 → 保留完整 JSON 载荷（含 `code`、`message`、`min_version`、`download_url`），供上层 `parse_upgrade_notice` 解析
/// - HTTP 402 或 `error.code == "insufficient_quota"` → `InsufficientQuota`（禁止重试）
/// - `error.code == "concurrency_limit_exceeded"` → `ConcurrencyLimitExceeded`
/// - 其它状态码与错误分类保留原语义。
pub(crate) fn parse_openai_error(status: Option<u16>, raw: &str) -> ProviderError {
    let trimmed = raw.trim();
    if status == Some(426) {
        return ProviderError::api(426, truncate(trimmed, 2_000));
    }
    if let Ok(parsed) = serde_json::from_str::<Value>(trimmed) {
        if let Some(error) = parsed.get("error") {
            if let Some(code_str) = error.as_str() {
                let message = truncate(code_str, 500);
                return match status {
                    Some(402) => ProviderError::insufficient_quota(message),
                    Some(code) => ProviderError::api(code, message),
                    None if code_str == "invalid_token" => ProviderError::api_with_category(
                        ProviderErrorCategory::Authentication,
                        Some(401),
                        message,
                    ),
                    None => ProviderError::api_with_category(
                        ProviderErrorCategory::Other,
                        None,
                        message,
                    ),
                };
            }
            let code = error.get("code").and_then(Value::as_str);
            let err_type = error.get("type").and_then(Value::as_str);
            let reason = error
                .get("reason")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|r| !r.is_empty());
            let base_message = error
                .get("message")
                .and_then(Value::as_str)
                .filter(|msg| !msg.trim().is_empty())
                .map(|msg| truncate(msg, 500))
                .or_else(|| code.map(|c| truncate(c, 500)))
                .unwrap_or_else(|| truncate(trimmed, 500));
            let message = match (code, reason) {
                (Some("wallet_frozen"), Some(reason)) => {
                    format!("{base_message} (reason: {})", truncate(reason, 200))
                }
                _ => base_message,
            };

            if status == Some(402)
                || code == Some("insufficient_quota")
                || err_type == Some("billing_error")
            {
                return ProviderError::insufficient_quota(message);
            }
            if code == Some("concurrency_limit_exceeded") {
                return ProviderError::concurrency_limit_exceeded(message);
            }
            if let Some(http_status) = status {
                return ProviderError::api(http_status, message);
            }
            let category = match (code, err_type) {
                (Some("unauthorized"), _) | (_, Some("authentication_error")) => {
                    ProviderErrorCategory::Authentication
                }
                (Some("forbidden"), _) | (_, Some("authorization_error" | "permission_error")) => {
                    ProviderErrorCategory::Permission
                }
                (_, Some("rate_limit_error")) => ProviderErrorCategory::RateLimit,
                (Some("upstream_unavailable" | "upstream_stream_interrupted"), _)
                | (_, Some("upstream_error" | "server_error")) => ProviderErrorCategory::Overloaded,
                (Some("invalid_request"), _) | (_, Some("invalid_request_error")) => {
                    ProviderErrorCategory::InvalidRequest
                }
                _ => ProviderErrorCategory::Other,
            };
            return ProviderError::api_with_category(category, None, message);
        }
    }
    match status {
        Some(402) => ProviderError::insufficient_quota(truncate(trimmed, 500)),
        Some(http_status) => ProviderError::api(http_status, truncate(trimmed, 500)),
        None => ProviderError::api_with_category(
            ProviderErrorCategory::Other,
            None,
            truncate(trimmed, 500),
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_openai_error_preserves_wallet_frozen_reason() {
        let raw = r#"{"error":{"code":"wallet_frozen","type":"permission_error","message":"Your LLM wallet is frozen. Please contact support.","reason":"异常刷量"}}"#;
        let err = parse_openai_error(Some(403), raw);
        assert_eq!(err.category(), ProviderErrorCategory::Permission);
        assert!(err.to_string().contains("(reason: 异常刷量)"));

        let raw_no_reason = r#"{"error":{"code":"wallet_frozen","type":"permission_error","message":"Your LLM wallet is frozen. Please contact support."}}"#;
        let err2 = parse_openai_error(Some(403), raw_no_reason);
        assert_eq!(err2.category(), ProviderErrorCategory::Permission);
        assert!(!err2.to_string().contains("(reason:"));
    }

    #[test]
    fn parse_openai_error_preserves_structured_426_upgrade_payload() {
        let raw = r#"{"error":{"code":"desktop_client_disabled","message":"临时维护中","min_version":"0.2.0","download_url":"https://codingirlsclub.com/releases"}}"#;
        let err = parse_openai_error(Some(426), raw);
        match err {
            ProviderError::Api {
                status: Some(426),
                message,
                ..
            } => {
                assert_eq!(message, raw);
            }
            other => panic!("expected 426 Api error, got {other:?}"),
        }
    }
}
