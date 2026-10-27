//! Owner-level concurrency guards: a running turn must reject thread replacement
//! before it mutates the current thread, and must reopen only after completion.
use cgc_agent_core::{Entry, SelectedModel, Thread};
use cgc_agent_host::NativeAcpServer;
use cgc_agent_provider::{
    CompletionEvent, CompletionStream, Model, ModelLimits, Provider, ProviderError, ProviderId,
    Request, StopReason,
};
use cgc_agent_tools::{ToolContext, ToolRegistry};
use cgc_desktop_app::native_runtime::{
    NativeRuntimeConfig, NativeRuntimeError, NativeRuntimeHandle, RuntimePhase,
};
use cgc_platform::acp::connection::{AcpHost, AcpHostConfig, HostEvent};
use futures::executor::block_on;
use std::{sync::Arc, time::Duration};

fn model() -> Model {
    Model::new(
        ProviderId::new("fake"),
        "Fake",
        "m1",
        "m1",
        ModelLimits::new(8_000, 1_000),
    )
}

/// 后台线程按 150ms 节奏发送 delta；owner executor 在事件之间可继续处理命令，
/// 因而 Runnable 期间能真实观测到 Busy 拒绝（而不是被阻塞的假象）。
struct SlowProvider {
    id: ProviderId,
    model: Model,
}

impl Provider for SlowProvider {
    fn id(&self) -> &ProviderId {
        &self.id
    }
    fn name(&self) -> &str {
        "Slow"
    }
    fn models(&self) -> Vec<Model> {
        vec![self.model.clone()]
    }
    fn stream(
        &self,
        _model: &Model,
        _request: Request,
    ) -> futures::future::BoxFuture<'static, Result<CompletionStream, ProviderError>> {
        use futures::StreamExt;
        let (sender, receiver) = futures::channel::mpsc::unbounded();
        std::thread::spawn(move || {
            for index in 0..20 {
                std::thread::sleep(Duration::from_millis(150));
                if sender
                    .unbounded_send(Ok(CompletionEvent::Text(format!("chunk-{index} "))))
                    .is_err()
                {
                    return;
                }
            }
            let _ = sender.unbounded_send(Ok(CompletionEvent::Stop(StopReason::EndTurn)));
        });
        Box::pin(futures::future::ready(Ok(
            receiver.boxed() as CompletionStream
        )))
    }
}

#[test]
fn opening_or_replacing_a_thread_during_a_turn_returns_busy_and_keeps_content() {
    let workspace = std::env::temp_dir().join(format!("cgc-native-busy-{}", std::process::id()));
    std::fs::create_dir_all(&workspace).unwrap();
    let provider: Arc<dyn Provider> = Arc::new(SlowProvider {
        id: ProviderId::new("fake"),
        model: model(),
    });

    let runtime = NativeRuntimeHandle::spawn(
        Thread::new(
            "busy-thread",
            SelectedModel::new(ProviderId::new("fake"), model().id.clone()),
        ),
        None,
        NativeRuntimeConfig {
            provider,
            model: model(),
            registry: Arc::new(ToolRegistry::new()),
            context: ToolContext::new(&workspace),
            context_size: 8_000,
            auto_approve: true,
        },
        None,
    );
    let binding = block_on(runtime.connect()).expect("bind owner");
    let host = AcpHost::start_in_process(
        AcpHostConfig::new("", workspace.clone()),
        NativeAcpServer::new(Box::new(binding)),
    )
    .expect("start host");
    loop {
        let event = host
            .recv_timeout(Duration::from_secs(10))
            .expect("ready event");
        let ready = matches!(event, HostEvent::Ready { .. });
        if ready {
            break;
        }
    }

    assert!(host.prompt("慢一点回答"));
    // Turn 开始时 owner 立即取消 ready 并置 active；首个 delta 之前就能观察 Running
    // 之外的证据：此时发起的线程替换必须被 Busy 拒绝，且不改变内容/世代。
    std::thread::sleep(Duration::from_millis(300));
    let before = block_on(runtime.inspect()).unwrap();
    assert_eq!(before.thread.id, "busy-thread");

    // 生成中打开另一个线程 / 新建会话：必须 Busy。
    let opened = block_on(runtime.open_thread("another-thread".to_string()));
    assert_eq!(
        opened.err(),
        Some(NativeRuntimeError::Busy),
        "生成中不得切换线程"
    );
    let new_thread = block_on(runtime.new_thread());
    assert_eq!(
        new_thread.err(),
        Some(NativeRuntimeError::Busy),
        "生成中不得新建会话"
    );
    let after = block_on(runtime.inspect()).unwrap();
    assert_eq!(after.thread.id, before.thread.id, "线程不得被替换");
    assert_eq!(
        after.thread.entries, before.thread.entries,
        "内容不得被清空"
    );

    // 本轮正常完成后，内容保留且可以再开新线程。
    let deadline = std::time::Instant::now() + Duration::from_secs(20);
    while block_on(runtime.inspect()).unwrap().phase != RuntimePhase::Idle {
        assert!(std::time::Instant::now() < deadline, "turn never finished");
        std::thread::sleep(Duration::from_millis(20));
    }
    let finished = block_on(runtime.inspect()).unwrap();
    assert!(
        matches!(&finished.thread.entries[..], [Entry::User { text, .. }, Entry::Assistant { .. }] if text == "慢一点回答"),
        "完成后的线程应保留本轮 user + assistant：{:?}",
        finished.thread.entries.len()
    );
    assert!(block_on(runtime.new_thread()).is_ok(), "空闲后允许新建会话");

    host.shutdown();
    std::fs::remove_dir_all(workspace).ok();
}
