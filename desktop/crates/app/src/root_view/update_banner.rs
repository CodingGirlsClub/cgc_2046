//! 桌面客户端轻量更新提示横幅与 HTTP 426 强制升级/止损覆盖层（ADR-0027 Phase 1）。

use std::time::Duration;

use cgc_platform::api::upgrade::{
    clear_upgrade_notice, sanitize_download_url, upgrade_notice, UpgradeNotice,
    DEFAULT_DOWNLOAD_URL,
};
use cgc_platform::update::{check_for_update, UpdateCheckOutcome};
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::Sizable as _;
use gpui_kit::InteractiveElement as _;
use gpui_kit::*;

use super::RootView;
use crate::i18n::{translate, Key, Language};
use crate::theme::{self, space, RADIUS_LARGE, RADIUS_MEDIUM};

#[derive(Clone, Debug, PartialEq, Eq)]
pub(in crate::root_view) struct UpdateBannerState {
    pub latest_version: String,
    pub download_url: String,
    pub release_notes: Option<String>,
    pub dismissed: bool,
}

impl UpdateBannerState {
    pub fn safe_download_url(&self) -> String {
        sanitize_download_url(&self.download_url)
            .unwrap_or_else(|| DEFAULT_DOWNLOAD_URL.to_string())
    }
}

pub(in crate::root_view) fn resolve_upgrade_title_key(notice: &UpgradeNotice) -> Key {
    if notice.is_kill_switch() {
        Key::PlatformUpgradeDisabledTitle
    } else if notice.is_blocked() {
        Key::PlatformUpgradeBlockedTitle
    } else {
        Key::PlatformUpgradeTitle
    }
}

impl RootView {
    pub(in crate::root_view) fn maybe_start_update_check(&mut self, cx: &mut Context<Self>) {
        if self.update_check_started || cgc_platform::runtime::use_fake_backend() {
            return;
        }
        self.update_check_started = true;
        let current_version = cgc_platform::runtime::client_version().to_string();
        let task = cx
            .background_executor()
            .spawn(async move { check_for_update(None, &current_version, Duration::from_secs(6)) });
        cx.spawn(async move |this, cx| {
            let outcome = task.await;
            let _ = this.update(cx, |this, cx| {
                this.apply_update_check_outcome(outcome);
                cx.notify();
            });
        })
        .detach();
    }

    pub(in crate::root_view) fn apply_update_check_outcome(
        &mut self,
        outcome: Result<UpdateCheckOutcome, String>,
    ) {
        match outcome {
            Ok(UpdateCheckOutcome::UpdateAvailable {
                latest_version,
                download_url,
                release_notes,
            }) => {
                self.update_banner = Some(UpdateBannerState {
                    latest_version,
                    download_url,
                    release_notes,
                    dismissed: false,
                });
            }
            Ok(UpdateCheckOutcome::UpgradeRequired(_)) | Ok(UpdateCheckOutcome::UpToDate) => {}
            Err(error) => {
                log::debug!(target: "update", "版本检查未生效（离线或旧后端）：{error}");
            }
        }
    }

    pub(in crate::root_view) fn dismiss_update_banner(&mut self, cx: &mut Context<Self>) {
        if let Some(banner) = &mut self.update_banner {
            banner.dismissed = true;
            cx.notify();
        }
    }

    pub(in crate::root_view) fn retry_after_upgrade_notice(&mut self, cx: &mut Context<Self>) {
        clear_upgrade_notice();
        self.update_check_started = false;
        self.session_checked = false;
        self.workspaces_started = false;
        self.events_started = false;
        self.courses_started = false;
        self.enrollments_started = false;
        self.maybe_start_update_check(cx);
        cx.notify();
    }

    pub(in crate::root_view) fn render_update_banner(
        &self,
        language: Language,
        palette: &theme::Palette,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        if upgrade_notice().is_some() {
            return None;
        }
        let banner = self.update_banner.as_ref().filter(|b| !b.dismissed)?;
        let url = banner.safe_download_url();
        let label = match banner.release_notes.as_deref() {
            Some(notes) if !notes.trim().is_empty() => format!(
                "{} v{} — {}",
                translate(language, Key::PlatformUpdateAvailable),
                banner.latest_version,
                notes.trim()
            ),
            _ => format!(
                "{} v{}",
                translate(language, Key::PlatformUpdateAvailable),
                banner.latest_version
            ),
        };
        let root_for_dismiss = cx.entity().downgrade();

        Some(
            div()
                .id("desktop-update-banner")
                .w_full()
                .flex()
                .flex_row()
                .items_center()
                .justify_between()
                .gap(space(2))
                .px(space(3))
                .py(space(1))
                .bg(palette.soft)
                .border_b_1()
                .border_color(palette.line)
                .child(
                    div()
                        .id("desktop-update-banner-text")
                        .test_support()
                        .role(Role::Alert)
                        .flex_1()
                        .min_w_0()
                        .text_size(px(12.0))
                        .text_color(palette.ink)
                        .child(label),
                )
                .child(
                    div()
                        .flex()
                        .flex_row()
                        .items_center()
                        .gap(space(1))
                        .child(
                            Button::new("desktop-update-banner-download")
                                .label(translate(language, Key::PlatformUpdateDownload))
                                .primary()
                                .xsmall()
                                .on_click(move |_, _, cx| {
                                    cx.open_url(&url);
                                }),
                        )
                        .child(
                            Button::new("desktop-update-banner-dismiss")
                                .label(translate(language, Key::PlatformUpdateDismiss))
                                .ghost()
                                .xsmall()
                                .on_click(move |_, _, cx| {
                                    let _ = root_for_dismiss
                                        .update(cx, |this, cx| this.dismiss_update_banner(cx));
                                }),
                        ),
                )
                .into_any_element(),
        )
    }

    pub(in crate::root_view) fn render_upgrade_overlay(
        &self,
        notice: &UpgradeNotice,
        language: Language,
        palette: &theme::Palette,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let title = translate(language, resolve_upgrade_title_key(notice));
        let message = if notice.message.trim().is_empty() {
            if notice.is_kill_switch() {
                translate(language, Key::PlatformUpgradeDisabledMessage).to_string()
            } else {
                translate(language, Key::PlatformUpgradeDefaultMessage).to_string()
            }
        } else {
            notice.message.clone()
        };
        let current_line = format!(
            "{}: v{}",
            translate(language, Key::PlatformUpgradeCurrentVersion),
            crate::build_info::VERSION
        );
        let min_line = notice.min_version.as_deref().map(|min| {
            format!(
                "{}: v{min}",
                translate(language, Key::PlatformUpgradeMinVersion)
            )
        });
        let download_url = notice.safe_download_url();
        let root_for_retry = cx.entity().downgrade();

        div()
            .id("desktop-upgrade-required-overlay")
            .test_support()
            .role(Role::Alert)
            .flex_1()
            .w_full()
            .flex()
            .items_center()
            .justify_center()
            .p(space(6))
            .bg(palette.canvas)
            .child(
                div()
                    .w(px(460.0))
                    .max_w_full()
                    .flex()
                    .flex_col()
                    .gap(space(3))
                    .p(space(6))
                    .rounded(px(RADIUS_LARGE))
                    .bg(palette.card)
                    .border_1()
                    .border_color(palette.line)
                    .child(
                        div()
                            .text_size(px(18.0))
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(palette.ink)
                            .child(title),
                    )
                    .child(
                        div()
                            .text_size(px(13.0))
                            .text_color(palette.ink_2)
                            .child(message),
                    )
                    .child(
                        div()
                            .flex()
                            .flex_col()
                            .gap(px(4.0))
                            .p(space(2))
                            .rounded(px(RADIUS_MEDIUM))
                            .bg(palette.soft)
                            .text_size(px(12.0))
                            .text_color(palette.ink_3)
                            .child(current_line)
                            .children(min_line),
                    )
                    .child(
                        div()
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap(space(2))
                            .pt(space(1))
                            .child(
                                Button::new("desktop-upgrade-download")
                                    .label(translate(language, Key::PlatformUpgradeDownload))
                                    .primary()
                                    .small()
                                    .on_click(move |_, _, cx| {
                                        cx.open_url(&download_url);
                                    }),
                            )
                            .child(
                                Button::new("desktop-upgrade-retry")
                                    .label(translate(language, Key::PlatformUpgradeRetry))
                                    .ghost()
                                    .small()
                                    .on_click(move |_, _, cx| {
                                        let _ = root_for_retry.update(cx, |this, cx| {
                                            this.retry_after_upgrade_notice(cx);
                                        });
                                    }),
                            ),
                    ),
            )
            .into_any_element()
    }
}

#[cfg(test)]
mod tests {
    use super::{
        resolve_upgrade_title_key, Key, UpdateBannerState, UpgradeNotice, DEFAULT_DOWNLOAD_URL,
    };

    #[test]
    fn upgrade_title_key_reflects_notice_code() {
        let kill = UpgradeNotice {
            code: "desktop_client_disabled".into(),
            message: "维护中".into(),
            min_version: None,
            latest_version: None,
            download_url: None,
        };
        assert_eq!(
            resolve_upgrade_title_key(&kill),
            Key::PlatformUpgradeDisabledTitle
        );

        let blocked = UpgradeNotice {
            code: "client_version_blocked".into(),
            message: "已停用".into(),
            min_version: None,
            latest_version: None,
            download_url: None,
        };
        assert_eq!(
            resolve_upgrade_title_key(&blocked),
            Key::PlatformUpgradeBlockedTitle
        );

        let upgrade = UpgradeNotice::fallback_from_message("请升级".into());
        assert_eq!(
            resolve_upgrade_title_key(&upgrade),
            Key::PlatformUpgradeTitle
        );
    }

    #[test]
    fn banner_state_sanitizes_download_url() {
        let valid = UpdateBannerState {
            latest_version: "0.2.0".into(),
            download_url: "https://codingirlsclub.com/releases".into(),
            release_notes: Some("notes".into()),
            dismissed: false,
        };
        assert_eq!(
            valid.safe_download_url(),
            "https://codingirlsclub.com/releases"
        );

        let untrusted = UpdateBannerState {
            latest_version: "0.2.0".into(),
            download_url: "javascript:alert(1)".into(),
            release_notes: None,
            dismissed: false,
        };
        assert_eq!(untrusted.safe_download_url(), DEFAULT_DOWNLOAD_URL);
    }
}
