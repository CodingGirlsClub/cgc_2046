//! CGC Cloud 钱包状态、主动续费面板与 402 续费卡片（Phase 4 / Plan 009）。
//!
//! 钱包查询与收银台调用都在后台线程执行；UI 只保存摘要，不持久化 token。

use super::*;
use cgc_platform::gateway::{GatewayError, WalletSummary};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct CheckoutSku {
    pub order_kind: &'static str,
    pub price_cents: i64,
    pub label: &'static str,
}

pub(super) const CHECKOUT_SKUS: [CheckoutSku; 3] = [
    CheckoutSku {
        order_kind: "llm_subscription",
        price_cents: 2900,
        label: "¥29 月卡（30天）",
    },
    CheckoutSku {
        order_kind: "llm_credit_pack",
        price_cents: 1000,
        label: "¥10 永久加油包",
    },
    CheckoutSku {
        order_kind: "llm_credit_pack",
        price_cents: 5000,
        label: "¥50 永久加油包",
    },
];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum PaidStateAction {
    RetryTurn,
    ClosePanel,
}

pub(super) fn wallet_card_visible(insufficient_quota: bool, wallet_panel_open: bool) -> bool {
    insufficient_quota || wallet_panel_open
}

pub(super) fn paid_state_action(insufficient_quota: bool) -> PaidStateAction {
    if insufficient_quota {
        PaidStateAction::RetryTurn
    } else {
        PaidStateAction::ClosePanel
    }
}

pub(crate) fn format_mc_as_cny(mc: i64) -> String {
    format!("¥{:.2}", mc as f64 / 1_000_000.0)
}

fn wallet_badge_label(available_mc: i64, percentage: i64, frozen: bool) -> String {
    if frozen {
        return "额度已冻结".to_string();
    }
    if percentage < 10 {
        return format!("额度 {} ({percentage}%)", format_mc_as_cny(available_mc));
    }
    format!("额度 {}", format_mc_as_cny(available_mc))
}

pub(crate) fn format_price_cents(price_cents: i64) -> String {
    if price_cents % 100 == 0 {
        format!("¥{}", price_cents / 100)
    } else {
        format!("¥{:.2}", price_cents as f64 / 100.0)
    }
}

fn grant_source_label(source_type: &str) -> &'static str {
    match source_type {
        "subscription" => "月卡",
        "pack" => "永久加油包",
        "workspace_grant" => "工作台额度",
        "admin_gift" => "赠送额度",
        _ => "通用额度",
    }
}

fn format_grant_expiry(expires_at: Option<&str>) -> String {
    let Some(raw) = expires_at.map(str::trim).filter(|raw| !raw.is_empty()) else {
        return "永久有效".to_string();
    };
    let date = raw.split('T').next().unwrap_or(raw);
    format!("{date} 到期")
}

fn polling_error_is_transient(error: &GatewayError) -> bool {
    matches!(error, GatewayError::Transport(_))
}

fn provider_label(provider: &str) -> &'static str {
    match provider {
        "wechat_native" => "微信",
        "alipay_qr" => "支付宝",
        _ => "支付渠道",
    }
}

impl NativeAgentView {
    /// 仅当当前激活模型属于 CGC 官方托管网关时展示额度 UI 与拉取钱包。
    pub(super) fn is_managed_model_selected(&self) -> bool {
        self.metadata().model.provider_id.as_str() == cgc_agent_store::CGC_CLOUD_PROVIDER_ID
    }

    /// 账号/scope 切换时清掉上一账号的钱包与收银台状态，并推进 serial
    /// 让在途的 wallet / checkout / polling 回调全部失效。
    pub(crate) fn reset_account_state(&mut self, cx: &mut Context<Self>) {
        self.wallet = None;
        self.wallet_panel_open = false;
        self.wallet_panel_from_settings = false;
        self.wallet_frozen_notice = None;
        self.wallet_refresh_serial = self.wallet_refresh_serial.wrapping_add(1);
        self.clear_quota_state();
        cx.notify();
    }

    /// 成功恢复后清掉过期的 402 状态；同时推进 serial 停止旧订单轮询。
    pub(super) fn clear_quota_state(&mut self) {
        self.insufficient_quota = false;
        self.wallet_frozen_notice = None;
        self.quota_checkout = None;
        self.quota_checkout_serial = self.quota_checkout_serial.wrapping_add(1);
    }

    /// 点击状态栏算力徽章：切换主动钱包面板并刷新余额。
    pub(super) fn toggle_wallet_panel(&mut self, cx: &mut Context<Self>) {
        if !self.is_managed_model_selected() {
            return;
        }
        self.wallet_panel_open = !self.wallet_panel_open;
        self.wallet_panel_from_settings = false;
        if !self.wallet_panel_open && !self.insufficient_quota {
            self.quota_checkout = None;
            self.quota_checkout_serial = self.quota_checkout_serial.wrapping_add(1);
        }
        self.refresh_wallet(cx);
        cx.notify();
    }

    /// 主动打开或 402 触发时关闭钱包面板，并同步清理未支付轮询与 402 提示态。
    pub(super) fn close_wallet_panel(&mut self, cx: &mut Context<Self>) {
        if self.insufficient_quota {
            self.state.session.last_error = None;
        }
        self.wallet_panel_open = false;
        self.wallet_panel_from_settings = false;
        self.clear_quota_state();
        cx.notify();
    }

    /// 登录成功 / 每轮结束后异步刷新 `myLlmWallet`；失败不阻塞对话。
    pub(crate) fn refresh_wallet(&mut self, cx: &mut Context<Self>) {
        self.refresh_wallet_inner(false, cx);
    }

    /// Settings 托管卡片打开钱包：即使当前选的是 BYOK 也要能看余额与充值。
    pub(crate) fn open_wallet_panel(&mut self, cx: &mut Context<Self>) {
        self.wallet_panel_open = true;
        self.wallet_panel_from_settings = true;
        self.refresh_wallet_inner(true, cx);
        cx.notify();
    }

    fn refresh_wallet_inner(&mut self, force: bool, cx: &mut Context<Self>) {
        if !cgc_platform::gateway::signed_in() {
            self.wallet = None;
            // 让已经发出的 wallet 请求在回调里也被丢弃。
            self.wallet_refresh_serial = self.wallet_refresh_serial.wrapping_add(1);
            cx.notify();
            return;
        }
        if !force && !self.is_managed_model_selected() {
            self.wallet_refresh_serial = self.wallet_refresh_serial.wrapping_add(1);
            cx.notify();
            return;
        }
        self.wallet_refresh_serial = self.wallet_refresh_serial.wrapping_add(1);
        let serial = self.wallet_refresh_serial;
        let task = cx
            .background_executor()
            .spawn(async move { cgc_platform::gateway::wallet() });
        cx.spawn(async move |this, cx| {
            let result = task.await;
            let _ = this.update(cx, |this, cx| {
                if this.wallet_refresh_serial != serial {
                    return;
                }
                match result {
                    Ok(wallet) => {
                        this.wallet = Some(wallet);
                    }
                    Err(error) => {
                        log::warn!(target: "native-agent", "wallet refresh failed: {}", error.diagnostic());
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    pub(super) fn wallet_badge(
        &self,
        palette: &theme::Palette,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        if !self.is_managed_model_selected() {
            return None;
        }
        let wallet = self.wallet.as_ref()?;
        let percentage = wallet.remaining_percentage.clamp(0, 100);
        let frozen = wallet.status == "frozen";
        let color = if frozen || percentage < 10 {
            palette.danger
        } else {
            palette.ink_3
        };
        let dot_color = if frozen || percentage < 10 {
            palette.danger
        } else if percentage < 30 {
            palette.warning
        } else {
            palette.accent
        };
        let label = wallet_badge_label(wallet.available_mc, percentage, frozen);
        let aria_label = format!(
            "额度详情：可用 {}，剩余 {percentage}%",
            format_mc_as_cny(wallet.available_mc)
        );
        Some(
            div()
                .id("native-agent-wallet")
                .test_support()
                .role(Role::Button)
                .aria_label(aria_label)
                .cursor_pointer()
                .flex()
                .flex_row()
                .items_center()
                .gap(px(5.0))
                .px(space(1))
                .py(px(2.0))
                .rounded(px(RADIUS_SMALL))
                .text_size(px(11.0))
                .text_color(color)
                .hover(|style| style.bg(palette.soft))
                .child(div().w(px(6.0)).h(px(6.0)).rounded_full().bg(dot_color))
                .child(label)
                .on_click(cx.listener(|this, _, _window, cx| {
                    this.toggle_wallet_panel(cx);
                }))
                .into_any_element(),
        )
    }

    fn start_quota_checkout(
        &mut self,
        order_kind: &'static str,
        price_cents: i64,
        provider: &'static str,
        cx: &mut Context<Self>,
    ) {
        self.quota_checkout_serial = self.quota_checkout_serial.wrapping_add(1);
        let serial = self.quota_checkout_serial;
        self.quota_checkout = Some(QuotaCheckout {
            state: QuotaCheckoutState::Creating,
            qr: None,
            price_cents,
            provider: provider.to_string(),
        });
        let task = cx.background_executor().spawn(async move {
            let idempotency_key = format!("desktop-quota-{}", uuid::Uuid::new_v4());
            cgc_platform::gateway::create_payment_order(
                order_kind,
                provider,
                price_cents,
                None,
                &idempotency_key,
            )
        });
        cx.spawn(async move |this, cx| {
            let result = task.await;
            let _ = this.update(cx, |this, cx| {
                if this.quota_checkout_serial != serial {
                    return;
                }
                match result {
                    Ok(checkout) => {
                        let qr = checkout
                            .credential
                            .get("code_url")
                            .and_then(serde_json::Value::as_str)
                            .and_then(|code_url| crate::qr::encode(code_url).ok());
                        let Some(qr) = qr else {
                            this.quota_checkout = Some(QuotaCheckout {
                                state: QuotaCheckoutState::Failed(
                                    "支付渠道未返回可用二维码，请重新创建订单".into(),
                                ),
                                qr: None,
                                price_cents: checkout.order.amount_cents,
                                provider: checkout.order.provider,
                            });
                            cx.notify();
                            return;
                        };
                        let server_price_cents = checkout.order.amount_cents;
                        this.quota_checkout = Some(QuotaCheckout {
                            state: QuotaCheckoutState::Ready,
                            qr: Some(qr),
                            price_cents: server_price_cents,
                            provider: checkout.order.provider,
                        });
                        this.poll_quota_order(checkout.order.id, serial, cx);
                    }
                    Err(error) => {
                        this.quota_checkout = Some(QuotaCheckout {
                            state: QuotaCheckoutState::Failed(error.diagnostic()),
                            qr: None,
                            price_cents,
                            provider: provider.to_string(),
                        });
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    fn poll_quota_order(&self, order_id: String, serial: u64, cx: &mut Context<Self>) {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(600);
        cx.spawn(async move |this, cx| loop {
            if std::time::Instant::now() >= deadline {
                let _ = this.update(cx, |this, cx| {
                    if this.quota_checkout_serial == serial {
                        if let Some(checkout) = this.quota_checkout.as_mut() {
                            checkout.state =
                                QuotaCheckoutState::Failed("支付确认超时，请重新创建订单".into());
                            cx.notify();
                        }
                    }
                });
                break;
            }
            cx.background_executor()
                .timer(std::time::Duration::from_secs(2))
                .await;
            let poll_id = order_id.clone();
            let task = cx
                .background_executor()
                .spawn(async move { cgc_platform::gateway::payment_order(&poll_id) });
            let result = task.await;
            let keep = this
                .update(cx, |this, cx| {
                    if this.quota_checkout_serial != serial {
                        return false;
                    }
                    let Some(checkout) = this.quota_checkout.as_mut() else {
                        return false;
                    };
                    match result {
                        Ok(order) if order.status == "paid" => {
                            checkout.state = QuotaCheckoutState::Paid;
                            checkout.price_cents = order.amount_cents;
                            this.refresh_wallet(cx);
                            cx.notify();
                            false
                        }
                        Ok(order) if matches!(order.status.as_str(), "expired" | "cancelled") => {
                            checkout.state =
                                QuotaCheckoutState::Failed("支付订单已关闭，请重新创建订单".into());
                            cx.notify();
                            false
                        }
                        Ok(_) => true,
                        Err(error) if polling_error_is_transient(&error) => true,
                        Err(error) => {
                            checkout.state = QuotaCheckoutState::Failed(error.diagnostic());
                            cx.notify();
                            false
                        }
                    }
                })
                .unwrap_or(false);
            if !keep {
                break;
            }
        })
        .detach();
    }

    /// HTTP 403 / 钱包冻结的独立提示横幅：不打开充值卡片，只提示联系客服。
    pub(super) fn render_wallet_frozen_notice(
        &self,
        palette: &theme::Palette,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        if !self.is_managed_model_selected()
            || wallet_card_visible(self.insufficient_quota, self.wallet_panel_open)
        {
            return None;
        }
        let notice = self.wallet_frozen_notice.as_ref()?;
        let dismiss = cx.entity().downgrade();
        Some(
            div()
                .id("native-agent-wallet-frozen-notice")
                .test_support()
                .flex()
                .flex_row()
                .items_center()
                .justify_between()
                .gap(px(8.0))
                .p(space(2))
                .mb(space(2))
                .rounded(px(RADIUS_MEDIUM))
                .border_1()
                .border_color(palette.danger)
                .bg(palette.soft)
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .text_size(px(12.0))
                        .text_color(palette.danger)
                        .child(notice.clone()),
                )
                .child(
                    div().flex_shrink_0().child(
                        Button::new("native-agent-wallet-frozen-dismiss")
                            .label("关闭")
                            .xsmall()
                            .ghost()
                            .on_click(move |_, _, cx| {
                                let _ = dismiss.update(cx, |this, cx| {
                                    this.wallet_frozen_notice = None;
                                    this.state.session.last_error = None;
                                    cx.notify();
                                });
                            }),
                    ),
                )
                .into_any_element(),
        )
    }

    pub(super) fn render_quota_card(
        &self,
        palette: &theme::Palette,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        if !wallet_card_visible(self.insufficient_quota, self.wallet_panel_open) {
            return None;
        }
        // BYOK 只在用户从 Settings 显式打开时展示；陈旧的主动面板状态不得泄漏。
        if !self.is_managed_model_selected() && !self.wallet_panel_from_settings {
            return None;
        }
        let weak = cx.entity().downgrade();
        let header_title = if self.insufficient_quota {
            "额度余额不足，充值后即可继续生成。"
        } else {
            "CGC 额度"
        };
        let close_weak = weak.clone();
        let header = div()
            .flex()
            .flex_row()
            .items_center()
            .justify_between()
            .gap(px(8.0))
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .text_size(px(12.0))
                    .text_color(palette.ink)
                    .child(header_title),
            )
            .child(
                div().flex_shrink_0().child(
                    Button::new("native-agent-wallet-close")
                        .label("关闭")
                        .xsmall()
                        .ghost()
                        .on_click(move |_, _, cx| {
                            let _ = close_weak.update(cx, |this, cx| {
                                this.close_wallet_panel(cx);
                            });
                        }),
                ),
            );

        let mut card = div()
            .id("native-agent-quota-card")
            .test_support()
            .flex()
            .flex_col()
            .gap(px(6.0))
            .p(space(2))
            .mb(space(2))
            .rounded(px(RADIUS_MEDIUM))
            .border_1()
            .border_color(if self.insufficient_quota {
                palette.warning
            } else {
                palette.line
            })
            .bg(palette.soft)
            .child(header);

        let wallet_frozen = self
            .wallet
            .as_ref()
            .is_some_and(|wallet| wallet.status == "frozen");
        if let Some(wallet) = self.wallet.as_ref() {
            card = card.child(render_wallet_breakdown(wallet, palette));
        }
        if wallet_frozen || self.wallet_frozen_notice.is_some() {
            card = card.child(
                div().text_size(px(11.0)).text_color(palette.danger).child(
                    self.wallet_frozen_notice
                        .clone()
                        .unwrap_or_else(|| super::turn::WALLET_FROZEN_NOTICE.to_string()),
                ),
            );
            return Some(card.into_any_element());
        }

        match self.quota_checkout.as_ref().map(|checkout| &checkout.state) {
            Some(QuotaCheckoutState::Creating) => {
                card = card.child(div().text_size(px(11.0)).text_color(palette.ink_3).child(
                    format!(
                        "正在创建{}订单…",
                        provider_label(
                            self.quota_checkout
                                .as_ref()
                                .map(|checkout| checkout.provider.as_str())
                                .unwrap_or("alipay_qr")
                        )
                    ),
                ));
            }
            Some(QuotaCheckoutState::Ready) => {
                if let Some(qr) = self.quota_checkout.as_ref().and_then(|c| c.qr.as_ref()) {
                    card = card.child(div().flex().justify_center().child(crate::qr::render_qr(
                        qr,
                        black(),
                        white(),
                        px(160.0),
                    )));
                }
                let price = format_price_cents(
                    self.quota_checkout
                        .as_ref()
                        .map(|checkout| checkout.price_cents)
                        .unwrap_or(1000),
                );
                card = card.child(div().text_size(px(11.0)).text_color(palette.ink_3).child(
                    format!(
                        "{}扫码支付 {price}；到账后会自动刷新。",
                        provider_label(
                            self.quota_checkout
                                .as_ref()
                                .map(|checkout| checkout.provider.as_str())
                                .unwrap_or("alipay_qr")
                        ),
                    ),
                ));
            }
            Some(QuotaCheckoutState::Paid) => match paid_state_action(self.insufficient_quota) {
                PaidStateAction::RetryTurn => {
                    let paid_retry = weak.clone();
                    card = card
                        .child(
                            div()
                                .text_size(px(11.0))
                                .text_color(palette.accent)
                                .child("额度已到账，可以继续生成。"),
                        )
                        .child(
                            Button::new("native-agent-quota-continue")
                                .label("继续生成")
                                .primary()
                                .small()
                                .on_click(move |_, _, cx| {
                                    let _ = paid_retry.update(cx, |this, cx| {
                                        this.quota_checkout = None;
                                        this.insufficient_quota = false;
                                        this.wallet_panel_open = false;
                                        this.status = "额度已到账，继续生成".into();
                                        this.retry_last_turn(cx);
                                        cx.notify();
                                    });
                                }),
                        );
                }
                PaidStateAction::ClosePanel => {
                    let close_paid = weak.clone();
                    card = card
                        .child(
                            div()
                                .text_size(px(11.0))
                                .text_color(palette.accent)
                                .child("充值已到账"),
                        )
                        .child(
                            Button::new("native-agent-quota-paid-close")
                                .label("关闭")
                                .primary()
                                .small()
                                .on_click(move |_, _, cx| {
                                    let _ = close_paid.update(cx, |this, cx| {
                                        this.close_wallet_panel(cx);
                                    });
                                }),
                        );
                }
            },
            Some(QuotaCheckoutState::Failed(message)) => {
                card = card.child(
                    div()
                        .text_size(px(11.0))
                        .text_color(palette.danger)
                        .child(format!("创建充值订单失败：{message}")),
                );
            }
            None => {}
        }

        if matches!(
            self.quota_checkout.as_ref().map(|checkout| &checkout.state),
            None | Some(QuotaCheckoutState::Failed(_))
        ) {
            card = card.child(self.render_topup_options(weak));
        }
        Some(card.into_any_element())
    }

    fn render_topup_options(&self, weak: gpui::WeakEntity<Self>) -> AnyElement {
        let mut options = div().flex().flex_col().gap(px(6.0));
        for sku in CHECKOUT_SKUS {
            let mut row = div()
                .flex()
                .items_center()
                .gap(px(6.0))
                .child(div().text_size(px(11.0)).child(sku.label));
            for (provider, provider_name) in [("alipay_qr", "支付宝"), ("wechat_native", "微信")]
            {
                let weak = weak.clone();
                row = row.child(
                    Button::new(format!(
                        "native-agent-quota-{}-{provider}-{}",
                        sku.order_kind, sku.price_cents
                    ))
                    .label(provider_name)
                    .small()
                    .on_click(move |_, _, cx| {
                        let _ = weak.update(cx, |this, cx| {
                            this.start_quota_checkout(sku.order_kind, sku.price_cents, provider, cx)
                        });
                    }),
                );
            }
            options = options.child(row);
        }
        options.into_any_element()
    }
}

fn render_wallet_breakdown(wallet: &WalletSummary, palette: &theme::Palette) -> AnyElement {
    let mut section = div().flex().flex_col().gap(px(3.0));
    let mut balance_row = div()
        .flex()
        .flex_row()
        .flex_wrap()
        .gap(px(8.0))
        .text_size(px(11.0))
        .text_color(palette.ink_2)
        .child(format!(
            "可用余额：{}",
            format_mc_as_cny(wallet.available_mc)
        ));
    if wallet.held_mc > 0 {
        balance_row = balance_row.child(
            div()
                .text_color(palette.ink_3)
                .child(format!("预扣中：{}", format_mc_as_cny(wallet.held_mc))),
        );
    }
    section = section.child(balance_row);

    for grant in &wallet.active_grants {
        section = section.child(div().text_size(px(10.0)).text_color(palette.ink_3).child(
            format!(
                "{} · 剩余 {} · {}",
                grant_source_label(&grant.source_type),
                format_mc_as_cny(grant.remaining_mc),
                format_grant_expiry(grant.expires_at.as_deref()),
            ),
        ));
    }
    section.into_any_element()
}

#[cfg(test)]
mod tests {
    use super::{
        format_grant_expiry, format_mc_as_cny, format_price_cents, grant_source_label,
        paid_state_action, polling_error_is_transient, provider_label, wallet_badge_label,
        wallet_card_visible, CheckoutSku, PaidStateAction, CHECKOUT_SKUS,
    };
    use cgc_platform::gateway::GatewayError;

    #[test]
    fn checkout_sku_table_includes_subscription_and_credit_packs() {
        assert_eq!(
            CHECKOUT_SKUS,
            [
                CheckoutSku {
                    order_kind: "llm_subscription",
                    price_cents: 2900,
                    label: "¥29 月卡（30天）",
                },
                CheckoutSku {
                    order_kind: "llm_credit_pack",
                    price_cents: 1000,
                    label: "¥10 永久加油包",
                },
                CheckoutSku {
                    order_kind: "llm_credit_pack",
                    price_cents: 5000,
                    label: "¥50 永久加油包",
                },
            ]
        );
        assert_eq!(provider_label("alipay_qr"), "支付宝");
        assert_eq!(provider_label("wechat_native"), "微信");
        assert_eq!(provider_label("unknown"), "支付渠道");
    }

    #[test]
    fn wallet_card_visibility_and_paid_action_distinguish_proactive_vs_402() {
        assert!(!wallet_card_visible(false, false));
        assert!(wallet_card_visible(true, false));
        assert!(wallet_card_visible(false, true));
        assert!(wallet_card_visible(true, true));

        assert_eq!(paid_state_action(true), PaidStateAction::RetryTurn);
        assert_eq!(paid_state_action(false), PaidStateAction::ClosePanel);
    }

    #[test]
    fn wallet_formatting_helpers_format_cny_and_grants() {
        assert_eq!(format_mc_as_cny(0), "¥0.00");
        assert_eq!(format_mc_as_cny(1_250_000), "¥1.25");
        assert_eq!(format_mc_as_cny(29_000_000), "¥29.00");

        assert_eq!(format_price_cents(2900), "¥29");
        assert_eq!(format_price_cents(1050), "¥10.50");

        assert_eq!(grant_source_label("subscription"), "月卡");
        assert_eq!(grant_source_label("pack"), "永久加油包");
        assert_eq!(grant_source_label("workspace_grant"), "工作台额度");
        assert_eq!(grant_source_label("admin_gift"), "赠送额度");
        assert_eq!(grant_source_label("other"), "通用额度");

        assert_eq!(format_grant_expiry(None), "永久有效");
        assert_eq!(format_grant_expiry(Some("")), "永久有效");
        assert_eq!(
            format_grant_expiry(Some("2026-12-19T00:00:00Z")),
            "2026-12-19 到期"
        );
    }

    #[test]
    fn only_transport_poll_errors_are_retryable() {
        assert!(polling_error_is_transient(&GatewayError::Transport(
            "timeout".into()
        )));
        assert!(!polling_error_is_transient(&GatewayError::Unauthenticated));
        assert!(!polling_error_is_transient(&GatewayError::Graphql {
            code: Some("llm_payment_order_not_found".into()),
            message: "missing".into(),
        }));
    }

    #[test]
    fn wallet_badge_includes_available_balance_and_percentage() {
        assert_eq!(wallet_badge_label(52_984_724, 92, false), "额度 ¥52.98");
        assert_eq!(wallet_badge_label(0, 0, false), "额度 ¥0.00 (0%)");
        assert_eq!(wallet_badge_label(52_984_724, 92, true), "额度已冻结");
    }
}
