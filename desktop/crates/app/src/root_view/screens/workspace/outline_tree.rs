//! 课程 Outline 的 Tree 投影：把 `CourseOutline` 映射成 gpui-kit 树节点。
//!
//! 节点 id 形如 `chapter:{course}:{id}` / `issue:{course}:{id}`（无章节 id 时
//! 用序号兜底）；展开态按这些稳定 id 持久化，不依赖列表下标，也不会在
//! 切换课程时串用同名章节。树行只显示标题（章节带两位序号），目标/进度
//! 留在卡片与面板 header。

use super::super::super::*;
use super::super::ScreenContext;
use cgc_courses::outline::CourseOutline;
use gpui_kit::component::list::ListItem;
use gpui_kit::component::tree::{tree, TreeEvent, TreeItem, TreeState};
use gpui_kit::prelude::FluentBuilder;
use std::collections::BTreeSet;

fn chapter_node_id(course_id: &str, chapter_id: Option<&str>, index: usize) -> String {
    match chapter_id.filter(|id| !id.trim().is_empty()) {
        Some(id) => format!("chapter:{course_id}:{id}"),
        None => format!("chapter:{course_id}:#{index}"),
    }
}

pub(in crate::root_view) fn issue_node_id(course_id: &str, issue_id: &str) -> String {
    format!("issue:{course_id}:{issue_id}")
}

fn ungrouped_node_id(course_id: &str) -> String {
    format!("ungrouped:{course_id}")
}

/// 纯投影：章节与单元按 outline 顺序展平为树节点。
///
/// 节点 id 带课程 id：同一份 workspace 状态里切换课程时，`ch-1` 这类
/// 重复的章节 id 不会共享展开态。
pub(in crate::root_view) fn outline_items(
    outline: &CourseOutline,
    course_id: &str,
    expanded: &BTreeSet<String>,
    ungrouped_label: &str,
) -> Vec<TreeItem> {
    let mut items = Vec::with_capacity(outline.chapters.len() + 1);
    for (index, chapter) in outline.chapters.iter().enumerate() {
        let id = chapter_node_id(course_id, chapter.id.as_deref(), index);
        let label = format!("{:02}  {}", index + 1, chapter.title);
        let children = chapter
            .issues
            .iter()
            .map(|issue| TreeItem::new(issue_node_id(course_id, &issue.id), issue.title.clone()))
            .collect::<Vec<_>>();
        items.push(
            TreeItem::new(id.clone(), label)
                .expanded(expanded.contains(&id))
                .children(children),
        );
    }
    if !outline.ungrouped.is_empty() {
        let id = ungrouped_node_id(course_id);
        let children = outline
            .ungrouped
            .iter()
            .map(|issue| TreeItem::new(issue_node_id(course_id, &issue.id), issue.title.clone()))
            .collect::<Vec<_>>();
        items.push(
            TreeItem::new(id.clone(), ungrouped_label.to_string())
                .expanded(expanded.contains(&id))
                .children(children),
        );
    }
    items
}

/// 惰性创建 TreeState 并同步 items；展开态变化写回 `outline_expanded`。
pub(in crate::root_view) fn render_outline_tree(
    ctx: &mut ScreenContext<'_>,
    outline: &CourseOutline,
    key: (String, Option<i64>),
    active_issue: Option<&str>,
    ungrouped_label: &str,
    palette: &theme::Palette,
    cx: &mut Context<RootView>,
) -> AnyElement {
    let course_id_owned = key.0.clone();
    let course_id = course_id_owned.as_str();
    let tree_state = match ctx.outline_tree.clone() {
        Some(state) => state,
        None => {
            let state = cx.new(|cx| TreeState::new(cx));
            let subscription = cx.subscribe(&state, |this, _, event: &TreeEvent, cx| {
                match event {
                    TreeEvent::Expanded(id) => {
                        this.outline_expanded.insert(id.to_string());
                    }
                    TreeEvent::Collapsed(id) => {
                        this.outline_expanded.remove(id.as_ref());
                    }
                }
                this.persist_current_workspace_state();
                cx.notify();
            });
            ctx.outline_tree = Some(state.clone());
            ctx.outline_tree_subscription = Some(subscription);
            state
        }
    };

    let key_is_same = ctx.outline_tree_key.as_ref() == Some(&key);
    if !key_is_same {
        let items = outline_items(outline, course_id, &ctx.outline_expanded, ungrouped_label);
        tree_state.update(cx, |state, cx| {
            state.set_items(items, cx);
            if let Some(issue_id) = active_issue {
                state.reveal_item(
                    &SharedString::from(issue_node_id(course_id, issue_id)),
                    gpui_kit::ScrollStrategy::Center,
                    cx,
                );
            }
        });
        ctx.outline_tree_key = Some(key);
    }

    let root = cx.entity().downgrade();
    let active_issue = active_issue.map(str::to_string);
    let course_id = course_id.to_string();
    let issue_prefix = format!("issue:{course_id}:");
    let active_node_id = active_issue
        .as_deref()
        .map(|issue_id| issue_node_id(&course_id, issue_id));
    let ink = palette.ink;
    let ink_2 = palette.ink_2;
    let ink_3 = palette.ink_3;
    let accent = palette.accent;

    tree(&tree_state, move |_ix, entry, _selected, _window, _cx| {
        let node_id = entry.item().id.clone();
        let label = entry.item().label.clone();
        let depth = entry.depth();
        let is_chapter = node_id.starts_with("chapter:") || node_id.starts_with("ungrouped:");
        let is_active = !is_chapter
            && active_node_id
                .as_deref()
                .is_some_and(|active_id| node_id.as_ref() == active_id);

        let row = if is_chapter {
            div()
                .flex()
                .flex_row()
                .items_center()
                .w_full()
                .gap(px(6.0))
                .child(
                    Icon::default()
                        .path(if entry.is_expanded() {
                            AssetIcon::ChevronDown.path()
                        } else {
                            AssetIcon::ChevronRight.path()
                        })
                        .text_color(ink_3)
                        .small(),
                )
                .child(
                    div()
                        .flex_1()
                        .min_w(px(0.0))
                        .truncate()
                        .text_size(px(11.0))
                        .text_color(if entry.is_expanded() { ink } else { ink_2 })
                        .child(label),
                )
                .into_any_element()
        } else {
            div()
                .w_full()
                .min_w(px(0.0))
                .truncate()
                .text_size(px(12.0))
                .text_color(if is_active { ink } else { ink_2 })
                .child(label)
                .into_any_element()
        };

        let item = ListItem::new(SharedString::from(format!("outline-node-{node_id}")))
            .h(px(28.0))
            .pl(px(8.0) + px(14.0) * depth as f32)
            .selected(is_active)
            .when(is_active, |this| this.border_l_2().border_color(accent))
            .child(row);

        if is_chapter {
            return item;
        }
        let issue_id = node_id
            .strip_prefix(&issue_prefix)
            .map(str::to_string)
            .unwrap_or_default();
        let title = entry.item().label.clone();
        let course_id = course_id.clone();
        let root = root.clone();
        item.on_click(move |_, _, cx| {
            let _ = root.update(cx, |this, cx| {
                this.open_issue_tab(&course_id, &issue_id, title.clone(), cx);
            });
        })
    })
    .into_any_element()
}

#[cfg(test)]
mod tests {
    use super::outline_items;
    use cgc_courses::outline::{CourseOutline, OutlineChapter, OutlineIssue};
    use std::collections::BTreeSet;

    fn issue(id: &str) -> OutlineIssue {
        OutlineIssue {
            id: id.to_string(),
            title: format!("单元 {id}"),
            kind: None,
            goal: None,
            chapter_id: None,
        }
    }

    fn outline() -> CourseOutline {
        CourseOutline {
            chapters: vec![OutlineChapter {
                id: Some("ch-1".into()),
                title: "走进物理世界".into(),
                issues: vec![issue("a"), issue("b")],
            }],
            ungrouped: vec![issue("c")],
        }
    }

    #[test]
    fn chapters_keep_stable_ids_and_two_digit_order() {
        let items = outline_items(&outline(), "crs-1", &BTreeSet::new(), "未分组");
        assert_eq!(items.len(), 2);
        assert_eq!(items[0].id.as_ref(), "chapter:crs-1:ch-1");
        assert_eq!(items[0].label.as_ref(), "01  走进物理世界");
        assert_eq!(items[0].children.len(), 2);
        assert_eq!(items[0].children[0].id.as_ref(), "issue:crs-1:a");
        assert_eq!(items[1].id.as_ref(), "ungrouped:crs-1");
        assert_eq!(items[1].children[0].id.as_ref(), "issue:crs-1:c");
    }

    #[test]
    fn expanded_set_survives_rebuild_by_business_id() {
        let expanded = BTreeSet::from([
            "chapter:crs-1:ch-1".to_string(),
            "ungrouped:crs-1".to_string(),
        ]);
        let items = outline_items(&outline(), "crs-1", &expanded, "未分组");
        assert!(items[0].is_expanded());
        assert!(items[1].is_expanded());
    }

    #[test]
    fn chapter_without_id_still_gets_a_distinct_node() {
        let mut outline = outline();
        outline.chapters[0].id = None;
        let items = outline_items(&outline, "crs-1", &BTreeSet::new(), "未分组");
        assert_eq!(items[0].id.as_ref(), "chapter:crs-1:#0");
    }

    #[test]
    fn expansion_is_scoped_to_the_course() {
        let expanded = BTreeSet::from(["chapter:crs-1:ch-1".to_string()]);
        let other = outline_items(&outline(), "crs-2", &expanded, "未分组");
        assert!(!other[0].is_expanded());
    }
}
