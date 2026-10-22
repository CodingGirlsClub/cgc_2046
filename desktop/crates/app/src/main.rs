//! CGC Desktop 入口：聚合注册 → 校验 → 应用启动主题 → 打开主窗口。
//!
//! 顶部 header / 底部 footer 的外壳样式在 `root_view`；系统外观变化由
//! `observe_window_appearance` 转给 `RootView::on_appearance_changed`。

use cgc_desktop_app::i18n::{default_language, translate, Key};
use cgc_desktop_app::registration::{build_registry, validate};
use cgc_desktop_app::root_view::RootView;
use cgc_desktop_app::theme;
use gpui_kit::AppContext as _;

fn main() {
    cgc_platform::telemetry::install_panic_hook_from_env();
    let registry = build_registry().expect("route registration must be valid");
    validate(&registry).expect("i18n registration must be valid");
    let startup_registry = registry.clone();

    gpui_kit::application()
        .with_assets(gpui_kit::assets::AllAssets)
        .run(move |cx| {
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
                        width: gpui_kit::px(800.0),
                        height: gpui_kit::px(560.0),
                    }),
                    ..Default::default()
                },
                cx,
                move |window, cx| {
                    theme::load_builtin_themes(cx);
                    let selected = theme::load_selected_theme()
                        .unwrap_or_else(|| theme::DEFAULT_THEME_NAME.to_string());
                    if !theme::apply_named(&selected, cx) {
                        let _ = theme::apply_named(theme::DEFAULT_THEME_NAME, cx);
                    }

                    let view_registry = startup_registry.clone();
                    let chat_input = cx.new(|cx| {
                        gpui_kit::component::input::TextareaState::new(window, cx)
                            .placeholder("给 agent 发消息… @ 引用上下文，/ 查看命令")
                    });
                    let config_search_input = cx.new(|cx| {
                        gpui_kit::component::input::InputState::new(window, cx).placeholder(
                            translate(default_language(), Key::AgentChatChatSelectOption),
                        )
                    });
                    let view = cx.new(move |_| RootView::new(view_registry));
                    view.update(cx, |this, _| {
                        this.set_chat_input(chat_input);
                        this.set_config_search_input(config_search_input);
                    });
                    // 登录页常驻扫码：启动即出码（fake 模式内部跳过）。
                    view.update(cx, |this, cx| this.ensure_wechat_login(cx));

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
