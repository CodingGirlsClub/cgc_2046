use super::super::super::*;
use super::super::ScreenContext;

pub(in crate::root_view) fn render_events_list(
    ctx: &mut ScreenContext<'_>,
    language: Language,
    palette: &theme::Palette,
    cx: &mut Context<RootView>,
) -> AnyElement {
    let filter = ctx.events.filter();
    let state = ctx.events.state().clone();
    let items = ctx.events.items().to_vec();
    let has_more = ctx.events.has_more();
    let selected = ctx.selected_event.clone();

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
