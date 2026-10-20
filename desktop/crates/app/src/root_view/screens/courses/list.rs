use super::super::super::*;

impl RootView {
    pub(in crate::root_view) fn render_courses_list(
        &mut self,
        language: Language,
        palette: &theme::Palette,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let state = self.courses.state().clone();
        let items = self.courses.items().to_vec();
        let has_more = self.courses.has_more();

        let body: AnyElement = match state {
            CoursesListState::Idle | CoursesListState::Loading => div()
                .text_color(palette.ink_3)
                .child(translate(language, Key::CoursesCatalogLoading))
                .into_any_element(),
            CoursesListState::Failed(message) => div()
                .flex()
                .flex_col()
                .gap(space(1))
                .child(div().text_color(palette.danger).child(message))
                .child(
                    div()
                        .id("courses-retry")
                        .px(space(2))
                        .py(px(5.0))
                        .rounded(px(RADIUS_MEDIUM))
                        .bg(palette.accent)
                        .text_color(white())
                        .child(translate(language, Key::CoursesCatalogRetry))
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.courses.retry_ready();
                            this.start_courses_load(cx, true);
                        })),
                )
                .into_any_element(),
            CoursesListState::Empty => div()
                .text_color(palette.ink_3)
                .child(translate(language, Key::CoursesCatalogEmpty))
                .into_any_element(),
            CoursesListState::Ready => {
                let rows = items
                    .iter()
                    .map(|course| course_row(course, language, palette, cx))
                    .collect::<Vec<_>>();
                let load_more = has_more.then(|| {
                    div()
                        .id("courses-load-more")
                        .mt(space(2))
                        .px(space(2))
                        .py(px(5.0))
                        .rounded(px(RADIUS_MEDIUM))
                        .border_1()
                        .border_color(palette.line_strong)
                        .text_color(palette.ink_2)
                        .child(translate(language, Key::CoursesCatalogLoadMore))
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.start_courses_load(cx, false);
                        }))
                        .into_any_element()
                });
                div()
                    .flex()
                    .flex_col()
                    .children(rows)
                    .children(load_more)
                    .into_any_element()
            }
        };

        div()
            .flex()
            .flex_col()
            .gap(space(2))
            .child(
                div()
                    .text_size(px(24.0))
                    .text_color(palette.ink)
                    .child(translate_registered(language, "courses.catalog.title")),
            )
            .child(body)
            .into_any_element()
    }
}
