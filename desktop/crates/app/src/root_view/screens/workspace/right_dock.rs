//! 右侧 Dock：Site Tree 与 Contextual Outline 互斥显示。
//!
//! 当前只做导航投影；数据加载仍由 controller 持有。完整实例树的懒加载、
//! 搜索与记忆在后续单元补齐。

use super::super::super::*;
use super::super::ScreenContext;
use crate::notification_center::{filtered_items, format_time, NotificationFilter};
use cgc_courses::outline::build_outline;
use gpui_kit::component::empty::{Empty, EmptyDescription, EmptyHeader, EmptyTitle};
use gpui_kit::component::progress::Progress;
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::skeleton::Skeleton;
use gpui_kit::component::spinner::Spinner;

pub(in crate::root_view) fn render_right_dock(
    ctx: &mut ScreenContext<'_>,
    language: Language,
    palette: &theme::Palette,
    window: &mut Window,
    cx: &mut Context<RootView>,
) -> AnyElement {
    let panel = ctx.right_panel;
    let width = ctx.right_panel_width;
    if panel == RightPanel::Notifications {
        return render_notifications_dock(ctx, language, palette, width, cx);
    }
    let title = match panel {
        RightPanel::SiteTree => translate(language, Key::WorkspaceSiteTreeTitle),
        RightPanel::Outline => translate(language, Key::WorkspaceOutlineTitle),
        RightPanel::Notifications => translate(language, Key::AppNotificationsTitle),
    };
    let icon = match panel {
        RightPanel::SiteTree => AssetIcon::FolderOpen,
        RightPanel::Outline => AssetIcon::FileText,
        RightPanel::Notifications => AssetIcon::Bell,
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
        RightPanel::SiteTree => render_site_tree(ctx, language, palette, window, cx),
        RightPanel::Outline => render_outline(ctx, language, palette, cx),
        RightPanel::Notifications => unreachable!(),
    };

    let header = (panel == RightPanel::Outline).then(|| {
        div()
            .id("right-dock-header")
            .role(Role::Toolbar)
            .aria_label(title)
            .flex()
            .flex_row()
            .items_center()
            .gap(px(6.0))
            .px(space(2))
            .h(px(COLUMN_HEADER_HEIGHT))
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
        .bg(if panel == RightPanel::SiteTree {
            palette.frame
        } else {
            palette.canvas
        })
        .children(header)
        .child(
            div()
                .id("right-dock-body")
                .flex_1()
                .min_h(px(0.0))
                .overflow_y_scroll()
                .track_scroll(&ctx.site_tree_scroll)
                .on_scroll(cx.listener(|_this, _, _, cx| {
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
                .p(if panel == RightPanel::SiteTree {
                    px(0.0)
                } else {
                    space(1)
                })
                .text_size(px(12.0))
                .text_color(palette.ink_2)
                .child(body),
        )
        .into_any_element()
}

fn render_notifications_dock(
    ctx: &mut ScreenContext<'_>,
    language: Language,
    palette: &theme::Palette,
    width: f32,
    cx: &mut Context<RootView>,
) -> AnyElement {
    use gpui_kit::component::button::{Button, ButtonVariants};

    let unread = crate::notification_center::unread_count(&ctx.notification_items);
    let filter = ctx.notification_filter;
    let loading = ctx.notification_loading;
    let error = ctx.notification_error.clone();
    let has_more = ctx.notification_next_cursor.is_some();
    let items = filtered_items(&ctx.notification_items, filter);
    let scroll = ctx.notification_scroll.clone();

    let header = div()
        .id("notifications-header")
        .role(Role::Toolbar)
        .aria_label(translate(language, Key::AppNotificationsTitle))
        .flex()
        .flex_row()
        .items_center()
        .justify_between()
        .gap(px(6.0))
        .px(space(2))
        .h(px(COLUMN_HEADER_HEIGHT))
        .border_b_1()
        .border_color(palette.line)
        .child(
            div()
                .flex()
                .flex_col()
                .gap(px(1.0))
                .child(
                    div()
                        .text_size(px(12.0))
                        .text_color(palette.ink)
                        .child(translate(language, Key::AppNotificationsTitle)),
                )
                .child(
                    div()
                        .text_size(px(10.0))
                        .text_color(if unread > 0 {
                            palette.accent
                        } else {
                            palette.ink_3
                        })
                        .child(
                            translate(language, Key::AppNotificationsUnreadCount)
                                .replace("{count}", &unread.to_string()),
                        ),
                ),
        )
        .child({
            let root = cx.entity().downgrade();
            Button::new("notifications-refresh")
                .xsmall()
                .ghost()
                .icon(
                    Icon::default()
                        .path(AssetIcon::RefreshCw.path())
                        .text_color(palette.ink_3)
                        .small(),
                )
                .accessibility_label(translate(language, Key::AppNotificationsRefresh))
                .tooltip(translate(language, Key::AppNotificationsRefresh))
                .loading(loading)
                .on_click(move |_, _, cx| {
                    let _ = root.update(cx, |this, cx| this.refresh_notifications(cx));
                })
        });

    let filters = div()
        .flex()
        .flex_row()
        .items_center()
        .gap(px(4.0))
        .px(space(2))
        .py(px(6.0))
        .border_b_1()
        .border_color(palette.line)
        .children(
            [NotificationFilter::All, NotificationFilter::Unread].map(|filter| {
                let root = cx.entity().downgrade();
                let label = match filter {
                    NotificationFilter::All => translate(language, Key::AppNotificationsAll),
                    NotificationFilter::Unread => translate(language, Key::AppNotificationsUnread),
                };
                let mut button = Button::new(match filter {
                    NotificationFilter::All => "notifications-filter-all",
                    NotificationFilter::Unread => "notifications-filter-unread",
                })
                .xsmall()
                .label(label);
                button = if filter == ctx.notification_filter {
                    button.primary()
                } else {
                    button.ghost()
                };
                button.on_click(move |_, _, cx| {
                    let _ = root.update(cx, |this, cx| {
                        this.set_notification_filter(filter, cx);
                    });
                })
            }),
        );

    let content = if let Some(error) = error {
        div()
            .flex()
            .flex_col()
            .items_center()
            .gap(space(2))
            .p(space(3))
            .child(
                div()
                    .text_size(px(11.0))
                    .text_color(palette.danger)
                    .child(translate(language, Key::AppNotificationsFailed)),
            )
            .child(
                div()
                    .text_size(px(10.0))
                    .text_color(palette.ink_3)
                    .child(error),
            )
            .child({
                let root = cx.entity().downgrade();
                Button::new("notifications-retry")
                    .xsmall()
                    .label(translate(language, Key::AppNotificationsRetry))
                    .on_click(move |_, _, cx| {
                        let _ = root.update(cx, |this, cx| this.refresh_notifications(cx));
                    })
            })
            .into_any_element()
    } else if (loading || !ctx.notification_loaded) && ctx.notification_items.is_empty() {
        div()
            .flex()
            .flex_col()
            .gap(space(1))
            .p(space(2))
            .children((0..3).map(|index| {
                Skeleton::new()
                    .h(px(if index == 0 { 44.0 } else { 36.0 }))
                    .w_full()
                    .into_any_element()
            }))
            .into_any_element()
    } else if items.is_empty() {
        Empty::new()
            .header(
                EmptyHeader::new()
                    .title(
                        EmptyTitle::new().child(if filter == NotificationFilter::Unread {
                            translate(language, Key::AppNotificationsEmptyUnread)
                        } else {
                            translate(language, Key::AppNotificationsEmpty)
                        }),
                    )
                    .description(
                        EmptyDescription::new()
                            .child(translate(language, Key::AppNotificationsEmptyHint)),
                    ),
            )
            .into_any_element()
    } else {
        let rows = items
            .iter()
            .map(|item| {
                let id = item.id.clone();
                let read = item.read_at.is_some();
                let root = cx.entity().downgrade();
                div()
                    .id(SharedString::from(format!("notification-row-{}", item.id)))
                    .flex()
                    .flex_col()
                    .gap(px(2.0))
                    .px(space(2))
                    .py(space(1))
                    .border_b_1()
                    .border_color(palette.line)
                    .bg(if read { palette.view } else { palette.card })
                    .hover(|style| style.bg(palette.soft))
                    .child(
                        div()
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap(px(5.0))
                            .child(div().size(px(5.0)).rounded_full().bg(if read {
                                palette.ink_3
                            } else {
                                palette.accent
                            }))
                            .child(
                                div()
                                    .flex_1()
                                    .min_w(px(0.0))
                                    .truncate()
                                    .text_size(px(11.0))
                                    .text_color(if read { palette.ink_2 } else { palette.ink })
                                    .child(item.title.clone()),
                            )
                            .child(
                                div()
                                    .flex_none()
                                    .text_size(px(9.0))
                                    .text_color(palette.ink_3)
                                    .child(format_time(&item.inserted_at)),
                            ),
                    )
                    .child(
                        div()
                            .pl(px(10.0))
                            .truncate()
                            .text_size(px(10.0))
                            .text_color(palette.ink_3)
                            .child(item.body.clone()),
                    )
                    .on_click(move |_, _, cx| {
                        let _ = root.update(cx, |this, cx| this.open_notification(&id, cx));
                    })
                    .into_any_element()
            })
            .collect::<Vec<_>>();
        let mut list = div()
            .flex()
            .flex_col()
            .w_full()
            .id("notification-list")
            .children(rows);
        if loading {
            list = list.child(
                div()
                    .flex()
                    .items_center()
                    .justify_center()
                    .py(space(1))
                    .child(Spinner::new().with_size(gpui_kit::component::Size::Small)),
            );
        }
        list.into_any_element()
    };

    let footer = has_more.then(|| {
        let root = cx.entity().downgrade();
        div()
            .flex()
            .justify_center()
            .p(space(1))
            .border_t_1()
            .border_color(palette.line)
            .child(
                Button::new("notifications-load-more")
                    .xsmall()
                    .ghost()
                    .label(translate(language, Key::AppNotificationsLoadMore))
                    .on_click(move |_, _, cx| {
                        let _ = root.update(cx, |this, cx| this.load_more_notifications(cx));
                    }),
            )
    });

    div()
        .id("notifications-dock")
        .w(px(width))
        .flex_none()
        .h_full()
        .flex()
        .flex_col()
        .min_h(px(0.0))
        .bg(palette.canvas)
        .child(header)
        .child(filters)
        .child(
            div()
                .id("notifications-scroll")
                .flex_1()
                .min_h(px(0.0))
                .overflow_y_scroll()
                .track_scroll(&scroll)
                .vertical_scrollbar(&scroll)
                .child(content),
        )
        .children(footer)
        .into_any_element()
}

fn render_site_tree(
    ctx: &mut ScreenContext<'_>,
    language: Language,
    palette: &theme::Palette,
    window: &mut Window,
    cx: &mut Context<RootView>,
) -> AnyElement {
    use gpui_kit::component::button::{Button, ButtonVariants};
    use gpui_kit::component::sidebar::{Sidebar, SidebarCollapsible, SidebarMenuItem};

    let workspace = ctx
        .workspaces
        .current()
        .map(|workspace| workspace.name.clone())
        .unwrap_or_else(|| "Workspace".to_string());
    // 工作区面节点只在有当前工作区时出现；站点级两组始终可见。
    let workspace_slug = ctx
        .workspaces
        .current()
        .map(|workspace| workspace.slug.clone());
    let events_open = ctx.site_tree_events_open;
    let courses_open = ctx.site_tree_courses_open;
    let search = render_site_tree_search(ctx, language, window, cx);
    let query = ctx
        .site_tree_search_input
        .as_ref()
        .expect("initialized search")
        .read(cx)
        .value()
        .trim()
        .to_lowercase();
    let matches_query = |title: &str| query.is_empty() || title.to_lowercase().contains(&query);
    let course_outline = ctx
        .content
        .content()
        .filter(|content| {
            ctx.course_enrollments
                .get(&content.course_id)
                .and_then(Option::as_deref)
                == Some("confirmed")
        })
        .map(|content| (content.course_id.clone(), build_outline(&content.document)));
    let outline_matches_course = |id: &str| {
        course_outline
            .as_ref()
            .filter(|(course_id, _)| course_id == id)
            .is_some_and(|(_, outline)| {
                outline.chapters.iter().any(|chapter| {
                    matches_query(&chapter.title)
                        || chapter
                            .issues
                            .iter()
                            .any(|issue| matches_query(&issue.title))
                }) || outline
                    .ungrouped
                    .iter()
                    .any(|issue| matches_query(&issue.title))
            })
    };
    // R5：树只读当前工作区的数据面。中心列表是 Public 缓存时，被动浏览公开目录
    // 也不能在树里短暂显示公开条目；等 ensure_navigation_data 切回 Workspace 再渲染。
    let events_scope_is_workspace = ctx.events_scope == Some(crate::routing::ListScope::Workspace);
    let events = if events_scope_is_workspace {
        ctx.events
            .items()
            .iter()
            .filter(|event| matches_query(&event.title))
            .map(|event| (event.id.clone(), event.title.clone()))
            .collect::<Vec<_>>()
    } else {
        Vec::new()
    };
    let show_unenrolled = ctx.display_preferences.dock_show_unenrolled;
    let courses_scope_is_workspace =
        ctx.courses_scope == Some(crate::routing::ListScope::Workspace);
    let courses = if courses_scope_is_workspace {
        ctx.courses
            .items()
            .iter()
            .filter(|course| matches_query(&course.title) || outline_matches_course(&course.id))
            .filter(|course| {
                show_unenrolled
                    || ctx
                        .course_enrollments
                        .get(&course.id)
                        .is_none_or(Option::is_some)
            })
            .map(|course| (course.id.clone(), course.title.clone()))
            .collect::<Vec<_>>()
    } else {
        Vec::new()
    };
    let show_events = events_open || !query.is_empty();
    let show_courses = courses_open || !query.is_empty();
    let search_events_empty = events.is_empty();
    let search_courses_empty = courses.is_empty();
    let expanded_course = ctx.site_tree_course_open.clone();
    let active_course = ctx
        .current
        .as_ref()
        .filter(|route_match| route_match.route.id.starts_with("courses."))
        .and_then(|route_match| route_match.params.get("id"))
        .cloned();
    let active_issue = ctx
        .current
        .as_ref()
        .and_then(|route_match| route_match.query.get("issue").cloned());
    let active_path = ctx
        .current
        .as_ref()
        .map(|route_match| {
            let mut path = route_match.route.path.to_string();
            for (key, value) in &route_match.params {
                path = path.replace(&format!(":{key}"), value);
            }
            crate::routing::path_with_query(&path, &route_match.query)
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
        .child(search)
        .w_full()
        .into_any_element();

    let mut items: Vec<SidebarMenuItem> = Vec::new();
    let group_heading = |key: Key| {
        let label = translate(language, key).to_string();
        SidebarMenuItem::new(label.clone())
            .accessibility_label(label)
            .pl(px(8.0))
    };

    if let Some(workspace_slug) = &workspace_slug {
        let overview_path = crate::routing::workspace_path(workspace_slug, "");
        let events_path = crate::routing::workspace_path(workspace_slug, "/events");
        let courses_path = crate::routing::workspace_path(workspace_slug, "/courses");
        items.push(group_heading(Key::NavGroupWorkspace));
        let root_overview = cx.entity().downgrade();
        let overview_label = translate(language, Key::AccountWorkspaceOverview).to_string();
        let overview_title = overview_label.clone();
        let overview_open = overview_path.clone();
        items.push(
            SidebarMenuItem::new(overview_label)
                .icon(Icon::default().path(AssetIcon::House.path()).small())
                .active(section_active(&overview_path))
                .on_click(move |_, _, cx| {
                    let _ = root_overview.update(cx, |this, cx| {
                        this.open_page_tab(&overview_open, overview_title.clone(), cx);
                    });
                }),
        );

        let root_agents = cx.entity().downgrade();
        items.push(
            SidebarMenuItem::new(translate(language, Key::NavAgents).to_string())
                .icon(
                    Icon::default()
                        .path(AssetIcon::BotMessageSquare.path())
                        .small(),
                )
                .active(active_path.as_deref() == Some("/agents"))
                .on_click(move |_, _, cx| {
                    let _ = root_agents.update(cx, |this, cx| this.open_agent_registry(cx));
                }),
        );

        let events_open_path = crate::routing::workspace_path(workspace_slug, "/events");
        let root_events = cx.entity().downgrade();
        let mut events_item =
            SidebarMenuItem::new(translate(language, Key::EventsListTitle).to_string())
                .icon(Icon::default().path(AssetIcon::Calendar.path()).small())
                .active(section_active(&events_path))
                .on_click(move |_, _, cx| {
                    let path = events_open_path.clone();
                    let _ = root_events.update(cx, |this, cx| {
                        this.toggle_site_tree_section(SiteTreeSection::Events, cx);
                        this.open_page_tab(
                            &path,
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
                    .accessibility_label(format!(
                        "{} {}",
                        if expanded {
                            translate(language, Key::AppA11yCollapse)
                        } else {
                            translate(language, Key::AppA11yExpand)
                        },
                        translate(language, Key::EventsListTitle)
                    ))
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
                let path = crate::routing::workspace_path(workspace_slug, &format!("/events/{id}"));
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
            if events_scope_is_workspace && ctx.events.has_more() {
                let root = cx.entity().downgrade();
                items.push(SidebarMenuItem::new("加载更多活动").pl(px(16.0)).on_click(
                    move |_, _, cx| {
                        let _ = root.update(cx, |this, cx| {
                            this.start_events_load_with_scope(
                                cx,
                                false,
                                crate::routing::ListScope::Workspace,
                            )
                        });
                    },
                ));
            }
        }

        let courses_open_path = crate::routing::workspace_path(workspace_slug, "/courses");
        let root_courses = cx.entity().downgrade();
        let mut courses_item =
            SidebarMenuItem::new(translate(language, Key::CoursesCatalogTitle).to_string())
                .icon(Icon::default().path(AssetIcon::BookOpen.path()).small())
                .active(section_active(&courses_path))
                .on_click(move |_, _, cx| {
                    let path = courses_open_path.clone();
                    let _ = root_courses.update(cx, |this, cx| {
                        this.toggle_site_tree_section(SiteTreeSection::Courses, cx);
                        this.open_page_tab(
                            &path,
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
                    .accessibility_label(format!(
                        "{} {}",
                        if expanded {
                            translate(language, Key::AppA11yCollapse)
                        } else {
                            translate(language, Key::AppA11yExpand)
                        },
                        translate(language, Key::CoursesCatalogTitle)
                    ))
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
                let path =
                    crate::routing::workspace_path(workspace_slug, &format!("/courses/{id}"));
                let active = active_course.as_deref() == Some(id.as_str())
                    || active_path.as_deref().is_some_and(|active| {
                        active == path || active.starts_with(&format!("{path}/"))
                    });
                let course_matches = matches_query(&title);
                let is_expanded = expanded_course.as_deref() == Some(id.as_str())
                    || (!query.is_empty() && outline_matches_course(&id));
                let click_course_id = course_id.clone();
                let chevron_label = format!(
                    "{} {title}",
                    if is_expanded {
                        translate(language, Key::AppA11yCollapse)
                    } else {
                        translate(language, Key::AppA11yExpand)
                    }
                );
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
                        .accessibility_label(chevron_label.clone())
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
                    let enrolled = ctx.course_enrollments.get(&id).and_then(Option::as_deref)
                        == Some("confirmed");
                    if !enrolled {
                        items.push(
                            SidebarMenuItem::new(
                                translate(language, Key::CoursesSiteTreeEnrollToUnlock).to_string(),
                            )
                            .disable(true)
                            .pl(px(28.0))
                            .border_l_1()
                            .border_color(palette.line),
                        );
                    } else if let Some((_, outline)) = course_outline
                        .as_ref()
                        .filter(|(course_id, _)| course_id == &id)
                    {
                        let groups = outline
                            .chapters
                            .iter()
                            .map(|chapter| {
                                (Some(chapter.title.as_str()), chapter.issues.as_slice())
                            })
                            .chain(std::iter::once((None, outline.ungrouped.as_slice())));
                        for (chapter_title, issues) in groups {
                            let chapter_matches =
                                course_matches || chapter_title.is_some_and(matches_query);
                            let chapter_visible = chapter_matches
                                || issues.iter().any(|issue| matches_query(&issue.title));
                            if !chapter_visible {
                                continue;
                            }
                            if let Some(title) = chapter_title {
                                items.push(
                                    SidebarMenuItem::new(title.to_string())
                                        .disable(true)
                                        .pl(px(28.0))
                                        .border_l_1()
                                        .border_color(palette.line),
                                );
                            }
                            for issue in issues {
                                if !chapter_matches && !matches_query(&issue.title) {
                                    continue;
                                }
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
            if courses_scope_is_workspace && ctx.courses.has_more() {
                items.push(SidebarMenuItem::new("加载更多课程").pl(px(16.0)).on_click(
                    move |_, _, cx| {
                        let _ = root.update(cx, |this, cx| {
                            this.start_courses_load_with_scope(
                                cx,
                                false,
                                crate::routing::ListScope::Workspace,
                            )
                        });
                    },
                ));
            }
            if !query.is_empty() && search_events_empty && search_courses_empty {
                items.push(
                    SidebarMenuItem::new(translate(language, Key::NavSiteTreeEmpty).to_string())
                        .disable(true)
                        .pl(px(8.0)),
                );
            }
        }
    }

    items.push(group_heading(Key::NavGroupMine));
    for spec in crate::root_view::nav_copy::SITE_TREE_MINE {
        let root = cx.entity().downgrade();
        let title = translate(language, spec.key).to_string();
        let path = spec.path.to_string();
        items.push(
            SidebarMenuItem::new(title.clone())
                .icon(Icon::default().path(spec.icon.path()).small())
                .active(section_active(spec.path))
                .on_click(move |_, _, cx| {
                    let _ = root.update(cx, |this, cx| {
                        this.open_page_tab(&path, title.clone(), cx);
                    });
                }),
        );
    }

    items.push(group_heading(Key::NavGroupCommunity));
    for spec in crate::root_view::nav_copy::SITE_TREE_COMMUNITY {
        let root = cx.entity().downgrade();
        let title = translate(language, spec.key).to_string();
        let path = spec.path.to_string();
        items.push(
            SidebarMenuItem::new(title.clone())
                .icon(Icon::default().path(spec.icon.path()).small())
                .active(section_active(spec.path))
                .on_click(move |_, _, cx| {
                    let _ = root.update(cx, |this, cx| {
                        this.open_page_tab(&path, title.clone(), cx);
                    });
                }),
        );
    }

    Sidebar::new("site-tree-sidebar")
        .side(gpui_kit::component::Side::Right)
        .collapsible(SidebarCollapsible::None)
        .header(header)
        .children(items)
        .w_full()
        .border_l_0()
        .bg(palette.frame)
        .into_any_element()
}

fn render_site_tree_search(
    ctx: &mut ScreenContext<'_>,
    language: Language,
    window: &mut Window,
    cx: &mut Context<RootView>,
) -> AnyElement {
    use gpui_kit::component::input::{Input, InputEvent, InputState};

    if ctx.site_tree_search_input.is_none() {
        let value = ctx.site_tree_query.clone();
        let input = cx.new(|cx| InputState::new(window, cx).default_value(value));
        ctx.site_tree_search_subscription =
            Some(
                cx.subscribe_in(&input, window, |this, input, event: &InputEvent, _, cx| {
                    match event {
                        InputEvent::Change => {
                            this.site_tree_query = input.read(cx).value().to_string();
                            if !this.site_tree_query.trim().is_empty() {
                                this.ensure_navigation_data(cx);
                            }
                        }
                        InputEvent::Focus => this.site_tree_search_focused = true,
                        InputEvent::Blur => this.site_tree_search_focused = false,
                        _ => return,
                    }
                    cx.notify();
                }),
            );
        ctx.site_tree_search_input = Some(input);
    }
    let input = ctx
        .site_tree_search_input
        .as_ref()
        .expect("initialized search")
        .clone();
    if ctx.site_tree_search_language != Some(language) {
        input.update(cx, |state, cx| {
            state.set_placeholder(translate(language, Key::NavSiteTreeSearch), window, cx);
        });
        ctx.site_tree_search_language = Some(language);
    }
    div()
        .id("site-tree-search")
        .test_support()
        .mx(space(1))
        .mb(px(2.0))
        .child(Input::new(&input).small())
        .into_any_element()
}

fn render_outline(
    ctx: &mut ScreenContext<'_>,
    language: Language,
    palette: &theme::Palette,
    cx: &mut Context<RootView>,
) -> AnyElement {
    let is_learning = ctx.current.as_ref().is_some_and(|route_match| {
        matches!(
            route_match.route.id,
            "courses.learning" | "courses.public_learning"
        )
    });
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
    let active_issue = ctx
        .current
        .as_ref()
        .and_then(|route_match| route_match.query.get("issue").cloned());
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
