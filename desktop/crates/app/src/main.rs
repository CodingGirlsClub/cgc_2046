//! CGC Desktop 入口：聚合注册 → 校验 → 应用启动主题 → 打开主窗口。
//!
//! 顶部 header / 底部 footer 的外壳样式在 `root_view`；系统外观变化由
//! `observe_window_appearance` 转给 `RootView::on_appearance_changed`。

use cgc_desktop_app::i18n::{default_language, translate, Key};
use cgc_desktop_app::icons::TRAY_ICON_PNG;
use cgc_desktop_app::registration::{build_registry, validate};
use cgc_desktop_app::root_view::{main_window_options, RootView};
use cgc_desktop_app::theme;
use gpui_kit::AppContext as _;
use gpui_kit::{point, px, size, Bounds, WindowBounds};
use std::sync::atomic::AtomicBool;
use std::sync::{Arc, Mutex};

fn main() {
    let paths = cgc_platform::paths::AppPaths::from_env();
    // 日志先于一切：用户双击 .app 启动时 stderr 不可见，出问题只能靠文件取证。
    let log_path = cgc_platform::logging::init(&paths.data_root);
    cgc_platform::logging::install_panic_hook();
    cgc_platform::telemetry::install_panic_hook_from_env();
    // `~/.cgc2046/settings.json` 的 `api.url`：不改包就能切后端。
    let user_settings = cgc_desktop_app::user_settings::load_default();
    cgc_platform::runtime::set_settings_api_url(user_settings.api.url.clone());
    log::info!(
        target: "app",
        "启动 env={:?} data_root={} endpoint={} log={}",
        paths.environment,
        paths.data_root.display(),
        cgc_platform::runtime::api_endpoint(),
        log_path
            .as_deref()
            .map(|path| path.display().to_string())
            .unwrap_or_else(|| "<disabled>".to_string()),
    );

    let registry = build_registry().expect("route registration must be valid");
    validate(&registry).expect("i18n registration must be valid");
    let startup_registry = registry.clone();

    let environment = format!("{:?}", paths.environment).to_ascii_lowercase();
    let initial_urls = std::env::args()
        .skip(1)
        .filter(|arg| arg.starts_with("cgc://"))
        .collect::<Vec<_>>();
    let instance =
        match cgc_platform::instance::claim(&paths.data_root, &environment, initial_urls.clone()) {
            Ok(cgc_platform::instance::InstanceStart::Owner(instance)) => Some(instance),
            Ok(cgc_platform::instance::InstanceStart::HandedOff) => return,
            Err(error) => {
                log::error!(target: "app", "单实例协调不可用：{error}");
                None
            }
        };
    let os_urls = Arc::new(Mutex::new(Vec::<String>::new()));
    let preferences = cgc_desktop_app::preferences::load();
    let history_sidebar_open = preferences.history_sidebar_open;
    let close_to_tray = Arc::new(AtomicBool::new(preferences.close_to_tray));
    let tray_hint_shown = Arc::new(AtomicBool::new(preferences.tray_hint_shown));
    let notification_responses = Arc::new(Mutex::new(
        Vec::<gpui_kit::SystemNotificationResponse>::new(),
    ));

    let application = gpui_kit::application().with_assets(gpui_kit::assets::AllAssets);
    {
        let os_urls = os_urls.clone();
        application.on_open_urls(move |urls| {
            if let Ok(mut queued) = os_urls.lock() {
                queued.extend(urls);
            }
        });
    }
    application.run(move |cx| {
        gpui_kit::init(cx);
        // demo / 真机回归实例使用独立 identity 与 display name，避免和正式客户端在
        // Dock / 应用切换 / 单实例激活上混在一起（2026-10-25 真机回归发现）。
        let demo_mode = std::env::var_os("CGC_NATIVE_AGENT_DEMO").is_some();
        if demo_mode {
            cx.set_app_identity(
                "com.codingirlsclub.cgc2046.desktop.demo",
                "程序媛汇（demo）",
            );
        } else {
            cx.set_app_identity("com.codingirlsclub.cgc2046.desktop", "程序媛汇");
        }
        cx.set_quit_mode(gpui_kit::QuitMode::Explicit);
        {
            let notification_responses = notification_responses.clone();
            cx.on_system_notification_response(move |response, _| {
                if let Ok(mut queue) = notification_responses.lock() {
                    queue.push(response);
                }
            });
        }
        gpui_kit::open_window(main_window_options(), cx, move |window, cx| {
            let mut instance = instance;
            let os_urls = os_urls.clone();
            let initial_urls = initial_urls.clone();
            let close_to_tray = close_to_tray.clone();
            let tray_hint_shown = tray_hint_shown.clone();
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
                gpui_kit::component::input::InputState::new(window, cx).placeholder(translate(
                    default_language(),
                    Key::AgentChatChatSelectOption,
                ))
            });
            let view = cx.new(move |_| RootView::new(view_registry));
            view.update(cx, |this, cx| {
                cgc_desktop_app::root_view::register_history_root(cx.entity().downgrade());
                this.set_history_sidebar_persisted(history_sidebar_open);
                this.set_tray_preferences(close_to_tray.clone(), tray_hint_shown.clone());
                this.install_main_window_lifecycle(window, cx);
                this.set_chat_input(chat_input);
                this.set_config_search_input(config_search_input);
                this.initialize_agent_session(window, cx);
            });
            if let Some(instance) = instance.take() {
                let os_urls = os_urls.clone();
                view.update(cx, |this, cx| {
                    this.start_external_link_pump(instance, os_urls, initial_urls.clone(), cx);
                });
            } else {
                view.update(cx, |this, cx| {
                    for url in initial_urls {
                        this.handle_deep_link(&url, cx);
                    }
                });
            }
            // 登录页常驻扫码：启动即出码（fake 模式内部跳过）。
            view.update(cx, |this, cx| this.ensure_wechat_login(cx));

            let labels = {
                let language = view.read(cx).language();
                cgc_platform::tray::TrayLabels {
                    open: translate(language, Key::AppTrayOpen).to_string(),
                    notifications: translate(language, Key::AppTrayNotifications).to_string(),
                    settings: translate(language, Key::AppTraySettings).to_string(),
                    quit: translate(language, Key::AppTrayQuit).to_string(),
                    tooltip: translate(language, Key::AppTrayTooltip).to_string(),
                }
            };
            match cgc_platform::tray::create(TRAY_ICON_PNG, labels) {
                Ok(tray) => view.update(cx, |this, cx| this.install_tray(tray, cx)),
                Err(error) => {
                    log::warn!(target: "app", "托盘不可用：{error}");
                    view.update(cx, |this, _| this.set_close_to_tray(false));
                }
            }

            view
        })
        .expect("main window opens");

        if demo_mode {
            // demo 窗口不抢焦点：正常客户端仍是前台窗口，Agent 只作为附加窗口。
            // 关键：显式给独立 bounds + 标题。`window_bounds: None` 会继承主窗口
            // bounds，在真机回归时几乎铺满屏幕、把客户端界面整体盖住（2026-10-25）。
            let mut options = main_window_options();
            options.focus = false;
            if let Some(titlebar) = options.titlebar.as_mut() {
                titlebar.title = Some("CGC Agent（demo）".into());
            }
            options.window_bounds = Some(WindowBounds::Windowed(Bounds {
                origin: point(px(80.0), px(80.0)),
                size: size(px(1000.0), px(760.0)),
            }));
            let _ = gpui_kit::open_window(options, cx, |window, cx| {
                RootView::isolated_native_demo(window, cx)
            });
        }
    });
}
