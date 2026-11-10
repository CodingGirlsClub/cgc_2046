//! 课程 CTA → Agent composer 的分发入口（AgentCall，不叫 LearningAction）。
//!
//! Native 轨拿到结构化 `AgentCall` 与 pending chip；ACP 轨按 #1260 的降级
//! 口径只预填可编辑文本，不承诺结构化 action。

use super::*;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum AgentCallSurface {
    Native,
    Acp,
    Initializing,
}

fn agent_call_surface(
    native_mode: bool,
    native_enabled: bool,
    has_native_view: bool,
) -> AgentCallSurface {
    if !native_mode || !native_enabled {
        AgentCallSurface::Acp
    } else if has_native_view {
        AgentCallSurface::Native
    } else {
        AgentCallSurface::Initializing
    }
}

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
        let decision = crate::agent_call::decide_delivery(
            crate::preferences::load().course_action_delivery,
            call,
            prompt,
        );
        let surface = agent_call_surface(
            self.native_chat_mode,
            Self::native_agent_enabled(),
            self.native_agent_view.is_some(),
        );

        match (surface, decision) {
            (
                AgentCallSurface::Native,
                crate::agent_call::DeliveryDecision::Compose { call, prompt },
            ) => {
                if let Some(view) = self.native_agent_view.clone() {
                    view.update(cx, |view, cx| {
                        view.compose_agent_call(call, prompt, label, window, cx);
                    });
                    cx.notify();
                } else {
                    self.show_agent_call_initializing_notice(cx);
                }
            }
            (
                AgentCallSurface::Native,
                crate::agent_call::DeliveryDecision::Send { call, prompt, .. },
            ) => {
                let sent = self.native_agent_view.clone().is_some_and(|view| {
                    view.update(cx, |view, cx| view.send_agent_call(call, prompt, cx))
                });
                if sent {
                    cx.notify();
                } else {
                    self.show_auto_send_failed_notice(cx);
                }
            }
            (AgentCallSurface::Initializing, _) => {
                self.show_agent_call_initializing_notice(cx);
            }
            (
                AgentCallSurface::Acp,
                crate::agent_call::DeliveryDecision::Compose { call, prompt },
            ) => {
                self.prefill_chat_agent_call(call, label, prompt, window, cx);
            }
            (
                AgentCallSurface::Acp,
                crate::agent_call::DeliveryDecision::Send { call, prompt, .. },
            ) => {
                if !self.send_chat_agent_call(call.clone(), prompt.clone(), cx) {
                    // Agent 忙碌或未就绪：退化为预填（FillOnly 行为），动作
                    // 保留为 pending chip 由用户空闲后确认发送；ACP 轨没有
                    // 队列泵，不自动排队。
                    self.prefill_chat_agent_call(call, label, prompt, window, cx);
                    self.show_auto_send_busy_notice(cx);
                }
            }
        }
    }

    /// CTA 预填：pending chip + 覆盖输入框（含 auto page token 的 composer
    /// context 重置）。Compose 分支与 AutoSend 忙碌退化共用。
    fn prefill_chat_agent_call(
        &mut self,
        call: crate::agent_call::AgentCall,
        label: String,
        prompt: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.chat.pending_agent_call = Some(crate::agent_call::PendingAgentCall::new(
            call,
            label,
            prompt.clone(),
        ));
        // set_value replaces the composer content, including the auto page
        // token. Reset the composer context so the next render re-attaches
        // the active page context before the CTA prompt is sent.
        self.chat.composer_context.reset();
        self.chat.input = prompt.clone();
        if let Some(input) = self.chat_input.clone() {
            input.update(cx, |input, cx| {
                input.set_value(prompt, window, cx);
                input.focus(window, cx);
            });
        }
        cx.notify();
    }

    fn show_auto_send_busy_notice(&mut self, cx: &mut Context<Self>) {
        self.pane_notice =
            Some(translate(self.language, Key::CoursesLearningAutoSendBusy).to_string());
        cx.notify();
    }

    fn show_auto_send_failed_notice(&mut self, cx: &mut Context<Self>) {
        self.pane_notice =
            Some(translate(self.language, Key::CoursesLearningAutoSendFailed).to_string());
        cx.notify();
    }

    fn show_agent_call_initializing_notice(&mut self, cx: &mut Context<Self>) {
        // Keep native mode untouched: the panel is still initializing, and
        // flipping memory without chat_state persistence desyncs the preference.
        self.pane_notice =
            Some(translate(self.language, Key::CoursesLearningAgentInitializing).to_string());
        cx.notify();
    }
}

#[cfg(test)]
mod tests {
    use super::{agent_call_surface, AgentCallSurface};

    #[test]
    fn native_cta_selects_native_surface_only_when_ready() {
        assert_eq!(
            agent_call_surface(true, true, true),
            AgentCallSurface::Native
        );
        assert_eq!(
            agent_call_surface(true, true, false),
            AgentCallSurface::Initializing
        );
        assert_eq!(agent_call_surface(false, true, true), AgentCallSurface::Acp);
        assert_eq!(agent_call_surface(true, false, true), AgentCallSurface::Acp);
    }
}
