use super::super::super::*;
use super::super::ScreenContext;

pub(in crate::root_view) fn render_agent_panel(
    ctx: &mut ScreenContext<'_>,
    language: Language,
    palette: &theme::Palette,
    cx: &mut Context<RootView>,
) -> AnyElement {
    let learning = ctx
        .current
        .as_ref()
        .is_some_and(|route_match| route_match.route.id == "courses.learning");
    div()
        .id("agent-panel-dock")
        .w(px(440.0))
        .flex_none()
        .h_full()
        .p(space(2))
        .border_l_1()
        .border_color(palette.line)
        .bg(palette.canvas)
        .child(if learning {
            super::panel::render_chat_panel(ctx, language, palette, cx)
        } else {
            div()
                .flex()
                .flex_col()
                .gap(space(2))
                .text_size(px(12.0))
                .text_color(palette.ink_3)
                .child(translate(language, Key::AgentChatPanelTitle))
                .child(translate(language, Key::CoursesLearningContextRequired))
                .into_any_element()
        })
        .into_any_element()
}
