//! 拉取官方 ACP / MCP Registry（发现层）并打印摘要；不安装任何条目。
fn main() {
    let acp_url = std::env::var("CGC_ACP_REGISTRY_URL")
        .unwrap_or_else(|_| cgc_platform::registry::discovery::ACP_REGISTRY_URL.to_string());
    let mcp_url = std::env::var("CGC_MCP_REGISTRY_URL")
        .unwrap_or_else(|_| cgc_platform::registry::discovery::MCP_REGISTRY_URL.to_string());
    let timeout = std::time::Duration::from_secs(20);

    match cgc_platform::registry::discovery::fetch_acp_registry(&acp_url, timeout) {
        Ok(agents) => {
            println!(
                "official ACP registry: {} agents (discovery only)",
                agents.len()
            );
            for agent in agents.iter().take(5) {
                println!(
                    "- {} {} ({:?})",
                    agent.id, agent.version, agent.distribution
                );
            }
        }
        Err(error) => {
            eprintln!("ACP discovery failed: {error}");
            std::process::exit(1);
        }
    }

    match cgc_platform::registry::discovery::fetch_mcp_registry(&mcp_url, timeout) {
        Ok(servers) => {
            println!(
                "official MCP registry: {} active servers (discovery only)",
                servers.len()
            );
            for server in servers.iter().take(5) {
                println!(
                    "- {} {} ({:?})",
                    server.name,
                    server.version,
                    server.remotes.first()
                );
            }
        }
        Err(error) => {
            eprintln!("MCP discovery failed: {error}");
            std::process::exit(1);
        }
    }
}
