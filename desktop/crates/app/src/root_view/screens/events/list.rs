use super::super::super::*;
use super::super::ScreenContext;
use gpui_kit::component::button::{Button, ButtonVariants};

pub(in crate::root_view) fn render_events_list(
    ctx: &mut ScreenContext<'_>,
    language: Language,
    palette: &theme::Palette,
    cx: &mut Context<RootView>,
) -> AnyElement {
    let public_face = ctx
        .current
        .as_ref()
        .is_some_and(|route_match| route_match.route.id == "events.public_list");
    let title_key = if public_face {
        Key::EventsPublicTitle
    } else {
        Key::EventsListTitle
    };
    let empty_key = if public_face {
        Key::EventsPublicEmpty
    } else {
        Key::EventsListEmpty
    };
    let filter = ctx.events.filter();
    let state = ctx.events.state().clone();
    let items = ctx.events.items().to_vec();
    let has_more = ctx.events.has_more();
    let selected = ctx.selected_event.clone();

    let filters = if public_face {
        Vec::new()
    } else {
        StatusFilter::ALL
            .iter()
            .map(|candidate| {
                let candidate = *candidate;
                let active = candidate == filter;
                div()
                    .id(format!("events-filter-{:?}", candidate).to_lowercase())
                    .test_support()
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
            .collect::<Vec<_>>()
    };

    let body: AnyElement = match state {
        ListState::Idle | ListState::Loading => {
            render_loading_state(language, Key::EventsListLoading, palette).into_any_element()
        }
        ListState::Failed(message) => div()
            .flex()
            .flex_col()
            .gap(space(1))
            .child(div().text_color(palette.danger).child(message))
            .child({
                let root = cx.entity().downgrade();
                Button::new("events-retry")
                    .label(translate(language, Key::EventsListRetry))
                    .primary()
                    .on_click(move |_, _, cx| {
                        let _ = root.update(cx, |this, cx| this.retry_events(cx));
                    })
            })
            .into_any_element(),
        ListState::Empty => div()
            .id("events-list-empty")
            .test_support()
            .role(Role::Status)
            .aria_label(translate(language, empty_key).to_string())
            .text_color(palette.ink_3)
            .child(translate(language, empty_key))
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
                                .child(div().text_size(px(11.0)).text_color(palette.ink_3).child(
                                    {
                                        let venue = event
                                            .venue
                                            .as_deref()
                                            .filter(|venue| !venue.trim().is_empty());
                                        let base = match (public_face, venue) {
                                            (true, Some(venue)) => {
                                                format!("{starts} · {venue} · {price}")
                                            }
                                            _ => format!("{starts} · {price}"),
                                        };
                                        match event.registration_deadline.as_deref() {
                                            Some(deadline) => {
                                                let deadline =
                                                    deadline.chars().take(10).collect::<String>();
                                                format!(
                                                    "{base} · {} {deadline}",
                                                    translate(language, Key::EventsListDeadline)
                                                )
                                            }
                                            None => base,
                                        }
                                    },
                                )),
                        )
                        .child(
                            div()
                                .flex()
                                .items_center()
                                .gap(space(1))
                                .child(if public_face {
                                    let badge = event
                                        .enrollment_badge
                                        .as_deref()
                                        .and_then(crate::root_view::nav_copy::enrollment_badge_key);
                                    match badge {
                                        Some(key) => {
                                            let label = translate(language, key);
                                            div()
                                                .id(format!("event-badge-{}", event.id))
                                                .test_support()
                                                .aria_label(label.to_string())
                                                .px(px(6.0))
                                                .py(px(2.0))
                                                .rounded(px(RADIUS_SMALL))
                                                .bg(palette.soft)
                                                .text_size(px(11.0))
                                                .text_color(palette.ink_2)
                                                .child(label)
                                                .into_any_element()
                                        }
                                        None => event_status_tag(
                                            event.status.as_str(),
                                            translate(language, status_key(event.status.as_str()))
                                                .into(),
                                        )
                                        .with_size(gpui_kit::component::Size::Small)
                                        .into_any_element(),
                                    }
                                } else {
                                    event_status_tag(
                                        event.status.as_str(),
                                        translate(language, status_key(event.status.as_str()))
                                            .into(),
                                    )
                                    .with_size(gpui_kit::component::Size::Small)
                                    .into_any_element()
                                })
                                .child(div().text_size(px(11.0)).text_color(palette.ink_3).child(
                                    match (event.confirmed_count, event.capacity) {
                                        (Some(confirmed), Some(capacity)) => {
                                            format!("{confirmed}/{capacity}")
                                        }
                                        (Some(confirmed), None) => {
                                            format!("{confirmed}/∞")
                                        }
                                        _ => String::new(),
                                    },
                                )),
                        )
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.navigate_to_event_detail(&event.id, cx);
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
                let root = cx.entity().downgrade();
                Button::new("events-load-more")
                    .label(translate(language, Key::EventsListLoadMore))
                    .secondary()
                    .mt(space(2))
                    .on_click(move |_, _, cx| {
                        let _ = root.update(cx, |this, cx| this.start_events_load(cx, false));
                    })
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
                        .id("events-list-title")
                        .test_support()
                        .role(Role::Heading)
                        .aria_label(translate(language, title_key).to_string())
                        .text_size(px(24.0))
                        .text_color(palette.ink)
                        .child(translate(language, title_key)),
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
