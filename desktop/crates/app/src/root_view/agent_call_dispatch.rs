//! 课程 CTA → Agent composer 的分发入口（AgentCall，不叫 LearningAction）。
//!
//! Native 轨拿到结构化 `AgentCall` 与 pending chip；ACP 轨按 #1260 的降级
//! 口径只预填可编辑文本，不承诺结构化 action。

use super::*;

impl RootView {
    pub(in crate::root_view) fn apply_agent_call(
        &mut self,
        call: crate::agent_call::AgentCall,
        prompt: String,
        label: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.agent_panel_open = true;

        if self.native_chat_mode && Self::native_agent_enabled() {
            if let Some(view) = self.native_agent_view.clone() {
                view.update(cx, |view, cx| {
                    view.compose_agent_call(call, prompt, label, window, cx);
                });
                cx.notify();
                return;
            }
            // native 面板尚未初始化时，不把用户留在空面板：回退 ACP 文本预填。
            self.native_chat_mode = false;
        }

        self.chat.input = prompt.clone();
        if let Some(input) = self.chat_input.clone() {
            input.update(cx, |input, cx| {
                input.set_value(prompt, window, cx);
                input.focus(window, cx);
            });
        }
        cx.notify();
    }
}
