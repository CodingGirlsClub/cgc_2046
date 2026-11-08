use super::super::*;
use super::ScreenContext;

pub(in crate::root_view) fn render_participations(
    ctx: &mut ScreenContext<'_>,
    language: Language,
    palette: &theme::Palette,
    cx: &mut Context<RootView>,
) -> AnyElement {
    let state = ctx.enrollments_state.clone();
    let rows = ctx.enrollments_rows.clone();
    let body: AnyElement = match state {
        EnrollmentsListState::Idle | EnrollmentsListState::Loading => {
            render_loading_state(language, Key::AccountWorkspaceLoading, palette).into_any_element()
        }
        EnrollmentsListState::Failed(_) => div()
            .text_color(palette.danger)
            .child(translate(language, Key::AccountWorkspaceFailed))
            .into_any_element(),
        _ if rows.is_empty() => div()
            .text_size(px(12.0))
            .text_color(palette.ink_3)
            .child(translate(language, Key::EventsParticipationsEmpty))
            .into_any_element(),
        _ => div()
            .flex()
            .flex_col()
            .gap(px(1.0))
            .children(rows.into_iter().map(|row| {
                let title = row.target_title.clone().unwrap_or_default();
                let kind = if row.event_id.is_some() {
                    translate(language, Key::EventsParticipationsKindEvent)
                } else {
                    translate(language, Key::EventsParticipationsKindCourse)
                };
                let status = enroll_status_label(language, row.status.as_str());
                let date = row
                    .starts_at
                    .as_deref()
                    .map(|value| value.chars().take(10).collect::<String>())
                    .unwrap_or_default();
                let check_in = row
                    .check_in_code
                    .clone()
                    .map(|code| {
                        format!(
                            "{} {code}",
                            translate(language, Key::EventsParticipationsCheckIn)
                        )
                    })
                    .unwrap_or_default();
                let origin = super::render_workspace_badge(
                    ctx.workspaces.workspaces(),
                    Some(&row.workspace_id),
                    language,
                    palette,
                );
                let path = row
                    .event_id
                    .as_ref()
                    .map(|id| format!("/events/{id}"))
                    .or_else(|| row.course_id.as_ref().map(|id| format!("/courses/{id}")))
                    .map(|suffix| {
                        crate::routing::offering_path(
                            ctx.workspaces.workspaces(),
                            Some(&row.workspace_id),
                            &suffix,
                        )
                    });
                let tab_title = title.clone();
                div()
                    .id(format!("participation-{}", row.id))
                    .test_support()
                    .role(Role::Link)
                    .aria_label(title.clone())
                    .flex()
                    .flex_row()
                    .items_center()
                    .justify_between()
                    .gap(space(2))
                    .px(space(2))
                    .py(space(2))
                    .border_b_1()
                    .border_color(palette.line)
                    .hover(|style| style.bg(palette.soft))
                    .child(
                        div()
                            .flex()
                            .flex_col()
                            .gap(px(2.0))
                            .child(div().text_color(palette.ink).child(title))
                            .children(origin)
                            .child(
                                div()
                                    .text_size(px(11.0))
                                    .text_color(palette.ink_3)
                                    .child(format!("{kind} · {status}")),
                            )
                            .children((!date.is_empty()).then(|| {
                                div()
                                    .text_size(px(11.0))
                                    .text_color(palette.ink_3)
                                    .child(date)
                                    .into_any_element()
                            }))
                            .children((!check_in.is_empty()).then(|| {
                                div()
                                    .text_size(px(11.0))
                                    .text_color(palette.accent)
                                    .child(check_in)
                                    .into_any_element()
                            })),
                    )
                    .child(
                        div()
                            .text_size(px(11.0))
                            .text_color(palette.accent)
                            .child(translate(language, Key::EventsParticipationsView)),
                    )
                    .on_click(cx.listener(move |this, _, _, cx| {
                        if let Some(path) = path.as_deref() {
                            // 「我的报名 → 查看」走统一 tab 生命周期：先持久化源台 →
                            // 切台恢复目标台 → 插入并持久化目标 tab（R10）。
                            this.open_page_tab(path, tab_title.clone(), cx);
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
                        .child(translate(language, Key::EventsParticipationsTitle)),
                )
                .child(
                    div()
                        .text_size(px(12.0))
                        .text_color(palette.ink_3)
                        .child(translate(language, Key::EventsParticipationsSubtitle)),
                ),
        )
        .child(body)
        .into_any_element()
}
