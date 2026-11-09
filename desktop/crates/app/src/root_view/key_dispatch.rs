use super::*;

impl RootView {
    pub(in crate::root_view) fn is_settings_shortcut(keystroke: &gpui_kit::Keystroke) -> bool {
        keystroke.key == "," && (keystroke.modifiers.platform || keystroke.modifiers.control)
    }

    pub(in crate::root_view) fn is_new_chat_shortcut(keystroke: &Keystroke) -> bool {
        keystroke.key.eq_ignore_ascii_case("n")
            && !keystroke.modifiers.shift
            && (keystroke.modifiers.platform || keystroke.modifiers.control)
    }

    /// Zed `ToggleWorkspaceSidebar`（⌥⌘J / Ctrl+Alt+J）：切换历史侧边栏。
    pub(in crate::root_view) fn is_threads_sidebar_shortcut(keystroke: &Keystroke) -> bool {
        keystroke.key.eq_ignore_ascii_case("j")
            && !keystroke.modifiers.shift
            && keystroke.modifiers.alt
            && (keystroke.modifiers.platform || keystroke.modifiers.control)
    }

    pub(in crate::root_view) fn is_agent_panel_shortcut(keystroke: &Keystroke) -> bool {
        keystroke.key.eq_ignore_ascii_case("j")
            && !keystroke.modifiers.shift
            && (keystroke.modifiers.platform || keystroke.modifiers.control)
    }

    pub(in crate::root_view) fn handle_shell_key(
        &mut self,
        event: &KeyDownEvent,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if event.keystroke.key == "escape" && self.chat.session.is_busy() {
            self.stop_chat_turn(cx);
            return;
        }
        if Self::is_new_chat_shortcut(&event.keystroke) {
            self.new_chat(cx);
            return;
        }
        if Self::is_threads_sidebar_shortcut(&event.keystroke) {
            self.toggle_history_sidebar(cx);
            return;
        }
        if Self::is_agent_panel_shortcut(&event.keystroke) {
            self.toggle_agent_panel(cx);
            return;
        }
        if (event.keystroke.modifiers.platform || event.keystroke.modifiers.control)
            && event.keystroke.key.eq_ignore_ascii_case("b")
        {
            let panel = if event.keystroke.modifiers.shift {
                RightPanel::Outline
            } else {
                RightPanel::SiteTree
            };
            self.toggle_right_panel(panel, cx);
            return;
        }
        if self.site_tree_search_focused
            && self.right_panel_open
            && self.right_panel == RightPanel::SiteTree
        {
            return;
        }
        if self.agent_registry_search_focused
            && self
                .current
                .as_ref()
                .is_some_and(|route_match| route_match.route.id == "app.agents")
        {
            match event.keystroke.key.as_str() {
                "escape" | "enter" => self.agent_registry_search_focused = false,
                "backspace" => {
                    self.agent_registry_query.pop();
                }
                _ => {
                    if let Some(text) = event.keystroke.key_char.as_deref() {
                        if !event.keystroke.modifiers.modified() && !text.is_empty() {
                            self.agent_registry_query.push_str(text);
                        }
                    }
                }
            }
            cx.notify();
            return;
        }
        if Self::is_settings_shortcut(&event.keystroke) {
            self.open_settings_window(cx);
            return;
        }
        // 审批卡的键盘等价路径（显式组合键，避免与输入 y/n 冲突）。
        if event.keystroke.modifiers.control
            && event.keystroke.modifiers.shift
            && self.current.as_ref().is_some_and(|route_match| {
                matches!(
                    route_match.route.id,
                    "courses.learning" | "courses.public_learning"
                )
            })
        {
            match event.keystroke.key.as_str() {
                "y" => {
                    self.respond_chat_permission(true, cx);
                    return;
                }
                "n" => {
                    self.respond_chat_permission(false, cx);
                    return;
                }
                _ => {}
            }
        }
        if self.chat.focused {
            // Textarea 自己处理 Enter/方向键/输入；根视图只保留上面的全局快捷键，
            // 不要让 Enter 继续触发课程页的“开始学习”。
            return;
        }
        if event.keystroke.key != "enter" {
            return;
        }
        let Some(route_match) = self.current.clone() else {
            return;
        };
        // 公开详情页复用同一块「开始学习 / 按 Enter 进入学习」提示，键盘必须同源（R17）。
        if !matches!(
            route_match.route.id,
            "courses.detail" | "courses.public_detail"
        ) {
            return;
        }
        let Some(course_id) = route_match.params.get("id").cloned() else {
            return;
        };
        let enrolled = self
            .course_detail
            .detail()
            .and_then(|detail| detail.enrollment_status.as_deref())
            == Some("confirmed");
        if enrolled {
            let workspace_id = self
                .course_detail
                .detail()
                .and_then(|detail| detail.workspace_id.clone());
            self.navigate_to_learning(&course_id, workspace_id.as_deref(), cx);
            cx.notify();
        }
    }
}
