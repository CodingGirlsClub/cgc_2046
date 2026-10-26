//! 全局「历史对话」overlay（Stage 3.3b / Zed 式 Thread 历史交互）。
//!
//! 由 RootView footer 的时钟图标打开，native / ACP 两轨共用：主列表 = native +
//! ACP 未归档（ACP 每 agent 最近 N 条，更早自动归档），Archive 视图按
//! 今天/昨天/最近 7 天/更早分桶并支持过滤、Unarchive。
//! 行操作只有 Rename / Archive（Zed 语义，没有逐条永久删除；永久删除只走设置）。

use super::*;
use crate::acp_history::{self, ArchiveBucket, HistoryEntry, HistorySource, RECENT_PER_AGENT};
use gpui_kit::component::button::{Button, ButtonVariants};
use gpui_kit::component::input::{Input, InputState};
use gpui_kit::component::popover::Popover;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(in crate::root_view) enum HistoryTab {
    #[default]
    Threads,
    Archive,
}

impl HistoryTab {
    fn label(self) -> &'static str {
        match self {
            HistoryTab::Threads => "最近",
            HistoryTab::Archive => "归档",
        }
    }
}

#[derive(Default)]
pub(in crate::root_view) struct HistoryOverlay {
    pub tab: HistoryTab,
    pub filter: String,
    pub filter_input: Option<Entity<InputState>>,
    pub filter_subscription: Option<Subscription>,
    pub rename: Option<HistoryRename>,
}

pub(in crate::root_view) struct HistoryRename {
    pub thread_id: String,
    pub input: Entity<InputState>,
}

impl RootView {
    /// 行操作菜单（Rename / Archive 或 Unarchive）。按钮在自己的触发区，
    /// 与行的打开区域是兄弟节点，不依赖冒泡顺序（修 × 误触行打开的问题）。
    #[allow(clippy::too_many_arguments)]
    fn render_history_row_menu(&self, entry: &HistoryEntry, cx: &mut Context<Self>) -> AnyElement {
        let thread_id = entry.thread_id.clone();
        let title = entry.title.clone();
        let source = entry.source;
        let archived = entry.archived;
        let root = cx.entity().downgrade();
        Popover::new(SharedString::from(format!("history-menu-{thread_id}")))
            .anchor(Anchor::BottomRight)
            .trigger(
                Button::new(SharedString::from(format!(
                    "history-menu-trigger-{thread_id}"
                )))
                .label("⋯")
                .xsmall()
                .ghost()
                .tooltip("历史操作"),
            )
            .content(move |_, _window, cx| {
                let palette = theme::palette_from_theme(cx);
                let rename_root = root.clone();
                let rename_title = title.clone();
                let rename_id = thread_id.clone();
                let archive_root = root.clone();
                let archive_id = thread_id.clone();
                let mut items = div().w(px(150.0)).flex().flex_col().gap(px(1.0));
                items = items.child(
                    div()
                        .id(format!("history-rename-{thread_id}"))
                        .role(Role::Button)
                        .flex()
                        .px(space(1))
                        .py(px(3.0))
                        .rounded(px(RADIUS_SMALL))
                        .text_size(px(11.0))
                        .text_color(palette.ink_2)
                        .hover(|style| style.bg(palette.soft))
                        .child("Rename")
                        .on_click(move |_, window, cx| {
                            cx.stop_propagation();
                            let rename_id = rename_id.clone();
                            let rename_title = rename_title.clone();
                            let _ = rename_root.update(cx, |this, cx| {
                                this.begin_history_rename(rename_id, rename_title, window, cx);
                            });
                        }),
                );
                if archived {
                    items = items.child(
                        div()
                            .id(format!("history-unarchive-{thread_id}"))
                            .role(Role::Button)
                            .flex()
                            .px(space(1))
                            .py(px(3.0))
                            .rounded(px(RADIUS_SMALL))
                            .text_size(px(11.0))
                            .text_color(palette.ink_2)
                            .hover(|style| style.bg(palette.soft))
                            .child("Unarchive")
                            .on_click(move |_, _, cx| {
                                cx.stop_propagation();
                                let archive_id = archive_id.clone();
                                let _ = archive_root.update(cx, |this, cx| {
                                    this.unarchive_history_thread(archive_id, cx);
                                });
                            }),
                    );
                } else if source == HistorySource::Acp {
                    items = items.child(
                        div()
                            .id(format!("history-archive-{thread_id}"))
                            .role(Role::Button)
                            .flex()
                            .px(space(1))
                            .py(px(3.0))
                            .rounded(px(RADIUS_SMALL))
                            .text_size(px(11.0))
                            .text_color(palette.ink_2)
                            .hover(|style| style.bg(palette.soft))
                            .child("Archive")
                            .on_click(move |_, _, cx| {
                                cx.stop_propagation();
                                let archive_id = archive_id.clone();
                                let _ = archive_root.update(cx, |this, cx| {
                                    this.archive_history_thread(archive_id, cx);
                                });
                            }),
                    );
                }
                items.into_any_element()
            })
            .into_any_element()
    }

    fn render_history_row(
        &mut self,
        entry: &HistoryEntry,
        now: &chrono::DateTime<chrono::Local>,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let palette = theme::palette_from_theme(cx);
        let thread_id = entry.thread_id.clone();
        let session_id = entry.session_id.clone();
        let source = entry.source;
        let title = entry
            .title
            .clone()
            .filter(|title| !title.trim().is_empty())
            .unwrap_or_else(|| "未命名对话".to_string());
        let agent_label = entry.agent_label().to_string();
        let time_label = acp_history::relative_time_label(&entry.updated_at, now);
        let is_current = match source {
            HistorySource::Acp => entry
                .session_id
                .as_deref()
                .is_some_and(|session| self.chat.session_id.as_deref() == Some(session)),
            HistorySource::Native => self.native_agent_view.as_ref().is_some_and(|view| {
                view.read(cx).current_thread_id().as_deref() == Some(thread_id.as_str())
            }),
        };
        let renaming = self
            .history_overlay
            .as_ref()
            .and_then(|overlay| overlay.rename.as_ref())
            .filter(|rename| rename.thread_id == thread_id)
            .map(|rename| rename.input.clone());
        if let Some(input) = renaming {
            let save_root = cx.entity().downgrade();
            let cancel_root = cx.entity().downgrade();
            return div()
                .id(format!("history-rename-row-{thread_id}"))
                .flex()
                .flex_row()
                .items_center()
                .gap(space(1))
                .px(space(1))
                .py(px(2.0))
                .child(div().flex_1().child(Input::new(&input)))
                .child(
                    Button::new(SharedString::from(format!(
                        "history-rename-save-{thread_id}"
                    )))
                    .label("保存")
                    .xsmall()
                    .on_click(move |_, _, cx| {
                        cx.stop_propagation();
                        let _ = save_root.update(cx, |this, cx| {
                            this.commit_history_rename(cx);
                        });
                    }),
                )
                .child(
                    Button::new(SharedString::from(format!(
                        "history-rename-cancel-{thread_id}"
                    )))
                    .label("取消")
                    .xsmall()
                    .ghost()
                    .on_click(move |_, _, cx| {
                        cx.stop_propagation();
                        let _ = cancel_root.update(cx, |this, cx| {
                            this.cancel_history_rename(cx);
                        });
                    }),
                )
                .into_any_element();
        }
        let open_root = cx.entity().downgrade();
        let open_thread_id = thread_id.clone();
        let open_session_id = session_id.clone();
        let open_source = source;
        let menu = self.render_history_row_menu(entry, cx);
        div()
            .id(format!("history-row-{thread_id}"))
            .flex()
            .flex_row()
            .items_center()
            .gap(space(1))
            .px(space(1))
            .py(px(3.0))
            .rounded(px(RADIUS_SMALL))
            .hover(|style| style.bg(palette.soft))
            .child(
                div()
                    .id(format!("history-open-{thread_id}"))
                    .role(Role::Button)
                    .aria_label(title.clone())
                    .flex_1()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap(space(1))
                    .text_size(px(12.0))
                    .text_color(if is_current {
                        palette.accent
                    } else {
                        palette.ink_2
                    })
                    .child(div().flex_1().child(title))
                    .child(
                        div()
                            .text_size(px(10.0))
                            .text_color(palette.ink_3)
                            .child(format!("{agent_label} · {time_label}")),
                    )
                    .on_click(move |_, window, cx| {
                        cx.stop_propagation();
                        let _ = open_root.update(cx, |this, cx| {
                            this.open_history_entry(
                                open_thread_id.clone(),
                                open_session_id.clone(),
                                open_source,
                                window,
                                cx,
                            );
                        });
                    }),
            )
            .child(menu)
            .into_any_element()
    }

    pub(in crate::root_view) fn render_history_overlay(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let palette = theme::palette_from_theme(cx);
        let Some(overlay) = self.history_overlay.as_ref() else {
            return div().into_any_element();
        };
        let tab = overlay.tab;
        let filter = overlay.filter.clone();
        if self.chat.history.is_empty() {
            self.chat.history = self.load_unified_history();
        }
        let filter_input = self.ensure_history_filter_input(window, cx);
        let filter_value = filter_input.read(cx).value().to_string();
        if filter_value != filter {
            if let Some(overlay) = self.history_overlay.as_mut() {
                overlay.filter = filter_value.clone();
            }
        }
        let now = acp_history::now_local();
        let active_entries = acp_history::filter_history(
            acp_history::main_list(&self.chat.history, RECENT_PER_AGENT),
            &filter_value,
        );
        let archived_entries =
            acp_history::filter_history(self.chat.history.clone(), &filter_value);
        let mut rows: Vec<AnyElement> = Vec::new();
        match tab {
            HistoryTab::Threads => {
                if active_entries.is_empty() {
                    rows.push(
                        div()
                            .text_size(px(11.0))
                            .text_color(palette.ink_3)
                            .child("暂无历史对话")
                            .into_any_element(),
                    );
                }
                for entry in &active_entries {
                    rows.push(self.render_history_row(entry, &now, cx));
                }
            }
            HistoryTab::Archive => {
                let groups = acp_history::group_archive(&archived_entries, &now);
                if groups.is_empty() {
                    rows.push(
                        div()
                            .text_size(px(11.0))
                            .text_color(palette.ink_3)
                            .child("归档为空")
                            .into_any_element(),
                    );
                }
                for (bucket, entries) in &groups {
                    rows.push(
                        div()
                            .px(space(1))
                            .py(px(2.0))
                            .text_size(px(10.0))
                            .text_color(palette.ink_3)
                            .child(bucket.label())
                            .into_any_element(),
                    );
                    for entry in entries {
                        rows.push(self.render_history_row(entry, &now, cx));
                    }
                }
                let _ = ArchiveBucket::Today;
            }
        }
        let tab_button = |id: &'static str,
                          tab_value: HistoryTab,
                          current: HistoryTab,
                          palette: &theme::Palette,
                          cx: &mut Context<Self>| {
            let active = tab_value == current;
            div()
                .id(id)
                .role(Role::Button)
                .aria_label(tab_value.label())
                .px(space(1))
                .py(px(2.0))
                .rounded(px(RADIUS_SMALL))
                .text_size(px(11.0))
                .text_color(if active {
                    palette.accent
                } else {
                    palette.ink_3
                })
                .bg(if active { palette.soft } else { palette.card })
                .hover(|style| style.bg(palette.soft))
                .child(tab_value.label())
                .on_click(cx.listener(move |this, _, _, cx| {
                    this.set_history_tab(tab_value, cx);
                }))
                .into_any_element()
        };
        let threads_tab = tab_button(
            "history-tab-threads",
            HistoryTab::Threads,
            tab,
            &palette,
            cx,
        );
        let archive_tab = tab_button(
            "history-tab-archive",
            HistoryTab::Archive,
            tab,
            &palette,
            cx,
        );
        let close_root = cx.entity().downgrade();
        div()
            .id("history-overlay")
            .absolute()
            .inset_0()
            .occlude()
            .flex()
            .items_center()
            .justify_center()
            .bg(gpui_kit::Rgba {
                r: 0.0,
                g: 0.0,
                b: 0.0,
                a: 0.25,
            })
            .child(
                div()
                    .id("history-overlay-card")
                    .w(px(560.0))
                    .h(px(520.0))
                    .max_h(px(520.0))
                    .flex()
                    .flex_col()
                    .gap(space(1))
                    .p(space(2))
                    .rounded(px(RADIUS_MEDIUM))
                    .border_1()
                    .border_color(palette.line_strong)
                    .bg(palette.card)
                    .child(
                        div()
                            .flex()
                            .flex_row()
                            .items_center()
                            .justify_between()
                            .child(
                                div()
                                    .text_size(px(13.0))
                                    .text_color(palette.ink)
                                    .child("历史对话"),
                            )
                            .child(
                                div()
                                    .id("history-overlay-close")
                                    .role(Role::Button)
                                    .aria_label("关闭历史")
                                    .size(px(20.0))
                                    .flex()
                                    .items_center()
                                    .justify_center()
                                    .rounded(px(RADIUS_SMALL))
                                    .text_color(palette.ink_3)
                                    .hover(|style| style.bg(palette.soft))
                                    .child("×")
                                    .on_click(move |_, _, cx| {
                                        cx.stop_propagation();
                                        let _ = close_root.update(cx, |this, cx| {
                                            this.close_history_overlay(cx);
                                        });
                                    }),
                            ),
                    )
                    .child(
                        div()
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap(space(1))
                            .child(threads_tab)
                            .child(archive_tab)
                            .child(div().flex_1().child(Input::new(&filter_input))),
                    )
                    .child(
                        div()
                            .id("history-overlay-list")
                            .flex_1()
                            .min_h(px(0.0))
                            .overflow_y_scroll()
                            .flex()
                            .flex_col()
                            .gap(px(1.0))
                            .children(rows),
                    )
                    .child(
                        div()
                            .text_size(px(10.0))
                            .text_color(palette.ink_3)
                            .child("Archive 仅隐藏条目；永久删除请到设置「清空 ACP 对话历史」。"),
                    ),
            )
            .into_any_element()
    }
}
