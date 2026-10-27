//! Native runtime construction resources and revocable platform authorization.
//! Connection state belongs to ConversationSession; execution belongs to the owner.

use cgc_agent_store::AuditLog;
use cgc_agent_tools::mcp::McpLeaseGuard;
use cgc_agent_tools::{discover_read_only_mcp_tools_with, SharedAgentState, Tool};
use cgc_platform::mcp::{
    client::{McpClientError, McpHttpClient},
    credential::LearningHostLease,
    inject::mcp_endpoint,
};
use std::sync::Arc;

/// 子 agent 卡片状态（P2 实时进度；ACP v1 无对应 update，走 native 辅助通道）。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SubagentCard {
    pub task: String,
    pub text: String,
    /// `None` 表示仍在运行。
    pub finished: Option<bool>,
    /// 触发该子 agent 的 task tool call id。
    pub tool_call_id: Option<String>,
}

pub(crate) struct NativePanelHost {
    pub(crate) agent_state: SharedAgentState,
    pub(crate) action_audit: Option<AuditLog>,
    mcp: Option<McpContext>,
}

/// Full lease identity and its local revocation signal. Never serializable or Debug.
#[derive(Clone)]
pub(crate) struct McpContext(Arc<McpContextData>);

struct McpContextData {
    lease: LearningHostLease,
    epoch: u64,
    endpoint: String,
    workspace_id: Option<String>,
    guard: McpLeaseGuard,
}

impl McpContext {
    pub(crate) fn for_lease(
        lease: LearningHostLease,
        epoch: u64,
        api_url: Option<&str>,
        workspace_id: Option<&str>,
    ) -> Option<Self> {
        if lease.epoch != epoch || lease.token.trim().is_empty() {
            return None;
        }
        Some(Self(Arc::new(McpContextData {
            lease,
            epoch,
            endpoint: mcp_endpoint(api_url),
            workspace_id: workspace_id
                .map(str::trim)
                .filter(|id| !id.is_empty())
                .map(str::to_string),
            guard: McpLeaseGuard::new(),
        })))
    }
    pub(crate) fn lease(&self) -> &LearningHostLease {
        &self.0.lease
    }
    pub(crate) fn epoch(&self) -> u64 {
        self.0.epoch
    }
    pub(crate) fn revoke(&self) {
        self.0.guard.revoke();
    }
    pub(crate) fn is_revoked(&self) -> bool {
        self.0.guard.is_revoked()
    }

    pub(crate) fn same_authority(&self, other: &Self) -> bool {
        Arc::ptr_eq(&self.0, &other.0)
    }

    pub(crate) fn discover_tools(&self) -> Result<Vec<Arc<dyn Tool>>, McpClientError> {
        if self.is_revoked() {
            return Err(McpClientError::Transport("平台授权已撤销".into()));
        }
        let injected = self
            .0
            .workspace_id
            .as_ref()
            .map(|id| serde_json::json!({ "workspace_id": id }));
        let client = McpHttpClient::new(&self.0.endpoint).with_bearer_token(&self.0.lease.token);
        let tools = discover_read_only_mcp_tools_with(
            NATIVE_MCP_SERVER,
            client,
            injected,
            Some(self.0.guard.clone()),
        )?;
        if self.is_revoked() {
            return Err(McpClientError::Transport("平台授权已撤销".into()));
        }
        Ok(tools)
    }
}

pub(crate) const NATIVE_MCP_SERVER: &str = "cgc-2046-learning";

impl NativePanelHost {
    pub(crate) fn new(agent_state: SharedAgentState, action_audit: Option<AuditLog>) -> Self {
        Self {
            agent_state,
            action_audit,
            mcp: None,
        }
    }

    pub(crate) fn set_mcp_context(&mut self, context: Option<McpContext>) -> bool {
        let context = context.filter(|context| !context.is_revoked());
        match (&self.mcp, &context) {
            (None, None) => return false,
            (Some(current), Some(next)) if current.same_authority(next) => return false,
            _ => {}
        }
        if let Some(previous) = self.mcp.take() {
            previous.revoke();
        }
        self.mcp = context;
        true
    }

    pub(crate) fn mcp_context(&self) -> Option<&McpContext> {
        self.mcp.as_ref()
    }
}

#[cfg(test)]
mod tests;
