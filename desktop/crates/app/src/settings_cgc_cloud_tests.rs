//! CGC Cloud 托管卡片的 headless 回归：目录渲染、模型开关与充值入口。
//!
//! 只在 `CGC_UI_TESTS=1` + `--features gpui-kit/test-support` 下编译。

use std::cell::{Cell, RefCell};
use std::rc::Rc;
use std::sync::{Arc, Mutex};

use cgc_platform::gateway::{GatewayModel, WalletSummary};
use gpui_kit::test::{TestQueryExt, TestWindowExt};
use gpui_kit::{
    div, px, size, AppContext, Bounds, Context, IntoElement, ParentElement, Render, Styled,
    TestAppContext, VisualTestContext, Window, WindowBounds, WindowOptions,
};

use crate::settings_cgc_cloud::{render_card, CgcCloudHandlers, CgcCloudSettingsState};

fn model(id: &str, name: &str) -> GatewayModel {
    GatewayModel {
        model_id: id.to_string(),
        display_name: name.to_string(),
        context_window: 128_000,
        max_output_tokens: 8_192,
        supports_thinking: false,
        supports_tools: true,
        supports_images: false,
        reasoning_efforts: Vec::new(),
        input_price_mc: 3_000_000,
        cache_hit_price_mc: 300_000,
        output_price_mc: 4_500_000,
    }
}

fn wallet() -> WalletSummary {
    WalletSummary {
        wallet_id: "w-1".to_string(),
        cached_balance_mc: 10_000_000,
        held_mc: 0,
        available_mc: 10_000_000,
        max_concurrent_streams: 2,
        status: "active".to_string(),
        remaining_percentage: 80,
        active_grants: Vec::new(),
    }
}

struct Probe {
    state: Arc<Mutex<CgcCloudSettingsState>>,
    provider_toggles: Rc<Cell<usize>>,
    model_toggles: Rc<RefCell<Option<(String, bool)>>>,
    refreshes: Rc<Cell<usize>>,
    recharges: Rc<Cell<usize>>,
}

impl Render for Probe {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let palette = crate::theme::palette_from_theme(cx);
        let provider_toggles = self.provider_toggles.clone();
        let model_toggles = self.model_toggles.clone();
        let refreshes = self.refreshes.clone();
        let recharges = self.recharges.clone();
        div().child(render_card(
            &self.state,
            CgcCloudHandlers {
                toggle_provider: Box::new(move |_enabled, _, _| {
                    provider_toggles.set(provider_toggles.get() + 1);
                }),
                toggle_model: Box::new(move |model_id, enabled, _, _| {
                    *model_toggles.borrow_mut() = Some((model_id, enabled));
                }),
                refresh: Box::new(move |_, _| refreshes.set(refreshes.get() + 1)),
                open_wallet: Box::new(move |_, _| recharges.set(recharges.get() + 1)),
            },
            true,
            &palette,
        ))
    }
}

#[gpui_kit::test]
fn cgc_cloud_card_lists_models_and_toggles(cx: &mut TestAppContext) {
    cx.update(gpui_kit::init);
    let state = Arc::new(Mutex::new(CgcCloudSettingsState {
        signed_in: true,
        models: vec![
            model("managed-a", "Managed A"),
            model("managed-b", "Managed B"),
        ],
        fetched_at: Some(1_700_000_000),
        provider_enabled: true,
        wallet: Some(wallet()),
        ..CgcCloudSettingsState::default()
    }));
    let provider_toggles = Rc::new(Cell::new(0));
    let model_toggles = Rc::new(RefCell::new(None));
    let refreshes = Rc::new(Cell::new(0));
    let recharges = Rc::new(Cell::new(0));
    let (provider_toggles_probe, model_toggles_probe) =
        (provider_toggles.clone(), model_toggles.clone());
    let (refreshes_probe, recharges_probe) = (refreshes.clone(), recharges.clone());
    let (handle, _probe) = cx.update(|cx| {
        gpui_kit::open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(Bounds::centered(
                    None,
                    size(px(440.), px(460.)),
                    cx,
                ))),
                ..Default::default()
            },
            cx,
            |_, cx| {
                cx.new(|_| Probe {
                    state,
                    provider_toggles: provider_toggles_probe,
                    model_toggles: model_toggles_probe,
                    refreshes: refreshes_probe,
                    recharges: recharges_probe,
                })
            },
        )
        .unwrap()
    });

    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        assert!(
            window.try_find("settings-cgc-cloud-card").is_some(),
            "托管卡片应渲染"
        );
        assert!(window
            .try_find("settings-cgc-cloud-model-managed-a")
            .is_some());
        assert!(window
            .try_find("settings-cgc-cloud-model-managed-b")
            .is_some());
        assert!(window.try_find("settings-cgc-cloud-refresh").is_some());
        assert!(window.try_find("settings-cgc-cloud-recharge").is_some());
    })
    .unwrap();

    let mut vcx = VisualTestContext::from_window(handle, cx);
    vcx.update(|window, cx| window.click("settings-cgc-cloud-model-managed-a", cx));
    assert_eq!(
        model_toggles.borrow().clone(),
        Some(("managed-a".to_string(), false)),
        "点击已启用模型应请求停用"
    );
    vcx.update(|window, cx| window.click("settings-cgc-cloud-refresh", cx));
    assert_eq!(refreshes.get(), 1);
    vcx.update(|window, cx| window.click("settings-cgc-cloud-recharge", cx));
    assert_eq!(recharges.get(), 1);
    vcx.update(|window, cx| window.click("settings-cgc-cloud-enabled", cx));
    assert_eq!(provider_toggles.get(), 1);
}

#[gpui_kit::test]
fn cgc_cloud_card_reports_empty_catalog(cx: &mut TestAppContext) {
    cx.update(gpui_kit::init);
    let state = Arc::new(Mutex::new(CgcCloudSettingsState {
        signed_in: true,
        models: Vec::new(),
        ..CgcCloudSettingsState::default()
    }));
    let (handle, _probe) = cx.update(|cx| {
        gpui_kit::open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(Bounds::centered(
                    None,
                    size(px(440.), px(260.)),
                    cx,
                ))),
                ..Default::default()
            },
            cx,
            |_, cx| {
                cx.new(|_| Probe {
                    state,
                    provider_toggles: Rc::new(Cell::new(0)),
                    model_toggles: Rc::new(RefCell::new(None)),
                    refreshes: Rc::new(Cell::new(0)),
                    recharges: Rc::new(Cell::new(0)),
                })
            },
        )
        .unwrap()
    });

    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        assert!(
            window.try_find("settings-cgc-cloud-card").is_some(),
            "空目录仍应渲染卡片"
        );
        assert!(window.try_find("settings-cgc-cloud-refresh").is_some());
        assert!(window
            .try_find("settings-cgc-cloud-model-managed-a")
            .is_none());
    })
    .unwrap();
}
