use super::super::*;
use super::ScreenContext;

pub(in crate::root_view) fn render_workspace_overview(
    ctx: &mut ScreenContext<'_>,
    language: Language,
    palette: &theme::Palette,
    cx: &mut Context<RootView>,
) -> AnyElement {
    let workspace = ctx.workspaces.current().cloned();
    let enrollments_state = ctx.enrollments_state.clone();
    let enrollment_rows = ctx.enrollments_rows.clone();
    let events_state = ctx.events.state().clone();
    let events = ctx.events.items().to_vec();
    let course_rows = enrollment_rows
        .iter()
        .filter(|row| row.course_id.is_some())
        .take(4)
        .cloned()
        .collect::<Vec<_>>();
    let participation_rows = enrollment_rows.iter().take(3).cloned().collect::<Vec<_>>();

    let Some(workspace) = workspace else {
        return div()
            .flex()
            .flex_col()
            .gap(space(2))
            .child(
                div()
                    .text_size(px(12.0))
                    .text_color(palette.ink_3)
                    .child(translate(language, Key::AccountWorkspaceLoading)),
            )
            .into_any_element();
    };

    let roles = workspace
        .my_role_names
        .iter()
        .map(|role| workspace_role_label(language, role))
        .collect::<Vec<_>>()
        .join(" · ");
    let members = workspace
        .member_count
        .map(|count| {
            format!(
                "{count} {}",
                translate(language, Key::AccountWorkspaceMembers)
            )
        })
        .unwrap_or_default();

    let learning_body: AnyElement = match enrollments_state {
        EnrollmentsListState::Idle | EnrollmentsListState::Loading => div()
            .text_size(px(12.0))
            .text_color(palette.ink_3)
            .child(translate(language, Key::AccountWorkspaceLoading))
            .into_any_element(),
        EnrollmentsListState::Failed(_) => div()
            .flex()
            .flex_row()
            .items_center()
            .gap(space(2))
            .text_size(px(12.0))
            .text_color(palette.danger)
            .child(translate(language, Key::AccountWorkspaceFailed))
            .child(
                div()
                    .id("workspace-learning-retry")
                    .px(space(1))
                    .py(px(3.0))
                    .rounded(px(RADIUS_SMALL))
                    .bg(palette.soft)
                    .text_color(palette.ink_2)
                    .child(translate(language, Key::AccountWorkspaceRetry))
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.enrollments_started = false;
                        this.enrollments_state = EnrollmentsListState::Idle;
                        cx.notify();
                    })),
            )
            .into_any_element(),
        _ if course_rows.is_empty() => div()
            .flex()
            .flex_col()
            .gap(space(1))
            .text_size(px(12.0))
            .text_color(palette.ink_3)
            .child(translate(language, Key::AccountWorkspaceNoLearning))
            .child(
                div()
                    .id("workspace-browse-courses")
                    .w(px(120.0))
                    .px(space(1))
                    .py(px(3.0))
                    .rounded(px(RADIUS_SMALL))
                    .bg(palette.soft)
                    .text_color(palette.accent)
                    .text_size(px(12.0))
                    .child(translate(language, Key::AccountWorkspaceBrowseCourses))
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.navigate("/courses");
                        cx.notify();
                    })),
            )
            .into_any_element(),
        _ => div()
            .flex()
            .flex_col()
            .gap(px(1.0))
            .children(course_rows.into_iter().map(|row| {
                let course_id = row.course_id.clone().unwrap_or_default();
                let target = row.target_title.clone().unwrap_or_default();
                let status = enroll_status_label(language, row.status.as_str());
                let confirmed = row.status == "confirmed";
                div()
                    .id(format!("workspace-course-{}", row.id))
                    .flex()
                    .flex_row()
                    .items_center()
                    .justify_between()
                    .gap(space(2))
                    .px(space(2))
                    .py(space(1))
                    .border_b_1()
                    .border_color(palette.line)
                    .hover(|style| style.bg(palette.soft))
                    .child(
                        div()
                            .flex()
                            .flex_col()
                            .gap(px(2.0))
                            .child(div().text_color(palette.ink).child(target))
                            .child(
                                div()
                                    .text_size(px(11.0))
                                    .text_color(palette.ink_3)
                                    .child(status),
                            ),
                    )
                    .child(div().text_size(px(11.0)).text_color(palette.accent).child(
                        if confirmed {
                            translate(language, Key::AccountWorkspaceContinueLearning)
                        } else {
                            translate(language, Key::AccountWorkspaceViewAll)
                        },
                    ))
                    .on_click(cx.listener(move |this, _, _, cx| {
                        if confirmed {
                            this.navigate_to_learning(&course_id, cx);
                        } else {
                            this.navigate(&format!("/courses/{course_id}"));
                        }
                        cx.notify();
                    }))
                    .into_any_element()
            }))
            .into_any_element(),
    };

    let events_body: AnyElement = match events_state {
        ListState::Idle | ListState::Loading => div()
            .text_size(px(12.0))
            .text_color(palette.ink_3)
            .child(translate(language, Key::AccountWorkspaceLoading))
            .into_any_element(),
        ListState::Failed(_) => div()
            .text_size(px(12.0))
            .text_color(palette.danger)
            .child(translate(language, Key::AccountWorkspaceFailed))
            .into_any_element(),
        _ if events.is_empty() => div()
            .text_size(px(12.0))
            .text_color(palette.ink_3)
            .child(translate(language, Key::AccountWorkspaceNoEvents))
            .into_any_element(),
        _ => div()
            .flex()
            .flex_col()
            .gap(px(1.0))
            .children(events.into_iter().take(3).map(|event| {
                let event_id = event.id.clone();
                let date = event
                    .starts_at
                    .as_deref()
                    .map(|value| value.chars().take(10).collect::<String>())
                    .unwrap_or_default();
                div()
                    .id(format!("workspace-event-{}", event_id))
                    .flex()
                    .flex_row()
                    .items_center()
                    .justify_between()
                    .gap(space(2))
                    .px(space(2))
                    .py(space(1))
                    .border_b_1()
                    .border_color(palette.line)
                    .hover(|style| style.bg(palette.soft))
                    .child(
                        div()
                            .flex()
                            .flex_col()
                            .gap(px(2.0))
                            .child(div().text_color(palette.ink).child(event.title.clone()))
                            .child(
                                div()
                                    .text_size(px(11.0))
                                    .text_color(palette.ink_3)
                                    .child(date),
                            ),
                    )
                    .child(
                        div()
                            .text_size(px(11.0))
                            .text_color(palette.ink_3)
                            .child(translate(language, status_key(event.status.as_str()))),
                    )
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.navigate_to_event_detail(&event_id, cx);
                        cx.notify();
                    }))
                    .into_any_element()
            }))
            .into_any_element(),
    };

    let participation_body: AnyElement = match enrollments_state {
        EnrollmentsListState::Idle | EnrollmentsListState::Loading => div()
            .text_size(px(12.0))
            .text_color(palette.ink_3)
            .child(translate(language, Key::AccountWorkspaceLoading))
            .into_any_element(),
        EnrollmentsListState::Failed(_) => div()
            .text_size(px(12.0))
            .text_color(palette.danger)
            .child(translate(language, Key::AccountWorkspaceFailed))
            .into_any_element(),
        _ if participation_rows.is_empty() => div()
            .text_size(px(12.0))
            .text_color(palette.ink_3)
            .child(translate(language, Key::AccountWorkspaceNoLearning))
            .into_any_element(),
        _ => div()
            .flex()
            .flex_col()
            .gap(px(1.0))
            .children(participation_rows.into_iter().map(|row| {
                let target = row.target_title.clone().unwrap_or_default();
                let status = enroll_status_label(language, row.status.as_str());
                let event_id = row.event_id.clone();
                let course_id = row.course_id.clone();
                div()
                    .id(format!("workspace-participation-{}", row.id))
                    .flex()
                    .flex_row()
                    .items_center()
                    .justify_between()
                    .gap(space(2))
                    .px(space(2))
                    .py(space(1))
                    .border_b_1()
                    .border_color(palette.line)
                    .hover(|style| style.bg(palette.soft))
                    .child(
                        div()
                            .flex()
                            .flex_col()
                            .gap(px(2.0))
                            .child(div().text_color(palette.ink).child(target))
                            .child(
                                div()
                                    .text_size(px(11.0))
                                    .text_color(palette.ink_3)
                                    .child(status),
                            ),
                    )
                    .child(
                        div()
                            .text_size(px(11.0))
                            .text_color(palette.accent)
                            .child(translate(language, Key::EventsParticipationsView)),
                    )
                    .on_click(cx.listener(move |this, _, _, cx| {
                        if let Some(event_id) = event_id.as_deref() {
                            this.navigate_to_event_detail(event_id, cx);
                        } else if let Some(course_id) = course_id.as_deref() {
                            this.navigate(&format!("/courses/{course_id}"));
                        }
                        cx.notify();
                    }))
                    .into_any_element()
            }))
            .into_any_element(),
    };

    div()
        .flex()
        .flex_col()
        .gap(space(3))
        .w_full()
        .max_w(px(980.0))
        .child(
            div()
                .flex()
                .flex_col()
                .gap(space(1))
                .child(
                    div()
                        .text_size(px(28.0))
                        .text_color(palette.ink)
                        .child(workspace.name.clone()),
                )
                .child(
                    div()
                        .text_size(px(12.0))
                        .text_color(palette.ink_3)
                        .child(translate(language, Key::AccountWorkspaceSubtitle)),
                )
                .child(
                    div()
                        .flex()
                        .flex_row()
                        .items_center()
                        .gap(space(2))
                        .text_size(px(12.0))
                        .text_color(palette.ink_3)
                        .child(workspace.slug.clone())
                        .children((!members.is_empty()).then(|| div().child(members)))
                        .children((!roles.is_empty()).then(|| div().child(roles))),
                ),
        )
        .child(
            div()
                .flex()
                .flex_row()
                .items_center()
                .justify_between()
                .child(
                    div()
                        .text_size(px(16.0))
                        .text_color(palette.ink)
                        .child(translate(language, Key::AccountWorkspaceContinueLearning)),
                )
                .child(
                    div()
                        .id("workspace-all-learning")
                        .text_size(px(11.0))
                        .text_color(palette.accent)
                        .child(translate(language, Key::AccountWorkspaceViewAll))
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.navigate("/learning");
                            cx.notify();
                        })),
                ),
        )
        .child(learning_body)
        .child(
            div()
                .flex()
                .flex_row()
                .items_center()
                .justify_between()
                .child(
                    div()
                        .text_size(px(16.0))
                        .text_color(palette.ink)
                        .child(translate(language, Key::AccountWorkspaceUpcomingEvents)),
                )
                .child(
                    div()
                        .id("workspace-all-events")
                        .text_size(px(11.0))
                        .text_color(palette.accent)
                        .child(translate(language, Key::AccountWorkspaceViewAll))
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.navigate("/events");
                            cx.notify();
                        })),
                ),
        )
        .child(events_body)
        .child(
            div()
                .flex()
                .flex_row()
                .items_center()
                .justify_between()
                .child(
                    div()
                        .text_size(px(16.0))
                        .text_color(palette.ink)
                        .child(translate(language, Key::AccountWorkspaceMyParticipations)),
                )
                .child(
                    div()
                        .id("workspace-all-participations")
                        .text_size(px(11.0))
                        .text_color(palette.accent)
                        .child(translate(language, Key::AccountWorkspaceViewAll))
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.navigate("/participations");
                            cx.notify();
                        })),
                ),
        )
        .child(participation_body)
        .into_any_element()
}
