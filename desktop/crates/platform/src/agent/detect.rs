//! 本机 agent 探测：托管 Node、持久包入口和真实版本使用同一条启动路径。

use std::time::Duration;

use super::command::run_output;
use super::dsh_runtime::{probe_dsh_runtime, RuntimeProbe};
use super::launch::{build_launch, NodeRuntime};
use super::node_runtime::NODE_VERSION;
use crate::registry::manifest::{AgentEntry, Distribution, Registry};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NodeStatus {
    pub required: String,
    pub found: Option<String>,
}

impl NodeStatus {
    pub fn is_ready(&self) -> bool {
        self.found.as_deref().is_some_and(|found| {
            version_at_least(found, &self.required) && version_at_least(found, NODE_VERSION)
        })
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
    /// 非阻断运行时探测：UI 用于展示 DSH Desktop 版本 / bundled 来源。
    pub runtime: RuntimeProbe,
}

pub fn parse_version(output: &str) -> Option<String> {
    for token in output.split(|ch: char| !(ch.is_ascii_alphanumeric() || ch == '.')) {
        let token = token.trim_start_matches(['v', 'V']);
        let parts: Vec<&str> = token.split('.').collect();
        if parts.len() >= 3
            && parts
                .iter()
                .take(3)
                .all(|part| !part.is_empty() && part.chars().all(|ch| ch.is_ascii_digit()))
        {
            return Some(parts[..3].join("."));
        }
    }
    None
}

pub fn version_at_least(found: &str, required: &str) -> bool {
    let mut found = found
        .split('.')
        .map(|part| part.parse::<u64>().unwrap_or(0));
    let mut required = required
        .split('.')
        .map(|part| part.parse::<u64>().unwrap_or(0));
    for _ in 0..3 {
        match found.next().unwrap_or(0).cmp(&required.next().unwrap_or(0)) {
            std::cmp::Ordering::Greater => return true,
            std::cmp::Ordering::Less => return false,
            std::cmp::Ordering::Equal => {}
        }
    }
    true
}

pub fn detect_node(runtime: Option<&NodeRuntime>, required: &str) -> NodeStatus {
    // 签名清单描述 agent 的兼容下限；客户端安全基线不可被旧清单降低。
    let required = if version_at_least(required, NODE_VERSION) {
        required
    } else {
        NODE_VERSION
    };
    NodeStatus {
        required: required.to_string(),
        found: runtime.and_then(NodeRuntime::version),
    }
}

pub fn detect_all(registry: &Registry, runtime: Option<&NodeRuntime>) -> Vec<DetectedAgent> {
    let plugin = super::dsh_plugin::probe();
    detect_all_with(registry, runtime, plugin.as_ref())
}

/// 可注入 plugin 探测的版本（测试不依赖本机 DSH 安装）。
pub fn detect_all_with(
    registry: &Registry,
    runtime: Option<&NodeRuntime>,
    plugin: Option<&super::dsh_plugin::DshPlugin>,
) -> Vec<DetectedAgent> {
    let node = detect_node(runtime, &registry.node_required);
    registry
        .agents
        .iter()
        .map(|entry| {
            // ADR-0031 D1 修订：plugin 形态优先；profile 已装 adapter 即 Ready，
            // 不走 npm 包探测（plugin 用的是用户 DSH 的 runtime）。
            if let Some(plugin) = plugin.filter(|_| entry.uses_dsh_runtime()) {
                return DetectedAgent {
                    entry: entry.clone(),
                    status: AgentStatus::Ready {
                        version: plugin.version.clone(),
                    },
                    runtime: RuntimeProbe::plugin(plugin.version.clone(), plugin.dsh.clone()),
                };
            }
            let runtime_probe = if entry.uses_dsh_runtime() {
                probe_dsh_runtime(Some(entry), runtime)
            } else {
                RuntimeProbe::missing()
            };
            DetectedAgent {
                entry: entry.clone(),
                status: detect_agent(entry, runtime, &node),
                runtime: runtime_probe,
            }
        })
        .collect()
}

pub fn detect_agent(
    entry: &AgentEntry,
    runtime: Option<&NodeRuntime>,
    node: &NodeStatus,
) -> AgentStatus {
    if matches!(entry.distribution, Distribution::Npx { .. }) && !node.is_ready() {
        return AgentStatus::NodeUnavailable {
            required: node.required.clone(),
            found: node.found.clone(),
        };
    }
    let mut plan = match build_launch(entry, runtime, &std::env::temp_dir()) {
        Ok(plan) => plan,
        Err(_) => return AgentStatus::Missing,
    };
    if matches!(entry.distribution, Distribution::Npx { .. }) {
        plan.args.truncate(1);
    } else {
        plan.args.clear();
    }
    plan.args.extend(if entry.version_args.is_empty() {
        vec!["--version".to_string()]
    } else {
        entry.version_args.clone()
    });
    let output = match run_output(&plan, Duration::from_secs(5)) {
        Ok(output) => output,
        Err(error) => return AgentStatus::Error(error),
    };
    match parse_version(&output) {
        Some(version) => {
            let required = match &entry.distribution {
                Distribution::Npx { version, .. } => version,
                _ => &entry.minimum_version,
            };
            if matches!(entry.distribution, Distribution::Npx { .. }) && &version != required {
                AgentStatus::Error(format!("expected pinned agent {required}, got {version}"))
            } else if version_at_least(&version, required) {
                AgentStatus::Ready { version }
            } else {
                AgentStatus::Outdated {
                    found: version,
                    required: required.clone(),
                }
            }
        }
        None => AgentStatus::Error("cannot parse agent version".to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plugin_form_wins_for_dsh_entry() {
        let registry = Registry::builtin().expect("registry");
        let plugin = crate::agent::dsh_plugin::DshPlugin {
            dsh: std::path::PathBuf::from("/tmp/dsh"),
            home: std::path::PathBuf::from("/tmp/dsh-home"),
            version: "0.4.41".to_string(),
        };
        let rows = detect_all_with(&registry, None, Some(&plugin));
        let dsh = rows
            .iter()
            .find(|row| row.entry.id == "deepseek")
            .expect("deepseek row");
        assert_eq!(
            dsh.status,
            AgentStatus::Ready {
                version: "0.4.41".to_string()
            }
        );
        assert_eq!(
            dsh.runtime.source,
            crate::agent::dsh_runtime::RuntimeSource::Plugin
        );
        assert_eq!(dsh.runtime.version.as_deref(), Some("0.4.41"));
        // 非 DSH 条目不受 plugin 影响（没有 Node 时仍是 NodeUnavailable）。
        let codex = rows
            .iter()
            .find(|row| row.entry.id == "codex")
            .expect("codex");
        assert!(matches!(codex.status, AgentStatus::NodeUnavailable { .. }));
    }

    #[test]
    fn parses_versions_from_cli_output() {
        assert_eq!(parse_version("omp/18.12.2").as_deref(), Some("18.12.2"));
        assert_eq!(parse_version("v24.1.0\n").as_deref(), Some("24.1.0"));
        assert_eq!(parse_version("no version"), None);
        assert!(version_at_least("18.12.2", "18.0.0"));
        assert!(!version_at_least("17.9.9", "18.0.0"));
    }
}
