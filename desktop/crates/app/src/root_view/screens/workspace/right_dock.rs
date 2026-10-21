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

    let header = (panel == RightPanel::Outline).then(|| {
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
            )
            .into_any_element()
    });

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
        .children(header)
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
    use gpui_kit::component::button::{Button, ButtonVariants};
    use gpui_kit::component::sidebar::{Sidebar, SidebarCollapsible, SidebarMenuItem};

    let workspace = ctx
        .workspaces
        .current()
        .map(|workspace| workspace.name.clone())
        .unwrap_or_else(|| "Workspace".to_string());
    let events_open = ctx.site_tree_events_open;
    let courses_open = ctx.site_tree_courses_open;
    let events = ctx
        .events
        .items()
        .iter()
        .take(20)
        .map(|event| (event.id.clone(), event.title.clone()))
        .collect::<Vec<_>>();
    let courses = ctx
        .courses
        .items()
        .iter()
        .take(20)
        .map(|course| (course.id.clone(), course.title.clone()))
        .collect::<Vec<_>>();
    let show_events = events_open;
    let show_courses = courses_open;
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
    let active_path = ctx
        .current
        .as_ref()
        .map(|route_match| {
            let mut path = route_match.route.path.to_string();
            for (key, value) in &route_match.params {
                path = path.replace(&format!(":{key}"), value);
            }
            path
        })
        .or_else(|| {
            ctx.active_tab.as_deref().and_then(|active| {
                ctx.tabs
                    .iter()
                    .find(|tab| tab.id == active)
                    .map(|tab| tab.path.clone())
            })
        });
    let section_active = |path: &str| {
        active_path.as_deref().is_some_and(|active| {
            active == path
                || (path == "/events" && active.starts_with("/events/"))
                || (path == "/courses" && active.starts_with("/courses/"))
        })
    };

    let header = div()
        .flex()
        .flex_col()
        .gap(px(2.0))
        .child(
            div()
                .px(space(1))
                .py(px(3.0))
                .text_size(px(11.0))
                .text_color(palette.ink_3)
                .child(workspace),
        )
        .w_full()
        .into_any_element();

    let mut items: Vec<SidebarMenuItem> = Vec::new();
    let root_overview = cx.entity().downgrade();
    let overview_label = translate(language, Key::AccountWorkspaceOverview).to_string();
    let overview_title = overview_label.clone();
    items.push(
        SidebarMenuItem::new(overview_label)
            .icon(Icon::default().path(AssetIcon::House.path()).small())
            .active(section_active("/workspace"))
            .on_click(move |_, _, cx| {
                let _ = root_overview.update(cx, |this, cx| {
                    this.open_page_tab("/workspace", overview_title.clone(), cx);
                });
            }),
    );

    let root_events = cx.entity().downgrade();
    let mut events_item =
        SidebarMenuItem::new(translate(language, Key::EventsListTitle).to_string())
            .icon(Icon::default().path(AssetIcon::Calendar.path()).small())
            .active(section_active("/events"))
            .on_click(move |_, _, cx| {
                let _ = root_events.update(cx, |this, cx| {
                    this.toggle_site_tree_section(SiteTreeSection::Events, cx);
                    this.open_page_tab(
                        "/events",
                        translate(language, Key::EventsListTitle).to_string(),
                        cx,
                    );
                });
            });
    let events_chevron = {
        let root = cx.entity().downgrade();
        let expanded = show_events;
        move |_: &mut Window, _: &mut App| {
            let click_root = root.clone();
            Button::new("site-tree-events-chevron")
                .xsmall()
                .ghost()
                .icon(
                    Icon::default()
                        .path(if expanded {
                            AssetIcon::ChevronDown.path()
                        } else {
                            AssetIcon::ChevronRight.path()
                        })
                        .small(),
                )
                .on_click(move |_, _, cx| {
                    cx.stop_propagation();
                    let _ = click_root.update(cx, |this, cx| {
                        this.toggle_site_tree_section(SiteTreeSection::Events, cx);
                    });
                })
                .into_any_element()
        }
    };
    events_item = events_item.suffix(events_chevron);
    items.push(events_item);
    if show_events {
        for (id, title) in events {
            let path = format!("/events/{id}");
            let active = active_path.as_deref() == Some(path.as_str());
            let root = cx.entity().downgrade();
            let page_title = title.clone();
            items.push(
                SidebarMenuItem::new(title)
                    .active(active)
                    .pl(px(16.0))
                    .border_l_1()
                    .border_color(palette.line)
                    .on_click(move |_, _, cx| {
                        let _ = root.update(cx, |this, cx| {
                            this.open_page_tab(&path, page_title.clone(), cx);
                        });
                    }),
            );
        }
        if ctx.events.has_more() {
            let root = cx.entity().downgrade();
            items.push(SidebarMenuItem::new("加载更多活动").pl(px(16.0)).on_click(
                move |_, _, cx| {
                    let _ = root.update(cx, |this, cx| this.start_events_load(cx, false));
                },
            ));
        }
    }

    let root_courses = cx.entity().downgrade();
    let mut courses_item =
        SidebarMenuItem::new(translate(language, Key::CoursesCatalogTitle).to_string())
            .icon(Icon::default().path(AssetIcon::BookOpen.path()).small())
            .active(section_active("/courses"))
            .on_click(move |_, _, cx| {
                let _ = root_courses.update(cx, |this, cx| {
                    this.toggle_site_tree_section(SiteTreeSection::Courses, cx);
                    this.open_page_tab(
                        "/courses",
                        translate(language, Key::CoursesCatalogTitle).to_string(),
                        cx,
                    );
                });
            });
    let courses_chevron = {
        let root = cx.entity().downgrade();
        let expanded = show_courses;
        move |_: &mut Window, _: &mut App| {
            let click_root = root.clone();
            Button::new("site-tree-courses-chevron")
                .xsmall()
                .ghost()
                .icon(
                    Icon::default()
                        .path(if expanded {
                            AssetIcon::ChevronDown.path()
                        } else {
                            AssetIcon::ChevronRight.path()
                        })
                        .small(),
                )
                .on_click(move |_, _, cx| {
                    cx.stop_propagation();
                    let _ = click_root.update(cx, |this, cx| {
                        this.toggle_site_tree_section(SiteTreeSection::Courses, cx);
                    });
                })
                .into_any_element()
        }
    };
    courses_item = courses_item.suffix(courses_chevron);
    items.push(courses_item);
    if show_courses {
        for (id, title) in courses {
            let root = cx.entity().downgrade();
            let course_id = id.clone();
            let path = format!("/courses/{id}");
            let active = active_course.as_deref() == Some(id.as_str())
                || active_path.as_deref().is_some_and(|active| {
                    active == path || active.starts_with(&format!("{path}/"))
                });
            let is_expanded = expanded_course.as_deref() == Some(id.as_str());
            let click_course_id = course_id.clone();
            let chevron = {
                let root = root.clone();
                move |_: &mut Window, _: &mut App| {
                    let root = root.clone();
                    let course_id = course_id.clone();
                    Button::new(SharedString::from(format!(
                        "site-course-chevron-{course_id}"
                    )))
                    .xsmall()
                    .ghost()
                    .icon(
                        Icon::default()
                            .path(if is_expanded {
                                AssetIcon::ChevronDown.path()
                            } else {
                                AssetIcon::ChevronRight.path()
                            })
                            .small(),
                    )
                    .on_click(move |_, _, cx| {
                        cx.stop_propagation();
                        let _ = root.update(cx, |this, cx| {
                            this.toggle_site_tree_course(&course_id, cx);
                        });
                    })
                    .into_any_element()
                }
            };
            let open_path = path.clone();
            let open_title = title.clone();
            let mut course_item = SidebarMenuItem::new(title)
                .active(active)
                .pl(px(16.0))
                .suffix(chevron)
                .on_click(move |_, _, cx| {
                    let _ = root.update(cx, |this, cx| {
                        this.toggle_site_tree_course(&click_course_id, cx);
                        this.open_page_tab(&open_path, open_title.clone(), cx);
                    });
                });
            let _ = &mut course_item;
            items.push(course_item);
            if is_expanded {
                if let Some(content) = course_content
                    .as_ref()
                    .filter(|content| content.course_id == id)
                {
                    let outline = build_outline(&content.document);
                    for chapter in &outline.chapters {
                        items.push(
                            SidebarMenuItem::new(chapter.title.clone())
                                .disable(true)
                                .pl(px(28.0))
                                .border_l_1()
                                .border_color(palette.line),
                        );
                        for issue in &chapter.issues {
                            let root = cx.entity().downgrade();
                            let issue_id = issue.id.clone();
                            let title = issue.title.clone();
                            let active = active_issue.as_deref() == Some(issue_id.as_str());
                            let course_id = id.clone();
                            items.push(
                                SidebarMenuItem::new(title.clone())
                                    .active(active)
                                    .pl(px(36.0))
                                    .border_l_1()
                                    .border_color(palette.line)
                                    .on_click(move |_, _, cx| {
                                        let _ = root.update(cx, |this, cx| {
                                            this.open_issue_tab(
                                                &course_id,
                                                &issue_id,
                                                title.clone(),
                                                cx,
                                            );
                                        });
                                    }),
                            );
                        }
                    }
                }
            }
        }
        let root = cx.entity().downgrade();
        if ctx.courses.has_more() {
            items.push(SidebarMenuItem::new("加载更多课程").pl(px(16.0)).on_click(
                move |_, _, cx| {
                    let _ = root.update(cx, |this, cx| this.start_courses_load(cx, false));
                },
            ));
        }
    }

    let root_learning = cx.entity().downgrade();
    items.push(
        SidebarMenuItem::new(translate(language, Key::CoursesLearningHomeTitle).to_string())
            .icon(
                Icon::default()
                    .path(AssetIcon::GraduationCap.path())
                    .small(),
            )
            .active(section_active("/learning"))
            .on_click(move |_, _, cx| {
                let _ = root_learning.update(cx, |this, cx| {
                    this.open_page_tab(
                        "/learning",
                        translate(language, Key::CoursesLearningHomeTitle).to_string(),
                        cx,
                    );
                });
            }),
    );
    let root_participations = cx.entity().downgrade();
    items.push(
        SidebarMenuItem::new(translate(language, Key::EventsParticipationsTitle).to_string())
            .icon(Icon::default().path(AssetIcon::Ticket.path()).small())
            .active(section_active("/participations"))
            .on_click(move |_, _, cx| {
                let _ = root_participations.update(cx, |this, cx| {
                    this.open_page_tab(
                        "/participations",
                        translate(language, Key::EventsParticipationsTitle).to_string(),
                        cx,
                    );
                });
            }),
    );

    Sidebar::new("site-tree-sidebar")
        .side(gpui_kit::component::Side::Right)
        .collapsible(SidebarCollapsible::None)
        .header(header)
        .children(items)
        .w_full()
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
