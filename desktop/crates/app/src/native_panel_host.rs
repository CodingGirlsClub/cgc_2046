//! B4a-3a：native 面板的非 UI 宿主状态。
//!
//! 先承载共享 agent 状态与进程内 ACP 连接；B4a-3b 再把 model/provider 选择、
//! title/audit 迁入，视图只做渲染与事件委托。

use cgc_agent_tools::SharedAgentState;
use cgc_platform::acp::connection::AcpHost;

pub(crate) struct NativePanelHost {
    pub(crate) agent_state: SharedAgentState,
    pub(crate) acp_host: Option<AcpHost>,
}

impl NativePanelHost {
    pub(crate) fn new(agent_state: SharedAgentState) -> Self {
        Self {
            agent_state,
            acp_host: None,
        }
    }

    pub(crate) fn has_agent_state(&self) -> bool {
        self.agent_state.try_lock().is_ok()
    }

    pub(crate) fn set_acp_host(&mut self, host: Option<AcpHost>) {
        self.acp_host = host;
    }

    pub(crate) fn acp_connected(&self) -> bool {
        self.acp_host.is_some()
    }
}

#[cfg(test)]
mod tests {
    use super::NativePanelHost;
    use cgc_agent_tools::{AgentState, SharedAgentState};
    use std::sync::{Arc, Mutex};

    fn host() -> NativePanelHost {
        let state: SharedAgentState = Arc::new(Mutex::new(AgentState::default()));
        NativePanelHost::new(state)
    }

    #[test]
    fn host_initializes_with_agent_state_and_no_acp() {
        let host = host();
        assert!(host.has_agent_state());
        assert!(!host.acp_connected());
    }

    #[test]
    fn set_acp_host_tracks_connection_flag() {
        let mut host = host();
        host.set_acp_host(None);
        assert!(!host.acp_connected());
    }
}
