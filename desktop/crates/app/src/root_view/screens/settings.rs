use super::super::*;

impl RootView {
    pub(in crate::root_view) fn render_settings(
        &mut self,
        language: Language,
        palette: &theme::Palette,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let email = self
            .session
            .signed_in()
            .and_then(|session| session.email.clone())
            .unwrap_or_else(|| "—".to_string());
        let user_id = self
            .session
            .signed_in()
            .map(|session| session.user_id.clone())
            .unwrap_or_default();
        let workspace = self
            .workspaces
            .current()
            .map(|workspace| workspace.name.clone())
            .unwrap_or_else(|| "—".to_string());
        let error = self.settings_error.clone().map(|message| {
            div()
                .text_size(px(12.0))
                .text_color(palette.danger)
                .child(message)
                .into_any_element()
        });
        let revoke = div()
            .id("settings-revoke-device")
            .role(Role::Button)
            .aria_label(translate(language, Key::AppSettingsRevokeDevice))
            .px(space(2))
            .py(px(6.0))
            .rounded(px(RADIUS_MEDIUM))
            .bg(if self.revoking {
                palette.soft
            } else {
                palette.danger
            })
            .text_color(if self.revoking {
                palette.ink_3
            } else {
                palette.canvas
            })
            .child(if self.revoking {
                translate(language, Key::AppSettingsRevoking)
            } else {
                translate(language, Key::AppSettingsRevokeDevice)
            })
            .on_click(cx.listener(|this, _, _, cx| this.revoke_device(cx)));

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

    pub(in crate::root_view) fn revoke_device(&mut self, cx: &mut Context<Self>) {
        if self.revoking {
            return;
        }
        let Some(token) = self
            .session
            .signed_in()
            .map(|session| session.token.clone())
        else {
            return;
        };
        self.revoking = true;
        self.settings_error = None;
        let api = self.session.api_handle();
        let task = cx
            .background_executor()
            .spawn(async move { api.revoke(&token) });
        cx.spawn(async move |this, cx| {
            let result = task.await;
            let _ = this.update(cx, |this, cx| {
                this.revoking = false;
                match result {
                    Ok(()) => {
                        this.session.sign_out_local();
                        this.workspaces.reset();
                        this.workspaces_started = false;
                        this.reset_workspace_data();
                        this.navigate("/");
                    }
                    Err(error) => {
                        this.settings_error = Some(error.diagnostic());
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }
}
