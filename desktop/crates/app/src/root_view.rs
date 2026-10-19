//! 应用外壳：顶部 header（品牌 + 一级导航，聚合注册路由）+ 内容区 + 底部 footer
//! （status bar：主题/语言/版本）。布局参考 Zed：一级入口在顶部 tab bar，工具与
//! 状态按钮在底部 status bar，左右 side panel 留给后续上下文面板（dock）。
//!
//! 颜色与间距来自 `theme` 的设计 token（story 1.2）；文案来自 `i18n`（story 1.3）；
//! 导航项完全由 `registration` 聚合出的注册表驱动（story 1.4）——
//! 新增一个 domain 的 `ROUTES` 条目就会自动出现在导航里。

use gpui_kit::*;

use crate::i18n::{default_language, translate, translate_registered, Key, Language};
use crate::routing::{Route, RouteRegistry};
use crate::theme::{self, space, ThemePreference, RADIUS_MEDIUM};

pub struct RootView {
    registry: RouteRegistry,
    current: Option<Route>,
    language: Language,
    preference: ThemePreference,
}

impl RootView {
    pub fn new(registry: RouteRegistry) -> Self {
        Self::with_startup(registry, default_language(), theme::preference_from_env())
    }

    /// 显式启动状态的构造器：测试与将来的设置页恢复都用它，避免读进程环境变量。
    pub fn with_startup(
        registry: RouteRegistry,
        language: Language,
        preference: ThemePreference,
    ) -> Self {
        let current = registry.routes().first().copied();
        Self {
            registry,
            current,
            language,
            preference,
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

    /// 系统外观变化时由 `observe_window_appearance` 调用：只有「跟随系统」才重刷 kit 主题。
    pub fn on_appearance_changed(&mut self, appearance: WindowAppearance, cx: &mut Context<Self>) {
        if self.preference == ThemePreference::System {
            theme::apply(theme::resolve(self.preference, appearance), cx);
            cx.notify();
        }
    }
}

impl Render for RootView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let mode = theme::resolve(self.preference, window.appearance());
        let palette = theme::palette(mode);
        let language = self.language;
        let current = self.current;

        // 顶部 header：品牌 + 一级导航（domain 注册表驱动）。
        let nav_items = self
            .registry
            .routes()
            .iter()
            .map(|route| {
                let route = *route;
                let selected = current.is_some_and(|current| current.id == route.id);
                let tab = div()
                    .id(route.id)
                    .flex()
                    .items_center()
                    .h_full()
                    .px(space(2))
                    .text_color(if selected { palette.ink } else { palette.ink_2 })
                    .child(translate_registered(language, route.title_key))
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.select(route);
                        cx.notify();
                    }));
                if selected {
                    tab.border_b_2().border_color(palette.accent)
                } else {
                    tab
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
                        .child(translate_registered(language, route.title_key)),
                )
                .child(
                    div()
                        .text_color(palette.ink_3)
                        .child(translate(language, Key::AppPlaceholderBody)),
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
                        .child(translate(language, Key::AppEmptyTitle)),
                )
                .child(
                    div()
                        .text_color(palette.ink_3)
                        .child(translate(language, Key::AppEmptyBody)),
                )
                .into_any_element(),
        };

        let theme_label = translate(language, self.preference.label_key());
        let language_label = translate(
            language,
            match language {
                Language::Zh => Key::AppLangZh,
                Language::En => Key::AppLangEn,
            },
        );

        // 顶部：Zed 的 tab bar / toolbar 位置放一级导航；底部：Zed 的 status bar
        // 位置放主题、语言等工具按钮（status_bar.rs 里侧栏开关同样在底部状态栏）。
        div()
            .size_full()
            .flex()
            .flex_col()
            .bg(palette.canvas)
            .text_color(palette.ink)
            .font_family(theme::FONT_SANS)
            .text_size(px(14.0))
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .h(px(48.0))
                    .px(space(3))
                    .gap(space(1))
                    .bg(palette.frame)
                    .border_b_1()
                    .border_color(palette.line)
                    .child(
                        div()
                            .text_size(px(15.0))
                            .text_color(palette.ink)
                            .child(translate(language, Key::AppName)),
                    )
                    .child(div().w(space(2)))
                    .children(nav_items)
                    .child(div().flex_1()),
            )
            .child(div().flex_1().w_full().p(space(6)).child(content))
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .h(px(30.0))
                    .px(space(2))
                    .gap(space(1))
                    .bg(palette.frame)
                    .border_t_1()
                    .border_color(palette.line)
                    .text_size(px(12.0))
                    .child(
                        div()
                            .id("theme-toggle")
                            .px(space(1))
                            .py(px(2.0))
                            .rounded(px(RADIUS_MEDIUM))
                            .text_color(palette.ink_3)
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
                            .py(px(2.0))
                            .rounded(px(RADIUS_MEDIUM))
                            .text_color(palette.ink_3)
                            .child(language_label)
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.toggle_language();
                                cx.notify();
                            })),
                    )
                    .child(div().flex_1())
                    .child(
                        div()
                            .text_color(palette.ink_3)
                            .child(concat!("v", env!("CARGO_PKG_VERSION"))),
                    ),
            )
    }
}

#[cfg(test)]
mod tests {
    // 注意：不要改成 `use super::*`——父模块的 `use gpui_kit::*` 会引入 gpui 的
    // `test` 宏并遮蔽 std 的 `#[test]`；本模块只做显式导入。
    use super::RootView;
    use crate::i18n::{translate, Key, Language};
    use crate::registration::build_registry;
    use crate::theme::ThemePreference;

    fn view() -> RootView {
        RootView::with_startup(
            build_registry().expect("registry builds"),
            Language::Zh,
            ThemePreference::System,
        )
    }

    #[test]
    fn starts_on_home_with_explicit_startup_state() {
        let view = view();
        assert_eq!(view.current().map(|route| route.id), Some("app.home"));
        assert_eq!(view.language(), Language::Zh);
        assert_eq!(view.preference(), ThemePreference::System);
    }

    #[test]
    fn toggling_language_changes_labels() {
        let mut view = view();
        let before = translate(view.language(), Key::AppEmptyTitle);
        view.toggle_language();
        let after = translate(view.language(), Key::AppEmptyTitle);
        assert_ne!(before, after);
        view.toggle_language();
        assert_eq!(translate(view.language(), Key::AppEmptyTitle), before);
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
