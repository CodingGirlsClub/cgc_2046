//! 桌面客户端轻量更新提示横幅与启动版本检查（ADR-0027 Phase 1）。

use std::time::Duration;

use cgc_platform::api::upgrade::{sanitize_download_url, DEFAULT_DOWNLOAD_URL};
use cgc_platform::update::{check_for_update, UpdateCheckOutcome};
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::Sizable as _;
use gpui_kit::InteractiveElement as _;
use gpui_kit::*;

use super::RootView;
use crate::i18n::{translate, Key, Language};
use crate::theme::{self, space};

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
            Ok(UpdateCheckOutcome::UpgradeRequired(notice)) => {
                self.apply_upgrade_notice(notice);
            }
            Ok(UpdateCheckOutcome::UpToDate) => {}
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

    pub(in crate::root_view) fn render_update_banner(
        &self,
        language: Language,
        palette: &theme::Palette,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        if self.is_upgrade_gate_active() {
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
}

#[cfg(test)]
mod tests {
    use super::{Key, RootView, UpdateBannerState, DEFAULT_DOWNLOAD_URL};
    use crate::i18n::Language;
    use crate::registration::build_registry;
    use crate::root_view::{demo_signed_in, upgrade_overlay_title_key, EnrollmentsListState};
    use crate::theme::ThemePreference;
    use cgc_courses::catalog::{CoursesError, CoursesListState};
    use cgc_courses::content::CourseContentState;
    use cgc_courses::notes::{NotesError, NotesState};
    use cgc_courses::projection::ProjectionState;
    use cgc_events::list::{EventsError, ListState};
    use cgc_platform::api::UpgradeNotice;
    use cgc_platform::workspace::{WorkspaceError, WorkspaceListState};

    #[test]
    fn upgrade_title_key_reflects_notice_code() {
        let kill = UpgradeNotice {
            code: "desktop_client_disabled".into(),
            message: "维护中".into(),
            min_version: None,
            download_url: None,
        };
        assert_eq!(
            upgrade_overlay_title_key(&kill),
            Key::PlatformUpgradeDisabledTitle
        );

        let blocked = UpgradeNotice {
            code: "client_version_blocked".into(),
            message: "已停用".into(),
            min_version: None,
            download_url: None,
        };
        assert_eq!(
            upgrade_overlay_title_key(&blocked),
            Key::PlatformUpgradeBlockedTitle
        );

        let upgrade = UpgradeNotice::fallback_from_message("请升级".into());
        assert_eq!(
            upgrade_overlay_title_key(&upgrade),
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
            download_url: "https://evil.example/payload.exe".into(),
            release_notes: None,
            dismissed: false,
        };
        assert_eq!(untrusted.safe_download_url(), DEFAULT_DOWNLOAD_URL);
    }

    #[test]
    fn clear_upgrade_overlay_state_resets_failed_data_services_for_signed_in_user() {
        let _guard = crate::root_view::upgrade_latch_test_lock();
        let _isolation = crate::root_view::tests::isolate_workspace_state();
        let mut view = RootView::with_session(
            build_registry().expect("registry"),
            Language::Zh,
            ThemePreference::Light,
            demo_signed_in(),
        );

        view.apply_upgrade_notice(UpgradeNotice::fallback_from_message("暂停服务".into()));
        view.update_check_started = true;
        view.session_checked = true;

        view.workspaces
            .fail(&WorkspaceError::Transport("426".into()));
        view.workspaces_started = true;

        view.events.fail(&EventsError::Transport("426".into()));
        view.events_started = true;

        view.detail.fail(&EventsError::Transport("426".into()));
        view.detail_started = true;

        view.courses.fail(&CoursesError::Transport("426".into()));
        view.courses_started = true;

        view.course_detail
            .fail(&CoursesError::Transport("426".into()));
        view.course_detail_started = true;

        view.content.fail(&CoursesError::Transport("426".into()));
        view.notes.fail(&NotesError::Transport("426".into()));
        view.notes_started = true;
        view.projection.fail(&CoursesError::Transport("426".into()));

        view.nav_events.fail(&EventsError::Transport("426".into()));
        view.nav_events_started = true;

        view.nav_courses
            .fail(&CoursesError::Transport("426".into()));
        view.nav_courses_started = true;

        view.enrollments_state = EnrollmentsListState::Failed("426".into());
        view.enrollments_started = true;

        view.clear_upgrade_overlay_state();

        assert!(view.upgrade_notice.is_none());
        assert!(!view.update_check_started);
        assert!(!view.session_checked);
        assert_eq!(view.workspaces.state(), &WorkspaceListState::Idle);
        assert!(!view.workspaces_started);
        assert_eq!(view.events.state(), &ListState::Idle);
        assert!(!view.events_started);
        assert_eq!(view.detail.state(), &ListState::Idle);
        assert!(!view.detail_started);
        assert_eq!(view.courses.state(), &CoursesListState::Idle);
        assert!(!view.courses_started);
        assert_eq!(view.course_detail.state(), &CoursesListState::Idle);
        assert!(!view.course_detail_started);
        assert_eq!(view.content.state(), &CourseContentState::Idle);
        assert_eq!(view.notes.state(), &NotesState::Idle);
        assert!(!view.notes_started);
        assert_eq!(view.projection.state(), &ProjectionState::Idle);
        assert_eq!(view.nav_events.state(), &ListState::Idle);
        assert!(!view.nav_events_started);
        assert_eq!(view.nav_courses.state(), &CoursesListState::Idle);
        assert!(!view.nav_courses_started);
        assert_eq!(view.enrollments_state, EnrollmentsListState::Idle);
        assert!(!view.enrollments_started);
    }
}
