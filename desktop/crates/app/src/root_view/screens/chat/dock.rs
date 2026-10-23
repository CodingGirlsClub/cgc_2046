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
            .child(
                div()
                    .flex()
                    .items_center()
                    .justify_between()
                    .pb(space(1))
                    .child(
                        div()
                            .text_size(px(12.0))
                            .text_color(palette.ink_2)
                            .child("Native Agent"),
                    )
                    .child(
                        div()
                            .id("chat-native-new")
                            .role(Role::Button)
                            .aria_label("新对话")
                            .text_size(px(11.0))
                            .text_color(palette.ink_3)
                            .child("新对话")
                            .on_click(cx.listener(|this, _, _, cx| this.new_native_chat(cx))),
                    )
                    .child(
                        div()
                            .id("chat-switch-to-acp")
                            .role(Role::Button)
                            .aria_label("切回 ACP")
                            .text_size(px(11.0))
                            .text_color(palette.ink_3)
                            .child("切回 ACP")
                            .on_click(
                                cx.listener(|this, _, _, cx| this.toggle_native_chat_mode(cx)),
                            ),
                    ),
            )
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
