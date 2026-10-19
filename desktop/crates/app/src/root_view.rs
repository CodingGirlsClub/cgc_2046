//! 最小窗口视图：左侧导航壳 + 右侧空态页。
//!
//! 本 story 只做骨架；设计 token 在 1.2、i18n 在 1.3、无障碍在 1.5。

use gpui_kit::*;

use crate::routing::RouteRegistry;
use crate::strings::{APP_NAME_KEY, EMPTY_BODY_KEY, EMPTY_TITLE_KEY};

pub struct RootView {
    registry: RouteRegistry,
}

impl RootView {
    pub fn new(registry: RouteRegistry) -> Self {
        Self { registry }
    }
}

impl Render for RootView {
    fn render(&mut self, _window: &mut Window, _cx: &mut Context<Self>) -> impl IntoElement {
        let nav_items = self
            .registry
            .routes()
            .iter()
            .map(|route| div().child(route.title_key).into_any_element())
            .collect::<Vec<_>>();

        div()
            .size_full()
            .flex()
            .flex_row()
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap_2()
                    .child(APP_NAME_KEY)
                    .children(nav_items),
            )
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap_2()
                    .items_center()
                    .justify_center()
                    .child(EMPTY_TITLE_KEY)
                    .child(EMPTY_BODY_KEY),
            )
    }
}
