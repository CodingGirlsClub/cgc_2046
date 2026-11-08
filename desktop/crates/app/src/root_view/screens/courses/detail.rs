use super::super::super::*;
use super::super::ScreenContext;

pub(in crate::root_view) fn render_course_detail(
    ctx: &mut ScreenContext<'_>,
    language: Language,
    palette: &theme::Palette,
    cx: &mut Context<RootView>,
) -> AnyElement {
    let state = ctx.course_detail.state().clone();
    let detail = ctx.course_detail.detail().cloned();
    let course_id = ctx
        .current
        .as_ref()
        .and_then(|route_match| route_match.params.get("id"))
        .cloned()
        .unwrap_or_default();
    let public_face = ctx
        .current
        .as_ref()
        .is_some_and(|route_match| route_match.route.id == "courses.public_detail");

    let back_key = crate::root_view::nav_copy::course_detail_back_key(
        ctx.current
            .as_ref()
            .map(|route_match| route_match.route.id)
            .unwrap_or("courses.detail"),
    );
    let back = div()
        .id("course-detail-back")
        .text_size(px(12.0))
        .text_color(palette.ink_3)
        .child(translate(language, back_key))
        .on_click(cx.listener(|this, _, _, cx| {
            let public = this
                .current
                .as_ref()
                .is_some_and(|route_match| route_match.route.id == "courses.public_detail");
            let path = if public {
                "/courses".to_string()
            } else {
                this.workspace_path("/courses")
                    .unwrap_or_else(|| "/courses".to_string())
            };
            this.navigate(&path);
            cx.notify();
        }));

    let body: AnyElement = match state {
        CoursesListState::Idle | CoursesListState::Loading => {
            render_loading_state(language, Key::CoursesDetailLoading, palette).into_any_element()
        }
        CoursesListState::Failed(message) => {
            let not_found = message == "not found";
            div()
                .flex()
                .flex_col()
                .gap(space(1))
                .child(div().text_color(palette.danger).child(if not_found {
                    translate(language, Key::CoursesDetailNotFound)
                } else {
                    translate(language, Key::CoursesDetailError)
                }))
                .children((!not_found).then(|| {
                    div()
                        .id("course-detail-retry")
                        .px(space(2))
                        .py(px(5.0))
                        .rounded(px(RADIUS_MEDIUM))
                        .bg(palette.accent)
                        .text_color(white())
                        .child(translate(language, Key::CoursesDetailRetry))
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.course_detail.retry_ready();
                            this.course_detail_started = false;
                            cx.notify();
                        }))
                        .into_any_element()
                }))
                .into_any_element()
        }
        CoursesListState::Empty => div()
            .text_color(palette.ink_3)
            .child(translate(language, Key::CoursesDetailNotFound))
            .into_any_element(),
        CoursesListState::Ready => match detail {
            Some(detail) => {
                let enrollment_status = detail.enrollment_status.as_deref();
                let enrolled = enrollment_status == Some("confirmed");
                let pending =
                    matches!(enrollment_status, Some("pending") | Some("payment_pending"));
                let action = if enrolled {
                    let target = course_id.clone();
                    let workspace_id = detail.workspace_id.clone();
                    div()
                        .flex()
                        .flex_col()
                        .gap(px(4.0))
                        .child(
                            div()
                                .id("course-start-learning")
                                .px(space(2))
                                .py(px(6.0))
                                .rounded(px(RADIUS_MEDIUM))
                                .bg(palette.accent)
                                .text_color(white())
                                .child(translate(language, Key::CoursesDetailEnrolled))
                                .on_click(cx.listener(move |this, _, _, cx| {
                                    this.navigate_to_learning(&target, workspace_id.as_deref(), cx);
                                    cx.notify();
                                })),
                        )
                        .child(
                            div()
                                .text_size(px(11.0))
                                .text_color(palette.ink_3)
                                .child(translate(language, Key::CoursesLearningKeyboardHint)),
                        )
                        .into_any_element()
                } else if pending {
                    let status_key = if enrollment_status == Some("pending") {
                        Key::EventsEnrollStatusPending
                    } else {
                        Key::EventsEnrollStatusPaymentPending
                    };
                    div()
                        .flex()
                        .flex_col()
                        .gap(px(4.0))
                        .child(
                            div()
                                .text_size(px(12.0))
                                .text_color(palette.ink_2)
                                .child(translate(language, status_key)),
                        )
                        .child(
                            div()
                                .id("course-view-participations")
                                .test_support()
                                .role(Role::Link)
                                .aria_label(
                                    translate(language, Key::EventsEnrollViewParticipations)
                                        .to_string(),
                                )
                                .text_size(px(12.0))
                                .text_color(palette.accent)
                                .child(translate(language, Key::EventsEnrollViewParticipations))
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.navigate("/participations");
                                    cx.notify();
                                })),
                        )
                        .into_any_element()
                } else {
                    let target = course_id.clone();
                    if public_face && detail.visibility == "workspace" {
                        div()
                            .id("course-enroll-workspace-only")
                            .test_support()
                            .role(Role::Status)
                            .aria_label(
                                translate(language, Key::EventsEnrollWorkspaceOnly).to_string(),
                            )
                            .text_size(px(12.0))
                            .text_color(palette.ink_3)
                            .child(translate(language, Key::EventsEnrollWorkspaceOnly))
                            .into_any_element()
                    } else if detail.enrollment_policy == "invite_only" {
                        div()
                            .id("course-enroll-invite-only")
                            .test_support()
                            .role(Role::Status)
                            .aria_label(
                                translate(language, Key::CoursesEnrollInviteRequired).to_string(),
                            )
                            .text_size(px(12.0))
                            .text_color(palette.ink_3)
                            .child(translate(language, Key::CoursesEnrollInviteRequired))
                            .into_any_element()
                    } else if detail.status != "open" {
                        div()
                            .text_size(px(12.0))
                            .text_color(palette.danger)
                            .child(translate(language, Key::EventsEnrollErrorNotOpen))
                            .into_any_element()
                    } else {
                        let selected_tier = ctx.selected_tier.clone();
                        let selected_tier_unavailable =
                            selected_tier.as_deref().is_some_and(|id| {
                                detail
                                    .available_price_tiers
                                    .iter()
                                    .any(|tier| tier.id == id && tier.amount_cents.is_none())
                            });
                        let tier_chips = detail
                            .available_price_tiers
                            .iter()
                            .map(|tier| {
                                let price_known = tier.amount_cents.is_some();
                                let selected =
                                    price_known && selected_tier.as_deref() == Some(tier.id.as_str());
                                let tier_id = tier.id.clone();
                                let label = match tier.amount_cents {
                                    Some(cents) => {
                                        format!("{} ¥{:.2}", tier.name, cents as f64 / 100.0)
                                    }
                                    None => format!(
                                        "{} {}",
                                        tier.name,
                                        translate(language, Key::CoursesDetailPricePending)
                                    ),
                                };
                                div()
                                    .id(format!("course-tier-{}", tier.id))
                                    .px(space(1))
                                    .py(px(3.0))
                                    .rounded(px(RADIUS_SMALL))
                                    .text_size(px(12.0))
                                    .bg(if selected {
                                        palette.accent
                                    } else {
                                        palette.soft
                                    })
                                    .text_color(if !price_known {
                                        palette.ink_3
                                    } else if selected {
                                        palette.canvas
                                    } else {
                                        palette.ink_2
                                    })
                                    .child(label)
                                    .on_click(cx.listener(move |this, _, _, cx| {
                                        if price_known {
                                            this.selected_tier = Some(tier_id.clone());
                                            cx.notify();
                                        }
                                    }))
                                    .into_any_element()
                            })
                            .collect::<Vec<_>>();
                        let error = ctx.enrollment_error.as_deref().map(|suffix| {
                            div()
                                .text_size(px(12.0))
                                .text_color(palette.danger)
                                .child(enroll_error_label(language, suffix))
                                .into_any_element()
                        });
                        div()
                            .flex()
                            .flex_col()
                            .items_start()
                            .gap(space(1))
                            .children((detail.pricing_enabled && !tier_chips.is_empty()).then(
                                || {
                                    div()
                                        .flex()
                                        .flex_row()
                                        .items_center()
                                        .gap(space(1))
                                        .children(tier_chips)
                                        .into_any_element()
                                },
                            ))
                            .child(
                                div()
                                    .id("course-enroll-button")
                                    .test_support()
                                    .px(space(2))
                                    .py(px(6.0))
                                    .rounded(px(RADIUS_MEDIUM))
                                    .bg(if ctx.enrolling || selected_tier_unavailable {
                                        palette.soft
                                    } else {
                                        palette.accent
                                    })
                                    .text_color(if ctx.enrolling || selected_tier_unavailable {
                                        palette.ink_3
                                    } else {
                                        white()
                                    })
                                    .child(if selected_tier_unavailable {
                                        translate(language, Key::CoursesDetailPricePending)
                                    } else if ctx.enrolling {
                                        translate(language, Key::EventsEnrollEnrolling)
                                    } else {
                                        translate(language, Key::EventsEnrollButton)
                                    })
                                    .on_click(cx.listener(move |this, _, _, cx| {
                                        if !selected_tier_unavailable {
                                            this.submit_course_enrollment(&target, cx);
                                            cx.notify();
                                        }
                                    })),
                            )
                            .children(error)
                            .into_any_element()
                    }
                };

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
                    .children(super::super::render_workspace_badge(
                        ctx.workspaces.workspaces(),
                        detail.workspace_id.as_deref(),
                        language,
                        palette,
                    ))
                    .children(
                        public_face
                            .then(|| {
                                super::super::render_workspace_link(
                                    ctx.workspaces.workspaces(),
                                    detail.workspace_id.as_deref(),
                                    &format!("/courses/{}", detail.id),
                                    &detail.title,
                                    language,
                                    palette,
                                    cx,
                                )
                            })
                            .flatten(),
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
                                    .text_size(px(12.0))
                                    .text_color(palette.ink_2)
                                    .child(status_label(language, detail.status.as_str())),
                            )
                            .child(
                                div()
                                    .px(space(1))
                                    .py(px(3.0))
                                    .rounded(px(RADIUS_SMALL))
                                    .bg(palette.soft)
                                    .text_size(px(12.0))
                                    .text_color(palette.ink_2)
                                    .child(if detail.pricing_enabled {
                                        translate(language, Key::EventsDetailPaid)
                                    } else {
                                        translate(language, Key::EventsDetailFree)
                                    }),
                            ),
                    )
                    .child(action)
                    .into_any_element()
            }
            None => div()
                .text_color(palette.ink_3)
                .child(translate(language, Key::CoursesDetailNotFound))
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
