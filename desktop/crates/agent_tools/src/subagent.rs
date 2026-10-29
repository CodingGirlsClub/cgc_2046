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

/// 子 agent 生命周期事件。
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SubagentEvent {
    Started { task: String },
    TextDelta { text: String },
    Finished { ok: bool },
}

/// 子 agent 事件出口。
pub type SubagentEventSink = Arc<dyn Fn(SubagentEvent) + Send + Sync>;

/// 子 agent 执行器；由宿主提供（通常复用主 agent 的 provider/model）。
pub type SubagentRunner = Arc<
    dyn Fn(SubagentRequest, SubagentEventSink) -> BoxFuture<'static, Result<String, String>>
        + Send
        + Sync,
>;

/// `task` 工具：把一段独立任务交给子 agent 执行，返回其最终文本。
pub struct TaskTool {
    runner: SubagentRunner,
    events: SubagentEventSink,
}

impl TaskTool {
    pub fn new(runner: SubagentRunner, events: SubagentEventSink) -> Self {
        Self { runner, events }
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
        let events = self.events.clone();
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
            match (runner)(request, events).await {
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
        let runner: SubagentRunner = Arc::new(|request, _events| {
            Box::pin(async move { Ok(format!("done: {}", request.task)) })
        });
        let events: SubagentEventSink = Arc::new(|_event| {});
        let tool = TaskTool::new(runner, events);
        let result =
            futures::executor::block_on(tool.run(serde_json::json!({"task": "lint"}), context()))
                .expect("run");
        assert_eq!(result.content, "done: lint");
        assert!(!result.is_error);
    }

    #[test]
    fn runner_errors_become_error_results() {
        let runner: SubagentRunner =
            Arc::new(|_request, _events| Box::pin(async move { Err("provider down".to_string()) }));
        let events: SubagentEventSink = Arc::new(|_event| {});
        let tool = TaskTool::new(runner, events);
        let result =
            futures::executor::block_on(tool.run(serde_json::json!({"task": "lint"}), context()))
                .expect("run");
        assert!(result.is_error);
        assert!(result.content.contains("provider down"));
    }

    #[test]
    fn task_tool_forwards_events_to_sink() {
        let captured = Arc::new(std::sync::Mutex::new(Vec::new()));
        let events: SubagentEventSink = {
            let captured = captured.clone();
            Arc::new(move |event| captured.lock().unwrap().push(event))
        };
        let runner: SubagentRunner = {
            Arc::new(move |request, events| {
                let started = SubagentEvent::Started {
                    task: request.task.clone(),
                };
                let events_for_inner = events.clone();
                Box::pin(async move {
                    events(started);
                    events_for_inner(SubagentEvent::Finished { ok: true });
                    Ok("done".to_string())
                })
            })
        };
        let tool = TaskTool::new(runner, events);
        futures::executor::block_on(tool.run(serde_json::json!({"task": "x"}), context()))
            .expect("run");
        let events = captured.lock().unwrap();
        assert!(events.contains(&SubagentEvent::Started {
            task: "x".to_string()
        }));
        assert!(events.contains(&SubagentEvent::Finished { ok: true }));
    }

    #[test]
    fn task_tool_requires_approval() {
        let runner: SubagentRunner =
            Arc::new(|_request, _events| Box::pin(async { Ok(String::new()) }));
        let events: SubagentEventSink = Arc::new(|_event| {});
        assert_eq!(
            TaskTool::new(runner, events).approval(&serde_json::json!({})),
            Approval::Ask
        );
    }
}
