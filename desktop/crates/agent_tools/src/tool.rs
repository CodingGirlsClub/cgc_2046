use std::path::{Path, PathBuf};

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
#[derive(Clone, Debug)]
pub struct ToolContext {
    workspace: PathBuf,
    max_read_bytes: u64,
}

impl ToolContext {
    pub fn new(workspace: impl Into<PathBuf>) -> Self {
        Self {
            workspace: workspace.into(),
            max_read_bytes: 256 * 1024,
        }
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

    /// 解析工作区内的相对路径：拒绝绝对路径与 `..` 逃逸。
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
        Ok(parent.join(joined.file_name().unwrap_or_default()))
    }

    /// 写入场景的路径解析：允许父目录尚不存在，但仍阻止越出工作区。
    pub fn resolve_for_write(&self, path: &str) -> Result<PathBuf, ToolError> {
        let resolved = self.normalize_relative(path)?;
        let root = self.workspace_root()?;
        if resolved.as_os_str().is_empty() {
            return Ok(root);
        }
        let candidate = root.join(&resolved);
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
    fn name(&self) -> &'static str;

    fn description(&self) -> &'static str;

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
