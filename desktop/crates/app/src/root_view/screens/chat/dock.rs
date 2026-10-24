use super::super::super::*;
use super::super::ScreenContext;

pub(in crate::root_view) fn render_agent_panel(
    ctx: &mut ScreenContext<'_>,
    language: Language,
    palette: &theme::Palette,
    window: &mut Window,
    cx: &mut Context<RootView>,
) -> AnyElement {
    super::agent_panel::render_agent_panel(ctx, language, palette, window, cx)
}
