//! 历史侧栏的单行渲染（Zed 形态：两行正文 + hover 出现的铅笔/归档图标）。

use super::*;
use crate::acp_history::{HistoryEntry, HistorySource};

/// 行操作（hover 时出现的图标按钮；没有逐条永久删除）。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(in crate::root_view) struct HistoryRowActions {
    pub rename: bool,
    pub archive: bool,
    pub unarchive: bool,
}

/// native 无 archived 列，只能 Rename；ACP 主列表可 Archive，归档列表可 Unarchive。
pub(in crate::root_view) fn history_row_actions(entry: &HistoryEntry) -> HistoryRowActions {
    HistoryRowActions {
        rename: true,
        archive: !entry.archived && entry.source == HistorySource::Acp,
        unarchive: entry.archived,
    }
}

/// 行首 agent 图标（与 agent panel 的映射保持一致）。
pub(in crate::root_view) fn history_agent_icon(agent_label: &str) -> SharedString {
    match agent_label {
        "native" => AssetIcon::Bot.path(),
        other => crate::root_view::screens::agent_icon_path(other),
    }
}

impl RootView {
    /// 历史行（Zed 侧栏形态）：两行布局（agent 图标 + 标题 / agent · 相对时间），
    /// hover 时右侧出现铅笔（重命名）与归档/取消归档图标按钮。
    pub(in crate::root_view) fn render_history_row(
        &mut self,
        entry: &HistoryEntry,
        now: &chrono::DateTime<chrono::Local>,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let palette = theme::palette_from_theme(cx);
        let thread_id = entry.thread_id.clone();
        let session_id = entry.session_id.clone();
        let source = entry.source;
        let actions = history_row_actions(entry);
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
            .history_sidebar
            .as_ref()
            .and_then(|sidebar| sidebar.rename.as_ref())
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

        let group_name = SharedString::from(format!("history-row-{thread_id}"));
        let icon_path = history_agent_icon(&agent_label);
        let open_root = cx.entity().downgrade();
        let open_thread_id = thread_id.clone();
        let open_session_id = session_id.clone();
        let open_source = source;
        let open_area = div()
            .id(format!("history-open-{thread_id}"))
            .role(Role::Button)
            .aria_label(title.clone())
            .flex_1()
            .min_w(px(0.0))
            .flex()
            .flex_row()
            .items_center()
            .gap(space(1))
            .child(
                div()
                    .flex_none()
                    .text_color(palette.ink_3)
                    .child(Icon::default().path(icon_path).small()),
            )
            .child(
                div()
                    .flex_1()
                    .min_w(px(0.0))
                    .flex()
                    .flex_col()
                    .gap(px(1.0))
                    .child(
                        div()
                            .text_size(px(12.0))
                            .text_color(if is_current {
                                palette.accent
                            } else {
                                palette.ink_2
                            })
                            .child(title.clone()),
                    )
                    .child(
                        div()
                            .text_size(px(10.0))
                            .text_color(palette.ink_3)
                            .child(format!("{agent_label} · {time_label}")),
                    ),
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
            });

        let mut action_buttons: Vec<AnyElement> = Vec::new();
        if actions.rename {
            let rename_root = cx.entity().downgrade();
            let rename_id = thread_id.clone();
            let rename_title = entry.title.clone();
            let group = group_name.clone();
            action_buttons.push(
                div()
                    .id(format!("history-rename-icon-{thread_id}"))
                    .role(Role::Button)
                    .aria_label("重命名")
                    .size(px(18.0))
                    .flex()
                    .items_center()
                    .justify_center()
                    .rounded(px(RADIUS_SMALL))
                    .text_color(palette.ink_3)
                    .invisible()
                    .group_hover(group, |style| style.visible())
                    .hover(|style| style.bg(palette.card))
                    .child(Icon::default().path(AssetIcon::Pencil.path()).small())
                    .tooltip(move |window, cx| Tooltip::new("重命名").build(window, cx))
                    .on_click(move |_, window, cx| {
                        cx.stop_propagation();
                        let rename_id = rename_id.clone();
                        let rename_title = rename_title.clone();
                        let _ = rename_root.update(cx, |this, cx| {
                            this.begin_history_rename(rename_id, rename_title, window, cx);
                        });
                    })
                    .into_any_element(),
            );
        }
        if actions.archive {
            let archive_root = cx.entity().downgrade();
            let archive_id = thread_id.clone();
            let group = group_name.clone();
            action_buttons.push(
                div()
                    .id(format!("history-archive-icon-{thread_id}"))
                    .role(Role::Button)
                    .aria_label("归档")
                    .size(px(18.0))
                    .flex()
                    .items_center()
                    .justify_center()
                    .rounded(px(RADIUS_SMALL))
                    .text_color(palette.ink_3)
                    .invisible()
                    .group_hover(group, |style| style.visible())
                    .hover(|style| style.bg(palette.card))
                    .child(Icon::default().path(AssetIcon::Archive.path()).small())
                    .tooltip(move |window, cx| Tooltip::new("归档").build(window, cx))
                    .on_click(move |_, _, cx| {
                        cx.stop_propagation();
                        let archive_id = archive_id.clone();
                        let _ = archive_root.update(cx, |this, cx| {
                            this.archive_history_thread(archive_id, cx);
                        });
                    })
                    .into_any_element(),
            );
        }
        if actions.unarchive {
            let unarchive_root = cx.entity().downgrade();
            let unarchive_id = thread_id.clone();
            let group = group_name.clone();
            action_buttons.push(
                div()
                    .id(format!("history-unarchive-icon-{thread_id}"))
                    .role(Role::Button)
                    .aria_label("取消归档")
                    .size(px(18.0))
                    .flex()
                    .items_center()
                    .justify_center()
                    .rounded(px(RADIUS_SMALL))
                    .text_color(palette.ink_3)
                    .invisible()
                    .group_hover(group, |style| style.visible())
                    .hover(|style| style.bg(palette.card))
                    .child(
                        Icon::default()
                            .path(AssetIcon::ArchiveRestore.path())
                            .small(),
                    )
                    .tooltip(move |window, cx| Tooltip::new("取消归档").build(window, cx))
                    .on_click(move |_, _, cx| {
                        cx.stop_propagation();
                        let unarchive_id = unarchive_id.clone();
                        let _ = unarchive_root.update(cx, |this, cx| {
                            this.unarchive_history_thread(unarchive_id, cx);
                        });
                    })
                    .into_any_element(),
            );
        }

        let mut row = div()
            .id(format!("history-row-{thread_id}"))
            .group(group_name)
            .flex()
            .flex_row()
            .items_center()
            .gap(px(2.0))
            .px(space(1))
            .py(px(3.0))
            .rounded(px(RADIUS_SMALL))
            .hover(|style| style.bg(palette.soft))
            .child(open_area)
            .children(action_buttons);
        if is_current {
            row = row.bg(palette.soft);
        }
        row.into_any_element()
    }
}

#[cfg(test)]
mod history_row_tests {
    use crate::acp_history::{HistoryEntry, HistorySource};
    use crate::root_view::history_sidebar::history_row::{history_agent_icon, history_row_actions};
    use gpui_kit::assets::IconName as AssetIcon;

    fn entry(source: HistorySource, archived: bool) -> HistoryEntry {
        HistoryEntry {
            thread_id: "acp-1".to_string(),
            session_id: Some("sess-1".to_string()),
            agent_id: Some("omp".to_string()),
            title: Some("t".to_string()),
            updated_at: "2026-10-26T12:00:00Z".to_string(),
            archived,
            source,
        }
    }

    #[test]
    fn hover_actions_follow_zed_semantics() {
        let active_acp = history_row_actions(&entry(HistorySource::Acp, false));
        assert!(active_acp.rename && active_acp.archive && !active_acp.unarchive);
        let archived_acp = history_row_actions(&entry(HistorySource::Acp, true));
        assert!(archived_acp.rename && !archived_acp.archive && archived_acp.unarchive);
        let native = history_row_actions(&entry(HistorySource::Native, false));
        assert!(
            native.rename && !native.archive && !native.unarchive,
            "native 无 archived 列"
        );
    }

    #[test]
    fn agent_icon_maps_native_and_external_agents() {
        assert_eq!(history_agent_icon("native"), AssetIcon::Bot.path());
        assert_eq!(
            history_agent_icon("codex"),
            AssetIcon::SquareTerminal.path(),
            "与 agent panel 的 agent_icon_path 同映射"
        );
    }
}
