#![cfg(unix)]

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::net::TcpListener;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc;
use std::time::Duration;

use cgc_platform::agent::launch::{build_launch_with_env, NodeRuntime};
use cgc_platform::registry::install::install_entry;
use cgc_platform::registry::manifest::Registry;

static NEXT: AtomicU64 = AtomicU64::new(0);

struct Fixture(PathBuf);

impl Fixture {
    fn new() -> Self {
        let fixture = Self(std::env::temp_dir().join(format!(
            "cgc agent install {} {}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        )));
        fixture.executable("node24/bin/node", "#!/bin/sh\nif [ \"$1\" = --version ]; then echo v24.22.0; exit; fi\nexec /bin/sh \"$@\"\n");
        fixture.executable("node24/lib/node_modules/npm/bin/npm-cli.js", "#!/bin/sh\n");
        fixture
    }

    fn executable(&self, relative: &str, script: &str) -> PathBuf {
        let path = self.0.join(relative);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, script).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
        path
    }

    fn runtime(&self) -> NodeRuntime {
        NodeRuntime::new(self.0.join("node24"))
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[test]
fn managed_agent_reaches_registry_through_inherited_proxy() {
    let fixture = Fixture::new();
    let proxy = TcpListener::bind(("127.0.0.1", 0)).unwrap();
    proxy.set_nonblocking(true).unwrap();
    let proxy_url = format!("http://{}", proxy.local_addr().unwrap());
    let (stop, stopped) = mpsc::channel();
    let server = std::thread::spawn(move || {
        while matches!(stopped.try_recv(), Err(mpsc::TryRecvError::Empty)) {
            match proxy.accept() {
                Ok((mut socket, _)) => {
                    socket.set_nonblocking(false).unwrap();
                    socket
                        .set_read_timeout(Some(Duration::from_secs(2)))
                        .unwrap();
                    let mut request = BufReader::new(&mut socket);
                    let mut line = String::new();
                    request.read_line(&mut line).unwrap();
                    assert!(line.starts_with("GET http://registry.invalid/fixture "));
                    loop {
                        line.clear();
                        if request.read_line(&mut line).unwrap() == 0 || line == "\r\n" {
                            break;
                        }
                    }
                    socket.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 20\r\nConnection: close\r\n\r\nfixture-agent 2.2.2\n").unwrap();
                    return true;
                }
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    std::thread::sleep(Duration::from_millis(10));
                }
                Err(error) => panic!("proxy failed: {error}"),
            }
        }
        false
    });
    fixture.executable(
        "agents/codex/2.2.2/node_modules/@agentclientprotocol/codex-acp/package.json",
        r#"{"name":"@agentclientprotocol/codex-acp","version":"2.2.2","bin":"index.js"}"#,
    );
    fixture.executable(
        "agents/codex/2.2.2/node_modules/@agentclientprotocol/codex-acp/index.js",
        "#!/bin/sh\nexec /usr/bin/curl -qfsS --max-time 2 http://registry.invalid/fixture\n",
    );
    let registry = Registry::builtin().unwrap();
    let plan = build_launch_with_env(
        registry.get("codex").unwrap(),
        Some(&fixture.runtime()),
        Path::new(&fixture.0),
        |key| match key {
            "http_proxy" => Some(proxy_url.clone()),
            "HOME" => Some(fixture.0.to_string_lossy().into_owned()),
            _ => None,
        },
    )
    .unwrap();
    let output = Command::new(&plan.program)
        .args(&plan.args)
        .current_dir(&plan.cwd)
        .env_clear()
        .envs(&plan.env)
        .output()
        .unwrap();
    let _ = stop.send(());
    let received = server.join().unwrap();
    assert!(
        output.status.success(),
        "managed agent cannot reach its registry: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(received, "registry request must actually reach the proxy");
    assert_eq!(output.stdout, b"fixture-agent 2.2.2\n");
}

#[test]
fn concurrent_installations_preserve_the_first_healthy_package() {
    let fixture = Fixture::new();
    fixture.executable("node24/lib/node_modules/npm/bin/npm-cli.js", r#"#!/bin/sh
root="${0%/node24/lib/node_modules/npm/bin/npm-cli.js}"
if /bin/mkdir "$root/first" 2>/dev/null; then turn=first; else turn=second; fi
printf ready > "$root/entered-$turn"
i=0
while [ ! -f "$root/release-$turn" ]; do
  i=$((i+1))
  if [ "$i" -gt 500 ]; then exit 73; fi
  /bin/sleep 0.01
done
/bin/mkdir -p node_modules/@agentclientprotocol/codex-acp
printf '%s' '{"name":"@agentclientprotocol/codex-acp","version":"2.2.2","bin":"index.js"}' > node_modules/@agentclientprotocol/codex-acp/package.json
/bin/cp "$root/adapter" node_modules/@agentclientprotocol/codex-acp/index.js
"#);
    fixture.executable("adapter", "#!/bin/sh\nprintf 'fixture-agent 2.2.2\\n'\n");
    let entry = Registry::builtin().unwrap().get("codex").unwrap().clone();
    let start_install = || {
        let entry = entry.clone();
        let runtime = fixture.runtime();
        std::thread::spawn(move || install_entry(&entry, Some(&runtime)))
    };
    let wait_for = |name: &str, timeout: Duration| {
        let started = std::time::Instant::now();
        while !fixture.0.join(name).exists() && started.elapsed() < timeout {
            std::thread::sleep(Duration::from_millis(10));
        }
        fixture.0.join(name).exists()
    };
    let first = start_install();
    let first_started = wait_for("entered-first", Duration::from_secs(3));
    let second = start_install();
    // Before the fix both installers reach npm. With serialization the second
    // caller waits, then reuses the first caller's published healthy package.
    let _ = wait_for("entered-second", Duration::from_secs(1));
    fs::write(fixture.0.join("release-first"), b"release").unwrap();
    let first_result = first.join().unwrap();
    let protected = fixture.0.join("agents/codex/2.2.2/read-only-assets");
    fs::create_dir_all(&protected).unwrap();
    fs::write(protected.join("asset"), b"installed immutable asset").unwrap();
    fs::set_permissions(&protected, fs::Permissions::from_mode(0o555)).unwrap();
    fs::write(fixture.0.join("release-second"), b"release").unwrap();
    let second_result = second.join().unwrap();
    // Restore permissions before assertions so failed runs remain isolated.
    let _ = fs::set_permissions(&protected, fs::Permissions::from_mode(0o755));
    assert!(first_started, "the first installer must reach npm");
    first_result.expect("first install must publish a working package");
    second_result.expect("concurrent install must reuse an already healthy package");
    let plan = build_launch_with_env(&entry, Some(&fixture.runtime()), &fixture.0, |_| None)
        .expect("published package must remain launchable");
    let output = Command::new(&plan.program)
        .args(&plan.args)
        .env_clear()
        .envs(&plan.env)
        .current_dir(&plan.cwd)
        .output()
        .unwrap();
    assert!(output.status.success());
    assert_eq!(output.stdout, b"fixture-agent 2.2.2\n");
}
