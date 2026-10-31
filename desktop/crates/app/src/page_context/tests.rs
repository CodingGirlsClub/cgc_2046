use super::*;

fn scope() -> ConversationScope {
    ConversationScope::new("thread-1", "native")
}

fn course(id: &str) -> PageContext {
    PageContext {
        workspace_id: Some("workspace-1".into()),
        tab_id: format!("issue:{id}:unit-A"),
        route: format!("/courses/{id}/learn"),
        title: "Rust".into(),
        version: "3".into(),
        body: PageBody::Loading,
        course: Some(CourseContext {
            id: id.into(),
            title: "Rust".into(),
            revision: Some(3),
            unit: Some(PageUnit {
                id: "unit-A".into(),
                title: "Ownership".into(),
            }),
        }),
    }
}

#[test]
fn queued_prompt_keeps_the_context_at_submission() {
    let state = PageContextState::default();
    state.set_current(Some(course("course-A")));
    let (queued, frozen) = state.freeze(scope(), "explain ownership".into());
    state.set_current(Some(course("course-B")));

    assert!(queued.contains("course-A"));
    assert!(!queued.contains("course-B"));
    assert!(state.freeze(scope(), "next".into()).0.contains("course-B"));
    assert_eq!(frozen.unwrap().page.course.unwrap().id, "course-A");
}

#[test]
fn independent_controllers_do_not_share_context_or_dismissal() {
    let first = PageContextState::default();
    let second = PageContextState::default();
    first.set_current(Some(course("course-A")));
    second.set_current(Some(course("course-B")));
    first.dismiss();
    assert_eq!(
        first.freeze(scope(), "question".into()),
        ("question".into(), None)
    );
    assert!(second
        .freeze(scope(), "question".into())
        .0
        .contains("course-B"));

    let reopened_window = first.clone();
    reopened_window.reset_dismissed();
    assert!(
        first
            .freeze(scope(), "question".into())
            .0
            .contains("course-A"),
        "windows explicitly sharing the same root retain its context"
    );
    second.dismiss();
    assert!(first.visible().is_some());
}

#[test]
fn changing_page_removes_stale_unit_context_and_resets_dismissal() {
    let state = PageContextState::default();
    state.set_current(Some(course("course-A")));
    state.dismiss();
    let mut next = course("course-B");
    next.tab_id = "page:/courses/course-B/learn".into();
    next.version = "unversioned".into();
    next.course.as_mut().unwrap().unit = None;
    next.course.as_mut().unwrap().revision = None;
    state.set_current(Some(next));

    let (prompt, snapshot) = state.freeze(scope(), "next exercise".into());
    assert!(prompt.contains("course-B"));
    assert!(!prompt.contains("unit-A"));
    assert_eq!(snapshot.unwrap().page.course.unwrap().unit, None);
    assert!(prompt.ends_with("next exercise"));
}

#[test]
fn same_tab_version_loads_body_only_once_per_thread_and_agent() {
    let state = PageContextState::default();
    state.set_current(Some(PageContext {
        workspace_id: Some("workspace-1".into()),
        tab_id: "tab-event-1".into(),
        route: "/events/event-1".into(),
        title: "Reading Rust".into(),
        version: "v1".into(),
        body: PageBody::Ready("complete event body".into()),
        course: None,
    }));
    let scope = ConversationScope::new("thread-1", "acp");

    let (first, snapshot) = state.freeze(scope.clone(), "first question".into());
    assert!(first.contains("complete event body"));
    state.mark_sent(&scope, &snapshot);

    let (second, _) = state.freeze(scope, "follow up".into());
    assert!(second.ends_with("follow up"));
    assert!(second.contains("route=/events/event-1"));
    assert!(!second.contains("complete event body"));
}

#[test]
fn chip_distinguishes_ready_loaded_and_needs_reload() {
    let state = PageContextState::default();
    let mut context = PageContext {
        workspace_id: Some("workspace-1".into()),
        tab_id: "tab-event-1".into(),
        route: "/events/event-1".into(),
        title: "Reading Rust".into(),
        version: "v1".into(),
        body: PageBody::Ready("version one".into()),
        course: None,
    };
    let scope = ConversationScope::new("thread-1", "native");
    state.set_current(Some(context.clone()));
    assert_eq!(state.chip_state(&scope), Some(PageLoadState::Ready));

    let (_, snapshot) = state.freeze(scope.clone(), "first".into());
    state.mark_sent(&scope, &snapshot);
    assert_eq!(state.chip_state(&scope), Some(PageLoadState::Loaded));

    context.version = "v2".into();
    context.body = PageBody::Ready("version two".into());
    state.set_current(Some(context));
    assert_eq!(state.chip_state(&scope), Some(PageLoadState::NeedsReload));
}

#[test]
fn invalidating_before_any_load_keeps_the_chip_ready() {
    let state = PageContextState::default();
    state.set_current(Some(PageContext {
        workspace_id: Some("workspace-1".into()),
        tab_id: "tab-event-1".into(),
        route: "/events/event-1".into(),
        title: "Reading Rust".into(),
        version: "v1".into(),
        body: PageBody::Ready("event body".into()),
        course: None,
    }));
    let scope = ConversationScope::new("thread-1", "native");

    state.invalidate_loaded(&scope);
    assert_eq!(state.chip_state(&scope), Some(PageLoadState::Ready));
}

#[test]
fn invalidated_history_requires_one_reload_then_returns_to_loaded() {
    let state = PageContextState::default();
    state.set_current(Some(PageContext {
        workspace_id: Some("workspace-1".into()),
        tab_id: "tab-event-1".into(),
        route: "/events/event-1".into(),
        title: "Reading Rust".into(),
        version: "v1".into(),
        body: PageBody::Ready("event body".into()),
        course: None,
    }));
    let scope = ConversationScope::new("thread-1", "native");

    let (_, snapshot) = state.freeze(scope.clone(), "first".into());
    state.mark_sent(&scope, &snapshot);
    assert_eq!(state.chip_state(&scope), Some(PageLoadState::Loaded));

    state.invalidate_loaded(&scope);
    assert_eq!(state.chip_state(&scope), Some(PageLoadState::NeedsReload));

    let (reloaded, snapshot) = state.freeze(scope.clone(), "again".into());
    assert!(reloaded.contains("event body"));
    state.mark_sent(&scope, &snapshot);
    assert_eq!(state.chip_state(&scope), Some(PageLoadState::Loaded));
}

#[test]
fn over_budget_body_is_truncated_and_marked_partial() {
    let full_body = "abcdefghijklmnopqrstuvwxyz0123456789".repeat(4);
    let state = PageContextState::default();
    state.set_current(Some(PageContext {
        workspace_id: Some("workspace-1".into()),
        tab_id: "tab-long".into(),
        route: "/events/long".into(),
        title: "Long page".into(),
        version: "v1".into(),
        body: PageBody::Ready(full_body.clone().into()),
        course: None,
    }));
    let scope = ConversationScope::with_body_budget("thread-1", "acp", 24);

    let (prompt, snapshot) = state.freeze(scope.clone(), "summarize".into());
    assert!(prompt.contains("Page body truncated"));
    assert!(!prompt.contains(&full_body));
    state.mark_sent(&scope, &snapshot);
    assert_eq!(state.chip_state(&scope), Some(PageLoadState::Partial));

    let (follow_up, _) = state.freeze(scope, "follow up".into());
    assert!(follow_up.ends_with("follow up"));
    assert!(!follow_up.contains("<active_tab_body>"));
}

#[test]
fn invalidation_between_freeze_and_send_cannot_claim_body_is_loaded() {
    for agent in ["native", "codex", "claude"] {
        let state = PageContextState::default();
        let scope = ConversationScope::new("session-1", agent);
        let mut page = course("course-A");
        page.body = PageBody::Ready("course task body".into());
        state.set_current(Some(page));
        let (_, first) = state.freeze(scope.clone(), "first".into());
        state.mark_sent(&scope, &first);
        let (_, queued) = state.freeze(scope.clone(), "edited first message".into());
        state.invalidate_loaded(&scope);
        state.mark_sent(&scope, &queued);
        assert_eq!(state.chip_state(&scope), Some(PageLoadState::NeedsReload));
        assert!(state
            .freeze(scope, "next".into())
            .0
            .contains("course task body"));
    }
}

#[test]
fn follow_up_keeps_current_page_identity_when_body_is_deduplicated() {
    let state = PageContextState::default();
    let mut page = course("course-A");
    page.body = PageBody::Ready("course task body".into());
    state.set_current(Some(page));
    let (_, first) = state.freeze(scope(), "first".into());
    state.mark_sent(&scope(), &first);
    let (follow_up, _) = state.freeze(scope(), "what is the task?".into());
    assert!(follow_up.contains("course_id=course-A"));
    assert!(follow_up.contains("unit_id=unit-A"));
    assert!(!follow_up.contains("course task body"));
}

#[test]
fn history_invalidation_is_isolated_between_native_and_external_sessions() {
    let state = PageContextState::default();
    let mut page = course("course-A");
    page.body = PageBody::Ready("course task body".into());
    state.set_current(Some(page));
    let scopes = [
        scope(),
        ConversationScope::new("session-1", "codex"),
        ConversationScope::new("session-1", "claude"),
    ];
    for scope in &scopes {
        let (_, frozen) = state.freeze(scope.clone(), "first".into());
        state.mark_sent(scope, &frozen);
    }
    state.invalidate_loaded(&scopes[1]);
    assert_eq!(state.chip_state(&scopes[0]), Some(PageLoadState::Loaded));
    assert_eq!(
        state.chip_state(&scopes[1]),
        Some(PageLoadState::NeedsReload)
    );
    assert_eq!(state.chip_state(&scopes[2]), Some(PageLoadState::Loaded));
    assert_eq!(
        state.chip_state(&ConversationScope::new("new-thread", "native")),
        Some(PageLoadState::Ready)
    );
}

#[test]
fn queued_and_retried_messages_reload_the_original_page_after_history_changes() {
    let state = PageContextState::default();
    let mut page = course("course-A");
    page.body = PageBody::Ready("original course task body".into());
    state.set_current(Some(page));
    let (first_prompt, first) = state.freeze(scope(), "first".into());
    state.mark_sent(&scope(), &first);
    let (queued_prompt, queued) = state.freeze(scope(), "queued".into());
    state.set_current(Some(course("course-B")));
    state.invalidate_loaded(&scope());
    // 包含正文的旧回执同样不能跨历史世代反写。
    state.mark_sent(&scope(), &first);
    let (retried_prompt, retried) = state.refresh(scope(), first_prompt, first);
    assert!(retried_prompt.contains("original course task body"));
    assert!(!retried_prompt.contains("course-B"));
    let (refreshed, sent) = state.refresh(scope(), queued_prompt, queued);
    assert!(refreshed.contains("course_id=course-A"));
    assert!(refreshed.contains("original course task body"));
    assert!(refreshed.ends_with("queued"));
    state.mark_sent(&scope(), &sent);
    let (deduplicated, _) = state.refresh(scope(), retried_prompt, retried);
    assert!(!deduplicated.contains("<active_tab_body>"));
}

#[test]
fn stale_full_receipt_cannot_replace_a_newer_successful_load() {
    let state = PageContextState::default();
    let mut page = course("course-A");
    page.body = PageBody::Ready("course task body".into());
    state.set_current(Some(page));
    let (_, old) = state.freeze(scope(), "old".into());
    state.mark_sent(&scope(), &old);
    state.invalidate_loaded(&scope());
    let (_, current) = state.freeze(scope(), "current".into());
    state.mark_sent(&scope(), &current);
    state.mark_sent(&scope(), &old);
    assert_eq!(state.chip_state(&scope()), Some(PageLoadState::Loaded));
    let other = ConversationScope::new("other-session", "codex");
    state.invalidate_loaded(&other);
    state.mark_sent(&other, &current);
    assert_eq!(state.chip_state(&other), Some(PageLoadState::Ready));
}

#[test]
fn identity_only_submission_cannot_mark_a_later_ready_body_loaded() {
    let state = PageContextState::default();
    let mut page = course("course-A");
    state.set_current(Some(page.clone()));
    let (_, loading) = state.freeze(scope(), "while loading".into());
    page.body = PageBody::Ready("course task body".into());
    state.set_current(Some(page));
    state.mark_sent(&scope(), &loading);
    assert_eq!(state.chip_state(&scope()), Some(PageLoadState::Ready));
}

#[test]
fn workspace_changes_require_their_own_body_even_for_the_same_tab_version() {
    let state = PageContextState::default();
    let mut page = course("course-A");
    page.body = PageBody::Ready("workspace A course task".into());
    state.set_current(Some(page.clone()));
    let (_, original) = state.freeze(scope(), "first".into());
    state.mark_sent(&scope(), &original);
    page.workspace_id = Some("workspace-2".into());
    page.body = PageBody::Ready("workspace B course task".into());
    state.set_current(Some(page));
    let (prompt, _) = state.freeze(scope(), "next".into());
    assert!(prompt.contains("workspace_id=workspace-2"));
    assert!(prompt.contains("workspace B course task"));
}

#[test]
fn uncertain_history_events_reload_only_the_affected_conversation() {
    use cgc_platform::acp::connection::HostEvent;
    for event in [
        HostEvent::Error {
            message: "send failed".into(),
        },
        HostEvent::Exited,
        HostEvent::TurnEnd {
            cancelled: true,
            stop_reason: "Cancelled".into(),
        },
        HostEvent::CompactionUpdated {
            status: "completed".into(),
            summary: Some("history compacted".into()),
        },
    ] {
        let state = PageContextState::default();
        let mut page = course("course-A");
        page.body = PageBody::Ready("course task body".into());
        state.set_current(Some(page));
        let native = scope();
        let external = ConversationScope::new("session-1", "codex");
        for scope in [&native, &external] {
            let (_, frozen) = state.freeze(scope.clone(), "first".into());
            state.mark_sent(scope, &frozen);
        }
        state.observe_event(&external, &event);
        assert_eq!(state.chip_state(&native), Some(PageLoadState::Loaded));
        assert_eq!(
            state.chip_state(&external),
            Some(PageLoadState::NeedsReload)
        );
        assert!(state
            .freeze(external, "again".into())
            .0
            .contains("course task body"));
    }
}

#[test]
fn ready_state_label_describes_loaded_into_composer_without_ambiguity() {
    assert_eq!(page_load_state_label(Some(PageLoadState::Ready)), "已就绪");
}
