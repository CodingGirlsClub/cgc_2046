//! 取消必须能唤醒沉默的模型流：否则 Stop 要等到下一个 delta 才生效。
use std::sync::Arc;
use std::time::Duration;

use cgc_agent_core::{Agent, AgentError, CancelToken, SelectedModel, Thread};
use cgc_agent_provider::{
    CompletionEvent, CompletionStream, Model, ModelLimits, Provider, ProviderError, ProviderId,
    Request,
};

struct SilentProvider {
    model: Model,
}

impl Provider for SilentProvider {
    fn id(&self) -> &ProviderId {
        &self.model.provider_id
    }
    fn name(&self) -> &str {
        "Silent"
    }
    fn models(&self) -> Vec<Model> {
        vec![self.model.clone()]
    }
    fn stream(
        &self,
        _model: &Model,
        _request: Request,
    ) -> futures::future::BoxFuture<'static, Result<CompletionStream, ProviderError>> {
        // 永不产生事件：模拟模型长时间沉默。
        Box::pin(async {
            use futures::StreamExt;
            Ok(
                futures::stream::pending::<Result<CompletionEvent, ProviderError>>().boxed()
                    as CompletionStream,
            )
        })
    }
}

fn model() -> Model {
    Model::new(
        ProviderId::new("fake"),
        "Silent",
        "m1",
        "m1",
        ModelLimits::new(8_000, 1_000),
    )
}

#[test]
fn cancel_wakes_a_silent_stream_instead_of_waiting_for_the_next_event() {
    let model = model();
    let provider: Arc<dyn Provider> = Arc::new(SilentProvider {
        model: model.clone(),
    });
    let mut agent = Agent::new(
        Thread::new(
            "quiet",
            SelectedModel::new(model.provider_id.clone(), model.id.clone()),
        ),
        None,
    );
    let cancel: CancelToken = agent.cancel_token();

    let (sender, receiver) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let result = futures::executor::block_on(agent.prompt(provider.as_ref(), &model, "hi"));
        let _ = sender.send(result);
    });

    std::thread::sleep(Duration::from_millis(150));
    cancel.cancel();

    match receiver.recv_timeout(Duration::from_secs(3)) {
        Ok(Ok(_)) => panic!("取消后不应成功完成"),
        Ok(Err(AgentError::Cancelled)) => {}
        Ok(Err(other)) => panic!("期望 Cancelled，实际 {other}"),
        Err(_) => panic!("取消没有唤醒沉默的流：prompt 仍在等待下一个事件"),
    }
}
