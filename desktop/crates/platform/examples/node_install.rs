//! Story 5.9 的 managed Node runtime HITL：下载 → checksum → 解压。
//! 用法：`cargo run -p cgc-platform --example node_install`

use cgc_platform::agent::node_runtime::{HttpDownloader, NodeRuntimeManager};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let manager = NodeRuntimeManager::default_manager();
    println!("node root: {:?}", manager.root);
    println!("status before: {:?}", manager.status());
    manager.install(&HttpDownloader)?;
    println!("status after: {:?}", manager.status());
    let node = manager.root.join("bin/node");
    let output = std::process::Command::new(node).arg("--version").output()?;
    println!(
        "managed node --version: {}",
        String::from_utf8_lossy(&output.stdout).trim()
    );
    Ok(())
}
