use super::super::*;
use super::ScreenContext;
use gpui_kit::component::button::{Button, ButtonVariants};
use gpui_kit::component::Disableable;

fn input_content(
    display: AnyElement,
    focused: bool,
    empty: bool,
    palette: &theme::Palette,
) -> AnyElement {
    let caret = div()
        .w(px(1.0))
        .h(px(16.0))
        .bg(palette.accent)
        .into_any_element();
    let mut children = Vec::new();
    if focused && empty {
        children.push(caret);
        children.push(display);
    } else {
        children.push(display);
        if focused {
            children.push(caret);
        }
    }
    div()
        .flex()
        .flex_row()
        .items_center()
        .gap(px(1.0))
        .children(children)
        .into_any_element()
}

pub(in crate::root_view) fn render_reset_login_card(
    ctx: &mut ScreenContext<'_>,
    language: Language,
    palette: &theme::Palette,
    cx: &mut Context<RootView>,
) -> AnyElement {
    let email = ctx.login_email.clone();
    let token = ctx.login_reset_token.clone();
    let new_password = ctx.login_new_password.clone();
    let reset_sent = ctx.reset_sent;
    let signing_in = ctx.signing_in;
    let email_input = login_input(
        ctx,
        language,
        palette,
        "reset-email",
        LoginField::Email,
        Key::AppAuthResetEmail,
        email,
        false,
        cx,
    );
    let token_input = login_input(
        ctx,
        language,
        palette,
        "reset-token",
        LoginField::ResetToken,
        Key::AppAuthResetToken,
        token,
        false,
        cx,
    );
    let password_input = login_input(
        ctx,
        language,
        palette,
        "reset-password",
        LoginField::NewPassword,
        Key::AppAuthResetNewPassword,
        new_password,
        true,
        cx,
    );
    let mut card = div()
        .w(px(360.0))
        .flex()
        .flex_col()
        .gap(space(2))
        .p(space(5))
        .rounded(px(RADIUS_LARGE))
        .border_1()
        .border_color(palette.line)
        .bg(palette.card)
        .child(
            div()
                .text_size(px(22.0))
                .text_color(palette.ink)
                .child(translate(language, Key::AppName)),
        )
        .child(
            div()
                .text_size(px(12.0))
                .text_color(palette.ink_3)
                .child(translate(language, Key::AppAuthResetTitle)),
        );
    if reset_sent {
        card = card
            .child(translate(language, Key::AppAuthResetSent))
            .child(token_input)
            .child(password_input)
            .child(
                div()
                    .id("reset-submit")
                    .h(px(34.0))
                    .flex()
                    .items_center()
                    .justify_center()
                    .rounded(px(RADIUS_MEDIUM))
                    .bg(if signing_in {
                        palette.soft
                    } else {
                        palette.accent
                    })
                    .text_color(if signing_in {
                        palette.ink_3
                    } else {
                        palette.ink
                    })
                    .child(translate(language, Key::AppAuthResetSubmit))
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.submit_reset_password(cx);
                    })),
            );
    } else {
        card = card.child(email_input).child(
            div()
                .id("reset-request")
                .role(Role::Button)
                .aria_label(translate(language, Key::AppAuthResetRequest))
                .h(px(34.0))
                .flex()
                .items_center()
                .justify_center()
                .rounded(px(RADIUS_MEDIUM))
                .bg(if signing_in {
                    palette.soft
                } else {
                    palette.accent
                })
                .text_color(if signing_in {
                    palette.ink_3
                } else {
                    palette.ink
                })
                .child(translate(language, Key::AppAuthResetRequest))
                .on_click(cx.listener(|this, _, _, cx| {
                    this.request_password_reset(cx);
                })),
        );
    }
    card = card.children(login_feedback(ctx, language, palette)).child(
        div()
            .id("reset-back")
            .text_size(px(12.0))
            .text_color(palette.ink_3)
            .child(translate(language, Key::AppAuthBack))
            .on_click(cx.listener(|this, _, _, cx| {
                this.back_to_password_login(cx);
            })),
    );
    card.into_any_element()
}

pub(in crate::root_view) fn render_wechat_login_panel(
    ctx: &mut ScreenContext<'_>,
    language: Language,
    palette: &theme::Palette,
    cx: &mut Context<RootView>,
) -> AnyElement {
    let view = ctx.wechat_login.clone();
    let mut panel = div()
        .w_full()
        .flex()
        .flex_col()
        .gap(space(2))
        .child(
            div()
                .text_size(px(18.0))
                .text_color(palette.ink)
                .child(translate(language, Key::AppAuthWechatTitle)),
        )
        .child(
            div()
                .text_size(px(12.0))
                .text_color(palette.ink_3)
                .child(translate(language, Key::AppAuthWechatHint)),
        );

    match view {
        WechatLoginView::Idle | WechatLoginView::Starting => {
            panel = panel.child(
                div()
                    .h(px(180.0))
                    .w_full()
                    .flex()
                    .items_center()
                    .justify_center()
                    .text_size(px(12.0))
                    .text_color(palette.ink_3)
                    .child(translate(language, Key::AppAuthWechatStarting)),
            );
        }
        WechatLoginView::Ready {
            launch_url,
            approved,
            remaining_seconds,
            ..
        } => {
            let qr = encode_qr(&launch_url)
                .map(|matrix| render_qr(&matrix, black(), white(), px(180.0)));
            panel = panel.child(div().w_full().flex().justify_center().children(qr));
            let hint = if approved {
                Key::AppAuthWechatApproved
            } else {
                Key::AppAuthWechatHint
            };
            panel = panel.child(
                div()
                    .text_size(px(12.0))
                    .text_color(if approved {
                        palette.accent
                    } else {
                        palette.ink_3
                    })
                    .child(translate(language, hint)),
            );
            if !approved {
                panel = panel.child(div().text_size(px(12.0)).text_color(palette.ink_3).child(
                    format!(
                        "{} {}s",
                        translate(language, Key::AppAuthWechatExpiresLabel),
                        remaining_seconds
                    ),
                ));
            }
        }
        WechatLoginView::Expired => {
            panel = panel
                .child(
                    div()
                        .text_size(px(12.0))
                        .text_color(palette.danger)
                        .child(translate(language, Key::AppAuthWechatExpired)),
                )
                .child(wechat_refresh_button(ctx, language, palette, cx));
        }
        WechatLoginView::Failed(error) => {
            panel = panel
                .child(
                    div()
                        .text_size(px(12.0))
                        .text_color(palette.danger)
                        .child(translate(language, error.key())),
                )
                .child(wechat_refresh_button(ctx, language, palette, cx));
        }
    }

    panel.into_any_element()
}

/// 登录页两栏：左扫码（常驻），右密码表单。
pub(in crate::root_view) fn render_login_split(
    ctx: &mut ScreenContext<'_>,
    language: Language,
    palette: &theme::Palette,
    cx: &mut Context<RootView>,
) -> AnyElement {
    let email = ctx.login_email.clone();
    let password = ctx.login_password.clone();
    let email_empty = email.is_empty();
    let password_empty = password.is_empty();
    let focused = ctx.focused;
    let signing_in = ctx.signing_in;
    let login_notice = ctx.login_notice;
    let login_error_key = ctx.login_error_key();

    let email_border = if focused == LoginField::Email {
        palette.accent
    } else {
        palette.line_strong
    };
    let password_border = if focused == LoginField::Password {
        palette.accent
    } else {
        palette.line_strong
    };
    let email_display = if email.is_empty() {
        div()
            .text_color(palette.ink_3)
            .child(translate(language, Key::AppAuthEmail))
            .into_any_element()
    } else {
        div()
            .text_color(palette.ink)
            .child(email)
            .into_any_element()
    };
    let password_display = if password.is_empty() {
        div()
            .text_color(palette.ink_3)
            .child(translate(language, Key::AppAuthPassword))
            .into_any_element()
    } else {
        div()
            .text_color(palette.ink)
            .child("•".repeat(password.chars().count().max(1)))
            .into_any_element()
    };

    let password_panel = div()
        .w(px(320.0))
        .flex_shrink_0()
        .flex()
        .flex_col()
        .gap(space(2))
        .p(space(4))
        .rounded(px(RADIUS_LARGE))
        .bg(palette.soft)
        .child(
            div()
                .text_size(px(18.0))
                .text_color(palette.ink)
                .child(translate(language, Key::AppAuthPasswordTitle)),
        )
        .child(
            div()
                .text_size(px(12.0))
                .text_color(palette.ink_3)
                .child(translate(language, Key::AppAuthPasswordHint)),
        )
        .child(
            div()
                .id("login-email")
                .h(px(34.0))
                .flex()
                .items_center()
                .px(space(2))
                .rounded(px(RADIUS_MEDIUM))
                .border_1()
                .border_color(email_border)
                .bg(palette.view)
                .role(Role::TextInput)
                .aria_label(translate(language, Key::AppAuthEmail))
                .child(input_content(
                    email_display,
                    focused == LoginField::Email,
                    email_empty,
                    palette,
                ))
                .on_mouse_down(
                    MouseButton::Left,
                    cx.listener(|this, _, window, cx| {
                        this.focused = LoginField::Email;
                        let focus = this.ensure_key_focus(cx);
                        window.focus(&focus, cx);
                        cx.notify();
                    }),
                ),
        )
        .child(
            div()
                .id("login-password")
                .h(px(34.0))
                .flex()
                .items_center()
                .px(space(2))
                .rounded(px(RADIUS_MEDIUM))
                .border_1()
                .border_color(password_border)
                .bg(palette.view)
                .role(Role::TextInput)
                .aria_label(translate(language, Key::AppAuthPassword))
                .child(input_content(
                    password_display,
                    focused == LoginField::Password,
                    password_empty,
                    palette,
                ))
                .on_mouse_down(
                    MouseButton::Left,
                    cx.listener(|this, _, window, cx| {
                        this.focused = LoginField::Password;
                        let focus = this.ensure_key_focus(cx);
                        window.focus(&focus, cx);
                        cx.notify();
                    }),
                ),
        )
        .children(login_error_key.map(|key| {
            div()
                .text_size(px(12.0))
                .text_color(palette.danger)
                .child(translate(language, key))
                .into_any_element()
        }))
        .child({
            let root = cx.entity().downgrade();
            Button::new("login-submit")
                .label(translate(language, Key::AppAuthSubmit))
                .primary()
                .w_full()
                .h(px(36.0))
                .loading(signing_in)
                .disabled(signing_in)
                .on_click(move |_, _, cx| {
                    let _ = root.update(cx, |this, cx| this.submit_login(cx));
                })
        })
        .children(login_notice.map(|key| {
            div()
                .text_size(px(12.0))
                .text_color(palette.accent)
                .child(translate(language, key))
                .into_any_element()
        }))
        .child(
            div()
                .id("login-forgot")
                .role(Role::Link)
                .aria_label(translate(language, Key::AppAuthForgot))
                .text_size(px(12.0))
                .text_color(palette.ink_3)
                .child(translate(language, Key::AppAuthForgot))
                .on_click(cx.listener(|this, _, _, cx| {
                    this.switch_login_mode(LoginMode::Reset);
                    cx.notify();
                })),
        )
        .child(
            div()
                .text_size(px(12.0))
                .text_color(palette.ink_3)
                .child(translate(language, Key::AppAuthFirstUse)),
        );

    div()
        .w(px(720.0))
        .flex()
        .flex_col()
        .gap(space(3))
        .p(space(5))
        .rounded(px(RADIUS_LARGE))
        .border_1()
        .border_color(palette.line)
        .bg(palette.card)
        .child(
            div()
                .text_size(px(22.0))
                .text_color(palette.ink)
                .child(translate(language, Key::AppName)),
        )
        .child(
            div()
                .flex()
                .flex_row()
                .gap(space(4))
                .items_start()
                .child(
                    div()
                        .flex_1()
                        .min_w(px(0.0))
                        .child(render_wechat_login_panel(ctx, language, palette, cx)),
                )
                .child(password_panel),
        )
        .into_any_element()
}

pub(in crate::root_view) fn wechat_refresh_button(
    _ctx: &mut ScreenContext<'_>,
    language: Language,
    palette: &theme::Palette,
    cx: &mut Context<RootView>,
) -> AnyElement {
    div()
        .id("wechat-refresh")
        .role(Role::Button)
        .aria_label(translate(language, Key::AppAuthWechatRefresh))
        .h(px(34.0))
        .flex()
        .items_center()
        .justify_center()
        .rounded(px(RADIUS_MEDIUM))
        .bg(palette.soft)
        .text_color(palette.ink_2)
        .child(translate(language, Key::AppAuthWechatRefresh))
        .on_click(cx.listener(|this, _, _, cx| {
            this.start_wechat_login(cx);
        }))
        .into_any_element()
}

#[allow(clippy::too_many_arguments)]
pub(in crate::root_view) fn login_input(
    ctx: &mut ScreenContext<'_>,
    language: Language,
    palette: &theme::Palette,
    id: &str,
    field: LoginField,
    placeholder: Key,
    value: String,
    masked: bool,
    cx: &mut Context<RootView>,
) -> AnyElement {
    let focused = ctx.focused == field;
    let empty = value.is_empty();
    let display = if empty {
        translate(language, placeholder).to_string()
    } else if masked {
        "•".repeat(value.chars().count().max(1))
    } else {
        value
    };
    let empty = empty || display.is_empty();
    div()
        .id(id.to_string())
        .h(px(34.0))
        .flex()
        .items_center()
        .px(space(2))
        .rounded(px(RADIUS_MEDIUM))
        .border_1()
        .border_color(if focused {
            palette.accent
        } else {
            palette.line_strong
        })
        .bg(palette.view)
        .text_color(if empty { palette.ink_3 } else { palette.ink })
        .child(input_content(
            div()
                .text_color(if empty { palette.ink_3 } else { palette.ink })
                .child(display)
                .into_any_element(),
            focused,
            empty,
            palette,
        ))
        .role(Role::TextInput)
        .aria_label(translate(language, placeholder))
        .on_mouse_down(
            MouseButton::Left,
            cx.listener(move |this, _, window, cx| {
                this.focused = field;
                let focus = this.ensure_key_focus(cx);
                window.focus(&focus, cx);
                cx.notify();
            }),
        )
        .into_any_element()
}

pub(in crate::root_view) fn login_feedback(
    ctx: &mut ScreenContext<'_>,
    language: Language,
    palette: &theme::Palette,
) -> Vec<AnyElement> {
    let mut elements = Vec::new();
    if let Some(key) = ctx.login_notice {
        elements.push(
            div()
                .text_size(px(12.0))
                .text_color(palette.accent)
                .child(translate(language, key))
                .into_any_element(),
        );
    }
    if let Some(key) = ctx.login_error.map(LoginError::key) {
        elements.push(
            div()
                .text_size(px(12.0))
                .text_color(palette.danger)
                .child(translate(language, key))
                .into_any_element(),
        );
    }
    elements
}
