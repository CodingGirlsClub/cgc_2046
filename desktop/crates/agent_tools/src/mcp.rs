//! 3.4b：MCP 工具适配 —— 把 MCP server 的只读工具包装成第一方 `Tool`。
//!
//! 白名单 fail-closed：只有 5 个只读课程工具会被注册；其它工具一律不暴露给模型。
//! MCP 调用失败（超时/401/403/协议错误/isError）以 error 文本回灌模型，不 panic。
//!
//! Layering：本模块依赖 `cgc_platform::mcp::client`（client 是最底层传输，
//! 不依赖 agent_tools，无环）。

use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc, Mutex,
};

use cgc_platform::mcp::client::{McpClientError, McpHttpClient};
use futures::future::BoxFuture;
use futures::FutureExt as _;
use serde_json::Value;

use crate::approval::Approval;
use crate::error::ToolError;
use crate::tool::{Tool, ToolContext, ToolResult};

/// Revokes already-captured MCP clients without exposing or copying their secret.
#[derive(Clone, Default)]
pub struct McpLeaseGuard(Arc<AtomicBool>);

impl McpLeaseGuard {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn revoke(&self) {
        self.0.store(true, Ordering::SeqCst);
    }
    pub fn is_revoked(&self) -> bool {
        self.0.load(Ordering::SeqCst)
    }
    pub fn same_as(&self, other: &Self) -> bool {
        Arc::ptr_eq(&self.0, &other.0)
    }
}

/// 只读课程工具白名单（3.4b；白名单外一律不注册）。
pub const READ_ONLY_MCP_TOOLS: [&str; 5] = [
    "get_course_content",
    "get_course_revision",
    "get_learning_state",
    "get_role_playbook",
    "get_enrollment_summary",
];

/// 是否在白名单内（纯函数，fail-closed）。
pub fn is_read_only_mcp_tool(name: &str) -> bool {
    READ_ONLY_MCP_TOOLS.contains(&name)
}

/// 把客户端注入的固定参数补进模型给出的 args（仅补齐缺失的顶层字段）。
///
/// 只读课程工具的后端 schema 要求 `workspace_id`，而模型上下文里通常没有，
/// 由客户端注入当前工作台，避免工具因缺参不可用。
pub fn merge_injected_args(mut args: Value, injected: Option<&Value>) -> Value {
    let (Some(injected), Some(object)) = (injected, args.as_object_mut()) else {
        return args;
    };
    if let Some(defaults) = injected.as_object() {
        for (key, value) in defaults {
            // 空串/null 等同于未提供：模型常按 schema 先塞一个占位值
            // （真机 3.4d：workspace_id="" 直接导致后端 `failed to load course`）。
            let missing = match object.get(key) {
                None => true,
                Some(Value::Null) => true,
                Some(Value::String(text)) => text.trim().is_empty(),
                Some(_) => false,
            };
            if missing {
                object.insert(key.clone(), value.clone());
            }
        }
    }
    args
}

/// 一个 MCP 工具的第一方包装。
pub struct McpTool {
    name: String,
    description: String,
    schema: Value,
    remote_name: String,
    client: Arc<Mutex<McpHttpClient>>,
    /// 客户端已知的固定参数（如当前 `workspace_id`）：仅补齐 args 中缺失的
    /// 顶层字符串字段，不覆盖模型显式给出的值。
    injected: Option<Value>,
    lease_guard: Option<McpLeaseGuard>,
}

impl Tool for McpTool {
    fn name(&self) -> &str {
        &self.name
    }

    fn description(&self) -> &str {
        &self.description
    }

    fn schema(&self) -> Value {
        self.schema.clone()
    }

    /// 白名单内全部是只读课程工具：默认 Allow，不弹审批卡。
    fn approval(&self, _args: &Value) -> Approval {
        if self
            .lease_guard
            .as_ref()
            .is_some_and(McpLeaseGuard::is_revoked)
        {
            Approval::Deny("平台授权已撤销".into())
        } else {
            Approval::Allow
        }
    }

    fn run(
        &self,
        args: Value,
        _context: ToolContext,
    ) -> BoxFuture<'static, Result<ToolResult, ToolError>> {
        if self
            .lease_guard
            .as_ref()
            .is_some_and(McpLeaseGuard::is_revoked)
        {
            return async { Ok(ToolResult::error("平台授权已撤销，请重新登录")) }.boxed();
        }
        let lease_guard = self.lease_guard.clone();
        let client = self.client.clone();
        let remote_name = self.remote_name.clone();
        let args = merge_injected_args(args, self.injected.as_ref());
        async move {
            let (sender, receiver) = futures::channel::oneshot::channel();
            let worker_guard = lease_guard.clone();
            // MCP client 是同步（ureq）实现；放到独立线程避免阻塞工具执行器。
            std::thread::spawn(move || {
                let result = match client.lock() {
                    Ok(mut client) => {
                        if worker_guard.as_ref().is_some_and(McpLeaseGuard::is_revoked) {
                            Err(McpClientError::Transport("平台授权已撤销".into()))
                        } else {
                            client.call_tool(&remote_name, args)
                        }
                    }
                    Err(_) => Err(McpClientError::Transport("MCP client 锁中毒".to_string())),
                };
                let _ = sender.send(result);
            });
            let response = receiver.await;
            if lease_guard.as_ref().is_some_and(McpLeaseGuard::is_revoked) {
                return Ok(ToolResult::error("平台授权已撤销，已丢弃旧授权的返回结果"));
            }
            match response {
                Ok(Ok(text)) => Ok(ToolResult::ok(text)),
                Ok(Err(error)) => Ok(ToolResult::error(format!("MCP 调用失败：{error}"))),
                Err(_) => Ok(ToolResult::error("MCP 调用被取消".to_string())),
            }
        }
        .boxed()
    }
}

/// provider 要求 function name 匹配 `^[a-zA-Z0-9_-]+$`（不接受 `:`/`.` 等），
/// 因此工具名用 `mcp_<server>_<tool>` 并把非法字符替换为 `_`。
fn mcp_tool_name(server_name: &str, tool_name: &str) -> String {
    let raw = format!("mcp_{server_name}_{tool_name}");
    raw.chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '_' || c == '-' {
                c
            } else {
                '_'
            }
        })
        .collect()
}

/// 连接 MCP server、握手、拉取 tools/list，并按白名单包装成工具。
///
/// 握手/列表失败保留诊断错误且不注册任何工具；白名单外、schema 非法的工具跳过。
pub fn discover_read_only_mcp_tools(
    server_name: &str,
    client: McpHttpClient,
) -> Result<Vec<Arc<dyn Tool>>, McpClientError> {
    discover_read_only_mcp_tools_with(server_name, client, None, None)
}

/// 同 [`discover_read_only_mcp_tools`]，额外注入固定参数（如 `workspace_id`）。
pub fn discover_read_only_mcp_tools_with(
    server_name: &str,
    mut client: McpHttpClient,
    injected: Option<Value>,
    lease_guard: Option<McpLeaseGuard>,
) -> Result<Vec<Arc<dyn Tool>>, McpClientError> {
    client.initialize("cgc-desktop", env!("CARGO_PKG_VERSION"))?;
    let tools = client.list_tools()?;
    let client = Arc::new(Mutex::new(client));
    Ok(tools
        .into_iter()
        .filter(|tool| is_read_only_mcp_tool(&tool.name))
        .filter_map(|tool| {
            let schema = valid_tool_schema(&tool.input_schema)?;
            let name = mcp_tool_name(server_name, &tool.name);
            let description = tool
                .description
                .unwrap_or_else(|| format!("MCP 只读工具 {}", tool.name));
            Some(Arc::new(McpTool {
                name,
                description,
                schema,
                remote_name: tool.name,
                client: client.clone(),
                injected: injected.clone(),
                lease_guard: lease_guard.clone(),
            }) as Arc<dyn Tool>)
        })
        .collect())
}

/// 把白名单内的 MCP 工具注册进 registry（返回注册数量）。
pub fn register_read_only_mcp_tools(
    registry: &mut crate::registry::ToolRegistry,
    server_name: &str,
    client: McpHttpClient,
) -> Result<usize, McpClientError> {
    register_read_only_mcp_tools_with(registry, server_name, client, None, None)
}

/// 同 [`register_read_only_mcp_tools`]，额外注入固定参数（如 `workspace_id`）。
pub fn register_read_only_mcp_tools_with(
    registry: &mut crate::registry::ToolRegistry,
    server_name: &str,
    client: McpHttpClient,
    injected: Option<Value>,
    lease_guard: Option<McpLeaseGuard>,
) -> Result<usize, McpClientError> {
    let tools = discover_read_only_mcp_tools_with(server_name, client, injected, lease_guard)?;
    let count = tools.len();
    for tool in tools {
        registry.register(tool);
    }
    Ok(count)
}

/// 同源配置入口：endpoint（`platform::mcp::inject::mcp_endpoint`）+ lease token。
///
/// 无 token/空 token 时不建连、不注册；连接错误交给调用者展示，不伪装成空授权集。
pub fn register_read_only_mcp_tools_from_lease(
    registry: &mut crate::registry::ToolRegistry,
    server_name: &str,
    endpoint: &str,
    token: Option<&str>,
) -> Result<usize, McpClientError> {
    register_read_only_mcp_tools_from_lease_with(registry, server_name, endpoint, token, None, None)
}

/// 同 [`register_read_only_mcp_tools_from_lease`]，额外注入固定参数。
pub fn register_read_only_mcp_tools_from_lease_with(
    registry: &mut crate::registry::ToolRegistry,
    server_name: &str,
    endpoint: &str,
    token: Option<&str>,
    injected: Option<Value>,
    lease_guard: Option<McpLeaseGuard>,
) -> Result<usize, McpClientError> {
    let Some(token) = token.filter(|token| !token.trim().is_empty()) else {
        return Ok(0);
    };
    let client = McpHttpClient::new(endpoint).with_bearer_token(token);
    register_read_only_mcp_tools_with(registry, server_name, client, injected, lease_guard)
}

/// MCP `inputSchema` 必须是 object；缺失/非法（Null/非 object）→ 跳过该工具。
fn valid_tool_schema(schema: &Value) -> Option<Value> {
    schema.is_object().then(|| schema.clone())
}

#[cfg(test)]
mod tests;
