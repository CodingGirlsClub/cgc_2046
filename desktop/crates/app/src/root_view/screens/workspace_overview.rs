use super::super::*;
use super::ScreenContext;

#[cfg(all(test, cgc_ui_tests))]
mod tests;

pub(in crate::root_view) fn render_workspace_overview(
    ctx: &mut ScreenContext<'_>,
    language: Language,
    palette: &theme::Palette,
    cx: &mut Context<RootView>,
) -> AnyElement {
    let workspace = ctx.workspaces.current().cloned();
    let workspace_state = ctx.workspaces.state().clone();
    let events_state = ctx.events.state().clone();
    let events = ctx.events.items().to_vec();
    let courses_state = ctx.courses.state().clone();
    let course_items = ctx.courses.items().to_vec();

    let Some(workspace) = workspace else {
        // 没有当前工作台时，失败必须直接可见：否则后台不可达会让概览页永远停在
        // 「加载中…」，用户既看不到原因也没有重试入口（issue #1238）。
        return match workspace_state {
            WorkspaceListState::Failed(message) => {
                render_workspace_failure(language, palette, &message, cx)
            }
            _ => div()
                .flex()
                .flex_col()
                .gap(space(2))
                .child(
                    div()
                        .text_size(px(12.0))
                        .text_color(palette.ink_3)
                        .child(translate(language, Key::AccountWorkspaceLoading)),
                )
                .into_any_element(),
        };
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

    let events_body: AnyElement = match events_state {
        ListState::Idle | ListState::Loading => {
            render_loading_state(language, Key::AccountWorkspaceLoading, palette)
        }
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

    let courses_body: AnyElement = match courses_state {
        CoursesListState::Idle | CoursesListState::Loading => {
            render_loading_state(language, Key::AccountWorkspaceLoading, palette)
        }
        CoursesListState::Failed(_) => div()
            .text_size(px(12.0))
            .text_color(palette.danger)
            .child(translate(language, Key::AccountWorkspaceFailed))
            .into_any_element(),
        _ if course_items.is_empty() => div()
            .text_size(px(12.0))
            .text_color(palette.ink_3)
            .child(translate(language, Key::CoursesCatalogEmpty))
            .into_any_element(),
        _ => div()
            .flex()
            .flex_col()
            .gap(px(1.0))
            .children(course_items.into_iter().take(3).map(|course| {
                let course_id = course.id.clone();
                let title = course.title.clone();
                div()
                    .id(format!("workspace-course-{}", course_id))
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
                    .child(div().text_color(palette.ink).child(title))
                    .child(
                        div()
                            .text_size(px(11.0))
                            .text_color(palette.accent)
                            .child(translate(language, Key::AccountWorkspaceViewAll)),
                    )
                    .on_click(cx.listener(move |this, _, _, cx| {
                        let path = this
                            .workspace_path(&format!("/courses/{course_id}"))
                            .unwrap_or_else(|| format!("/courses/{course_id}"));
                        this.navigate(&path);
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
                .child(overview_section_heading(
                    language,
                    palette,
                    Key::AccountWorkspaceUpcomingEvents,
                ))
                .child(
                    div()
                        .id("workspace-all-events")
                        .text_size(px(11.0))
                        .text_color(palette.accent)
                        .child(translate(language, Key::AccountWorkspaceViewAll))
                        .on_click(cx.listener(|this, _, _, cx| {
                            let path = this
                                .workspace_path("/events")
                                .unwrap_or_else(|| "/events".to_string());
                            this.navigate(&path);
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
                .child(overview_section_heading(
                    language,
                    palette,
                    Key::CoursesCatalogTitle,
                ))
                .child(
                    div()
                        .id("workspace-all-courses")
                        .text_size(px(11.0))
                        .text_color(palette.accent)
                        .child(translate(language, Key::AccountWorkspaceViewAll))
                        .on_click(cx.listener(|this, _, _, cx| {
                            let path = this
                                .workspace_path("/courses")
                                .unwrap_or_else(|| "/courses".to_string());
                            this.navigate(&path);
                            cx.notify();
                        })),
                ),
        )
        .child(courses_body)
        .into_any_element()
}

/// 概览区块标题：带 Heading role 与可读 label，便于读屏与 UI 回归定位。
fn overview_section_heading(language: Language, palette: &theme::Palette, key: Key) -> AnyElement {
    div()
        .id(format!("overview-section-{}", key.as_str()))
        .test_support()
        .role(Role::Heading)
        .aria_label(translate(language, key).to_string())
        .text_size(px(16.0))
        .text_color(palette.ink)
        .child(translate(language, key))
        .into_any_element()
}

/// 工作台列表拉取失败且没有可渲染的工作台：给出类别文案、原始诊断与重试入口。
///
/// 诊断行直接展示 `WorkspaceError::diagnostic()`（端点 + 错误类别，不含凭证），
/// 用户反馈「加载不出来」时不必再让维护者去猜是网络、端点还是服务端错误。
fn render_workspace_failure(
    language: Language,
    palette: &theme::Palette,
    diagnostic: &str,
    cx: &mut Context<RootView>,
) -> AnyElement {
    use gpui_kit::component::button::{Button, ButtonVariants};
    div()
        .id("workspace-overview-error")
        .test_support()
        .role(Role::Alert)
        .aria_label(translate(language, Key::AppWorkspaceError))
        .flex()
        .flex_col()
        .gap(space(1))
        .child(
            div()
                .text_size(px(16.0))
                .text_color(palette.ink)
                .child(translate(language, Key::AppWorkspaceError)),
        )
        .child(
            div()
                .id("workspace-overview-error-detail")
                .test_support()
                .aria_label(diagnostic.to_string())
                .text_size(px(12.0))
                .text_color(palette.ink_3)
                .child(diagnostic.to_string()),
        )
        .child(
            Button::new("workspace-overview-retry")
                .label(translate(language, Key::AppWorkspaceRetry))
                .ghost()
                .xsmall()
                .on_click(cx.listener(|this, _, _, cx| this.retry_workspace_load(cx))),
        )
        .into_any_element()
}
