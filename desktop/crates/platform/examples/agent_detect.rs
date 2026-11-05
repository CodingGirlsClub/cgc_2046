//! Story 5.3 的探测 HITL：加载内置签名清单并探测本机 agent / Node runtime。
//! 用法：`cargo run -p cgc-platform --example agent_detect`

use cgc_platform::agent::detect::{detect_all, detect_node, AgentStatus};
use cgc_platform::agent::launch::NodeRuntime;
use cgc_platform::agent::node_runtime::NodeRuntimeManager;
use cgc_platform::registry::manifest::Registry;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let registry = Registry::builtin()?;
    let runtime = NodeRuntime::new(NodeRuntimeManager::default_manager().root);
    let node = detect_node(Some(&runtime), &registry.node_required);
    println!(
        "registry: {} agents, node required {}, found {:?}",
        registry.agents.len(),
        node.required,
        node.found
    );
    for detected in detect_all(&registry, Some(&runtime)) {
        let status = match &detected.status {
            AgentStatus::Ready { version } => format!("ready {version}"),
            AgentStatus::Missing => "missing".to_string(),
            AgentStatus::Outdated { found, required } => {
                format!("outdated {found} < {required}")
            }
            AgentStatus::NodeUnavailable { required, found } => {
                format!("node unavailable (need {required}, found {found:?})")
            }
            AgentStatus::Error(reason) => format!("error: {reason}"),
        };
        println!(
            "{} ({}) → {} [mcp={}]",
            detected.entry.display_name, detected.entry.id, status, detected.entry.mcp_server_name
        );
    }
    Ok(())
}
