use futures::future::BoxFuture;

use crate::{
    approval::Approval,
    error::ToolError,
    tool::{Tool, ToolContext, ToolResult},
};

/// 写入工作区内的文本文件；默认需要用户确认。
pub struct WriteFileTool;

impl Tool for WriteFileTool {
    fn name(&self) -> &'static str {
        "write_file"
    }

    fn description(&self) -> &'static str {
        "Create or overwrite a UTF-8 text file inside the workspace. Requires approval."
    }

    fn schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "properties": {
                "path": { "type": "string", "description": "Workspace-relative file path" },
                "content": { "type": "string", "description": "Full file content" }
            },
            "required": ["path", "content"]
        })
    }

    fn approval(&self, _args: &serde_json::Value) -> Approval {
        Approval::Ask
    }

    fn run(
        &self,
        args: serde_json::Value,
        context: ToolContext,
    ) -> BoxFuture<'static, Result<ToolResult, ToolError>> {
        Box::pin(async move {
            let path = args
                .get("path")
                .and_then(|value| value.as_str())
                .ok_or_else(|| ToolError::InvalidArgs("missing path".to_string()))?;
            let content = args
                .get("content")
                .and_then(|value| value.as_str())
                .ok_or_else(|| ToolError::InvalidArgs("missing content".to_string()))?;
            let resolved = context.resolve_for_write(path)?;
            if let Some(parent) = resolved.parent() {
                std::fs::create_dir_all(parent)?;
            }
            std::fs::write(&resolved, content)?;
            Ok(ToolResult::ok(format!(
                "wrote {} bytes to {}",
                content.len(),
                resolved.display()
            )))
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_workspace(tag: &str) -> std::path::PathBuf {
        use std::sync::atomic::{AtomicU64, Ordering};
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let serial = COUNTER.fetch_add(1, Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!(
            "cgc-agent-tools-write-{}-{tag}-{serial}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("workspace");
        dir
    }

    #[test]
    fn writes_file_and_creates_parent() {
        let workspace = temp_workspace("write");
        let context = ToolContext::new(&workspace);
        let result = futures::executor::block_on(WriteFileTool.run(
            serde_json::json!({"path": "nested/a.txt", "content": "hello"}),
            context,
        ))
        .expect("write");
        assert!(result.content.contains("wrote 5 bytes"));
        assert_eq!(
            std::fs::read_to_string(workspace.join("nested/a.txt")).unwrap(),
            "hello"
        );
        let _ = std::fs::remove_dir_all(&workspace);
    }

    #[test]
    fn write_requires_approval() {
        assert_eq!(
            WriteFileTool.approval(&serde_json::json!({})),
            Approval::Ask
        );
    }

    #[test]
    fn write_rejects_escape() {
        let workspace = temp_workspace("escape");
        let context = ToolContext::new(&workspace);
        let error = futures::executor::block_on(WriteFileTool.run(
            serde_json::json!({"path": "../escape.txt", "content": "x"}),
            context,
        ))
        .unwrap_err();
        assert!(matches!(error, ToolError::PathEscape(_)));
        let _ = std::fs::remove_dir_all(&workspace);
    }
}
