use futures::{future, FutureExt};

use crate::{
    error::{ProviderError, ProviderErrorCategory},
    model::{Model, ProviderId},
    provider::{CompletionStream, Provider},
    request::Request,
};

/// 未配置模型时的 Provider：不发起任何请求，直接把可读的配置错误交给上层。
/// 生产环境用它替代 EchoProvider，避免用户收到看似正常的离线回显。
pub struct UnconfiguredProvider {
    model: Model,
}

impl UnconfiguredProvider {
    pub fn new(model: Model) -> Self {
        Self { model }
    }
}

impl Provider for UnconfiguredProvider {
    #[allow(clippy::misnamed_getters)]
    fn id(&self) -> &ProviderId {
        &self.model.provider_id
    }

    #[allow(clippy::misnamed_getters)]
    fn name(&self) -> &str {
        &self.model.provider_name
    }

    fn models(&self) -> Vec<Model> {
        vec![self.model.clone()]
    }

    fn stream(
        &self,
        _model: &Model,
        _request: Request,
    ) -> future::BoxFuture<'static, Result<CompletionStream, ProviderError>> {
        future::ready(Err(ProviderError::api_with_category(
            ProviderErrorCategory::InvalidRequest,
            None,
            "未配置模型，请先在 Settings → AI → LLM Providers 配置 Provider",
        )))
        .boxed()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::ModelLimits;

    #[test]
    fn reports_unconfigured_error_without_streaming() {
        let model = Model::new(
            ProviderId::new("unconfigured"),
            "Unconfigured",
            "unconfigured",
            "unconfigured",
            ModelLimits::new(8_000, 1_000),
        );
        let provider = UnconfiguredProvider::new(model.clone());
        let result = futures::executor::block_on(provider.stream(&model, Request::default()));
        let error = match result {
            Ok(_) => panic!("unconfigured provider must fail before streaming"),
            Err(error) => error,
        };
        assert_eq!(error.category(), ProviderErrorCategory::InvalidRequest);
        assert!(error.to_string().contains("未配置模型"));
    }
}
