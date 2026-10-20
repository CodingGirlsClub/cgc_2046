//! 中心 Pane 的 TabBar。Tab 状态在 ShellState；本模块只做渲染与动作派发。

use super::super::super::*;
use super::super::ScreenContext;

pub(in crate::root_view) fn render_pane_tabs(
    ctx: &mut ScreenContext<'_>,
    palette: &theme::Palette,
    cx: &mut Context<RootView>,
) -> AnyElement {
    let tabs = ctx.tabs.clone();
    let notice = ctx.pane_notice.clone();
    if tabs.is_empty() && notice.is_none() {
        return div().into_any_element();
    }
    let active = ctx.active_tab.clone();
    let mut items = Vec::new();
    for tab in tabs {
        let id = tab.id.clone();
        let activate_id = id.clone();
        let close_id = id.clone();
        let is_active = active.as_deref() == Some(id.as_str());
        let mut item = div()
            .id(SharedString::from(format!("pane-tab-{id}")))
            .flex()
            .flex_row()
            .items_center()
            .gap(px(4.0))
            .h(px(32.0))
            .min_w(px(80.0))
            .max_w(px(220.0))
            .px(space(2))
            .border_r_1()
            .border_color(palette.line)
            .text_size(px(12.0))
            .text_color(if is_active {
                palette.ink
            } else {
                palette.ink_3
            })
            .bg(if is_active {
                palette.view
            } else {
                palette.frame
            })
            .hover(|style| style.bg(palette.soft))
            .child(
                div()
                    .flex_1()
                    .min_w(px(0.0))
                    .overflow_hidden()
                    .child(tab.title.clone()),
            )
            .child(
                div()
                    .id(SharedString::from(format!("pane-tab-close-{close_id}")))
                    .flex()
                    .items_center()
                    .justify_center()
                    .size(px(16.0))
                    .rounded(px(RADIUS_SMALL))
                    .text_size(px(11.0))
                    .text_color(palette.ink_3)
                    .hover(|style| style.bg(palette.soft).text_color(palette.ink))
                    .child("×")
                    .on_click(cx.listener(move |this, _, _, cx| {
                        cx.stop_propagation();
                        this.close_pane_tab(&close_id, cx);
                    })),
            )
            .on_click(cx.listener(move |this, _, _, cx| {
                this.activate_tab(&activate_id, cx);
            }));
        if is_active {
            item = item.border_b_2().border_color(palette.accent);
        }
        items.push(item.into_any_element());
    }
    if let Some(notice) = notice {
        items.push(
            div()
                .id("pane-notice")
                .flex()
                .flex_row()
                .items_center()
                .gap(px(4.0))
                .px(space(1))
                .py(px(2.0))
                .text_size(px(10.0))
                .text_color(palette.ink_3)
                .child(notice)
                .child(
                    div()
                        .id("pane-notice-dismiss")
                        .px(px(3.0))
                        .rounded(px(RADIUS_SMALL))
                        .hover(|style| style.bg(palette.soft))
                        .child("×")
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.clear_pane_notice(cx);
                        })),
                )
                .into_any_element(),
        );
    }
    div()
        .id("pane-tab-bar")
        .flex()
        .flex_row()
        .items_center()
        .w_full()
        .h(px(32.0))
        .flex_none()
        .border_b_1()
        .border_color(palette.line)
        .bg(palette.frame)
        .children(items)
        .into_any_element()
}
