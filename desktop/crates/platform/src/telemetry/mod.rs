//! 崩溃采集默认关闭；日志/遥测不含凭证与对话（脊柱 AD-13、AD-16，story 5.10）。
//!
//! 本模块只提供**纯函数与本地 stderr**：不联网、不落盘；开启时也只输出脱敏后的
//! panic 位置与消息。对话内容不属于日志素材。

/// 默认关闭：仅显式 `CGC_CRASH_REPORT=1|true` 才启用。
pub fn crash_reporting_enabled(value: Option<&str>) -> bool {
    matches!(value, Some("1" | "true" | "TRUE"))
}

/// 脱敏：JWT/Bearer、learning_host 前缀、sk-/ghp_ 等 token、手机号、邮箱。
pub fn redact_sensitive(input: &str) -> String {
    let mut output = String::with_capacity(input.len());
    for token in input.split_inclusive(char::is_whitespace) {
        let core = token.trim_end();
        let suffix = &token[core.len()..];
        output.push_str(&redact_token(core));
        output.push_str(suffix);
    }
    output
}

fn redact_token(token: &str) -> String {
    let lower = token.to_ascii_lowercase();
    if lower.starts_with("bearer") || lower.contains("authorization:") {
        return "<redacted>".to_string();
    }
    if token.starts_with("cgch_")
        || token.starts_with("sk-")
        || token.starts_with("ghp_")
        || token.starts_with("eyJ")
    {
        return "<redacted>".to_string();
    }
    if token.chars().filter(|ch| *ch == '.').count() == 2
        && token.len() > 40
        && token
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '.' | '-' | '_'))
    {
        return "<redacted>".to_string();
    }
    if token.chars().all(|ch| ch.is_ascii_digit()) && token.len() == 11 {
        return "<phone>".to_string();
    }
    if let Some((local, domain)) = token.split_once('@') {
        if !local.is_empty() && domain.contains('.') {
            return "<email>".to_string();
        }
    }
    token.to_string()
}

/// 安装 panic hook：默认不安装；启用时只打印脱敏后的位置/消息到 stderr。
pub fn install_panic_hook_from_env() {
    if !crash_reporting_enabled(std::env::var("CGC_CRASH_REPORT").ok().as_deref()) {
        return;
    }
    let previous = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        let location = info
            .location()
            .map(|location| format!("{}:{}", location.file(), location.line()))
            .unwrap_or_else(|| "unknown".to_string());
        let message = info
            .payload()
            .downcast_ref::<String>()
            .map(String::as_str)
            .or_else(|| info.payload().downcast_ref::<&str>().copied())
            .unwrap_or("panic");
        eprintln!("[crash] {location}: {}", redact_sensitive(message));
        previous(info);
    }));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn crash_reporting_is_default_off() {
        assert!(!crash_reporting_enabled(None));
        assert!(!crash_reporting_enabled(Some("0")));
        assert!(!crash_reporting_enabled(Some("false")));
        assert!(crash_reporting_enabled(Some("1")));
        assert!(crash_reporting_enabled(Some("true")));
    }

    #[test]
    fn redacts_tokens_phones_and_emails() {
        let text = format!(
            "auth Bearer abc.def.ghi token cgch_secret sk-123456 email demo@example.com phone 13800138000 jwt {}",
            "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.signature"
        );
        let redacted = redact_sensitive(&text);
        assert!(!redacted.contains("cgch_"));
        assert!(!redacted.contains("sk-"));
        assert!(!redacted.contains("demo@example.com"));
        assert!(!redacted.contains("13800138000"));
        assert!(!redacted.contains("eyJhbGci"));
        assert!(redacted.contains("<redacted>"));
        assert!(redacted.contains("<email>"));
        assert!(redacted.contains("<phone>"));
    }

    #[test]
    fn keeps_plain_diagnostics() {
        assert_eq!(
            redact_sensitive("transport error: connection refused"),
            "transport error: connection refused"
        );
    }
}
