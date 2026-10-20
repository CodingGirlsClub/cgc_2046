use super::super::super::*;

impl RootView {
    pub(in crate::root_view) fn render_course_detail(
        &mut self,
        language: Language,
        palette: &theme::Palette,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let state = self.course_detail.state().clone();
        let detail = self.course_detail.detail().cloned();
        let course_id = self
            .current
            .as_ref()
            .and_then(|route_match| route_match.params.get("id"))
            .cloned()
            .unwrap_or_default();

        let back = div()
            .id("course-detail-back")
            .text_size(px(12.0))
            .text_color(palette.ink_3)
            .child(translate(language, Key::CoursesDetailBack))
            .on_click(cx.listener(|this, _, _, cx| {
                this.navigate("/courses");
                cx.notify();
            }));

        let body: AnyElement = match state {
            CoursesListState::Idle | CoursesListState::Loading => div()
                .text_color(palette.ink_3)
                .child(translate(language, Key::CoursesDetailLoading))
                .into_any_element(),
            CoursesListState::Failed(message) => {
                let not_found = message == "not found";
                div()
                    .flex()
                    .flex_col()
                    .gap(space(1))
                    .child(div().text_color(palette.danger).child(if not_found {
                        translate(language, Key::CoursesDetailNotFound)
                    } else {
                        translate(language, Key::CoursesDetailError)
                    }))
                    .children((!not_found).then(|| {
                        div()
                            .id("course-detail-retry")
                            .px(space(2))
                            .py(px(5.0))
                            .rounded(px(RADIUS_MEDIUM))
                            .bg(palette.accent)
                            .text_color(white())
                            .child(translate(language, Key::CoursesDetailRetry))
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.course_detail.retry_ready();
                                this.course_detail_started = false;
                                cx.notify();
                            }))
                            .into_any_element()
                    }))
                    .into_any_element()
            }
            CoursesListState::Empty => div()
                .text_color(palette.ink_3)
                .child(translate(language, Key::CoursesDetailNotFound))
                .into_any_element(),
            CoursesListState::Ready => match detail {
                Some(detail) => {
                    let enrolled = detail.enrollment_status.as_deref() == Some("confirmed");
                    let action = if enrolled {
                        let target = course_id.clone();
                        div()
                            .flex()
                            .flex_col()
                            .gap(px(4.0))
                            .child(
                                div()
                                    .id("course-start-learning")
                                    .px(space(2))
                                    .py(px(6.0))
                                    .rounded(px(RADIUS_MEDIUM))
                                    .bg(palette.accent)
                                    .text_color(white())
                                    .child(translate(language, Key::CoursesDetailEnrolled))
                                    .on_click(cx.listener(move |this, _, _, cx| {
                                        this.navigate_to_learning(&target);
                                        cx.notify();
                                    })),
                            )
                            .child(
                                div()
                                    .text_size(px(11.0))
                                    .text_color(palette.ink_3)
                                    .child(translate(language, Key::CoursesLearningKeyboardHint)),
                            )
                            .into_any_element()
                    } else {
                        div()
                            .px(space(2))
                            .py(px(6.0))
                            .rounded(px(RADIUS_MEDIUM))
                            .bg(palette.soft)
                            .text_color(palette.ink_3)
                            .child(translate(language, Key::CoursesDetailNotEnrolled))
                            .into_any_element()
                    };

                    div()
                        .flex()
                        .flex_col()
                        .gap(space(2))
                        .child(
                            div()
                                .text_size(px(24.0))
                                .text_color(palette.ink)
                                .child(detail.title.clone()),
                        )
                        .children(detail.description.clone().map(|description| {
                            div()
                                .text_color(palette.ink_2)
                                .child(description)
                                .into_any_element()
                        }))
                        .child(
                            div()
                                .flex()
                                .flex_row()
                                .items_center()
                                .gap(space(2))
                                .child(
                                    div()
                                        .px(space(1))
                                        .py(px(3.0))
                                        .rounded(px(RADIUS_SMALL))
                                        .bg(palette.soft)
                                        .text_size(px(12.0))
                                        .text_color(palette.ink_2)
                                        .child(status_label(language, detail.status.as_str())),
                                )
                                .child(
                                    div()
                                        .px(space(1))
                                        .py(px(3.0))
                                        .rounded(px(RADIUS_SMALL))
                                        .bg(palette.soft)
                                        .text_size(px(12.0))
                                        .text_color(palette.ink_2)
                                        .child(if detail.pricing_enabled {
                                            translate(language, Key::EventsDetailPaid)
                                        } else {
                                            translate(language, Key::EventsDetailFree)
                                        }),
                                ),
                        )
                        .child(action)
                        .into_any_element()
                }
                None => div()
                    .text_color(palette.ink_3)
                    .child(translate(language, Key::CoursesDetailNotFound))
                    .into_any_element(),
            },
        };

        div()
            .flex()
            .flex_col()
            .gap(space(2))
            .child(back)
            .child(body)
            .into_any_element()
    }
}
