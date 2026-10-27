//! 连续多轮审批回归（Phase A 真机 bug 回归）：
//! 每一轮都通过真实 `Agent` 走进程内 ACP → request_permission → 回传。
//! 断言每轮都产生 HostEvent::PermissionRequested（可渲染），回传后回合正常
//! TurnEnd（不出现 turn timeout / Error），且 Agent 每轮交回。
//!
//! 覆盖真实 provider 行为的一种极端：两轮复用同一个 tool_call_id（部分 provider
//! 会这样），确保上一轮的工具收尾事件不会污染下一轮审批。

use std::sync::Arc;
use std::time::{Duration, Instant};

use cgc_agent_core::{Agent, SelectedModel, Thread};
use cgc_agent_host::{NativeAcpServer, NativeAcpServerConfig};
use cgc_agent_provider::{
    CompletionEvent, FakeProvider, Model, ModelId, ModelLimits, ProviderId, StopReason, ToolUse,
};
use cgc_agent_tools::{ToolContext, ToolRegistry};
use cgc_desktop_app::agent_ingest::apply_permission_resolved;
use cgc_desktop_app::native_agent_view::NativeThreadState;
use cgc_desktop_app::native_runtime::{NativeRuntimeConfig, NativeRuntimeHandle};
use cgc_platform::acp::connection::{AcpHost, AcpHostConfig, HostEvent};

fn model() -> Model {
    Model::new(
        ProviderId::new("fake"),
        "Fake",
        "m1",
        "m1",
        ModelLimits::new(8_000, 1_000),
    )
}

fn temp_workspace(tag: &str) -> std::path::PathBuf {
    let dir =
        std::env::temp_dir().join(format!("cgc-native-approval-{}-{tag}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let _ = std::fs::create_dir_all(&dir);
    dir
}

fn tool_use(id: &str) -> Vec<Result<CompletionEvent, cgc_agent_provider::ProviderError>> {
    vec![
        Ok(CompletionEvent::ToolUse(ToolUse {
            id: id.to_string(),
            name: "run_command".to_string(),
            args: serde_json::json!({"command": "echo hi"}),
        })),
        Ok(CompletionEvent::Stop(StopReason::ToolUse)),
    ]
}

fn final_text(text: &str) -> Vec<Result<CompletionEvent, cgc_agent_provider::ProviderError>> {
    vec![
        Ok(CompletionEvent::Text(text.to_string())),
        Ok(CompletionEvent::Stop(StopReason::EndTurn)),
    ]
}

struct Harness {
    host: AcpHost,
    runtime: NativeRuntimeHandle,
    config: NativeRuntimeConfig,
    /// 与 native 面板同一条状态机：HostEvent → NativeThreadState。
    state: NativeThreadState,
}

fn start_harness(provider: Arc<FakeProvider>, workspace: std::path::PathBuf) -> Harness {
    let runtime = NativeRuntimeHandle::new();
    let agent = Agent::new(
        Thread::new(
            "t1",
            SelectedModel::new(ProviderId::new("fake"), ModelId::new("m1")),
        ),
        None,
    );
    runtime.put_agent(agent);
    let config = NativeRuntimeConfig {
        provider,
        model: model(),
        registry: Arc::new(ToolRegistry::with_builtin_tools()),
        context: ToolContext::new(&workspace)
            .with_sandbox(cgc_agent_tools::SandboxPolicy::new(&workspace)),
        context_size: 8_000,
        auto_approve: false,
    };
    runtime.put_config(config.clone());
    let server =
        NativeAcpServer::new(Box::new(runtime.clone())).with_config(NativeAcpServerConfig {
            agent_name: "cgc-native".to_string(),
            version: "0.0.1".to_string(),
        });
    let host = AcpHost::start_in_process(AcpHostConfig::new("", workspace), server)
        .expect("start in-process host");
    Harness {
        host,
        runtime,
        config,
        state: NativeThreadState::new(),
    }
}

/// 跑一轮：等 PermissionRequested → 回传 allow_once → 等 TurnEnd。
/// 返回本轮收集到的事件；出错（Error/超时）直接 panic。
fn run_turn_with_approval(
    harness: &mut Harness,
    prompt: &str,
    expected_tool_call_id: &str,
) -> Vec<HostEvent> {
    // 每轮开始前把 Agent 放回 runtime（模拟视图在 turn 前交棒）。
    let agent = harness
        .runtime
        .take_agent()
        .expect("agent should be handed back between turns");
    harness.runtime.put_agent(agent);
    harness.runtime.put_config(harness.config.clone());
    assert!(harness.host.prompt(prompt));
    let mut events = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(20);
    let mut permission_requested = false;
    while Instant::now() < deadline {
        let Some(event) = harness.host.recv_timeout(Duration::from_millis(50)) else {
            continue;
        };
        // 镜像 native 面板的批处理：先归约，再同步出可渲染的审批卡。
        harness.state.apply_host_event(&event);
        harness.state.sync_pending_permission();
        let is_permission = matches!(event, HostEvent::PermissionRequested { .. });
        if is_permission {
            let HostEvent::PermissionRequested {
                request_id,
                tool_call_id,
                ..
            } = &event
            else {
                unreachable!()
            };
            assert_eq!(
                tool_call_id.as_deref(),
                Some(expected_tool_call_id),
                "permission must belong to this turn's tool call"
            );
            // 关键断言：本轮的审批卡必须真实存在（UI 能渲染、能点击）。
            assert!(
                harness.state.pending_permission.is_some(),
                "本轮审批必须能渲染出审批卡（真机 bug 2 回归）: {request_id}"
            );
            // 模拟跨回合/乱序的旧 tool_call_update（复用同一个 tool_call_id）：
            // 不得清掉当前 pending。
            harness.state.apply_host_event(&HostEvent::ToolCallUpdated {
                tool_call_id: expected_tool_call_id.to_string(),
                title: None,
                status: Some("completed".to_string()),
                output: Some("stale-from-previous-turn".to_string()),
            });
            assert!(
                harness.state.pending_permission.is_some(),
                "乱序 tool_call_update 不得清掉待审批卡（真机 bug 2 回归）"
            );
            // 回传决定 + 落行，等价于 UI 点「允许一次」。
            assert!(harness.state.resolve_permission(request_id).is_some());
            apply_permission_resolved(&mut harness.state.thread, request_id.clone(), true);
            assert!(
                harness
                    .host
                    .respond_permission_option(request_id, "allow_once"),
                "permission request must be pending (renderable) when UI answers"
            );
            assert!(harness.state.pending_permission.is_none());
            permission_requested = true;
        }
        let is_error = matches!(event, HostEvent::Error { .. });
        let turn_end = matches!(event, HostEvent::TurnEnd { .. });
        events.push(event);
        if is_error {
            panic!("turn must not fail (turn timeout regression): {events:?}");
        }
        if turn_end {
            break;
        }
    }
    assert!(
        permission_requested,
        "turn must surface a renderable permission request: {events:?}"
    );
    assert!(
        matches!(events.last(), Some(HostEvent::TurnEnd { .. })),
        "turn must end with TurnEnd: {events:?}"
    );
    events
}

#[test]
fn two_consecutive_turns_each_request_approval_and_end_without_timeout() {
    let workspace = temp_workspace("two-turns");
    let provider = Arc::new(FakeProvider::new(
        ProviderId::new("fake"),
        "Fake",
        vec![model()],
    ));
    // 第 1 轮：工具调用（call-1）→ 审批 → 工具结果 → 收尾文本。
    provider.push_script(tool_use("call-1"));
    provider.push_script(final_text("done-1"));
    // 第 2 轮：**故意复用同一个 tool_call_id**（真机 provider 可能这样做）。
    provider.push_script(tool_use("call-1"));
    provider.push_script(final_text("done-2"));
    let mut harness = start_harness(Arc::clone(&provider), workspace);

    // Ready
    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline {
        if let Some(event) = harness.host.recv_timeout(Duration::from_millis(50)) {
            if matches!(event, HostEvent::Ready { .. }) {
                break;
            }
        }
    }

    let first = run_turn_with_approval(&mut harness, "first", "call-1");
    assert!(first
        .iter()
        .any(|event| matches!(event, HostEvent::ToolCallUpdated { status: Some(status), .. } if status == "completed")));
    let second = run_turn_with_approval(&mut harness, "second", "call-1");
    assert!(second
        .iter()
        .any(|event| matches!(event, HostEvent::ToolCallUpdated { status: Some(status), .. } if status == "completed")));

    // 两轮都留痕且都已解决；pending 不残留。
    let permission_rows = harness
        .state
        .thread
        .entries
        .iter()
        .filter(|entry| {
            matches!(
                entry,
                cgc_agent_ui::conversation::Entry::Permission {
                    resolved: Some(true),
                    ..
                }
            )
        })
        .count();
    assert_eq!(permission_rows, 2, "两轮审批都应标记为已允许");
    assert!(harness.state.pending_permission.is_none());

    // 两轮都结束后 Agent 必须交回（可继续第三轮/持久化）。
    assert!(harness.runtime.take_agent().is_some());
    harness.host.shutdown();
}
