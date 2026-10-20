use super::super::super::*;

impl RootView {
    pub(in crate::root_view) fn render_course_learning(
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
        let user_id = self
            .session
            .signed_in()
            .map(|session| session.user_id.clone());

        let back = div()
            .id("course-learning-back")
            .text_size(px(12.0))
            .text_color(palette.ink_3)
            .child(translate(language, Key::CoursesDetailBack))
            .on_click(cx.listener(move |this, _, _, cx| {
                this.navigate(&format!("/courses/{course_id}"));
                cx.notify();
            }));

        let body: AnyElement = match state {
            CoursesListState::Idle | CoursesListState::Loading => div()
                .text_color(palette.ink_3)
                .child(translate(language, Key::CoursesLearningLoading))
                .into_any_element(),
            CoursesListState::Failed(message) => div()
                .flex()
                .flex_col()
                .gap(space(1))
                .child(div().text_color(palette.danger).child(message))
                .child(
                    div()
                        .id("course-learning-retry")
                        .px(space(2))
                        .py(px(5.0))
                        .rounded(px(RADIUS_MEDIUM))
                        .bg(palette.accent)
                        .text_color(white())
                        .child(translate(language, Key::CoursesLearningRetry))
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.course_detail.retry_ready();
                            this.course_detail_started = false;
                            cx.notify();
                        })),
                )
                .into_any_element(),
            CoursesListState::Empty => div()
                .text_color(palette.ink_3)
                .child(translate(language, Key::CoursesDetailNotFound))
                .into_any_element(),
            CoursesListState::Ready => match detail {
                Some(detail) => match learning_context(user_id, &detail) {
                    Ok(context) => div()
                        .flex()
                        .flex_col()
                        .gap(space(2))
                        .child(
                            div()
                                .text_size(px(24.0))
                                .text_color(palette.ink)
                                .child(detail.title.clone()),
                        )
                        .child(
                            div()
                                .flex()
                                .flex_row()
                                .gap(space(2))
                                .text_size(px(12.0))
                                .text_color(palette.ink_3)
                                .child(format!(
                                    "{} {}",
                                    translate(language, Key::CoursesLearningWorkspace),
                                    context.workspace_id
                                ))
                                .child(format!(
                                    "{} {}",
                                    translate(language, Key::CoursesLearningRevision),
                                    context.course_revision_id
                                )),
                        )
                        .child(self.render_learning_projection(language, palette, cx))
                        .child(self.render_course_materials(language, palette, cx))
                        .into_any_element(),
                    Err(_) => div()
                        .px(space(2))
                        .py(px(6.0))
                        .rounded(px(RADIUS_MEDIUM))
                        .bg(palette.soft)
                        .text_color(palette.danger)
                        .child(translate(language, Key::CoursesLearningContextRequired))
                        .into_any_element(),
                },
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

    pub(in crate::root_view) fn render_learning_projection(
        &mut self,
        language: Language,
        palette: &theme::Palette,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        match self.projection.state().clone() {
            ProjectionState::Idle | ProjectionState::Empty => div().into_any_element(),
            ProjectionState::Loading => div()
                .text_size(px(11.0))
                .text_color(palette.ink_3)
                .child(translate(language, Key::CoursesLearningProjectionTitle))
                .into_any_element(),
            ProjectionState::Failed(_) => div()
                .flex()
                .flex_row()
                .items_center()
                .gap(space(1))
                .text_size(px(11.0))
                .text_color(palette.ink_3)
                .child(translate(language, Key::CoursesLearningProjectionError))
                .child(
                    div()
                        .id("projection-retry")
                        .px(space(1))
                        .py(px(2.0))
                        .rounded(px(RADIUS_SMALL))
                        .bg(palette.soft)
                        .text_color(palette.ink_2)
                        .child(translate(language, Key::CoursesLearningProjectionRetry))
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.projection.retry_ready();
                            cx.notify();
                        })),
                )
                .into_any_element(),
            ProjectionState::Ready => {
                let Some(projection) = self.projection.projection().cloned() else {
                    return div().into_any_element();
                };
                let progress = projection.progress.clone();
                let next = projection.next_action.clone();
                let stale = projection.stale_revision;
                let review_count = projection.review_queue.len();
                let objectives = projection
                    .objectives
                    .iter()
                    .take(4)
                    .map(|objective| {
                        let status = match objective.mastery.as_str() {
                            "mastered" => "✓",
                            "learning" => "◐",
                            _ => "○",
                        };
                        div()
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap(space(1))
                            .text_size(px(11.0))
                            .text_color(palette.ink_2)
                            .child(format!("{status} {}", objective.title))
                            .children(objective.locked.then(|| {
                                div()
                                    .text_size(px(10.0))
                                    .text_color(palette.ink_3)
                                    .child(translate(
                                        language,
                                        Key::CoursesLearningProjectionLocked,
                                    ))
                                    .into_any_element()
                            }))
                            .into_any_element()
                    })
                    .collect::<Vec<_>>();
                div()
                    .mt(space(2))
                    .flex()
                    .flex_col()
                    .gap(space(1))
                    .p(space(2))
                    .rounded(px(RADIUS_MEDIUM))
                    .border_1()
                    .border_color(palette.line)
                    .bg(palette.card)
                    .child(
                        div()
                            .text_size(px(13.0))
                            .text_color(palette.ink)
                            .child(translate(language, Key::CoursesLearningProjectionTitle)),
                    )
                    .children(progress.map(|progress| {
                        div()
                            .text_size(px(12.0))
                            .text_color(palette.ink_2)
                            .child(format!(
                                "{} / {}",
                                progress.mastered_required, progress.total_required
                            ))
                            .into_any_element()
                    }))
                    .children(next.map(|next| {
                        div()
                            .text_size(px(12.0))
                            .text_color(palette.accent)
                            .child(next.reason)
                            .into_any_element()
                    }))
                    .children(stale.then(|| {
                        div()
                            .text_size(px(11.0))
                            .text_color(palette.danger)
                            .child(translate(language, Key::CoursesLearningProjectionStale))
                            .into_any_element()
                    }))
                    .children((review_count > 0).then(|| {
                        div()
                            .text_size(px(11.0))
                            .text_color(palette.ink_3)
                            .child(format!("待复习 {review_count}"))
                            .into_any_element()
                    }))
                    .children(objectives)
                    .into_any_element()
            }
        }
    }

    pub(in crate::root_view) fn render_course_materials(
        &mut self,
        language: Language,
        palette: &theme::Palette,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        match self.content.state().clone() {
            CourseContentState::Idle | CourseContentState::Loading => div()
                .mt(space(2))
                .text_size(px(12.0))
                .text_color(palette.ink_3)
                .child(translate(language, Key::CoursesLearningContentLoading))
                .into_any_element(),
            CourseContentState::Failed(message) => div()
                .mt(space(2))
                .flex()
                .flex_col()
                .gap(space(1))
                .child(
                    div()
                        .text_size(px(12.0))
                        .text_color(palette.danger)
                        .child(message),
                )
                .child(
                    div()
                        .id("course-content-retry")
                        .px(space(2))
                        .py(px(5.0))
                        .rounded(px(RADIUS_MEDIUM))
                        .bg(palette.accent)
                        .text_color(palette.canvas)
                        .child(translate(language, Key::CoursesLearningContentRetry))
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.content.retry_ready();
                            cx.notify();
                        })),
                )
                .into_any_element(),
            CourseContentState::Empty => div()
                .mt(space(2))
                .text_size(px(12.0))
                .text_color(palette.ink_3)
                .child(translate(language, Key::CoursesLearningContentEmpty))
                .into_any_element(),
            CourseContentState::Ready => {
                let Some(content) = self.content.content().cloned() else {
                    return div()
                        .text_color(palette.ink_3)
                        .child(translate(language, Key::CoursesLearningContentEmpty))
                        .into_any_element();
                };
                let mut materials = Vec::new();
                for issue in &content.document.issues {
                    for material in issue
                        .story_materials
                        .iter()
                        .chain(issue.objective_materials.iter())
                    {
                        if !matches!(material.kind, MaterialKind::Text | MaterialKind::Markdown) {
                            continue;
                        }
                        let Some(body) = material.body.as_deref() else {
                            continue;
                        };
                        if body.trim().is_empty() {
                            continue;
                        }
                        let view_handle = cx.entity().downgrade();
                        materials.push(
                            TextView::markdown(
                                format!("course-material-{}", materials.len()),
                                sanitize_markdown(body),
                            )
                            .on_link_click(move |url, _, _, cx| {
                                if crate::safe_markdown::is_safe_link(url) {
                                    let url = url.to_string();
                                    let _ = view_handle.update(cx, |this, cx| {
                                        this.pending_link = Some(url);
                                        cx.notify();
                                    });
                                }
                            })
                            .into_any_element(),
                        );
                        materials.extend(render_markdown_with_math(
                            body,
                            &format!("course-math-{}", materials.len()),
                            14.0,
                            2.0,
                            palette.ink,
                        ));
                    }
                }
                if materials.is_empty() {
                    return div()
                        .text_color(palette.ink_3)
                        .child(translate(language, Key::CoursesLearningContentEmpty))
                        .into_any_element();
                }
                let confirm = self.pending_link.clone().map(|url| {
                    div()
                        .flex()
                        .flex_row()
                        .items_center()
                        .gap(space(1))
                        .p(space(1))
                        .rounded(px(RADIUS_MEDIUM))
                        .bg(palette.soft)
                        .text_size(px(12.0))
                        .child(div().text_color(palette.ink_2).child(format!(
                            "{} {url}",
                            translate(language, Key::CoursesRenderOpenLink)
                        )))
                        .child(
                            div()
                                .id("open-external-link")
                                .px(space(1))
                                .py(px(2.0))
                                .rounded(px(RADIUS_SMALL))
                                .bg(palette.accent)
                                .text_color(palette.canvas)
                                .child(translate(language, Key::CoursesRenderOpen))
                                .on_click(cx.listener(move |this, _, _, cx| {
                                    if let Some(url) = this.pending_link.take() {
                                        cx.open_url(&url);
                                    }
                                    cx.notify();
                                })),
                        )
                        .child(
                            div()
                                .id("cancel-external-link")
                                .px(space(1))
                                .py(px(2.0))
                                .rounded(px(RADIUS_SMALL))
                                .text_color(palette.ink_3)
                                .child(translate(language, Key::CoursesRenderCancel))
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.pending_link = None;
                                    cx.notify();
                                })),
                        )
                        .into_any_element()
                });
                div()
                    .mt(space(2))
                    .flex()
                    .flex_col()
                    .gap(space(2))
                    .children(confirm)
                    .children(materials)
                    .into_any_element()
            }
        }
    }
}
