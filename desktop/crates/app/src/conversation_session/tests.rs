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
