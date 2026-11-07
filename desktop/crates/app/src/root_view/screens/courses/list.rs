use super::super::super::*;
use super::super::ScreenContext;

pub(in crate::root_view) fn render_courses_list(
    ctx: &mut ScreenContext<'_>,
    language: Language,
    palette: &theme::Palette,
    cx: &mut Context<RootView>,
) -> AnyElement {
    let public_face = ctx
        .current
        .as_ref()
        .is_some_and(|route_match| route_match.route.id == "courses.public_list");
    let title_key = if public_face {
        Key::CoursesPublicTitle
    } else {
        Key::CoursesCatalogTitle
    };
    let empty_key = if public_face {
        Key::CoursesPublicEmpty
    } else {
        Key::CoursesCatalogEmpty
    };
    let state = ctx.courses.state().clone();
    let items = ctx.courses.items().to_vec();
    let has_more = ctx.courses.has_more();

    let body: AnyElement = match state {
        CoursesListState::Idle | CoursesListState::Loading => {
            render_loading_state(language, Key::CoursesCatalogLoading, palette).into_any_element()
        }
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
            .id("courses-list-empty")
            .test_support()
            .role(Role::Status)
            .aria_label(translate(language, empty_key).to_string())
            .text_color(palette.ink_3)
            .child(translate(language, empty_key))
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
                .id("courses-list-title")
                .test_support()
                .role(Role::Heading)
                .aria_label(translate(language, title_key).to_string())
                .text_size(px(24.0))
                .text_color(palette.ink)
                .child(translate(language, title_key)),
        )
        .child(body)
        .into_any_element()
}
