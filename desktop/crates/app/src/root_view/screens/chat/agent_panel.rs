//! Agent Panel 外壳：统一 header（标题编辑、＋、⋯）与内容视图。
//!
//! native agent 与 ACP agent 都作为内容接入；标题编辑与 ＋ 菜单在 header 统一处理。

use super::super::super::*;
use super::super::ScreenContext;
use crate::icons::{AGENT_HEADER_ICON_SIZE, AGENT_ROW_ICON_SIZE};
use crate::root_view::state::ShellState;
use cgc_platform::agent::detect::AgentStatus;
use gpui_kit::component::button::{Button, ButtonVariants};
use gpui_kit::component::input::Input;
use gpui_kit::component::popover::Popover;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(in crate::root_view) enum AgentPanelContent {
    Terminal,
    Native,
    External,
}

/// Native/ACP 都是全局 Agent Panel；路由只决定中心内容，不再决定 ACP 是否可用。
pub(in crate::root_view) fn content_kind(
    native_mode: bool,
    _route_id: Option<&str>,
) -> AgentPanelContent {
    if native_mode {
        AgentPanelContent::Native
    } else {
        AgentPanelContent::External
    }
}

/// 面板槽位的两个独立事实：终端实例是否存在（可能被隐藏）、它是否占据面板。
///
/// 切到 agent 时只隐藏终端（`RootView::dismiss_terminal_for_chat`），PTY 与输出保留，
/// 所以「终端存在」不等于「终端占面板」。任何「当前显示什么」的判断都必须过这里，
/// 不能再直接读 `terminal_view.is_some()`——那会把隐藏终端当成面板模式（issue #1269）。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(in crate::root_view) struct PanelSlot {
    pub terminal_present: bool,
    pub terminal_visible: bool,
}

impl PanelSlot {
    /// 面板内容优先级：可见终端 > native > external。
    pub fn content(self, native_mode: bool) -> AgentPanelContent {
        if self.terminal_present && self.terminal_visible {
            AgentPanelContent::Terminal
        } else {
            content_kind(native_mode, None)
        }
    }
}

/// 当前面板显示什么：唯一判定入口（header、标题、编辑入口都从这里派生）。
pub(in crate::root_view) fn panel_content(state: &ShellState) -> AgentPanelContent {
    PanelSlot {
        terminal_present: state.terminal_view.is_some(),
        terminal_visible: state.terminal_visible,
    }
    .content(state.native_chat_mode && RootView::native_agent_enabled())
}

impl ShellState {
    /// 当前终端的展示标题：custom > live OSC > live cwd > spawn cwd。
    ///
    /// header 与历史列表共用同一组输入，`cd` 之后不会各显示一个目录名（#1252 B2）。
    pub(in crate::root_view) fn terminal_display_title(&self, cx: &App) -> Option<String> {
        let view = self.terminal_view.as_ref()?;
        let view = view.read(cx);
        let spawn_cwd = self
            .terminal_cwd
            .as_deref()
            .and_then(std::path::Path::to_str);
        crate::acp_history::terminal_title(
            Some(view.title()),
            self.terminal_custom_title.as_deref(),
            view.cwd().filter(|cwd| !cwd.is_empty()).or(spawn_cwd),
        )
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(in crate::root_view) enum HeaderIcon {
    Terminal,
    Agent,
}

/// header 的图标与可编辑性：由面板内容派生，不单独判断。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(in crate::root_view) struct HeaderModel {
    pub icon: HeaderIcon,
    pub editable: bool,
}

pub(in crate::root_view) fn header_model(content: AgentPanelContent) -> HeaderModel {
    match content {
        AgentPanelContent::Terminal => HeaderModel {
            icon: HeaderIcon::Terminal,
            editable: true,
        },
        AgentPanelContent::Native | AgentPanelContent::External => HeaderModel {
            icon: HeaderIcon::Agent,
            editable: true,
        },
    }
}

/// 标题选择：只按面板内容分派，隐藏终端的 OSC 标题不会泄漏到线程面板。
fn title_for(
    content: AgentPanelContent,
    terminal_title: Option<&str>,
    native_title: Option<&str>,
    chat_title: Option<&str>,
) -> String {
    match content {
        AgentPanelContent::Terminal => terminal_panel_title(terminal_title.unwrap_or("")),
        AgentPanelContent::Native => native_title.unwrap_or("新对话").to_string(),
        AgentPanelContent::External => chat_title.unwrap_or("新对话").to_string(),
    }
}

fn panel_title(state: &ShellState, cx: &App) -> String {
    let content = panel_content(state);
    let terminal_title = state.terminal_display_title(cx);
    let native_title = state
        .native_agent_view
        .as_ref()
        .map(|view| view.read(cx).display_title());
    let chat_title = state.chat.title_override.clone().or_else(|| {
        state
            .chat
            .session
            .session_id
            .as_ref()
            .and_then(|session_id| {
                state
                    .chat
                    .sessions
                    .iter()
                    .find(|session| &session.session_id == session_id)
                    .and_then(|session| session.title.clone())
            })
    });
    title_for(
        content,
        terminal_title.as_deref(),
        native_title.as_deref(),
        chat_title.as_deref(),
    )
}

pub(in crate::root_view) fn render_agent_panel(
    ctx: &mut ScreenContext<'_>,
    language: Language,
    palette: &theme::Palette,
    _window: &mut Window,
    cx: &mut Context<RootView>,
) -> AnyElement {
    let panel = panel_content(ctx);
    let content: AnyElement = match panel {
        AgentPanelContent::Terminal => ctx
            .terminal_view
            .clone()
            .map(IntoElement::into_any_element)
            .unwrap_or_else(|| div().into_any_element()),
        AgentPanelContent::Native => ctx
            .native_agent_view
            .clone()
            .map(IntoElement::into_any_element)
            .unwrap_or_else(|| div().child("正在初始化 Agent…").into_any_element()),
        AgentPanelContent::External => super::panel::render_chat_panel(ctx, language, palette, cx),
    };
    div()
        .id("agent-panel-dock")
        .w(px(ctx.agent_panel_width))
        .flex_none()
        .h_full()
        .flex()
        .flex_col()
        .bg(palette.canvas)
        .child(header(ctx, language, palette, cx))
        .child(div().flex_1().min_h(px(0.0)).child(content))
        .into_any_element()
}

/// 终端面板标题：程序通过 OSC 设置了标题就用它，否则回退 `Terminal`。
pub(in crate::root_view) fn terminal_panel_title(title: &str) -> String {
    let trimmed = title.trim();
    if trimmed.is_empty() {
        "Terminal".to_string()
    } else {
        trimmed.to_string()
    }
}

pub(in crate::root_view) fn header(
    ctx: &mut ScreenContext<'_>,
    language: Language,
    palette: &theme::Palette,
    cx: &mut Context<RootView>,
) -> AnyElement {
    let palette = *palette;
    let root = cx.entity().downgrade();
    let content = panel_content(ctx);
    let model = header_model(content);
    let native_mode = content == AgentPanelContent::Native;
    let agent_icon_id = if native_mode {
        "native".to_string()
    } else {
        ctx.chat.selected_agent.clone().unwrap_or_default()
    };
    // 终端模式用终端图标，其余沿用 agent 品牌 mark（Zed 的 tab 同样按内容切图标）。
    let header_icon = match model.icon {
        HeaderIcon::Terminal => crate::root_view::agent_icons::terminal_icon_element(
            AGENT_HEADER_ICON_SIZE,
            palette.ink_3,
        ),
        HeaderIcon::Agent => crate::root_view::agent_icons::agent_icon_element(
            &agent_icon_id,
            AGENT_HEADER_ICON_SIZE,
            palette.ink_3,
        ),
    };
    let title = panel_title(ctx, cx);
    let editing = ctx.agent_panel_editing_title;
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
        // 对齐 Zed：标题本身就是编辑入口（没有铅笔）；Enter/失焦提交，Esc 取消。
        // 终端标题由 shell 的 OSC 驱动，面板内不提供改名（改名见 #1252 B2）。
        let click_root = root.clone();
        let key_root = root.clone();
        let editable: AnyElement = if model.editable {
            div()
                .id("agent-panel-title")
                .role(Role::Button)
                .aria_label("重命名对话")
                .tab_index(0isize)
                .flex_1()
                .flex()
                .flex_row()
                .items_center()
                .px(space(1))
                .rounded(px(RADIUS_SMALL))
                .hover(|style| style.bg(palette.soft))
                .child(div().text_size(px(13.0)).child(title.clone()))
                .on_click(move |_, window, cx| {
                    let _ = click_root.update(cx, |this, cx| {
                        this.start_edit_agent_panel_title(window, cx);
                    });
                })
                .on_key_down(move |event, window, cx| {
                    if matches!(event.keystroke.key.as_str(), "enter" | "space") {
                        let _ = key_root.update(cx, |this, cx| {
                            this.start_edit_agent_panel_title(window, cx);
                        });
                        cx.stop_propagation();
                    }
                })
                .into_any_element()
        } else {
            div()
                .id("agent-panel-title-readonly")
                .flex_1()
                .flex()
                .flex_row()
                .items_center()
                .px(space(1))
                .child(div().text_size(px(13.0)).child(title.clone()))
                .into_any_element()
        };
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
                    Button::new("agent-panel-title-retry")
                        .label("⚠")
                        .accessibility_label("重新生成标题")
                        .xsmall()
                        .ghost()
                        .tooltip(format!("标题生成失败，点击重试：{error}"))
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
    let terminal_open = ctx.terminal_view.is_some();

    div()
        .id("agent-panel-header")
        .role(Role::Toolbar)
        .aria_label("Agent 面板")
        .flex()
        .flex_row()
        .items_center()
        .gap(space(1))
        .px(space(2))
        .h(px(COLUMN_HEADER_HEIGHT))
        .border_b_1()
        .border_color(palette.line)
        .child(header_icon)
        .child(title_area)
        .child(
            Popover::new("agent-panel-new")
                .anchor(Anchor::TopRight)
                .trigger(
                    Button::new("agent-panel-new-trigger")
                        .label("＋")
                        .accessibility_label(translate(language, Key::AppA11yNewChat))
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
                                    AGENT_ROW_ICON_SIZE,
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
                    let term_root = add_menu_root.clone();
                    let term_dismiss = dismiss.clone();
                    rows.push(
                        div()
                            .id("agent-panel-terminal")
                            .role(Role::Button)
                            .aria_label("Terminal")
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
                            .child(crate::root_view::agent_icons::terminal_icon_element(
                                AGENT_ROW_ICON_SIZE,
                                palette.ink_3,
                            ))
                            .child(div().flex_1().child("Terminal"))
                            .on_click(move |_, window, cx| {
                                let _ =
                                    term_root.update(cx, |this, cx| this.open_terminal(window, cx));
                                let _ =
                                    term_dismiss.update(cx, |state, cx| state.dismiss(window, cx));
                            })
                            .into_any_element(),
                    );
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
                                        AGENT_ROW_ICON_SIZE,
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
                            .role(Role::Button)
                            .aria_label(translate(language, Key::AppA11yAddMoreAgents))
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
            Button::new("agent-panel-more-trigger")
                .label("⋯")
                .xsmall()
                .ghost()
                .tooltip("Agent Menu")
                .dropdown_menu_with_anchor(Anchor::TopRight, move |menu, _window, _cx| {
                    let mut menu = menu;
                    if can_regenerate_title {
                        let regen_root = regenerate_root.clone();
                        menu = menu.item(PopupMenuItem::new("Regenerate Thread Title").on_click(
                            move |_, _, cx| {
                                let _ = regen_root.update(cx, |this, cx| {
                                    this.regenerate_agent_panel_title(cx);
                                });
                            },
                        ));
                    }
                    let threads_root = settings_root.clone();
                    menu = menu.item(
                        PopupMenuItem::element(move |_, _| {
                            div()
                                .flex()
                                .w_full()
                                .justify_between()
                                .gap(space(2))
                                .child("Toggle Threads Sidebar")
                                .child(
                                    div()
                                        .text_size(px(10.0))
                                        .text_color(palette.ink_3)
                                        .child(threads_sidebar_shortcut_label()),
                                )
                        })
                        .on_click(move |_, _, cx| {
                            let _ = threads_root.update(cx, |this, cx| {
                                this.toggle_history_sidebar(cx);
                            });
                        }),
                    );
                    let settings = settings_root.clone();
                    menu = menu.item(PopupMenuItem::new("Settings").on_click(move |_, _, cx| {
                        let _ = settings.update(cx, |this, cx| this.open_settings_window(cx));
                    }));
                    if terminal_open {
                        let close_root = settings_root.clone();
                        menu = menu.item(PopupMenuItem::new("Close Terminal").on_click(
                            move |_, _, cx| {
                                let _ = close_root.update(cx, |this, cx| this.close_terminal(cx));
                            },
                        ));
                    }
                    menu
                }),
        )
        .into_any_element()
}

fn menu_separator(palette: theme::Palette) -> AnyElement {
    div()
        .h(px(1.0))
        .w_full()
        .bg(palette.line)
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

#[cfg(test)]
mod tests {
    // 只做显式导入：父模块的 glob 会引入 gpui 的 test 宏。
    use super::{
        header_model, terminal_panel_title, title_for, AgentPanelContent, HeaderIcon, PanelSlot,
    };

    /// 面板内容优先级：终端可见时占位；隐藏（切到 agent）后显示对话内容。
    /// 原 bug（#1269）：隐藏终端仍被当成面板模式——本测试的 `hidden` 分支就是那条守卫。
    #[test]
    fn terminal_owns_the_panel_only_while_visible() {
        let visible = PanelSlot {
            terminal_present: true,
            terminal_visible: true,
        };
        assert_eq!(visible.content(true), AgentPanelContent::Terminal);
        assert_eq!(visible.content(false), AgentPanelContent::Terminal);

        // 隐藏终端后（进程仍在跑）面板回到对话内容。
        let hidden = PanelSlot {
            terminal_present: true,
            terminal_visible: false,
        };
        assert_eq!(hidden.content(true), AgentPanelContent::Native);
        assert_eq!(hidden.content(false), AgentPanelContent::External);

        let absent = PanelSlot {
            terminal_present: false,
            terminal_visible: false,
        };
        assert_eq!(absent.content(true), AgentPanelContent::Native);
        assert_eq!(absent.content(false), AgentPanelContent::External);
    }

    #[test]
    fn header_follows_panel_content_not_terminal_presence() {
        let terminal = header_model(AgentPanelContent::Terminal);
        assert_eq!(terminal.icon, HeaderIcon::Terminal);
        assert!(
            terminal.editable,
            "终端标题可在面板内改名（写 custom_title）"
        );

        for content in [AgentPanelContent::Native, AgentPanelContent::External] {
            let model = header_model(content);
            assert_eq!(model.icon, HeaderIcon::Agent);
            assert!(model.editable);
        }
    }

    /// 原 bug 的直接断言：终端存在但隐藏时，线程面板的标题不能取终端 OSC 标题。
    #[test]
    fn hidden_terminal_title_never_reaches_a_thread_panel() {
        let osc = Some("ywen: ~/cgc2046_workspace/assistant/884c");
        assert_eq!(
            title_for(AgentPanelContent::Native, osc, Some("课程"), Some("chat")),
            "课程"
        );
        assert_eq!(
            title_for(AgentPanelContent::External, osc, None, Some("chat")),
            "chat"
        );
        // 终端内容仍然用终端标题。
        assert_eq!(
            title_for(AgentPanelContent::Terminal, osc, Some("课程"), None),
            "ywen: ~/cgc2046_workspace/assistant/884c"
        );
    }

    #[test]
    fn terminal_title_falls_back_when_empty() {
        assert_eq!(terminal_panel_title(""), "Terminal");
        assert_eq!(terminal_panel_title("   \n"), "Terminal");
    }

    #[test]
    fn terminal_title_uses_program_title() {
        assert_eq!(terminal_panel_title("  vim main.rs  "), "vim main.rs");
    }
}
