use futures::future::BoxFuture;

use crate::{
    approval::Approval,
    error::ToolError,
    tool::{Tool, ToolContext, ToolResult},
};

/// 列出工作区目录（默认根目录）。
pub struct ListDirectoryTool;

impl Tool for ListDirectoryTool {
    fn name(&self) -> &'static str {
        "list_directory"
    }

    fn description(&self) -> &'static str {
        "List entries of a directory inside the workspace, sorted by name."
    }

    fn schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "properties": {
                "path": { "type": "string", "description": "Workspace-relative directory; defaults to ." }
            }
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
                .unwrap_or(".");
            let resolved = context.resolve(path)?;
            let mut entries = Vec::new();
            for entry in std::fs::read_dir(&resolved)? {
                let entry = entry?;
                let name = entry.file_name().to_string_lossy().to_string();
                let suffix = if entry.file_type()?.is_dir() { "/" } else { "" };
                entries.push(format!("{name}{suffix}"));
            }
            entries.sort();
            entries.truncate(200);
            Ok(ToolResult::ok(entries.join("\n")))
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lists_and_sorts_entries() {
        let workspace =
            std::env::temp_dir().join(format!("cgc-agent-tools-list-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&workspace);
        std::fs::create_dir_all(workspace.join("sub")).expect("workspace");
        std::fs::write(workspace.join("b.txt"), "b").expect("b");
        std::fs::write(workspace.join("a.txt"), "a").expect("a");
        let context = ToolContext::new(&workspace);
        let result =
            futures::executor::block_on(ListDirectoryTool.run(serde_json::json!({}), context))
                .expect("list");
        assert_eq!(result.content, "a.txt\nb.txt\nsub/");
        let _ = std::fs::remove_dir_all(&workspace);
    }

    #[test]
    fn rejects_escape() {
        let workspace = std::env::temp_dir().join(format!(
            "cgc-agent-tools-list-escape-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&workspace);
        std::fs::create_dir_all(&workspace).expect("workspace");
        let context = ToolContext::new(&workspace);
        let error = futures::executor::block_on(
            ListDirectoryTool.run(serde_json::json!({"path": "../../"}), context),
        )
        .unwrap_err();
        assert!(matches!(error, ToolError::PathEscape(_)));
        let _ = std::fs::remove_dir_all(&workspace);
    }
}
