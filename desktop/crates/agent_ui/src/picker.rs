//! 双栈共用的选择器弹层（Stage 1e）。
//!
//! 覆盖 native 的模型/推理强度/审批模式 picker 与 ACP 的 config picker：
//! trigger 按钮、Popover 内容、分组标题、选中/禁用样式、可选的搜索框与滚动条、
//! 关闭行为都只有一份实现。调用方只提供条目数据、样式与 `on_select` 回调。
//!
//! 对齐 Zed：11px 条目、hover soft、选中 accent + ✓；禁用条目 muted 且不可点。

use std::rc::Rc;

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::{Input, InputState};
use gpui_kit::component::popover::Popover;
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::Sizable as _;
use gpui_kit::InteractiveElement as _;
use gpui_kit::StatefulInteractiveElement as _;
use gpui_kit::*;

/// 一个可选条目。
pub struct PickerItem {
    pub id: SharedString,
    pub label: String,
    pub selected: bool,
    pub disabled: bool,
}

impl PickerItem {
    pub fn new(id: impl Into<SharedString>, label: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            label: label.into(),
            selected: false,
            disabled: false,
        }
    }

    pub fn selected(mut self, selected: bool) -> Self {
        self.selected = selected;
        self
    }

    pub fn disabled(mut self, disabled: bool) -> Self {
        self.disabled = disabled;
        self
    }
}

/// 分组（`title = None` 表示不渲染组标题）。
pub struct PickerGroup {
    pub title: Option<String>,
    pub items: Vec<PickerItem>,
}

impl PickerGroup {
    pub fn flat(items: Vec<PickerItem>) -> Self {
        Self { title: None, items }
    }

    pub fn titled(title: impl Into<String>, items: Vec<PickerItem>) -> Self {
        Self {
            title: Some(title.into()),
            items,
        }
    }
}

/// 选择器条目样式（各栈从自己的主题 palette 构造）。
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PickerStyle {
    pub accent: Hsla,
    pub ink_2: Hsla,
    pub ink_3: Hsla,
    pub soft: Hsla,
    pub card: Hsla,
    pub radius: f32,
}

/// 弹层打开回调（用于清空搜索词等）。
pub type OpenCallback = Box<dyn Fn(&mut Window, &mut App) + 'static>;

/// 条目点击回调（扁平下标，组标题不计入）。
pub type SelectCallback = Box<dyn Fn(usize, &mut Window, &mut App) + 'static>;

/// 行内共享的点击回调（每个条目的 on_click 各持一份 Rc）。
type SharedSelectCallback = Rc<dyn Fn(usize, &mut Window, &mut App)>;

/// 可选搜索框（ACP config picker 的 Model 类目用）。
pub struct PickerSearch {
    pub input: Entity<InputState>,
    pub scroll: ScrollHandle,
    /// 弹层打开时回调（用于清空搜索词）。
    pub on_open: Option<OpenCallback>,
}

pub struct PickerPopoverSpec {
    pub popover_id: SharedString,
    pub trigger_id: SharedString,
    pub trigger_label: String,
    pub trigger_tooltip: String,
    pub trigger_max_width: Option<f32>,
    pub anchor: Option<Anchor>,
    pub groups: Vec<PickerGroup>,
    pub style: PickerStyle,
    pub width: f32,
    pub list_max_height: Option<f32>,
    pub search: Option<PickerSearch>,
    /// 被点中条目的扁平下标（组标题不计入）。
    pub on_select: SelectCallback,
}

pub fn render_picker_popover(spec: PickerPopoverSpec) -> AnyElement {
    let PickerPopoverSpec {
        popover_id,
        trigger_id,
        trigger_label,
        trigger_tooltip,
        trigger_max_width,
        anchor,
        groups,
        style,
        width,
        list_max_height,
        search,
        on_select,
    } = spec;

    let mut trigger = Button::new(trigger_id)
        .label(trigger_label)
        .xsmall()
        .ghost()
        .tooltip(trigger_tooltip);
    if let Some(max_width) = trigger_max_width {
        trigger = trigger.max_w(px(max_width));
    }

    let list_id = SharedString::from(format!("{popover_id}-list"));
    let on_select: SharedSelectCallback = Rc::from(on_select);
    let (search_input, search_on_open) = match search {
        Some(PickerSearch {
            input,
            scroll,
            on_open,
        }) => (Some((input, scroll)), on_open),
        None => (None, None),
    };

    let mut popover = Popover::new(popover_id);
    if let Some(anchor) = anchor {
        popover = popover.anchor(anchor);
    }
    popover = popover.trigger(trigger).content(move |_, _, cx| {
        let dismiss = cx.entity().downgrade();
        let (search_entity, search_scroll) = match &search_input {
            Some((input, scroll)) => (Some(input.clone()), Some(scroll.clone())),
            None => (None, None),
        };
        let mut flat = 0usize;
        let mut rows: Vec<AnyElement> = Vec::new();
        for group in &groups {
            if let Some(title) = &group.title {
                rows.push(
                    div()
                        .px(px(8.0))
                        .pt(px(4.0))
                        .pb(px(2.0))
                        .text_size(px(9.0))
                        .text_color(style.ink_3)
                        .child(title.clone())
                        .into_any_element(),
                );
            }
            for item in &group.items {
                let item_index = flat;
                flat += 1;
                let id = item.id.clone();
                let label = item.label.clone();
                let selected = item.selected;
                let disabled = item.disabled;
                let on_select = on_select.clone();
                let row_dismiss = dismiss.clone();
                let mut row = div()
                    .id(id)
                    .role(Role::Button)
                    .aria_label(label.clone())
                    .flex()
                    .flex_row()
                    .items_center()
                    .justify_between()
                    .gap(px(8.0))
                    .px(px(8.0))
                    .py(px(3.0))
                    .rounded(px(style.radius))
                    .text_size(px(11.0))
                    .text_color(if disabled {
                        style.ink_3
                    } else if selected {
                        style.accent
                    } else {
                        style.ink_2
                    })
                    .child(div().truncate().child(label))
                    .children(selected.then_some("✓"));
                if !disabled {
                    row = row.hover(|hovered| hovered.bg(style.soft)).on_click(
                        move |_, window, cx| {
                            on_select(item_index, window, cx);
                            let _ = row_dismiss.update(cx, |state, cx| state.dismiss(window, cx));
                        },
                    );
                }
                rows.push(row.into_any_element());
            }
        }

        let mut list = div()
            .id(list_id.clone())
            .flex()
            .flex_col()
            .gap(px(1.0))
            .occlude()
            .children(rows);
        if let Some(max_height) = list_max_height {
            list = list.max_h(px(max_height));
        }
        if let Some(scroll) = &search_scroll {
            list = list
                .track_scroll(scroll)
                .overflow_y_scroll()
                .vertical_scrollbar(scroll);
        } else if list_max_height.is_some() {
            list = list.overflow_y_scroll();
        }

        div()
            .flex()
            .flex_col()
            .w(px(width))
            .occlude()
            .children(search_entity.map(|input| {
                div()
                    .px(px(8.0))
                    .pb(px(6.0))
                    .mb(px(4.0))
                    .border_b_1()
                    .child(Input::new(&input).small().appearance(false).w_full())
                    .into_any_element()
            }))
            .child(list)
            .into_any_element()
    });
    if let Some(on_open) = search_on_open {
        popover = popover.on_open_change(move |open, window, cx| {
            if *open {
                on_open(window, cx);
            }
        });
    }
    popover.into_any_element()
}

impl PickerStyle {
    /// 两栈共用的默认样式（从各自 palette 覆盖颜色即可）。
    pub fn from_palette(
        accent: Hsla,
        ink_2: Hsla,
        ink_3: Hsla,
        soft: Hsla,
        card: Hsla,
        radius: f32,
    ) -> Self {
        Self {
            accent,
            ink_2,
            ink_3,
            soft,
            card,
            radius,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{PickerGroup, PickerItem};

    #[test]
    fn item_builder_sets_flags_and_group_keeps_order() {
        let group = PickerGroup::titled(
            "Provider A",
            vec![
                PickerItem::new("a-1", "model-1").selected(true),
                PickerItem::new("a-2", "model-2").disabled(true),
            ],
        );
        assert_eq!(group.title.as_deref(), Some("Provider A"));
        assert!(group.items[0].selected);
        assert!(!group.items[0].disabled);
        assert!(group.items[1].disabled);
        let flat = PickerGroup::flat(vec![PickerItem::new("x", "x")]);
        assert!(flat.title.is_none());
    }
}
