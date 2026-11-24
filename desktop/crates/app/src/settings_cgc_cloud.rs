//! Settings 的 CGC Cloud 托管卡片：目录、开关覆盖与钱包摘要。
//!
//! 状态与渲染独立于 BYOK 表单；设置窗口只提供持久化与 runtime 刷新回调。

use std::collections::HashSet;
use std::rc::Rc;
use std::sync::{Arc, Mutex};

use cgc_agent_store::{AgentPrefs, CGC_CLOUD_PROVIDER_ID};
use cgc_platform::gateway::{GatewayModel, WalletSummary};
use gpui_kit::component::switch::Switch;
use gpui_kit::{
    div, px, AnyElement, App, InteractiveElement as _, IntoElement, ParentElement, Role,
    SharedString, StatefulInteractiveElement as _, Styled, TestSupportExt as _, Window,
};

use crate::theme::{self, space, RADIUS_MEDIUM, RADIUS_SMALL};

#[derive(Clone, Debug, Default)]
pub(crate) struct CgcCloudSettingsState {
    pub signed_in: bool,
    pub models: Vec<GatewayModel>,
    pub fetched_at: Option<u64>,
    pub last_error: Option<String>,
    pub syncing: bool,
    pub provider_enabled: bool,
    pub disabled_models: HashSet<String>,
    pub wallet: Option<WalletSummary>,
    pub wallet_error: Option<String>,
    pub wallet_loading: bool,
    /// 自增序号：回调落地前比对，丢弃过期刷新。
    pub request_serial: u64,
}

impl CgcCloudSettingsState {
    pub(crate) fn apply_prefs(&mut self, prefs: &AgentPrefs) {
        let saved = prefs.provider(CGC_CLOUD_PROVIDER_ID);
        self.provider_enabled = saved.is_none_or(|provider| provider.enabled);
        self.disabled_models = saved
            .map(|provider| {
                provider
                    .model_params
                    .iter()
                    .filter(|model| !model.enabled)
                    .map(|model| model.id.clone())
                    .collect()
            })
            .unwrap_or_default();
    }

    pub(crate) fn model_enabled(&self, model_id: &str) -> bool {
        !self.disabled_models.contains(model_id)
    }

    /// 账号切换/登出：清除账号维度的数据；provider/model 覆盖属于本机偏好，保留。
    pub(crate) fn clear_account_scoped(&mut self) {
        self.signed_in = false;
        self.models.clear();
        self.fetched_at = None;
        self.last_error = None;
        self.syncing = false;
        self.wallet = None;
        self.wallet_error = None;
        self.wallet_loading = false;
        self.request_serial = self.request_serial.wrapping_add(1);
    }

    /// 异步响应落地前校验账号与请求序号，避免把上一账号的余额写进当前卡片。
    pub(crate) fn accepts_response(
        &self,
        response_user_id: &str,
        current_user_id: Option<&str>,
        serial: u64,
    ) -> bool {
        self.request_serial == serial && current_user_id == Some(response_user_id)
    }

    pub(crate) fn enabled_model_count(&self) -> usize {
        self.models
            .iter()
            .filter(|model| self.model_enabled(&model.model_id))
            .count()
    }
}

pub(crate) fn state_from_prefs(prefs: &AgentPrefs) -> CgcCloudSettingsState {
    let mut state = CgcCloudSettingsState {
        signed_in: cgc_platform::gateway::signed_in(),
        ..CgcCloudSettingsState::default()
    };
    state.apply_prefs(prefs);
    state
}

pub(crate) type ToggleProviderHandler = Box<dyn Fn(bool, &mut Window, &mut App) + 'static>;
pub(crate) type ToggleModelHandler = Box<dyn Fn(String, bool, &mut Window, &mut App) + 'static>;
pub(crate) type SimpleHandler = Box<dyn Fn(&mut Window, &mut App) + 'static>;
type SharedToggleModelHandler = Rc<dyn Fn(String, bool, &mut Window, &mut App)>;

pub(crate) struct CgcCloudHandlers {
    pub toggle_provider: ToggleProviderHandler,
    pub toggle_model: ToggleModelHandler,
    pub refresh: SimpleHandler,
    pub open_wallet: SimpleHandler,
}

fn status_chip(state: &CgcCloudSettingsState) -> (&'static str, bool) {
    if state.syncing {
        ("同步中", false)
    } else if state.last_error.is_some() {
        ("同步失败", true)
    } else if state.fetched_at.is_none() {
        ("未同步", false)
    } else if state.models.is_empty() {
        ("暂无可用模型", false)
    } else {
        ("已就绪", false)
    }
}

fn relative_time(fetched_at: Option<u64>) -> String {
    let Some(fetched_at) = fetched_at else {
        return "尚未同步".to_string();
    };
    let age = crate::provider_fetch::now_unix().saturating_sub(fetched_at);
    if age < 60 {
        "刚刚".to_string()
    } else if age < 3_600 {
        format!("{} 分钟前", age / 60)
    } else if age < 86_400 {
        format!("{} 小时前", age / 3_600)
    } else {
        format!("{} 天前", age / 86_400)
    }
}

pub(crate) fn render_card(
    state: &Arc<Mutex<CgcCloudSettingsState>>,
    handlers: CgcCloudHandlers,
    native_agent_enabled: bool,
    palette: &theme::Palette,
) -> AnyElement {
    let snapshot = state.lock().map(|state| state.clone()).unwrap_or_default();
    let CgcCloudHandlers {
        toggle_provider,
        toggle_model,
        refresh,
        open_wallet,
    } = handlers;
    let toggle_model: SharedToggleModelHandler = Rc::from(toggle_model);
    let mut card = div()
        .id("settings-cgc-cloud-card")
        .test_support()
        .flex()
        .flex_col()
        .gap(space(1))
        .p(space(1))
        .rounded(px(RADIUS_MEDIUM))
        .border_1()
        .border_color(palette.line)
        .child(
            div()
                .flex()
                .flex_row()
                .items_center()
                .gap(space(2))
                .child(
                    div()
                        .flex_1()
                        .flex()
                        .flex_col()
                        .gap(px(1.0))
                        .child(div().text_size(px(13.0)).child("CGC Cloud"))
                        .child(
                            div()
                                .text_size(px(10.0))
                                .text_color(palette.ink_3)
                                .child("程序媛汇账号托管模型（按会话用量计费）"),
                        ),
                )
                .children(snapshot.signed_in.then(|| {
                    let (label, danger) = status_chip(&snapshot);
                    div()
                        .text_size(px(10.0))
                        .text_color(if danger {
                            palette.danger
                        } else {
                            palette.ink_3
                        })
                        .child(label)
                }))
                .children(snapshot.signed_in.then(|| {
                    let toggle = toggle_provider;
                    Switch::new(SharedString::from("settings-cgc-cloud-enabled"))
                        .checked(snapshot.provider_enabled)
                        .accessibility_label("启用 CGC Cloud")
                        .tooltip("关闭后托管模型不再出现在模型选择器")
                        .on_change(move |checked, window, cx| {
                            toggle(*checked, window, cx);
                        })
                })),
        )
        .children((!snapshot.signed_in).then(|| {
            div()
                .text_size(px(11.0))
                .text_color(palette.ink_3)
                .child("登录 CGC 账号即可使用平台托管模型")
                .into_any_element()
        }))
        .children(snapshot.signed_in.then(|| {
            let refresh = refresh;
            let syncing = snapshot.syncing;
            div()
                .flex()
                .flex_row()
                .items_center()
                .gap(space(2))
                .child(
                    div()
                        .flex_1()
                        .text_size(px(10.0))
                        .text_color(if snapshot.last_error.is_some() {
                            palette.danger
                        } else {
                            palette.ink_3
                        })
                        .child(status_line(&snapshot)),
                )
                .child(
                    div()
                        .id("settings-cgc-cloud-refresh")
                        .test_support()
                        .role(Role::Button)
                        .aria_label("刷新 CGC Cloud 模型目录")
                        .px(space(2))
                        .py(px(3.0))
                        .rounded(px(RADIUS_SMALL))
                        .border_1()
                        .border_color(palette.line)
                        .text_size(px(10.0))
                        .text_color(if syncing {
                            palette.ink_3
                        } else {
                            palette.ink_2
                        })
                        .child(if syncing {
                            "同步中…"
                        } else {
                            "刷新模型"
                        })
                        .on_click(move |_, window, cx| {
                            if !syncing {
                                refresh(window, cx);
                            }
                        }),
                )
                .into_any_element()
        }))
        .children({
            let models = if snapshot.signed_in {
                snapshot.models.clone()
            } else {
                Vec::new()
            };
            models
                .into_iter()
                .map(|model| {
                    let enabled = snapshot.model_enabled(&model.model_id);
                    let model_id = model.model_id.clone();
                    let toggle = toggle_model.clone();
                    div()
                        .id(SharedString::from(format!(
                            "settings-cgc-cloud-model-{}",
                            model.model_id
                        )))
                        .test_support()
                        .role(Role::Button)
                        .aria_label(format!(
                            "{} {}",
                            if enabled { "停用" } else { "启用" },
                            model.display_name
                        ))
                        .px(space(2))
                        .py(px(2.0))
                        .rounded(px(RADIUS_SMALL))
                        .border_1()
                        .border_color(if enabled {
                            palette.accent
                        } else {
                            palette.line
                        })
                        .text_size(px(10.0))
                        .text_color(if enabled {
                            palette.accent
                        } else {
                            palette.ink_3
                        })
                        .child(format!(
                            "{} {}",
                            if enabled { "✓" } else { "○" },
                            if model.display_name.trim().is_empty() {
                                model.model_id.as_str()
                            } else {
                                model.display_name.as_str()
                            }
                        ))
                        .on_click(move |_, window, cx| {
                            toggle(model_id.clone(), !enabled, window, cx);
                        })
                })
                .collect::<Vec<_>>()
        })
        .children(snapshot.signed_in.then(|| {
            let open_wallet = open_wallet;
            div()
                .flex()
                .flex_row()
                .items_center()
                .gap(space(2))
                .child(
                    div()
                        .flex_1()
                        .text_size(px(10.0))
                        .text_color(if snapshot.wallet_error.is_some() {
                            palette.danger
                        } else {
                            palette.ink_3
                        })
                        .child(wallet_line(&snapshot)),
                )
                .children(native_agent_enabled.then(|| {
                    div()
                        .id("settings-cgc-cloud-recharge")
                        .test_support()
                        .role(Role::Button)
                        .aria_label("打开算力钱包与充值")
                        .px(space(2))
                        .py(px(3.0))
                        .rounded(px(RADIUS_SMALL))
                        .bg(palette.accent)
                        .text_color(palette.canvas)
                        .text_size(px(10.0))
                        .child("充值")
                        .on_click(move |_, window, cx| open_wallet(window, cx))
                }))
                .into_any_element()
        }));
    if !snapshot.signed_in {
        card = card.child(
            div()
                .text_size(px(10.0))
                .text_color(palette.ink_3)
                .child("当前未登录；托管模型不会进入选择器。"),
        );
    }
    card.into_any_element()
}

fn status_line(state: &CgcCloudSettingsState) -> String {
    if let Some(error) = &state.last_error {
        return format!("同步失败：{error}");
    }
    if state.syncing {
        return "正在同步模型目录…".to_string();
    }
    if state.fetched_at.is_none() {
        return "尚未同步，点「刷新模型」获取".to_string();
    }
    if state.models.is_empty() {
        return "服务端当前无可用托管模型".to_string();
    }
    format!(
        "已启用 {}/{} 个模型 · 最近同步 {}",
        state.enabled_model_count(),
        state.models.len(),
        relative_time(state.fetched_at)
    )
}

fn wallet_line(state: &CgcCloudSettingsState) -> String {
    if let Some(error) = &state.wallet_error {
        return format!("余额读取失败：{error}");
    }
    if state.wallet_loading {
        return "正在读取算力余额…".to_string();
    }
    match &state.wallet {
        Some(wallet) => format!(
            "可用余额 {}（{}%）",
            crate::native_agent_view::format_mc_as_cny(wallet.available_mc),
            wallet.remaining_percentage
        ),
        None => "算力余额暂不可用".to_string(),
    }
}

#[cfg(test)]
mod tests {
    use cgc_agent_store::{cgc_cloud_provider_with_models, AgentPrefs, ModelPrefs};

    use super::{CgcCloudSettingsState, GatewayModel, WalletSummary};

    fn gateway_model(id: &str) -> GatewayModel {
        GatewayModel {
            model_id: id.to_string(),
            display_name: id.to_string(),
            context_window: 128_000,
            max_output_tokens: 8_192,
            supports_thinking: false,
            supports_tools: true,
            supports_images: false,
            reasoning_efforts: Vec::new(),
            input_price_mc: 1,
            cache_hit_price_mc: 1,
            output_price_mc: 1,
        }
    }

    #[test]
    fn missing_provider_falls_back_to_enabled_without_overrides() {
        let mut state = CgcCloudSettingsState::default();
        state.apply_prefs(&AgentPrefs::default());
        assert!(state.provider_enabled);
        assert!(state.disabled_models.is_empty());
    }

    #[test]
    fn apply_prefs_tracks_provider_and_model_overrides() {
        let mut provider = cgc_cloud_provider_with_models(vec![
            ModelPrefs::new("managed-a"),
            ModelPrefs::new("managed-b"),
        ]);
        provider.enabled = false;
        provider
            .model_params
            .iter_mut()
            .find(|model| model.id == "managed-b")
            .expect("model")
            .enabled = false;
        let mut prefs = AgentPrefs::default();
        prefs.upsert_provider(provider);

        let mut state = CgcCloudSettingsState {
            models: vec![gateway_model("managed-a"), gateway_model("managed-b")],
            ..CgcCloudSettingsState::default()
        };
        state.apply_prefs(&prefs);

        assert!(!state.provider_enabled);
        assert!(state.model_enabled("managed-a"));
        assert!(!state.model_enabled("managed-b"));
        assert_eq!(state.enabled_model_count(), 1);
    }

    #[test]
    fn account_switch_clears_wallet_and_catalog_but_keeps_overrides() {
        let wallet = WalletSummary {
            wallet_id: "w-old".to_string(),
            cached_balance_mc: 10,
            held_mc: 0,
            available_mc: 10,
            max_concurrent_streams: 1,
            status: "active".to_string(),
            remaining_percentage: 50,
            active_grants: Vec::new(),
        };
        let mut state = CgcCloudSettingsState {
            signed_in: true,
            models: vec![gateway_model("managed-a")],
            fetched_at: Some(10),
            last_error: Some("old".to_string()),
            syncing: true,
            provider_enabled: false,
            wallet: Some(wallet),
            wallet_error: Some("wallet-error".to_string()),
            wallet_loading: true,
            request_serial: 7,
            ..CgcCloudSettingsState::default()
        };
        state.disabled_models.insert("managed-a".to_string());

        state.clear_account_scoped();

        assert!(!state.signed_in);
        assert!(state.models.is_empty());
        assert!(state.fetched_at.is_none());
        assert!(state.last_error.is_none());
        assert!(!state.syncing);
        assert!(state.wallet.is_none());
        assert!(state.wallet_error.is_none());
        assert!(!state.wallet_loading);
        assert_eq!(state.request_serial, 8);
        assert!(!state.provider_enabled, "本机覆盖必须保留");
        assert!(state.disabled_models.contains("managed-a"));
    }

    #[test]
    fn accepts_response_rejects_other_account_or_stale_serial() {
        let state = CgcCloudSettingsState {
            request_serial: 5,
            ..CgcCloudSettingsState::default()
        };
        assert!(state.accepts_response("user-a", Some("user-a"), 5));
        assert!(!state.accepts_response("user-a", Some("user-b"), 5));
        assert!(!state.accepts_response("user-a", None, 5));
        assert!(!state.accepts_response("user-a", Some("user-a"), 4));
    }
}
