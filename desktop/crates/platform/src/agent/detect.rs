//! 本机 agent 与 Node runtime 探测（story 5.3）。
//!
//! 探测只读：运行 `--version`（5s 预算）并解析语义版本；不自动安装、不读 agent 凭证。
//! 结果用于 5.9 的引导安装与 5.4 的启动前置判断。

use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use crate::registry::manifest::{AgentEntry, Distribution, Registry};

const PROBE_TIMEOUT: Duration = Duration::from_secs(5);

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NodeStatus {
    pub required: String,
    pub found: Option<String>,
}

impl NodeStatus {
    pub fn is_ready(&self) -> bool {
        self.found
            .as_deref()
            .is_some_and(|found| version_at_least(found, &self.required))
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AgentStatus {
    Ready {
        version: String,
    },
    Missing,
    Outdated {
        found: String,
        required: String,
    },
    NodeUnavailable {
        required: String,
        found: Option<String>,
    },
    Error(String),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DetectedAgent {
    pub entry: AgentEntry,
    pub status: AgentStatus,
}

/// 探测命令的可替换 seam（测试用静态版本）。
pub trait CommandProbe: Send + Sync {
    fn version(&self, program: &str, args: &[&str]) -> Result<String, String>;
}

pub struct SystemProbe;

impl CommandProbe for SystemProbe {
    fn version(&self, program: &str, args: &[&str]) -> Result<String, String> {
        let mut child = Command::new(program)
            .args(args)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|error| error.to_string())?;
        let started = Instant::now();
        loop {
            match child.try_wait() {
                Ok(Some(status)) => {
                    let output = child
                        .wait_with_output()
                        .map_err(|error| error.to_string())?;
                    let stdout = String::from_utf8_lossy(&output.stdout);
                    let stderr = String::from_utf8_lossy(&output.stderr);
                    let text = format!("{stdout}\n{stderr}");
                    if !status.success() && parse_version(&text).is_none() {
                        return Err(format!("{program} exited with {}", status));
                    }
                    return Ok(text);
                }
                Ok(None) if started.elapsed() < PROBE_TIMEOUT => {
                    std::thread::sleep(Duration::from_millis(20));
                }
                Ok(None) => {
                    let _ = child.kill();
                    let _ = child.wait();
                    return Err(format!("{program} probe timeout"));
                }
                Err(error) => return Err(error.to_string()),
            }
        }
    }
}

/// 从版本输出中取第一个 `x.y.z` 语义版本；容忍前缀（`omp/18.12.2`）。
pub fn parse_version(output: &str) -> Option<String> {
    for token in output.split(|ch: char| !(ch.is_ascii_alphanumeric() || ch == '.')) {
        let token = token.trim_start_matches(['v', 'V']);
        let parts: Vec<&str> = token.split('.').collect();
        if parts.len() >= 3
            && parts
                .iter()
                .take(3)
                .all(|part| !part.is_empty() && part.chars().all(|c| c.is_ascii_digit()))
        {
            return Some(parts[..3].join("."));
        }
    }
    None
}

pub fn version_at_least(found: &str, required: &str) -> bool {
    fn numbers(version: &str) -> Vec<u64> {
        version
            .split('.')
            .map(|part| part.parse::<u64>().unwrap_or(0))
            .collect()
    }
    let found = numbers(found);
    let required = numbers(required);
    for index in 0..3 {
        let a = found.get(index).copied().unwrap_or(0);
        let b = required.get(index).copied().unwrap_or(0);
        if a != b {
            return a > b;
        }
    }
    true
}

pub fn detect_node(probe: &dyn CommandProbe, required: &str) -> NodeStatus {
    let found = probe
        .version("node", &["--version"])
        .ok()
        .and_then(|output| parse_version(&output));
    NodeStatus {
        required: required.to_string(),
        found,
    }
}

pub fn detect_all(registry: &Registry, probe: &dyn CommandProbe) -> Vec<DetectedAgent> {
    let node = detect_node(probe, &registry.node_required);
    registry
        .agents
        .iter()
        .map(|entry| DetectedAgent {
            entry: entry.clone(),
            status: detect_agent(entry, &node, probe),
        })
        .collect()
}

pub fn detect_agent(
    entry: &AgentEntry,
    node: &NodeStatus,
    probe: &dyn CommandProbe,
) -> AgentStatus {
    match &entry.distribution {
        Distribution::Native { command } => probe_version(entry, probe, command, &["--version"]),
        Distribution::Npx { package, .. } => {
            if !node.is_ready() {
                return AgentStatus::NodeUnavailable {
                    required: node.required.clone(),
                    found: node.found.clone(),
                };
            }
            let mut args = vec!["--no-install".to_string(), package.clone()];
            if entry.version_args.is_empty() {
                args.push("--version".to_string());
            } else {
                args.extend(entry.version_args.clone());
            }
            let refs = args.iter().map(String::as_str).collect::<Vec<_>>();
            probe_version(entry, probe, "npx", &refs)
        }
    }
}

fn probe_version(
    entry: &AgentEntry,
    probe: &dyn CommandProbe,
    program: &str,
    args: &[&str],
) -> AgentStatus {
    match probe.version(program, args) {
        Ok(output) => match parse_version(&output) {
            Some(version) if version_at_least(&version, &entry.minimum_version) => {
                AgentStatus::Ready { version }
            }
            Some(version) => AgentStatus::Outdated {
                found: version,
                required: entry.minimum_version.clone(),
            },
            None => AgentStatus::Error("cannot parse version".to_string()),
        },
        Err(_) => AgentStatus::Missing,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    #[derive(Default)]
    struct StaticProbe {
        versions: HashMap<String, String>,
    }

    impl StaticProbe {
        fn with(mut self, command: &str, version: &str) -> Self {
            self.versions
                .insert(command.to_string(), version.to_string());
            self
        }
    }

    impl CommandProbe for StaticProbe {
        fn version(&self, program: &str, _args: &[&str]) -> Result<String, String> {
            self.versions
                .get(program)
                .cloned()
                .ok_or_else(|| "not found".to_string())
        }
    }

    fn registry() -> Registry {
        Registry::builtin().expect("builtin registry")
    }

    #[test]
    fn parses_versions_from_cli_output() {
        assert_eq!(parse_version("omp/18.12.2").as_deref(), Some("18.12.2"));
        assert_eq!(parse_version("v24.1.0\n").as_deref(), Some("24.1.0"));
        assert_eq!(parse_version("no version"), None);
        assert!(version_at_least("18.12.2", "18.0.0"));
        assert!(!version_at_least("17.9.9", "18.0.0"));
    }

    #[test]
    fn omp_ready_or_outdated() {
        let registry = registry();
        let entry = registry.get("omp").expect("omp");
        let node = NodeStatus {
            required: "24.0.0".into(),
            found: Some("24.1.0".into()),
        };
        let ready = detect_agent(
            entry,
            &node,
            &StaticProbe::default().with("omp", "omp/18.12.2"),
        );
        assert_eq!(
            ready,
            AgentStatus::Ready {
                version: "18.12.2".into()
            }
        );
        let outdated = detect_agent(
            entry,
            &node,
            &StaticProbe::default().with("omp", "omp/17.0.0"),
        );
        assert!(matches!(outdated, AgentStatus::Outdated { .. }));
    }

    #[test]
    fn missing_agent_is_reported() {
        let registry = registry();
        let entry = registry.get("omp").expect("omp");
        let node = NodeStatus {
            required: "24.0.0".into(),
            found: Some("24.1.0".into()),
        };
        assert_eq!(
            detect_agent(entry, &node, &StaticProbe::default()),
            AgentStatus::Missing
        );
    }

    #[test]
    fn npx_agents_require_node_24() {
        let registry = registry();
        let codex = registry.get("codex").expect("codex");
        let old_node = NodeStatus {
            required: "24.0.0".into(),
            found: Some("22.22.3".into()),
        };
        assert!(matches!(
            detect_agent(codex, &old_node, &StaticProbe::default()),
            AgentStatus::NodeUnavailable { .. }
        ));

        let probe = StaticProbe::default()
            .with("node", "v24.1.0")
            .with("npx", "2.2.2");
        let detected = detect_all(&registry, &probe);
        assert_eq!(detected.len(), 3);
        assert!(matches!(
            &detected
                .iter()
                .find(|agent| agent.entry.id == "codex")
                .map(|agent| &agent.status),
            Some(AgentStatus::Ready { version }) if version == "2.2.2"
        ));
    }

    #[test]
    fn codex_detection_uses_official_package_and_version_flag() {
        struct ArgsProbe;
        impl CommandProbe for ArgsProbe {
            fn version(&self, program: &str, args: &[&str]) -> Result<String, String> {
                if program == "npx"
                    && args.contains(&"@agentclientprotocol/codex-acp")
                    && args.last() == Some(&"--version")
                {
                    Ok("2.2.2".to_string())
                } else {
                    Err("wrong probe args".to_string())
                }
            }
        }
        let registry = registry();
        let codex = registry.get("codex").expect("codex");
        let node = NodeStatus {
            required: "24.0.0".into(),
            found: Some("24.1.0".into()),
        };
        assert_eq!(
            detect_agent(codex, &node, &ArgsProbe),
            AgentStatus::Ready {
                version: "2.2.2".to_string()
            }
        );
    }

    #[test]
    fn detect_all_marks_node_status() {
        let registry = registry();
        let probe = StaticProbe::default().with("node", "v22.22.3");
        let detected = detect_all(&registry, &probe);
        let codex = detected
            .iter()
            .find(|agent| agent.entry.id == "codex")
            .expect("codex");
        assert!(matches!(codex.status, AgentStatus::NodeUnavailable { .. }));
        let omp = detected
            .iter()
            .find(|agent| agent.entry.id == "omp")
            .expect("omp");
        assert_eq!(omp.status, AgentStatus::Missing);
    }
}
