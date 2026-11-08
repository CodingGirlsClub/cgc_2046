use super::state::PaneTab;
use super::*;

impl RootView {
    /// 把当前 active tab 的页面身份、正文与版本写入全局上下文。
    /// active tab 与当前路由不一致时不猜上下文，避免把旧 tab 正文送给 Agent。
    pub(in crate::root_view) fn refresh_page_context(&self) {
        let Some(route_match) = self.current.as_ref() else {
            self.page_context.set_current(None);
            return;
        };
        let route_id = route_match.route.id;
        let Some(active_id) = self.active_tab.as_deref() else {
            self.page_context.set_current(None);
            return;
        };
        let Some(tab) = self.tabs.iter().find(|tab| tab.id == active_id).cloned() else {
            self.page_context.set_current(None);
            return;
        };
        if self.current_path().as_deref() != Some(tab.path.as_str()) {
            self.page_context.set_current(None);
            return;
        }
        let mut context = if matches!(
            route_id,
            "courses.learning"
                | "courses.detail"
                | "courses.public_detail"
                | "courses.public_learning"
        ) {
            self.course_page_context(&tab)
        } else {
            Some(self.generic_page_context(&tab, route_id))
        };
        if let Some(context) = &mut context {
            // 工作区单一真源是路由：`/w/<slug>` 决定归属，站点级页面不借用当前台。
            context.workspace_id = self.route_workspace_id();
        }
        self.page_context.set_current(context);
    }

    /// 当前路由 `:slug` 对应的可访问工作区 id；站点级页面返回 None。
    pub(in crate::root_view) fn route_workspace_id(&self) -> Option<String> {
        let slug = self.current.as_ref()?.params.get("slug")?;
        self.workspaces
            .workspaces()
            .iter()
            .find(|workspace| &workspace.slug == slug && workspace.can_access)
            .map(|workspace| workspace.id.clone())
    }

    pub(in crate::root_view) fn current_path(&self) -> Option<String> {
        let route_match = self.current.as_ref()?;
        let mut path = route_match.route.path.to_string();
        for (name, value) in &route_match.params {
            path = path.replace(&format!(":{name}"), value);
        }
        Some(crate::routing::path_with_query(&path, &route_match.query))
    }

    pub(in crate::root_view) fn course_page_context(
        &self,
        tab: &PaneTab,
    ) -> Option<crate::page_context::PageContext> {
        let course_id = self.current.as_ref()?.params.get("id")?;
        let detail = self
            .course_detail
            .detail()
            .filter(|detail| &detail.id == course_id);
        let content = self
            .content
            .content()
            .filter(|content| &content.course_id == course_id);
        let unit = self
            .active_issue_tab()
            .map(|(_, issue_id)| crate::page_context::PageUnit {
                id: issue_id.to_string(),
                title: tab.title.clone(),
            });
        let (body, version) = self
            .active_issue_tab()
            .and_then(|(course_id, issue_id)| {
                self.content
                    .content()
                    .filter(|content| content.course_id == course_id)
                    .and_then(|content| {
                        content
                            .document
                            .issues
                            .iter()
                            .find(|issue| issue.id.as_deref() == Some(issue_id))
                            .map(|issue| {
                                crate::page_context::project_issue(
                                    issue,
                                    content.revision_number,
                                    &tab.id,
                                )
                            })
                    })
            })
            .or_else(|| {
                if self.active_issue_tab().is_some() {
                    return None;
                }
                if matches!(
                    self.current.as_ref()?.route.id,
                    "courses.detail" | "courses.public_detail"
                ) {
                    detail.map(|detail| crate::page_context::project_course_detail(detail, &tab.id))
                } else {
                    content.map(|content| {
                        crate::page_context::project_course_learning(content, &tab.id)
                    })
                }
            })
            .unwrap_or_else(|| {
                if self.current.as_ref().is_some_and(|route| {
                    matches!(route.route.id, "courses.detail" | "courses.public_detail")
                }) {
                    return match self.course_detail.state() {
                        cgc_courses::catalog::CoursesListState::Failed(message) => {
                            Self::failed_context(&tab.id, message)
                        }
                        cgc_courses::catalog::CoursesListState::Empty => (
                            crate::page_context::PageBody::Empty,
                            format!("empty:{}", tab.id),
                        ),
                        _ => Self::loading_context(&tab.id),
                    };
                }
                match self.content.state() {
                    cgc_courses::content::CourseContentState::Failed(message) => {
                        Self::failed_context(&tab.id, message)
                    }
                    cgc_courses::content::CourseContentState::Empty => (
                        crate::page_context::PageBody::Empty,
                        format!("empty:{}", tab.id),
                    ),
                    _ => Self::loading_context(&tab.id),
                }
            });
        Some(crate::page_context::PageContext {
            // 归属由 `refresh_page_context` 按路由统一写入，课程详情不再提供第二真源。
            workspace_id: None,
            tab_id: tab.id.clone(),
            route: tab.path.clone(),
            title: tab.title.clone(),
            version,
            body,
            course: Some(crate::page_context::CourseContext {
                id: course_id.clone(),
                title: detail
                    .map(|detail| detail.title.clone())
                    .or_else(|| content.map(|content| content.title.clone()))
                    .unwrap_or_else(|| tab.title.clone()),
                revision: content
                    .and_then(|content| content.revision_number)
                    .or_else(|| detail.and_then(|detail| detail.revision_number)),
                unit,
            }),
        })
    }

    pub(in crate::root_view) fn loading_context(
        tab_id: &str,
    ) -> (crate::page_context::PageBody, String) {
        (
            crate::page_context::PageBody::Loading,
            format!("loading:{tab_id}"),
        )
    }

    pub(in crate::root_view) fn failed_context(
        tab_id: &str,
        message: &str,
    ) -> (crate::page_context::PageBody, String) {
        (
            crate::page_context::PageBody::Unavailable(message.to_string()),
            format!("failed:{tab_id}:{message}"),
        )
    }

    pub(in crate::root_view) fn generic_page_context(
        &self,
        tab: &PaneTab,
        route_id: &str,
    ) -> crate::page_context::PageContext {
        let (body, version) = match route_id {
            "events.detail" | "events.public_detail" => {
                let event_id = self
                    .current
                    .as_ref()
                    .and_then(|route| route.params.get("id"));
                match self.detail.state() {
                    cgc_events::list::ListState::Ready => self
                        .detail
                        .detail()
                        .filter(|detail| Some(&detail.id) == event_id)
                        .map(|detail| crate::page_context::project_event_detail(detail, &tab.id))
                        .unwrap_or_else(|| Self::loading_context(&tab.id)),
                    cgc_events::list::ListState::Failed(message)
                        if self.detail.event_id() == event_id.map(String::as_str) =>
                    {
                        Self::failed_context(&tab.id, message)
                    }
                    cgc_events::list::ListState::Empty
                        if self.detail.event_id() == event_id.map(String::as_str) =>
                    {
                        (
                            crate::page_context::PageBody::Empty,
                            format!("empty:{}", tab.id),
                        )
                    }
                    _ => Self::loading_context(&tab.id),
                }
            }
            "events.list" | "events.public_list" => {
                if self.events.items().is_empty() {
                    match self.events.state() {
                        cgc_events::list::ListState::Failed(message) => {
                            Self::failed_context(&tab.id, message)
                        }
                        cgc_events::list::ListState::Empty => (
                            crate::page_context::PageBody::Empty,
                            format!("empty:{}", tab.id),
                        ),
                        _ => Self::loading_context(&tab.id),
                    }
                } else {
                    crate::page_context::project_event_list(
                        self.events.items(),
                        &format!("{:?}", self.events.filter()),
                        &tab.id,
                    )
                }
            }

            "courses.catalog" | "courses.public_list" => {
                if self.courses.items().is_empty() {
                    match self.courses.state() {
                        cgc_courses::catalog::CoursesListState::Failed(message) => {
                            Self::failed_context(&tab.id, message)
                        }
                        cgc_courses::catalog::CoursesListState::Empty => (
                            crate::page_context::PageBody::Empty,
                            format!("empty:{}", tab.id),
                        ),
                        _ => Self::loading_context(&tab.id),
                    }
                } else {
                    crate::page_context::project_course_list(self.courses.items(), &tab.id)
                }
            }
            "courses.learning_home" => {
                // 页面以 run 为主、已确认课程兜底；上下文与可见行同源。
                crate::page_context::project_learning_runs(
                    &self.learning_runs,
                    &self.enrollments_rows,
                    &tab.id,
                )
            }
            "events.participations" => {
                crate::page_context::project_enrollments(&self.enrollments_rows, &tab.id)
            }
            "account.workspace" => self
                .workspaces
                .current()
                .map(|workspace| {
                    crate::page_context::project_workspace_overview(
                        workspace,
                        self.events.items(),
                        self.courses.items(),
                        &tab.id,
                    )
                })
                .unwrap_or_else(|| match self.workspaces.state() {
                    cgc_platform::workspace::WorkspaceListState::Failed(message) => {
                        Self::failed_context(&tab.id, message)
                    }
                    cgc_platform::workspace::WorkspaceListState::Empty => (
                        crate::page_context::PageBody::Empty,
                        format!("empty:{}", tab.id),
                    ),
                    _ => Self::loading_context(&tab.id),
                }),
            _ => (
                crate::page_context::PageBody::Empty,
                format!("empty-v1:{}:{}", tab.id, tab.path),
            ),
        };
        crate::page_context::PageContext {
            workspace_id: None,
            tab_id: tab.id.clone(),
            route: tab.path.clone(),
            title: tab.title.clone(),
            version,
            body,
            course: None,
        }
    }
}
