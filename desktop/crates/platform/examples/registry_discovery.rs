//! 拉取官方 ACP Registry（发现层）并打印摘要；不安装任何条目。
fn main() {
    let url = std::env::var("CGC_ACP_REGISTRY_URL")
        .unwrap_or_else(|_| cgc_platform::registry::discovery::ACP_REGISTRY_URL.to_string());
    match cgc_platform::registry::discovery::fetch_acp_registry(
        &url,
        std::time::Duration::from_secs(20),
    ) {
        Ok(agents) => {
            println!(
                "official ACP registry: {} agents (discovery only)",
                agents.len()
            );
            for agent in agents.iter().take(8) {
                println!(
                    "- {} {} ({:?})",
                    agent.id, agent.version, agent.distribution
                );
            }
        }
        Err(error) => {
            eprintln!("discovery failed: {error}");
            std::process::exit(1);
        }
    }
}
