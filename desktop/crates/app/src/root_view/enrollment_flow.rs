use super::*;

impl RootView {
    pub(in crate::root_view) fn start_payment(&mut self, provider: &str, cx: &mut Context<Self>) {
        if matches!(
            self.payment,
            PaymentViewState::Creating | PaymentViewState::Qr { .. } | PaymentViewState::Paid
        ) {
            return;
        }
        let Some(enrollment) = self.detail.enrollment().cloned() else {
            return;
        };
        if enrollment.status != "payment_pending" {
            return;
        }
        let deposit = self
            .detail
            .detail()
            .map(|detail| detail.deposit_enabled)
            .unwrap_or(false);
        if deposit && !self.deposit_consent {
            self.payment = PaymentViewState::Failed("deposit_consent".to_string());
            cx.notify();
            return;
        }
        self.payment = PaymentViewState::Creating;
        let api = Arc::clone(&self.orders);
        let token = self.session_token();
        let enrollment_id = enrollment.id.clone();
        let provider = provider.to_string();
        self.payment_generation = self.payment_generation.saturating_add(1);
        let generation = self.payment_generation;
        let task = cx.background_executor().spawn(async move {
            api.create_order(token.as_deref(), &enrollment_id, &provider, deposit)
        });
        cx.spawn(async move |this, cx| {
            let result = task.await;
            let _ = this.update(cx, |this, cx| {
                if this.payment_generation != generation {
                    return;
                }
                match result {
                    Ok(order) => {
                        let url = order.credential.as_deref().and_then(qr_code_url);
                        match url {
                            Some(url) => {
                                this.payment = PaymentViewState::Qr {
                                    url,
                                    order_id: order.id.clone(),
                                    expire_at: order.expire_at.clone(),
                                };
                                let enrollment_id = this
                                    .detail
                                    .enrollment()
                                    .map(|enrollment| enrollment.id.clone())
                                    .unwrap_or_default();
                                let target = this.detail.detail().map(|detail| detail.id.clone());
                                this.poll_payment(order.id, generation, enrollment_id, target, cx);
                            }
                            None => {
                                this.payment =
                                    PaymentViewState::Failed("unsupported_credential".to_string());
                            }
                        }
                    }
                    Err(error) if error.is_unauthorized() => this.force_sign_out(cx),
                    Err(error) => {
                        this.payment =
                            PaymentViewState::Failed(error.code().unwrap_or("generic").to_string());
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    pub(in crate::root_view) fn poll_payment(
        &mut self,
        order_id: String,
        generation: u64,
        enrollment_id: String,
        target_event_id: Option<String>,
        cx: &mut Context<Self>,
    ) {
        let api = Arc::clone(&self.orders);
        let token = self.session_token();
        let bus = Arc::clone(&self.events_bus);
        cx.spawn(async move |this, cx| loop {
            cx.background_executor().timer(Duration::from_secs(2)).await;
            let poll_api = Arc::clone(&api);
            let poll_token = token.clone();
            let poll_id = order_id.clone();
            let result = cx
                .background_executor()
                .spawn(async move { poll_api.order_status(poll_token.as_deref(), &poll_id) })
                .await;
            let keep = this
                .update(cx, |this, cx| {
                    if this.payment_generation != generation {
                        return false;
                    }
                    match result {
                        Ok(order) if order.status == "paid" => {
                            this.payment = PaymentViewState::Paid;
                            (bus).publish(AppEvent::EnrollmentChanged {
                                enrollment_id: enrollment_id.clone(),
                                event_id: target_event_id.clone(),
                                course_id: None,
                            });
                            this.events_started = false;
                            this.events.reset();
                            this.course_detail_started = false;
                            this.course_detail.reset();
                            this.refresh_enrollment(cx);
                            cx.notify();
                            false
                        }
                        Ok(order) if is_terminal_status(&order.status) => {
                            this.payment = PaymentViewState::Terminal(order.status.clone());
                            cx.notify();
                            false
                        }
                        Ok(_) => true,
                        Err(error) if error.is_unauthorized() => {
                            this.force_sign_out(cx);
                            false
                        }
                        Err(error) => {
                            this.payment = PaymentViewState::Failed(error.diagnostic());
                            cx.notify();
                            false
                        }
                    }
                })
                .unwrap_or(false);
            if !keep {
                break;
            }
        })
        .detach();
    }

    pub(in crate::root_view) fn close_payment(&mut self, cx: &mut Context<Self>) {
        self.payment = PaymentViewState::Idle;
        self.payment_generation = self.payment_generation.saturating_add(1);
        cx.notify();
    }

    pub(in crate::root_view) fn cancel_enrollment_action(&mut self, cx: &mut Context<Self>) {
        let Some(enrollment) = self.detail.enrollment().cloned() else {
            return;
        };
        let api = self.detail.api_handle();
        let token = self.session_token();
        let bus = Arc::clone(&self.events_bus);
        let target = self.detail.detail().map(|detail| detail.id.clone());
        let enrollment_id = enrollment.id.clone();
        let task = cx
            .background_executor()
            .spawn(async move { api.cancel_enrollment(token.as_deref(), &enrollment_id) });
        cx.spawn(async move |this, cx| {
            let result = task.await;
            let _ = this.update(cx, |this, cx| {
                match result {
                    Ok(enrollment) => {
                        bus.publish(AppEvent::EnrollmentChanged {
                            enrollment_id: enrollment.id.clone(),
                            event_id: target.clone(),
                            course_id: None,
                        });
                        this.detail.adopt_enrollment(Some(enrollment));
                        this.payment = PaymentViewState::Idle;
                        this.payment_generation = this.payment_generation.saturating_add(1);
                        this.enrollment_error = None;
                    }
                    Err(error) if error.is_unauthorized() => this.force_sign_out(cx),
                    Err(error) if error.is_unauthorized() => this.force_sign_out(cx),
                    Err(_) => {
                        this.enrollment_error = Some("generic".to_string());
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    pub(in crate::root_view) fn refresh_enrollment(&mut self, cx: &mut Context<Self>) {
        let Some(event_id) = self
            .current
            .as_ref()
            .and_then(|route_match| route_match.params.get("id"))
            .cloned()
        else {
            return;
        };
        let api = self.detail.api_handle();
        let token = self.session_token();
        let task = cx
            .background_executor()
            .spawn(async move { api.get_my_enrollment(token.as_deref(), &event_id) });
        cx.spawn(async move |this, cx| {
            let result = task.await;
            let _ = this.update(cx, |this, cx| {
                if let Ok(enrollment) = result {
                    this.detail.adopt_enrollment(enrollment);
                    this.enrollment_error = None;
                    cx.notify();
                }
            });
        })
        .detach();
    }

    /// 课程报名：与活动共用 createEnrollment；成功后重拉详情刷新报名状态。
    pub(in crate::root_view) fn submit_course_enrollment(
        &mut self,
        course_id: &str,
        cx: &mut Context<Self>,
    ) {
        if self.enrolling {
            return;
        }
        let Some(detail) = self.course_detail.detail().cloned() else {
            return;
        };
        if detail.pricing_enabled
            && !detail.available_price_tiers.is_empty()
            && self.selected_tier.is_none()
        {
            self.enrollment_error = Some("tier_required".to_string());
            cx.notify();
            return;
        }
        // R14：未知金额档位不可提交（UI 已禁用，这里再兜一层）。
        if let Some(tier_id) = self.selected_tier.as_deref() {
            if detail
                .available_price_tiers
                .iter()
                .any(|tier| tier.id == tier_id && tier.amount_cents.is_none())
            {
                self.enrollment_error = Some("tier_unavailable".to_string());
                cx.notify();
                return;
            }
        }
        let Some(user_id) = self
            .session
            .signed_in()
            .map(|session| session.user_id.clone())
        else {
            self.enrollment_error = Some("auth".to_string());
            cx.notify();
            return;
        };
        self.enrolling = true;
        self.enrollment_error = None;
        let mut request = EnrollmentRequest::course(course_id, user_id);
        request.tier_id = self.selected_tier.clone();
        let api = self.events.api_handle();
        let token = self.session_token();
        let course_id = course_id.to_string();
        let epoch = self.workspaces.epoch();
        let task = cx
            .background_executor()
            .spawn(async move { api.create_enrollment(token.as_deref(), &request) });
        cx.spawn(async move |this, cx| {
            let result = task.await;
            let _ = this.update(cx, |this, cx| {
                this.enrolling = false;
                let same_course = this
                    .current
                    .as_ref()
                    .and_then(|route_match| route_match.params.get("id"))
                    .is_some_and(|id| id == &course_id);
                match result {
                    Ok(enrollment) => {
                        if this.workspaces.is_current_epoch(epoch) {
                            this.course_enrollments
                                .insert(course_id.clone(), Some(enrollment.status.clone()));
                            this.load_expanded_site_tree_course(cx);
                        }
                        this.enrollment_error = None;
                        this.selected_tier = None;
                        this.enrollments_started = false;
                        this.enrollments_state = EnrollmentsListState::Idle;
                        if same_course {
                            this.course_detail_started = false;
                            this.start_course_detail_load(cx, course_id);
                        }
                    }
                    Err(error) if error.is_unauthorized() => this.force_sign_out(cx),
                    Err(cgc_events::list::EventsError::Domain { code, .. }) => {
                        if same_course {
                            this.enrollment_error = Some(enrollment_error_key(&code).to_string());
                            if state::enrollment_error_needs_refresh(&code) {
                                // R15：跨端已完成报名，本端缓存已过期；像活动分支一样
                                // 重拉详情与本人报名，恢复权威状态后按钮才会消失。
                                this.course_enrollments.remove(&course_id);
                                this.course_detail_started = false;
                                this.start_course_detail_load(cx, course_id.clone());
                                this.load_course_enrollments(cx);
                            }
                        }
                    }
                    Err(_) if same_course => {
                        this.enrollment_error = Some("generic".to_string());
                    }
                    Err(_) => {}
                }
                cx.notify();
            });
        })
        .detach();
    }

    pub(in crate::root_view) fn submit_enrollment(&mut self, cx: &mut Context<Self>) {
        if self.enrolling {
            return;
        }
        let Some(detail) = self.detail.detail().cloned() else {
            return;
        };
        let Some(user_id) = self
            .session
            .signed_in()
            .map(|session| session.user_id.clone())
        else {
            return;
        };
        if detail.pricing_enabled
            && !detail.available_price_tiers.is_empty()
            && self.selected_tier.is_none()
        {
            self.enrollment_error = Some("tier_required".to_string());
            cx.notify();
            return;
        }
        if detail.min_age.is_some() && !self.age_confirmed {
            self.enrollment_error = Some("age_required".to_string());
            cx.notify();
            return;
        }
        self.enrolling = true;
        self.enrollment_error = None;
        let requested_event = detail.id.clone();
        let mut request = EnrollmentRequest::event(detail.id.clone(), user_id);
        request.tier_id = self.selected_tier.clone();
        request.age_confirmed = self.age_confirmed;
        let api = self.detail.api_handle();
        let token = self.session_token();
        let task = cx
            .background_executor()
            .spawn(async move { api.create_enrollment(token.as_deref(), &request) });
        cx.spawn(async move |this, cx| {
            let result = task.await;
            let _ = this.update(cx, |this, cx| {
                this.enrolling = false;
                let same_event = this
                    .current
                    .as_ref()
                    .and_then(|route_match| route_match.params.get("id"))
                    .is_some_and(|id| id == &requested_event);
                match result {
                    Ok(enrollment) => {
                        if same_event {
                            this.detail.adopt_enrollment(Some(enrollment));
                        }
                        this.enrollment_error = None;
                        this.enrollments_started = false;
                        this.enrollments_state = EnrollmentsListState::Idle;
                    }
                    Err(cgc_events::list::EventsError::Domain { code, .. }) => {
                        if same_event {
                            let suffix = enrollment_error_key(&code).to_string();
                            this.enrollment_error = Some(suffix);
                            if code == "enrollment_duplicate_active" {
                                this.refresh_enrollment(cx);
                            }
                        }
                    }
                    Err(_) if same_event => {
                        this.enrollment_error = Some("generic".to_string());
                    }
                    Err(_) => {}
                }
                cx.notify();
            });
        })
        .detach();
    }

    pub(in crate::root_view) fn retry_detail(&mut self, cx: &mut Context<Self>) {
        self.detail.retry_ready();
        self.detail_started = false;
        if let Some(event_id) = self
            .current
            .as_ref()
            .and_then(|route_match| route_match.params.get("id"))
            .cloned()
        {
            self.start_detail_load(cx, event_id);
        }
        cx.notify();
    }
}
