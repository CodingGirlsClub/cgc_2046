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

    // 3. 子视图 NativeAgentView 在 turn 失败命中 CGC Cloud 426 时，必须主动同步并通知父级 RootView
    let native_view = cx
        .update_window(handle, |_, window, cx| {
            let model = cgc_agent_provider::Model::new(
                cgc_agent_provider::ProviderId::new("fake"),
                "Test provider",
                "test-model",
                "Test model",
                cgc_agent_provider::ModelLimits::new(8_000, 1_000),
            );
            let thread = cgc_agent_core::Thread::new(
                "upgrade-test",
                cgc_agent_core::SelectedModel::new(
                    cgc_agent_provider::ProviderId::new("fake"),
                    cgc_agent_provider::ModelId::new("test-model"),
                ),
            );
            let runtime = crate::native_runtime::NativeRuntimeHandle::spawn(
                thread,
                None,
                crate::native_runtime::NativeRuntimeConfig {
                    provider: std::sync::Arc::new(cgc_agent_provider::FakeProvider::new(
                        cgc_agent_provider::ProviderId::new("fake"),
                        "Test provider",
                        vec![model.clone()],
                    )),
                    model,
                    registry: std::sync::Arc::new(cgc_agent_tools::ToolRegistry::new()),
                    context: cgc_agent_tools::ToolContext::new(std::env::temp_dir()),
                    context_size: 8_000,
                    auto_approve: false,
                },
                None,
            );
            let _ = futures::executor::block_on(runtime.inspect()).expect("runtime ready");
            cx.new(|cx| {
                crate::native_agent_view::NativeAgentView::new(
                    window,
                    cx,
                    runtime,
                    crate::page_context::PageContextState::default(),
                    Language::Zh,
                    None,
                )
            })
        })
        .expect("init native agent view");

    crate::native_runtime::maybe_record_upgrade_notice(
        &cgc_agent_core::AgentError::Provider(cgc_agent_provider::ProviderError::api(
            426,
            "版本过旧，请升级客户端",
        )),
        true,
    );
    native_view.update(cx, |view, cx| {
        view.apply_turn_error(
            crate::native_runtime::NativeTurnErrorKind::Other,
            "版本过旧，请升级客户端",
            cx,
        );
    });

    root.read_with(cx, |this, _| {
        assert_eq!(
            this.upgrade_notice.as_ref().map(|n| n.message.as_str()),
            Some("版本过旧，请升级客户端"),
            "子视图 426 turn error 必须立即同步到父级 RootView.upgrade_notice"
        );
    });
    vcx.update(|window, cx| {
        window.render_frame(cx);
        assert!(window.find_by_label(&download_label).visible());
    });
    clear_upgrade_notice();
}
