use std::{collections::VecDeque, sync::Mutex};

use futures::{future, stream, FutureExt, StreamExt};

use crate::{
    error::ProviderError,
    event::{CompletionEvent, StopReason},
    model::{Model, ProviderId},
    provider::{CompletionStream, Provider},
    request::Request,
};

/// 测试与事件回放用的 Provider：按脚本吐事件，并记录收到的请求。
pub struct FakeProvider {
    id: ProviderId,
    name: String,
    models: Vec<Model>,
    scripts: Mutex<VecDeque<Vec<Result<CompletionEvent, ProviderError>>>>,
    requests: Mutex<Vec<Request>>,
}

impl FakeProvider {
    pub fn new(id: ProviderId, name: impl Into<String>, models: Vec<Model>) -> Self {
        Self {
            id,
            name: name.into(),
            models,
            scripts: Mutex::new(VecDeque::new()),
            requests: Mutex::new(Vec::new()),
        }
    }

    /// 追加一段脚本；每次 `stream` 消费一段。
    pub fn push_script(&self, script: Vec<Result<CompletionEvent, ProviderError>>) {
        self.scripts.lock().expect("scripts").push_back(script);
    }

    pub fn requests(&self) -> Vec<Request> {
        self.requests.lock().expect("requests").clone()
    }
}

impl Provider for FakeProvider {
    fn id(&self) -> &ProviderId {
        &self.id
    }

    fn name(&self) -> &str {
        &self.name
    }

    fn models(&self) -> Vec<Model> {
        self.models.clone()
    }

    fn stream(
        &self,
        _model: &Model,
        request: Request,
    ) -> future::BoxFuture<'static, Result<CompletionStream, ProviderError>> {
        self.requests.lock().expect("requests").push(request);
        let script = self
            .scripts
            .lock()
            .expect("scripts")
            .pop_front()
            .unwrap_or_else(|| {
                vec![
                    Ok(CompletionEvent::Text("ok".to_string())),
                    Ok(CompletionEvent::Stop(StopReason::EndTurn)),
                ]
            });
        let stream: CompletionStream = stream::iter(script).boxed();
        future::ready(Ok(stream)).boxed()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{model::ModelLimits, request::Message};

    fn model() -> Model {
        Model::new(
            ProviderId::new("fake"),
            "Fake",
            "m1",
            "m1",
            ModelLimits::new(8_000, 1_000),
        )
    }

    fn collect(
        provider: &dyn Provider,
        request: Request,
    ) -> Vec<Result<CompletionEvent, ProviderError>> {
        let stream =
            futures::executor::block_on(provider.stream(&model(), request)).expect("stream");
        futures::executor::block_on(stream.collect::<Vec<_>>())
    }

    #[test]
    fn fake_streams_script() {
        let fake = FakeProvider::new(ProviderId::new("fake"), "Fake", vec![model()]);
        fake.push_script(vec![
            Ok(CompletionEvent::Text("hel".into())),
            Ok(CompletionEvent::Text("lo".into())),
            Ok(CompletionEvent::Stop(StopReason::EndTurn)),
        ]);
        let events = collect(&fake, Request::new(vec![Message::user("hi")]));
        assert_eq!(events.len(), 3);
        assert_eq!(
            events[0].as_ref().unwrap(),
            &CompletionEvent::Text("hel".into())
        );
    }

    #[test]
    fn fake_records_requests() {
        let fake = FakeProvider::new(ProviderId::new("fake"), "Fake", vec![model()]);
        let _ = collect(&fake, Request::new(vec![Message::user("hello")]));
        let requests = fake.requests();
        assert_eq!(requests.len(), 1);
        assert_eq!(requests[0].messages[0].text(), "hello");
    }

    #[test]
    fn fake_errors_flow_through_stream() {
        let fake = FakeProvider::new(ProviderId::new("fake"), "Fake", vec![model()]);
        fake.push_script(vec![Err(ProviderError::api(429, "slow down"))]);
        let events = collect(&fake, Request::new(vec![Message::user("hi")]));
        assert_eq!(events.len(), 1);
        assert!(events[0].as_ref().unwrap_err().is_retryable());
    }
}
