//! Agent Panel 外壳：统一 header（标题编辑、＋、⋯）与内容视图。
//!
//! native agent 与 ACP agent 都作为内容接入；标题编辑与 ＋ 菜单在 header 统一处理。

use super::super::super::*;
use super::super::ScreenContext;
use cgc_platform::agent::detect::AgentStatus;
use gpui_kit::component::button::{Button, ButtonVariants};
use gpui_kit::component::input::Input;
use gpui_kit::component::popover::Popover;

pub(in crate::root_view) fn render_agent_panel(
    ctx: &mut ScreenContext<'_>,
    language: Language,
    palette: &theme::Palette,
    _window: &mut Window,
    cx: &mut Context<RootView>,
) -> AnyElement {
    let learning = ctx
        .current
        .as_ref()
        .is_some_and(|route_match| route_match.route.id == "courses.learning");
    let native_mode = ctx.native_chat_mode && RootView::native_agent_enabled();
    let content: AnyElement = if native_mode {
        ctx.native_agent_view
            .clone()
            .map(IntoElement::into_any_element)
            .unwrap_or_else(|| div().child("正在初始化 Agent…").into_any_element())
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
        .bg(palette.canvas)
        .child(header(ctx, palette, cx))
        .child(div().flex_1().min_h(px(0.0)).child(content))
        .into_any_element()
}

fn menu_separator(palette: theme::Palette) -> AnyElement {
    div()
        .my(px(2.0))
        .h(px(1.0))
        .w_full()
        .bg(palette.line)
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
            ctx.chat.session.session_id.as_ref().and_then(|session_id| {
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
    let agent_icon_id = if native_mode {
        "native".to_string()
    } else {
        ctx.chat.selected_agent.clone().unwrap_or_default()
    };
    let title = panel_title(ctx, cx);
    let editing = ctx.agent_panel_editing_title;
    let hovered = ctx.agent_panel_title_hovered;
    let title_input = ctx.agent_panel_title_input.clone();
    // 对齐 Zed：生成中标题做呼吸态、失败时给重试入口；两者都只对 native 轨生效。
    let (title_generating, title_error) = if native_mode {
        ctx.native_agent_view
            .as_ref()
            .map(|view| {
                let view = view.read(cx);
                (view.title_generating(), view.title_generation_error())
            })
            .unwrap_or((false, None))
    } else {
        (false, None)
    };
    let can_regenerate_title = native_mode
        && !title_generating
        && ctx
            .native_agent_view
            .as_ref()
            .is_some_and(|view| !view.read(cx).is_empty_thread());

    let title_area: AnyElement = if editing {
        match title_input {
            Some(input) => div()
                .flex_1()
                .child(Input::new(&input).w_full())
                .into_any_element(),
            None => div().flex_1().child(title.clone()).into_any_element(),
        }
    } else if title_generating {
        div()
            .id("agent-panel-title-generating")
            .flex_1()
            .flex()
            .flex_row()
            .items_center()
            .px(space(1))
            .child(
                div()
                    .text_size(px(13.0))
                    .text_color(palette.ink_3)
                    .child(title.clone())
                    .with_animation(
                        "agent-panel-generating-title",
                        Animation::new(std::time::Duration::from_secs(2))
                            .repeat()
                            .with_easing(pulsating_between(0.4, 0.8)),
                        |label, delta| label.opacity(delta),
                    ),
            )
            .tooltip(|window, cx| Tooltip::new("正在生成标题…").build(window, cx))
            .into_any_element()
    } else {
        let hover_root = root.clone();
        let click_root = root.clone();
        let edit_root = root.clone();
        let editable = div()
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
            });
        if let Some(error) = title_error {
            let retry_root = root.clone();
            div()
                .flex_1()
                .flex()
                .flex_row()
                .items_center()
                .gap(px(2.0))
                .child(editable)
                .child(
                    div()
                        .id("agent-panel-title-retry")
                        .role(Role::Button)
                        .aria_label("重新生成标题")
                        .px(px(2.0))
                        .text_size(px(11.0))
                        .text_color(palette.danger)
                        .child("⚠")
                        .tooltip(move |window, cx| {
                            Tooltip::new(format!("标题生成失败，点击重试：{error}"))
                                .build(window, cx)
                        })
                        .on_click(move |_, _, cx| {
                            let _ = retry_root.update(cx, |this, cx| {
                                this.regenerate_agent_panel_title(cx);
                            });
                        }),
                )
                .into_any_element()
        } else {
            editable.into_any_element()
        }
    };

    // 对齐 Zed：只列本机已注册/已检测到 Ready 的 external agents；
    // 未安装的通过 Add More Agents 进入安装页。
    let mut agent_options: Vec<(String, String)> = ctx
        .agent_registry_rows
        .iter()
        .filter(|row| matches!(row.status, AgentStatus::Ready { .. }))
        .map(|row| (row.entry.id.clone(), row.entry.display_name.clone()))
        .collect();
    agent_options.sort_unstable_by_key(|(_, name)| name.to_lowercase());
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
        .px(space(2))
        .pt(space(2))
        .pb(space(1))
        .border_b_1()
        .border_color(palette.line)
        .child(crate::root_view::agent_icons::agent_icon_element(
            &agent_icon_id,
            16.0,
            palette.ink_3,
        ))
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
                    let mut rows: Vec<AnyElement> = Vec::new();
                    if RootView::native_agent_enabled() {
                        let cgc_root = add_menu_root.clone();
                        let cgc_dismiss = dismiss.clone();
                        rows.push(
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
                                .child(crate::root_view::agent_icons::agent_icon_element(
                                    "native",
                                    14.0,
                                    palette.ink_3,
                                ))
                                .child(div().flex_1().child("CGC Agent"))
                                .child(
                                    div()
                                        .text_size(px(10.0))
                                        .text_color(palette.ink_3)
                                        .child("Native"),
                                )
                                .on_click(move |_, window, cx| {
                                    let _ = cgc_root.update(cx, |this, cx| {
                                        this.enter_native_chat(cx);
                                        this.new_native_chat(cx);
                                    });
                                    let _ = cgc_dismiss
                                        .update(cx, |state, cx| state.dismiss(window, cx));
                                })
                                .into_any_element(),
                        );
                    }
                    rows.push(menu_separator(palette));
                    rows.push(
                        div()
                            .px(space(1))
                            .pt(px(2.0))
                            .pb(px(1.0))
                            .text_size(px(10.0))
                            .text_color(palette.ink_3)
                            .child("External Agents")
                            .into_any_element(),
                    );
                    if agent_options.is_empty() {
                        rows.push(
                            div()
                                .px(space(1))
                                .py(px(3.0))
                                .text_size(px(10.0))
                                .text_color(palette.ink_3)
                                .child(if loading || !registry_started {
                                    "检测本机 agent…"
                                } else {
                                    "没有已安装的 agent"
                                })
                                .into_any_element(),
                        );
                    } else {
                        for (id, name) in &agent_options {
                            let row_root = add_menu_root.clone();
                            let row_dismiss = dismiss.clone();
                            let id = id.clone();
                            let name = name.clone();
                            rows.push(
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
                                    .child(crate::root_view::agent_icons::agent_icon_element(
                                        &id,
                                        14.0,
                                        palette.ink_3,
                                    ))
                                    .child(div().flex_1().child(name.clone()))
                                    .on_click(move |_, window, cx| {
                                        let _ = row_root.update(cx, |this, cx| {
                                            this.select_chat_agent(id.clone(), name.clone(), cx);
                                        });
                                        let _ = row_dismiss
                                            .update(cx, |state, cx| state.dismiss(window, cx));
                                    })
                                    .into_any_element(),
                            );
                        }
                    }
                    rows.push(menu_separator(palette));
                    let add_weak = add_menu_root.clone();
                    let add_dismiss = dismiss.clone();
                    rows.push(
                        div()
                            .id("agent-panel-add-more")
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap(space(1))
                            .px(space(1))
                            .py(px(3.0))
                            .rounded(px(RADIUS_SMALL))
                            .text_size(px(11.0))
                            .text_color(palette.accent)
                            .hover(|style| style.bg(palette.soft))
                            .child(Icon::default().path(AssetIcon::Plus.path()).small())
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
                        .w(px(240.0))
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
                    let threads_root = settings_root.clone();
                    let threads_dismiss = dismiss.clone();
                    let settings_root = settings_root.clone();
                    let settings_dismiss = dismiss;
                    div()
                        .w(px(220.0))
                        .flex()
                        .flex_col()
                        .gap(px(1.0))
                        .children(can_regenerate_title.then(|| {
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
                                .id("agent-panel-toggle-threads-sidebar")
                                .flex()
                                .flex_row()
                                .items_center()
                                .justify_between()
                                .gap(space(1))
                                .px(space(1))
                                .py(px(3.0))
                                .rounded(px(RADIUS_SMALL))
                                .text_size(px(11.0))
                                .text_color(palette.ink_2)
                                .hover(|style| style.bg(palette.soft))
                                .child("Toggle Threads Sidebar")
                                .child(
                                    div()
                                        .text_size(px(10.0))
                                        .text_color(palette.ink_3)
                                        .child(threads_sidebar_shortcut_label()),
                                )
                                .on_click(move |_, window, cx| {
                                    let _ = threads_root.update(cx, |this, cx| {
                                        this.toggle_history_sidebar(cx);
                                    });
                                    let _ = threads_dismiss
                                        .update(cx, |state, cx| state.dismiss(window, cx));
                                }),
                        )
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

/// 历史侧栏快捷键展示文本（与 `RootView::is_threads_sidebar_shortcut` 保持一致；
/// Zed 用 ⌥⌘J，非 macOS 用 Ctrl+Alt+J）。
fn threads_sidebar_shortcut_label() -> &'static str {
    if cfg!(target_os = "macos") {
        "⌥⌘J"
    } else {
        "Ctrl+Alt+J"
    }
}
