//! ACP `mcpServers` 注入（story 5.5）：只在 `session/new` / `session/load` 注入 CGC MCP。
//!
//! - 名称按 agent 固定：OMP `cgc-2046`，Codex / Claude Code `cgc-2046-learning`；
//! - 凭证用 2.8 的 learning_host lease，放 `Authorization: Bearer <token>`；
//! - 不写用户 `mcp.json`/agent 配置；不注入第二个凭证或第三方 server。

use agent_client_protocol::schema::v1::{HttpHeader, McpServer, McpServerHttp, NewSessionRequest};
use std::path::Path;

use crate::mcp::credential::LearningHostLease;
use crate::registry::manifest::AgentEntry;

/// 由 GraphQL 端点推导 MCP 端点：`…/api/graphql` → `…/mcp`，否则补 `/mcp`。
pub fn mcp_endpoint(api_url: Option<&str>) -> String {
    let base = api_url.unwrap_or("http://localhost:4000/api/graphql");
    let base = base.trim_end_matches('/');
    if let Some(prefix) = base.strip_suffix("/api/graphql") {
        return format!("{prefix}/mcp");
    }
    if let Some(prefix) = base.strip_suffix("/graphql") {
        return format!("{prefix}/mcp");
    }
    format!("{base}/mcp")
}

/// 构造单个 CGC MCP server 配置；返回对象含明文凭证，禁止 Debug/日志输出。
pub fn build_mcp_server(
    entry: &AgentEntry,
    lease: &LearningHostLease,
    endpoint: &str,
) -> McpServer {
    let server =
        McpServerHttp::new(entry.mcp_server_name.clone(), endpoint).headers(vec![HttpHeader::new(
            "Authorization",
            format!("Bearer {}", lease.token),
        )]);
    McpServer::Http(server)
}

/// 组装 create/new session 请求（注入点唯一；测试可断言序列化结果）。
pub fn new_session_request(
    cwd: &Path,
    entry: &AgentEntry,
    lease: &LearningHostLease,
    endpoint: &str,
) -> NewSessionRequest {
    NewSessionRequest::new(cwd.to_path_buf())
        .mcp_servers(vec![build_mcp_server(entry, lease, endpoint)])
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::registry::manifest::Registry;

    fn lease() -> LearningHostLease {
        LearningHostLease {
            token: "cgch_test_token".to_string(),
            token_id: "tok-1".to_string(),
            epoch: 3,
        }
    }

    #[test]
    fn endpoint_is_derived_from_graphql_url() {
        assert_eq!(
            mcp_endpoint(Some("http://127.0.0.1:4000/api/graphql")),
            "http://127.0.0.1:4000/mcp"
        );
        assert_eq!(
            mcp_endpoint(Some("https://cgc.example.com/api/graphql")),
            "https://cgc.example.com/mcp"
        );
        assert_eq!(
            mcp_endpoint(Some("https://cgc.example.com")),
            "https://cgc.example.com/mcp"
        );
        assert_eq!(mcp_endpoint(None), "http://localhost:4000/mcp");
    }

    #[test]
    fn server_name_matches_agent_contract() {
        let registry = Registry::builtin().expect("registry");
        let omp = build_mcp_server(
            registry.get("omp").expect("omp"),
            &lease(),
            "http://127.0.0.1:4000/mcp",
        );
        let codex = build_mcp_server(
            registry.get("codex").expect("codex"),
            &lease(),
            "http://127.0.0.1:4000/mcp",
        );
        match omp {
            McpServer::Http(http) => assert_eq!(http.name, "cgc-2046"),
            other => panic!("unexpected transport: {other:?}"),
        }
        match codex {
            McpServer::Http(http) => assert_eq!(http.name, "cgc-2046-learning"),
            other => panic!("unexpected transport: {other:?}"),
        }
    }

    #[test]
    fn session_request_carries_single_authorized_server() {
        let registry = Registry::builtin().expect("registry");
        let request = new_session_request(
            Path::new("/tmp"),
            registry.get("codex").expect("codex"),
            &lease(),
            "https://cgc.example.com/mcp",
        );
        assert_eq!(request.mcp_servers.len(), 1);
        let McpServer::Http(http) = &request.mcp_servers[0] else {
            panic!("expected http server");
        };
        assert_eq!(http.name, "cgc-2046-learning");
        assert_eq!(http.url, "https://cgc.example.com/mcp");
        assert_eq!(http.headers.len(), 1);
        assert_eq!(http.headers[0].name, "Authorization");
        assert_eq!(http.headers[0].value, "Bearer cgch_test_token");
    }

    #[test]
    fn empty_lease_epoch_still_injects_but_is_tracked() {
        let registry = Registry::builtin().expect("registry");
        let lease = LearningHostLease {
            token: "cgch_x".to_string(),
            token_id: "tok-x".to_string(),
            epoch: 0,
        };
        let request = new_session_request(
            Path::new("/tmp"),
            registry.get("omp").expect("omp"),
            &lease,
            "http://localhost:4000/mcp",
        );
        assert_eq!(request.mcp_servers.len(), 1);
    }
}
