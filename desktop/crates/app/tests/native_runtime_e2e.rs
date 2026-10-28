//! Real Agent → native ACP server → AcpHost; views never take or replace the Agent.
use cgc_agent_core::{Entry, SelectedModel, Thread};
use cgc_agent_host::{NativeAcpServer, NativeAcpServerConfig};
use cgc_agent_provider::{
    CompletionEvent, CompletionStream, FakeProvider, Model, ModelId, ModelLimits, Provider,
    ProviderError, ProviderId, Request, StopReason,
};
use cgc_agent_tools::{ToolContext, ToolRegistry};
use cgc_desktop_app::native_runtime::{
    NativeRuntimeConfig, NativeRuntimeHandle, NativeRuntimeSnapshot, RuntimePhase,
};
use cgc_platform::acp::connection::{AcpHost, AcpHostConfig, HostEvent};
use futures::{executor::block_on, future, stream, FutureExt as _, StreamExt as _};
use std::{
    sync::Arc,
    time::{Duration, Instant},
};

fn model(provider: &str) -> Model {
    Model::new(
        ProviderId::new(provider),
        "Fake",
        "m1",
        "m1",
        ModelLimits::new(8_000, 1_000),
    )
}
fn workspace(tag: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("cgc-native-runtime-{}-{tag}", std::process::id()));
    std::fs::create_dir_all(&dir).expect("workspace");
    dir
}
fn runtime(provider: Arc<dyn Provider>, selected: Model, id: &str) -> NativeRuntimeHandle {
    NativeRuntimeHandle::spawn(
        Thread::new(
            id,
            SelectedModel::new(ProviderId::new("fake"), ModelId::new("m1")),
        ),
        None,
        NativeRuntimeConfig {
            provider,
            model: selected,
            registry: Arc::new(ToolRegistry::new()),
            context: ToolContext::new(workspace(id)),
            context_size: 8_000,
            auto_approve: true,
        },
        None,
    )
}
fn start_host(runtime: &NativeRuntimeHandle) -> AcpHost {
    let binding = block_on(runtime.connect()).expect("bind owner");
    let server = NativeAcpServer::new(Box::new(binding)).with_config(NativeAcpServerConfig {
        agent_name: "cgc-native".into(),
        version: "test".into(),
    });
    AcpHost::start_in_process(AcpHostConfig::new("", workspace("host")), server)
        .expect("start host")
}
fn wait_for(host: &AcpHost, predicate: impl Fn(&HostEvent) -> bool) -> Vec<HostEvent> {
    let mut events = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline {
        if let Some(event) = host.recv_timeout(Duration::from_millis(50)) {
            let matched = predicate(&event);
            events.push(event);
            if matched {
                return events;
            }
        }
    }
    panic!("expected event not received: {events:?}");
}
fn wait_ready(host: &AcpHost) {
    wait_for(host, |event| matches!(event, HostEvent::Ready { .. }));
}
fn wait_title(runtime: &NativeRuntimeHandle, expected: &str) {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let snapshot = block_on(runtime.inspect()).expect("snapshot");
        if snapshot.display_title.as_deref() == Some(expected) {
            return;
        }
        assert!(
            Instant::now() < deadline,
            "title never generated: {:?}",
            snapshot.display_title
        );
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn wait_until(runtime: &NativeRuntimeHandle, predicate: impl Fn(&NativeRuntimeSnapshot) -> bool) {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let snapshot = block_on(runtime.inspect()).expect("snapshot");
        if predicate(&snapshot) {
            return;
        }
        assert!(Instant::now() < deadline, "condition never met");
        std::thread::sleep(Duration::from_millis(20));
    }
}

/// 标题生成是后台任务：turn 结束不等于标题已完成，但也不能反过来阻塞下一轮。
struct BackgroundTitleProvider {
    id: ProviderId,
    model: Model,
    title_delay: Duration,
}

impl Provider for BackgroundTitleProvider {
    fn id(&self) -> &ProviderId {
        &self.id
    }
    fn name(&self) -> &str {
        "BackgroundTitle"
    }
    fn models(&self) -> Vec<Model> {
        vec![self.model.clone()]
    }
    fn stream(
        &self,
        _model: &Model,
        request: Request,
    ) -> future::BoxFuture<'static, Result<CompletionStream, ProviderError>> {
        let is_title = request
            .messages
            .iter()
            .any(|message| message.text().contains("简洁的标题"));
        if is_title {
            let (sender, receiver) = futures::channel::mpsc::unbounded();
            let delay = self.title_delay;
            std::thread::spawn(move || {
                std::thread::sleep(delay);
                let _ = sender.unbounded_send(Ok(CompletionEvent::Text("后台标题".into())));
                let _ = sender.unbounded_send(Ok(CompletionEvent::Stop(StopReason::EndTurn)));
            });
            future::ready(Ok(receiver.boxed() as CompletionStream)).boxed()
        } else {
            future::ready(Ok(stream::iter(vec![
                Ok(CompletionEvent::Text("ok".into())),
                Ok(CompletionEvent::Stop(StopReason::EndTurn)),
            ])
            .boxed() as CompletionStream))
            .boxed()
        }
    }
}

#[test]
fn native_runtime_turn_flows_through_acp_and_owner_keeps_execution_thread() {
    let provider = Arc::new(FakeProvider::new(
        ProviderId::new("fake"),
        "Fake",
        vec![model("fake")],
    ));
    provider.push_script(vec![
        Ok(CompletionEvent::Text("hi".into())),
        Ok(CompletionEvent::Stop(StopReason::EndTurn)),
    ]);
    let runtime = runtime(provider, model("fake"), "turn");
    let host = start_host(&runtime);
    wait_ready(&host);
    assert!(host.prompt("hi"));
    let events = wait_for(&host, |event| matches!(event, HostEvent::TurnEnd { .. }));
    assert!(events
        .iter()
        .any(|event| matches!(event, HostEvent::Delta(text) if text == "hi")));
    assert!(events.iter().any(|event| matches!(
        event,
        HostEvent::TurnEnd {
            cancelled: false,
            ..
        }
    )));
    let snapshot = block_on(runtime.inspect()).expect("snapshot");
    assert!(
        matches!(&snapshot.thread.entries[..], [Entry::User { text: user, .. }, Entry::Assistant { text, .. }] if user == "hi" && text == "hi")
    );
    // 标题是后台 job，不影响 phase；turn 收尾即 Idle。
    assert_eq!(snapshot.phase, RuntimePhase::Idle);
    host.shutdown();
}

#[test]
fn completed_turn_generates_thread_title_once() {
    let provider = Arc::new(FakeProvider::new(
        ProviderId::new("fake"),
        "Fake",
        vec![model("fake")],
    ));
    provider.push_script(vec![
        Ok(CompletionEvent::Text("hi".into())),
        Ok(CompletionEvent::Stop(StopReason::EndTurn)),
    ]);
    // 第二次 stream 是 turn 结束后 owner 自动发起的标题生成。
    provider.push_script(vec![
        Ok(CompletionEvent::Text("自动生成的标题".into())),
        Ok(CompletionEvent::Stop(StopReason::EndTurn)),
    ]);
    let runtime = runtime(provider.clone(), model("fake"), "auto-title");
    let host = start_host(&runtime);
    wait_ready(&host);
    assert!(host.prompt("hi"));
    wait_for(&host, |event| matches!(event, HostEvent::TurnEnd { .. }));
    wait_title(&runtime, "自动生成的标题");

    let requests = provider.requests();
    assert_eq!(
        requests.len(),
        2,
        "成功 turn 后应只补一次标题生成: {requests:?}"
    );
    let title_request = &requests[1];
    assert!(
        title_request
            .messages
            .iter()
            .any(|message| message.text().contains("简洁的标题")),
        "标题请求应使用 Zed 的 summarize_thread 提示: {title_request:?}"
    );
    assert!(
        title_request
            .messages
            .iter()
            .any(|message| message.text() == "hi"),
        "标题请求应携带全量历史（含会话原文）: {title_request:?}"
    );
    assert!(
        title_request.messages.len() >= 3,
        "标题请求 = 历史消息 + 末尾提示: {title_request:?}"
    );
    assert!(
        title_request
            .messages
            .last()
            .is_some_and(|message| message.text().contains("简洁的标题")),
        "摘要提示应在消息末尾: {title_request:?}"
    );

    // 标题已存在后，后续成功 turn 不得重复生成标题。
    provider.push_script(vec![
        Ok(CompletionEvent::Text("again".into())),
        Ok(CompletionEvent::Stop(StopReason::EndTurn)),
    ]);
    assert!(host.prompt("follow up"));
    wait_for(&host, |event| matches!(event, HostEvent::TurnEnd { .. }));
    std::thread::sleep(Duration::from_millis(200));
    assert_eq!(provider.requests().len(), 3, "标题已存在时不应再次生成标题");
    assert_eq!(
        block_on(runtime.inspect())
            .expect("snapshot")
            .display_title
            .as_deref(),
        Some("自动生成的标题")
    );
    host.shutdown();
}

#[test]
fn failed_turn_preserves_owner_and_can_be_followed_by_another_connection() {
    let provider = Arc::new(FakeProvider::new(
        ProviderId::new("fake"),
        "Fake",
        vec![model("fake")],
    ));
    let runtime = runtime(provider, model("other"), "error");
    let host = start_host(&runtime);
    wait_ready(&host);
    assert!(host.prompt("hi"));
    let events = wait_for(&host, |event| matches!(event, HostEvent::Error { .. }));
    assert!(events
        .iter()
        .any(|event| matches!(event, HostEvent::Error { message } if message.contains("model"))));
    assert_eq!(
        block_on(runtime.inspect()).unwrap().phase,
        RuntimePhase::Idle
    );
    host.shutdown();
    let next = start_host(&runtime);
    wait_ready(&next);
    next.shutdown();
}

#[test]
fn title_generation_runs_in_background_and_does_not_block_next_turn() {
    let provider: Arc<dyn Provider> = Arc::new(BackgroundTitleProvider {
        id: ProviderId::new("fake"),
        model: model("fake"),
        title_delay: Duration::from_millis(1_500),
    });
    let runtime = runtime(provider, model("fake"), "bg-title");
    let host = start_host(&runtime);
    wait_ready(&host);
    assert!(host.prompt("first"));
    wait_for(&host, |event| matches!(event, HostEvent::TurnEnd { .. }));
    wait_until(&runtime, |snapshot| snapshot.title_generating);

    // 标题还在后台生成时即可开始下一轮。
    assert!(host.prompt("second"));
    let events = wait_for(&host, |event| matches!(event, HostEvent::TurnEnd { .. }));
    assert!(events
        .iter()
        .any(|event| matches!(event, HostEvent::Delta(text) if text == "ok")));
    assert!(
        block_on(runtime.inspect())
            .expect("snapshot")
            .title_generating,
        "第二轮回合结束时标题仍应在后台生成（不能被标题阻塞）"
    );

    wait_title(&runtime, "后台标题");
    assert!(
        !block_on(runtime.inspect())
            .expect("snapshot")
            .title_generating
    );
    host.shutdown();
}

#[test]
fn failed_title_generation_surfaces_error_and_can_be_retried() {
    let provider = Arc::new(FakeProvider::new(
        ProviderId::new("fake"),
        "Fake",
        vec![model("fake")],
    ));
    provider.push_script(vec![
        Ok(CompletionEvent::Text("hi".into())),
        Ok(CompletionEvent::Stop(StopReason::EndTurn)),
    ]);
    provider.push_script(vec![Err(ProviderError::Transport("boom".into()))]);
    provider.push_script(vec![
        Ok(CompletionEvent::Text("重试标题".into())),
        Ok(CompletionEvent::Stop(StopReason::EndTurn)),
    ]);
    let runtime = runtime(provider, model("fake"), "title-error");
    let host = start_host(&runtime);
    wait_ready(&host);
    assert!(host.prompt("hi"));
    wait_for(&host, |event| matches!(event, HostEvent::TurnEnd { .. }));

    wait_until(&runtime, |snapshot| {
        snapshot.title_generation_error.is_some()
    });
    let snapshot = block_on(runtime.inspect()).expect("snapshot");
    assert!(
        snapshot
            .title_generation_error
            .as_deref()
            .is_some_and(|error| error.contains("boom")),
        "应保留失败诊断：{:?}",
        snapshot.title_generation_error
    );
    assert_eq!(snapshot.display_title, None);
    assert!(!snapshot.title_generating);

    runtime.generate_title(true);
    wait_title(&runtime, "重试标题");
    let snapshot = block_on(runtime.inspect()).expect("snapshot");
    assert_eq!(snapshot.title_generation_error, None);
    host.shutdown();
}

#[test]
fn superseded_server_cannot_consume_the_current_runtime() {
    let provider = Arc::new(FakeProvider::new(
        ProviderId::new("fake"),
        "Fake",
        vec![model("fake")],
    ));
    let runtime = runtime(provider.clone(), model("fake"), "generation-thread");
    let old = start_host(&runtime);
    wait_ready(&old);
    let current = start_host(&runtime);
    wait_ready(&current);
    assert!(old.prompt("stale server input"));
    wait_for(&old, |event| {
        matches!(event, HostEvent::Error { .. } | HostEvent::TurnEnd { .. })
    });
    assert!(
        provider.requests().is_empty(),
        "stale server must be rejected before provider access"
    );
    assert!(current.prompt("current server input"));
    let events = wait_for(&current, |event| matches!(event, HostEvent::TurnEnd { .. }));
    assert!(events
        .iter()
        .any(|event| matches!(event, HostEvent::Delta(text) if text == "ok")));
    let requests = provider.requests();
    // turn 成功后 owner 会补一次标题生成，最后一个请求不再是用户消息；只要当前输入
    // 确实到达过 provider 即可。
    assert!(requests.iter().any(|request| request
        .messages
        .iter()
        .any(|message| message.text() == "current server input")));
    assert!(!requests
        .iter()
        .flat_map(|request| &request.messages)
        .any(|message| message.text() == "stale server input"));
    old.shutdown();
    current.shutdown();
}
