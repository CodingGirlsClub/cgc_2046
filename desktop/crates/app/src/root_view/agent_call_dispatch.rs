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

        match agent_call_surface(
            self.native_chat_mode,
            Self::native_agent_enabled(),
            self.native_agent_view.is_some(),
        ) {
            AgentCallSurface::Native => {
                if let Some(view) = self.native_agent_view.clone() {
                    view.update(cx, |view, cx| {
                        view.compose_agent_call(call, prompt, label, window, cx);
                    });
                    cx.notify();
                    return;
                }
                self.show_agent_call_initializing_notice(cx);
            }
            AgentCallSurface::Initializing => {
                self.show_agent_call_initializing_notice(cx);
            }
            AgentCallSurface::Acp => {
                self.chat.pending_agent_call = Some(crate::agent_call::PendingAgentCall::new(
                    call,
                    label,
                    prompt.clone(),
                ));
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
