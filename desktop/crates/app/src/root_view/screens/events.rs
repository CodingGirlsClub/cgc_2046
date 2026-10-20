use super::super::*;

impl RootView {
    pub(in crate::root_view) fn render_enrollments_list(
        &mut self,
        language: Language,
        palette: &theme::Palette,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let body: AnyElement = match &self.enrollments_state {
            EnrollmentsListState::Idle | EnrollmentsListState::Loading => div()
                .text_color(palette.ink_3)
                .child(translate(language, Key::EventsMineLoading))
                .into_any_element(),
            EnrollmentsListState::Failed(message) => div()
                .flex()
                .flex_col()
                .gap(space(1))
                .child(div().text_color(palette.danger).child(message.clone()))
                .child(
                    div()
                        .id("enrollments-retry")
                        .px(space(2))
                        .py(px(5.0))
                        .rounded(px(RADIUS_MEDIUM))
                        .bg(palette.accent)
                        .text_color(palette.canvas)
                        .child(translate(language, Key::EventsMineRetry))
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.enrollments_started = false;
                            this.enrollments_state = EnrollmentsListState::Idle;
                            cx.notify();
                        })),
                )
                .into_any_element(),
            EnrollmentsListState::Empty => div()
                .text_color(palette.ink_3)
                .child(translate(language, Key::EventsMineEmpty))
                .into_any_element(),
            EnrollmentsListState::Ready => {
                let rows = self
                    .enrollments_rows
                    .iter()
                    .map(|row| {
                        let starts = row
                            .starts_at
                            .as_deref()
                            .map(|value| value.chars().take(10).collect::<String>())
                            .unwrap_or_default();
                        let target = row.target_title.clone().unwrap_or_default();
                        let event_id = row.event_id.clone();
                        let course_id = row.course_id.clone();
                        let row_id = row.id.clone();
                        div()
                            .id(format!("enrollment-row-{row_id}"))
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
                                    .child(div().text_color(palette.ink).child(target))
                                    .child(
                                        div()
                                            .text_size(px(11.0))
                                            .text_color(palette.ink_3)
                                            .child(starts),
                                    ),
                            )
                            .child(
                                div()
                                    .px(px(6.0))
                                    .py(px(2.0))
                                    .rounded(px(RADIUS_SMALL))
                                    .bg(palette.soft)
                                    .text_size(px(11.0))
                                    .text_color(palette.ink_2)
                                    .child(enroll_status_label(language, &row.status)),
                            )
                            .on_click(cx.listener(move |this, _, _, cx| {
                                if let Some(event_id) = &event_id {
                                    this.navigate(&format!("/events/{event_id}"));
                                } else if let Some(course_id) = &course_id {
                                    this.navigate(&format!("/courses/{course_id}"));
                                }
                                cx.notify();
                            }))
                            .into_any_element()
                    })
                    .collect::<Vec<_>>();
                div().flex().flex_col().children(rows).into_any_element()
            }
        };

        div()
            .flex()
            .flex_col()
            .gap(space(2))
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .justify_between()
                    .child(
                        div()
                            .text_size(px(24.0))
                            .text_color(palette.ink)
                            .child(translate_registered(language, "events.mine.title")),
                    )
                    .child(
                        div()
                            .id("enrollments-back")
                            .text_size(px(12.0))
                            .text_color(palette.ink_3)
                            .child(translate(language, Key::EventsDetailBack))
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.navigate("/events");
                                cx.notify();
                            })),
                    ),
            )
            .child(body)
            .into_any_element()
    }

    pub(in crate::root_view) fn render_detail(
        &mut self,
        language: Language,
        palette: &theme::Palette,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let state = self.detail.state().clone();
        let detail = self.detail.detail().cloned();

        let back = div()
            .id("detail-back")
            .child(translate(language, Key::EventsDetailBack))
            .text_color(palette.ink_3)
            .text_size(px(12.0))
            .on_click(cx.listener(|this, _, _, cx| {
                this.navigate("/events");
                cx.notify();
            }));

        let body: AnyElement = match state {
            ListState::Idle | ListState::Loading => div()
                .text_color(palette.ink_3)
                .child(translate(language, Key::EventsDetailLoading))
                .into_any_element(),
            ListState::Failed(message) => {
                let not_found = message == "not found";
                div()
                    .flex()
                    .flex_col()
                    .gap(space(1))
                    .child(div().text_color(palette.danger).child(if not_found {
                        translate(language, Key::EventsDetailNotFound)
                    } else {
                        translate(language, Key::EventsDetailError)
                    }))
                    .children((!not_found).then(|| {
                        div()
                            .id("detail-retry")
                            .px(space(2))
                            .py(px(5.0))
                            .rounded(px(RADIUS_MEDIUM))
                            .bg(palette.accent)
                            .text_color(white())
                            .child(translate(language, Key::EventsDetailRetry))
                            .on_click(cx.listener(|this, _, _, cx| this.retry_detail(cx)))
                            .into_any_element()
                    }))
                    .into_any_element()
            }
            ListState::Empty => div()
                .text_color(palette.ink_3)
                .child(translate(language, Key::EventsDetailNotFound))
                .into_any_element(),
            ListState::Ready => match detail {
                Some(detail) => {
                    let starts = detail
                        .starts_at
                        .as_deref()
                        .map(|value| value.chars().take(10).collect::<String>())
                        .unwrap_or_default();
                    let venue = detail
                        .venue
                        .as_deref()
                        .and_then(cgc_events::detail::venue_city)
                        .unwrap_or_default();
                    let (price_label, price_detail) = match detail.price_mode() {
                        PriceMode::Free => (
                            translate(language, Key::EventsDetailFree).to_string(),
                            String::new(),
                        ),
                        PriceMode::Paid {
                            min_amount_cents,
                            tiers,
                        } => (
                            translate(language, Key::EventsDetailPaid).to_string(),
                            format!("¥{:.2} 起 · {tiers} 档", min_amount_cents as f64 / 100.0),
                        ),
                        PriceMode::Deposit { amount_cents } => (
                            translate(language, Key::EventsDetailDeposit).to_string(),
                            format!("押金 ¥{:.2}（可退）", amount_cents as f64 / 100.0),
                        ),
                    };
                    let capacity = detail
                        .capacity
                        .map(|capacity| {
                            format!("{}/{}", detail.confirmed_count.unwrap_or(0), capacity)
                        })
                        .unwrap_or_else(|| "—".to_string());

                    div()
                        .flex()
                        .flex_col()
                        .gap(space(2))
                        .child(
                            div()
                                .text_size(px(24.0))
                                .text_color(palette.ink)
                                .child(detail.title.clone()),
                        )
                        .child(
                            div()
                                .text_size(px(12.0))
                                .text_color(palette.ink_3)
                                .child(format!(
                                    "{starts} · {} · {}",
                                    translate(language, Key::EventsDetailVenue),
                                    if venue.is_empty() {
                                        "—".to_string()
                                    } else {
                                        venue
                                    }
                                )),
                        )
                        .children(detail.description.clone().map(|description| {
                            div()
                                .text_color(palette.ink_2)
                                .child(description)
                                .into_any_element()
                        }))
                        .child(
                            div()
                                .flex()
                                .flex_row()
                                .items_center()
                                .gap(space(2))
                                .child(
                                    div()
                                        .px(space(1))
                                        .py(px(3.0))
                                        .rounded(px(RADIUS_SMALL))
                                        .bg(palette.soft)
                                        .text_color(palette.ink_2)
                                        .text_size(px(12.0))
                                        .child(translate(
                                            language,
                                            status_key(detail.status.as_str()),
                                        )),
                                )
                                .child(
                                    div()
                                        .px(space(1))
                                        .py(px(3.0))
                                        .rounded(px(RADIUS_SMALL))
                                        .bg(palette.soft)
                                        .text_color(palette.ink_2)
                                        .text_size(px(12.0))
                                        .child(format!("{price_label} {price_detail}")),
                                )
                                .child(div().text_size(px(12.0)).text_color(palette.ink_3).child(
                                    format!(
                                        "{} {capacity}",
                                        translate(language, Key::EventsDetailCapacity)
                                    ),
                                )),
                        )
                        .child(self.render_enrollment_area(language, palette, &detail, cx))
                        .into_any_element()
                }
                None => div()
                    .text_color(palette.ink_3)
                    .child(translate(language, Key::EventsDetailNotFound))
                    .into_any_element(),
            },
        };

        div()
            .flex()
            .flex_col()
            .gap(space(2))
            .child(back)
            .child(body)
            .into_any_element()
    }

    pub(in crate::root_view) fn render_enrollment_area(
        &mut self,
        language: Language,
        palette: &theme::Palette,
        detail: &EventDetail,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        if let Some(enrollment) = self.detail.enrollment().cloned() {
            let status = div()
                .flex()
                .flex_row()
                .items_center()
                .gap(space(1))
                .text_size(px(12.0))
                .text_color(palette.ink_2)
                .child(enroll_status_label(language, enrollment.status.as_str()));
            if enrollment.status != "payment_pending" {
                let paid_notice = matches!(self.payment, PaymentViewState::Paid).then(|| {
                    div()
                        .text_size(px(12.0))
                        .text_color(palette.accent)
                        .child(translate(language, Key::EventsPayPaid))
                        .into_any_element()
                });
                let check_in = (detail.deposit_enabled && enrollment.status == "confirmed")
                    .then(|| enrollment.check_in_code.clone())
                    .flatten()
                    .map(|code| {
                        let content = format!("cgc2046:checkin:{}:{code}", detail.id);
                        let qr = encode_qr(&content)
                            .map(|matrix| render_qr(&matrix, black(), white(), px(160.0)))
                            .unwrap_or_else(|_| {
                                div()
                                    .text_color(palette.danger)
                                    .child(translate(language, Key::EventsPayFailed))
                                    .into_any_element()
                            });
                        div()
                            .flex()
                            .flex_col()
                            .gap(px(4.0))
                            .child(
                                div()
                                    .text_size(px(12.0))
                                    .text_color(palette.ink_3)
                                    .child(translate(language, Key::EventsCheckinTitle)),
                            )
                            .child(qr)
                            .child(div().text_size(px(12.0)).text_color(palette.ink_2).child(
                                format!("{} {code}", translate(language, Key::EventsCheckinCode)),
                            ))
                            .into_any_element()
                    });
                return div()
                    .mt(space(2))
                    .flex()
                    .flex_col()
                    .gap(px(2.0))
                    .text_size(px(12.0))
                    .text_color(palette.ink_2)
                    .child(enroll_status_label(language, enrollment.status.as_str()))
                    .children(paid_notice)
                    .children(check_in)
                    .into_any_element();
            }

            let payment_body: AnyElement = match self.payment.clone() {
                PaymentViewState::Idle | PaymentViewState::Failed(_) => {
                    let deposit = detail.deposit_enabled;
                    let consent = self.deposit_consent;
                    let failed = match &self.payment {
                        PaymentViewState::Failed(message) => Some(message.clone()),
                        _ => None,
                    };
                    div()
                        .flex()
                        .flex_col()
                        .gap(space(1))
                        .child(
                            div()
                                .text_size(px(12.0))
                                .text_color(palette.ink_3)
                                .child(translate(language, Key::EventsPayChooseChannel)),
                        )
                        .child(
                            div()
                                .flex()
                                .flex_row()
                                .gap(space(1))
                                .child(
                                    div()
                                        .id("pay-wechat")
                                        .px(space(2))
                                        .py(px(5.0))
                                        .rounded(px(RADIUS_MEDIUM))
                                        .bg(palette.accent)
                                        .text_color(palette.canvas)
                                        .child(translate(language, Key::EventsPayWechat))
                                        .on_click(cx.listener(|this, _, _, cx| {
                                            this.start_payment("wechat_native", cx);
                                        })),
                                )
                                .child(
                                    div()
                                        .id("pay-alipay")
                                        .px(space(2))
                                        .py(px(5.0))
                                        .rounded(px(RADIUS_MEDIUM))
                                        .bg(palette.soft)
                                        .text_color(palette.ink_2)
                                        .child(translate(language, Key::EventsPayAlipay))
                                        .on_click(cx.listener(|this, _, _, cx| {
                                            this.start_payment("alipay_qr", cx);
                                        })),
                                ),
                        )
                        .children((deposit).then(|| {
                            div()
                                .id("pay-deposit-consent")
                                .flex()
                                .flex_row()
                                .items_center()
                                .gap(px(4.0))
                                .text_size(px(12.0))
                                .text_color(palette.ink_2)
                                .child(if consent { "☑" } else { "☐" })
                                .child(translate(language, Key::EventsPayDepositConsent))
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.deposit_consent = !this.deposit_consent;
                                    cx.notify();
                                }))
                                .into_any_element()
                        }))
                        .children(failed.map(|message| {
                            let text = if message == "deposit_consent" {
                                translate(language, Key::EventsPayDepositConsent)
                            } else {
                                translate(language, Key::EventsPayFailed)
                            };
                            div()
                                .text_size(px(12.0))
                                .text_color(palette.danger)
                                .child(text)
                                .into_any_element()
                        }))
                        .into_any_element()
                }
                PaymentViewState::Creating => div()
                    .text_size(px(12.0))
                    .text_color(palette.ink_3)
                    .child(translate(language, Key::EventsPayCreating))
                    .into_any_element(),
                PaymentViewState::Qr { url, expire_at, .. } => {
                    let qr_element: AnyElement = match encode_qr(&url) {
                        Ok(matrix) => render_qr(&matrix, black(), white(), px(200.0)),
                        Err(QrError::Empty | QrError::TooLong | QrError::Encode(_)) => div()
                            .text_color(palette.danger)
                            .child(translate(language, Key::EventsPayFailed))
                            .into_any_element(),
                    };
                    let remaining = expire_at
                        .as_deref()
                        .and_then(payment_remaining_secs)
                        .map(|seconds| format!("{:02}:{:02}", seconds / 60, seconds % 60));
                    div()
                        .flex()
                        .flex_col()
                        .items_start()
                        .gap(space(1))
                        .child(qr_element)
                        .child(
                            div()
                                .text_size(px(12.0))
                                .text_color(palette.ink_2)
                                .child(translate(language, Key::EventsPayScanHint)),
                        )
                        .children(remaining.map(|remaining| {
                            div()
                                .text_size(px(12.0))
                                .text_color(palette.ink_3)
                                .child(format!(
                                    "{} {remaining}",
                                    translate(language, Key::EventsPayRemaining)
                                ))
                                .into_any_element()
                        }))
                        .child(
                            div()
                                .id("pay-close")
                                .px(space(1))
                                .py(px(3.0))
                                .rounded(px(RADIUS_SMALL))
                                .bg(palette.soft)
                                .text_size(px(12.0))
                                .text_color(palette.ink_2)
                                .child(translate(language, Key::EventsPayClose))
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.close_payment(cx);
                                })),
                        )
                        .into_any_element()
                }
                PaymentViewState::Terminal(status) => div()
                    .text_size(px(12.0))
                    .text_color(palette.danger)
                    .child(terminal_status_label(language, &status))
                    .into_any_element(),
                PaymentViewState::Paid => div()
                    .text_size(px(12.0))
                    .text_color(palette.accent)
                    .child(translate(language, Key::EventsPayPaid))
                    .into_any_element(),
            };

            let cancel = div()
                .id("enroll-cancel")
                .px(space(1))
                .py(px(3.0))
                .rounded(px(RADIUS_SMALL))
                .bg(palette.soft)
                .text_size(px(12.0))
                .text_color(palette.ink_3)
                .child(translate(language, Key::EventsEnrollCancel))
                .on_click(cx.listener(|this, _, _, cx| {
                    this.cancel_enrollment_action(cx);
                }));
            return div()
                .mt(space(2))
                .flex()
                .flex_col()
                .gap(space(1))
                .child(status)
                .child(payment_body)
                .child(cancel)
                .into_any_element();
        }

        if detail.enrollment_policy == "invite_only" {
            return div()
                .mt(space(2))
                .text_size(px(12.0))
                .text_color(palette.ink_3)
                .child(translate(language, Key::EventsEnrollInviteRequired))
                .into_any_element();
        }
        if detail.status != "open" {
            return div()
                .mt(space(2))
                .text_size(px(12.0))
                .text_color(palette.danger)
                .child(translate(language, Key::EventsEnrollErrorNotOpen))
                .into_any_element();
        }

        let selected_tier = self.selected_tier.clone();
        let tier_chips: Vec<AnyElement> = detail
            .available_price_tiers
            .iter()
            .map(|tier| {
                let selected = selected_tier.as_deref() == Some(tier.id.as_str());
                let tier_id = tier.id.clone();
                div()
                    .id(format!("enroll-tier-{}", tier.id))
                    .px(space(1))
                    .py(px(3.0))
                    .rounded(px(RADIUS_SMALL))
                    .text_size(px(12.0))
                    .bg(if selected {
                        palette.accent
                    } else {
                        palette.soft
                    })
                    .text_color(if selected {
                        palette.canvas
                    } else {
                        palette.ink_2
                    })
                    .child(format!(
                        "{} ¥{:.2}",
                        tier.name,
                        tier.amount_cents as f64 / 100.0
                    ))
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.selected_tier = Some(tier_id.clone());
                        cx.notify();
                    }))
                    .into_any_element()
            })
            .collect();

        let age_confirm = detail.min_age.map(|min_age| {
            let checked = self.age_confirmed;
            div()
                .id("enroll-age-confirm")
                .flex()
                .flex_row()
                .items_center()
                .gap(px(4.0))
                .text_size(px(12.0))
                .text_color(palette.ink_2)
                .child(if checked { "☑" } else { "☐" })
                .child(format!(
                    "{} ({min_age}+)",
                    translate(language, Key::EventsEnrollAgeConfirm)
                ))
                .on_click(cx.listener(|this, _, _, cx| {
                    this.age_confirmed = !this.age_confirmed;
                    cx.notify();
                }))
                .into_any_element()
        });

        let error = self.enrollment_error.as_deref().map(|suffix| {
            div()
                .text_size(px(12.0))
                .text_color(palette.danger)
                .child(enroll_error_label(language, suffix))
                .into_any_element()
        });

        let submit = div()
            .id("events-enroll-button")
            .px(space(2))
            .py(px(6.0))
            .rounded(px(RADIUS_MEDIUM))
            .bg(if self.enrolling {
                palette.soft
            } else {
                palette.accent
            })
            .text_color(if self.enrolling {
                palette.ink_3
            } else {
                palette.canvas
            })
            .child(if self.enrolling {
                translate(language, Key::EventsEnrollEnrolling)
            } else {
                translate(language, Key::EventsEnrollButton)
            })
            .on_click(cx.listener(|this, _, _, cx| {
                this.submit_enrollment(cx);
            }));

        div()
            .mt(space(2))
            .flex()
            .flex_col()
            .gap(space(1))
            .children((detail.pricing_enabled && !tier_chips.is_empty()).then(|| {
                div()
                    .flex()
                    .flex_col()
                    .gap(px(4.0))
                    .child(
                        div()
                            .text_size(px(12.0))
                            .text_color(palette.ink_3)
                            .child(translate(language, Key::EventsEnrollTier)),
                    )
                    .children(tier_chips)
                    .into_any_element()
            }))
            .children(age_confirm)
            .children(error)
            .child(submit)
            .into_any_element()
    }

    pub(in crate::root_view) fn render_events_list(
        &mut self,
        language: Language,
        palette: &theme::Palette,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let filter = self.events.filter();
        let state = self.events.state().clone();
        let items = self.events.items().to_vec();
        let has_more = self.events.has_more();
        let selected = self.selected_event.clone();

        let filters = StatusFilter::ALL
            .iter()
            .map(|candidate| {
                let candidate = *candidate;
                let active = candidate == filter;
                div()
                    .id(format!("events-filter-{:?}", candidate).to_lowercase())
                    .px(space(1))
                    .py(px(3.0))
                    .rounded(px(RADIUS_MEDIUM))
                    .text_size(px(12.0))
                    .text_color(if active {
                        palette.canvas
                    } else {
                        palette.ink_2
                    })
                    .bg(if active { palette.accent } else { palette.soft })
                    .child(translate(language, filter_key(candidate)))
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.select_events_filter(candidate, cx);
                    }))
                    .into_any_element()
            })
            .collect::<Vec<_>>();

        let body: AnyElement = match state {
            ListState::Idle | ListState::Loading => div()
                .text_color(palette.ink_3)
                .child(translate(language, Key::EventsListLoading))
                .into_any_element(),
            ListState::Failed(message) => div()
                .flex()
                .flex_col()
                .gap(space(1))
                .child(div().text_color(palette.danger).child(message))
                .child(
                    div()
                        .id("events-retry")
                        .px(space(2))
                        .py(px(5.0))
                        .rounded(px(RADIUS_MEDIUM))
                        .bg(palette.accent)
                        .text_color(white())
                        .child(translate(language, Key::EventsListRetry))
                        .on_click(cx.listener(|this, _, _, cx| this.retry_events(cx))),
                )
                .into_any_element(),
            ListState::Empty => div()
                .text_color(palette.ink_3)
                .child(translate(language, Key::EventsListEmpty))
                .into_any_element(),
            ListState::Ready => {
                let rows = items
                    .iter()
                    .map(|event| {
                        let event = event.clone();
                        let starts = event
                            .starts_at
                            .as_deref()
                            .map(|value| value.chars().take(10).collect::<String>())
                            .unwrap_or_default();
                        let price = if event.pricing_enabled {
                            translate(language, Key::EventsListPaid)
                        } else {
                            translate(language, Key::EventsListFree)
                        };
                        div()
                            .id(format!("event-row-{}", event.id))
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
                                            .child(format!("{starts} · {price}")),
                                    ),
                            )
                            .child(
                                div()
                                    .flex()
                                    .items_center()
                                    .gap(space(1))
                                    .child(
                                        div()
                                            .px(px(6.0))
                                            .py(px(2.0))
                                            .rounded(px(RADIUS_SMALL))
                                            .bg(palette.soft)
                                            .text_size(px(11.0))
                                            .text_color(palette.ink_2)
                                            .child(translate(
                                                language,
                                                status_key(event.status.as_str()),
                                            )),
                                    )
                                    .child(
                                        div().text_size(px(11.0)).text_color(palette.ink_3).child(
                                            match (event.confirmed_count, event.capacity) {
                                                (Some(confirmed), Some(capacity)) => {
                                                    format!("{confirmed}/{capacity}")
                                                }
                                                (Some(confirmed), None) => {
                                                    format!("{confirmed}/∞")
                                                }
                                                _ => String::new(),
                                            },
                                        ),
                                    ),
                            )
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.navigate_to_event_detail(&event.id);
                                cx.notify();
                            }))
                            .into_any_element()
                    })
                    .collect::<Vec<_>>();

                let detail_notice = selected.map(|title| {
                    div()
                        .mt(space(2))
                        .text_size(px(12.0))
                        .text_color(palette.ink_3)
                        .child(format!(
                            "{title} — {}",
                            translate(language, Key::EventsListDetail)
                        ))
                        .into_any_element()
                });

                let load_more = has_more.then(|| {
                    div()
                        .id("events-load-more")
                        .mt(space(2))
                        .px(space(2))
                        .py(px(5.0))
                        .rounded(px(RADIUS_MEDIUM))
                        .border_1()
                        .border_color(palette.line_strong)
                        .text_color(palette.ink_2)
                        .child(translate(language, Key::EventsListLoadMore))
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.start_events_load(cx, false);
                        }))
                        .into_any_element()
                });

                div()
                    .flex()
                    .flex_col()
                    .children(rows)
                    .children(load_more)
                    .children(detail_notice)
                    .into_any_element()
            }
        };

        div()
            .flex()
            .flex_col()
            .gap(space(2))
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .justify_between()
                    .child(
                        div()
                            .text_size(px(24.0))
                            .text_color(palette.ink)
                            .child(translate_registered(language, "events.list.title")),
                    )
                    .child(
                        div()
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap(space(1))
                            .children(filters),
                    ),
            )
            .child(body)
            .into_any_element()
    }
}
