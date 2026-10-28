//! Story 5.5 的注入 HITL：真实 OMP 在 session/new 收到注入的 cgc-2046 MCP server，
//! 不写用户配置。凭证来自环境变量 `CGC_LEARNING_TOKEN`（不打印）。
//!
//! 用法：`CGC_LEARNING_TOKEN=<cgch_…> cargo run -p cgc-platform --example mcp_injection`

use std::path::PathBuf;
use std::time::Duration;

use cgc_platform::acp::connection::{AcpHost, AcpHostConfig, HostEvent};
use cgc_platform::mcp::credential::LearningHostLease;
use cgc_platform::mcp::inject::{build_mcp_server, mcp_endpoint};
use cgc_platform::registry::manifest::Registry;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let token = std::env::var("CGC_LEARNING_TOKEN").expect("CGC_LEARNING_TOKEN");
    let registry = Registry::builtin()?;
    let entry = registry.get("omp")?;
    let lease = LearningHostLease {
        token,
        token_id: "hitl".to_string(),
        epoch: 1,
    };
    let endpoint = mcp_endpoint(std::env::var("CGC_API_URL").ok().as_deref());
    let server = build_mcp_server(entry, &lease, &endpoint);
    println!(
        "injecting mcp server for {} (token redacted)",
        entry.display_name
    );

    let host = AcpHost::start(
        AcpHostConfig::new("omp acp", PathBuf::from("/tmp"))
            .with_name("omp")
            .with_mcp_servers(vec![server]),
    )?;

    let mut ready = false;
    let mut ended = false;
    let mut text = String::new();
    let deadline = std::time::Instant::now() + Duration::from_secs(90);
    while std::time::Instant::now() < deadline {
        match host.recv_timeout(Duration::from_secs(2)) {
            Some(HostEvent::Ready {
                agent_name,
                version,
                ..
            }) => {
                ready = true;
                println!("ready: {agent_name} {version}");
                host.prompt("请只回复 ok");
            }
            Some(HostEvent::Delta(chunk)) => text.push_str(&chunk),
            Some(HostEvent::TurnEnd { .. }) => {
                ended = true;
                break;
            }
            Some(HostEvent::Error { message }) => return Err(message.into()),
            Some(_) => {}
            None => {}
        }
    }
    host.shutdown();
    println!("ready={ready} ended={ended} text_len={}", text.len());
    if !ready || !ended {
        return Err("injected session did not complete".into());
    }
    Ok(())
}
