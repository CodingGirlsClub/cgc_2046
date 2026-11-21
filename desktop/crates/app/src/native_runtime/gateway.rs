//! CGC Cloud provider adapter: 第一方登录态 Bearer 鉴权。

use std::sync::Arc;

use cgc_agent_provider::{BearerTokenSource, ProviderError};

pub(super) fn token_source() -> Arc<dyn BearerTokenSource> {
    Arc::new(GatewayTokenSource)
}

struct GatewayTokenSource;

impl BearerTokenSource for GatewayTokenSource {
    fn resolve_token(&self) -> Result<String, ProviderError> {
        cgc_platform::gateway::gateway_token().map_err(map_gateway_error)
    }
}

fn map_gateway_error(error: cgc_platform::gateway::GatewayError) -> ProviderError {
    use cgc_platform::gateway::GatewayError;
    match error {
        GatewayError::Unauthenticated => {
            ProviderError::api(401, "CGC session expired; sign in again")
        }
        GatewayError::Transport(reason) => ProviderError::transport(reason),
        GatewayError::Graphql { code, message } => match code.as_deref() {
            Some("insufficient_quota") => ProviderError::insufficient_quota(message),
            Some("concurrency_limit_exceeded") => {
                ProviderError::concurrency_limit_exceeded(message)
            }
            Some("unauthorized") | Some("unauthenticated") => ProviderError::api(401, message),
            _ => ProviderError::api(500, message),
        },
    }
}
