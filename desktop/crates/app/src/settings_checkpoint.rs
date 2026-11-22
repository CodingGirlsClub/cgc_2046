//! 设置页（AI → 通用）的 Git 检查点对象库占用展示与手动一键清理入口（ADR-0028 决策 9 Phase 2）。

use std::sync::{Arc, Mutex};

use cgc_agent_checkpoint::{CheckpointStorageSummary, ReclaimReport};
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::setting::SettingItem;
use gpui_kit::component::{Disableable as _, Sizable as _};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    div, px, Context, InteractiveElement as _, IntoElement as _, ParentElement as _, Styled as _,
    WeakEntity,
};

use crate::native_runtime::{format_bytes, NativeRuntimeError, NativeRuntimeHandle};
use crate::settings_window::SettingsWindowView;
use crate::theme::{self, space};

#[derive(Clone, Debug, Default)]
pub(crate) struct CheckpointSettingsState {
    pub loading: bool,
    pub cleaning: bool,
    pub armed: bool,
    pub request_serial: u64,
    pub summary: Option<CheckpointStorageSummary>,
    pub unavailable: bool,
    pub notice: Option<String>,
    pub error: Option<String>,
}

impl CheckpointSettingsState {
    pub(crate) fn for_runtime(has_runtime: bool) -> Self {
        Self {
            loading: false,
            unavailable: !has_runtime,
            ..Self::default()
        }
    }

    pub(crate) fn apply_summary(
        &mut self,
        result: Result<Option<CheckpointStorageSummary>, NativeRuntimeError>,
    ) {
        self.loading = false;
        match result {
            Ok(Some(summary)) => {
                self.unavailable = false;
                self.summary = Some(summary);
                self.error = None;
            }
            Ok(None) => {
                self.unavailable = true;
                self.summary = None;
                self.armed = false;
            }
            Err(error) => self.error = Some(error.to_string()),
        }
    }

    pub(crate) fn apply_cleanup(&mut self, result: Result<ReclaimReport, NativeRuntimeError>) {
        self.cleaning = false;
        self.armed = false;
        match result {
            Ok(report) => {
                self.unavailable = false;
                self.error = None;
                self.summary = Some(CheckpointStorageSummary {
                    stats: report.stats_after,
                    total_refs: report.remaining_refs,
                    limit_bytes: report.limit_bytes,
                });
                let used = format_bytes(report.stats_after.total_bytes());
                let limit = format_bytes(report.limit_bytes);
                let pruned = report.pruned.len();
                let remain = report.remaining_refs;
                let suffix = if report.within_budget {
                    format!("（保留当前对话最新 {remain} 条）")
                } else {
                    "（仍高于上限，未触碰你的 Git 分支或提交）".to_string()
                };
                self.notice = Some(format!(
                    "已清理 {pruned} 个历史检查点，当前占用 {used} / {limit}{suffix}"
                ));
            }
            Err(error) => self.error = Some(error.to_string()),
        }
    }

    pub(crate) fn status_line(&self) -> (String, bool) {
        if self.loading && self.summary.is_none() {
            return ("正在统计检查点仓库占用…".into(), false);
        }
        if self.unavailable {
            let msg = "当前工作区未启用 Git 检查点（打开 Native Agent 工作区且安装 Git 后可用）。";
            return (msg.into(), false);
        }
        if let Some(summary) = self.summary {
            let used = summary.stats.total_bytes();
            let used_s = format_bytes(used);
            let limit_s = format_bytes(summary.limit_bytes);
            let refs = summary.total_refs;
            return (
                format!("当前占用：{used_s} / {limit_s}（共 {refs} 个检查点）"),
                used > summary.limit_bytes,
            );
        }
        ("尚未读取检查点仓库占用".into(), false)
    }

    pub(crate) fn button_label(&self) -> &'static str {
        if self.cleaning {
            "正在清理…"
        } else if self.armed {
            "再次点击确认清理"
        } else {
            "清理全部历史检查点"
        }
    }
}

pub(crate) fn refresh(
    runtime: Option<NativeRuntimeHandle>,
    state: Arc<Mutex<CheckpointSettingsState>>,
    cx: &mut Context<SettingsWindowView>,
) {
    let Some(runtime) = runtime else {
        if let Ok(mut guard) = state.lock() {
            guard.loading = false;
            guard.unavailable = true;
            guard.summary = None;
            guard.armed = false;
        }
        cx.notify();
        return;
    };
    let serial = if let Ok(mut guard) = state.lock() {
        if guard.cleaning || guard.loading {
            return;
        }
        guard.loading = true;
        guard.error = None;
        guard.request_serial = guard.request_serial.wrapping_add(1);
        guard.request_serial
    } else {
        return;
    };
    cx.notify();
    let operation = runtime.inspect_checkpoint_storage();
    cx.spawn(async move |this, cx| {
        let result = operation.await;
        if let Ok(mut guard) = state.lock() {
            if guard.request_serial == serial && !guard.cleaning {
                guard.apply_summary(result);
            }
        }
        let _ = this.update(cx, |_, cx| cx.notify());
    })
    .detach();
}

pub(crate) fn handle_clear_click(
    runtime: Option<NativeRuntimeHandle>,
    state: Arc<Mutex<CheckpointSettingsState>>,
    cx: &mut Context<SettingsWindowView>,
) {
    let Some(runtime) = runtime else {
        if let Ok(mut guard) = state.lock() {
            guard.armed = false;
            guard.unavailable = true;
        }
        cx.notify();
        return;
    };
    if let Ok(mut guard) = state.lock() {
        if guard.cleaning || guard.loading || guard.unavailable {
            return;
        }
        if !guard.armed {
            guard.armed = true;
            guard.error = None;
            guard.notice = None;
            drop(guard);
            cx.notify();
            return;
        }
        guard.armed = false;
        guard.cleaning = true;
        guard.error = None;
        guard.notice = None;
        guard.request_serial = guard.request_serial.wrapping_add(1);
    }
    cx.notify();
    let operation = runtime.purge_checkpoint_history();
    cx.spawn(async move |this, cx| {
        let result = operation.await;
        if let Ok(mut guard) = state.lock() {
            guard.apply_cleanup(result);
        }
        let _ = this.update(cx, |_, cx| cx.notify());
    })
    .detach();
}

pub(crate) fn render_item(
    state: Arc<Mutex<CheckpointSettingsState>>,
    weak: WeakEntity<SettingsWindowView>,
) -> SettingItem {
    SettingItem::render(move |_options, _window, cx| {
        let palette = theme::palette_from_theme(cx);
        let snapshot = state.lock().map(|guard| guard.clone()).unwrap_or_default();
        let (status_text, over_budget) = snapshot.status_line();
        let disabled = snapshot.cleaning || snapshot.loading || snapshot.unavailable;
        let status_color = if over_budget {
            palette.danger
        } else {
            palette.ink_2
        };
        let clear_weak = weak.clone();
        let refresh_weak = weak.clone();

        let mut column = div()
            .flex()
            .flex_col()
            .gap(px(4.0))
            .child(div().text_size(px(11.0)).text_color(palette.ink_3).child(
                "删除当前工作区的历史 Git 检查点并立即执行 gc --prune=now 回收空间（保留当前对话最新 1 条，绝不触碰你的 Git 分支或提交）。",
            ))
            .child(
                div()
                    .id("settings-checkpoint-storage-status")
                    .text_size(px(11.0))
                    .text_color(status_color)
                    .child(status_text),
            )
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap(space(2))
                    .child(
                        Button::new("settings-clear-checkpoint-history")
                            .outline()
                            .small()
                            .when(snapshot.armed, |button| button.danger())
                            .disabled(disabled)
                            .label(snapshot.button_label())
                            .on_click(move |_, _, cx| {
                                let _ = clear_weak.update(cx, |this, cx| {
                                    this.trigger_checkpoint_cleanup(cx);
                                });
                            }),
                    )
                    .child(
                        Button::new("settings-refresh-checkpoint-storage")
                            .ghost()
                            .small()
                            .disabled(disabled)
                            .label("刷新")
                            .on_click(move |_, _, cx| {
                                let _ = refresh_weak.update(cx, |this, cx| {
                                    this.refresh_checkpoint_storage(cx);
                                });
                            }),
                    ),
            );
        if let Some(notice) = snapshot.notice {
            column = column.child(
                div()
                    .id("settings-checkpoint-storage-notice")
                    .text_size(px(10.0))
                    .text_color(palette.ink_3)
                    .child(notice),
            );
        }
        if let Some(error) = snapshot.error {
            column = column.child(
                div()
                    .id("settings-checkpoint-storage-error")
                    .text_size(px(10.0))
                    .text_color(palette.danger)
                    .child(error),
            );
        }
        column.into_any_element()
    })
}

#[cfg(test)]
mod tests {
    use super::CheckpointSettingsState;
    use cgc_agent_checkpoint::{
        CheckpointStorageSummary, ObjectStoreStats, PrunedRef, ReclaimReport,
    };

    #[test]
    fn state_transitions_format_summary_and_cleanup_feedback() {
        let mut state = CheckpointSettingsState::for_runtime(true);
        state.loading = true;
        assert_eq!(state.status_line().0, "正在统计检查点仓库占用…");

        state.apply_summary(Ok(Some(CheckpointStorageSummary {
            stats: ObjectStoreStats {
                loose_bytes: 2 * 1024 * 1024,
                pack_bytes: 512 * 1024,
                ..Default::default()
            },
            total_refs: 12,
            limit_bytes: 500 * 1024 * 1024,
        })));
        assert!(!state.loading);
        let (line, over) = state.status_line();
        assert!(!over && line.contains("2.5 MiB / 500.0 MiB") && line.contains("共 12 个检查点"));
        assert_eq!(state.button_label(), "清理全部历史检查点");

        state.armed = true;
        assert_eq!(state.button_label(), "再次点击确认清理");

        state.apply_cleanup(Ok(ReclaimReport {
            pruned: vec![PrunedRef {
                thread_id: "t1".into(),
                seq: 1,
                ref_name: "refs/cgc/checkpoints/t1/1".into(),
            }],
            remaining_refs: 1,
            stats_after: ObjectStoreStats {
                loose_bytes: 192 * 1024,
                ..Default::default()
            },
            within_budget: true,
            limit_bytes: 500 * 1024 * 1024,
        }));
        assert!(!state.armed && !state.cleaning);
        assert_eq!(state.summary.unwrap().total_refs, 1);
        let notice = state.notice.as_deref().unwrap();
        assert!(
            notice.contains("已清理 1 个历史检查点") && notice.contains("保留当前对话最新 1 条")
        );
    }
}

#[cfg(all(test, cgc_ui_tests))]
mod ui_tests {
    use std::sync::atomic::AtomicBool;
    use std::sync::Arc;

    use cgc_agent_checkpoint::CheckpointManager;
    use cgc_agent_core::{SelectedModel, Thread};
    use cgc_agent_provider::{EchoProvider, Model, ModelLimits, ProviderId};
    use cgc_agent_store::SessionStore;
    use cgc_agent_tools::{ToolContext, ToolRegistry};
    use cgc_platform::session::FakeAuthApi;
    use gpui_kit::test::TestWindowExt;
    use gpui_kit::{
        px, size, AppContext, Bounds, TestAppContext, VisualTestContext, WeakEntity, WindowBounds,
        WindowOptions,
    };

    use crate::i18n::Language;
    use crate::native_runtime::{NativeRuntimeConfig, NativeRuntimeHandle};
    use crate::settings_window::SettingsWindowView;

    #[gpui_kit::test]
    fn settings_ai_page_displays_checkpoint_storage_and_purges_history_on_double_confirm(
        cx: &mut TestAppContext,
    ) {
        cx.executor().allow_parking();
        let root =
            std::env::temp_dir().join(format!("cgc-settings-cp-ui-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&root).unwrap();
        let manager = CheckpointManager::initialize(&root).unwrap();
        for (tid, seq, body) in [("old-thread", 1, "old-1\n"), ("old-thread", 2, "old-2\n")] {
            std::fs::write(root.join("a.txt"), body).unwrap();
            manager.snapshot(tid, seq).unwrap();
        }
        let model = Model::new(
            ProviderId::new("test"),
            "Test",
            "m1",
            "m1",
            ModelLimits::new(8_000, 1_000),
        );
        let thread = Thread::new(
            "ui-thread",
            SelectedModel::new(model.provider_id.clone(), model.id.clone()),
        );
        let runtime = NativeRuntimeHandle::spawn(
            thread,
            None,
            NativeRuntimeConfig {
                provider: Arc::new(EchoProvider::new(model.clone())),
                model,
                registry: Arc::new(ToolRegistry::new()),
                context: ToolContext::new(&root),
                context_size: 8_000,
                auto_approve: false,
            },
            Some(SessionStore::open_in_memory().unwrap()),
        );
        let scope = crate::agent_scope::AgentScope {
            key: "cp-ui".into(),
            root: root.clone(),
        };
        let active_thread_id = futures::executor::block_on(runtime.switch_scope(scope))
            .expect("switch scope")
            .thread
            .id
            .clone();
        for (seq, body) in [(1, "cur-1\n"), (2, "cur-2\n")] {
            std::fs::write(root.join("a.txt"), body).unwrap();
            manager.snapshot(&active_thread_id, seq).unwrap();
        }

        cx.update(gpui_kit::init);
        let bounds = cx.update(|cx| Bounds::centered(None, size(px(620.0), px(900.0)), cx));
        let options = WindowOptions {
            window_bounds: Some(WindowBounds::Windowed(bounds)),
            ..Default::default()
        };
        let (handle, settings) = cx.update(|cx| {
            gpui_kit::open_window(options, cx, |_, cx| {
                cx.new(|cx| {
                    let mut view = SettingsWindowView::new(
                        Language::Zh,
                        None,
                        "cp-ui-user".into(),
                        Some("Checkpoint UI".into()),
                        String::new(),
                        Arc::new(FakeAuthApi::demo()),
                        Arc::new(AtomicBool::new(false)),
                        Some(runtime.clone()),
                        WeakEntity::new_invalid(),
                        cx,
                    );
                    view.open_ai(cx);
                    view
                })
            })
            .expect("settings window")
        });

        let mut visual = VisualTestContext::from_window(handle, cx);
        for _ in 0..40 {
            visual.run_until_parked();
            if visual.update(|_, cx| {
                settings
                    .read(cx)
                    .checkpoint_storage_summary_for_test()
                    .is_some()
            }) {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        visual.update(|window, cx| {
            window.render_frame(cx);
            assert!(window.find("settings-clear-checkpoint-history").visible());
            assert!(window.find("settings-refresh-checkpoint-storage").visible());
            let summary = settings
                .read(cx)
                .checkpoint_storage_summary_for_test()
                .expect("loaded summary");
            assert_eq!(summary.total_refs, 4);
        });

        visual.update(|_, cx| settings.update(cx, |view, cx| view.trigger_checkpoint_cleanup(cx)));
        assert_eq!(manager.storage_summary().unwrap().total_refs, 4);

        visual.update(|_, cx| settings.update(cx, |view, cx| view.trigger_checkpoint_cleanup(cx)));
        for _ in 0..60 {
            visual.run_until_parked();
            if visual.update(|_, cx| {
                settings
                    .read(cx)
                    .checkpoint_storage_notice_for_test()
                    .is_some()
            }) {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(15));
        }

        visual.update(|_, cx| {
            let view = settings.read(cx);
            let notice = view.checkpoint_storage_notice_for_test().unwrap();
            assert!(notice.contains("已清理 3 个历史检查点"), "notice: {notice}");
            let summary = view.checkpoint_storage_summary_for_test().unwrap();
            assert_eq!(summary.total_refs, 1);
        });
        assert_eq!(manager.storage_summary().unwrap().total_refs, 1);
        assert!(manager.list("old-thread").unwrap().is_empty());
        assert_eq!(manager.list(&active_thread_id).unwrap()[0].seq, 2);
        let _ = std::fs::remove_dir_all(root);
    }
}
