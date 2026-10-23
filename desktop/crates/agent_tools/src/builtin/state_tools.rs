use futures::future::BoxFuture;
use serde::Deserialize;

use crate::{
    approval::Approval,
    error::ToolError,
    state::{Goal, ItemStatus, PlanStep, SharedAgentState, TodoItem},
    tool::{Tool, ToolContext, ToolResult},
};

#[derive(Deserialize)]
struct TodoInput {
    todos: Vec<TodoInputItem>,
}

#[derive(Deserialize)]
struct TodoInputItem {
    content: String,
    #[serde(default)]
    status: ItemStatus,
}

/// 设置当前 todo 列表（整体替换）。
pub struct TodoWriteTool {
    state: SharedAgentState,
}

impl TodoWriteTool {
    pub fn new(state: SharedAgentState) -> Self {
        Self { state }
    }
}

impl Tool for TodoWriteTool {
    fn name(&self) -> &'static str {
        "todo_write"
    }

    fn description(&self) -> &'static str {
        "Replace the session todo list. Use it to track multi-step work."
    }

    fn schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "properties": {
                "todos": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "properties": {
                            "content": { "type": "string" },
                            "status": { "type": "string", "enum": ["pending", "in_progress", "completed", "blocked"] }
                        },
                        "required": ["content"]
                    }
                }
            },
            "required": ["todos"]
        })
    }

    fn approval(&self, _args: &serde_json::Value) -> Approval {
        Approval::Allow
    }

    fn run(
        &self,
        args: serde_json::Value,
        _context: ToolContext,
    ) -> BoxFuture<'static, Result<ToolResult, ToolError>> {
        let state = self.state.clone();
        Box::pin(async move {
            let input: TodoInput = serde_json::from_value(args)
                .map_err(|error| ToolError::InvalidArgs(error.to_string()))?;
            let todos: Vec<TodoItem> = input
                .todos
                .into_iter()
                .map(|todo| TodoItem {
                    content: todo.content,
                    status: todo.status,
                })
                .collect();
            let count = todos.len();
            state
                .lock()
                .map_err(|_| ToolError::Io("agent state poisoned".to_string()))?
                .set_todos(todos);
            Ok(ToolResult::ok(format!("todos updated: {count} items")))
        })
    }
}

#[derive(Deserialize)]
struct GoalInput {
    #[serde(default)]
    objective: String,
    #[serde(default)]
    token_budget: Option<u64>,
    #[serde(default)]
    clear: bool,
}

/// 设置/清除当前目标。
pub struct GoalWriteTool {
    state: SharedAgentState,
}

impl GoalWriteTool {
    pub fn new(state: SharedAgentState) -> Self {
        Self { state }
    }
}

impl Tool for GoalWriteTool {
    fn name(&self) -> &'static str {
        "goal_write"
    }

    fn description(&self) -> &'static str {
        "Set or clear the session goal (objective + optional token budget)."
    }

    fn schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "properties": {
                "objective": { "type": "string" },
                "token_budget": { "type": "integer", "minimum": 1 },
                "clear": { "type": "boolean" }
            }
        })
    }

    fn approval(&self, _args: &serde_json::Value) -> Approval {
        Approval::Allow
    }

    fn run(
        &self,
        args: serde_json::Value,
        _context: ToolContext,
    ) -> BoxFuture<'static, Result<ToolResult, ToolError>> {
        let state = self.state.clone();
        Box::pin(async move {
            let input: GoalInput = serde_json::from_value(args)
                .map_err(|error| ToolError::InvalidArgs(error.to_string()))?;
            let mut guard = state
                .lock()
                .map_err(|_| ToolError::Io("agent state poisoned".to_string()))?;
            if input.clear {
                guard.set_goal(None);
                return Ok(ToolResult::ok("goal cleared"));
            }
            if input.objective.trim().is_empty() {
                return Err(ToolError::InvalidArgs("objective required".to_string()));
            }
            guard.set_goal(Some(Goal {
                objective: input.objective,
                token_budget: input.token_budget,
            }));
            Ok(ToolResult::ok("goal updated"))
        })
    }
}

#[derive(Deserialize)]
struct PlanInput {
    steps: Vec<PlanInputStep>,
}

#[derive(Deserialize)]
struct PlanInputStep {
    title: String,
    #[serde(default)]
    status: ItemStatus,
}

/// 设置当前计划步骤。
pub struct PlanWriteTool {
    state: SharedAgentState,
}

impl PlanWriteTool {
    pub fn new(state: SharedAgentState) -> Self {
        Self { state }
    }
}

impl Tool for PlanWriteTool {
    fn name(&self) -> &'static str {
        "plan_write"
    }

    fn description(&self) -> &'static str {
        "Replace the plan steps shown to the user."
    }

    fn schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "properties": {
                "steps": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "properties": {
                            "title": { "type": "string" },
                            "status": { "type": "string", "enum": ["pending", "in_progress", "completed", "blocked"] }
                        },
                        "required": ["title"]
                    }
                }
            },
            "required": ["steps"]
        })
    }

    fn approval(&self, _args: &serde_json::Value) -> Approval {
        Approval::Allow
    }

    fn run(
        &self,
        args: serde_json::Value,
        _context: ToolContext,
    ) -> BoxFuture<'static, Result<ToolResult, ToolError>> {
        let state = self.state.clone();
        Box::pin(async move {
            let input: PlanInput = serde_json::from_value(args)
                .map_err(|error| ToolError::InvalidArgs(error.to_string()))?;
            let steps: Vec<PlanStep> = input
                .steps
                .into_iter()
                .map(|step| PlanStep {
                    title: step.title,
                    status: step.status,
                })
                .collect();
            let count = steps.len();
            state
                .lock()
                .map_err(|_| ToolError::Io("agent state poisoned".to_string()))?
                .set_plan(steps);
            Ok(ToolResult::ok(format!("plan updated: {count} steps")))
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    fn state() -> SharedAgentState {
        Arc::new(std::sync::Mutex::new(crate::state::AgentState::default()))
    }

    fn context() -> ToolContext {
        ToolContext::new(std::env::temp_dir())
    }

    #[test]
    fn todo_tool_replaces_todos() {
        let state = state();
        let tool = TodoWriteTool::new(state.clone());
        let result = futures::executor::block_on(tool.run(
            serde_json::json!({
                "todos": [
                    {"content": "read code", "status": "completed"},
                    {"content": "write tests"}
                ]
            }),
            context(),
        ))
        .expect("run");
        assert!(result.content.contains("2 items"));
        let guard = state.lock().unwrap();
        assert_eq!(guard.todos.len(), 2);
        assert_eq!(guard.todos[0].status, ItemStatus::Completed);
        assert_eq!(guard.todos[1].status, ItemStatus::Pending);
    }

    #[test]
    fn goal_tool_sets_and_clears() {
        let state = state();
        let tool = GoalWriteTool::new(state.clone());
        futures::executor::block_on(tool.run(
            serde_json::json!({"objective": "finish P2", "token_budget": 5000}),
            context(),
        ))
        .expect("set");
        assert_eq!(
            state.lock().unwrap().goal.as_ref().unwrap().objective,
            "finish P2"
        );
        futures::executor::block_on(tool.run(serde_json::json!({"clear": true}), context()))
            .expect("clear");
        assert!(state.lock().unwrap().goal.is_none());
    }

    #[test]
    fn plan_tool_sets_steps() {
        let state = state();
        let tool = PlanWriteTool::new(state.clone());
        futures::executor::block_on(tool.run(
            serde_json::json!({"steps": [{"title": "step one", "status": "completed"}, {"title": "step two", "status": "in_progress"}]}),
            context(),
        ))
        .expect("run");
        let guard = state.lock().unwrap();
        assert_eq!(guard.plan.len(), 2);
        assert_eq!(guard.plan[1].status, ItemStatus::InProgress);
        assert!(guard.summary().unwrap().contains("1/2"));
    }

    #[test]
    fn state_tools_are_allowed_without_approval() {
        let state = state();
        assert_eq!(
            TodoWriteTool::new(state.clone()).approval(&serde_json::json!({})),
            Approval::Allow
        );
        assert_eq!(
            GoalWriteTool::new(state.clone()).approval(&serde_json::json!({})),
            Approval::Allow
        );
        assert_eq!(
            PlanWriteTool::new(state).approval(&serde_json::json!({})),
            Approval::Allow
        );
    }
}
