use futures::{future::BoxFuture, stream::BoxStream};

use crate::{
    error::ProviderError,
    event::CompletionEvent,
    model::{Model, ProviderId},
    request::Request,
};

/// Provider 的流式输出。drop 掉 stream 即取消（实现方可据此中断网络读取）。
pub type CompletionStream = BoxStream<'static, Result<CompletionEvent, ProviderError>>;

/// 一个模型 Provider。行为只有 `stream` 一项必填；其余能力按需扩展。
pub trait Provider: Send + Sync {
    fn id(&self) -> &ProviderId;

    fn name(&self) -> &str;

    fn models(&self) -> Vec<Model>;

    /// 发起一次流式请求。返回的 future 只负责建立流；连接/网络错误优先作为
    /// stream 里的 `Err` 项上报，便于 UI 统一处理。
    fn stream(
        &self,
        model: &Model,
        request: Request,
    ) -> BoxFuture<'static, Result<CompletionStream, ProviderError>>;
}
