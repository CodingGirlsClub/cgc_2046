use super::state::PaneTab;
use super::*;
use crate::root_view::screens::workspace::outline_tree::issue_node_id;

impl RootView {
    /// 课程归属与路由 slug 不一致（深链/旧地址）时把地址收敛到课程所属工作区，
    /// 保证路由、tab 与 Agent 上下文只有一个归属。
    pub(in crate::root_view) fn canonicalize_course_route(
        &mut self,
        detail: &cgc_courses::catalog::CourseDetail,
    ) {
        let Some(owner) = detail.workspace_id.as_deref().and_then(|id| {
            self.workspaces
                .workspaces()
                .iter()
                .find(|workspace| workspace.id == id && workspace.can_access)
        }) else {
            return;
        };
        let Some((suffix, query, route_slug)) = self.current.as_ref().and_then(|route_match| {
            let route_slug = route_match.params.get("slug")?.clone();
            let suffix = match route_match.route.id {
                "courses.learning" | "courses.public_learning" => {
                    format!("/courses/{}/learn", detail.id)
                }
                "courses.detail" | "courses.public_detail" => {
                    format!("/courses/{}", detail.id)
                }
                _ => return None,
            };
            Some((suffix, route_match.query.clone(), route_slug))
        }) else {
            return;
        };
        // 站点级公开页没有 slug，保持公开地址不动。
        if route_slug == owner.slug {
            return;
        }
        let target = crate::routing::path_with_query(
            &crate::routing::workspace_path(&owner.slug, &suffix),
            &query,
        );
        if self.current_path().as_deref() == Some(target.as_str()) {
            return;
        }
        // 纠偏只改路由：目标台的 tab 由目标台自己的 tab 生命周期插入并持久化。
        // 在这里改写当前 tab 会把目标台路径写进**源台**的 tab 桶（R10）。
        self.navigate(&target);
    }

    pub(in crate::root_view) fn navigate_to_learning(
        &mut self,
        course_id: &str,
        workspace_id: Option<&str>,
        cx: &mut Context<Self>,
    ) {
        let path = crate::routing::offering_path(
            self.workspaces.workspaces(),
            workspace_id,
            &format!("/courses/{course_id}/learn"),
        );
        let title = self
            .courses
            .items()
            .iter()
            .find(|course| course.id == course_id)
            .map(|course| format!("{} · 学习", course.title))
            .unwrap_or_else(|| "学习".to_string());
        self.open_page_tab(&path, title, cx);
    }

    /// 从 Site Tree 打开页面：同一个 path 只保留一个 Tab，并激活它。
    pub(in crate::root_view) fn open_page_tab(
        &mut self,
        path: &str,
        title: impl Into<String>,
        cx: &mut Context<Self>,
    ) {
        let tab = PaneTab::page(path, title);
        self.open_tab(tab, cx);
    }

    /// 从 Outline / Site Tree 打开 issue 卡；同一门课同一张卡只保留一个 Tab。
    pub(in crate::root_view) fn open_issue_tab(
        &mut self,
        course_id: &str,
        issue_id: &str,
        title: impl Into<String>,
        cx: &mut Context<Self>,
    ) {
        let workspace_id = self
            .course_detail
            .detail()
            .filter(|detail| detail.id == course_id)
            .and_then(|detail| detail.workspace_id.as_deref())
            .or_else(|| {
                self.courses
                    .items()
                    .iter()
                    .find(|course| course.id == course_id)
                    .and_then(|course| course.workspace_id.as_deref())
            });
        if let Some(tree) = self.outline_tree.clone() {
            tree.update(cx, |state, cx| {
                state.reveal_item(
                    &SharedString::from(issue_node_id(course_id, issue_id)),
                    gpui_kit::ScrollStrategy::Center,
                    cx,
                );
            });
        }
        let base = crate::routing::offering_path(
            self.workspaces.workspaces(),
            workspace_id,
            &format!("/courses/{course_id}/learn"),
        );
        let Some(path) = crate::routing::path_with_issue(&base, issue_id) else {
            self.open_page_tab(&base, title, cx);
            return;
        };
        self.open_page_tab(&path, title, cx);
    }

    /// 唯一的「插入 tab + 持久化」入口：`navigate()` 只换路由，不插 tab。
    pub(in crate::root_view) fn open_tab(&mut self, tab: PaneTab, cx: &mut Context<Self>) {
        self.site_tree_search_focused = false;
        self.page_context.reset_dismissed();
        self.navigate(&tab.path);
        self.sync_workspace_route(cx);
        self.state.open_tab(tab);
        self.persist_current_workspace_state();
        cx.notify();
    }

    pub(in crate::root_view) fn activate_tab(&mut self, id: &str, cx: &mut Context<Self>) {
        let Some(tab) = self.tabs.iter().find(|tab| tab.id == id).cloned() else {
            return;
        };
        self.active_tab = Some(tab.id.clone());
        self.site_tree_search_focused = false;
        self.page_context.reset_dismissed();
        self.navigate(&tab.path);
        self.persist_current_workspace_state();
        cx.notify();
    }

    pub(in crate::root_view) fn close_pane_tab(&mut self, id: &str, cx: &mut Context<Self>) {
        let was_active = self.active_tab.as_deref() == Some(id);
        if !self.state.close_tab(id) {
            return;
        }
        if was_active {
            match self
                .active_tab
                .as_deref()
                .and_then(|active| self.tabs.iter().find(|tab| tab.id == active))
                .map(|tab| tab.path.clone())
            {
                Some(path) => self.navigate(&path),
                None => match self.workspaces.current() {
                    Some(workspace) => {
                        let path = crate::routing::workspace_path(&workspace.slug, "");
                        self.navigate(&path);
                    }
                    None => self.navigate("/learning"),
                },
            }
        }
        self.persist_current_workspace_state();
        cx.notify();
    }

    pub(in crate::root_view) fn clear_pane_notice(&mut self, cx: &mut Context<Self>) {
        self.pane_notice = None;
        cx.notify();
    }

    /// 当前路由若是学习页上的 issue 卡，返回课程 id 与 issue id。
    pub(in crate::root_view) fn active_issue_tab(&self) -> Option<(&str, &str)> {
        let route_match = self.current.as_ref()?;
        if !matches!(
            route_match.route.id,
            "courses.learning" | "courses.public_learning"
        ) {
            return None;
        }
        let course_id = route_match.params.get("id")?;
        let issue_id = route_match.query.get("issue")?;
        Some((course_id.as_str(), issue_id.as_str()))
    }

    pub(in crate::root_view) fn persist_site_tree_scroll(&mut self, cx: &mut Context<Self>) {
        self.persist_current_workspace_state();
        cx.notify();
    }

    pub(in crate::root_view) fn persist_workspace_layout(&mut self, cx: &mut Context<Self>) {
        self.persist_current_workspace_state();
        cx.notify();
    }

    pub(in crate::root_view) fn persist_current_workspace_state(&mut self) {
        if let Some(workspace_id) = self.workspaces.current_id().map(str::to_string) {
            self.persist_workspace_state(&workspace_id);
        }
    }

    pub(in crate::root_view) fn persist_workspace_state(&mut self, workspace_id: &str) {
        if let Some(slug) = self
            .workspaces
            .workspaces()
            .iter()
            .find(|workspace| workspace.id == workspace_id)
            .map(|workspace| workspace.slug.clone())
        {
            self.last_workspace_slug = Some(slug.clone());
            crate::workspace_state::set_last_workspace(&slug);
        }
        let entry = crate::workspace_state::WorkspaceEntry {
            tabs: self
                .tabs
                .iter()
                .map(|tab| crate::workspace_state::PersistedTab {
                    title: tab.title.clone(),
                    path: tab.path.clone(),
                })
                .collect(),
            active_tab: self.active_tab.clone(),
            site_tree_events_open: self.site_tree_events_open,
            site_tree_courses_open: self.site_tree_courses_open,
            site_tree_query: self.site_tree_query.clone(),
            site_tree_course_open: self.site_tree_course_open.clone(),
            site_tree_scroll_y: self
                .site_tree_scroll_restore
                .unwrap_or_else(|| self.site_tree_scroll.offset().y.as_f32()),
            outline_expanded: self.outline_expanded.iter().cloned().collect(),
            layout: self.workspace_layout_overridden.then_some(
                crate::workspace_state::PanelLayout {
                    right_panel_width: self.right_panel_width,
                    agent_panel_width: self.agent_panel_width,
                    agent_panel_open: self.agent_panel_open,
                    right_panel_open: self.panel_memory.open,
                    right_panel: match self.panel_memory.panel {
                        RightPanel::Outline => crate::workspace_state::PersistedRightPanel::Outline,
                        RightPanel::Notes => crate::workspace_state::PersistedRightPanel::Notes,
                        _ => crate::workspace_state::PersistedRightPanel::SiteTree,
                    },
                },
            ),
        };
        crate::workspace_state::save_entry(workspace_id, entry);
    }

    pub(in crate::root_view) fn restore_workspace_state(
        &mut self,
        cx: &mut Context<Self>,
        keep_route: bool,
    ) {
        let Some(workspace_id) = self.workspaces.current_id().map(str::to_string) else {
            return;
        };
        self.apply_panel_defaults(&crate::preferences::load());
        let Some(entry) = crate::workspace_state::entry(&workspace_id) else {
            cx.notify();
            return;
        };
        if let Some(layout) = entry.layout {
            self.workspace_layout_overridden = true;
            self.agent_panel_open = layout.agent_panel_open;
            self.right_panel_open = layout.right_panel_open;
            self.right_panel = match layout.right_panel {
                crate::workspace_state::PersistedRightPanel::Outline => RightPanel::Outline,
                crate::workspace_state::PersistedRightPanel::Notes => RightPanel::Notes,
                crate::workspace_state::PersistedRightPanel::SiteTree => RightPanel::SiteTree,
            };
            self.panel_memory = state::PanelMemory {
                panel: self.right_panel,
                open: layout.right_panel_open,
            };
            self.right_panel_width = layout.right_panel_width;
            self.agent_panel_width = layout.agent_panel_width;
        }
        self.site_tree_events_open = entry.site_tree_events_open;
        self.site_tree_courses_open = entry.site_tree_courses_open;
        self.site_tree_query = entry.site_tree_query;
        self.site_tree_search_input = None;
        self.site_tree_search_subscription = None;
        self.site_tree_search_language = None;
        self.site_tree_course_open = entry.site_tree_course_open;
        self.site_tree_scroll = ScrollHandle::new();
        self.site_tree_scroll_restore = Some(entry.site_tree_scroll_y);
        self.outline_expanded = entry.outline_expanded.into_iter().collect();
        self.outline_tree = None;
        self.outline_tree_subscription = None;
        self.outline_tree_key = None;
        let stored_tab_count = entry.tabs.len();
        let current_slug = self
            .workspaces
            .current()
            .map(|workspace| workspace.slug.clone());
        self.tabs = entry
            .tabs
            .into_iter()
            .filter(|tab| {
                crate::routing::tab_belongs_to(&tab.path, current_slug.as_deref())
                    && matches!(
                        self.registry.select(&tab.path),
                        crate::routing::RouteSelection::Match(_)
                    )
            })
            .map(|tab| PaneTab::page(&tab.path, tab.title))
            .collect();
        if stored_tab_count > self.tabs.len() {
            self.pane_notice = Some(format!(
                "{} 个失效或不属于当前工作区的标签已清理",
                stored_tab_count - self.tabs.len()
            ));
        }
        self.active_tab = entry
            .active_tab
            .filter(|active| self.tabs.iter().any(|tab| &tab.id == active))
            .or_else(|| self.tabs.first().map(|tab| tab.id.clone()));
        if keep_route {
            // 深链/显式导航目标不因恢复旧 tab 被覆盖；tab 高亮只按当前路径匹配。
            let current_path = self.current_path();
            self.active_tab = current_path.as_deref().and_then(|path| {
                crate::root_view::state::active_tab_for_path(
                    &self.tabs,
                    self.active_tab.as_deref(),
                    path,
                )
            });
        } else if let Some(path) = self
            .active_tab
            .as_deref()
            .and_then(|active| self.tabs.iter().find(|tab| tab.id == active))
            .map(|tab| tab.path.clone())
        {
            self.navigate(&path);
        }
        cx.notify();
    }
}
