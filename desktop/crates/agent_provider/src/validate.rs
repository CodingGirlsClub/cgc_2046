//! 轻量连通性验证：用 `/models` 端点确认 Base URL 可达、API Key 被接受。
//! 不发起对话请求，避免验证本身消耗 token。

use crate::error::ProviderError;

pub fn validate_credentials(
    base_url: &str,
    models_url: Option<&str>,
    api_key: &str,
) -> Result<(), ProviderError> {
    match models_url.filter(|url| !url.trim().is_empty()) {
        Some(url) => crate::probe::list_models_at(url, api_key).map(|_| ()),
        None => crate::probe::list_models(base_url, api_key).map(|_| ()),
    }
}
