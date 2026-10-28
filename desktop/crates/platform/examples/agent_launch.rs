//! Story 5.4 的启动 HITL：按内置清单构建启动计划（native OMP / managed Node npx），
//! 真实拉起 native 进程并优雅终止。用法：`cargo run -p cgc-platform --example agent_launch`

use std::path::PathBuf;
use std::time::Duration;

use cgc_platform::agent::launch::{build_launch, NodeRuntime};
use cgc_platform::agent::lifecycle::AgentProcess;
use cgc_platform::registry::manifest::Registry;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let registry = Registry::builtin()?;
    let cwd = std::env::temp_dir();
    let omp = registry.get("omp")?;
    let plan = build_launch(omp, None, &cwd)?;
    println!("omp plan: program={:?} args={:?}", plan.program, plan.args);
    println!(
        "omp env keys={:?} (no token vars)",
        plan.env.keys().collect::<Vec<_>>()
    );
    let mut process = AgentProcess::spawn(&plan)?;
    std::thread::sleep(Duration::from_millis(800));
    println!("omp running after 800ms: {}", process.is_running()?);
    let status = process.terminate(Duration::from_secs(2))?;
    println!(
        "omp terminated: success={} code={:?}",
        status.success(),
        status.code()
    );

    let codex = registry.get("codex")?;
    match std::env::var_os("CGC_MANAGED_NODE") {
        Some(root) => {
            let plan = build_launch(codex, Some(&NodeRuntime::new(PathBuf::from(root))), &cwd)?;
            println!(
                "codex plan: program={:?} args={:?}",
                plan.program, plan.args
            );
        }
        None => match build_launch(codex, None, &cwd) {
            Ok(_) => println!("codex plan unexpectedly available"),
            Err(error) => println!("codex plan blocked (expected without managed node): {error}"),
        },
    }
    Ok(())
}
