use futures::{future, stream, FutureExt, StreamExt};

use crate::{
    error::ProviderError,
    event::{CompletionEvent, StopReason},
    model::Model,
    provider::{CompletionStream, Provider},
    request::Request,
};

/// 离线 demo / 测试用 Provider：把用户最后一条消息原样回显。
pub struct EchoProvider {
    model: Model,
}

impl EchoProvider {
    pub fn new(model: Model) -> Self {
        Self { model }
    }
}

impl Provider for EchoProvider {
    #[allow(clippy::misnamed_getters)]
    fn id(&self) -> &crate::model::ProviderId {
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
        request: Request,
    ) -> future::BoxFuture<'static, Result<CompletionStream, ProviderError>> {
        let last_user = request
            .messages
            .iter()
            .rev()
            .find(|message| message.role == crate::request::Role::User)
            .map(|message| message.text())
            .unwrap_or_default();
        let events = vec![
            Ok(CompletionEvent::Text(format!(
                "（离线 demo）收到：{last_user}"
            ))),
            Ok(CompletionEvent::Stop(StopReason::EndTurn)),
        ];
        let stream: CompletionStream = stream::iter(events).boxed();
        future::ready(Ok(stream)).boxed()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{model::ModelLimits, model::ProviderId, request::Message};

    #[test]
    fn echoes_last_user_message() {
        let model = Model::new(
            ProviderId::new("echo"),
            "Echo",
            "echo",
            "echo",
            ModelLimits::new(8_000, 1_000),
        );
        let provider = EchoProvider::new(model.clone());
        let request = Request::new(vec![
            Message::user("first"),
            Message::assistant_text("reply"),
            Message::user("你好"),
        ]);
        let mut stream =
            futures::executor::block_on(provider.stream(&model, request)).expect("stream");
        let events: Vec<_> = futures::executor::block_on(stream.by_ref().collect::<Vec<_>>());
        let text = events
            .iter()
            .find_map(|event| match event {
                Ok(CompletionEvent::Text(text)) => Some(text.clone()),
                _ => None,
            })
            .expect("text");
        assert!(text.contains("你好"));
        assert!(matches!(
            events.last(),
            Some(Ok(CompletionEvent::Stop(StopReason::EndTurn)))
        ));
    }
}
