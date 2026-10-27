//! Native agent 的工作区 scope（ADR-0028 / Stage 3.5a 全局 Agent Panel）。
//!
//! 所有页面共用同一个 assistant 工作区：`~/cgc2046_workspace/assistant/<userId>`。
//! 课程页不再拥有专用工作区/线程——课程上下文（course/revision/unit）改为在
//! prompt 里附加（见 `page_context`），符合「全局 Agent Panel + 课程页只传上下文」。
//!
//! `CGC_AGENT_WORKSPACE` takes precedence; RootView explicitly supplies each owner scope.

use std::path::{Path, PathBuf};

/// 一个页面 scope 对应的 agent 工作区。
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct AgentScope {
    /// 稳定的 scope key（用于线程 id / checkpoint 命名）。
    pub key: String,
    /// 工作区根目录（sandbox 根、checkpoint 仓库、线程归属都按它）。
    pub root: PathBuf,
}

/// 解析当前 scope（Stage 3.5a 起与页面无关，始终是 assistant 工作区）。
pub(crate) fn resolve(user_id: Option<&str>) -> AgentScope {
    if let Some(root) = std::env::var_os("CGC_AGENT_WORKSPACE") {
        let root = PathBuf::from(root);
        return AgentScope {
            key: format!("env-{}", short_key(&root)),
            root,
        };
    }
    let base = workspace_base();
    let user = sanitize(user_id.unwrap_or("local"));
    let root = base.join("assistant").join(&user);
    AgentScope {
        key: format!("assistant-{user}"),
        root,
    }
}

fn workspace_base() -> PathBuf {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir)
        .join("cgc2046_workspace")
}

/// 目录名/线程 id 安全字符：保留 ASCII 字母数字、`-`、`_`，其余替换为 `-`。
fn sanitize(raw: &str) -> String {
    let mut sanitized: String = raw
        .chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() || ch == '-' || ch == '_' {
                ch
            } else {
                '-'
            }
        })
        .collect();
    if sanitized.is_empty() {
        sanitized.push_str("local");
    }
    sanitized
}

/// 线程 id 前缀的短 key；过长的环境路径做截断。
fn short_key(root: &Path) -> String {
    let raw = sanitize(&root.display().to_string());
    if raw.chars().count() <= 48 {
        raw
    } else {
        raw.chars().take(48).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn resolve_at(base: &Path, user: Option<&str>, env_override: Option<&Path>) -> AgentScope {
        if let Some(root) = env_override {
            return AgentScope {
                key: format!("env-{}", short_key(root)),
                root: root.to_path_buf(),
            };
        }
        let user = sanitize(user.unwrap_or("local"));
        AgentScope {
            key: format!("assistant-{user}"),
            root: base.join("assistant").join(&user),
        }
    }

    #[test]
    fn all_pages_share_assistant_scope() {
        let base = Path::new("/tmp/cgc-base");
        let assistant = resolve_at(base, Some("u1"), None);
        assert_eq!(assistant.key, "assistant-u1");
        assert_eq!(assistant.root, base.join("assistant/u1"));

        let anonymous = resolve_at(base, None, None);
        assert_eq!(anonymous.key, "assistant-local");
        assert_eq!(anonymous.root, base.join("assistant/local"));
    }

    #[test]
    fn env_override_wins_and_sanitizes_keys() {
        let base = Path::new("/tmp/cgc-base");
        let env = resolve_at(base, Some("u1"), Some(Path::new("/tmp/custom-ws")));
        assert!(env.key.starts_with("env-"));
        assert_eq!(env.root, Path::new("/tmp/custom-ws"));

        assert_eq!(sanitize("../../etc"), "------etc");
    }
}
