//! B4a-3a：native 面板的非 UI 宿主状态。
//!
//! 先承载共享 agent 状态与进程内 ACP 连接；B4a-3b 再把 model/provider 选择、
//! title/audit 迁入，视图只做渲染与事件委托。

use cgc_agent_core::SelectedModel;
use cgc_agent_store::AuditLog;
use cgc_agent_tools::{register_read_only_mcp_tools_from_lease, SharedAgentState, ToolRegistry};
use cgc_platform::acp::connection::AcpHost;
use cgc_platform::mcp::credential::LearningHostLease;
use cgc_platform::mcp::inject::mcp_endpoint;

pub(crate) struct NativePanelHost {
    pub(crate) agent_state: SharedAgentState,
    pub(crate) acp_host: Option<AcpHost>,
    /// 动作审计（apply_native_agent_action 写入）。
    pub(crate) action_audit: Option<AuditLog>,
    /// 用户手动标题镜像（真实来源仍是 Agent/Thread；host 供 UI 委托查询）。
    title_override: Option<String>,
    /// 当前选择模型镜像（真实来源是 view 的 Model/Provider；host 供委托/测试）。
    selected_model: Option<SelectedModel>,
    /// 3.4c：native MCP 注入配置（endpoint + learning_host lease token）。
    mcp: Option<McpInjection>,
}

/// 3.4c：native MCP 注入配置。token 不实现 Debug，避免日志泄露。
#[derive(Clone)]
pub(crate) struct McpInjection {
    pub(crate) endpoint: String,
    pub(crate) token: String,
}

impl std::fmt::Debug for McpInjection {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("McpInjection")
            .field("endpoint", &self.endpoint)
            .field("token", &"<redacted>")
            .finish()
    }
}

/// native MCP 的 server 名（与 ACP 注入的 codex/claude 名称对齐）。
pub(crate) const NATIVE_MCP_SERVER: &str = "cgc-2046-learning";

/// 解析 native MCP 注入配置（纯函数，env 覆盖优先，便于 headless e2e）。
///
/// 优先级：`CGC_MCP_ENDPOINT` + `CGC_MCP_TOKEN`（测试/调试 seam）> lease + api_url
/// （与 ACP 注入同源：`mcp_endpoint(CGC_API_URL)`）。无 token 一律 None（fail-closed）。
pub(crate) fn resolve_mcp_injection(
    lease: Option<&LearningHostLease>,
    api_url: Option<&str>,
    env_endpoint: Option<&str>,
    env_token: Option<&str>,
) -> Option<McpInjection> {
    if let Some(token) = env_token.filter(|token| !token.trim().is_empty()) {
        let endpoint = env_endpoint
            .map(str::to_string)
            .unwrap_or_else(|| mcp_endpoint(api_url));
        return Some(McpInjection {
            endpoint,
            token: token.to_string(),
        });
    }
    let lease = lease?;
    Some(McpInjection {
        endpoint: mcp_endpoint(api_url),
        token: lease.token.clone(),
    })
}

impl NativePanelHost {
    pub(crate) fn new(agent_state: SharedAgentState) -> Self {
        Self {
            agent_state,
            acp_host: None,
            action_audit: None,
            title_override: None,
            selected_model: None,
            mcp: None,
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
            mcp: None,
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

    /// controller 接线：用 RootView 已持有的 lease 注入（不重复请求平台）。
    pub(crate) fn set_mcp_lease(
        &mut self,
        lease: Option<LearningHostLease>,
        api_url: Option<&str>,
    ) {
        self.mcp = resolve_mcp_injection(
            lease.as_ref(),
            api_url,
            std::env::var("CGC_MCP_ENDPOINT").ok().as_deref(),
            std::env::var("CGC_MCP_TOKEN").ok().as_deref(),
        );
    }

    /// 测试/调试 seam：直接注入 endpoint + token。
    #[cfg(test)]
    pub(crate) fn set_mcp_injection(
        &mut self,
        endpoint: impl Into<String>,
        token: impl Into<String>,
    ) {
        self.mcp = Some(McpInjection {
            endpoint: endpoint.into(),
            token: token.into(),
        });
    }

    pub(crate) fn mcp_injection(&self) -> Option<&McpInjection> {
        self.mcp.as_ref()
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

/// 3.4c：把 host 的 MCP 配置注册进 native ToolRegistry（无配置 = 0 个，fail-closed）。
pub(crate) fn register_mcp_tools_for_host(
    registry: &mut ToolRegistry,
    host: &NativePanelHost,
) -> usize {
    let Some(injection) = host.mcp_injection() else {
        return 0;
    };
    register_read_only_mcp_tools_from_lease(
        registry,
        NATIVE_MCP_SERVER,
        &injection.endpoint,
        Some(&injection.token),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
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
    fn spawn_mcp_mock(responses: Vec<&'static str>) -> (String, std::sync::mpsc::Receiver<String>) {
        use std::io::{Read, Write};
        use std::net::TcpListener;
        use std::sync::mpsc;
        use std::time::Duration;
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let addr = listener.local_addr().expect("addr");
        let (sender, receiver) = mpsc::channel();
        std::thread::spawn(move || {
            for body in responses {
                let Ok((mut stream, _)) = listener.accept() else {
                    break;
                };
                let mut buffer = [0u8; 4096];
                let mut request = Vec::new();
                let mut content_length = 0usize;
                let mut header_end = None;
                while let Ok(read) = stream.read(&mut buffer) {
                    if read == 0 {
                        break;
                    }
                    request.extend_from_slice(&buffer[..read]);
                    if header_end.is_none() {
                        if let Some(position) = request.windows(4).position(|w| w == b"\r\n\r\n") {
                            header_end = Some(position + 4);
                            let headers = String::from_utf8_lossy(&request[..position]).to_string();
                            content_length = headers
                                .lines()
                                .find_map(|line| {
                                    let (name, value) = line.split_once(':')?;
                                    name.eq_ignore_ascii_case("content-length")
                                        .then(|| value.trim().parse::<usize>().ok())
                                        .flatten()
                                })
                                .unwrap_or(0);
                            if content_length == 0 {
                                let _ = stream.set_read_timeout(Some(Duration::from_millis(200)));
                            }
                        }
                    }
                    if let Some(end) = header_end {
                        if content_length > 0 && request.len() >= end + content_length {
                            break;
                        }
                    }
                }
                let _ = sender.send(String::from_utf8_lossy(&request).to_string());
                let response = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                );
                let _ = stream.write_all(response.as_bytes());
                let _ = stream.flush();
            }
        });
        (format!("http://{addr}/mcp"), receiver)
    }

    fn init_body() -> &'static str {
        r#"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","serverInfo":{"name":"cgc"}}}"#
    }

    fn tools_body() -> &'static str {
        r#"{"jsonrpc":"2.0","id":2,"result":{"tools":[
            {"name":"get_course_content","description":"课程正文","inputSchema":{"type":"object"}},
            {"name":"get_course_revision","inputSchema":{"type":"object"}},
            {"name":"get_learning_state","inputSchema":{"type":"object"}},
            {"name":"get_role_playbook","inputSchema":{"type":"object"}},
            {"name":"get_enrollment_summary","inputSchema":{"type":"object"}},
            {"name":"delete_everything","inputSchema":{"type":"object"}}
        ]}}"#
    }

    #[test]
    fn resolve_injection_prefers_env_then_lease() {
        let lease = LearningHostLease {
            token: "lease-token".into(),
            token_id: "tok".into(),
            epoch: 1,
        };
        let from_lease = resolve_mcp_injection(
            Some(&lease),
            Some("https://cgc.example.com/api/graphql"),
            None,
            None,
        )
        .expect("lease injection");
        assert_eq!(from_lease.endpoint, "https://cgc.example.com/mcp");
        assert_eq!(from_lease.token, "lease-token");

        let from_env = resolve_mcp_injection(
            None,
            None,
            Some("http://127.0.0.1:9/mcp"),
            Some("env-token"),
        )
        .expect("env injection");
        assert_eq!(from_env.endpoint, "http://127.0.0.1:9/mcp");
        assert_eq!(from_env.token, "env-token");

        assert!(resolve_mcp_injection(None, None, None, None).is_none());
        assert!(resolve_mcp_injection(None, None, Some("x"), Some("  ")).is_none());
    }

    #[test]
    fn native_registry_gets_only_whitelisted_mcp_tools_and_calls_work() {
        use cgc_agent_tools::{ToolContext, ToolRegistry};
        use futures::executor::block_on;
        let (endpoint, _requests) = spawn_mcp_mock(vec![
            init_body(),
            tools_body(),
            r#"{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"MCP 正文"}]}}"#,
        ]);
        let mut host = host();
        host.set_mcp_injection(endpoint, "lease-token");
        let mut registry = ToolRegistry::new();
        let count = register_mcp_tools_for_host(&mut registry, &host);
        assert_eq!(count, 5, "5 个白名单工具全部注册");
        assert!(registry
            .get("mcp:cgc-2046-learning:get_course_content")
            .is_some());
        assert!(registry
            .get("mcp:cgc-2046-learning:delete_everything")
            .is_none());

        let result = block_on(registry.run(
            "mcp:cgc-2046-learning:get_course_content",
            serde_json::json!({"course_id": "crs-002"}),
            ToolContext::new("/tmp"),
        ))
        .expect("run mcp tool");
        assert_eq!(result.content, "MCP 正文");
        assert!(!result.is_error);
    }

    #[test]
    fn no_injection_registers_zero_tools() {
        let mut host = host();
        host.set_mcp_lease(None, None);
        let mut registry = ToolRegistry::new();
        assert_eq!(register_mcp_tools_for_host(&mut registry, &host), 0);
        assert!(registry.schemas().is_empty());
    }

    #[test]
    fn injection_debug_redacts_token() {
        let mut host = host();
        host.set_mcp_injection("http://127.0.0.1:9/mcp", "super-secret-token");
        let debug = format!("{:?}", host.mcp_injection().expect("injection"));
        assert!(debug.contains("<redacted>"));
        assert!(!debug.contains("super-secret-token"));
    }
}
