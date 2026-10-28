//! 双栈共用的 slash 命令菜单（Stage 1f）。
//!
//! native 的 composer 命令菜单与 ACP 的命令面板此前各自拼行：分组标题、选中
//! 样式、label/description/scope 布局、hover 更新选中、点击回调都是两份实现。
//! 这里收成一份；调用方只提供条目数据、样式与回调。
//!
//! 与 Zed 对齐：分组标题 9px muted；条目 11px，选中用 accent 背景或 accent 文本
//! （由各栈 style 决定）；hover 先更新选中再点击。

use gpui_kit::InteractiveElement as _;
use gpui_kit::StatefulInteractiveElement as _;
use gpui_kit::*;

/// 一个命令条目。
pub struct CommandMenuItem {
    pub id: SharedString,
    pub label: String,
    pub description: String,
    pub scope: Option<String>,
    pub group: String,
    pub selected: bool,
}

/// 菜单样式（各栈从自己的主题 palette 构造）。
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CommandMenuStyle {
    pub card: Hsla,
    pub line: Hsla,
    pub soft: Hsla,
    pub accent: Hsla,
    pub canvas: Hsla,
    pub ink: Hsla,
    pub ink_2: Hsla,
    pub ink_3: Hsla,
    pub selected_bg: Hsla,
    pub selected_text: Hsla,
    pub radius: f32,
    pub padding: f32,
}

/// hover 时回调（native 用来同步 `slash_index`）。
pub type HoverCallback = Box<dyn Fn(usize, &mut App) + 'static>;
/// 点击回调（条目扁平下标）。
pub type ClickCallback = Box<dyn Fn(usize, &mut Window, &mut App) + 'static>;

/// 行内共享的点击回调（每个条目各持一份 Rc）。
type SharedClick = std::rc::Rc<dyn Fn(usize, &mut Window, &mut App)>;
/// 行内共享的 hover 回调。
type SharedHover = std::rc::Rc<dyn Fn(usize, &mut App)>;

pub struct CommandMenuSpec {
    pub menu_id: SharedString,
    pub items: Vec<CommandMenuItem>,
    pub style: CommandMenuStyle,
    /// label 列宽（native 150 / ACP 170）。
    pub label_width: f32,
    /// `Some` 时固定菜单宽度；`None` 由父容器决定（ACP 跟随输入框）。
    pub width: Option<f32>,
    pub max_height: f32,
    /// ACP 固定行高 24；native 由内容撑开。
    pub row_height: Option<f32>,
    pub on_hover: Option<HoverCallback>,
    pub on_click: ClickCallback,
}

pub fn render_command_menu(spec: CommandMenuSpec) -> AnyElement {
    let CommandMenuSpec {
        menu_id,
        items,
        style,
        label_width,
        width,
        max_height,
        row_height,
        on_hover,
        on_click,
    } = spec;
    let on_click: SharedClick = std::rc::Rc::from(on_click);
    let on_hover: Option<SharedHover> = on_hover.map(std::rc::Rc::from);
    let mut rows: Vec<AnyElement> = Vec::new();
    let mut last_group: Option<&str> = None;
    for (index, item) in items.iter().enumerate() {
        if last_group != Some(item.group.as_str()) {
            last_group = Some(item.group.as_str());
            rows.push(
                div()
                    .px(px(8.0))
                    .pt(px(4.0))
                    .pb(px(2.0))
                    .text_size(px(9.0))
                    .text_color(style.ink_3)
                    .child(item.group.clone())
                    .into_any_element(),
            );
        }
        let selected = item.selected;
        let mut row = div()
            .id(item.id.clone())
            .role(Role::Button)
            .aria_label(item.description.clone())
            .flex()
            .flex_row()
            .items_center()
            .gap(px(8.0))
            .px(px(8.0))
            .py(px(3.0))
            .rounded(px(style.radius))
            .text_size(px(11.0))
            .text_color(if selected {
                style.selected_text
            } else {
                style.ink
            })
            .bg(if selected {
                style.selected_bg
            } else {
                style.card
            })
            .child(
                div()
                    .w(px(label_width))
                    .flex_shrink_0()
                    .truncate()
                    .child(item.label.clone()),
            )
            .children(item.scope.clone().map(|scope| {
                div()
                    .text_size(px(9.0))
                    .text_color(style.ink_3)
                    .child(scope)
            }))
            .child(
                div()
                    .flex_1()
                    .min_w(px(0.0))
                    .truncate()
                    .text_size(px(10.0))
                    .text_color(if selected {
                        style.selected_text
                    } else {
                        style.ink_3
                    })
                    .child(item.description.clone()),
            );
        if let Some(height) = row_height {
            row = row.h(px(height));
        }
        row = row.hover(|hovered| {
            hovered.bg(if selected {
                style.selected_bg
            } else {
                style.soft
            })
        });
        if let Some(on_hover) = on_hover.clone() {
            row = row.on_hover(move |hovered: &bool, _, cx| {
                if *hovered {
                    on_hover(index, cx);
                }
            });
        }
        let on_click = on_click.clone();
        rows.push(
            row.on_click(move |_, window, cx| on_click(index, window, cx))
                .into_any_element(),
        );
    }

    let mut menu = div()
        .id(menu_id)
        .flex()
        .flex_col()
        .gap(px(1.0))
        .p(px(style.padding))
        .rounded(px(style.radius))
        .border_1()
        .border_color(style.line)
        .bg(style.card)
        .occlude()
        .max_h(px(max_height))
        .overflow_y_scroll()
        .children(rows);
    if let Some(width) = width {
        menu = menu.w(px(width));
    }
    menu.into_any_element()
}

#[cfg(test)]
mod tests {
    use super::{CommandMenuItem, CommandMenuStyle};

    #[test]
    fn menu_item_carries_group_and_selection() {
        let item = CommandMenuItem {
            id: "cmd".into(),
            label: "/review".to_string(),
            description: "review changes".to_string(),
            scope: Some("workspace".to_string()),
            group: "Commands".to_string(),
            selected: true,
        };
        assert!(item.selected);
        assert_eq!(item.group, "Commands");
    }

    #[test]
    fn style_is_copy() {
        let style = CommandMenuStyle {
            card: gpui_kit::Hsla::default(),
            line: gpui_kit::Hsla::default(),
            soft: gpui_kit::Hsla::default(),
            accent: gpui_kit::Hsla::default(),
            canvas: gpui_kit::Hsla::default(),
            ink: gpui_kit::Hsla::default(),
            ink_2: gpui_kit::Hsla::default(),
            ink_3: gpui_kit::Hsla::default(),
            selected_bg: gpui_kit::Hsla::default(),
            selected_text: gpui_kit::Hsla::default(),
            radius: 4.0,
            padding: 4.0,
        };
        let copied = style;
        assert_eq!(copied.radius, 4.0);
    }
}
