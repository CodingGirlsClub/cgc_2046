#![cfg(unix)]

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};

use cgc_platform::acp::connection::{AcpHost, AcpHostConfig, HostEvent};
use cgc_platform::agent::detect::{detect_all, detect_node, AgentStatus};
use cgc_platform::agent::launch::{build_launch_with_env, NodeRuntime};
use cgc_platform::agent::node_runtime::{NodeRuntimeManager, RuntimeStatus};
use cgc_platform::registry::install::install_entry;
use cgc_platform::registry::manifest::Registry;
use std::time::Duration;

static NEXT: AtomicU64 = AtomicU64::new(0);

struct RuntimeFixture(PathBuf);

impl RuntimeFixture {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!(
            "cgc managed runtime {} {}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        let root = root.join("node24");
        fs::create_dir_all(&root).unwrap();
        Self(root)
    }

    fn executable(&self, relative: &str, script: &str) -> PathBuf {
        let root = if relative.starts_with("agents/") {
            self.0.parent().unwrap()
        } else {
            &self.0
        };
        let path = root.join(relative);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, script).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
        path
    }
}

impl Drop for RuntimeFixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(self.0.parent().unwrap());
    }
}

#[test]
fn managed_launch_runs_node_shebang_descendant_without_system_node() {
    let fixture = RuntimeFixture::new();
    fixture.executable(
        "bin/node",
        "#!/bin/sh\nif [ \"$1\" = --version ]; then echo v24.22.0; exit; fi\nexec /bin/sh \"$@\"\n",
    );
    fixture.executable(
        "lib/node_modules/npm/bin/npx-cli.js",
        "#!/bin/sh\nexec \"$PWD/adapter\"\n",
    );
    fixture.executable("lib/node_modules/npm/bin/npm-cli.js", "#!/bin/sh\n");
    fixture.executable(
        "agents/codex/2.2.2/node_modules/@agentclientprotocol/codex-acp/package.json",
        r#"{"name":"@agentclientprotocol/codex-acp","version":"2.2.2","bin":"index.js"}"#,
    );
    fixture.executable(
        "agents/codex/2.2.2/node_modules/@agentclientprotocol/codex-acp/index.js",
        "#!/bin/sh\nexec \"$PWD/adapter\"\n",
    );
    fixture.executable(
        "adapter",
        "#!/usr/bin/env node\nprintf 'fixture-agent 2.2.2\\n'\n",
    );
    let registry = Registry::builtin().unwrap();
    let plan = build_launch_with_env(
        registry.get("codex").unwrap(),
        Some(&NodeRuntime::new(&fixture.0)),
        Path::new(&fixture.0),
        |key| (key == "PATH").then(|| "/cgc-no-system-node".to_string()),
    )
    .unwrap();
    let output = Command::new(&plan.program)
        .args(&plan.args)
        .current_dir(&plan.cwd)
        .env_clear()
        .envs(&plan.env)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "managed agent failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(output.stdout, b"fixture-agent 2.2.2\n");
}

#[test]
fn installed_agent_runs_after_npx_cache_is_unavailable() {
    let fixture = RuntimeFixture::new();
    fixture.executable(
        "bin/node",
        "#!/bin/sh\nif [ \"$1\" = --version ]; then echo v24.22.0; exit; fi\nexec /bin/sh \"$@\"\n",
    );
    fixture.executable(
        "lib/node_modules/npm/bin/npx-cli.js",
        "#!/bin/sh\nprintf 'fixture-agent 2.2.2\\n'\n",
    );
    fixture.executable(
        "lib/node_modules/npm/bin/npm-cli.js",
        "#!/bin/sh\nroot=\"${0%/lib/node_modules/npm/bin/npm-cli.js}\"\n/bin/mkdir -p node_modules/@agentclientprotocol/codex-acp\nprintf '%s' '{\"name\":\"@agentclientprotocol/codex-acp\",\"version\":\"2.2.2\",\"bin\":{\"codex-acp\":\"index.js\"}}' > node_modules/@agentclientprotocol/codex-acp/package.json\n/bin/cp \"$root/adapter\" node_modules/@agentclientprotocol/codex-acp/index.js\n",
    );
    fixture.executable(
        "adapter",
        "#!/usr/bin/env node\nprintf 'fixture-agent 2.2.2\\n'\n",
    );
    let registry = Registry::builtin().unwrap();
    let entry = registry.get("codex").unwrap();
    let runtime = NodeRuntime::new(&fixture.0);
    install_entry(entry, Some(&runtime)).expect("install agent");
    fs::remove_file(fixture.0.join("lib/node_modules/npm/bin/npx-cli.js")).unwrap();
    let plan = build_launch_with_env(entry, Some(&runtime), &fixture.0, |key| {
        (key == "PATH").then(|| "/cgc-no-system-node".to_string())
    })
    .expect("installed agent must not depend on the npx cache");
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
fn managed_runtime_checks_the_executable_version_before_reporting_ready() {
    for (version, expected) in [
        ("24.21.0", RuntimeStatus::Missing),
        (
            "24.22.0",
            RuntimeStatus::Installed {
                version: "24.22.0".to_string(),
            },
        ),
    ] {
        let fixture = RuntimeFixture::new();
        fixture.executable("bin/node", &format!("#!/bin/sh\nprintf 'v{version}\\n'\n"));
        fixture.executable("lib/node_modules/npm/bin/npm-cli.js", "#!/bin/sh\n");
        let manager = NodeRuntimeManager {
            root: fixture.0.clone(),
            artifact: None,
        };
        assert_eq!(manager.status(), expected, "actual Node {version}");
    }
}

#[test]
fn acp_host_preserves_managed_environment_and_working_directory() {
    let fixture = RuntimeFixture::new();
    fixture.executable(
        "bin/node",
        "#!/bin/sh\nif [ \"$1\" = --version ]; then echo v24.22.0; exit; fi\nexec /bin/sh \"$@\"\n",
    );
    fixture.executable("lib/node_modules/npm/bin/npm-cli.js", "#!/bin/sh\n");
    fixture.executable(
        "agents/codex/2.2.2/node_modules/@agentclientprotocol/codex-acp/package.json",
        r#"{"name":"@agentclientprotocol/codex-acp","version":"2.2.2","bin":"index.js"}"#,
    );
    fixture.executable(
        "agents/codex/2.2.2/node_modules/@agentclientprotocol/codex-acp/index.js",
        "#!/bin/sh\nexec \"$PWD/acp-stdio\"\n",
    );
    fixture.executable("acp-stdio", r#"#!/usr/bin/env node
if [ "$CGC_RUNTIME_MARKER" != fixture ]; then echo 'missing launch environment' >&2; exit 66; fi
/bin/sleep 30 &
printf '%s' "$!" > "$PWD/child.pid"
while IFS= read -r request; do
  id=${request#*'"id":'}
  id=${id%%,*}
  id=${id%%\}*}
  case "$request" in
    *'"method":"initialize"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":1,"agentCapabilities":{},"authMethods":[]}}\n' "$id" ;;
    *'"method":"session/new"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"sessionId":"managed-fixture"}}\n' "$id" ;;
  esac
done
"#);
    let registry = Registry::builtin().unwrap();
    let mut plan = build_launch_with_env(
        registry.get("codex").unwrap(),
        Some(&NodeRuntime::new(&fixture.0)),
        &fixture.0,
        |key| (key == "PATH").then(|| "/cgc-no-system-node".to_string()),
    )
    .unwrap();
    plan.env
        .insert("CGC_RUNTIME_MARKER".to_string(), "fixture".to_string());
    let config = AcpHostConfig::from_launch_plan(plan);
    let host = AcpHost::start(config).unwrap();
    let event = host.recv_timeout(Duration::from_secs(5));
    assert!(
        matches!(event, Some(HostEvent::Ready { .. })),
        "ACP initialization failed: {event:?}"
    );
    let pid = fs::read_to_string(fixture.0.join("child.pid")).unwrap();
    let running = || {
        Command::new("/bin/kill")
            .args(["-0", pid.trim()])
            .stderr(std::process::Stdio::null())
            .status()
            .unwrap()
            .success()
    };
    assert!(running(), "agent descendant must exist before shutdown");
    host.shutdown();
    let started = std::time::Instant::now();
    while running() && started.elapsed() < Duration::from_secs(5) {
        std::thread::sleep(Duration::from_millis(20));
    }
    assert!(!running(), "ACP shutdown left an agent descendant running");
}

#[test]
fn old_registry_requirement_cannot_lower_the_node_security_floor() {
    let fixture = RuntimeFixture::new();
    fixture.executable("bin/node", "#!/bin/sh\nprintf 'v24.21.0\\n'\n");
    fixture.executable("lib/node_modules/npm/bin/npm-cli.js", "#!/bin/sh\n");
    let status = detect_node(Some(&NodeRuntime::new(&fixture.0)), "24.0.0");
    assert_eq!(status.required, "24.22.0");
    assert_eq!(status.found.as_deref(), Some("24.21.0"));
    assert!(!status.is_ready());
}

#[test]
fn readiness_tracks_the_actual_package_entry_after_installation() {
    let fixture = RuntimeFixture::new();
    fixture.executable(
        "bin/node",
        "#!/bin/sh\nif [ \"$1\" = --version ]; then echo v24.22.0; exit; fi\nexec /bin/sh \"$@\"\n",
    );
    fixture.executable("lib/node_modules/npm/bin/npm-cli.js", "#!/bin/sh\n");
    let registry = Registry::builtin().unwrap();
    let runtime = NodeRuntime::new(&fixture.0);
    let status = || {
        detect_all(&registry, Some(&runtime))
            .into_iter()
            .find(|agent| agent.entry.id == "codex")
            .unwrap()
            .status
    };
    assert_eq!(status(), AgentStatus::Missing);
    fixture.executable(
        "agents/codex/2.2.2/node_modules/@agentclientprotocol/codex-acp/package.json",
        r#"{"name":"@agentclientprotocol/codex-acp","version":"2.2.2","bin":"index.js"}"#,
    );
    let executable = fixture.executable(
        "agents/codex/2.2.2/node_modules/@agentclientprotocol/codex-acp/index.js",
        "#!/bin/sh\nprintf 'fixture-agent 2.2.2\\n'\n",
    );
    assert_eq!(
        status(),
        AgentStatus::Ready {
            version: "2.2.2".to_string()
        }
    );
    fs::remove_file(executable).unwrap();
    assert_eq!(status(), AgentStatus::Missing);
}

#[test]
fn package_entry_cannot_escape_its_package_directory() {
    for escape in ["parent", "symlink"] {
        let fixture = RuntimeFixture::new();
        fixture.executable("bin/node", "#!/bin/sh\nif [ \"$1\" = --version ]; then echo v24.22.0; exit; fi\nexec /bin/sh \"$@\"\n");
        fixture.executable("lib/node_modules/npm/bin/npm-cli.js", "#!/bin/sh\n");
        let metadata = fixture.executable(
            "agents/codex/2.2.2/node_modules/@agentclientprotocol/codex-acp/package.json",
            r#"{"name":"@agentclientprotocol/codex-acp","version":"2.2.2","bin":"index.js"}"#,
        );
        let executable = fixture.executable(
            "agents/codex/2.2.2/node_modules/@agentclientprotocol/codex-acp/index.js",
            "#!/bin/sh\nprintf 'fixture-agent 2.2.2\\n'\n",
        );
        let outside = fixture.executable(
            "agents/codex/2.2.2/node_modules/@agentclientprotocol/outside.js",
            "#!/bin/sh\nprintf 'outside-package\\n'\n",
        );
        let entry = Registry::builtin().unwrap().get("codex").unwrap().clone();
        let runtime = NodeRuntime::new(&fixture.0);
        let launch = || {
            build_launch_with_env(&entry, Some(&runtime), &fixture.0, |key| {
                (key == "PATH").then(|| "/cgc-no-system-node".to_string())
            })
        };
        let plan = launch().unwrap();
        let output = Command::new(&plan.program)
            .args(&plan.args)
            .current_dir(&plan.cwd)
            .env_clear()
            .envs(&plan.env)
            .output()
            .unwrap();
        assert!(output.status.success());
        assert_eq!(output.stdout, b"fixture-agent 2.2.2\n");

        if escape == "parent" {
            fs::write(&metadata, r#"{"name":"@agentclientprotocol/codex-acp","version":"2.2.2","bin":"../outside.js"}"#).unwrap();
        } else {
            fs::remove_file(&executable).unwrap();
            std::os::unix::fs::symlink(&outside, &executable).unwrap();
        }
        let error = launch().expect_err("an agent entry must remain inside its package");
        assert!(
            matches!(
                error,
                cgc_platform::agent::launch::LaunchError::AgentPackageMissing(_)
            ),
            "{escape}: {error}"
        );
    }
}
