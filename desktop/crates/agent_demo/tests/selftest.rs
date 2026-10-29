use std::process::Command;

#[test]
fn selftest_runs_full_tool_loop() {
    let output = Command::new(env!("CARGO_BIN_EXE_cgc-agent-demo"))
        .arg("--selftest")
        .output()
        .expect("run demo");
    assert!(
        output.status.success(),
        "selftest failed: status={:?} stdout={} stderr={}",
        output.status,
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(String::from_utf8_lossy(&output.stdout).contains("SELFTEST OK"));
}
