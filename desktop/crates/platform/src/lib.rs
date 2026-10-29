//! CGC Desktop 的 platform 层：定义端口 trait，不依赖任何具体 OS 实现（脊柱 AD-1）。
//!
//! 模块划分对齐 Zed：`acp` 是协议/线程抽象（Zed `acp_thread`），`agent` 是接入与启动
//! （Zed `agent_servers`），`mcp` 是 MCP 注入（Zed `context_server` 的简化），`registry`
//! 是清单/校验/安装。我们不实现 native agent、LLM 客户端与工具沙箱（BYO）。

pub mod acp;
pub mod agent;
pub mod api;
pub mod events;
pub mod instance;
pub mod logging;
pub mod mcp;
pub mod notifications;
pub mod paths;
pub mod registry;
pub mod routes;
pub mod runtime;
pub mod session;
pub mod telemetry;
pub mod tray;
pub mod workspace;
