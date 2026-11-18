//! CGC Cloud provider adapter: dynamic terminal MCP token + logical model routing.

use std::sync::Arc;

use cgc_agent_provider::{BearerTokenSource, Model, ProviderError, Request};

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

/// CGC Cloud logical model routing:
/// - background compaction/title requests explicitly select `cgc-background`;
/// - thinking requests go to `cgc-reasoning`;
/// - everything else uses `cgc-default`.
pub(super) fn managed_model_id(model: &Model, request: &Request) -> String {
    if model.id.as_str() == "cgc-background" {
        return "cgc-background".to_string();
    }
    if model.id.as_str() == "cgc-reasoning" || request.thinking_enabled == Some(true) {
        return "cgc-reasoning".to_string();
    }
    "cgc-default".to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use cgc_agent_provider::{ModelLimits, ProviderId};

    fn model(id: &str) -> Model {
        Model::new(
            ProviderId::new("cgc-cloud"),
            "CGC Cloud",
            id,
            id,
            ModelLimits::new(1_000_000, 65_536),
        )
    }

    #[test]
    fn routes_managed_models_by_thinking_and_background() {
        let request = Request::new(Vec::new());
        assert_eq!(
            managed_model_id(&model("cgc-default"), &request),
            "cgc-default"
        );
        let thinking = Request::new(Vec::new()).with_thinking_enabled(true);
        assert_eq!(
            managed_model_id(&model("cgc-default"), &thinking),
            "cgc-reasoning"
        );
        assert_eq!(
            managed_model_id(&model("cgc-background"), &request),
            "cgc-background"
        );
    }
}
