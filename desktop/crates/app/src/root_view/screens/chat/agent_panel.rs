//! Agent Panel 外壳。
//!
//! 对齐 Zed：header（标题/＋/⋯）与内容视图分离，native agent 与 ACP agent
//! 都作为 Agent Panel 的内容接入。Phase 1 仅做结构收敛，行为保持不变。

use super::super::super::*;
use super::super::ScreenContext;

pub(in crate::root_view) fn render_agent_panel(
    ctx: &mut ScreenContext<'_>,
    language: Language,
    palette: &theme::Palette,
    window: &mut Window,
    cx: &mut Context<RootView>,
) -> AnyElement {
    let learning = ctx
        .current
        .as_ref()
        .is_some_and(|route_match| route_match.route.id == "courses.learning");
    if ctx.native_chat_mode && RootView::native_agent_enabled() {
        if ctx.native_agent_view.is_none() {
            let view = cx.new(|cx| crate::native_agent_view::NativeAgentView::new(window, cx));
            ctx.native_agent_view = Some(view);
        }
        let view = ctx.native_agent_view.clone().expect("native agent view");
        return div()
            .id("agent-panel-dock")
            .w(px(ctx.agent_panel_width))
            .flex_none()
            .h_full()
            .flex()
            .flex_col()
            .p(space(2))
            .border_r_1()
            .border_color(palette.line)
            .bg(palette.canvas)
            .child(div().flex_1().min_h(px(0.0)).child(view))
            .into_any_element();
    }
    div()
        .id("agent-panel-dock")
        .w(px(ctx.agent_panel_width))
        .flex_none()
        .h_full()
        .p(space(2))
        .border_r_1()
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
