//! 右侧 Dock：Site Tree 与 Contextual Outline 互斥显示。
//!
//! 当前只做导航投影；数据加载仍由 controller 持有。完整实例树的懒加载、
//! 搜索与记忆在后续单元补齐。

use super::super::super::*;
use super::super::ScreenContext;
use cgc_courses::outline::build_outline;
use gpui_kit::component::progress::Progress;

pub(in crate::root_view) fn render_right_dock(
    ctx: &mut ScreenContext<'_>,
    language: Language,
    palette: &theme::Palette,
    window: &mut Window,
    cx: &mut Context<RootView>,
) -> AnyElement {
    let panel = ctx.right_panel;
    let width = ctx.right_panel_width;
    let title = match panel {
        RightPanel::SiteTree => translate(language, Key::WorkspaceSiteTreeTitle),
        RightPanel::Outline => translate(language, Key::WorkspaceOutlineTitle),
    };
    let icon = match panel {
        RightPanel::SiteTree => AssetIcon::FolderOpen,
        RightPanel::Outline => AssetIcon::FileText,
    };
    if panel == RightPanel::SiteTree {
        if let Some(offset) = ctx.site_tree_scroll_restore.take() {
            let handle = ctx.site_tree_scroll.clone();
            window.on_next_frame(move |_, _| {
                handle.set_offset(gpui::point(px(0.0), px(offset)));
            });
        }
    }
    let body = match panel {
        RightPanel::SiteTree => render_site_tree(ctx, language, palette, cx),
        RightPanel::Outline => render_outline(ctx, language, palette, cx),
    };

    div()
        .id("right-dock")
        .w(px(width))
        .flex_none()
        .h_full()
        .flex()
        .flex_col()
        .min_h(px(0.0))
        .border_l_1()
        .border_color(palette.line)
        .bg(palette.view)
        .child(
            div()
                .flex()
                .flex_row()
                .items_center()
                .gap(px(6.0))
                .px(space(2))
                .py(space(1))
                .border_b_1()
                .border_color(palette.line)
                .child(
                    Icon::default()
                        .path(icon.path())
                        .text_color(palette.ink_3)
                        .small(),
                )
                .child(
                    div()
                        .text_size(px(12.0))
                        .text_color(palette.ink)
                        .child(title),
                ),
        )
        .child(
            div()
                .id("right-dock-body")
                .flex_1()
                .min_h(px(0.0))
                .overflow_y_scroll()
                .track_scroll(&ctx.site_tree_scroll)
                .on_scroll_wheel(cx.listener(|_this, _, _, cx| {
                    cx.spawn(async move |this, cx| {
                        cx.background_executor()
                            .timer(std::time::Duration::from_millis(200))
                            .await;
                        let _ = this.update(cx, |this, cx| {
                            this.persist_site_tree_scroll(cx);
                        });
                    })
                    .detach();
                }))
                .p(space(1))
                .text_size(px(12.0))
                .text_color(palette.ink_2)
                .child(body),
        )
        .into_any_element()
}

fn render_site_tree(
    ctx: &mut ScreenContext<'_>,
    language: Language,
    palette: &theme::Palette,
    cx: &mut Context<RootView>,
) -> AnyElement {
    let workspace = ctx
        .workspaces
        .current()
        .map(|workspace| workspace.name.clone())
        .unwrap_or_else(|| "Workspace".to_string());
    let events_open = ctx.site_tree_events_open;
    let courses_open = ctx.site_tree_courses_open;
    let query = ctx.site_tree_query.clone();
    let matches = |title: &str| {
        query.trim().is_empty() || title.to_lowercase().contains(&query.trim().to_lowercase())
    };
    let events = ctx
        .events
        .items()
        .iter()
        .filter(|event| matches(&event.title))
        .take(20)
        .map(|event| (event.id.clone(), event.title.clone()))
        .collect::<Vec<_>>();
    let courses = ctx
        .courses
        .items()
        .iter()
        .filter(|course| matches(&course.title))
        .take(20)
        .map(|course| (course.id.clone(), course.title.clone()))
        .collect::<Vec<_>>();
    let show_events = events_open || !query.trim().is_empty();
    let show_courses = courses_open || !query.trim().is_empty();
    let expanded_course = ctx.site_tree_course_open.clone();
    let course_content = ctx.content.content().cloned();
    let active_course = ctx
        .current
        .as_ref()
        .filter(|route_match| route_match.route.id.starts_with("courses."))
        .and_then(|route_match| route_match.params.get("id"))
        .cloned();
    let active_issue = ctx.active_tab.as_deref().and_then(|active| {
        ctx.tabs
            .iter()
            .find(|tab| tab.id == active)
            .and_then(|tab| tab.issue_id.clone())
    });

    let mut rows = Vec::new();
    rows.push(
        div()
            .px(space(1))
            .py(px(3.0))
            .text_color(palette.ink_3)
            .child(workspace)
            .into_any_element(),
    );
    rows.push(
        div()
            .id("site-tree-search")
            .mx(space(1))
            .my(px(2.0))
            .px(space(1))
            .py(px(3.0))
            .rounded(px(RADIUS_SMALL))
            .border_1()
            .border_color(if ctx.site_tree_search_focused {
                palette.accent
            } else {
                palette.line
            })
            .bg(palette.view)
            .text_size(px(11.0))
            .text_color(if query.is_empty() {
                palette.ink_3
            } else {
                palette.ink
            })
            .child(if query.is_empty() {
                "搜索".to_string()
            } else {
                query.clone()
            })
            .on_mouse_down(
                MouseButton::Left,
                cx.listener(|this, _, window, cx| {
                    this.site_tree_search_focused = true;
                    let focus = this.ensure_key_focus(cx);
                    window.focus(&focus, cx);
                    cx.notify();
                }),
            )
            .into_any_element(),
    );
    rows.push(tree_section_row(
        "overview",
        translate(language, Key::AccountWorkspaceOverview).to_string(),
        "/workspace",
        None,
        None,
        palette,
        cx,
    ));
    rows.push(tree_section_row(
        "events",
        translate(language, Key::EventsListTitle).to_string(),
        "/events",
        Some(show_events),
        Some(SiteTreeSection::Events),
        palette,
        cx,
    ));
    if show_events {
        for (id, title) in events {
            rows.push(tree_leaf_row(
                &format!("site-event-{id}"),
                title,
                &format!("/events/{id}"),
                palette,
                cx,
            ));
        }
        if ctx.events.has_more() {
            rows.push(
                div()
                    .id("site-tree-events-more")
                    .pl(px(24.0))
                    .pr(space(1))
                    .py(px(3.0))
                    .text_size(px(10.0))
                    .text_color(palette.accent)
                    .child("加载更多活动")
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.start_events_load(cx, false);
                    }))
                    .into_any_element(),
            );
        }
    }
    rows.push(tree_section_row(
        "courses",
        translate(language, Key::CoursesCatalogTitle).to_string(),
        "/courses",
        Some(show_courses),
        Some(SiteTreeSection::Courses),
        palette,
        cx,
    ));
    if show_courses {
        for (id, title) in courses {
            let is_expanded = expanded_course.as_deref() == Some(id.as_str());
            let enrollment_known = ctx.course_enrollments.contains_key(&id);
            let is_enrolled = ctx
                .course_enrollments
                .get(&id)
                .and_then(|status| status.as_deref())
                .is_some();
            let unenrolled = enrollment_known && !is_enrolled;
            let title_for_click = title.clone();
            let course_id_for_toggle = id.clone();
            let path = format!("/courses/{id}");
            let row = div()
                .id(SharedString::from(format!("site-course-{id}")))
                .flex()
                .flex_row()
                .items_center()
                .gap(px(3.0))
                .px(space(1))
                .py(px(3.0))
                .rounded(px(RADIUS_SMALL))
                .bg(if active_course.as_deref() == Some(id.as_str()) {
                    palette.soft
                } else {
                    palette.view
                })
                .hover(|style| style.bg(palette.soft))
                .child(
                    div()
                        .id(SharedString::from(format!("site-course-chevron-{id}")))
                        .w(px(12.0))
                        .flex()
                        .items_center()
                        .justify_center()
                        .text_size(px(10.0))
                        .text_color(palette.ink_3)
                        .child(if is_expanded { "▾" } else { "▸" })
                        .on_click(cx.listener(move |this, _, _, cx| {
                            cx.stop_propagation();
                            this.toggle_site_tree_course(&course_id_for_toggle, cx);
                        })),
                )
                .child(div().flex_1().child(title))
                .children(unenrolled.then(|| {
                    div()
                        .text_size(px(9.0))
                        .text_color(palette.ink_3)
                        .child("未报名")
                }))
                .on_click(cx.listener(move |this, _, _, cx| {
                    this.open_page_tab(&path, title_for_click.clone(), cx);
                }));
            rows.push(row.into_any_element());
            if is_expanded {
                if let Some(content) = course_content
                    .as_ref()
                    .filter(|content| content.course_id == id)
                {
                    let outline = build_outline(&content.document);
                    for chapter in &outline.chapters {
                        rows.push(
                            div()
                                .pl(px(24.0))
                                .pr(space(1))
                                .py(px(2.0))
                                .text_size(px(10.0))
                                .text_color(palette.ink_3)
                                .child(chapter.title.clone())
                                .into_any_element(),
                        );
                        for issue in &chapter.issues {
                            rows.push(tree_issue_row(
                                issue,
                                palette,
                                &id,
                                active_issue.as_deref(),
                                cx,
                            ));
                        }
                    }
                    for issue in &outline.ungrouped {
                        rows.push(tree_issue_row(
                            issue,
                            palette,
                            &id,
                            active_issue.as_deref(),
                            cx,
                        ));
                    }
                } else {
                    rows.push(
                        div()
                            .pl(px(24.0))
                            .py(px(2.0))
                            .text_size(px(10.0))
                            .text_color(palette.ink_3)
                            .child("加载课程目录…")
                            .into_any_element(),
                    );
                }
            }
        }
        if ctx.courses.has_more() {
            rows.push(
                div()
                    .id("site-tree-courses-more")
                    .pl(px(24.0))
                    .pr(space(1))
                    .py(px(3.0))
                    .text_size(px(10.0))
                    .text_color(palette.accent)
                    .child("加载更多课程")
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.start_courses_load(cx, false);
                    }))
                    .into_any_element(),
            );
        }
    }
    rows.push(tree_section_row(
        "learning",
        translate(language, Key::CoursesLearningHomeTitle).to_string(),
        "/learning",
        None,
        None,
        palette,
        cx,
    ));
    rows.push(tree_section_row(
        "participations",
        translate(language, Key::EventsParticipationsTitle).to_string(),
        "/participations",
        None,
        None,
        palette,
        cx,
    ));
    div()
        .flex()
        .flex_col()
        .gap(px(1.0))
        .children(rows)
        .into_any_element()
}

fn tree_issue_row(
    issue: &cgc_courses::outline::OutlineIssue,
    palette: &theme::Palette,
    course_id: &str,
    active_issue: Option<&str>,
    cx: &mut Context<RootView>,
) -> AnyElement {
    let issue_id = issue.id.clone();
    let title = issue.title.clone();
    let course_id = course_id.to_string();
    let is_active = active_issue == Some(issue.id.as_str());
    div()
        .id(SharedString::from(format!(
            "site-issue-{course_id}-{}",
            issue.id
        )))
        .flex()
        .flex_row()
        .items_center()
        .pl(px(36.0))
        .pr(space(1))
        .py(px(2.0))
        .rounded(px(RADIUS_SMALL))
        .bg(if is_active {
            palette.soft
        } else {
            palette.view
        })
        .hover(|style| style.bg(palette.soft))
        .child(div().flex_1().child(title.clone()))
        .on_click(cx.listener(move |this, _, _, cx| {
            this.open_issue_tab(&course_id, &issue_id, title.clone(), cx);
        }))
        .into_any_element()
}

fn tree_section_row(
    id: &str,
    label: String,
    path: &'static str,
    expanded: Option<bool>,
    section: Option<SiteTreeSection>,
    palette: &theme::Palette,
    cx: &mut Context<RootView>,
) -> AnyElement {
    let title = label.clone();
    let mut row = div()
        .id(SharedString::from(format!("site-tree-{id}")))
        .flex()
        .flex_row()
        .items_center()
        .gap(px(3.0))
        .px(space(1))
        .py(px(3.0))
        .rounded(px(RADIUS_SMALL))
        .hover(|style| style.bg(palette.soft));
    if let (Some(expanded), Some(section)) = (expanded, section) {
        let section_for_click = section;
        row = row.child(
            div()
                .id(SharedString::from(format!("site-tree-chevron-{id}")))
                .w(px(12.0))
                .flex()
                .items_center()
                .justify_center()
                .text_size(px(10.0))
                .text_color(palette.ink_3)
                .child(if expanded { "▾" } else { "▸" })
                .on_click(cx.listener(move |this, _, _, cx| {
                    cx.stop_propagation();
                    this.toggle_site_tree_section(section_for_click, cx);
                })),
        );
    } else {
        row = row.child(div().w(px(12.0)));
    }
    row.child(div().flex_1().child(label))
        .on_click(cx.listener(move |this, _, _, cx| {
            this.open_page_tab(path, title.clone(), cx);
        }))
        .into_any_element()
}

fn tree_leaf_row(
    id: &str,
    title: String,
    path: &str,
    palette: &theme::Palette,
    cx: &mut Context<RootView>,
) -> AnyElement {
    let title_for_click = title.clone();
    let path = path.to_string();
    div()
        .id(SharedString::from(id.to_string()))
        .flex()
        .flex_row()
        .items_center()
        .pl(px(24.0))
        .pr(space(1))
        .py(px(3.0))
        .rounded(px(RADIUS_SMALL))
        .hover(|style| style.bg(palette.soft))
        .child(div().flex_1().child(title))
        .on_click(cx.listener(move |this, _, _, cx| {
            this.open_page_tab(&path, title_for_click.clone(), cx);
        }))
        .into_any_element()
}

fn render_outline(
    ctx: &mut ScreenContext<'_>,
    language: Language,
    palette: &theme::Palette,
    cx: &mut Context<RootView>,
) -> AnyElement {
    let is_learning = ctx
        .current
        .as_ref()
        .is_some_and(|route_match| route_match.route.id == "courses.learning");
    let content = ctx.content.content().cloned();
    let Some(content) = content else {
        return empty_outline(language, palette);
    };
    if !is_learning {
        return empty_outline(language, palette);
    }

    let outline = build_outline(&content.document);
    let projection = ctx.projection.projection().cloned();
    let course_id = content.course_id.clone();
    let active_issue = ctx.active_tab.as_deref().and_then(|active| {
        ctx.tabs
            .iter()
            .find(|tab| tab.id == active)
            .and_then(|tab| tab.issue_id.clone())
    });
    let mut rows = Vec::new();
    rows.push(
        div()
            .px(space(1))
            .py(px(3.0))
            .text_color(palette.ink)
            .child(content.title.clone())
            .into_any_element(),
    );
    if let Some(progress) = projection
        .as_ref()
        .and_then(|projection| projection.progress.as_ref())
    {
        let percent = if progress.total_required > 0 {
            progress.mastered_required as f32 / progress.total_required as f32 * 100.0
        } else {
            0.0
        };
        rows.push(
            div()
                .px(space(1))
                .pb(px(3.0))
                .flex()
                .flex_col()
                .gap(px(3.0))
                .text_size(px(10.0))
                .text_color(palette.ink_3)
                .child(format!(
                    "进度 {}/{}",
                    progress.mastered_required, progress.total_required
                ))
                .child(
                    Progress::new("outline-course-progress")
                        .value(percent)
                        .with_size(gpui_kit::component::Size::XSmall),
                )
                .into_any_element(),
        );
    }
    if let Some(next) = projection
        .as_ref()
        .and_then(|projection| projection.next_action.as_ref())
    {
        rows.push(
            div()
                .px(space(1))
                .pb(px(3.0))
                .text_size(px(10.0))
                .text_color(palette.accent)
                .child(format!("下一步：{}", next.reason))
                .into_any_element(),
        );
    }
    if outline.is_empty() {
        rows.push(
            div()
                .px(space(1))
                .py(px(3.0))
                .text_color(palette.ink_3)
                .child(translate(language, Key::CoursesLearningContentEmpty))
                .into_any_element(),
        );
    }
    for chapter in &outline.chapters {
        rows.push(
            div()
                .px(space(1))
                .pt(space(1))
                .text_color(palette.ink_3)
                .child(chapter.title.clone())
                .into_any_element(),
        );
        for issue in &chapter.issues {
            rows.push(outline_issue_row(
                issue,
                palette,
                &course_id,
                active_issue.as_deref(),
                cx,
            ));
        }
    }
    if !outline.ungrouped.is_empty() {
        rows.push(
            div()
                .px(space(1))
                .pt(space(1))
                .text_color(palette.ink_3)
                .child(translate(language, Key::CoursesLearningUngrouped))
                .into_any_element(),
        );
        for issue in &outline.ungrouped {
            rows.push(outline_issue_row(
                issue,
                palette,
                &course_id,
                active_issue.as_deref(),
                cx,
            ));
        }
    }
    div()
        .flex()
        .flex_col()
        .gap(px(1.0))
        .children(rows)
        .into_any_element()
}

fn empty_outline(language: Language, palette: &theme::Palette) -> AnyElement {
    div()
        .p(space(1))
        .text_color(palette.ink_3)
        .child(translate(language, Key::CoursesLearningContextRequired))
        .into_any_element()
}

fn outline_issue_row(
    issue: &cgc_courses::outline::OutlineIssue,
    palette: &theme::Palette,
    course_id: &str,
    active_issue: Option<&str>,
    cx: &mut Context<RootView>,
) -> AnyElement {
    let issue_id = issue.id.clone();
    let title = issue.title.clone();
    let course_id = course_id.to_string();
    let is_active = active_issue == Some(issue.id.as_str());
    let mut row = div()
        .id(SharedString::from(format!("outline-issue-{}", issue.id)))
        .flex()
        .flex_col()
        .gap(px(1.0))
        .px(space(1))
        .py(px(3.0))
        .rounded(px(RADIUS_SMALL))
        .bg(if is_active {
            palette.soft
        } else {
            palette.view
        })
        .hover(|style| style.bg(palette.soft))
        .child(div().text_size(px(12.0)).child(title.clone()))
        .on_click(cx.listener(move |this, _, _, cx| {
            this.open_issue_tab(&course_id, &issue_id, title.clone(), cx);
        }));
    if let Some(goal) = issue.goal.clone() {
        row = row.child(
            div()
                .text_size(px(10.0))
                .text_color(palette.ink_3)
                .child(goal),
        );
    }
    row.into_any_element()
}
