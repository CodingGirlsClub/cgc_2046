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
        eprintln!("[busy] provider.stream called");
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
    // 这个用例曾在 CI 上挂死：runtime worker 一旦卡住，`block_on(inspect())` 永不返回，
    // 整个 job 只能等 60 分钟超时（2026-10-28 macOS 腿实际发生）。用看门狗把「挂死」
    // 收敛成 45s 内的明确失败，别让 CI 再被拖一小时。
    let handle = std::thread::spawn(scenario);
    let deadline = std::time::Instant::now() + Duration::from_secs(45);
    while !handle.is_finished() {
        if std::time::Instant::now() > deadline {
            panic!("native_runtime_busy 用例 45s 未完成（疑似 runtime worker 死锁）");
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    handle.join().expect("scenario panicked");
}

fn scenario() {
    eprintln!("[busy] 1 start");
    let workspace = std::env::temp_dir().join(format!("cgc-native-busy-{}", std::process::id()));
    std::fs::create_dir_all(&workspace).unwrap();
    let provider: Arc<dyn Provider> = Arc::new(SlowProvider {
        id: ProviderId::new("fake"),
        model: model(),
    });

    eprintln!("[busy] 2 spawning runtime");
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
    eprintln!("[busy] 3 connecting");
    let binding = block_on(runtime.connect()).expect("bind owner");
    eprintln!("[busy] 3 connected");
    let host = AcpHost::start_in_process(
        AcpHostConfig::new("", workspace.clone()),
        NativeAcpServer::new(Box::new(binding)),
    )
    .expect("start host");
    eprintln!("[busy] 4 host started, waiting ready");
    loop {
        let event = host
            .recv_timeout(Duration::from_secs(10))
            .expect("ready event");
        let ready = matches!(event, HostEvent::Ready { .. });
        if ready {
            eprintln!("[busy] 4 ready");
            break;
        }
        eprintln!("[busy] 4 non-ready event");
    }

    assert!(host.prompt("慢一点回答"));
    eprintln!("[busy] 5 prompted");
    // Turn 开始时 owner 立即取消 ready 并置 active；首个 delta 之前就能观察 Running
    // 之外的证据：此时发起的线程替换必须被 Busy 拒绝，且不改变内容/世代。
    std::thread::sleep(Duration::from_millis(300));
    eprintln!("[busy] 6 inspecting");
    let before = block_on(runtime.inspect()).unwrap();
    eprintln!("[busy] 6 inspected");
    assert_eq!(before.thread.id, "busy-thread");

    // 生成中打开另一个线程 / 新建会话：必须 Busy。
    eprintln!("[busy] 7 open_thread");
    let opened = block_on(runtime.open_thread("another-thread".to_string()));
    assert_eq!(
        opened.err(),
        Some(NativeRuntimeError::Busy),
        "生成中不得切换线程"
    );
    eprintln!("[busy] 7 new_thread");
    let new_thread = block_on(runtime.new_thread());
    assert_eq!(
        new_thread.err(),
        Some(NativeRuntimeError::Busy),
        "生成中不得新建会话"
    );
    eprintln!("[busy] 8 inspect after");
    let after = block_on(runtime.inspect()).unwrap();
    assert_eq!(after.thread.id, before.thread.id, "线程不得被替换");
    assert_eq!(
        after.thread.entries, before.thread.entries,
        "内容不得被清空"
    );

    // 本轮正常完成后，内容保留且可以再开新线程。
    let deadline = std::time::Instant::now() + Duration::from_secs(20);
    eprintln!("[busy] 9 waiting idle");
    while block_on(runtime.inspect()).unwrap().phase != RuntimePhase::Idle {
        assert!(std::time::Instant::now() < deadline, "turn never finished");
        std::thread::sleep(Duration::from_millis(20));
    }
    eprintln!("[busy] 10 idle reached");
    let finished = block_on(runtime.inspect()).unwrap();
    eprintln!("[busy] 11 inspected finished");
    assert!(
        matches!(&finished.thread.entries[..], [Entry::User { text, .. }, Entry::Assistant { .. }] if text == "慢一点回答"),
        "完成后的线程应保留本轮 user + assistant：{:?}",
        finished.thread.entries.len()
    );
    assert!(block_on(runtime.new_thread()).is_ok(), "空闲后允许新建会话");
    eprintln!("[busy] 12 new thread ok");

    // 测试从 Ready 之后就不再消费 host 事件；shutdown 内部会先丢弃事件接收端，
    // 避免 host 线程阻塞在 send 上导致 join 挂死（2026-10-29 的 CI flake）。
    eprintln!("[busy] 13 shutdown");
    host.shutdown();
    eprintln!("[busy] 14 shutdown done");
    std::fs::remove_dir_all(workspace).ok();
}
