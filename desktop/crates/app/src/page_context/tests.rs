use super::*;

fn scope() -> ConversationScope {
    ConversationScope::new("thread-1", "native")
}

fn course(id: &str) -> PageContext {
    PageContext {
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
    assert_eq!(frozen.unwrap().course.unwrap().id, "course-A");
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
    assert_eq!(snapshot.unwrap().course.unwrap().unit, None);
    assert!(prompt.ends_with("next exercise"));
}

#[test]
fn same_tab_version_loads_body_only_once_per_thread_and_agent() {
    let state = PageContextState::default();
    state.set_current(Some(PageContext {
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
    assert_eq!(second, "follow up");
    assert!(!second.contains("complete event body"));
}

#[test]
fn chip_distinguishes_ready_loaded_and_needs_reload() {
    let state = PageContextState::default();
    let mut context = PageContext {
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
        tab_id: "tab-event-1".into(),
        route: "/events/event-1".into(),
        title: "Reading Rust".into(),
        version: "v1".into(),
        body: PageBody::Ready("event body".into()),
        course: None,
    }));
    let scope = ConversationScope::new("thread-1", "native");

    state.invalidate_loaded();
    assert_eq!(state.chip_state(&scope), Some(PageLoadState::Ready));
}

#[test]
fn invalidated_history_requires_one_reload_then_returns_to_loaded() {
    let state = PageContextState::default();
    state.set_current(Some(PageContext {
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

    state.invalidate_loaded();
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
        tab_id: "tab-long".into(),
        route: "/events/long".into(),
        title: "Long page".into(),
        version: "v1".into(),
        body: PageBody::Ready(full_body.clone().into()),
        course: None,
    }));
    let scope = ConversationScope::with_body_budget("thread-1", "acp", 24);

    let (prompt, snapshot) = state.freeze(scope.clone(), "summarize".into());
    assert!(prompt.contains("正文已截断"));
    assert!(!prompt.contains(&full_body));
    state.mark_sent(&scope, &snapshot);
    assert_eq!(state.chip_state(&scope), Some(PageLoadState::Partial));

    let (follow_up, _) = state.freeze(scope, "follow up".into());
    assert_eq!(follow_up, "follow up");
}

#[test]
fn ready_state_label_describes_loaded_into_composer_without_ambiguity() {
    assert_eq!(page_load_state_label(Some(PageLoadState::Ready)), "已就绪");
}
