//! 轻量连通性验证：用 `/models` 端点确认 Base URL 可达、API Key 被接受。
//! 不发起对话请求，避免验证本身消耗 token。

use crate::error::ProviderError;

pub fn validate_credentials(base_url: &str, api_key: &str) -> Result<(), ProviderError> {
    crate::probe::list_models(base_url, api_key).map(|_| ())
}
