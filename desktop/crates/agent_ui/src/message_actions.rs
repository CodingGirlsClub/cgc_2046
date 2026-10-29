//! 双栈共享的消息操作栏与右键菜单（Stage 1b）。
//!
//! 只放纯渲染：按钮/菜单该不该出现由 `message_flow` 决定，动作由调用方以回调
//! 注入（`Box<dyn Fn(&mut App)>`），因此 native（`NativeAgentView`）与 ACP
//! （`RootView`）共用同一套外观、元素 id 规则、aria 标签与 tooltip。
//!
//! 对齐 Zed：默认 40% 透明的 muted 图标按钮，hover 提亮；按钮 22px。

use gpui_kit::component::menu::{PopupMenu, PopupMenuItem};
use gpui_kit::component::tooltip::Tooltip;
use gpui_kit::component::{Icon, Sizable};
use gpui_kit::InteractiveElement as _;
use gpui_kit::StatefulInteractiveElement as _;
use gpui_kit::*;

/// 图标来源：native 用 kit 内置 `IconName`，ACP 用资产路径。
#[derive(Clone)]
pub enum ActionGlyph {
    Named(gpui_kit::assets::IconName),
    Path(SharedString),
}

/// 三个动作的图标；与 `ActionCallbacks` 一一对应。
#[derive(Clone)]
pub struct ActionGlyphs {
    pub copy: ActionGlyph,
    pub user: ActionGlyph,
    pub top: ActionGlyph,
}

/// 操作栏样式（两栈各自从主题 palette 构造，避免 `agent_ui` 依赖 app 主题模块）。
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ActionStyle {
    pub icon_color: Hsla,
    pub hover_bg: Hsla,
    pub button_size: f32,
    pub radius: f32,
    pub gap: f32,
}

/// 菜单/操作栏里注入的动作回调（`App` 足够完成剪贴板写入与实体更新）。
pub type ActionCallback = Box<dyn Fn(&mut App) + 'static>;

/// 操作栏回调；`None` 表示该按钮不渲染。
#[derive(Default)]
pub struct ActionCallbacks {
    pub on_copy: Option<ActionCallback>,
    pub on_scroll_user: Option<ActionCallback>,
    pub on_scroll_top: Option<ActionCallback>,
}

pub struct ActionBarSpec {
    pub row_id: SharedString,
    pub copy_id: SharedString,
    pub user_id: SharedString,
    pub top_id: SharedString,
    pub glyphs: ActionGlyphs,
    pub style: ActionStyle,
    pub callbacks: ActionCallbacks,
}

/// 渲染一组消息操作按钮（Copy / Scroll to User Message / Scroll to Top）。
pub fn render_action_bar(spec: ActionBarSpec) -> AnyElement {
    let ActionBarSpec {
        row_id,
        copy_id,
        user_id,
        top_id,
        glyphs,
        style,
        callbacks,
    } = spec;
    let mut row = div()
        .id(row_id)
        .flex()
        .flex_row()
        .w_full()
        .items_center()
        .justify_end()
        .gap(px(style.gap))
        .opacity(0.4)
        .hover(|style| style.opacity(1.0));
    if let Some(on_copy) = callbacks.on_copy {
        row = row.child(action_button(
            copy_id,
            "Copy This Agent Response",
            &glyphs.copy,
            style,
            on_copy,
        ));
    }
    if let Some(on_scroll_user) = callbacks.on_scroll_user {
        row = row.child(action_button(
            user_id,
            "Scroll to User Message",
            &glyphs.user,
            style,
            on_scroll_user,
        ));
    }
    if let Some(on_scroll_top) = callbacks.on_scroll_top {
        row = row.child(action_button(
            top_id,
            "Scroll to Top",
            &glyphs.top,
            style,
            on_scroll_top,
        ));
    }
    row.into_any_element()
}

fn action_button(
    id: SharedString,
    label: &'static str,
    glyph: &ActionGlyph,
    style: ActionStyle,
    on_click: ActionCallback,
) -> AnyElement {
    let icon = match glyph {
        ActionGlyph::Named(name) => Icon::new(*name).xsmall().into_any_element(),
        ActionGlyph::Path(path) => Icon::default()
            .path(path.clone())
            .small()
            .into_any_element(),
    };
    div()
        .id(id)
        .role(Role::Button)
        .aria_label(label)
        .flex()
        .items_center()
        .justify_center()
        .size(px(style.button_size))
        .rounded(px(style.radius))
        .text_color(style.icon_color)
        .hover(|hovered| hovered.bg(style.hover_bg))
        .child(icon)
        .tooltip(move |window, cx| Tooltip::new(label).build(window, cx))
        .on_click(move |_, _, cx| on_click(cx))
        .into_any_element()
}

/// 右键菜单三种复制载荷（Copy / Copy as Markdown / Copy This Agent Response）。
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct MenuPayloads {
    pub plain: String,
    pub markdown: String,
    pub agent_response: Option<String>,
}

/// 渲染消息右键菜单（复制动作在共享层执行，滚动动作由调用方注入）。
pub fn render_message_menu(
    menu: PopupMenu,
    payloads: MenuPayloads,
    on_scroll_top: ActionCallback,
    on_scroll_bottom: ActionCallback,
) -> PopupMenu {
    let MenuPayloads {
        plain,
        markdown,
        agent_response,
    } = payloads;
    let mut menu = menu
        .item(PopupMenuItem::new("Copy").on_click(move |_, _, cx| {
            cx.write_to_clipboard(ClipboardItem::new_string(plain.clone()));
        }))
        .item(
            PopupMenuItem::new("Copy as Markdown").on_click(move |_, _, cx| {
                cx.write_to_clipboard(ClipboardItem::new_string(markdown.clone()));
            }),
        );
    if let Some(agent_response) = agent_response {
        menu = menu.item(PopupMenuItem::new("Copy This Agent Response").on_click(
            move |_, _, cx| {
                cx.write_to_clipboard(ClipboardItem::new_string(agent_response.clone()));
            },
        ));
    }
    menu.item(PopupMenuItem::separator())
        .item(PopupMenuItem::new("Scroll to Top").on_click(move |_, _, cx| on_scroll_top(cx)))
        .item(PopupMenuItem::new("Scroll to Bottom").on_click(move |_, _, cx| on_scroll_bottom(cx)))
}
