//! 两个 HTTP Provider 适配器共用的传输辅助。

use futures::channel::mpsc;

use crate::error::ProviderError;
use crate::event::CompletionEvent;

/// 阻塞式送入；返回 `false` 表示消费者已放弃，worker 应尽快退出。
pub(crate) fn send_blocking(
    sender: &mut mpsc::Sender<Result<CompletionEvent, ProviderError>>,
    event: Result<CompletionEvent, ProviderError>,
) -> bool {
    use futures::SinkExt as _;
    futures::executor::block_on(sender.send(event)).is_ok()
}

pub(crate) fn map_ureq_error(error: ureq::Error) -> ProviderError {
    match error {
        ureq::Error::StatusCode(status) => ProviderError::api(status, "http status error"),
        ureq::Error::Timeout(_) => ProviderError::transport("request timed out"),
        ureq::Error::Io(error) => ProviderError::transport(error.to_string()),
        other => ProviderError::transport(other.to_string()),
    }
}

pub(crate) fn truncate(text: &str, max_chars: usize) -> String {
    text.chars().take(max_chars).collect()
}
