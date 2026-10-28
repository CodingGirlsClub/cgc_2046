//! Two real tool turns over ACP, including reused tool ids and late tool updates.
use cgc_agent_core::{SelectedModel, Thread};
use cgc_agent_host::NativeAcpServer;
use cgc_agent_provider::{
    CompletionEvent, FakeProvider, Model, ModelLimits, ProviderId, StopReason, ToolUse,
};
use cgc_agent_tools::{SandboxPolicy, ToolContext, ToolRegistry};
use cgc_desktop_app::{
    native_agent_view::NativeThreadState,
    native_runtime::{NativeRuntimeConfig, NativeRuntimeHandle},
};
use cgc_platform::acp::connection::{AcpHost, AcpHostConfig, HostEvent};
use futures::executor::block_on;
use std::{sync::Arc, time::Duration};

fn wait_title(runtime: &NativeRuntimeHandle, expected: &str) {
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    loop {
        let snapshot = block_on(runtime.inspect()).unwrap();
        if snapshot.display_title.as_deref() == Some(expected) {
            return;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "title never generated: {:?}",
            snapshot.display_title
        );
        std::thread::sleep(Duration::from_millis(20));
    }
}

#[test]
fn two_consecutive_turns_each_request_approval_and_end_without_timeout() {
    let workspace =
        std::env::temp_dir().join(format!("cgc-native-approval-{}", std::process::id()));
    std::fs::create_dir_all(&workspace).unwrap();
    let model = Model::new(
        ProviderId::new("fake"),
        "Fake",
        "m1",
        "m1",
        ModelLimits::new(8_000, 1_000),
    );
    let provider = Arc::new(FakeProvider::new(
        ProviderId::new("fake"),
        "Fake",
        vec![model.clone()],
    ));
    let tool_round = || {
        vec![
            Ok(CompletionEvent::ToolUse(ToolUse {
                id: "reused-id".into(),
                name: "run_command".into(),
                args: serde_json::json!({"command":"echo hi"}),
            })),
            Ok(CompletionEvent::Stop(StopReason::ToolUse)),
        ]
    };
    let answer_round = |text: &str| {
        vec![
            Ok(CompletionEvent::Text(text.into())),
            Ok(CompletionEvent::Stop(StopReason::EndTurn)),
        ]
    };
    provider.push_script(tool_round());
    provider.push_script(answer_round("first finished"));
    // 首次成功 turn 收尾会多一次标题生成 stream（标题已存在后不再触发）。
    provider.push_script(answer_round("首轮标题"));
    provider.push_script(tool_round());
    provider.push_script(answer_round("second finished"));
    let runtime = NativeRuntimeHandle::spawn(
        Thread::new(
            "approval",
            SelectedModel::new(model.provider_id.clone(), model.id.clone()),
        ),
        None,
        NativeRuntimeConfig {
            provider,
            model,
            registry: Arc::new(ToolRegistry::with_builtin_tools()),
            context: ToolContext::new(&workspace).with_sandbox(SandboxPolicy::new(&workspace)),
            context_size: 8_000,
            auto_approve: false,
        },
        None,
    );
    let binding = block_on(runtime.connect()).unwrap();
    let host = AcpHost::start_in_process(
        AcpHostConfig::new("", workspace.clone()),
        NativeAcpServer::new(Box::new(binding)),
    )
    .unwrap();
    let mut state = NativeThreadState::new();
    let generation = state.session.attach(host);
    loop {
        let event = state
            .session
            .host
            .as_ref()
            .unwrap()
            .recv_timeout(Duration::from_secs(10))
            .expect("ready event");
        let ready = matches!(event, HostEvent::Ready { .. });
        state.ingest(generation, &event);
        if ready {
            break;
        }
    }
    for prompt in ["first", "second"] {
        let submission =
            state
                .session
                .submission(prompt.into(), prompt.into(), None, Vec::new(), false);
        assert!(state.session.send(&submission));
        let mut approvals = 0;
        let mut answer = String::new();
        loop {
            let event = state
                .session
                .host
                .as_ref()
                .unwrap()
                .recv_timeout(Duration::from_secs(10))
                .expect("turn event");
            state.ingest(generation, &event);
            match event {
                HostEvent::PermissionRequested { request_id, .. } => {
                    assert_eq!(
                        state
                            .session
                            .thread
                            .pending_permission
                            .as_ref()
                            .unwrap()
                            .request_id,
                        request_id
                    );
                    state.ingest(
                        generation,
                        &HostEvent::ToolCallUpdated {
                            tool_call_id: "reused-id".into(),
                            title: None,
                            status: Some("completed".into()),
                            output: Some("late old result".into()),
                        },
                    );
                    assert_eq!(
                        state
                            .session
                            .thread
                            .pending_permission
                            .as_ref()
                            .unwrap()
                            .request_id,
                        request_id
                    );
                    assert!(state.session.resolve_permission("allow_once"));
                    approvals += 1;
                }
                HostEvent::Delta(text) => answer.push_str(&text),
                HostEvent::Error { message } => panic!("turn error: {message}"),
                HostEvent::TurnEnd { cancelled, .. } => {
                    assert!(!cancelled);
                    break;
                }
                _ => {}
            }
        }
        assert_eq!(approvals, 1);
        assert_eq!(answer, format!("{prompt} finished"));
        assert!(state.session.thread.pending_permission.is_none());
        // 首轮会触发标题生成（独立 stream）；等它落盘再发下一轮，保证脚本顺序确定。
        wait_title(&runtime, "首轮标题");
        state.session.mark_ready_for_next(generation);
    }
    let decisions: Vec<_> = state
        .session
        .thread
        .entries
        .iter()
        .filter_map(|entry| match entry {
            cgc_agent_ui::conversation::Entry::Permission { resolved, .. } => Some(*resolved),
            _ => None,
        })
        .collect();
    assert_eq!(decisions, vec![Some(true), Some(true)]);
    state.session.host.take().unwrap().shutdown();
    std::fs::remove_dir_all(workspace).unwrap();
}
