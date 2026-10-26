//! B4a-3a：native 面板的非 UI 宿主状态。
//!
//! 先承载共享 agent 状态与进程内 ACP 连接；B4a-3b 再把 model/provider 选择、
//! title/audit 迁入，视图只做渲染与事件委托。

use cgc_agent_core::SelectedModel;
use cgc_agent_store::AuditLog;
use cgc_agent_tools::SharedAgentState;
use cgc_platform::acp::connection::AcpHost;

pub(crate) struct NativePanelHost {
    pub(crate) agent_state: SharedAgentState,
    pub(crate) acp_host: Option<AcpHost>,
    /// 动作审计（apply_native_agent_action 写入）。
    pub(crate) action_audit: Option<AuditLog>,
    /// 用户手动标题镜像（真实来源仍是 Agent/Thread；host 供 UI 委托查询）。
    title_override: Option<String>,
    /// 当前选择模型镜像（真实来源是 view 的 Model/Provider；host 供委托/测试）。
    selected_model: Option<SelectedModel>,
}

impl NativePanelHost {
    pub(crate) fn new(agent_state: SharedAgentState) -> Self {
        Self {
            agent_state,
            acp_host: None,
            action_audit: None,
            title_override: None,
            selected_model: None,
        }
    }

    /// controller 接线用：注入已构造的 agent_state + 审计日志。
    pub(crate) fn new_with_audit(agent_state: SharedAgentState, audit: Option<AuditLog>) -> Self {
        Self {
            agent_state,
            acp_host: None,
            action_audit: audit,
            title_override: None,
            selected_model: None,
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

    pub(crate) fn set_action_audit(&mut self, audit: Option<AuditLog>) {
        self.action_audit = audit;
    }

    pub(crate) fn set_title_override(&mut self, title: Option<String>) {
        self.title_override = title;
    }

    pub(crate) fn set_selected_model(&mut self, model: SelectedModel) {
        self.selected_model = Some(model);
    }

    #[cfg(test)]
    pub(crate) fn title_override(&self) -> Option<&str> {
        self.title_override.as_deref()
    }

    #[cfg(test)]
    pub(crate) fn selected_model(&self) -> Option<&SelectedModel> {
        self.selected_model.as_ref()
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
    fn new_with_audit_exposes_audit_path() {
        use cgc_agent_tools::{AgentState, SharedAgentState};
        use std::sync::{Arc, Mutex};
        let state: SharedAgentState = Arc::new(Mutex::new(AgentState::default()));
        let host = NativePanelHost::new_with_audit(
            state,
            Some(cgc_agent_store::AuditLog::new("/tmp/cgc-audit.jsonl")),
        );
        assert!(host.has_agent_state());
        assert_eq!(
            host.action_audit.as_ref().map(|audit| audit.path()),
            Some(std::path::Path::new("/tmp/cgc-audit.jsonl"))
        );
    }

    #[test]
    fn title_override_set_and_clear() {
        let mut host = host();
        assert_eq!(host.title_override(), None);
        host.set_title_override(Some("我的标题".into()));
        assert_eq!(host.title_override(), Some("我的标题"));
        host.set_title_override(None);
        assert_eq!(host.title_override(), None);
    }

    #[test]
    fn selected_model_delegation() {
        let mut host = host();
        assert!(host.selected_model().is_none());
        host.set_selected_model(cgc_agent_core::SelectedModel::new(
            cgc_agent_provider::ProviderId::new("p"),
            cgc_agent_provider::ModelId::new("m"),
        ));
        let selected = host.selected_model().expect("selected");
        assert_eq!(
            selected.provider_id,
            cgc_agent_provider::ProviderId::new("p")
        );
        assert_eq!(selected.model_id, cgc_agent_provider::ModelId::new("m"));
    }

    #[test]
    fn set_acp_host_tracks_connection_flag() {
        let mut host = host();
        host.set_acp_host(None);
        assert!(!host.acp_connected());
    }
}
