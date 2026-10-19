//! CGC Desktop 入口：聚合注册 → 校验 → 应用启动主题 → 打开主窗口。
//!
//! 顶部 header / 底部 footer 的外壳样式在 `root_view`；系统外观变化由
//! `observe_window_appearance` 转给 `RootView::on_appearance_changed`。

use cgc_desktop_app::registration::{build_registry, validate};
use cgc_desktop_app::root_view::RootView;
use cgc_desktop_app::theme::{self, preference_from_env};
use gpui_kit::AppContext as _;

fn main() {
    let registry = build_registry().expect("route registration must be valid");
    validate(&registry).expect("i18n registration must be valid");
    let startup_registry = registry.clone();

    gpui_kit::application().run(move |cx| {
        gpui_kit::init(cx);
        gpui_kit::open_window(
            gpui_kit::WindowOptions {
                // 参考 Zed build_window_options：透明 titlebar + 自绘 header，
                // 红绿灯位置由 gpui 负责；Linux/Wayland 用 client side decorations。
                titlebar: Some(gpui_kit::TitlebarOptions {
                    title: None,
                    appears_transparent: true,
                    traffic_light_position: Some(gpui_kit::point(
                        gpui_kit::px(12.0),
                        gpui_kit::px(12.0),
                    )),
                }),
                app_owns_titlebar_drag: cfg!(target_os = "macos"),
                window_decorations: Some(gpui_kit::WindowDecorations::Client),
                window_min_size: Some(gpui_kit::Size {
                    width: gpui_kit::px(720.0),
                    height: gpui_kit::px(480.0),
                }),
                ..Default::default()
            },
            cx,
            move |window, cx| {
                let preference = preference_from_env();
                theme::apply(theme::resolve(preference, window.appearance()), cx);

                let view_registry = startup_registry.clone();
                let view = cx.new(move |_| RootView::new(view_registry));

                let observer_view = view.clone();
                window
                    .observe_window_appearance(move |window, cx| {
                        observer_view.update(cx, |this, cx| {
                            this.on_appearance_changed(window.appearance(), cx);
                        });
                    })
                    .detach();

                view
            },
        )
        .expect("main window opens");
    });
}
