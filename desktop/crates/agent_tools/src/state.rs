use std::sync::{Arc, Mutex};

use serde::{Deserialize, Serialize};

/// 计划 / 待办条目的状态。
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ItemStatus {
    #[default]
    Pending,
    InProgress,
    Completed,
    Blocked,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct TodoItem {
    pub content: String,
    pub status: ItemStatus,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PlanStep {
    pub title: String,
    pub status: ItemStatus,
}

/// 一个带预算的长期目标。
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Goal {
    pub objective: String,
    pub token_budget: Option<u64>,
}

/// agent 工具共享的可视状态（todo / plan / goal），由 UI 读取渲染。
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentState {
    #[serde(default)]
    pub todos: Vec<TodoItem>,
    #[serde(default)]
    pub plan: Vec<PlanStep>,
    #[serde(default)]
    pub goal: Option<Goal>,
}

impl AgentState {
    pub fn set_todos(&mut self, todos: Vec<TodoItem>) {
        self.todos = todos;
    }

    pub fn set_plan(&mut self, plan: Vec<PlanStep>) {
        self.plan = plan;
    }

    pub fn set_goal(&mut self, goal: Option<Goal>) {
        self.goal = goal;
    }

    pub fn summary(&self) -> Option<String> {
        if self.todos.is_empty() && self.plan.is_empty() && self.goal.is_none() {
            return None;
        }
        let mut lines = Vec::new();
        if let Some(goal) = &self.goal {
            let budget = goal
                .token_budget
                .map(|budget| format!("（预算 {budget} tokens）"))
                .unwrap_or_default();
            lines.push(format!("目标：{}{budget}", goal.objective));
        }
        if !self.plan.is_empty() {
            let done = self
                .plan
                .iter()
                .filter(|step| step.status == ItemStatus::Completed)
                .count();
            lines.push(format!("计划：{done}/{} 步完成", self.plan.len()));
        }
        if !self.todos.is_empty() {
            let done = self
                .todos
                .iter()
                .filter(|todo| todo.status == ItemStatus::Completed)
                .count();
            lines.push(format!("待办：{done}/{} 项完成", self.todos.len()));
        }
        Some(lines.join(" · "))
    }
}

/// 工具与 UI 共享的状态句柄。
pub type SharedAgentState = Arc<Mutex<AgentState>>;
