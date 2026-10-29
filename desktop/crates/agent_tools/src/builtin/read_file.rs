use futures::future::BoxFuture;

use crate::{
    approval::Approval,
    error::ToolError,
    tool::{Tool, ToolContext, ToolResult},
};

/// 读取工作区内的文本文件。
pub struct ReadFileTool;

impl Tool for ReadFileTool {
    fn name(&self) -> &'static str {
        "read_file"
    }

    fn description(&self) -> &'static str {
        "Read a UTF-8 text file inside the workspace. Returns the file content."
    }

    fn schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "properties": {
                "path": { "type": "string", "description": "Workspace-relative file path" }
            },
            "required": ["path"]
        })
    }

    fn approval(&self, _args: &serde_json::Value) -> Approval {
        Approval::Allow
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
            let (resolved, content) = context.read_text(path)?;
            Ok(ToolResult::ok(format!(
                "{}\n{}",
                resolved.display(),
                content
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
            "cgc-agent-tools-{}-{tag}-{serial}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("workspace");
        dir
    }

    #[test]
    fn reads_file_inside_workspace() {
        let workspace = temp_workspace("read");
        std::fs::write(workspace.join("a.txt"), "hello").expect("write");
        let context = ToolContext::new(&workspace);
        let result = futures::executor::block_on(
            ReadFileTool.run(serde_json::json!({"path": "a.txt"}), context),
        )
        .expect("read");
        assert!(result.content.ends_with("hello"));
        let _ = std::fs::remove_dir_all(&workspace);
    }

    #[test]
    fn rejects_path_escape() {
        let workspace = temp_workspace("escape");
        let context = ToolContext::new(&workspace);
        let error = futures::executor::block_on(
            ReadFileTool.run(serde_json::json!({"path": "../secret.txt"}), context),
        )
        .unwrap_err();
        assert!(matches!(error, ToolError::PathEscape(_)));
        let _ = std::fs::remove_dir_all(&workspace);
    }

    #[test]
    fn rejects_absolute_path() {
        let workspace = temp_workspace("absolute");
        let context = ToolContext::new(&workspace);
        let error = futures::executor::block_on(
            ReadFileTool.run(serde_json::json!({"path": "/etc/passwd"}), context),
        )
        .unwrap_err();
        assert!(matches!(error, ToolError::PathEscape(_)));
        let _ = std::fs::remove_dir_all(&workspace);
    }

    #[test]
    fn enforces_size_limit() {
        let workspace = temp_workspace("size");
        std::fs::write(workspace.join("big.txt"), "0123456789").expect("write");
        let context = ToolContext::new(&workspace).with_max_read_bytes(4);
        let error = futures::executor::block_on(
            ReadFileTool.run(serde_json::json!({"path": "big.txt"}), context),
        )
        .unwrap_err();
        assert!(matches!(error, ToolError::TooLarge(_)));
        let _ = std::fs::remove_dir_all(&workspace);
    }
}
