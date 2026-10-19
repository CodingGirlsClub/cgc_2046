//! 应用外壳：登录页 / 已登录壳（顶部 header + 内容 + 底部 status bar）。
//!
//! 布局参考 Zed（xerj 取证）：透明 titlebar 与红绿灯同排、右上角账户头像 + 下拉、
//! footer 只放图标（悬停 tooltip）。会话来自 `cgc_platform::session`：未登录时
//! 整个窗口显示登录页（guard），登录成功后进入壳；登出在头像下拉里（同 Zed 的
//! sign out）。网络调用放后台线程，结果回主线程刷新。

use gpui_kit::*;

use cgc_platform::session::{AuthError, SessionService, SessionState, SignedInSession};

use crate::i18n::{default_language, translate, translate_registered, Key, Language};
use crate::routing::{Route, RouteRegistry};
use crate::theme::{self, space, ThemePreference, RADIUS_LARGE, RADIUS_MEDIUM, RADIUS_SMALL};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum LoginField {
    Email,
    Password,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum LoginError {
    Invalid,
    Network,
}

impl LoginError {
    fn from_auth_error(error: &AuthError) -> Self {
        match error {
            AuthError::InvalidCredentials => LoginError::Invalid,
            AuthError::Transport(_) | AuthError::Server(_) => LoginError::Network,
        }
    }

    fn key(self) -> Key {
        match self {
            LoginError::Invalid => Key::AppAuthErrorInvalid,
            LoginError::Network => Key::AppAuthErrorNetwork,
        }
    }
}

pub struct RootView {
    registry: RouteRegistry,
    current: Option<Route>,
    language: Language,
    preference: ThemePreference,
    session: SessionService,
    login_email: String,
    login_password: String,
    focused: LoginField,
    login_error: Option<LoginError>,
    signing_in: bool,
    account_menu_open: bool,
    is_fake_mode: bool,
    key_focus: Option<FocusHandle>,
}

impl RootView {
    /// 生产入口：会话由 `SessionService::from_runtime()` 装配（CGC_AUTH / CGC_API_URL 决定 fake 或真实）。
    pub fn new(registry: RouteRegistry) -> Self {
        Self::with_session(
            registry,
            default_language(),
            theme::preference_from_env(),
            SessionService::from_runtime(),
        )
    }

    pub fn with_session(
        registry: RouteRegistry,
        language: Language,
        preference: ThemePreference,
        session: SessionService,
    ) -> Self {
        let current = registry.routes().first().copied();
        let is_fake_mode = std::env::var("CGC_AUTH").as_deref() != Ok("http")
            && std::env::var("CGC_API_URL").is_err();
        Self {
            registry,
            current,
            language,
            preference,
            session,
            login_email: String::new(),
            login_password: String::new(),
            focused: LoginField::Email,
            login_error: None,
            signing_in: false,
            account_menu_open: false,
            is_fake_mode,
            key_focus: None,
        }
    }

    pub fn current(&self) -> Option<Route> {
        self.current
    }

    pub fn language(&self) -> Language {
        self.language
    }

    pub fn preference(&self) -> ThemePreference {
        self.preference
    }

    pub fn account_menu_open(&self) -> bool {
        self.account_menu_open
    }

    pub fn toggle_account_menu(&mut self) -> bool {
        self.account_menu_open = !self.account_menu_open;
        self.account_menu_open
    }

    pub fn close_account_menu(&mut self) {
        self.account_menu_open = false;
    }

    pub fn is_signed_in(&self) -> bool {
        self.session.signed_in().is_some()
    }

    pub fn session_state(&self) -> &SessionState {
        self.session.state()
    }

    pub fn select(&mut self, route: Route) {
        self.current = Some(route);
    }

    pub fn toggle_language(&mut self) -> Language {
        self.language = self.language.toggle();
        self.language
    }

    pub fn cycle_theme(&mut self) -> ThemePreference {
        self.preference = self.preference.cycle();
        self.preference
    }

    /// 系统外观变化时由 `observe_window_appearance` 调用：只有「跟随系统」才重刷 kit 主题。
    pub fn on_appearance_changed(&mut self, appearance: WindowAppearance, cx: &mut Context<Self>) {
        if self.preference == ThemePreference::System {
            theme::apply(theme::resolve(self.preference, appearance), cx);
            cx.notify();
        }
    }

    fn ensure_key_focus(&mut self, cx: &mut Context<Self>) -> FocusHandle {
        self.key_focus
            .get_or_insert_with(|| cx.focus_handle())
            .clone()
    }

    fn login_error_key(&self) -> Option<Key> {
        self.login_error.map(LoginError::key)
    }

    fn submit_login(&mut self, cx: &mut Context<Self>) {
        if self.signing_in {
            return;
        }
        let login = self.login_email.trim().to_string();
        let password = self.login_password.clone();
        if login.is_empty() || password.is_empty() {
            self.login_error = Some(LoginError::Invalid);
            cx.notify();
            return;
        }

        self.signing_in = true;
        self.login_error = None;
        self.session.begin_sign_in();
        cx.notify();

        let api = self.session.api_handle();
        let task = cx
            .background_executor()
            .spawn(async move { api.sign_in(&login, &password) });

        cx.spawn(async move |this, cx| {
            let result = task.await;
            let _ = this.update(cx, |this, cx| {
                this.finish_login(result);
                cx.notify();
            });
        })
        .detach();
    }

    fn finish_login(&mut self, result: Result<SignedInSession, AuthError>) {
        self.signing_in = false;
        match result {
            Ok(session) => {
                if self.session.adopt_signed_in(session).is_err() {
                    self.login_error = Some(LoginError::Network);
                }
                self.login_password.clear();
            }
            Err(error) => {
                self.session.fail_sign_in(&error);
                self.login_error = Some(LoginError::from_auth_error(&error));
            }
        }
    }

    fn sign_out(&mut self, cx: &mut Context<Self>) {
        let token = self.session.sign_out_local();
        if let Some(token) = token {
            let api = self.session.api_handle();
            cx.background_executor()
                .spawn(async move {
                    let _ = api.revoke(&token);
                })
                .detach();
        }
        self.account_menu_open = false;
        self.login_email.clear();
        self.login_password.clear();
        self.login_error = None;
        cx.notify();
    }

    fn handle_key(&mut self, event: &KeyDownEvent, window: &mut Window, cx: &mut Context<Self>) {
        match event.keystroke.key.as_str() {
            "tab" => {
                self.focused = match self.focused {
                    LoginField::Email => LoginField::Password,
                    LoginField::Password => LoginField::Email,
                };
            }
            "enter" => self.submit_login(cx),
            "backspace" => {
                let buffer = self.field_mut();
                buffer.pop();
            }
            _ => {
                if let Some(text) = event.keystroke.key_char.as_deref() {
                    if !event.keystroke.modifiers.modified() && !text.is_empty() {
                        self.field_mut().push_str(text);
                    }
                }
            }
        }
        let focus = self.ensure_key_focus(cx);
        window.focus(&focus, cx);
        cx.notify();
    }

    fn field_mut(&mut self) -> &mut String {
        match self.focused {
            LoginField::Email => &mut self.login_email,
            LoginField::Password => &mut self.login_password,
        }
    }

    /// 测试用：直接访问会话状态机（生产 UI 只通过按钮/异步回调驱动）。
    #[cfg(test)]
    pub(crate) fn session_mut(&mut self) -> &mut SessionService {
        &mut self.session
    }

    #[cfg(test)]
    pub(crate) fn login_error(&self) -> Option<LoginError> {
        self.login_error
    }
}

impl Render for RootView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let mode = theme::resolve(self.preference, window.appearance());
        let palette = theme::palette(mode);
        let language = self.language;
        let account_menu = self.account_menu_open;
        let signing_in = self.signing_in;
        let login_error_key = self.login_error_key();
        let is_signed_in = self.is_signed_in();
        let email = self
            .session
            .signed_in()
            .and_then(|session| session.email.clone())
            .unwrap_or_default();
        let avatar_glyph = email
            .chars()
            .next()
            .map(|c| c.to_uppercase().to_string())
            .unwrap_or_else(|| "C".to_string());

        let theme_label = translate(language, self.preference.label_key());
        let language_label = translate(
            language,
            match language {
                Language::Zh => Key::AppLangZh,
                Language::En => Key::AppLangEn,
            },
        );
        let theme_tooltip = translate(language, Key::AppThemeToggle);
        let language_tooltip = translate(language, Key::AppLanguageToggle);
        let account_tooltip = translate(language, Key::AppAccountMenu);
        let sign_out_label = translate(language, Key::AppAuthSignOut);
        let signed_in_as = translate(language, Key::AppAuthSignedInAs);

        let theme_glyph = match self.preference {
            ThemePreference::Light => "☀",
            ThemePreference::Dark => "☾",
            ThemePreference::System => "◐",
        };
        let language_glyph = match language {
            Language::Zh => "中",
            Language::En => "A",
        };

        let key_focus = self.ensure_key_focus(cx);
        if !is_signed_in {
            window.focus(&key_focus, cx);
        }
        let login_email = self.login_email.clone();
        let login_password = self.login_password.clone();
        let focused = self.focused;
        let is_fake_mode = self.is_fake_mode;

        let mut root = div();
        if !is_signed_in {
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
            let email_display = if login_email.is_empty() {
                div()
                    .text_color(palette.ink_3)
                    .child(translate(language, Key::AppAuthEmail))
                    .into_any_element()
            } else {
                div()
                    .text_color(palette.ink)
                    .child(login_email)
                    .into_any_element()
            };
            let password_display = if login_password.is_empty() {
                div()
                    .text_color(palette.ink_3)
                    .child(translate(language, Key::AppAuthPassword))
                    .into_any_element()
            } else {
                div()
                    .text_color(palette.ink)
                    .child("•".repeat(login_password.chars().count().max(1)))
                    .into_any_element()
            };

            let login_card = div()
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
                        .child(translate(language, Key::AppAuthSubmit)),
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
                        .child(email_display)
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
                        .child(password_display)
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
                .child(
                    div()
                        .id("login-submit")
                        .h(px(36.0))
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
                        .child(translate(language, Key::AppAuthSubmit))
                        .on_click(cx.listener(|this, _, _, cx| this.submit_login(cx))),
                )
                .children(if is_fake_mode {
                    Some(
                        div()
                            .text_size(px(11.0))
                            .text_color(palette.ink_3)
                            .child(translate(language, Key::AppAuthFakeHint))
                            .into_any_element(),
                    )
                } else {
                    None
                });

            root = root
                .size_full()
                .flex()
                .flex_col()
                .bg(palette.canvas)
                .text_color(palette.ink)
                .font_family(theme::FONT_SANS)
                .text_size(px(14.0))
                .track_focus(&key_focus)
                .on_key_down(cx.listener(Self::handle_key))
                .child(
                    div()
                        .flex_1()
                        .w_full()
                        .flex()
                        .items_center()
                        .justify_center()
                        .child(login_card),
                )
                .child(self.render_footer(
                    language,
                    false,
                    theme_glyph,
                    theme_label,
                    theme_tooltip,
                    language_glyph,
                    language_label,
                    language_tooltip,
                    &palette,
                    cx,
                ));
            root
        } else {
            root = root
                .size_full()
                .flex()
                .flex_col()
                .bg(palette.canvas)
                .text_color(palette.ink)
                .font_family(theme::FONT_SANS)
                .text_size(px(14.0))
                .track_focus(&key_focus)
                .child(
                    div()
                        .flex()
                        .flex_row()
                        .items_center()
                        .h(px(44.0))
                        .pl(if cfg!(target_os = "macos") {
                            px(84.0)
                        } else {
                            space(3)
                        })
                        .pr(space(2))
                        .gap(space(1))
                        .bg(palette.frame)
                        .border_b_1()
                        .border_color(palette.line)
                        .child(
                            div()
                                .id("titlebar-drag")
                                .flex()
                                .items_center()
                                .h_full()
                                .pr(space(2))
                                .on_mouse_down(MouseButton::Left, |_, window, _| {
                                    window.start_window_move();
                                })
                                .child(
                                    div()
                                        .text_size(px(15.0))
                                        .text_color(palette.ink)
                                        .child(translate(language, Key::AppName)),
                                ),
                        )
                        .child(div().w(px(1.0)).h(px(14.0)).bg(palette.line))
                        .child(div().text_color(palette.ink_3).child(match self.current {
                            Some(route) => translate_registered(language, route.title_key),
                            None => translate(language, Key::AppNavLabel),
                        }))
                        .child(div().flex_1())
                        .child({
                            let account_menu = account_menu.then(|| {
                                div()
                                    .id("account-menu")
                                    .absolute()
                                    .top(px(34.0))
                                    .right_0()
                                    .w(px(200.0))
                                    .flex()
                                    .flex_col()
                                    .gap(px(2.0))
                                    .p(space(1))
                                    .rounded(px(RADIUS_MEDIUM))
                                    .border_1()
                                    .border_color(palette.line_strong)
                                    .bg(palette.card)
                                    .text_color(palette.ink)
                                    .child(
                                        div()
                                            .px(space(1))
                                            .py(px(4.0))
                                            .text_size(px(10.0))
                                            .text_color(palette.ink_3)
                                            .child(format!("{signed_in_as} {email}")),
                                    )
                                    .child(
                                        div()
                                            .id("account-sign-out")
                                            .px(space(1))
                                            .py(px(6.0))
                                            .rounded(px(RADIUS_SMALL))
                                            .text_color(palette.ink_2)
                                            .hover(|style| style.bg(palette.soft))
                                            .child(sign_out_label)
                                            .on_click(
                                                cx.listener(|this, _, _, cx| this.sign_out(cx)),
                                            ),
                                    )
                                    .into_any_element()
                            });

                            div()
                                .relative()
                                .flex()
                                .items_center()
                                .child(
                                    div()
                                        .id("account-menu-toggle")
                                        .size(px(26.0))
                                        .rounded_full()
                                        .flex()
                                        .items_center()
                                        .justify_center()
                                        .bg(palette.accent)
                                        .text_size(px(12.0))
                                        .text_color(hsla_white())
                                        .child(avatar_glyph)
                                        .tooltip(move |_, cx| {
                                            cx.new(|_| TooltipText {
                                                text: account_tooltip.into(),
                                            })
                                            .into()
                                        })
                                        .on_click(cx.listener(|this, _, _, cx| {
                                            this.toggle_account_menu();
                                            cx.notify();
                                        })),
                                )
                                .children(account_menu)
                        }),
                )
                .child(
                    div()
                        .flex_1()
                        .w_full()
                        .p(space(6))
                        .child(self.render_content(language, &palette, cx)),
                )
                .child(self.render_footer(
                    language,
                    true,
                    theme_glyph,
                    theme_label,
                    theme_tooltip,
                    language_glyph,
                    language_label,
                    language_tooltip,
                    &palette,
                    cx,
                ));
            root
        }
    }
}

impl RootView {
    fn render_nav_items(
        &self,
        language: Language,
        palette: &theme::Palette,
        cx: &mut Context<Self>,
    ) -> Vec<AnyElement> {
        let current = self.current;
        self.registry
            .routes()
            .iter()
            .map(|route| {
                let route = *route;
                let selected = current.is_some_and(|current| current.id == route.id);
                let label = translate_registered(language, route.title_key);
                div()
                    .id(format!("footer-nav-{}", route.id))
                    .size(px(22.0))
                    .rounded(px(RADIUS_MEDIUM))
                    .flex()
                    .items_center()
                    .justify_center()
                    .text_color(if selected {
                        palette.accent
                    } else {
                        palette.ink_3
                    })
                    .hover(|style| style.bg(palette.soft))
                    .child(route.icon)
                    .tooltip(move |_, cx| cx.new(|_| TooltipText { text: label.into() }).into())
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.select(route);
                        cx.notify();
                    }))
                    .into_any_element()
            })
            .collect()
    }

    fn render_content(
        &self,
        language: Language,
        palette: &theme::Palette,
        _cx: &mut Context<Self>,
    ) -> AnyElement {
        match self.current {
            Some(route) => div()
                .flex()
                .flex_col()
                .gap(space(2))
                .child(
                    div()
                        .text_size(px(24.0))
                        .text_color(palette.ink)
                        .child(translate_registered(language, route.title_key)),
                )
                .child(
                    div()
                        .text_color(palette.ink_3)
                        .child(translate(language, Key::AppPlaceholderBody)),
                )
                .into_any_element(),
            None => div()
                .flex()
                .flex_col()
                .items_center()
                .justify_center()
                .gap(space(2))
                .child(
                    div()
                        .text_size(px(22.0))
                        .text_color(palette.ink)
                        .child(translate(language, Key::AppEmptyTitle)),
                )
                .child(
                    div()
                        .text_color(palette.ink_3)
                        .child(translate(language, Key::AppEmptyBody)),
                )
                .into_any_element(),
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn render_footer(
        &self,
        language: Language,
        include_nav: bool,
        theme_glyph: &'static str,
        theme_label: &'static str,
        theme_tooltip: &'static str,
        language_glyph: &'static str,
        language_label: &'static str,
        language_tooltip: &'static str,
        palette: &theme::Palette,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        div()
            .flex()
            .flex_row()
            .items_center()
            .h(px(30.0))
            .px(space(2))
            .gap(px(2.0))
            .bg(palette.frame)
            .border_t_1()
            .border_color(palette.line)
            .text_size(px(12.0))
            .children(if include_nav {
                self.render_nav_items(language, palette, cx)
            } else {
                Vec::new()
            })
            .child(
                div()
                    .id("theme-toggle")
                    .size(px(22.0))
                    .rounded(px(RADIUS_MEDIUM))
                    .flex()
                    .items_center()
                    .justify_center()
                    .text_color(palette.ink_3)
                    .hover(|style| style.bg(palette.soft))
                    .child(theme_glyph)
                    .tooltip(move |_, cx| {
                        cx.new(|_| TooltipText {
                            text: format!("{theme_tooltip} · {theme_label}").into(),
                        })
                        .into()
                    })
                    .on_click(cx.listener(|this, _, window, cx| {
                        let preference = this.cycle_theme();
                        let mode = theme::resolve(preference, window.appearance());
                        theme::apply(mode, cx);
                        cx.notify();
                    })),
            )
            .child(
                div()
                    .id("language-toggle")
                    .size(px(22.0))
                    .rounded(px(RADIUS_MEDIUM))
                    .flex()
                    .items_center()
                    .justify_center()
                    .text_color(palette.ink_3)
                    .hover(|style| style.bg(palette.soft))
                    .child(language_glyph)
                    .tooltip(move |_, cx| {
                        cx.new(|_| TooltipText {
                            text: format!("{language_tooltip} · {language_label}").into(),
                        })
                        .into()
                    })
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.toggle_language();
                        cx.notify();
                    })),
            )
            .child(div().flex_1())
            .child(
                div()
                    .text_color(palette.ink_3)
                    .child(concat!("v", env!("CARGO_PKG_VERSION"))),
            )
            .into_any_element()
    }
}

/// 悬停 tooltip 的内容视图（footer 图标按钮使用）。
struct TooltipText {
    text: SharedString,
}

impl Render for TooltipText {
    fn render(&mut self, _window: &mut Window, _cx: &mut Context<Self>) -> impl IntoElement {
        div()
            .px(px(8.0))
            .py(px(4.0))
            .rounded(px(4.0))
            .bg(rgba(0x1f_20_22_f2))
            .text_color(hsla_white())
            .text_size(px(11.0))
            .child(self.text.clone())
    }
}

fn hsla_white() -> Hsla {
    rgba(0xff_ff_ff_ff).into()
}

#[cfg(test)]
mod tests {
    use super::RootView;
    use crate::i18n::{translate, Key, Language};
    use crate::registration::build_registry;
    use crate::theme::ThemePreference;
    use cgc_platform::session::{
        AuthError, FakeAuthApi, MemoryStore, SessionService, SignedInSession,
    };

    fn fake_signed_in() -> SignedInSession {
        SignedInSession {
            token: "fake-desktop-token".to_string(),
            user_id: "u-1".to_string(),
            email: Some("demo@example.com".to_string()),
            is_platform_admin: false,
        }
    }

    fn view() -> RootView {
        let session = SessionService::new(
            Box::new(FakeAuthApi::demo()),
            Box::new(MemoryStore::default()),
        );
        RootView::with_session(
            build_registry().expect("registry builds"),
            Language::Zh,
            ThemePreference::System,
            session,
        )
    }

    #[test]
    fn starts_on_home_signed_out() {
        let view = view();
        assert_eq!(view.current().map(|route| route.id), Some("app.home"));
        assert_eq!(view.language(), Language::Zh);
        assert_eq!(view.preference(), ThemePreference::System);
        assert!(
            !view.is_signed_in(),
            "fresh session must show the login page"
        );
    }

    #[test]
    fn fake_login_switches_guard_to_signed_in_and_back() {
        let mut view = view();
        view.session_mut()
            .sign_in("demo@example.com", "demo")
            .expect("fake login");
        assert!(view.is_signed_in());

        view.session_mut().sign_out_local();
        assert!(
            !view.is_signed_in(),
            "sign out must return to the login page"
        );
    }

    #[test]
    fn finish_login_success_enters_shell() {
        let mut view = view();
        view.finish_login(Ok(fake_signed_in()));
        assert!(view.is_signed_in());
        assert!(view.login_error().is_none());
    }

    #[test]
    fn finish_login_invalid_credentials_shows_error() {
        let mut view = view();
        view.finish_login(Err(AuthError::InvalidCredentials));
        assert!(!view.is_signed_in());
        assert!(view.login_error().is_some());
    }

    #[test]
    fn bad_credentials_keep_signed_out() {
        let mut view = view();
        assert!(view
            .session_mut()
            .sign_in("demo@example.com", "nope")
            .is_err());
        assert!(!view.is_signed_in());
    }

    #[test]
    fn toggling_language_changes_labels() {
        let mut view = view();
        let before = translate(view.language(), Key::AppEmptyTitle);
        view.toggle_language();
        let after = translate(view.language(), Key::AppEmptyTitle);
        assert_ne!(before, after);
        view.toggle_language();
        assert_eq!(translate(view.language(), Key::AppEmptyTitle), before);
    }

    #[test]
    fn cycling_theme_visits_all_preferences() {
        let mut view = view();
        assert_eq!(view.cycle_theme(), ThemePreference::Light);
        assert_eq!(view.cycle_theme(), ThemePreference::Dark);
        assert_eq!(view.cycle_theme(), ThemePreference::System);
    }

    #[test]
    fn account_menu_toggles_and_closes() {
        let mut view = view();
        assert!(!view.account_menu_open());
        assert!(view.toggle_account_menu());
        view.close_account_menu();
        assert!(!view.account_menu_open());
    }

    #[test]
    fn selecting_a_registered_route_updates_current() {
        let mut view = view();
        let events = view
            .registry
            .routes()
            .iter()
            .find(|route| route.id == "events.list")
            .copied()
            .expect("events route registered");
        view.select(events);
        assert_eq!(view.current().map(|route| route.id), Some("events.list"));
    }
}
