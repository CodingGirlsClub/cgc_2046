use super::super::*;

impl RootView {
    pub(in crate::root_view) fn render_learning_home(
        &mut self,
        language: Language,
        palette: &theme::Palette,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let state = self.enrollments_state.clone();
        let rows = self.enrollments_rows.clone();
        let course_rows = rows
            .iter()
            .filter(|row| row.course_id.is_some())
            .cloned()
            .collect::<Vec<_>>();
        let body: AnyElement = match state {
            EnrollmentsListState::Idle | EnrollmentsListState::Loading => div()
                .text_color(palette.ink_3)
                .child(translate(language, Key::AccountWorkspaceLoading))
                .into_any_element(),
            EnrollmentsListState::Failed(_) => div()
                .flex()
                .flex_col()
                .gap(space(1))
                .text_color(palette.danger)
                .child(translate(language, Key::AccountWorkspaceFailed))
                .child(
                    div()
                        .id("learning-home-retry")
                        .px(space(2))
                        .py(px(4.0))
                        .rounded(px(RADIUS_MEDIUM))
                        .bg(palette.accent)
                        .text_color(palette.canvas)
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
                .gap(space(2))
                .text_size(px(12.0))
                .text_color(palette.ink_3)
                .child(translate(language, Key::CoursesLearningHomeEmpty))
                .child(
                    div()
                        .id("learning-home-browse")
                        .w(px(120.0))
                        .px(space(1))
                        .py(px(3.0))
                        .rounded(px(RADIUS_SMALL))
                        .bg(palette.soft)
                        .text_color(palette.accent)
                        .child(translate(language, Key::CoursesLearningHomeBrowse))
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
                    let title = row.target_title.clone().unwrap_or_default();
                    let status = enroll_status_label(language, row.status.as_str());
                    let confirmed = row.status == "confirmed";
                    div()
                        .id(format!("learning-home-{}", row.id))
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
                                .child(
                                    div()
                                        .text_size(px(11.0))
                                        .text_color(palette.ink_3)
                                        .child(status),
                                ),
                        )
                        .child(div().text_size(px(12.0)).text_color(palette.accent).child(
                            if confirmed {
                                translate(language, Key::CoursesLearningHomeContinue)
                            } else {
                                translate(language, Key::CoursesLearningHomeBrowse)
                            },
                        ))
                        .on_click(cx.listener(move |this, _, _, cx| {
                            if confirmed {
                                this.navigate_to_learning(&course_id);
                            } else {
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
                            .child(translate(language, Key::CoursesLearningHomeTitle)),
                    )
                    .child(
                        div()
                            .text_size(px(12.0))
                            .text_color(palette.ink_3)
                            .child(translate(language, Key::CoursesLearningHomeSubtitle)),
                    ),
            )
            .child(body)
            .into_any_element()
    }
}
