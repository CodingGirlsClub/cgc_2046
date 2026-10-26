//! app 侧 native runtime 接线的端到端测试（Stage 3.1 Phase A）。
//!
//! 链路：`NativeRuntimeHandle`（app 实现）← `NativeAcpServer`（进程内 ACP agent）
//! ← 内存 Channel ← `AcpHost`（客户端）→ `HostEvent`。验证真实 `Agent` 交给
//! runtime 后，turn 事件确实经 ACP 回到客户端、turn 结束 Agent 被交回视图
//! （线程持久化/checkpoint 依赖它）。

use std::sync::Arc;
use std::time::{Duration, Instant};

use cgc_agent_core::{Agent, SelectedModel, Thread};
use cgc_agent_host::{NativeAcpServer, NativeAcpServerConfig};
use cgc_agent_provider::{
    CompletionEvent, FakeProvider, Model, ModelId, ModelLimits, ProviderId, StopReason,
};
use cgc_agent_tools::{ToolContext, ToolRegistry};
use cgc_desktop_app::native_runtime::{NativeRuntimeConfig, NativeRuntimeHandle};
use cgc_platform::acp::connection::{AcpHost, AcpHostConfig, HostEvent};

fn model(provider: &str) -> Model {
    Model::new(
        ProviderId::new(provider),
        "Fake",
        "m1",
        "m1",
        ModelLimits::new(8_000, 1_000),
    )
}

fn temp_workspace(tag: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("cgc-native-runtime-{}-{tag}", std::process::id()));
    let _ = std::fs::create_dir_all(&dir);
    dir
}

fn start_host(runtime: NativeRuntimeHandle) -> AcpHost {
    let server = NativeAcpServer::new(Box::new(runtime)).with_config(NativeAcpServerConfig {
        agent_name: "cgc-native".to_string(),
        version: "0.0.1".to_string(),
    });
    AcpHost::start_in_process(AcpHostConfig::new("", temp_workspace("host")), server)
        .expect("start in-process host")
}

fn wait_for(
    host: &AcpHost,
    predicate: impl Fn(&HostEvent) -> bool,
    timeout: Duration,
) -> Vec<HostEvent> {
    let mut events = Vec::new();
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if let Some(event) = host.recv_timeout(Duration::from_millis(50)) {
            let matched = predicate(&event);
            events.push(event);
            if matched {
                return events;
            }
        }
    }
    panic!("event not received within {timeout:?}: {events:?}");
}

fn wait_ready(host: &AcpHost) {
    wait_for(
        host,
        |event| matches!(event, HostEvent::Ready { .. }),
        Duration::from_secs(10),
    );
}

#[test]
fn native_runtime_turn_flows_through_acp_and_hands_agent_back() {
    let provider = FakeProvider::new(ProviderId::new("fake"), "Fake", vec![model("fake")]);
    provider.push_script(vec![
        Ok(CompletionEvent::Text("hi".to_string())),
        Ok(CompletionEvent::Stop(StopReason::EndTurn)),
    ]);
    let runtime = NativeRuntimeHandle::new();
    let agent = Agent::new(
        Thread::new(
            "t1",
            SelectedModel::new(ProviderId::new("fake"), ModelId::new("m1")),
        ),
        None,
    );
    runtime.put_agent(agent);
    runtime.put_config(NativeRuntimeConfig {
        provider: Arc::new(provider),
        model: model("fake"),
        registry: Arc::new(ToolRegistry::new()),
        context: ToolContext::new(temp_workspace("turn")),
        context_size: 1_000,
        auto_approve: true,
    });
    let host = start_host(runtime.clone());
    wait_ready(&host);
    assert!(host.prompt("hi"));
    let events = wait_for(
        &host,
        |event| matches!(event, HostEvent::TurnEnd { .. }),
        Duration::from_secs(10),
    );
    assert!(
        events
            .iter()
            .any(|event| matches!(event, HostEvent::Delta(text) if text == "hi")),
        "streamed text must arrive through ACP: {events:?}"
    );
    assert!(events.iter().any(|event| matches!(
        event,
        HostEvent::TurnEnd {
            cancelled: false,
            ..
        }
    )));

    // turn 结束 Agent 必须交回视图（保存线程 / checkpoint / 标题都依赖它）。
    let agent = runtime.take_agent().expect("agent handed back after turn");
    assert_eq!(agent.thread().entries.len(), 2, "user + assistant");
    host.shutdown();
}

#[test]
fn native_runtime_error_surfaces_as_host_error_and_hands_agent_back() {
    let provider = FakeProvider::new(ProviderId::new("fake"), "Fake", vec![model("fake")]);
    let runtime = NativeRuntimeHandle::new();
    let agent = Agent::new(
        Thread::new(
            "t1",
            SelectedModel::new(ProviderId::new("fake"), ModelId::new("m1")),
        ),
        None,
    );
    runtime.put_agent(agent);
    runtime.put_config(NativeRuntimeConfig {
        provider: Arc::new(provider),
        // provider id 与 model provider id 不一致 → Agent::validate 返回 ModelMismatch。
        model: model("other"),
        registry: Arc::new(ToolRegistry::new()),
        context: ToolContext::new(temp_workspace("error")),
        context_size: 1_000,
        auto_approve: true,
    });
    let host = start_host(runtime.clone());
    wait_ready(&host);
    assert!(host.prompt("hi"));
    let events = wait_for(
        &host,
        |event| matches!(event, HostEvent::Error { .. }),
        Duration::from_secs(10),
    );
    assert!(
        events.iter().any(|event| matches!(
            event,
            HostEvent::Error { message } if message.contains("model")
        )),
        "turn error must surface as HostEvent::Error: {events:?}"
    );
    assert!(
        runtime.take_agent().is_some(),
        "agent handed back even when turn fails"
    );
    host.shutdown();
}
