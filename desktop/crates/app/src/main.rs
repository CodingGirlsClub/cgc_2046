//! CGC Desktop 入口：初始化 gpui-kit，打开主窗口。

use cgc_desktop_app::root_view::RootView;
use cgc_desktop_app::routing::{Route, RouteId, RouteRegistry};
use cgc_desktop_app::strings::NAV_HOME_KEY;
use gpui_kit::AppContext as _;

fn main() {
    let mut registry = RouteRegistry::new();
    registry
        .register(Route {
            id: RouteId("home"),
            path: "/",
            title_key: NAV_HOME_KEY,
        })
        .expect("home route registers once");

    gpui_kit::application().run(move |cx| {
        gpui_kit::init(cx);
        let registry = registry.clone();
        gpui_kit::open_window(gpui_kit::WindowOptions::default(), cx, move |_, cx| {
            cx.new(|_| RootView::new(registry.clone()))
        })
        .expect("main window opens");
    });
}
