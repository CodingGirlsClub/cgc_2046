//! 应用外壳：左侧导航（聚合注册路由）+ 右侧当前路由占位页 + 主题/语言切换。
//!
//! 颜色与间距来自 `theme` 的设计 token（story 1.2）；文案来自 `i18n`（story 1.3）；
//! 导航项完全由 `registration` 聚合出的注册表驱动（story 1.4）——
//! 新增一个 domain 的 `ROUTES` 条目就会自动出现在导航里。

use gpui_kit::*;

use crate::i18n::{default_language, translate, Language};
use crate::routing::{Route, RouteRegistry};
use crate::theme::{self, space, ThemePreference, RADIUS_MEDIUM, RADIUS_SMALL};

pub struct RootView {
    registry: RouteRegistry,
    current: Option<Route>,
    language: Language,
    preference: ThemePreference,
}

impl RootView {
    pub fn new(registry: RouteRegistry) -> Self {
        let current = registry.routes().first().copied();
        Self {
            registry,
            current,
            language: default_language(),
            preference: theme::preference_from_env(),
        }
    }

    pub fn current(&self) -> Option<Route> {
        self.current
    }

    pub fn language(&self) -> Language {
        self.language
    }

    pub fn preference(&self) -> ThemePreference {
        self.preference
    }

    pub fn select(&mut self, route: Route) {
        self.current = Some(route);
    }

    pub fn toggle_language(&mut self) -> Language {
        self.language = self.language.toggle();
        self.language
    }

    pub fn cycle_theme(&mut self) -> ThemePreference {
        self.preference = self.preference.cycle();
        self.preference
    }
}

impl Render for RootView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let mode = theme::resolve(self.preference, window.appearance());
        let palette = theme::palette(mode);
        let language = self.language;
        let current = self.current;

        let nav_items = self
            .registry
            .routes()
            .iter()
            .map(|route| {
                let route = *route;
                let selected = current.is_some_and(|current| current.id == route.id);
                let item = div()
                    .id(route.id)
                    .flex()
                    .items_center()
                    .h(px(34.0))
                    .px(space(1))
                    .rounded(px(RADIUS_SMALL))
                    .text_color(if selected { palette.ink } else { palette.ink_2 })
                    .child(translate(language, route.title_key))
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.select(route);
                        cx.notify();
                    }));
                if selected {
                    item.bg(palette.soft)
                } else {
                    item
                }
            })
            .collect::<Vec<_>>();

        let content = match current {
            Some(route) => div()
                .flex()
                .flex_col()
                .gap(space(2))
                .child(
                    div()
                        .text_size(px(24.0))
                        .text_color(palette.ink)
                        .child(translate(language, route.title_key)),
                )
                .child(
                    div()
                        .text_color(palette.ink_3)
                        .child(translate(language, "app.placeholder.body")),
                )
                .into_any_element(),
            None => div()
                .flex()
                .flex_col()
                .items_center()
                .justify_center()
                .gap(space(2))
                .child(
                    div()
                        .text_size(px(22.0))
                        .text_color(palette.ink)
                        .child(translate(language, "app.empty.title")),
                )
                .child(
                    div()
                        .text_color(palette.ink_3)
                        .child(translate(language, "app.empty.body")),
                )
                .into_any_element(),
        };

        let theme_label = translate(language, self.preference.label_key());
        let language_label = translate(
            language,
            match language {
                Language::Zh => "app.lang.zh",
                Language::En => "app.lang.en",
            },
        );

        div()
            .size_full()
            .flex()
            .flex_row()
            .bg(palette.canvas)
            .text_color(palette.ink)
            .text_size(px(14.0))
            .child(
                div()
                    .flex()
                    .flex_col()
                    .w(px(220.0))
                    .h_full()
                    .p(space(4))
                    .gap(space(1))
                    .bg(palette.frame)
                    .border_r_1()
                    .border_color(palette.line)
                    .child(
                        div()
                            .text_size(px(17.0))
                            .text_color(palette.ink)
                            .child(translate(language, "app.name")),
                    )
                    .child(
                        div()
                            .mt(space(2))
                            .text_size(px(11.0))
                            .text_color(palette.ink_3)
                            .child(translate(language, "app.nav.label")),
                    )
                    .children(nav_items)
                    .child(div().flex_1())
                    .child(
                        div()
                            .flex()
                            .gap(space(1))
                            .child(
                                div()
                                    .id("theme-toggle")
                                    .px(space(1))
                                    .py(px(6.0))
                                    .rounded(px(RADIUS_MEDIUM))
                                    .border_1()
                                    .border_color(palette.line_strong)
                                    .text_color(palette.ink_2)
                                    .child(theme_label)
                                    .on_click(cx.listener(|this, _, window, cx| {
                                        let preference = this.cycle_theme();
                                        let mode = theme::resolve(preference, window.appearance());
                                        theme::apply(mode, cx);
                                        cx.notify();
                                    })),
                            )
                            .child(
                                div()
                                    .id("language-toggle")
                                    .px(space(1))
                                    .py(px(6.0))
                                    .rounded(px(RADIUS_MEDIUM))
                                    .border_1()
                                    .border_color(palette.line_strong)
                                    .text_color(palette.ink_2)
                                    .child(language_label)
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.toggle_language();
                                        cx.notify();
                                    })),
                            ),
                    ),
            )
            .child(div().flex_1().h_full().p(space(6)).child(content))
    }
}

#[cfg(test)]
mod tests {
    use super::RootView;
    use crate::i18n::{translate, Language};
    use crate::registration::build_registry;
    use crate::theme::ThemePreference;

    fn view() -> RootView {
        RootView::new(build_registry().expect("registry builds"))
    }

    #[test]
    fn starts_on_home_and_in_chinese_by_default() {
        std::env::remove_var("CGC_LANG");
        let view = view();
        assert_eq!(view.current().map(|route| route.id), Some("app.home"));
        assert_eq!(view.language(), Language::Zh);
        assert_eq!(view.preference(), ThemePreference::System);
    }

    #[test]
    fn toggling_language_changes_labels() {
        let mut view = view();
        let before = translate(view.language(), "app.empty.title");
        view.toggle_language();
        let after = translate(view.language(), "app.empty.title");
        assert_ne!(before, after);
        view.toggle_language();
        assert_eq!(translate(view.language(), "app.empty.title"), before);
    }

    #[test]
    fn cycling_theme_visits_all_preferences() {
        let mut view = view();
        assert_eq!(view.cycle_theme(), ThemePreference::Light);
        assert_eq!(view.cycle_theme(), ThemePreference::Dark);
        assert_eq!(view.cycle_theme(), ThemePreference::System);
    }

    #[test]
    fn selecting_a_registered_route_updates_current() {
        let mut view = view();
        let events = view
            .registry
            .routes()
            .iter()
            .find(|route| route.id == "events.list")
            .copied()
            .expect("events route registered");
        view.select(events);
        assert_eq!(view.current().map(|route| route.id), Some("events.list"));
    }
}
