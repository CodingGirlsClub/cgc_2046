use super::super::*;
use super::ScreenContext;

pub(in crate::root_view) fn course_enrollments(
    rows: &[MyEnrollmentRow],
) -> impl Iterator<Item = &MyEnrollmentRow> {
    rows.iter().filter(|row| row.course_id.is_some())
}

fn next_action_key(kind: &str) -> Option<Key> {
    match kind {
        "review" => Some(Key::CoursesLearningHomeNextReview),
        "remediation" => Some(Key::CoursesLearningHomeNextRemediation),
        "developing" => Some(Key::CoursesLearningHomeNextDeveloping),
        "next_required" => Some(Key::CoursesLearningHomeNextRequired),
        "elective" => Some(Key::CoursesLearningHomeNextElective),
        _ => None,
    }
}

fn progress_copy(
    language: Language,
    progress: &cgc_events::enrollments::LearningProgress,
) -> String {
    if progress.complete {
        return translate(language, Key::CoursesLearningHomeComplete).to_string();
    }
    translate(language, Key::CoursesLearningHomeProgress)
        .replace("{done}", &progress.mastered_required.to_string())
        .replace("{total}", &progress.total_required.to_string())
}

pub(in crate::root_view) fn render_learning_home(
    ctx: &mut ScreenContext<'_>,
    language: Language,
    palette: &theme::Palette,
    cx: &mut Context<RootView>,
) -> AnyElement {
    let state = ctx.enrollments_state.clone();
    let runs = ctx.learning_runs.clone();
    // run 可能来自活动报名（配套课写进 subject_course_id），关联时必须看完整报名列表。
    let all_rows = ctx.enrollments_rows.clone();
    let rows = course_enrollments(&all_rows).cloned().collect::<Vec<_>>();
    let run_courses = runs
        .iter()
        .map(|run| run.course_id.clone())
        .collect::<Vec<_>>();
    // 「已确认但无 run」才是兜底行；待支付/审批中留在「我的报名」。
    let fallback = rows
        .iter()
        .filter(|row| row.status == "confirmed")
        .filter(|row| {
            row.course_id
                .as_ref()
                .is_none_or(|course_id| !run_courses.contains(course_id))
        })
        .cloned()
        .collect::<Vec<_>>();
    let body: AnyElement = match state {
        EnrollmentsListState::Idle | EnrollmentsListState::Loading => {
            render_loading_state(language, Key::AccountWorkspaceLoading, palette).into_any_element()
        }
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
        _ if runs.is_empty() && fallback.is_empty() => div()
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
        _ => {
            let mut items = Vec::new();
            for run in runs {
                let enrollment = cgc_events::enrollments::enrollment_for_run(&all_rows, &run);
                let workspace_id = enrollment.map(|row| row.workspace_id.clone());
                let origin = super::render_workspace_badge(
                    ctx.workspaces.workspaces(),
                    workspace_id.as_deref(),
                    language,
                    palette,
                );
                let course_id = run.course_id.clone();
                let title = run
                    .target_title
                    .clone()
                    .or_else(|| enrollment.and_then(|row| row.target_title.clone()))
                    .unwrap_or_default();
                let progress = progress_copy(language, &run.progress);
                let next = run
                    .next_action
                    .as_ref()
                    .and_then(|action| next_action_key(&action.kind))
                    .map(|key| translate(language, key).to_string());
                let stale = run
                    .stale_revision
                    .then(|| translate(language, Key::CoursesLearningHomeStale).to_string());
                items.push(
                    div()
                        .id(format!("learning-run-{}", run.run_id))
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
                                        .id(format!("learning-progress-{}", run.run_id))
                                        .test_support()
                                        .role(Role::Status)
                                        .aria_label(progress.clone())
                                        .text_size(px(11.0))
                                        .text_color(palette.ink_3)
                                        .child(progress),
                                )
                                .children(next.map(|label| {
                                    div()
                                        .id(format!("learning-next-{}", run.run_id))
                                        .test_support()
                                        .role(Role::Status)
                                        .aria_label(label.clone())
                                        .text_size(px(11.0))
                                        .text_color(palette.accent)
                                        .child(label)
                                }))
                                .children(stale.map(|label| {
                                    div()
                                        .id(format!("learning-stale-{}", run.run_id))
                                        .test_support()
                                        .role(Role::Status)
                                        .aria_label(label.clone())
                                        .text_size(px(11.0))
                                        .text_color(palette.ink_3)
                                        .child(label)
                                })),
                        )
                        .child(
                            div()
                                .text_size(px(12.0))
                                .text_color(palette.accent)
                                .child(translate(language, Key::CoursesLearningHomeContinue)),
                        )
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.navigate_to_learning(&course_id, workspace_id.as_deref(), cx);
                            cx.notify();
                        }))
                        .into_any_element(),
                );
            }
            for row in fallback {
                let course_id = row.course_id.clone().unwrap_or_default();
                let title = row.target_title.clone().unwrap_or_default();
                let origin = super::render_workspace_badge(
                    ctx.workspaces.workspaces(),
                    Some(&row.workspace_id),
                    language,
                    palette,
                );
                let workspace_id = row.workspace_id;
                items.push(
                    div()
                        .id(format!("learning-home-{}", row.id))
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
                                .child(div().text_size(px(11.0)).text_color(palette.ink_3).child(
                                    translate(language, Key::CoursesLearningHomeNoProgress),
                                )),
                        )
                        .child(
                            div()
                                .text_size(px(12.0))
                                .text_color(palette.accent)
                                .child(translate(language, Key::CoursesLearningHomeContinue)),
                        )
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.navigate_to_learning(&course_id, Some(&workspace_id), cx);
                            cx.notify();
                        }))
                        .into_any_element(),
                );
            }
            div()
                .flex()
                .flex_col()
                .gap(px(1.0))
                .children(items)
                .into_any_element()
        }
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
