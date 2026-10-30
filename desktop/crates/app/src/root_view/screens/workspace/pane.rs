//! 中心 Pane 的 TabBar。Tab 状态在 ShellState；本模块只做渲染与动作派发。

use super::super::super::*;
use super::super::ScreenContext;
use gpui_kit::component::tab::{Tab, TabBar};

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
    let selected = tabs
        .iter()
        .position(|tab| active.as_deref() == Some(tab.id.as_str()));
    let mut tab_elements = Vec::new();
    for tab in tabs {
        let close_id = tab.id.clone();
        let open_id = tab.id.clone();
        let close_root = cx.entity().downgrade();
        let open_root = close_root.clone();
        let close = div()
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
            .on_click(move |_, _, cx| {
                cx.stop_propagation();
                let _ = close_root.update(cx, |this, cx| this.close_pane_tab(&close_id, cx));
            });
        tab_elements.push(
            Tab::new()
                .label(tab.title)
                .suffix(close)
                .on_click(move |_, _, cx| {
                    let _ = open_root.update(cx, |this, cx| this.activate_tab(&open_id, cx));
                }),
        );
    }
    // TabBar 默认 variant 自带 bottom border；再叠一条会让中间栏的线比左右栏粗，
    // 且两条线错开 1px。只保留 TabBar 自己的一条，高度与三栏 header 共用。
    let mut bar = TabBar::new("pane-tab-bar")
        .max_width(px(220.0))
        .children(tab_elements)
        .bg(palette.frame)
        .h(px(COLUMN_HEADER_HEIGHT))
        .text_size(px(12.0))
        .w_full();
    if let Some(selected) = selected {
        bar = bar.selected_index(selected);
    }
    if let Some(notice) = notice {
        let root = cx.entity().downgrade();
        bar = bar.suffix(
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
                        .on_click(move |_, _, cx| {
                            let _ = root.update(cx, |this, cx| this.clear_pane_notice(cx));
                        }),
                ),
        );
    }
    bar.into_any_element()
}
