use std::sync::Arc;

use futures::future::BoxFuture;

use crate::{
    approval::Approval,
    error::ToolError,
    tool::{Tool, ToolContext, ToolResult},
};

/// 子 agent 请求。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SubagentRequest {
    pub task: String,
    pub system_prompt: Option<String>,
}

/// 子 agent 执行器；由宿主提供（通常复用主 agent 的 provider/model）。
pub type SubagentRunner =
    Arc<dyn Fn(SubagentRequest) -> BoxFuture<'static, Result<String, String>> + Send + Sync>;

/// `task` 工具：把一段独立任务交给子 agent 执行，返回其最终文本。
pub struct TaskTool {
    runner: SubagentRunner,
}

impl TaskTool {
    pub fn new(runner: SubagentRunner) -> Self {
        Self { runner }
    }
}

impl Tool for TaskTool {
    fn name(&self) -> &'static str {
        "task"
    }

    fn description(&self) -> &'static str {
        "Delegate an isolated task to a subagent and return its final answer."
    }

    fn schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "properties": {
                "task": { "type": "string", "description": "Task for the subagent" },
                "system_prompt": { "type": "string", "description": "Optional subagent system prompt" }
            },
            "required": ["task"]
        })
    }

    fn approval(&self, _args: &serde_json::Value) -> Approval {
        Approval::Ask
    }

    fn run(
        &self,
        args: serde_json::Value,
        _context: ToolContext,
    ) -> BoxFuture<'static, Result<ToolResult, ToolError>> {
        let runner = self.runner.clone();
        Box::pin(async move {
            let task = args
                .get("task")
                .and_then(|value| value.as_str())
                .ok_or_else(|| ToolError::InvalidArgs("missing task".to_string()))?;
            let system_prompt = args
                .get("system_prompt")
                .and_then(|value| value.as_str())
                .map(str::to_string);
            let request = SubagentRequest {
                task: task.to_string(),
                system_prompt,
            };
            match (runner)(request).await {
                Ok(text) => Ok(ToolResult::ok(text)),
                Err(error) => Ok(ToolResult::error(error)),
            }
        })
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use super::*;

    fn context() -> ToolContext {
        ToolContext::new(std::env::temp_dir())
    }

    #[test]
    fn task_tool_returns_runner_output() {
        let runner: SubagentRunner =
            Arc::new(|request| Box::pin(async move { Ok(format!("done: {}", request.task)) }));
        let tool = TaskTool::new(runner);
        let result =
            futures::executor::block_on(tool.run(serde_json::json!({"task": "lint"}), context()))
                .expect("run");
        assert_eq!(result.content, "done: lint");
        assert!(!result.is_error);
    }

    #[test]
    fn runner_errors_become_error_results() {
        let runner: SubagentRunner =
            Arc::new(|_request| Box::pin(async move { Err("provider down".to_string()) }));
        let tool = TaskTool::new(runner);
        let result =
            futures::executor::block_on(tool.run(serde_json::json!({"task": "lint"}), context()))
                .expect("run");
        assert!(result.is_error);
        assert!(result.content.contains("provider down"));
    }

    #[test]
    fn task_tool_requires_approval() {
        let runner: SubagentRunner = Arc::new(|_request| Box::pin(async { Ok(String::new()) }));
        assert_eq!(
            TaskTool::new(runner).approval(&serde_json::json!({})),
            Approval::Ask
        );
    }
}
