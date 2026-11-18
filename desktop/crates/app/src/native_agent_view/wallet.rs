//! CGC Cloud 钱包状态与 402 续费卡片（Phase 4）。
//!
//! 钱包查询与收银台调用都在后台线程执行；UI 只保存摘要，不持久化 token。

use super::*;

const QUOTA_PACK_CENTS: i64 = 1000;

impl NativeAgentView {
    /// 登录成功 / 每轮结束后异步刷新 `myLlmWallet`；失败不阻塞对话。
    pub(super) fn refresh_wallet(&mut self, cx: &mut Context<Self>) {
        if !cgc_platform::gateway::signed_in() {
            self.wallet = None;
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

    pub(super) fn wallet_badge(&self, palette: &theme::Palette) -> Option<AnyElement> {
        let wallet = self.wallet.as_ref()?;
        let percentage = wallet.remaining_percentage.clamp(0, 100);
        let color = if percentage < 10 {
            palette.danger
        } else {
            palette.ink_3
        };
        Some(
            div()
                .id("native-agent-wallet")
                .text_size(px(11.0))
                .text_color(color)
                .child(format!("⚡ 算力 {percentage}%"))
                .into_any_element(),
        )
    }

    fn start_quota_checkout(&mut self, cx: &mut Context<Self>) {
        self.quota_checkout_serial = self.quota_checkout_serial.wrapping_add(1);
        let serial = self.quota_checkout_serial;
        let price_cents = QUOTA_PACK_CENTS;
        self.quota_checkout = Some(QuotaCheckout {
            state: QuotaCheckoutState::Creating,
            qr: None,
            price_cents,
        });
        let task = cx.background_executor().spawn(async move {
            let idempotency_key = format!("desktop-quota-{}", uuid::Uuid::new_v4());
            cgc_platform::gateway::create_payment_order(
                "llm_credit_pack",
                "alipay_qr",
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
                            });
                            cx.notify();
                            return;
                        };
                        let server_price_cents = checkout.order.amount_cents;
                        this.quota_checkout = Some(QuotaCheckout {
                            state: QuotaCheckoutState::Ready,
                            qr: Some(qr),
                            price_cents: server_price_cents,
                        });
                        this.poll_quota_order(checkout.order.id, serial, cx);
                    }
                    Err(error) => {
                        this.quota_checkout = Some(QuotaCheckout {
                            state: QuotaCheckoutState::Failed(error.diagnostic()),
                            qr: None,
                            price_cents,
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

    pub(super) fn render_quota_card(
        &self,
        palette: &theme::Palette,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        if !self.insufficient_quota {
            return None;
        }
        let retry = cx.entity().downgrade();
        let mut card = div()
            .id("native-agent-quota-card")
            .flex()
            .flex_col()
            .gap(px(6.0))
            .p(space(2))
            .mb(space(2))
            .rounded(px(RADIUS_MEDIUM))
            .border_1()
            .border_color(palette.warning)
            .bg(palette.soft)
            .child(
                div()
                    .text_size(px(12.0))
                    .text_color(palette.ink)
                    .child("算力余额不足，充值后即可继续生成。"),
            );

        match self.quota_checkout.as_ref().map(|checkout| &checkout.state) {
            Some(QuotaCheckoutState::Creating) => {
                card = card.child(
                    div()
                        .text_size(px(11.0))
                        .text_color(palette.ink_3)
                        .child("正在创建支付宝订单…"),
                );
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
                card = card.child(div().text_size(px(11.0)).text_color(palette.ink_3).child(
                    format!(
                            "支付宝扫码支付 ¥{}；到账后会自动刷新。",
                            self.quota_checkout
                                .as_ref()
                                .map(|checkout| checkout.price_cents / 100)
                                .unwrap_or(10)
                        ),
                ));
            }
            Some(QuotaCheckoutState::Paid) => {
                card = card.child(
                    div()
                        .text_size(px(11.0))
                        .text_color(palette.accent)
                        .child("算力已到账，可以继续生成。"),
                );
            }
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

        let button = match self.quota_checkout.as_ref().map(|checkout| &checkout.state) {
            Some(QuotaCheckoutState::Ready | QuotaCheckoutState::Creating) => None,
            Some(QuotaCheckoutState::Paid) => Some(
                Button::new("native-agent-quota-continue")
                    .label("继续生成")
                    .primary()
                    .small()
                    .on_click(move |_, _, cx| {
                        let _ = retry.update(cx, |this, cx| {
                            this.quota_checkout = None;
                            this.insufficient_quota = false;
                            this.status = "算力已到账，继续生成".into();
                            this.retry_last_turn(cx);
                            cx.notify();
                        });
                    }),
            ),
            _ => Some(
                Button::new("native-agent-quota-topup")
                    .label("支付宝扫码充值 ¥10")
                    .primary()
                    .small()
                    .on_click(move |_, _, cx| {
                        let _ = retry.update(cx, |this, cx| this.start_quota_checkout(cx));
                    }),
            ),
        };
        if let Some(button) = button {
            card = card.child(button);
        }
        Some(card.into_any_element())
    }
}
