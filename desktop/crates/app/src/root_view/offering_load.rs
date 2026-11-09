use super::controller::{list_response_disposition, ListResponseDisposition};
use super::*;

impl RootView {
    /// R4：工作区列表从空变非空后，为已加载的公开课程列表/详情补查 `courseWorkspaces`。
    pub(in crate::root_view) fn backfill_public_course_ownership(
        &mut self,
        cx: &mut Context<Self>,
    ) {
        if self.courses_scope == Some(crate::routing::ListScope::Public)
            && self.courses_started
            && self
                .courses
                .items()
                .iter()
                .any(|course| course.workspace_id.is_none())
        {
            // 重新走公开列表加载：此时 workspace_ids 已非空，`course_workspaces` 能补回归属。
            self.start_courses_load_with_scope(cx, true, crate::routing::ListScope::Public);
        }
        let public_course_id = self
            .current
            .as_ref()
            .filter(|route| {
                matches!(
                    route.route.id,
                    "courses.public_detail" | "courses.public_learning"
                )
            })
            .and_then(|route| route.params.get("id").cloned());
        if let (Some(course_id), true) = (
            public_course_id,
            self.course_detail
                .detail()
                .is_some_and(|detail| detail.workspace_id.is_none()),
        ) {
            // 详情同款：重拉一次，`start_course_detail_load` 会用非空 workspace_ids 补查。
            self.course_detail_started = false;
            self.start_course_detail_load(cx, course_id);
        }
    }

    pub(in crate::root_view) fn start_projection_load(
        &mut self,
        cx: &mut Context<Self>,
        course_id: String,
    ) {
        self.projection.begin_load(&course_id);
        let api = self.projection.api_handle();
        let token = self.session_token();
        let epoch = self.workspace_bound_epoch();
        let session_epoch = self.session_epoch;
        let requested_course = course_id.clone();
        let task = cx
            .background_executor()
            .spawn(async move { api.get_learning_projection(token.as_deref(), &course_id) });
        cx.spawn(async move |this, cx| {
            let result = task.await;
            let _ = this.update(cx, |this, cx| {
                let stale_epoch =
                    epoch.is_some_and(|epoch| !this.workspaces.is_current_epoch(epoch));
                let stale_session = this.session_epoch != session_epoch;
                // 复位判据是「服务当前正在跟踪的那门课」，不是路由对象：Site Tree 会为
                // 树里展开的**另一门课**加载正文/投影，此时路由往往没有 :id，按路由判会
                // 把别人已加载的数据清空（CourseContentService::adopt 不校验课程）。
                let still_wanted = this.projection.course_id() == Some(requested_course.as_str());
                if stale_epoch || stale_session || !still_wanted {
                    // 丢弃后必须复位：render 闸门要求 `Idle` 才会重发，否则投影永久
                    // 停在加载态且没有重试入口（R1）。
                    if still_wanted {
                        this.projection.reset();
                    }
                    return;
                }
                match result {
                    Ok(projection) => {
                        let user_id = this
                            .session
                            .signed_in()
                            .map(|session| session.user_id.clone());
                        if let (Some(user_id), Some(key)) = (
                            user_id,
                            projection.review_dedup_key(
                                this.session
                                    .signed_in()
                                    .map(|session| session.user_id.as_str())
                                    .unwrap_or(""),
                            ),
                        ) {
                            if this.review_event_keys.insert(key.clone()) {
                                this.events_bus.publish(AppEvent::ReviewQueueDue {
                                    user_id,
                                    course_id: projection.course_id.clone(),
                                    dedup_key: key,
                                });
                            }
                        }
                        this.projection.adopt(projection)
                    }
                    Err(error) if error.is_unauthorized() => this.force_sign_out(cx),
                    Err(error) => this.projection.fail(&error),
                }
                cx.notify();
            });
        })
        .detach();
    }

    pub(in crate::root_view) fn start_content_load(
        &mut self,
        cx: &mut Context<Self>,
        course_id: String,
    ) {
        self.content.begin_load(&course_id);
        let api = self.content.api_handle();
        let token = self.session_token();
        let epoch = self.workspace_bound_epoch();
        let session_epoch = self.session_epoch;
        let requested_course = course_id.clone();
        let task = cx
            .background_executor()
            .spawn(async move { api.get_course_content(token.as_deref(), &course_id) });
        cx.spawn(async move |this, cx| {
            let result = task.await;
            let _ = this.update(cx, |this, cx| {
                let stale_epoch =
                    epoch.is_some_and(|epoch| !this.workspaces.is_current_epoch(epoch));
                let stale_session = this.session_epoch != session_epoch;
                // 同 projection：判据是「当前加载/已加载的那门课」。旧课的迟到响应不得
                // 复位另一门课（Site Tree 展开的课）的正文。
                let still_wanted = this.content.course_id() == Some(requested_course.as_str());
                if stale_epoch || stale_session || !still_wanted {
                    // 丢弃后必须复位，否则正文闸门（`Idle`）不再重发（R1）。
                    if still_wanted {
                        this.content.reset();
                    }
                    return;
                }
                match result {
                    Ok(content) => this.content.adopt(content),
                    Err(error) if error.is_unauthorized() => this.force_sign_out(cx),
                    Err(error) => this.content.fail(&error),
                }
                cx.notify();
            });
        })
        .detach();
    }

    pub(in crate::root_view) fn start_courses_load(&mut self, cx: &mut Context<Self>, first: bool) {
        let Some(scope_mode) = self
            .current
            .as_ref()
            .and_then(|route_match| crate::routing::offering_list_scope(route_match.route.id))
        else {
            return;
        };
        self.start_courses_load_with_scope(cx, first, scope_mode);
    }

    /// `scope_mode` 由调用方显式决定：中心列表按路由，概览固定 Workspace。
    /// Site Tree 不走这里——它有自己的 `start_nav_courses_load` 缓存。
    pub(in crate::root_view) fn start_courses_load_with_scope(
        &mut self,
        cx: &mut Context<Self>,
        first: bool,
        scope_mode: crate::routing::ListScope,
    ) {
        let scope = match scope_mode {
            crate::routing::ListScope::Workspace => match self.workspaces.scope() {
                Some(scope) => Some(scope),
                None => return,
            },
            crate::routing::ListScope::Public => None,
        };
        self.courses_scope = Some(scope_mode);
        // R2：每次发起换一个代次，迟到响应只有代次与完整 scope 都匹配时才落地。
        self.courses_load_serial = self.courses_load_serial.wrapping_add(1);
        let serial = self.courses_load_serial;
        if first {
            self.courses.begin_first_load();
        } else {
            self.courses.begin_load_more();
        }
        self.courses_started = true;
        let api = self.courses.api_handle();
        let token = self.session_token();
        let workspace_ids = if matches!(scope_mode, crate::routing::ListScope::Public) {
            self.workspaces
                .workspaces()
                .iter()
                .filter(|workspace| workspace.can_access)
                .map(|workspace| workspace.id.clone())
                .collect::<Vec<_>>()
        } else {
            Vec::new()
        };
        let cursor = if first {
            None
        } else {
            self.courses.next_cursor().map(str::to_string)
        };
        // 只有依赖工作区的请求才受 workspace epoch 约束；公开面与工作区无关。
        let epoch = scope.as_ref().map(|_| self.workspaces.epoch());
        let session_epoch = self.session_epoch;
        let task = cx.background_executor().spawn(async move {
            let offering = match scope.as_ref() {
                Some(scope) => cgc_platform::workspace::OfferingScope::Workspace(scope),
                None => cgc_platform::workspace::OfferingScope::Public,
            };
            let mut page = api.list_courses(token.as_deref(), offering, cursor.as_deref(), 10)?;
            if matches!(scope_mode, crate::routing::ListScope::Public) {
                let ids = page
                    .items
                    .iter()
                    .filter(|course| course.workspace_id.is_none())
                    .map(|course| course.id.clone())
                    .collect::<Vec<_>>();
                match api.course_workspaces(token.as_deref(), &ids, &workspace_ids) {
                    Ok(mut owners) => {
                        for course in &mut page.items {
                            if course.workspace_id.is_none() {
                                course.workspace_id = owners.remove(&course.id);
                            }
                        }
                    }
                    Err(error) if error.is_unauthorized() => return Err(error),
                    Err(_) => {}
                }
            }
            Ok(page)
        });

        cx.spawn(async move |this, cx| {
            let result = task.await;
            let _ = this.update(cx, |this, cx| {
                let disposition = list_response_disposition(
                    this.courses_load_serial,
                    serial,
                    this.courses_scope,
                    scope_mode,
                    epoch,
                    epoch.is_none_or(|epoch| this.workspaces.is_current_epoch(epoch)),
                    this.session_epoch == session_epoch,
                );
                match disposition {
                    ListResponseDisposition::Ignore => return,
                    ListResponseDisposition::DiscardAndReset => {
                        // 丢弃越界响应后必须复位，否则闸门会永久停在 Loading。
                        this.courses.reset();
                        this.courses_started = false;
                        cx.notify();
                        return;
                    }
                    ListResponseDisposition::Apply => {}
                }
                match result {
                    Ok(page) => {
                        this.courses.adopt_page(page);
                        this.load_course_enrollments(cx);
                    }
                    Err(error) if error.is_unauthorized() => this.force_sign_out(cx),
                    Err(error) => this.courses.fail(&error),
                }
                cx.notify();
            });
        })
        .detach();
    }

    pub(in crate::root_view) fn start_course_detail_load(
        &mut self,
        cx: &mut Context<Self>,
        course_id: String,
    ) {
        self.selected_tier = None;
        self.age_confirmed = false;
        self.enrollment_error = None;
        self.enrolling = false;
        self.course_detail.begin_load();
        self.course_detail_started = true;
        if self
            .content
            .content()
            .is_none_or(|content| content.course_id != course_id)
        {
            self.content.reset();
        }
        self.projection.reset();
        self.pending_link = None;
        let epoch = self.workspace_bound_epoch();
        let session_epoch = self.session_epoch;
        let requested_course = course_id.clone();
        let api = self.course_detail.api_handle();
        let token = self.session_token();
        let cached_workspace = self
            .courses
            .items()
            .iter()
            .find(|course| course.id == course_id)
            .and_then(|course| course.workspace_id.clone());
        let workspace_ids = self
            .workspaces
            .workspaces()
            .iter()
            .filter(|workspace| workspace.can_access)
            .map(|workspace| workspace.id.clone())
            .collect::<Vec<_>>();
        let task = cx.background_executor().spawn(async move {
            let mut detail = api.get_course(token.as_deref(), &course_id)?;
            if detail.workspace_id.is_none() {
                detail.workspace_id = cached_workspace;
            }
            if detail.workspace_id.is_none() {
                match api.course_workspaces(
                    token.as_deref(),
                    std::slice::from_ref(&course_id),
                    &workspace_ids,
                ) {
                    Ok(mut owners) => detail.workspace_id = owners.remove(&course_id),
                    Err(error) if error.is_unauthorized() => return Err(error),
                    Err(_) => {}
                }
            }
            Ok(detail)
        });
        cx.spawn(async move |this, cx| {
            let result = task.await;
            let _ = this.update(cx, |this, cx| {
                let stale_epoch =
                    epoch.is_some_and(|epoch| !this.workspaces.is_current_epoch(epoch));
                let stale_session = this.session_epoch != session_epoch;
                let same_course = this.route_object_id() == Some(requested_course.as_str());
                if stale_epoch || stale_session || !same_course {
                    // 丢弃后必须复位：render 闸门要求 `!started && Idle` 才重发，
                    // 否则详情页永久转圈且只有 Failed 分支有重试入口（R1）。
                    if same_course {
                        this.course_detail.reset();
                        this.course_detail_started = false;
                    }
                    return;
                }
                match result {
                    Ok(detail) => {
                        this.canonicalize_course_route(&detail);
                        this.adopt_course_detail(detail);
                        this.load_expanded_site_tree_course(cx);
                        this.sync_agent_workspace_scope(cx);
                    }
                    Err(error) if error.is_unauthorized() => this.force_sign_out(cx),
                    Err(error) => this.course_detail.fail(&error),
                }
                cx.notify();
            });
        })
        .detach();
    }

    pub(in crate::root_view) fn load_course_enrollments(&mut self, cx: &mut Context<Self>) {
        let ids = self
            .courses
            .items()
            .iter()
            .map(|course| course.id.clone())
            .collect::<Vec<_>>();
        self.load_course_enrollments_for(ids, cx);
    }

    /// 报名状态按课程 id 查询；中心列表与 Site Tree 缓存各自调用，共用同一份缓存。
    pub(in crate::root_view) fn load_course_enrollments_for(
        &mut self,
        candidates: Vec<String>,
        cx: &mut Context<Self>,
    ) {
        let epoch = self.workspaces.epoch();
        let ids = candidates
            .into_iter()
            // M2：同一课程的状态查询在途时不再重复发起（快速翻页会反复触发本方法）。
            .filter(|id| {
                state::should_query_course_enrollment(
                    id,
                    &self.course_enrollments,
                    &self.course_enrollments_inflight,
                )
            })
            .collect::<Vec<_>>();
        if ids.is_empty() {
            return;
        }
        for id in &ids {
            self.course_enrollments_inflight.insert(id.clone());
        }
        let requested_ids = ids.clone();
        let api = self.courses.api_handle();
        let token = self.session_token();
        let task = cx.background_executor().spawn(async move {
            let mut statuses = std::collections::BTreeMap::new();
            for id in ids {
                // 查询失败不落 None：未知不能当成“未报名”，否则会误导学员。
                if let Ok(status) = api.get_my_enrollment_status(token.as_deref(), &id) {
                    statuses.insert(id, status);
                }
            }
            statuses
        });
        cx.spawn(async move |this, cx| {
            let statuses = task.await;
            let _ = this.update(cx, |this, cx| {
                // 回调无论是否因 epoch 丢弃都要清在途标记，否则该课程永不再查。
                for id in &requested_ids {
                    this.course_enrollments_inflight.remove(id);
                }
                if !this.workspaces.is_current_epoch(epoch) {
                    return;
                }
                for (id, status) in statuses {
                    this.course_enrollments.entry(id).or_insert(status);
                }
                this.load_expanded_site_tree_course(cx);
                cx.notify();
            });
        })
        .detach();
    }

    /// Site Tree 的数据按需加载；只有进入已登录工作区后才调用。
    ///
    /// 树使用独立缓存（`nav_events` / `nav_courses`），与中心列表互不覆盖：中心可能
    /// 停在公开目录（Public scope），树仍要展示当前工作区数据。
    pub(in crate::root_view) fn ensure_navigation_data(&mut self, cx: &mut Context<Self>) {
        if self.workspaces.scope().is_none() {
            return;
        }
        if !self.nav_events_started && matches!(self.nav_events.state(), ListState::Idle) {
            self.start_nav_events_load(cx, true);
        }
        if !self.nav_courses_started && matches!(self.nav_courses.state(), CoursesListState::Idle) {
            self.start_nav_courses_load(cx, true);
        }
    }

    /// Site Tree 课程缓存：恒为本工作区数据面，绝不写中心列表（review #1253 P2）。
    pub(in crate::root_view) fn start_nav_courses_load(
        &mut self,
        cx: &mut Context<Self>,
        first: bool,
    ) {
        let Some(scope) = self.workspaces.scope() else {
            return;
        };
        self.nav_courses_serial = self.nav_courses_serial.wrapping_add(1);
        let serial = self.nav_courses_serial;
        if first {
            self.nav_courses.begin_first_load();
        } else {
            self.nav_courses.begin_load_more();
        }
        self.nav_courses_started = true;
        let api = self.nav_courses.api_handle();
        let token = self.session_token();
        let cursor = if first {
            None
        } else {
            self.nav_courses.next_cursor().map(str::to_string)
        };
        let epoch = self.workspaces.epoch();
        let session_epoch = self.session_epoch;
        let task = cx.background_executor().spawn(async move {
            api.list_courses(
                token.as_deref(),
                cgc_platform::workspace::OfferingScope::Workspace(&scope),
                cursor.as_deref(),
                10,
            )
        });
        cx.spawn(async move |this, cx| {
            let result = task.await;
            let _ = this.update(cx, |this, cx| {
                if this.nav_courses_serial != serial {
                    return;
                }
                if this.session_epoch != session_epoch || !this.workspaces.is_current_epoch(epoch) {
                    // 切台/换账号后旧响应不能落地；复位让下一次展开重新加载。
                    this.nav_courses.reset();
                    this.nav_courses_started = false;
                    cx.notify();
                    return;
                }
                match result {
                    Ok(page) => {
                        this.nav_courses.adopt_page(page);
                        let ids = this
                            .nav_courses
                            .items()
                            .iter()
                            .map(|course| course.id.clone())
                            .collect();
                        this.load_course_enrollments_for(ids, cx);
                    }
                    Err(error) if error.is_unauthorized() => this.force_sign_out(cx),
                    Err(error) => this.nav_courses.fail(&error),
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// Site Tree 活动缓存：同 `start_nav_courses_load`，与中心列表隔离。
    pub(in crate::root_view) fn start_nav_events_load(
        &mut self,
        cx: &mut Context<Self>,
        first: bool,
    ) {
        let Some(scope) = self.workspaces.scope() else {
            return;
        };
        self.nav_events_serial = self.nav_events_serial.wrapping_add(1);
        let serial = self.nav_events_serial;
        if first {
            self.nav_events.begin_first_load();
        } else {
            self.nav_events.begin_load_more();
        }
        self.nav_events_started = true;
        let api = self.nav_events.api_handle();
        let token = self.session_token();
        let filter = self.nav_events.filter();
        let after = if first {
            None
        } else {
            self.nav_events.next_cursor().map(str::to_string)
        };
        let epoch = self.workspaces.epoch();
        let session_epoch = self.session_epoch;
        let task = cx.background_executor().spawn(async move {
            api.list_events(
                token.as_deref(),
                cgc_platform::workspace::OfferingScope::Workspace(&scope),
                filter,
                after.as_deref(),
                10,
            )
        });
        cx.spawn(async move |this, cx| {
            let result = task.await;
            let _ = this.update(cx, |this, cx| {
                if this.nav_events_serial != serial {
                    return;
                }
                if this.session_epoch != session_epoch || !this.workspaces.is_current_epoch(epoch) {
                    this.nav_events.reset();
                    this.nav_events_started = false;
                    cx.notify();
                    return;
                }
                match result {
                    Ok(page) => this.nav_events.adopt_page(page),
                    Err(error) if error.is_unauthorized() => this.force_sign_out(cx),
                    Err(error) => this.nav_events.fail(&error),
                }
                cx.notify();
            });
        })
        .detach();
    }

    pub(in crate::root_view) fn load_expanded_site_tree_course(&mut self, cx: &mut Context<Self>) {
        let Some(course_id) = self.site_tree_course_open.as_deref() else {
            return;
        };
        if self
            .current
            .as_ref()
            .filter(|route| {
                matches!(
                    route.route.id,
                    "courses.learning" | "courses.public_learning"
                )
            })
            .and_then(|route| route.params.get("id"))
            .is_some_and(|active| active != course_id)
        {
            return;
        }
        if self
            .course_enrollments
            .get(course_id)
            .and_then(Option::as_deref)
            == Some("confirmed")
            && self
                .content
                .content()
                .is_none_or(|content| content.course_id != course_id)
            && !(self.content.course_id() == Some(course_id)
                && matches!(self.content.state(), CourseContentState::Loading))
        {
            self.start_content_load(cx, course_id.to_string());
        }
    }

    pub(in crate::root_view) fn start_enrollments_load(&mut self, cx: &mut Context<Self>) {
        self.enrollments_started = true;
        self.enrollments_state = EnrollmentsListState::Loading;
        self.enrollments_load_more_failed = false;
        let api = Arc::clone(&self.enrollments_api);
        let token = self.session_token();
        let epoch = self.workspaces.epoch();
        let task = cx.background_executor().spawn(async move {
            let mut rows = api.my_enrollments(token.as_deref())?;
            let runs = api.my_learning_runs(token.as_deref())?;
            // R13：run 引用的 enrollment 不在分页结果里时，按 course 补查本人报名，
            // 让 learning_home 仍有 workspace_id 徽标与工作区地址。
            for run in &runs {
                if rows.iter().any(|row| row.id == run.enrollment_id) {
                    continue;
                }
                if let Ok(Some(row)) =
                    api.my_enrollment_for_course(token.as_deref(), &run.course_id)
                {
                    if !rows.iter().any(|existing| existing.id == row.id) {
                        rows.push(row);
                    }
                }
            }
            Ok::<_, cgc_events::list::EventsError>((rows, runs))
        });
        cx.spawn(async move |this, cx| {
            let result = task.await;
            let _ = this.update(cx, |this, cx| {
                if !this.workspaces.is_current_epoch(epoch) {
                    // 报名数据跨台，但切台/换账号后旧响应不能落地；复位让闸门重发。
                    this.enrollments_started = false;
                    this.enrollments_state = EnrollmentsListState::Idle;
                    cx.notify();
                    return;
                }
                match result {
                    Ok((rows, runs)) => {
                        this.enrollments_rows = rows;
                        this.learning_runs = runs;
                        this.enrollments_state =
                            if this.enrollments_rows.is_empty() && this.learning_runs.is_empty() {
                                EnrollmentsListState::Empty
                            } else {
                                EnrollmentsListState::Ready
                            };
                    }
                    Err(error) if error.is_unauthorized() => this.force_sign_out(cx),
                    Err(error) => {
                        this.enrollments_state = EnrollmentsListState::Failed(error.diagnostic());
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    pub(in crate::root_view) fn start_detail_load(
        &mut self,
        cx: &mut Context<Self>,
        event_id: String,
    ) {
        self.detail.begin_load(&event_id);
        self.detail_started = true;
        self.selected_tier = None;
        self.age_confirmed = false;
        self.enrollment_error = None;
        self.enrolling = false;
        let api = self.detail.api_handle();
        let token = self.session_token();
        let epoch = self.workspace_bound_epoch();
        let session_epoch = self.session_epoch;
        let requested_event = event_id.clone();
        let task = cx.background_executor().spawn(async move {
            let detail = api.get_event(token.as_deref(), &event_id)?;
            let enrollment = api
                .get_my_enrollment(token.as_deref(), &event_id)
                .unwrap_or(None);
            Ok::<_, cgc_events::list::EventsError>((detail, enrollment))
        });
        cx.spawn(async move |this, cx| {
            let result = task.await;
            let _ = this.update(cx, |this, cx| {
                let stale_epoch =
                    epoch.is_some_and(|epoch| !this.workspaces.is_current_epoch(epoch));
                let stale_session = this.session_epoch != session_epoch;
                let same_event = this.route_object_id() == Some(requested_event.as_str());
                if stale_epoch || stale_session || !same_event {
                    // 丢弃后必须复位，否则活动详情闸门（`Idle` + `!started`）不再重发（R1）。
                    if same_event {
                        this.detail.reset();
                        this.detail_started = false;
                    }
                    return;
                }
                match result {
                    Ok((detail, enrollment)) => {
                        this.detail.adopt(detail);
                        this.detail.adopt_enrollment(enrollment.clone());
                        if std::env::var("CGC_AUTO_PAY").as_deref() == Ok("1")
                            && enrollment
                                .as_ref()
                                .is_some_and(|enrollment| enrollment.status == "payment_pending")
                        {
                            this.start_payment("wechat_native", cx);
                        }
                    }
                    Err(error) if error.is_unauthorized() => this.force_sign_out(cx),
                    Err(error) => this.detail.fail(&error),
                }
                cx.notify();
            });
        })
        .detach();
    }

    pub(in crate::root_view) fn start_events_load(&mut self, cx: &mut Context<Self>, first: bool) {
        let Some(scope_mode) = self
            .current
            .as_ref()
            .and_then(|route_match| crate::routing::offering_list_scope(route_match.route.id))
        else {
            return;
        };
        self.start_events_load_with_scope(cx, first, scope_mode);
    }

    /// `scope_mode` 由调用方显式决定：中心列表按路由，概览固定 Workspace。
    /// Site Tree 不走这里——它有自己的 `start_nav_events_load` 缓存。
    pub(in crate::root_view) fn start_events_load_with_scope(
        &mut self,
        cx: &mut Context<Self>,
        first: bool,
        scope_mode: crate::routing::ListScope,
    ) {
        let scope = match scope_mode {
            crate::routing::ListScope::Workspace => match self.workspaces.scope() {
                Some(scope) => Some(scope),
                None => return,
            },
            crate::routing::ListScope::Public => None,
        };
        self.events_scope = Some(scope_mode);
        // R2：同上，活动列表与课程列表各有一份代次。
        self.events_load_serial = self.events_load_serial.wrapping_add(1);
        let serial = self.events_load_serial;
        if first {
            self.events.begin_first_load();
        } else {
            self.events.begin_load_more();
        }
        self.events_started = true;

        let api = self.events.api_handle();
        let token = self.session_token();
        let filter = self.events.filter();
        let after = if first {
            None
        } else {
            self.events.next_cursor().map(str::to_string)
        };
        let epoch = scope.as_ref().map(|_| self.workspaces.epoch());
        let session_epoch = self.session_epoch;
        let task = cx.background_executor().spawn(async move {
            let offering = match scope.as_ref() {
                Some(scope) => cgc_platform::workspace::OfferingScope::Workspace(scope),
                None => cgc_platform::workspace::OfferingScope::Public,
            };
            api.list_events(token.as_deref(), offering, filter, after.as_deref(), 10)
        });

        cx.spawn(async move |this, cx| {
            let result = task.await;
            let _ = this.update(cx, |this, cx| {
                let disposition = list_response_disposition(
                    this.events_load_serial,
                    serial,
                    this.events_scope,
                    scope_mode,
                    epoch,
                    epoch.is_none_or(|epoch| this.workspaces.is_current_epoch(epoch)),
                    this.session_epoch == session_epoch,
                );
                match disposition {
                    ListResponseDisposition::Ignore => return,
                    ListResponseDisposition::DiscardAndReset => {
                        // 丢弃越界响应后必须复位，否则闸门会永久停在 Loading。
                        this.events.reset();
                        this.events_started = false;
                        cx.notify();
                        return;
                    }
                    ListResponseDisposition::Apply => {}
                }
                match result {
                    Ok(page) => this.events.adopt_page(page),
                    Err(error) if error.is_unauthorized() => this.force_sign_out(cx),
                    Err(error) => this.events.fail(&error),
                }
                cx.notify();
            });
        })
        .detach();
    }
}
