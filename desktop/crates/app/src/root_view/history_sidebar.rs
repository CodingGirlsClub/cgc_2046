//! 全局「历史对话」侧边栏（Stage 3.3b / Zed Threads sidebar 形态）。
//!
//! 参考 XERJ 取证的 Zed 实现：thread history 是侧边栏而非模态框。`sidebar/sidebar.rs`
//! 是 Threads sidebar（可左右停靠、带 filter editor、按 project 分组）；
//! `agent_ui/threads_archive_view.rs` 是 Archive view（bucket separator + filter）；
//! `thread_metadata_store.rs` 的 `sidebar_threads` 表存历史元数据。
//!
//! 本侧栏由 RootView footer 时钟图标开关，native / ACP 两轨共用。主列表由 native
//! 与 ACP 未归档组成（ACP 每 agent 最近 N 条，更早自动归档），按 agent 分组；
//! Archive 视图按 今天/昨天/最近 7 天/更早分桶并支持过滤、Unarchive。行操作只有
//! Rename / Archive（没有逐条永久删除；永久删除只走设置）。

use super::*;
use crate::acp_history::{self, HistoryEntry, RECENT_PER_AGENT};
use gpui_kit::component::button::{Button, ButtonVariants};
use gpui_kit::component::input::{Input, InputState};

mod history_row;

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
pub(in crate::root_view) struct HistorySidebar {
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
    /// 全局历史侧边栏（Zed Threads sidebar 形态）：作为主布局的一列常驻/可切换，
    /// 不是模态框——打开线程时侧栏保持可见并高亮当前行。
    pub(in crate::root_view) fn render_history_sidebar(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let palette = theme::palette_from_theme(cx);
        let Some(sidebar) = self.history_sidebar.as_ref() else {
            return div().into_any_element();
        };
        let tab = sidebar.tab;
        let filter = sidebar.filter.clone();
        if self.chat.history.is_empty() {
            self.chat.history = self.load_unified_history();
        }
        let filter_input = self.ensure_history_filter_input(window, cx);
        let filter_value = filter_input.read(cx).value().to_string();
        if filter_value != filter {
            if let Some(sidebar) = self.history_sidebar.as_mut() {
                sidebar.filter = filter_value.clone();
            }
        }
        let now = acp_history::now_local();
        let main_entries = acp_history::filter_history(
            acp_history::main_list(&self.chat.history, RECENT_PER_AGENT),
            &filter_value,
        );
        let archived_entries =
            acp_history::filter_history(self.chat.history.clone(), &filter_value);
        let mut rows: Vec<AnyElement> = Vec::new();
        match tab {
            HistoryTab::Threads => {
                if main_entries.is_empty() {
                    rows.push(empty_hint(&palette, "暂无历史对话"));
                }
                for (agent, entries) in group_by_agent(&main_entries) {
                    rows.push(section_label(&palette, &agent));
                    for entry in entries {
                        rows.push(self.render_history_row(entry, &now, cx));
                    }
                }
            }
            HistoryTab::Archive => {
                let groups = acp_history::group_archive(&archived_entries, &now);
                if groups.is_empty() {
                    rows.push(empty_hint(&palette, "归档为空"));
                }
                for (bucket, entries) in &groups {
                    rows.push(section_label(&palette, bucket.label()));
                    for entry in entries {
                        rows.push(self.render_history_row(entry, &now, cx));
                    }
                }
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
        let new_root = cx.entity().downgrade();
        div()
            .id("history-sidebar")
            .w(px(260.0))
            .flex_none()
            .h_full()
            .flex()
            .flex_col()
            .gap(space(1))
            .p(space(1))
            .bg(palette.card)
            .border_r_1()
            .border_color(palette.line)
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .justify_between()
                    .child(
                        div()
                            .text_size(px(12.0))
                            .text_color(palette.ink)
                            .child("历史对话"),
                    )
                    .child(
                        div()
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap(px(2.0))
                            .child(
                                div()
                                    .id("history-new-thread")
                                    .role(Role::Button)
                                    .aria_label("新建对话")
                                    .px(space(1))
                                    .py(px(1.0))
                                    .rounded(px(RADIUS_SMALL))
                                    .text_size(px(12.0))
                                    .text_color(palette.ink_3)
                                    .hover(|style| style.bg(palette.soft))
                                    .child("＋")
                                    .on_click(move |_, _, cx| {
                                        let _ = new_root.update(cx, |this, cx| {
                                            this.start_new_thread_from_history(cx);
                                        });
                                    }),
                            )
                            .child(
                                div()
                                    .id("history-sidebar-close")
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
                                        let _ = close_root.update(cx, |this, cx| {
                                            this.close_history_sidebar(cx);
                                        });
                                    }),
                            ),
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
                    .child(div().flex_1()),
            )
            .child(Input::new(&filter_input))
            .child(
                div()
                    .id("history-sidebar-list")
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
            )
            .into_any_element()
    }
}

fn section_label(palette: &theme::Palette, label: &str) -> AnyElement {
    div()
        .w_full()
        .px(space(1))
        .pt(px(4.0))
        .pb(px(1.0))
        .text_size(px(10.0))
        .text_color(palette.ink_3)
        .child(label.to_string())
        .into_any_element()
}

fn empty_hint(palette: &theme::Palette, text: &str) -> AnyElement {
    div()
        .text_size(px(11.0))
        .text_color(palette.ink_3)
        .child(text.to_string())
        .into_any_element()
}

/// 主列表按 agent 分组（Zed sidebar 按项目分组；我们没有多项目，按 agent 轨）。
fn group_by_agent(entries: &[HistoryEntry]) -> Vec<(String, Vec<&HistoryEntry>)> {
    let mut groups: Vec<(String, Vec<&HistoryEntry>)> = Vec::new();
    for entry in entries {
        let agent = entry.agent_label().to_string();
        match groups.iter_mut().find(|(name, _)| *name == agent) {
            Some((_, rows)) => rows.push(entry),
            None => groups.push((agent, vec![entry])),
        }
    }
    groups
}

#[cfg(test)]
mod history_sidebar_tests {
    use crate::acp_history::{HistoryEntry, HistorySource};
    use crate::root_view::history_sidebar::group_by_agent;

    fn entry(thread_id: &str, agent: &str) -> HistoryEntry {
        HistoryEntry {
            thread_id: thread_id.to_string(),
            session_id: Some(thread_id.to_string()),
            agent_id: Some(agent.to_string()),
            title: Some(format!("{agent} {thread_id}")),
            updated_at: "2026-10-26T12:00:00Z".to_string(),
            archived: false,
            source: HistorySource::Acp,
        }
    }

    #[test]
    fn history_sidebar_groups_main_list_by_agent_in_first_seen_order() {
        let entries = vec![
            entry("acp-1", "omp"),
            entry("acp-2", "codex"),
            entry("acp-3", "omp"),
            entry("acp-4", "native"),
        ];
        let groups = group_by_agent(&entries);
        assert_eq!(
            groups
                .iter()
                .map(|(agent, _)| agent.as_str())
                .collect::<Vec<_>>(),
            vec!["omp", "codex", "native"],
            "按 agent 分组（Zed 按项目），组序 = 首次出现顺序"
        );
        assert_eq!(groups[0].1.len(), 2);
        assert_eq!(groups[1].1.len(), 1);
        assert_eq!(
            groups[0]
                .1
                .iter()
                .map(|entry| entry.thread_id.as_str())
                .collect::<Vec<_>>(),
            vec!["acp-1", "acp-3"]
        );
    }
}
