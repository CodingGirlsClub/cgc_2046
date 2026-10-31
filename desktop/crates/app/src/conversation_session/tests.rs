use super::*;
use cgc_agent_ui::conversation::{Entry, ThreadEvent};

fn ready() -> ConversationSession {
    let mut session = ConversationSession::native();
    session.ingest(
        0,
        &HostEvent::Ready {
            agent_name: "native".into(),
            version: "test".into(),
            session_id: "s".into(),
        },
    );
    session
}

#[test]
fn external_acp_sends_page_identity_each_turn_and_reloads_after_compaction() {
    use crate::page_context::{
        ConversationScope, PageBody, PageContext, PageContextState, PageLoadState,
    };
    use agent_client_protocol::schema::v1::{
        AgentCapabilities, CompactionStatus, CompactionUpdate, ContentBlock, InitializeRequest,
        InitializeResponse, NewSessionRequest, NewSessionResponse, PromptRequest, PromptResponse,
        SessionId, SessionNotification, SessionUpdate, StopReason,
    };
    use agent_client_protocol::{on_receive_request, Agent};
    use cgc_platform::acp::connection::AcpHostConfig;
    use std::{
        sync::{Arc, Mutex},
        time::{Duration, Instant},
    };

    let received = Arc::new(Mutex::new(Vec::<String>::new()));
    let captured = received.clone();
    let compact_next = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let compact_for_handler = compact_next.clone();
    let state = PageContextState::default();
    let scope = ConversationScope::new("external-session", "codex");
    let server = Agent
        .builder()
        .on_receive_request(
            async |_: InitializeRequest, responder, _| {
                responder.respond(
                    InitializeResponse::new(1u16.into())
                        .agent_capabilities(AgentCapabilities::new()),
                )
            },
            on_receive_request!(),
        )
        .on_receive_request(
            async |_: NewSessionRequest, responder, _| {
                responder.respond(NewSessionResponse::new("external-session"))
            },
            on_receive_request!(),
        )
        .on_receive_request(
            async move |request: PromptRequest, responder, cx| {
                let text = request
                    .prompt
                    .iter()
                    .filter_map(|block| match block {
                        ContentBlock::Text(text) => Some(text.text.as_str()),
                        _ => None,
                    })
                    .collect::<Vec<_>>()
                    .join("\n");
                captured.lock().unwrap().push(text);
                if compact_for_handler.swap(false, std::sync::atomic::Ordering::SeqCst) {
                    cx.send_notification(SessionNotification::new(
                        SessionId::new("external-session"),
                        SessionUpdate::CompactionUpdate(CompactionUpdate::new(
                            "compaction-1",
                            CompactionStatus::Completed,
                        )),
                    ))?;
                }
                responder.respond(PromptResponse::new(StopReason::EndTurn))
            },
            on_receive_request!(),
        );
    let host =
        AcpHost::start_in_process(AcpHostConfig::new("", std::env::temp_dir()), server).unwrap();
    let mut session = ConversationSession::default();
    let generation = session.attach(host);
    let drain_until_ready = |session: &mut ConversationSession| {
        let deadline = Instant::now() + Duration::from_secs(5);
        while !session.can_submit() {
            assert!(
                Instant::now() < deadline,
                "external ACP did not become ready"
            );
            if let Some(event) = session
                .host
                .as_ref()
                .unwrap()
                .recv_timeout(Duration::from_millis(20))
            {
                if session.ingest_external(generation, &event) {
                    state.observe_event(&scope, &event);
                }
            }
        }
    };
    drain_until_ready(&mut session);
    state.set_current(Some(PageContext {
        workspace_id: Some("workspace-1".into()),
        tab_id: "course-tab".into(),
        route: "/courses/course-1/learn".into(),
        title: "Course task".into(),
        version: "v1".into(),
        body: PageBody::Ready("complete course task body".into()),
        course: None,
    }));
    let mut send = |text: &str| {
        let (prompt, context) = state.freeze(scope.clone(), text.into());
        let mut submission = session.submission(text.into(), prompt, context, Vec::new(), false);
        assert!(session.send_with_context(&mut submission, &state, &scope));
        drain_until_ready(&mut session);
    };
    send("first");
    compact_next.store(true, std::sync::atomic::Ordering::SeqCst);
    send("follow up");
    assert_eq!(state.chip_state(&scope), Some(PageLoadState::NeedsReload));
    send("after compaction");
    let mut replay = cgc_agent_ui::conversation::ConversationThread::default();
    replay.apply(ThreadEvent::TurnStarted {
        user_text: "restored question".into(),
    });
    replay.apply(ThreadEvent::TextDelta("restored answer".into()));
    session.restore_thread(replay);
    state.invalidate_loaded(&scope);
    let (prompt, context) = state.freeze(scope.clone(), "after restore".into());
    let mut submission =
        session.submission("after restore".into(), prompt, context, Vec::new(), false);
    assert!(session.send_with_context(&mut submission, &state, &scope));
    drain_until_ready(&mut session);
    let prompts = received.lock().unwrap();
    assert_eq!(prompts.len(), 4);
    for prompt in prompts.iter() {
        assert!(prompt.contains("route=/courses/course-1/learn"));
        assert!(prompt.contains("workspace_id=workspace-1"));
    }
    assert!(prompts[0].contains("complete course task body"));
    assert!(!prompts[1].contains("<active_tab_body>"));
    assert!(prompts[2].contains("complete course task body"));
    assert!(prompts[3].contains("complete course task body"));
    assert_eq!(state.chip_state(&scope), Some(PageLoadState::Loaded));
    session.host.take().unwrap().shutdown();
}

#[test]
fn native_rewind_resubmits_course_body_to_provider_and_keeps_one_user_entry() {
    use crate::{
        native_runtime::{NativeRuntimeConfig, NativeRuntimeHandle, PreparedNativeTurn},
        page_context::{
            ConversationScope, CourseContext, PageBody, PageContext, PageContextState,
            PageLoadState,
        },
    };
    use cgc_agent_core::{Entry as NativeEntry, SelectedModel, Thread};
    use cgc_agent_host::NativeAcpServer;
    use cgc_agent_provider::{FakeProvider, Model, ModelId, ModelLimits, ProviderId};
    use cgc_agent_tools::{ToolContext, ToolRegistry};
    use cgc_platform::acp::connection::AcpHostConfig;
    use futures::executor::block_on;
    use std::{
        sync::Arc,
        time::{Duration, Instant},
    };

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
    let mut thread = Thread::new(
        "native-context-test",
        SelectedModel::new(ProviderId::new("fake"), ModelId::new("m1")),
    );
    thread.title = Some("Existing title".into());
    let runtime = NativeRuntimeHandle::spawn(
        thread,
        None,
        NativeRuntimeConfig {
            provider: provider.clone(),
            model,
            registry: Arc::new(ToolRegistry::new()),
            context: ToolContext::new(std::env::temp_dir()),
            context_size: 8_000,
            auto_approve: true,
        },
        None,
    );
    let state = PageContextState::default();
    let scope = ConversationScope::new("native-context-test", "native");
    state.set_current(Some(PageContext {
        workspace_id: Some("workspace-1".into()),
        tab_id: "course-tab".into(),
        route: "/courses/course-1/learn".into(),
        title: "Course".into(),
        version: "v1".into(),
        body: PageBody::Ready("complete course task body".into()),
        course: Some(CourseContext {
            id: "course-1".into(),
            title: "Course".into(),
            revision: Some(1),
            unit: None,
        }),
    }));
    let mut session = ConversationSession::native();
    let attach = |session: &mut ConversationSession| {
        let connection = block_on(runtime.connect()).unwrap();
        let host = AcpHost::start_in_process(
            AcpHostConfig::new("", std::env::temp_dir()),
            NativeAcpServer::new(Box::new(connection)),
        )
        .unwrap();
        let generation = session.attach(host);
        let deadline = Instant::now() + Duration::from_secs(5);
        while !session.can_submit() {
            assert!(
                Instant::now() < deadline,
                "native connection did not become ready"
            );
            if let Some(event) = session
                .host
                .as_ref()
                .unwrap()
                .recv_timeout(Duration::from_millis(20))
            {
                session.ingest(generation, &event);
            }
        }
    };
    let send = |session: &mut ConversationSession, text: &str| {
        let (prompt, context) = state.freeze(scope.clone(), text.into());
        let mut submission = session.submission(text.into(), prompt, context, Vec::new(), false);
        let snapshot = block_on(runtime.inspect()).unwrap();
        block_on(runtime.prepare(PreparedNativeTurn {
            thread_id: snapshot.thread.id.clone(),
            generation: snapshot.generation,
            display: text.into(),
            images: Vec::new(),
            retry: false,
        }))
        .unwrap();
        assert!(session.send_with_context(&mut submission, &state, &scope));
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            assert!(Instant::now() < deadline, "native turn did not end");
            if let Some(event) = session
                .host
                .as_ref()
                .unwrap()
                .recv_timeout(Duration::from_millis(20))
            {
                session.ingest(session.generation, &event);
                state.observe_event(&scope, &event);
                if matches!(event, HostEvent::TurnEnd { .. }) {
                    break;
                }
            }
        }
    };
    attach(&mut session);
    send(&mut session, "what is the task?");
    assert_eq!(state.chip_state(&scope), Some(PageLoadState::Loaded));
    block_on(runtime.rewind_thread("native-context-test".into(), 1, false)).unwrap();
    state.invalidate_loaded(&scope);
    attach(&mut session);
    send(&mut session, "explain the task again");
    let requests = provider.requests();
    assert_eq!(requests.len(), 2);
    for request in &requests {
        assert!(request
            .messages
            .iter()
            .any(|message| message.text().contains("course_id=course-1")
                && message.text().contains("complete course task body")));
    }
    let snapshot = block_on(runtime.inspect()).unwrap();
    assert_eq!(
        snapshot
            .thread
            .entries
            .iter()
            .filter(|entry| matches!(entry, NativeEntry::User { .. }))
            .count(),
        1
    );
    assert!(
        matches!(&snapshot.thread.entries[0], NativeEntry::User { text, .. } if text.contains("complete course task body"))
    );
    session.host.take().unwrap().shutdown();
}

#[test]
fn replaced_generation_cannot_change_content_title_or_release_queue() {
    let mut session = ready();
    let current = session.submission("current".into(), "current".into(), None, Vec::new(), false);
    session.accepted(current);
    session.generation += 1;
    let next = session.submission("next".into(), "next".into(), None, Vec::new(), false);
    session.queue.push(next);
    for event in [
        HostEvent::Delta("stale".into()),
        HostEvent::TitleUpdated {
            title: Some("stale".into()),
        },
        HostEvent::TurnEnd {
            cancelled: false,
            stop_reason: "EndTurn".into(),
        },
    ] {
        assert!(!session.ingest(0, &event));
    }
    session.mark_ready_for_next(0);
    assert!(session.next_queued().is_none());
    assert_eq!(
        session.thread.entries,
        vec![Entry::User {
            text: "current".into()
        }]
    );
    assert!(session.thread.title.is_none());
}

#[test]
fn stop_preserves_queue_and_terminal_does_not_grant_resource_readiness() {
    let mut session = ready();
    let first = session.submission("first".into(), "first".into(), None, Vec::new(), false);
    session.accepted(first);
    let next = session.submission("next".into(), "next".into(), None, Vec::new(), false);
    session.queue.push(next);
    session.stop();
    session.ingest(
        0,
        &HostEvent::TurnEnd {
            cancelled: true,
            stop_reason: "Cancelled".into(),
        },
    );
    session.ingest(
        0,
        &HostEvent::TurnEnd {
            cancelled: true,
            stop_reason: "Cancelled".into(),
        },
    );
    assert_eq!(session.queue[0].display, "next");
    session.queue_mode = QueueMode::Auto;
    assert!(session.next_queued().is_none());
    session.mark_ready_for_next(0);
    assert_eq!(session.next_queued().unwrap().display, "next");
    assert!(session.next_queued().is_none());
}

#[test]
fn unrelated_tool_completion_cannot_resolve_new_permission() {
    let mut session = ready();
    session.thread.apply(ThreadEvent::PermissionRequested {
        request_id: "current".into(),
        title: "run".into(),
        tool: Some("run_command".into()),
        tool_call_id: Some("new-call".into()),
        args: None,
        options: Vec::new(),
    });
    session.ingest(
        0,
        &HostEvent::ToolCallUpdated {
            tool_call_id: "previous-call".into(),
            title: None,
            status: Some("completed".into()),
            output: Some("old".into()),
        },
    );
    assert_eq!(
        session
            .thread
            .pending_permission
            .as_ref()
            .unwrap()
            .request_id,
        "current"
    );
}

#[test]
fn late_deltas_after_terminal_do_not_revive_streaming() {
    let mut session = ready();
    let first = session.submission("q".into(), "q".into(), None, Vec::new(), false);
    session.accepted(first);
    session.ingest(0, &HostEvent::Delta("回答".into()));
    session.ingest(
        0,
        &HostEvent::TurnEnd {
            cancelled: false,
            stop_reason: "EndTurn".into(),
        },
    );
    assert!(!session.is_busy(), "终态后不再是生成中");

    // 迟到的流式事件：不得重新拉起生成态，也不得写入内容。
    let before = session.thread.entries.clone();
    assert!(!session.ingest(0, &HostEvent::Delta("迟到".into())));
    assert!(!session.ingest(
        0,
        &HostEvent::UsageUpdated {
            used: 999,
            size: 1_000,
            cost: None,
        }
    ));
    assert!(!session.is_busy(), "迟到事件不得复活生成态");
    assert_eq!(session.thread.entries, before, "迟到内容不得写入");

    // 新的提交重新开启一轮，之后的增量正常归约。
    let next = session.submission("q2".into(), "q2".into(), None, Vec::new(), false);
    session.accepted(next);
    assert!(session.ingest(0, &HostEvent::Delta("新一轮".into())));
    assert!(session.is_busy());
}

/// 重复终态不得把队列发两次：Zed 用 AbsorbingCancel 做同样的事，我们用
/// 「终态只认一次 + 队列放行只认 owner 就绪」达到同一效果。
#[test]
fn duplicate_terminal_events_never_release_the_queue_twice() {
    let mut session = ready();
    let first = session.submission("q1".into(), "q1".into(), None, Vec::new(), false);
    session.accepted(first);
    let queued = session.submission("q2".into(), "q2".into(), None, Vec::new(), false);
    session.queue.push(queued);
    session.queue_mode = QueueMode::Auto;

    // 取消产生的终态可能重复到达（客户端合成 + agent 回传）。
    let cancelled = HostEvent::TurnEnd {
        cancelled: true,
        stop_reason: "cancelled".into(),
    };
    session.ingest(0, &cancelled);
    assert!(session.next_queued().is_none(), "终态本身不放行队列");
    session.ingest(0, &cancelled);
    assert!(session.next_queued().is_none(), "重复终态同样不放行");
    assert_eq!(session.queue.len(), 1, "队列不得被消费两次");

    // 只有 owner 的 Idle 证据才放行，且只放行一次。
    session.mark_ready_for_next(0);
    assert_eq!(session.next_queued().map(|q| q.display), Some("q2".into()));
    assert!(session.next_queued().is_none());
    assert!(session.queue.is_empty());
}
