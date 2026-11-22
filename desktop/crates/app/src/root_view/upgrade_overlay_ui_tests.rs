//! 426 升级/止损阻断覆盖层的真实 GPUI 窗口渲染回归。
//! 只在 `CGC_UI_TESTS=1` + `--features gpui-kit/test-support` 下编译；
//! 禁止 `use super::*;`（避免与 root_view 的 `gpui_kit::*` 叠开导致 `#[gpui_kit::test]` 递归展开）。

use super::demo_signed_in;
use super::RootView;
use crate::i18n::{translate, Key, Language};
use crate::theme::ThemePreference;
use cgc_platform::api::{
    clear_upgrade_notice, record_upgrade_notice, upgrade_notice, ApiError, UpgradeNotice,
};
use cgc_platform::session::{FakeAuthApi, MemoryStore, SessionService};
use gpui_kit::test::{TestQueryExt, TestWindowExt};
use gpui_kit::{
    px, size, AppContext as _, Bounds, TestAppContext, VisualTestContext, WindowBounds,
    WindowOptions,
};

#[gpui_kit::test]
fn upgrade_overlay_renders_over_signed_out_and_signed_in_views_without_sign_out(
    cx: &mut TestAppContext,
) {
    let _guard = super::upgrade_latch_test_lock();
    let _isolation = super::tests::isolate_workspace_state();
    clear_upgrade_notice();
    cx.update(gpui_kit::init);
    cx.update(crate::theme::load_builtin_themes);

    let (handle, root) = cx.update(|cx| {
        gpui_kit::open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(Bounds::centered(
                    None,
                    size(px(960.), px(640.)),
                    cx,
                ))),
                ..Default::default()
            },
            cx,
            |_, cx| {
                cx.new(|_| {
                    RootView::with_session(
                        crate::registration::build_registry().expect("registry"),
                        Language::Zh,
                        ThemePreference::Light,
                        SessionService::new(
                            Box::new(FakeAuthApi::demo()),
                            Box::new(MemoryStore::default()),
                        ),
                    )
                })
            },
        )
        .expect("open window")
    });

    let notice = UpgradeNotice {
        code: "desktop_client_disabled".to_string(),
        message: "临时维护中".to_string(),
        min_version: Some("0.2.0".to_string()),
        download_url: Some("https://codingirlsclub.com/releases".to_string()),
    };
    record_upgrade_notice(notice.clone());

    let download_label = translate(Language::Zh, Key::PlatformUpgradeDownload).to_string();
    let retry_label = translate(Language::Zh, Key::PlatformUpgradeRetry).to_string();

    // 1. 未登录态也必须渲染阻断覆盖层
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        assert!(window.find_by_label(&download_label).visible());
        assert!(window.find_by_label(&retry_label).visible());
    })
    .expect("render signed-out overlay");

    // 2. 切为已登录态并经 handle_notification_feed 触发 426：不得登出，仍显示覆盖层，点重试清 Latch
    clear_upgrade_notice();
    root.update(cx, |this, cx| {
        let signed_in = demo_signed_in();
        let session = signed_in.signed_in().expect("demo signed in").clone();
        this.finish_login(Ok(session));
        this.session_checked = true;
        record_upgrade_notice(notice.clone());
        this.handle_notification_feed(Err(ApiError::UpgradeRequired(notice.clone())), cx);
        assert!(this.is_signed_in());
    });

    let mut vcx = VisualTestContext::from_window(handle, cx);
    vcx.update(|window, cx| {
        window.render_frame(cx);
        assert!(window.find_by_label(&download_label).visible());
        assert!(window.find_by_label(&retry_label).visible());
    });

    let retry_center = vcx.update(|window, _| window.find_by_label(&retry_label).bounds().center());
    vcx.simulate_click(retry_center, gpui_kit::Modifiers::default());
    vcx.run_until_parked();
    vcx.update(|window, cx| {
        window.render_frame(cx);
        assert!(window
            .try_find_by_label(&download_label)
            .is_none_or(|el| !el.visible()));
    });

    root.read_with(cx, |this, _| {
        assert!(this.is_signed_in(), "点击重试后不应触发登出");
        assert_eq!(this.upgrade_notice, None);
    });
    assert_eq!(upgrade_notice(), None);
}
