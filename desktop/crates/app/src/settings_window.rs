//! 独立设置窗口（对齐 Zed：`cmd-,` / `ctrl-,` 打开独立 SettingsWindow；
//! 右上角用户菜单的 Settings 也打开它，而不是主窗口内路由）。
//!
//! 参考 Zed `settings_ui/src/settings_ui.rs::open_settings_editor_with`：
//! 已有窗口则激活复用，否则 `open_window` 新开居中窗口；主窗口仍保留自己的
//! 导航壳，设置不再占用 footer 导航位（`app.settings` 路由仅内部保留）。

use std::sync::Arc;

use gpui_kit::InteractiveElement;
use gpui_kit::*;

use crate::build_info;
use crate::i18n::{translate, Key, Language};
use crate::theme::{self, space, ThemePreference, RADIUS_LARGE, RADIUS_MEDIUM};
use cgc_platform::session::AuthApi;

pub struct SettingsWindowView {
    language: Language,
    preference: ThemePreference,
    email: Option<String>,
    user_id: String,
    workspace: Option<String>,
    token: String,
    api: Arc<dyn AuthApi + Send + Sync>,
    focus: FocusHandle,
    revoking: bool,
    revoked: bool,
    error: Option<String>,
}

impl SettingsWindowView {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        language: Language,
        preference: ThemePreference,
        email: Option<String>,
        user_id: String,
        workspace: Option<String>,
        token: String,
        api: Arc<dyn AuthApi + Send + Sync>,
        cx: &mut Context<Self>,
    ) -> Self {
        Self {
            language,
            preference,
            email,
            user_id,
            workspace,
            token,
            api,
            focus: cx.focus_handle(),
            revoking: false,
            revoked: false,
            error: None,
        }
    }

    pub fn focus_handle(&self) -> FocusHandle {
        self.focus.clone()
    }

    fn revoke(&mut self, cx: &mut Context<Self>) {
        if self.revoking || self.revoked || self.token.is_empty() {
            return;
        }
        self.revoking = true;
        self.error = None;
        let api = self.api.clone();
        let token = self.token.clone();
        let task = cx
            .background_executor()
            .spawn(async move { api.revoke(&token) });
        cx.spawn(async move |this, cx| {
            let result = task.await;
            let _ = this.update(cx, |this, cx| {
                this.revoking = false;
                match result {
                    Ok(()) => this.revoked = true,
                    Err(error) => this.error = Some(error.diagnostic()),
                }
                cx.notify();
            });
        })
        .detach();
    }

    fn render_section(
        title: &'static str,
        body: AnyElement,
        palette: &theme::Palette,
    ) -> AnyElement {
        div()
            .flex()
            .flex_col()
            .gap(space(1))
            .p(space(3))
            .rounded(px(RADIUS_LARGE))
            .border_1()
            .border_color(palette.line)
            .bg(palette.card)
            .child(
                div()
                    .text_size(px(12.0))
                    .text_color(palette.ink_3)
                    .child(title),
            )
            .child(body)
            .into_any_element()
    }
}

impl Render for SettingsWindowView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let language = self.language;
        let mode = theme::resolve(self.preference, window.appearance());
        let palette = theme::palette(mode);
        let shortcut = if cfg!(target_os = "macos") {
            "⌘,"
        } else {
            "Ctrl+,"
        };
        let account = self.email.clone().unwrap_or_else(|| self.user_id.clone());
        let workspace = self.workspace.clone().unwrap_or_else(|| "—".to_string());
        let error = self.error.clone();
        let revoking = self.revoking;
        let revoked = self.revoked;
        let focus = self.focus.clone();

        div()
            .size_full()
            .flex()
            .flex_col()
            .bg(palette.canvas)
            .text_color(palette.ink)
            .font_family(theme::FONT_SANS)
            .text_size(px(14.0))
            .track_focus(&focus)
            .on_key_down(cx.listener(
                |_this: &mut Self,
                 event: &KeyDownEvent,
                 window: &mut Window,
                 _: &mut Context<Self>| {
                    if event.keystroke.key == "escape" {
                        window.remove_window();
                    }
                },
            ))
            .child(
                div()
                    .id("settings-titlebar")
                    .flex()
                    .items_center()
                    .h(px(44.0))
                    .pl(if cfg!(target_os = "macos") {
                        px(84.0)
                    } else {
                        space(3)
                    })
                    .pr(space(2))
                    .gap(space(2))
                    .bg(palette.frame)
                    .border_b_1()
                    .border_color(palette.line)
                    .on_mouse_down(MouseButton::Left, |_, window, _| {
                        window.start_window_move();
                    })
                    .child(
                        div()
                            .text_size(px(14.0))
                            .text_color(palette.ink)
                            .child(translate(language, Key::AppSettingsTitle)),
                    )
                    .child(div().flex_1())
                    .child(
                        div()
                            .id("settings-close")
                            .role(Role::Button)
                            .aria_label(translate(language, Key::AppSettingsClose))
                            .px(space(2))
                            .py(px(4.0))
                            .rounded(px(RADIUS_MEDIUM))
                            .text_size(px(12.0))
                            .text_color(palette.ink_3)
                            .hover(|style| style.bg(palette.soft))
                            .child(translate(language, Key::AppSettingsClose))
                            .on_click(|_, window, _| window.remove_window()),
                    ),
            )
            .child(
                div()
                    .id("settings-content")
                    .flex()
                    .flex_col()
                    .gap(space(2))
                    .w_full()
                    .max_w(px(640.0))
                    .p(space(5))
                    .child(Self::render_section(
                        translate(language, Key::AppSettingsAccount),
                        div()
                            .flex()
                            .flex_col()
                            .gap(px(2.0))
                            .child(div().text_size(px(14.0)).child(account))
                            .child(
                                div()
                                    .text_size(px(11.0))
                                    .text_color(palette.ink_3)
                                    .child(format!("user_id: {}", self.user_id)),
                            )
                            .into_any_element(),
                        &palette,
                    ))
                    .child(Self::render_section(
                        translate(language, Key::AppSettingsWorkspace),
                        div()
                            .text_size(px(14.0))
                            .child(workspace)
                            .into_any_element(),
                        &palette,
                    ))
                    .child(Self::render_section(
                        translate(language, Key::AppSettingsBuild),
                        div()
                            .flex()
                            .flex_col()
                            .gap(px(2.0))
                            .child(div().text_size(px(13.0)).child(build_info::about_line()))
                            .child(
                                div()
                                    .text_size(px(11.0))
                                    .text_color(palette.ink_3)
                                    .child(translate(language, Key::AppSettingsShortcutHint)),
                            )
                            .into_any_element(),
                        &palette,
                    ))
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .justify_between()
                            .gap(space(2))
                            .p(space(2))
                            .rounded(px(RADIUS_LARGE))
                            .border_1()
                            .border_color(palette.line)
                            .bg(palette.card)
                            .child(
                                div()
                                    .flex()
                                    .flex_col()
                                    .gap(px(2.0))
                                    .child(
                                        div().text_size(px(13.0)).child(translate(
                                            language,
                                            Key::AppSettingsRevokeDevice,
                                        )),
                                    )
                                    .child(
                                        div()
                                            .text_size(px(11.0))
                                            .text_color(palette.ink_3)
                                            .child(translate(language, Key::AppSettingsRevokeHint)),
                                    ),
                            )
                            .child(
                                div()
                                    .id("settings-window-revoke")
                                    .role(Role::Button)
                                    .aria_label(translate(language, Key::AppSettingsRevokeDevice))
                                    .px(space(2))
                                    .py(px(6.0))
                                    .rounded(px(RADIUS_MEDIUM))
                                    .bg(if revoking || revoked {
                                        palette.soft
                                    } else {
                                        palette.danger
                                    })
                                    .text_color(if revoking || revoked {
                                        palette.ink_3
                                    } else {
                                        palette.canvas
                                    })
                                    .child(if revoking {
                                        translate(language, Key::AppSettingsRevoking)
                                    } else if revoked {
                                        translate(language, Key::AppSettingsRevoked)
                                    } else {
                                        translate(language, Key::AppSettingsRevokeDevice)
                                    })
                                    .on_click(cx.listener(|this, _, _, cx| this.revoke(cx))),
                            ),
                    )
                    .children(error.map(|message| {
                        div()
                            .text_size(px(12.0))
                            .text_color(palette.danger)
                            .child(message)
                    }))
                    .child(
                        div()
                            .text_size(px(11.0))
                            .text_color(palette.ink_3)
                            .child(format!(
                                "{} {}",
                                translate(language, Key::AppSettingsShortcutHint),
                                shortcut
                            )),
                    ),
            )
    }
}
