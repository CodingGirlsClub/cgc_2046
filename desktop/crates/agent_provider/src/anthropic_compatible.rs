use crate::{
    sse::SseDecoder, CompletionEvent, CompletionStream, Model, Provider, ProviderError, ProviderId,
    Request,
};
use futures::{channel::mpsc, future, FutureExt, SinkExt};
use serde_json::Value;
use std::{
    io::{BufRead, BufReader},
    sync::Arc,
    time::Duration,
};
use ureq::unversioned::{
    resolver::DefaultResolver,
    transport::{ConnectProxyConnector, Connector, RustlsConnector},
};

mod body;
mod cancel;
mod stream;

#[cfg(test)]
mod tests;

#[derive(Clone, Debug)]
pub struct AnthropicCompatibleConfig {
    pub base_url: String,
    pub api_key: String,
    pub models: Vec<Model>,
}

impl AnthropicCompatibleConfig {
    pub fn new(
        base_url: impl Into<String>,
        api_key: impl Into<String>,
        models: Vec<Model>,
    ) -> Self {
        Self {
            base_url: base_url.into(),
            api_key: api_key.into(),
            models,
        }
    }

    /// API root may include a gateway prefix or /v1, but never a full messages route.
    pub fn messages_url(&self) -> String {
        let root = self.base_url.trim().trim_end_matches('/');
        if root.ends_with("/v1") {
            format!("{root}/messages")
        } else {
            format!("{root}/v1/messages")
        }
    }
}

pub struct AnthropicCompatibleProvider {
    config: Arc<AnthropicCompatibleConfig>,
}

impl AnthropicCompatibleProvider {
    pub fn new(config: AnthropicCompatibleConfig) -> Self {
        Self {
            config: Arc::new(config),
        }
    }
}

impl Provider for AnthropicCompatibleProvider {
    fn id(&self) -> &ProviderId {
        &self
            .config
            .models
            .first()
            .expect("AnthropicCompatibleProvider requires at least one model")
            .provider_id
    }
    fn name(&self) -> &str {
        self.config
            .models
            .first()
            .map_or("Anthropic Compatible", |model| model.provider_name.as_str())
    }
    fn models(&self) -> Vec<Model> {
        self.config.models.clone()
    }
    fn stream(
        &self,
        model: &Model,
        request: Request,
    ) -> future::BoxFuture<'static, Result<CompletionStream, ProviderError>> {
        let body = match body::build_body(model, &request) {
            Ok(body) => body,
            Err(error) => return future::ready(Err(error)).boxed(),
        };
        future::ready(start_request(self.config.clone(), body).map(|(stream, _worker)| stream))
            .boxed()
    }
}

fn start_request(
    config: Arc<AnthropicCompatibleConfig>,
    body: Value,
) -> Result<(CompletionStream, std::thread::JoinHandle<()>), ProviderError> {
    let cancel = cancel::Cancel::default();
    let worker_cancel = cancel.clone();
    let (mut sender, receiver) = mpsc::channel(32);
    let worker = std::thread::Builder::new()
        .name("cgc-anthropic-provider".into())
        .spawn(move || {
            let result = run_request(&config, &body, &mut sender, &worker_cancel);
            worker_cancel.release();
            if let Err(error) = result {
                let _ = send(&mut sender, Err(error));
            }
        })
        .map_err(|error| ProviderError::transport(format!("spawn Anthropic provider: {error}")))?;
    let stream: CompletionStream = Box::pin(cancel::CancelOnDrop {
        inner: receiver,
        cancel,
    });
    Ok((stream, worker))
}

fn send(
    sender: &mut mpsc::Sender<Result<CompletionEvent, ProviderError>>,
    event: Result<CompletionEvent, ProviderError>,
) -> bool {
    futures::executor::block_on(sender.send(event)).is_ok()
}

fn run_request(
    config: &AnthropicCompatibleConfig,
    body: &Value,
    sender: &mut mpsc::Sender<Result<CompletionEvent, ProviderError>>,
    cancel: &cancel::Cancel,
) -> Result<(), ProviderError> {
    // Keep the bounded worker pattern shared with OpenAI; Anthropic requires a message_stop
    // and cannot use OpenAI's EOF finalization or [DONE] marker as proof of success.
    if sender.is_closed() {
        return Ok(());
    }
    let agent_config = ureq::Agent::config_builder()
        .http_status_as_error(false)
        .max_redirects(0)
        .timeout_global(Some(Duration::from_secs(300)))
        .build();
    let connector = ConnectProxyConnector::default()
        .chain(cancel::CancellingTcpConnector {
            cancel: cancel.clone(),
        })
        .chain(RustlsConnector::default());
    let agent = ureq::Agent::with_parts(agent_config, connector, DefaultResolver::default());
    let mut response = agent
        .post(&config.messages_url())
        .header("x-api-key", config.api_key.trim())
        .header("anthropic-version", "2023-06-01")
        .header("accept", "text/event-stream")
        .send_json(body)
        .map_err(|error| ProviderError::transport(error.to_string()))?;
    if !response.status().is_success() {
        let status = response.status().as_u16();
        let message = response.body_mut().read_to_string().unwrap_or_default();
        return Err(ProviderError::api(
            status,
            message.chars().take(500).collect::<String>(),
        ));
    }
    let mut reader = BufReader::new(response.into_body().into_reader());
    let mut decoder = SseDecoder::new();
    let mut state = stream::StreamState::default();
    let mut line = String::new();
    loop {
        if sender.is_closed() {
            return Ok(());
        }
        line.clear();
        if reader
            .read_line(&mut line)
            .map_err(|error| ProviderError::transport(format!("read Anthropic stream: {error}")))?
            == 0
        {
            break;
        }
        for event in decoder.feed(&line) {
            if sender.is_closed() {
                return Ok(());
            }
            for event in state.on_event(event)? {
                let stopped = matches!(event, CompletionEvent::Stop(_));
                if !send(sender, Ok(event)) || stopped {
                    return Ok(());
                }
            }
        }
    }
    if let Some(event) = decoder.finish() {
        for event in state.on_event(event)? {
            let stopped = matches!(event, CompletionEvent::Stop(_));
            if !send(sender, Ok(event)) || stopped {
                return Ok(());
            }
        }
    }
    Err(ProviderError::invalid_response(
        "Anthropic stream ended before message_stop",
    ))
}
