//! MCP 注入（Zed `context_server` 的简化）：只在 \`session/new\` 与 \`session/load\` 注入 CGC MCP，不写用户配置。

pub mod credential;
pub mod inject;
