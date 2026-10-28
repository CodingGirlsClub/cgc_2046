use std::path::{Path, PathBuf};
use std::sync::Arc;

use cgc_agent_provider::ToolSchema;
use futures::future::BoxFuture;

use crate::{approval::Approval, error::ToolError};

/// 工具结果：文本内容 + 是否错误；后续可扩展结构化结果。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ToolResult {
    pub content: String,
    pub is_error: bool,
}

impl ToolResult {
    pub fn ok(content: impl Into<String>) -> Self {
        Self {
            content: content.into(),
            is_error: false,
        }
    }

    pub fn error(content: impl Into<String>) -> Self {
        Self {
            content: content.into(),
            is_error: true,
        }
    }
}

/// 工具执行上下文：工作区根目录是唯一允许访问的路径。
#[derive(Clone)]
pub struct ToolContext {
    workspace: PathBuf,
    max_read_bytes: u64,
    sandbox: Option<crate::sandbox::SandboxPolicy>,
    action_sink: Option<crate::action::ActionSink>,
    cancel: Option<CancelProbe>,
}

/// 取消探针：工具在长操作中周期性查询，Stop 后立刻收尾而不是等到自身 timeout。
/// 由宿主（agent_core/agent_host）把 turn 的取消令牌桥接进来；`agent_tools`
/// 不依赖 core，因此用闭包而不是 `CancelToken` 类型。
pub type CancelProbe = Arc<dyn Fn() -> bool + Send + Sync>;

impl ToolContext {
    pub fn new(workspace: impl Into<PathBuf>) -> Self {
        Self {
            workspace: workspace.into(),
            max_read_bytes: 256 * 1024,
            sandbox: None,
            action_sink: None,
            cancel: None,
        }
    }

    /// 接入本轮 turn 的取消探针。
    pub fn with_cancel(mut self, cancel: CancelProbe) -> Self {
        self.cancel = Some(cancel);
        self
    }

    /// 本轮是否已被取消；没有探针时恒为 false（headless 调用保持原行为）。
    pub fn is_cancelled(&self) -> bool {
        self.cancel.as_ref().is_some_and(|cancel| cancel())
    }

    /// 把探针交给需要在自己线程里轮询的工具（如长命令执行）。
    pub fn cancel_probe(&self) -> Option<CancelProbe> {
        self.cancel.clone()
    }

    pub fn with_action_sink(mut self, action_sink: crate::action::ActionSink) -> Self {
        self.action_sink = Some(action_sink);
        self
    }

    /// 向客户端投递一个应用内动作；没有 sink 时静默忽略。
    pub fn emit_action(&self, action: crate::action::AppAction) {
        if let Some(sink) = &self.action_sink {
            sink(action);
        }
    }

    pub fn with_sandbox(mut self, sandbox: crate::sandbox::SandboxPolicy) -> Self {
        self.sandbox = Some(sandbox);
        self
    }

    pub fn sandbox(&self) -> Option<&crate::sandbox::SandboxPolicy> {
        self.sandbox.as_ref()
    }

    pub fn workspace(&self) -> &Path {
        &self.workspace
    }

    pub fn max_read_bytes(&self) -> u64 {
        self.max_read_bytes
    }

    pub fn with_max_read_bytes(mut self, max_read_bytes: u64) -> Self {
        self.max_read_bytes = max_read_bytes;
        self
    }

    /// 解析工作区内的相对路径：拒绝绝对路径与 `..` 逃逸，并校验最终目标本身。
    ///
    /// 只校验父目录不够：工作区内可以存在指向工作区外的符号链接（含悬空链接），
    /// 直接拼上最后一段会让 read / list 顺着链接读到工作区外。
    pub fn resolve(&self, path: &str) -> Result<PathBuf, ToolError> {
        let resolved = self.normalize_relative(path)?;
        let root = self.workspace_root()?;
        if resolved.as_os_str().is_empty() {
            return Ok(root);
        }
        let joined = root.join(&resolved);
        let parent = joined.parent().unwrap_or(&root);
        let parent = parent
            .canonicalize()
            .map_err(|_| ToolError::NotFound(path.to_string()))?;
        if !parent.starts_with(&root) {
            return Err(ToolError::PathEscape(path.to_string()));
        }
        let candidate = parent.join(joined.file_name().unwrap_or_default());
        match std::fs::symlink_metadata(&candidate) {
            // 最终目标本身是符号链接：必须解析到工作区内；悬空链接解析失败，
            // 按逃逸处理（fail-closed）。
            Ok(metadata) if metadata.file_type().is_symlink() => {
                let target = candidate
                    .canonicalize()
                    .map_err(|_| ToolError::PathEscape(path.to_string()))?;
                if !target.starts_with(&root) {
                    return Err(ToolError::PathEscape(path.to_string()));
                }
                Ok(target)
            }
            _ => Ok(candidate),
        }
    }

    /// 写入场景的路径解析：允许父目录尚不存在，但仍阻止越出工作区。
    pub fn resolve_for_write(&self, path: &str) -> Result<PathBuf, ToolError> {
        let resolved = self.normalize_relative(path)?;
        let root = self.workspace_root()?;
        if resolved.as_os_str().is_empty() {
            return Ok(root);
        }
        let candidate = root.join(&resolved);
        // 已存在的最终目标若是符号链接，写入会落到链接指向的位置：先校验真实目标。
        if let Ok(metadata) = std::fs::symlink_metadata(&candidate) {
            if metadata.file_type().is_symlink() {
                let target = candidate
                    .canonicalize()
                    .map_err(|_| ToolError::PathEscape(path.to_string()))?;
                if !target.starts_with(&root) {
                    return Err(ToolError::PathEscape(path.to_string()));
                }
                return Ok(target);
            }
        }
        let mut ancestor = candidate.parent();
        while let Some(dir) = ancestor {
            if dir.exists() {
                let canonical = dir
                    .canonicalize()
                    .map_err(|error| ToolError::Io(error.to_string()))?;
                if !canonical.starts_with(&root) {
                    return Err(ToolError::PathEscape(path.to_string()));
                }
                break;
            }
            ancestor = dir.parent();
        }
        Ok(candidate)
    }

    fn workspace_root(&self) -> Result<PathBuf, ToolError> {
        self.workspace
            .canonicalize()
            .map_err(|error| ToolError::Io(error.to_string()))
    }

    fn normalize_relative(&self, path: &str) -> Result<PathBuf, ToolError> {
        let candidate = Path::new(path);
        if candidate.is_absolute() || has_drive_prefix(path) {
            return Err(ToolError::PathEscape(path.to_string()));
        }
        let mut resolved = PathBuf::new();
        for component in candidate.components() {
            use std::path::Component;
            match component {
                Component::Normal(part) => resolved.push(part),
                Component::CurDir => {}
                Component::ParentDir => {
                    if !resolved.pop() {
                        return Err(ToolError::PathEscape(path.to_string()));
                    }
                }
                Component::RootDir | Component::Prefix(_) => {
                    return Err(ToolError::PathEscape(path.to_string()));
                }
            }
        }
        Ok(resolved)
    }

    /// 只读工具的统一入口：校验大小后读取为 UTF-8 文本。
    pub fn read_text(&self, path: &str) -> Result<(PathBuf, String), ToolError> {
        let path = self.resolve(path)?;
        let metadata = std::fs::metadata(&path).map_err(|error| {
            if error.kind() == std::io::ErrorKind::NotFound {
                ToolError::NotFound(path.display().to_string())
            } else {
                ToolError::Io(error.to_string())
            }
        })?;
        if !metadata.is_file() {
            return Err(ToolError::InvalidArgs(format!(
                "not a file: {}",
                path.display()
            )));
        }
        if metadata.len() > self.max_read_bytes {
            return Err(ToolError::TooLarge(path.display().to_string()));
        }
        let content = std::fs::read_to_string(&path)?;
        Ok((path, content))
    }
}

fn has_drive_prefix(path: &str) -> bool {
    path.len() > 2 && path.as_bytes()[1] == b':'
}

/// 一个 Agent 工具。`run` 返回的 future 必须是 'static + Send，便于并发执行。
pub trait Tool: Send + Sync {
    fn name(&self) -> &str;

    fn description(&self) -> &str;

    fn schema(&self) -> serde_json::Value;

    /// 审批分类：只读工具默认 Allow，写/执行默认 Ask。
    fn approval(&self, _args: &serde_json::Value) -> Approval {
        Approval::Allow
    }

    fn run(
        &self,
        args: serde_json::Value,
        context: ToolContext,
    ) -> BoxFuture<'static, Result<ToolResult, ToolError>>;

    fn to_schema(&self) -> ToolSchema {
        ToolSchema::new(self.name(), self.description(), self.schema())
    }
}

/// 工作区内符号链接的越界校验（Codex review P1）。
///
/// 只校验父目录时，`ws/link.txt -> /outside/secret` 会被 read_file 读出来、
/// 被 write_file 覆盖到工作区外，所以最终目标本身也要校验。
#[cfg(all(test, unix))]
mod symlink_escape_tests {
    use super::*;

    fn temp_dir(tag: &str) -> PathBuf {
        use std::sync::atomic::{AtomicU64, Ordering};
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let serial = COUNTER.fetch_add(1, Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!(
            "cgc-agent-tools-symlink-{}-{tag}-{serial}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("temp dir");
        dir
    }

    #[test]
    fn read_through_symlink_escaping_workspace_is_rejected() {
        let root = temp_dir("read-escape");
        let outside = temp_dir("read-outside");
        std::fs::write(outside.join("secret.txt"), b"secret").expect("secret");
        std::os::unix::fs::symlink(outside.join("secret.txt"), root.join("link.txt"))
            .expect("symlink");

        let context = ToolContext::new(root.clone());
        assert_eq!(
            context.resolve("link.txt"),
            Err(ToolError::PathEscape("link.txt".to_string()))
        );
        // 读入口也必须被拦，而不是只在 resolve 上拦。
        assert!(context.read_text("link.txt").is_err());

        let _ = std::fs::remove_dir_all(&root);
        let _ = std::fs::remove_dir_all(&outside);
    }

    #[test]
    fn write_through_symlink_escaping_workspace_is_rejected() {
        let root = temp_dir("write-escape");
        let outside = temp_dir("write-outside");
        let target = outside.join("victim.txt");
        std::fs::write(&target, b"original").expect("victim");
        std::os::unix::fs::symlink(&target, root.join("link.txt")).expect("symlink");

        let context = ToolContext::new(root.clone());
        assert_eq!(
            context.resolve_for_write("link.txt"),
            Err(ToolError::PathEscape("link.txt".to_string()))
        );
        assert_eq!(std::fs::read(&target).expect("read victim"), b"original");

        let _ = std::fs::remove_dir_all(&root);
        let _ = std::fs::remove_dir_all(&outside);
    }

    #[test]
    fn dangling_symlink_pointing_outside_is_rejected() {
        let root = temp_dir("dangling");
        let outside = temp_dir("dangling-outside");
        std::os::unix::fs::symlink(outside.join("missing.txt"), root.join("link.txt"))
            .expect("symlink");

        let context = ToolContext::new(root.clone());
        assert!(matches!(
            context.resolve("link.txt"),
            Err(ToolError::PathEscape(_))
        ));
        assert!(matches!(
            context.resolve_for_write("link.txt"),
            Err(ToolError::PathEscape(_))
        ));

        let _ = std::fs::remove_dir_all(&root);
        let _ = std::fs::remove_dir_all(&outside);
    }

    #[test]
    fn symlink_inside_workspace_still_works() {
        let root = temp_dir("inside");
        std::fs::write(root.join("real.txt"), b"inside").expect("real");
        std::os::unix::fs::symlink(root.join("real.txt"), root.join("link.txt")).expect("symlink");

        let context = ToolContext::new(root.clone());
        let resolved = context.resolve("link.txt").expect("resolve inside symlink");
        assert_eq!(
            resolved,
            root.canonicalize()
                .expect("canonical root")
                .join("real.txt")
        );
        assert_eq!(context.read_text("link.txt").expect("read").1, "inside");

        let _ = std::fs::remove_dir_all(&root);
    }
}
