use super::super::super::*;
use super::super::ScreenContext;

pub(in crate::root_view) fn render_enrollments_list(
    ctx: &mut ScreenContext<'_>,
    language: Language,
    palette: &theme::Palette,
    cx: &mut Context<RootView>,
) -> AnyElement {
    let body: AnyElement = match &ctx.enrollments_state {
        EnrollmentsListState::Idle | EnrollmentsListState::Loading => div()
            .text_color(palette.ink_3)
            .child(translate(language, Key::EventsMineLoading))
            .into_any_element(),
        EnrollmentsListState::Failed(message) => div()
            .flex()
            .flex_col()
            .gap(space(1))
            .child(div().text_color(palette.danger).child(message.clone()))
            .child(
                div()
                    .id("enrollments-retry")
                    .px(space(2))
                    .py(px(5.0))
                    .rounded(px(RADIUS_MEDIUM))
                    .bg(palette.accent)
                    .text_color(palette.canvas)
                    .child(translate(language, Key::EventsMineRetry))
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.enrollments_started = false;
                        this.enrollments_state = EnrollmentsListState::Idle;
                        cx.notify();
                    })),
            )
            .into_any_element(),
        EnrollmentsListState::Empty => div()
            .text_color(palette.ink_3)
            .child(translate(language, Key::EventsMineEmpty))
            .into_any_element(),
        EnrollmentsListState::Ready => {
            let rows = ctx
                .enrollments_rows
                .iter()
                .map(|row| {
                    let starts = row
                        .starts_at
                        .as_deref()
                        .map(|value| value.chars().take(10).collect::<String>())
                        .unwrap_or_default();
                    let target = row.target_title.clone().unwrap_or_default();
                    let event_id = row.event_id.clone();
                    let course_id = row.course_id.clone();
                    let row_id = row.id.clone();
                    div()
                        .id(format!("enrollment-row-{row_id}"))
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
                                        .child(starts),
                                ),
                        )
                        .child(
                            div()
                                .px(px(6.0))
                                .py(px(2.0))
                                .rounded(px(RADIUS_SMALL))
                                .bg(palette.soft)
                                .text_size(px(11.0))
                                .text_color(palette.ink_2)
                                .child(enroll_status_label(language, &row.status)),
                        )
                        .on_click(cx.listener(move |this, _, _, cx| {
                            if let Some(event_id) = &event_id {
                                this.navigate(&format!("/events/{event_id}"));
                            } else if let Some(course_id) = &course_id {
                                this.navigate(&format!("/courses/{course_id}"));
                            }
                            cx.notify();
                        }))
                        .into_any_element()
                })
                .collect::<Vec<_>>();
            div().flex().flex_col().children(rows).into_any_element()
        }
    };

    div()
        .flex()
        .flex_col()
        .gap(space(2))
        .child(
            div()
                .flex()
                .flex_row()
                .items_center()
                .justify_between()
                .child(
                    div()
                        .text_size(px(24.0))
                        .text_color(palette.ink)
                        .child(translate_registered(language, "events.mine.title")),
                )
                .child(
                    div()
                        .id("enrollments-back")
                        .text_size(px(12.0))
                        .text_color(palette.ink_3)
                        .child(translate(language, Key::EventsDetailBack))
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.navigate("/events");
                            cx.notify();
                        })),
                ),
        )
        .child(body)
        .into_any_element()
}
