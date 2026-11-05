use std::time::Duration;

use crate::error::ProviderError;

/// 轻量连通性验证：用 `/models` 端点确认 Base URL 可达、API Key 被接受。
/// 不发起对话请求，避免验证本身消耗 token。
pub fn validate_credentials(base_url: &str, api_key: &str) -> Result<(), ProviderError> {
    let url = models_url(base_url);
    let agent = ureq::Agent::new_with_config(
        ureq::Agent::config_builder()
            .http_status_as_error(false)
            .timeout_global(Some(Duration::from_secs(10)))
            .build(),
    );
    let response = agent
        .get(&url)
        .header("authorization", format!("Bearer {api_key}"))
        .call()
        .map_err(map_ureq_error)?;
    let status = response.status();
    if !status.is_success() {
        let mut response = response;
        let text = response.body_mut().read_to_string().unwrap_or_default();
        return Err(ProviderError::api(status.as_u16(), truncate(&text, 500)));
    }
    Ok(())
}

fn models_url(base_url: &str) -> String {
    format!("{}/models", base_url.trim_end_matches('/'))
}

fn map_ureq_error(error: ureq::Error) -> ProviderError {
    match error {
        ureq::Error::StatusCode(status) => ProviderError::api(status, "http status error"),
        ureq::Error::Timeout(_) => ProviderError::transport("request timed out"),
        ureq::Error::Io(error) => ProviderError::transport(error.to_string()),
        other => ProviderError::transport(other.to_string()),
    }
}

fn truncate(text: &str, max_chars: usize) -> String {
    text.chars().take(max_chars).collect()
}

#[cfg(test)]
mod tests {
    use super::models_url;

    #[test]
    fn models_url_normalizes_trailing_slashes() {
        assert_eq!(
            models_url("https://api.deepseek.com"),
            "https://api.deepseek.com/models"
        );
        assert_eq!(
            models_url("https://api.moonshot.cn/v1/"),
            "https://api.moonshot.cn/v1/models"
        );
    }
}
