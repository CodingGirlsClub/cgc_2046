//! 本机 agent 探测：托管 Node、持久包入口和真实版本使用同一条启动路径。

use std::time::Duration;

use super::command::run_output;
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
    let node = detect_node(runtime, &registry.node_required);
    registry
        .agents
        .iter()
        .map(|entry| DetectedAgent {
            entry: entry.clone(),
            status: detect_agent(entry, runtime, &node),
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
    fn parses_versions_from_cli_output() {
        assert_eq!(parse_version("omp/18.12.2").as_deref(), Some("18.12.2"));
        assert_eq!(parse_version("v24.1.0\n").as_deref(), Some("24.1.0"));
        assert_eq!(parse_version("no version"), None);
        assert!(version_at_least("18.12.2", "18.0.0"));
        assert!(!version_at_least("17.9.9", "18.0.0"));
    }
}
