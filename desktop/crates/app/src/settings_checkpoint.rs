//! 设置页（AI → 通用）的 Git 检查点对象库占用展示与手动一键清理入口（ADR-0028 决策 9 Phase 2）。

use std::path::{Path, PathBuf};
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

use crate::native_runtime::{
    format_bytes, NativeRuntimeError, NativeRuntimeHandle, WorkspaceCheckpointStorage,
};
use crate::settings_window::SettingsWindowView;
use crate::theme::{self, space};

#[derive(Clone, Debug, Default)]
pub(crate) struct CheckpointSettingsState {
    pub loading: bool,
    pub cleaning: bool,
    pub armed: bool,
    pub request_serial: u64,
    pub repo: Option<PathBuf>,
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
        result: Result<Option<WorkspaceCheckpointStorage>, NativeRuntimeError>,
        clear_error: bool,
    ) {
        self.loading = false;
        match result {
            Ok(Some(storage)) => {
                if self.repo.as_ref() != Some(&storage.repo) {
                    self.armed = false;
                    self.notice = None;
                }
                self.unavailable = false;
                self.repo = Some(storage.repo);
                self.summary = Some(storage.summary);
                if clear_error {
                    self.error = None;
                }
            }
            Ok(None) => {
                self.unavailable = true;
                self.repo = None;
                self.summary = None;
                self.armed = false;
                if clear_error {
                    self.error = None;
                }
            }
            Err(error) => self.error = Some(error.to_string()),
        }
    }

    /// 应用一次手动清理结果；若因工作区切换而被拒绝，返回 `true` 提示上层触发自动刷新。
    pub(crate) fn apply_cleanup(
        &mut self,
        result: Result<ReclaimReport, NativeRuntimeError>,
    ) -> bool {
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
                false
            }
            Err(NativeRuntimeError::WorkspaceChanged) => {
                self.repo = None;
                self.summary = None;
                self.notice = None;
                self.error = Some(NativeRuntimeError::WorkspaceChanged.to_string());
                true
            }
            Err(error) => {
                self.error = Some(error.to_string());
                false
            }
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
            let text = match self
                .repo
                .as_deref()
                .and_then(Path::file_name)
                .and_then(|name| name.to_str())
            {
                Some(name) if !name.is_empty() => {
                    format!("当前工作区（{name}）占用：{used_s} / {limit_s}（共 {refs} 个检查点）")
                }
                _ => format!("当前占用：{used_s} / {limit_s}（共 {refs} 个检查点）"),
            };
            return (text, used > summary.limit_bytes);
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
    refresh_with_options(runtime, state, true, cx);
}

fn refresh_with_options(
    runtime: Option<NativeRuntimeHandle>,
    state: Arc<Mutex<CheckpointSettingsState>>,
    clear_error: bool,
    cx: &mut Context<SettingsWindowView>,
) {
    let Some(runtime) = runtime else {
        if let Ok(mut guard) = state.lock() {
            guard.loading = false;
            guard.unavailable = true;
            guard.repo = None;
            guard.summary = None;
            guard.armed = false;
            if clear_error {
                guard.error = None;
            }
        }
        cx.notify();
        return;
    };
    let serial = if let Ok(mut guard) = state.lock() {
        if guard.cleaning {
            return;
        }
        guard.loading = true;
        guard.armed = false;
        if clear_error {
            guard.error = None;
        }
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
                guard.apply_summary(result, clear_error);
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
            guard.repo = None;
            guard.summary = None;
            guard.unavailable = true;
        }
        cx.notify();
        return;
    };
    let latest_workspace = runtime
        .latest_snapshot()
        .map(|snapshot| snapshot.workspace.as_ref().clone());
    let expected_repo = {
        let Ok(mut guard) = state.lock() else {
            return;
        };
        if guard.cleaning || guard.loading || guard.unavailable {
            return;
        }
        let Some(repo) = guard.repo.clone() else {
            return;
        };
        if latest_workspace
            .as_ref()
            .is_some_and(|workspace| workspace != &repo)
        {
            guard.armed = false;
            guard.repo = None;
            guard.summary = None;
            guard.notice = None;
            guard.error = Some(NativeRuntimeError::WorkspaceChanged.to_string());
            drop(guard);
            refresh_with_options(Some(runtime), state, false, cx);
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
        repo
    };
    cx.notify();
    let runtime_for_retry = runtime.clone();
    let state_for_retry = state.clone();
    let operation = runtime.purge_checkpoint_history(expected_repo);
    cx.spawn(async move |this, cx| {
        let result = operation.await;
        let workspace_changed = if let Ok(mut guard) = state.lock() {
            guard.apply_cleanup(result)
        } else {
            false
        };
        let _ = this.update(cx, |_, cx| {
            if workspace_changed {
                refresh_with_options(Some(runtime_for_retry), state_for_retry, false, cx);
            } else {
                cx.notify();
            }
        });
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
        let clear_disabled = disabled || snapshot.repo.is_none();
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
                            .disabled(clear_disabled)
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
#[path = "settings_checkpoint_tests.rs"]
mod tests;
