#![cfg(unix)]

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use cgc_platform::acp::connection::{AcpHost, AcpHostConfig, HostEvent};
use cgc_platform::agent::launch::{build_launch, LaunchPlan, NodeRuntime};
use cgc_platform::agent::node_runtime::{Downloader, NodeArtifact, NodeRuntimeManager};
use cgc_platform::registry::checksum::sha256_hex;
use cgc_platform::registry::install::install_entry;
use cgc_platform::registry::manifest::{AgentEntry, Registry};

static NEXT: AtomicU64 = AtomicU64::new(0);

struct Fixture(PathBuf);

impl Fixture {
    fn new() -> Self {
        let data = std::env::temp_dir().join(format!(
            "cgc agent recovery {} {}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(&data).unwrap();
        Self(data)
    }

    fn executable(&self, relative: &str, source: &str) -> PathBuf {
        let path = self.0.join(relative);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, source).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
        path
    }

    fn installed_agent(&self) -> (AgentEntry, NodeRuntime) {
        self.executable("node24/bin/node", "#!/bin/sh\nif [ \"$1\" = --version ]; then echo v24.22.0; exit; fi\nexec /bin/sh \"$@\"\n");
        self.executable("node24/lib/node_modules/npm/bin/npm-cli.js", "#!/bin/sh\nroot=\"${0%/lib/node_modules/npm/bin/npm-cli.js}\"\n/bin/mkdir -p node_modules/@agentclientprotocol/codex-acp\nprintf '%s' '{\"name\":\"@agentclientprotocol/codex-acp\",\"version\":\"2.2.2\",\"bin\":\"index.js\"}' > node_modules/@agentclientprotocol/codex-acp/package.json\n/bin/cp \"$root/adapter\" node_modules/@agentclientprotocol/codex-acp/index.js\n");
        self.executable(
            "node24/adapter",
            "#!/bin/sh\nprintf 'fixture-agent 2.2.2\\n'\n",
        );
        let entry = Registry::builtin().unwrap().get("codex").unwrap().clone();
        let runtime = NodeRuntime::new(self.0.join("node24"));
        install_entry(&entry, Some(&runtime)).unwrap();
        (entry, runtime)
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[test]
fn reinstall_repairs_an_existing_but_unrunnable_package() {
    let fixture = Fixture::new();
    let (entry, runtime) = fixture.installed_agent();
    let plan = build_launch(&entry, Some(&runtime), &fixture.0).unwrap();
    fs::write(
        &plan.args[0],
        "#!/bin/sh\necho 'fixture missing dependency' >&2\nexit 17\n",
    )
    .unwrap();

    install_entry(&entry, Some(&runtime)).expect("reinstall must replace a broken package");

    let plan = build_launch(&entry, Some(&runtime), &fixture.0).unwrap();
    let output = Command::new(&plan.program)
        .args(&plan.args)
        .current_dir(&plan.cwd)
        .env_clear()
        .envs(&plan.env)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(output.stdout, b"fixture-agent 2.2.2\n");
}

#[test]
fn reinstalling_node_preserves_installed_agent_packages() {
    struct Archive(Vec<u8>);
    impl Downloader for Archive {
        fn fetch(&self, _url: &str) -> Result<Vec<u8>, String> {
            Ok(self.0.clone())
        }
    }

    let fixture = Fixture::new();
    let (entry, runtime) = fixture.installed_agent();
    let source = Fixture::new();
    source.executable(
        "node24/bin/node",
        "#!/bin/sh\nif [ \"$1\" = --version ]; then echo v24.22.0; exit; fi\nexec /bin/sh \"$@\"\n",
    );
    source.executable("node24/lib/node_modules/npm/bin/npm-cli.js", "#!/bin/sh\n");
    let archive = Command::new("tar")
        .args(["-cJf", "-", "-C"])
        .arg(&source.0)
        .arg("node24")
        .output()
        .unwrap();
    assert!(
        archive.status.success(),
        "{}",
        String::from_utf8_lossy(&archive.stderr)
    );
    let manager = NodeRuntimeManager {
        root: runtime.root.clone(),
        artifact: Some(NodeArtifact {
            file_name: "preserve-agents.tar.xz".to_string(),
            sha256: sha256_hex(&archive.stdout),
        }),
    };

    manager.install(&Archive(archive.stdout)).unwrap();

    let plan = build_launch(&entry, Some(&runtime), &fixture.0)
        .expect("replacing Node must retain the installed package");
    let output = Command::new(&plan.program)
        .args(&plan.args)
        .current_dir(&plan.cwd)
        .env_clear()
        .envs(&plan.env)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(output.stdout, b"fixture-agent 2.2.2\n");
}

#[test]
fn crashed_agent_reports_exit_status_and_stops_descendants() {
    let fixture = Fixture::new();
    let script = fixture.executable("crash-agent", r#"#!/bin/sh
/bin/sleep 30 &
printf '%s' "$!" > "$PWD/descendant.pid"
while IFS= read -r request; do
  id=${request#*'"id":'}
  id=${id%%,*}
  id=${id%%\}*}
  case "$request" in
    *'"method":"initialize"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":1,"agentCapabilities":{},"authMethods":[]}}\n' "$id" ;;
    *'"method":"session/new"'*)
      printf '{"jsonrpc":"2.0","id":%s,"result":{"sessionId":"crash-fixture"}}\n' "$id"
      while [ ! -f "$PWD/crash-now" ]; do /bin/sleep 0.02; done
      printf 'fixture crash diagnostic\n' >&2
      exit 17
      ;;
  esac
done
"#);
    let plan = LaunchPlan {
        program: PathBuf::from("/bin/sh"),
        args: vec![script.to_string_lossy().into_owned()],
        env: Default::default(),
        cwd: fixture.0.clone(),
    };
    let host = AcpHost::start(AcpHostConfig::from_launch_plan(plan)).unwrap();
    assert!(matches!(
        host.recv_timeout(Duration::from_secs(5)),
        Some(HostEvent::Ready { .. })
    ));
    let pid = fs::read_to_string(fixture.0.join("descendant.pid")).unwrap();
    let running = || {
        Command::new("/bin/kill")
            .args(["-0", pid.trim()])
            .stderr(Stdio::null())
            .status()
            .unwrap()
            .success()
    };
    assert!(running(), "descendant must exist before the crash");

    fs::write(fixture.0.join("crash-now"), b"crash").unwrap();
    let started = Instant::now();
    let mut error = None;
    let mut exited = false;
    while started.elapsed() < Duration::from_secs(3) {
        match host.recv_timeout(Duration::from_millis(50)) {
            Some(HostEvent::Error { message }) => error = Some(message),
            Some(HostEvent::Exited) => {
                exited = true;
                break;
            }
            _ => {}
        }
    }
    host.shutdown();
    assert!(
        exited,
        "agent crash must close the host without a new user command"
    );
    let error = error.expect("nonzero agent exit must be reported");
    assert!(error.contains("17"), "exit status missing: {error}");
    assert!(
        error.contains("fixture crash diagnostic"),
        "stderr missing: {error}"
    );
    assert!(!running(), "agent crash left a descendant process running");
}

#[test]
fn stdout_eof_during_a_large_prompt_exits_without_user_shutdown() {
    let fixture = Fixture::new();
    let script = fixture.executable("half-closed-agent", r#"#!/bin/sh
printf '%s' "$$" > "$PWD/agent.pid"
while IFS= read -r request; do
  id=${request#*'"id":'}
  id=${id%%,*}
  id=${id%%\}*}
  case "$request" in
    *'"method":"initialize"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":1,"agentCapabilities":{},"authMethods":[]}}\n' "$id" ;;
    *'"method":"session/new"'*)
      printf '{"jsonrpc":"2.0","id":%s,"result":{"sessionId":"half-close-fixture"}}\n' "$id"
      /bin/dd bs=1 count=1 of=/dev/null 2>/dev/null
      exec 1>&-
      printf closed > "$PWD/half-closed"
      /bin/sleep 30
      exit 0
      ;;
  esac
done
"#);
    let host = AcpHost::start(AcpHostConfig::from_launch_plan(LaunchPlan {
        program: PathBuf::from("/bin/sh"),
        args: vec![script.to_string_lossy().into_owned()],
        env: Default::default(),
        cwd: fixture.0.clone(),
    }))
    .unwrap();
    assert!(matches!(
        host.recv_timeout(Duration::from_secs(5)),
        Some(HostEvent::Ready { .. })
    ));
    let pid = fs::read_to_string(fixture.0.join("agent.pid")).unwrap();
    assert!(host.prompt("x".repeat(4 * 1024 * 1024)));
    let started = Instant::now();
    let mut exited = false;
    while started.elapsed() < Duration::from_secs(3) {
        if matches!(
            host.recv_timeout(Duration::from_millis(20)),
            Some(HostEvent::Exited)
        ) {
            exited = true;
            break;
        }
    }
    let closed = fixture.0.join("half-closed").is_file();
    let running = Command::new("/bin/kill")
        .args(["-0", pid.trim()])
        .stderr(Stdio::null())
        .status()
        .unwrap()
        .success();
    // Cleanup is explicit even on the failing pre-fix path; it must not be what
    // makes the Exited event or process-termination assertions pass.
    host.shutdown();
    assert!(
        closed,
        "agent must read a prompt byte and half-close stdout"
    );
    assert!(
        exited,
        "stdout EOF must close the host without a user command"
    );
    assert!(!running, "automatic EOF handling must reap the agent");
}

fn probe_with_detached_pipe_holder(early_exit: bool) {
    let fixture = Fixture::new();
    fixture.executable("node24/lib/node_modules/npm/bin/npm-cli.js", "#!/bin/sh\n");
    fixture.executable(
        "node24/bin/node",
        &format!(
            r#"#!/usr/bin/python3 -I
import os
import pathlib
import time

pid_file = pathlib.Path.cwd() / 'escaped.pid'
if os.fork() == 0:
    os.setsid()
    pid_file.write_text(str(os.getpid()))
    time.sleep(10)
    os._exit(0)
while not pid_file.exists():
    time.sleep(0.001)
if {early_exit}:
    print('v24.22.0', flush=True)
else:
    time.sleep(30)
"#,
            early_exit = if early_exit { "True" } else { "False" }
        ),
    );
    let runtime = NodeRuntime::new(fixture.0.join("node24"));
    let started = Instant::now();
    let version = runtime.version();
    let elapsed = started.elapsed();
    let pid = fs::read_to_string(runtime.root.join("escaped.pid")).unwrap();
    let running = Command::new("/bin/kill")
        .args(["-0", pid.trim()])
        .stderr(Stdio::null())
        .status()
        .unwrap()
        .success();
    let _ = Command::new("/bin/kill")
        .args(["-KILL", pid.trim()])
        .stderr(Stdio::null())
        .status();
    assert!(
        elapsed < Duration::from_secs(6),
        "5s deadline excluded pipe EOF: {elapsed:?}"
    );
    assert!(
        running,
        "detached descendant must still hold the output pipes"
    );
    assert_eq!(
        version, None,
        "incomplete command output cannot report a ready runtime"
    );
}

#[test]
fn version_probe_timeout_does_not_wait_for_detached_pipe_holder() {
    probe_with_detached_pipe_holder(false);
}

#[test]
fn version_probe_deadline_also_covers_pipes_after_successful_child_exit() {
    probe_with_detached_pipe_holder(true);
}

#[test]
fn successful_exit_after_final_reply_reports_no_transport_error() {
    let fixture = Fixture::new();
    let script = fixture.executable("successful-agent", r#"#!/bin/sh
while IFS= read -r request; do
  id=${request#*'"id":'}
  id=${id%%,*}
  id=${id%%\}*}
  case "$request" in
    *'"method":"initialize"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":1,"agentCapabilities":{},"authMethods":[]}}\n' "$id" ;;
    *'"method":"session/new"'*)
      printf '{"jsonrpc":"2.0","id":%s,"result":{"sessionId":"successful-fixture"}}\n' "$id"
      exec 1>&-
      /bin/sleep 0.1
      exit 0
      ;;
  esac
done
"#);
    let host = AcpHost::start(AcpHostConfig::from_launch_plan(LaunchPlan {
        program: PathBuf::from("/bin/sh"),
        args: vec![script.to_string_lossy().into_owned()],
        env: Default::default(),
        cwd: fixture.0.clone(),
    }))
    .unwrap();
    assert!(matches!(
        host.recv_timeout(Duration::from_secs(5)),
        Some(HostEvent::Ready { .. })
    ));
    let started = Instant::now();
    let mut exited = false;
    let mut errors = Vec::new();
    while started.elapsed() < Duration::from_secs(3) {
        match host.recv_timeout(Duration::from_millis(20)) {
            Some(HostEvent::Error { message }) => errors.push(message),
            Some(HostEvent::Exited) => {
                exited = true;
                break;
            }
            _ => {}
        }
    }
    host.shutdown();
    assert!(exited, "successful process exit must finish the host");
    assert!(
        errors.is_empty(),
        "clean stdout EOF reported as transport failure: {errors:?}"
    );
}

#[test]
fn exit_failure_after_stdout_eof_keeps_status_and_diagnostic() {
    let fixture = Fixture::new();
    let script = fixture.executable("delayed-failure-agent", r#"#!/bin/sh
while IFS= read -r request; do
  id=${request#*'"id":'}
  id=${id%%,*}
  id=${id%%\}*}
  case "$request" in
    *'"method":"initialize"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":1,"agentCapabilities":{},"authMethods":[]}}\n' "$id" ;;
    *'"method":"session/new"'*)
      printf '{"jsonrpc":"2.0","id":%s,"result":{"sessionId":"delayed-failure-fixture"}}\n' "$id"
      exec 1>&-
      /bin/sleep 0.1
      printf 'delayed fixture failure\n' >&2
      exit 17
      ;;
  esac
done
"#);
    let host = AcpHost::start(AcpHostConfig::from_launch_plan(LaunchPlan {
        program: PathBuf::from("/bin/sh"),
        args: vec![script.to_string_lossy().into_owned()],
        env: Default::default(),
        cwd: fixture.0.clone(),
    }))
    .unwrap();
    assert!(matches!(
        host.recv_timeout(Duration::from_secs(5)),
        Some(HostEvent::Ready { .. })
    ));
    let started = Instant::now();
    let mut exited = false;
    let mut errors = Vec::new();
    while started.elapsed() < Duration::from_secs(3) {
        match host.recv_timeout(Duration::from_millis(20)) {
            Some(HostEvent::Error { message }) => errors.push(message),
            Some(HostEvent::Exited) => {
                exited = true;
                break;
            }
            _ => {}
        }
    }
    host.shutdown();
    assert!(
        exited,
        "EOF must finish the host after observing child exit"
    );
    assert!(
        errors
            .iter()
            .any(|error| error.contains("17") && error.contains("delayed fixture failure")),
        "late failure was lost: {errors:?}"
    );
}
