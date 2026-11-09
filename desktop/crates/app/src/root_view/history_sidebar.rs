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
use gpui_kit::component::button::{Button, ButtonVariants, Toggle, ToggleGroup};
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
        side: crate::preferences::PanelSide,
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
        let tabs = ToggleGroup::new("history-tabs")
            .segmented()
            .xsmall()
            .child(
                Toggle::new("history-tab-threads")
                    .label(HistoryTab::Threads.label())
                    .checked(tab == HistoryTab::Threads),
            )
            .child(
                Toggle::new("history-tab-archive")
                    .label(HistoryTab::Archive.label())
                    .checked(tab == HistoryTab::Archive),
            )
            .on_click(cx.listener(move |this, checks: &Vec<bool>, _, cx| {
                // 组内回调给的是「翻转后的全量状态」，未做互斥；选中那个与当前
                // tab 不同的真值才算用户真的点了它。
                if checks.get(1).copied() == Some(true) && tab != HistoryTab::Archive {
                    this.set_history_tab(HistoryTab::Archive, cx);
                } else if checks.first().copied() == Some(true) && tab != HistoryTab::Threads {
                    this.set_history_tab(HistoryTab::Threads, cx);
                }
            }));
        let close_root = cx.entity().downgrade();
        let new_root = cx.entity().downgrade();
        let mut panel = div()
            .id("history-sidebar")
            .w(px(260.0))
            .flex_none()
            .h_full()
            .flex()
            .flex_col()
            .gap(space(1))
            .p(space(1))
            .bg(palette.card);
        panel = if side == crate::preferences::PanelSide::Left {
            panel.border_r_1()
        } else {
            panel.border_l_1()
        };
        panel
            .border_color(palette.line)
            .child(
                div()
                    .id("history-header")
                    .role(Role::Toolbar)
                    .aria_label("历史对话")
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
                                Button::new("history-new-thread")
                                    .icon(
                                        Icon::default()
                                            .path(AssetIcon::Plus.path())
                                            .text_color(palette.ink_3),
                                    )
                                    .xsmall()
                                    .ghost()
                                    .accessibility_label("新建对话（当前 Agent）")
                                    .tooltip("新建对话（当前 Agent）")
                                    .on_click(move |_, _, cx| {
                                        let _ = new_root.update(cx, |this, cx| {
                                            this.start_new_thread_from_history(cx);
                                        });
                                    }),
                            )
                            .child(
                                Button::new("history-sidebar-close")
                                    .label("×")
                                    .xsmall()
                                    .ghost()
                                    .accessibility_label("关闭历史")
                                    .tooltip("关闭历史")
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
                    .child(tabs)
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
            working_directory: None,
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
