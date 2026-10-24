//! Agent Panel 外壳：统一 header（标题编辑、＋、⋯）与内容视图。
//!
//! native agent 与 ACP agent 都作为内容接入；标题编辑与 ＋ 菜单在 header 统一处理。

use super::super::super::*;
use super::super::ScreenContext;
use cgc_platform::agent::detect::AgentStatus;
use cgc_platform::registry::manifest::Registry;
use gpui_kit::component::button::{Button, ButtonVariants};
use gpui_kit::component::input::Input;
use gpui_kit::component::popover::Popover;

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
    let native_mode = ctx.native_chat_mode && RootView::native_agent_enabled();
    let content: AnyElement = if native_mode {
        if ctx.native_agent_view.is_none() {
            let view = cx.new(|cx| crate::native_agent_view::NativeAgentView::new(window, cx));
            ctx.native_agent_view = Some(view);
        }
        let view = ctx.native_agent_view.clone().expect("native agent view");
        view.into_any_element()
    } else if learning {
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
    };
    div()
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
        .child(header(ctx, palette, cx))
        .child(div().flex_1().min_h(px(0.0)).child(content))
        .into_any_element()
}

fn panel_title(ctx: &ScreenContext<'_>, cx: &mut Context<RootView>) -> String {
    if ctx.native_chat_mode && RootView::native_agent_enabled() {
        return ctx
            .native_agent_view
            .as_ref()
            .map(|view| view.read(cx).display_title())
            .unwrap_or_else(|| "新对话".to_string());
    }
    ctx.chat
        .title_override
        .clone()
        .or_else(|| {
            ctx.chat.session_id.as_ref().and_then(|session_id| {
                ctx.chat
                    .sessions
                    .iter()
                    .find(|session| &session.session_id == session_id)
                    .and_then(|session| session.title.clone())
            })
        })
        .unwrap_or_else(|| "新对话".to_string())
}

fn header(
    ctx: &mut ScreenContext<'_>,
    palette: &theme::Palette,
    cx: &mut Context<RootView>,
) -> AnyElement {
    let palette = *palette;
    let root = cx.entity().downgrade();
    let native_mode = ctx.native_chat_mode && RootView::native_agent_enabled();
    let title = panel_title(ctx, cx);
    let editing = ctx.agent_panel_editing_title;
    let hovered = ctx.agent_panel_title_hovered;
    let title_input = ctx.agent_panel_title_input.clone();

    let title_area: AnyElement = if editing {
        match title_input {
            Some(input) => div()
                .flex_1()
                .child(Input::new(&input).w_full())
                .into_any_element(),
            None => div().flex_1().child(title.clone()).into_any_element(),
        }
    } else {
        let hover_root = root.clone();
        let click_root = root.clone();
        let edit_root = root.clone();
        div()
            .id("agent-panel-title")
            .flex_1()
            .flex()
            .flex_row()
            .items_center()
            .gap(px(4.0))
            .px(space(1))
            .rounded(px(RADIUS_SMALL))
            .hover(|style| style.bg(palette.soft))
            .child(div().text_size(px(13.0)).child(title.clone()))
            .children(hovered.then(|| {
                let edit_root = edit_root.clone();
                div()
                    .id("agent-panel-edit-title")
                    .role(Role::Button)
                    .aria_label("编辑标题")
                    .px(px(2.0))
                    .text_size(px(11.0))
                    .text_color(palette.ink_3)
                    .hover(|style| style.bg(palette.soft))
                    .child("✏")
                    .tooltip(|window, cx| Tooltip::new("Edit Thread Title").build(window, cx))
                    .on_click(move |_, window, cx| {
                        let _ = edit_root.update(cx, |this, cx| {
                            this.start_edit_agent_panel_title(window, cx);
                        });
                    })
            }))
            .on_hover(move |is_hovered: &bool, _window, cx| {
                let _ = hover_root.update(cx, |this, cx| {
                    this.agent_panel_title_hovered = *is_hovered;
                    cx.notify();
                });
            })
            .on_click(move |_, window, cx| {
                let _ = click_root.update(cx, |this, cx| {
                    this.start_edit_agent_panel_title(window, cx);
                });
            })
            .into_any_element()
    };

    let installed: Vec<String> = ctx
        .agent_registry_rows
        .iter()
        .filter(|row| matches!(row.status, AgentStatus::Ready { .. }))
        .map(|row| row.entry.id.clone())
        .collect();
    let agent_options: Vec<(String, String)> = Registry::builtin()
        .map(|registry| {
            registry
                .agents
                .into_iter()
                .filter(|entry| installed.is_empty() || installed.contains(&entry.id))
                .map(|entry| (entry.id, entry.display_name))
                .collect()
        })
        .unwrap_or_default();
    let loading = ctx.agent_registry_loading;
    let registry_started = ctx.agent_registry_started;
    let menu_root = root.clone();
    let add_menu_root = root.clone();
    let regenerate_root = root.clone();
    let settings_root = root.clone();
    let save_root = root.clone();
    let cancel_root = root.clone();

    div()
        .id("agent-panel-header")
        .flex()
        .flex_row()
        .items_center()
        .gap(space(1))
        .pb(space(1))
        .border_b_1()
        .border_color(palette.line)
        .child(title_area)
        .children(editing.then(|| {
            let save_root = save_root.clone();
            let cancel_root = cancel_root.clone();
            div()
                .flex()
                .flex_row()
                .items_center()
                .gap(px(4.0))
                .child(
                    div()
                        .id("agent-panel-title-save")
                        .role(Role::Button)
                        .px(space(1))
                        .rounded(px(RADIUS_SMALL))
                        .bg(palette.accent)
                        .text_color(palette.canvas)
                        .text_size(px(10.0))
                        .child("保存")
                        .on_click(move |_, window, cx| {
                            let _ = save_root.update(cx, |this, cx| {
                                this.commit_agent_panel_title(window, cx);
                            });
                        }),
                )
                .child(
                    div()
                        .id("agent-panel-title-cancel")
                        .role(Role::Button)
                        .px(space(1))
                        .rounded(px(RADIUS_SMALL))
                        .text_size(px(10.0))
                        .text_color(palette.ink_3)
                        .child("取消")
                        .on_click(move |_, window, cx| {
                            let _ = cancel_root.update(cx, |this, cx| {
                                this.cancel_agent_panel_title(window, cx);
                            });
                        }),
                )
        }))
        .child(
            Popover::new("agent-panel-new")
                .anchor(Anchor::TopRight)
                .trigger(
                    Button::new("agent-panel-new-trigger")
                        .label("＋")
                        .xsmall()
                        .ghost()
                        .tooltip("New Agent Thread"),
                )
                .on_open_change(move |open, _, cx| {
                    if *open && !registry_started {
                        let load_root = menu_root.clone();
                        let _ = load_root.update(cx, |this, cx| {
                            this.start_agent_registry_load(cx);
                        });
                    }
                })
                .content(move |_, _, cx| {
                    let dismiss = cx.entity().downgrade();
                    let native_root = add_menu_root.clone();
                    let native_dismiss = dismiss.clone();
                    let rows: Vec<AnyElement> = agent_options
                        .iter()
                        .map(|(id, name)| {
                            let row_root = add_menu_root.clone();
                            let row_dismiss = dismiss.clone();
                            let id = id.clone();
                            let name = name.clone();
                            div()
                                .id(SharedString::from(format!("agent-panel-agent-{id}")))
                                .flex()
                                .flex_row()
                                .items_center()
                                .gap(space(1))
                                .px(space(1))
                                .py(px(3.0))
                                .rounded(px(RADIUS_SMALL))
                                .text_size(px(11.0))
                                .text_color(palette.ink_2)
                                .hover(|style| style.bg(palette.soft))
                                .child(div().flex_1().child(name.clone()))
                                .on_click(move |_, window, cx| {
                                    let _ = row_root.update(cx, |this, cx| {
                                        this.select_chat_agent(id.clone(), name.clone(), cx);
                                    });
                                    let _ = row_dismiss
                                        .update(cx, |state, cx| state.dismiss(window, cx));
                                })
                                .into_any_element()
                        })
                        .collect();
                    let mut rows = rows;
                    if native_mode {
                        rows.insert(
                            0,
                            div()
                                .id("agent-panel-native")
                                .flex()
                                .flex_row()
                                .items_center()
                                .gap(space(1))
                                .px(space(1))
                                .py(px(3.0))
                                .rounded(px(RADIUS_SMALL))
                                .text_size(px(11.0))
                                .text_color(palette.ink_2)
                                .hover(|style| style.bg(palette.soft))
                                .child(div().flex_1().child("Native Agent"))
                                .child(
                                    div()
                                        .text_size(px(10.0))
                                        .text_color(palette.ink_3)
                                        .child("Native"),
                                )
                                .on_click(move |_, window, cx| {
                                    let _ = native_root.update(cx, |this, cx| {
                                        this.enter_native_chat(cx);
                                        this.new_native_chat(cx);
                                    });
                                    let _ = native_dismiss
                                        .update(cx, |state, cx| state.dismiss(window, cx));
                                })
                                .into_any_element(),
                        );
                    }
                    if rows.is_empty() {
                        rows.push(
                            div()
                                .px(space(1))
                                .py(px(3.0))
                                .text_size(px(10.0))
                                .text_color(palette.ink_3)
                                .child(if loading {
                                    "检测本机 agent…"
                                } else {
                                    "没有已安装的 agent"
                                })
                                .into_any_element(),
                        );
                    }
                    let add_weak = add_menu_root.clone();
                    let add_dismiss = dismiss.clone();
                    rows.push(
                        div()
                            .id("agent-panel-add-more")
                            .px(space(1))
                            .py(px(3.0))
                            .rounded(px(RADIUS_SMALL))
                            .text_size(px(11.0))
                            .text_color(palette.accent)
                            .hover(|style| style.bg(palette.soft))
                            .child("Add More Agents")
                            .on_click(move |_, window, cx| {
                                let _ = add_weak.update(cx, |this, cx| {
                                    this.open_agent_registry(cx);
                                });
                                let _ =
                                    add_dismiss.update(cx, |state, cx| state.dismiss(window, cx));
                            })
                            .into_any_element(),
                    );
                    div()
                        .w(px(220.0))
                        .flex()
                        .flex_col()
                        .gap(px(1.0))
                        .children(rows)
                        .into_any_element()
                }),
        )
        .child(
            Popover::new("agent-panel-more")
                .anchor(Anchor::TopRight)
                .trigger(
                    Button::new("agent-panel-more-trigger")
                        .label("⋯")
                        .xsmall()
                        .ghost()
                        .tooltip("Agent Menu"),
                )
                .content(move |_, _, cx| {
                    let dismiss = cx.entity().downgrade();
                    let regen_root = regenerate_root.clone();
                    let regen_dismiss = dismiss.clone();
                    let settings_root = settings_root.clone();
                    let settings_dismiss = dismiss;
                    div()
                        .w(px(220.0))
                        .flex()
                        .flex_col()
                        .gap(px(1.0))
                        .children(native_mode.then(|| {
                            div()
                                .id("agent-panel-regenerate-title")
                                .px(space(1))
                                .py(px(3.0))
                                .rounded(px(RADIUS_SMALL))
                                .text_size(px(11.0))
                                .text_color(palette.ink_2)
                                .hover(|style| style.bg(palette.soft))
                                .child("Regenerate Thread Title")
                                .on_click(move |_, window, cx| {
                                    let _ = regen_root.update(cx, |this, cx| {
                                        this.regenerate_agent_panel_title(cx);
                                    });
                                    let _ = regen_dismiss
                                        .update(cx, |state, cx| state.dismiss(window, cx));
                                })
                        }))
                        .child(
                            div()
                                .id("agent-panel-settings")
                                .px(space(1))
                                .py(px(3.0))
                                .rounded(px(RADIUS_SMALL))
                                .text_size(px(11.0))
                                .text_color(palette.ink_2)
                                .hover(|style| style.bg(palette.soft))
                                .child("Settings")
                                .on_click(move |_, window, cx| {
                                    let _ = settings_root.update(cx, |this, cx| {
                                        this.open_settings_window(cx);
                                    });
                                    let _ = settings_dismiss
                                        .update(cx, |state, cx| state.dismiss(window, cx));
                                }),
                        )
                        .into_any_element()
                }),
        )
        .into_any_element()
}
