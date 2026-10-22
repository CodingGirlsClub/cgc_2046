use std::sync::Arc;

use cgc_agent_provider::ToolSchema;
use futures::future::BoxFuture;

use crate::{
    approval::Approval,
    error::ToolError,
    tool::{Tool, ToolContext, ToolResult},
};

/// 已注册工具集合。
#[derive(Default)]
pub struct ToolRegistry {
    tools: Vec<Arc<dyn Tool>>,
}

impl ToolRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with_read_tools() -> Self {
        let mut registry = Self::new();
        registry.register(Arc::new(crate::builtin::ReadFileTool));
        registry.register(Arc::new(crate::builtin::ListDirectoryTool));
        registry
    }

    pub fn register(&mut self, tool: Arc<dyn Tool>) {
        self.tools.push(tool);
    }

    pub fn get(&self, name: &str) -> Option<&Arc<dyn Tool>> {
        self.tools.iter().find(|tool| tool.name() == name)
    }

    pub fn schemas(&self) -> Vec<ToolSchema> {
        self.tools.iter().map(|tool| tool.to_schema()).collect()
    }

    pub fn approval(&self, name: &str, args: &serde_json::Value) -> Option<Approval> {
        self.get(name).map(|tool| tool.approval(args))
    }

    pub fn run(
        &self,
        name: &str,
        args: serde_json::Value,
        context: ToolContext,
    ) -> BoxFuture<'static, Result<ToolResult, ToolError>> {
        match self.get(name).cloned() {
            Some(tool) => tool.run(args, context),
            None => {
                let name = name.to_string();
                Box::pin(
                    async move { Err(ToolError::InvalidArgs(format!("unknown tool: {name}"))) },
                )
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_workspace() -> std::path::PathBuf {
        use std::sync::atomic::{AtomicU64, Ordering};
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let serial = COUNTER.fetch_add(1, Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!(
            "cgc-agent-tools-registry-{}-{serial}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("workspace");
        dir
    }

    #[test]
    fn read_registry_exposes_schemas_and_approval() {
        let registry = ToolRegistry::with_read_tools();
        let schemas = registry.schemas();
        let names: Vec<_> = schemas.iter().map(|schema| schema.name.as_str()).collect();
        assert!(names.contains(&"read_file"));
        assert!(names.contains(&"list_directory"));
        assert_eq!(
            registry.approval("read_file", &serde_json::json!({})),
            Some(Approval::Allow)
        );
        assert_eq!(registry.approval("missing", &serde_json::json!({})), None);
    }

    #[test]
    fn registry_runs_known_tool_and_errors_on_unknown() {
        let workspace = temp_workspace();
        std::fs::write(workspace.join("a.txt"), "hi").expect("write");
        let registry = ToolRegistry::with_read_tools();
        let result = futures::executor::block_on(registry.run(
            "read_file",
            serde_json::json!({"path": "a.txt"}),
            ToolContext::new(&workspace),
        ))
        .expect("read");
        assert!(result.content.ends_with("hi"));

        let error = futures::executor::block_on(registry.run(
            "missing",
            serde_json::json!({}),
            ToolContext::new(&workspace),
        ))
        .unwrap_err();
        assert!(matches!(error, ToolError::InvalidArgs(_)));
        let _ = std::fs::remove_dir_all(&workspace);
    }
}
