//! composer 内的 mention chip 渲染（B4b-b'3：从 native 视图抽出的 app 组件）。

use gpui_kit::component::input::InlineTokenContext;
use gpui_kit::component::tooltip::Tooltip;
use gpui_kit::component::{Icon, Sizable};
use gpui_kit::*;

use crate::mention::Mention;
use crate::theme::RADIUS_SMALL;

pub(crate) fn render_mention_chip(
    context: &InlineTokenContext,
    palette: crate::theme::Palette,
    workspace: &std::path::Path,
) -> AnyElement {
    let mention = Mention::parse_token_id(context.token().id());
    let (icon, label, tooltip) = match mention {
        Some(mention) => (
            mention.chip_icon_path(),
            mention.chip_label(),
            mention.tooltip(workspace),
        ),
        None => (
            gpui_kit::assets::IconName::Bot.path(),
            context.token().label().to_string(),
            context.token().text().to_string(),
        ),
    };
    let selected = context.is_selected();
    div()
        .id(SharedString::from(format!(
            "native-mention-chip-{}-{}",
            context.token().id(),
            context.range().start
        )))
        .flex()
        .flex_row()
        .items_center()
        .gap(px(2.0))
        .h(context.line_height())
        .max_w(context.available_width())
        .px(px(4.0))
        .rounded(px(RADIUS_SMALL))
        .bg(if selected {
            palette.accent
        } else {
            palette.soft
        })
        .text_color(if selected {
            palette.canvas
        } else {
            palette.ink_2
        })
        .text_size(px(11.0))
        .child(Icon::default().path(icon).small())
        .child(div().truncate().child(label))
        .tooltip(move |window, cx| Tooltip::new(tooltip.clone()).build(window, cx))
        .into_any_element()
}
