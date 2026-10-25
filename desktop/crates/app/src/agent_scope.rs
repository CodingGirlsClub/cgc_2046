//! Native agent 的工作区 scope（ADR-0028）。
//!
//! 工作区按页面作用域解析：
//! - 课程页：`~/cgc2046_workspace/courses/<userId>/<courseId>`
//! - 其它页面：`~/cgc2046_workspace/assistant/<userId>`
//!
//! `CGC_AGENT_WORKSPACE` 优先（开发/E2E 显式指定工作区）；全局 current 由
//! RootView 在渲染前刷新，NativeAgentView 渲染时比较并切换线程/工作区。

use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};

/// 一个页面 scope 对应的 agent 工作区。
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct AgentScope {
    /// 稳定的 scope key（用于线程 id / checkpoint 命名）。
    pub key: String,
    /// 工作区根目录（sandbox 根、checkpoint 仓库、线程归属都按它）。
    pub root: PathBuf,
}

static CURRENT: OnceLock<Mutex<Option<AgentScope>>> = OnceLock::new();

fn current_slot() -> &'static Mutex<Option<AgentScope>> {
    CURRENT.get_or_init(|| Mutex::new(None))
}

/// 设置全局当前 scope；返回是否发生变化。
pub(crate) fn set_current(scope: AgentScope) -> bool {
    let mut slot = current_slot()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    if slot.as_ref() == Some(&scope) {
        return false;
    }
    *slot = Some(scope);
    true
}

pub(crate) fn current() -> Option<AgentScope> {
    current_slot()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .clone()
}

/// 解析当前 scope。`user_id` / `active_tab_path` 来自登录态与当前 tab。
pub(crate) fn resolve(user_id: Option<&str>, active_tab_path: Option<&str>) -> AgentScope {
    if let Some(root) = std::env::var_os("CGC_AGENT_WORKSPACE") {
        let root = PathBuf::from(root);
        let _ = std::fs::create_dir_all(&root);
        return AgentScope {
            key: format!("env-{}", short_key(&root)),
            root,
        };
    }
    let base = workspace_base();
    let user = sanitize(user_id.unwrap_or("local"));
    if let Some(course_id) = active_tab_path.and_then(course_id_from_path) {
        let course = sanitize(&course_id);
        let root = base.join("courses").join(&user).join(&course);
        let _ = std::fs::create_dir_all(&root);
        return AgentScope {
            key: format!("course-{course}"),
            root,
        };
    }
    let root = base.join("assistant").join(&user);
    let _ = std::fs::create_dir_all(&root);
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

/// `/courses/<id>` 或 `/courses/<id>/...` → `<id>`。
fn course_id_from_path(path: &str) -> Option<String> {
    let rest = path.strip_prefix("/courses/")?;
    let id = rest.split('/').next().unwrap_or_default();
    if id.is_empty() {
        None
    } else {
        Some(id.to_string())
    }
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

    fn resolve_at(
        base: &Path,
        user: Option<&str>,
        active_tab_path: Option<&str>,
        env_override: Option<&Path>,
    ) -> AgentScope {
        if let Some(root) = env_override {
            return AgentScope {
                key: format!("env-{}", short_key(root)),
                root: root.to_path_buf(),
            };
        }
        let user = sanitize(user.unwrap_or("local"));
        if let Some(course_id) = active_tab_path.and_then(course_id_from_path) {
            let course = sanitize(&course_id);
            return AgentScope {
                key: format!("course-{course}"),
                root: base.join("courses").join(&user).join(&course),
            };
        }
        AgentScope {
            key: format!("assistant-{user}"),
            root: base.join("assistant").join(&user),
        }
    }

    #[test]
    fn resolves_course_and_assistant_scopes() {
        let base = Path::new("/tmp/cgc-base");
        let course = resolve_at(base, Some("u1"), Some("/courses/c1/learn"), None);
        assert_eq!(course.key, "course-c1");
        assert_eq!(course.root, base.join("courses/u1/c1"));

        let assistant = resolve_at(base, Some("u1"), Some("/workspace"), None);
        assert_eq!(assistant.key, "assistant-u1");
        assert_eq!(assistant.root, base.join("assistant/u1"));

        let anonymous = resolve_at(base, None, None, None);
        assert_eq!(anonymous.key, "assistant-local");
        assert_eq!(anonymous.root, base.join("assistant/local"));
    }

    #[test]
    fn env_override_wins_and_sanitizes_keys() {
        let base = Path::new("/tmp/cgc-base");
        let env = resolve_at(
            base,
            Some("u1"),
            Some("/courses/c1"),
            Some(Path::new("/tmp/custom-ws")),
        );
        assert!(env.key.starts_with("env-"));
        assert_eq!(env.root, Path::new("/tmp/custom-ws"));

        assert_eq!(sanitize("../../etc"), "------etc");
        assert_eq!(course_id_from_path("/courses/c1/learn"), Some("c1".into()));
        assert_eq!(course_id_from_path("/courses/"), None);
        assert_eq!(course_id_from_path("/workspace"), None);
    }

    #[test]
    fn set_current_reports_changes() {
        let first = AgentScope {
            key: "test-first".into(),
            root: PathBuf::from("/tmp/first"),
        };
        let second = AgentScope {
            key: "test-second".into(),
            root: PathBuf::from("/tmp/second"),
        };
        assert!(set_current(first.clone()));
        assert!(!set_current(first.clone()), "same scope should not notify");
        assert!(set_current(second.clone()));
        assert_eq!(current(), Some(second));
    }
}
