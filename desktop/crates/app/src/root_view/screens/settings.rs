use super::super::*;
use super::ScreenContext;
use gpui_kit::component::button::{Button, ButtonVariants};
use gpui_kit::component::Disableable;

pub(in crate::root_view) fn render_settings(
    ctx: &mut ScreenContext<'_>,
    language: Language,
    palette: &theme::Palette,
    cx: &mut Context<RootView>,
) -> AnyElement {
    let email = ctx
        .session
        .signed_in()
        .and_then(|session| session.email.clone())
        .unwrap_or_else(|| "—".to_string());
    let user_id = ctx
        .session
        .signed_in()
        .map(|session| session.user_id.clone())
        .unwrap_or_default();
    let workspace = ctx
        .workspaces
        .current()
        .map(|workspace| workspace.name.clone())
        .unwrap_or_else(|| "—".to_string());
    let error = ctx.settings_error.clone().map(|message| {
        div()
            .text_size(px(12.0))
            .text_color(palette.danger)
            .child(message)
            .into_any_element()
    });
    let revoke = {
        let root = cx.entity().downgrade();
        Button::new("settings-revoke-device")
            .label(if ctx.revoking {
                translate(language, Key::AppSettingsRevoking)
            } else {
                translate(language, Key::AppSettingsRevokeDevice)
            })
            .danger()
            .disabled(ctx.revoking)
            .on_click(move |_, _, cx| {
                let _ = root.update(cx, |this, cx| this.revoke_device(cx));
            })
    };

    div()
        .flex()
        .flex_col()
        .gap(space(3))
        .child(
            div()
                .text_size(px(24.0))
                .text_color(palette.ink)
                .child(translate(language, Key::AppSettingsTitle)),
        )
        .child(
            div()
                .flex()
                .flex_col()
                .gap(space(1))
                .p(space(2))
                .rounded(px(RADIUS_LARGE))
                .border_1()
                .border_color(palette.line)
                .bg(palette.card)
                .child(
                    div()
                        .text_size(px(12.0))
                        .text_color(palette.ink_3)
                        .child(translate(language, Key::AppSettingsAccount)),
                )
                .child(
                    div()
                        .text_size(px(14.0))
                        .text_color(palette.ink)
                        .child(format!("{email} · {user_id}")),
                )
                .child(
                    div()
                        .text_size(px(12.0))
                        .text_color(palette.ink_3)
                        .child(format!(
                            "{} {workspace}",
                            translate(language, Key::AppSettingsWorkspace)
                        )),
                )
                .child(
                    div()
                        .text_size(px(11.0))
                        .text_color(palette.ink_3)
                        .child(format!(
                            "{} {}",
                            translate(language, Key::AppSettingsBuild),
                            crate::build_info::about_line()
                        )),
                ),
        )
        .child(
            div()
                .flex()
                .flex_col()
                .gap(space(1))
                .child(
                    div()
                        .text_size(px(12.0))
                        .text_color(palette.ink_3)
                        .child(translate(language, Key::AppSettingsRevokeHint)),
                )
                .children(error)
                .child(revoke),
        )
        .into_any_element()
}
