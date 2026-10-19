//! CGC Desktop 入口：聚合注册 → 校验 → 打开主窗口。

use cgc_desktop_app::registration::{build_registry, validate};
use cgc_desktop_app::root_view::RootView;
use cgc_desktop_app::theme::{self, ThemePreference};
use gpui_kit::AppContext as _;

fn main() {
    let registry = build_registry().expect("route registration must be valid");
    validate(&registry).expect("i18n registration must be valid");
    let view_registry = registry.clone();

    gpui_kit::application().run(move |cx| {
        gpui_kit::init(cx);
        gpui_kit::open_window(gpui_kit::WindowOptions::default(), cx, move |window, cx| {
            let mode = theme::resolve(ThemePreference::System, window.appearance());
            theme::apply(mode, cx);
            cx.new(|_| RootView::new(view_registry))
        })
        .expect("main window opens");
    });
}
