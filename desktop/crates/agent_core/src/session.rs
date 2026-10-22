use std::{
    collections::HashSet,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
};

use cgc_agent_provider::{
    CompletionEvent, Message, Model, Provider, ProviderError, Request, StopReason, TokenUsage,
    ToolUse,
};
use cgc_agent_tools::{Approval, ApprovalDecision, ToolContext, ToolRegistry};
use futures::{future::BoxFuture, StreamExt};

use crate::thread::Thread;

/// 单轮工具循环的上限，防止模型无限调工具。
pub const MAX_TOOL_STEPS: usize = 8;

/// 取消句柄：UI 点击停止时调用 `cancel()`；Agent 在每个事件边界检查。
#[derive(Clone, Debug, Default)]
pub struct CancelToken {
    flag: Arc<AtomicBool>,
}

impl CancelToken {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn cancel(&self) {
        self.flag.store(true, Ordering::SeqCst);
    }

    pub fn reset(&self) {
        self.flag.store(false, Ordering::SeqCst);
    }

    pub fn is_cancelled(&self) -> bool {
        self.flag.load(Ordering::SeqCst)
    }
}

/// 一轮对话的结果。
#[derive(Clone, Debug, PartialEq)]
pub struct TurnOutcome {
    pub text: String,
    pub usage: TokenUsage,
    pub stop_reason: StopReason,
    pub tool_calls: Vec<ToolUse>,
}

/// 工具循环结束后的结果。
#[derive(Clone, Debug, PartialEq)]
pub struct ToolTurnOutcome {
    pub text: String,
    pub usage: TokenUsage,
    pub stop_reason: StopReason,
    pub tool_calls: Vec<ToolUse>,
    pub tool_results: Vec<ToolResultSummary>,
}

/// 一次工具执行的结果摘要，供 UI/日志使用。
#[derive(Clone, Debug, PartialEq)]
pub struct ToolResultSummary {
    pub tool_use_id: String,
    pub tool_name: String,
    pub content: String,
    pub is_error: bool,
}

/// 需要用户确认的审批请求。
#[derive(Clone, Debug, PartialEq)]
pub struct ApprovalRequest {
    pub tool_name: String,
    pub args: serde_json::Value,
}

/// 审批回调。UI 在后台任务里等待用户点击，然后 resolve。
pub trait Approver: Send + Sync {
    fn decide(&self, request: ApprovalRequest) -> BoxFuture<'static, ApprovalDecision>;
}

/// 无人值守场景（测试、CLI demo）：全部允许一次。
pub struct AutoApprover;

impl Approver for AutoApprover {
    fn decide(&self, _request: ApprovalRequest) -> BoxFuture<'static, ApprovalDecision> {
        Box::pin(async { ApprovalDecision::AllowOnce })
    }
}

/// 全部拒绝，用于演示拒绝路径。
pub struct DenyApprover;

impl Approver for DenyApprover {
    fn decide(&self, _request: ApprovalRequest) -> BoxFuture<'static, ApprovalDecision> {
        Box::pin(async { ApprovalDecision::Deny })
    }
}

#[derive(Debug, thiserror::Error)]
pub enum AgentError {
    #[error("provider error: {0}")]
    Provider(#[from] ProviderError),
    #[error("cancelled")]
    Cancelled,
    #[error("selected model does not match the model being used")]
    ModelMismatch,
    #[error("tool loop exceeded {MAX_TOOL_STEPS} steps")]
    StepLimitExceeded,
}

/// 一个 native agent 会话。P1a 先内存态。
pub struct Agent {
    thread: Thread,
    system_prompt: Option<String>,
    cancel: CancelToken,
    session_grants: HashSet<String>,
}

impl Agent {
    pub fn new(thread: Thread, system_prompt: Option<String>) -> Self {
        Self {
            thread,
            system_prompt,
            cancel: CancelToken::new(),
            session_grants: HashSet::new(),
        }
    }

    pub fn thread(&self) -> &Thread {
        &self.thread
    }

    pub fn thread_mut(&mut self) -> &mut Thread {
        &mut self.thread
    }

    pub fn cancel_token(&self) -> CancelToken {
        self.cancel.clone()
    }

    /// 纯文本一轮（不执行工具；tool_call 只记录）。
    pub async fn prompt(
        &mut self,
        provider: &dyn Provider,
        model: &Model,
        text: impl Into<String>,
    ) -> Result<TurnOutcome, AgentError> {
        self.validate(provider, model)?;
        self.thread.push_user(text);
        let request = self.build_request(Vec::new());
        let (text, usage, stop_reason, tool_calls) =
            run_stream(provider, model, request, &self.cancel).await?;
        self.record_turn(text.clone(), tool_calls.clone(), usage);
        Ok(TurnOutcome {
            text,
            usage,
            stop_reason,
            tool_calls,
        })
    }

    /// 带工具的一轮：tool_call → 审批 → 执行 → 结果回灌，直到模型不再调用工具。
    pub async fn prompt_with_tools(
        &mut self,
        provider: &dyn Provider,
        model: &Model,
        text: impl Into<String>,
        tools: &ToolRegistry,
        context: &ToolContext,
        approver: &dyn Approver,
    ) -> Result<ToolTurnOutcome, AgentError> {
        self.validate(provider, model)?;
        self.thread.push_user(text);

        let mut all_text = String::new();
        let mut total_usage = TokenUsage::default();
        let mut all_tool_calls = Vec::new();
        let mut tool_results = Vec::new();

        for step in 0..MAX_TOOL_STEPS {
            if self.cancel.is_cancelled() {
                return Err(AgentError::Cancelled);
            }
            let request = self.build_request(tools.schemas());
            let (text, usage, stop_reason, tool_calls) =
                run_stream(provider, model, request, &self.cancel).await?;
            self.record_turn(text.clone(), tool_calls.clone(), usage);
            all_text.push_str(&text);
            total_usage.add(usage);
            all_tool_calls.extend(tool_calls.clone());
            if stop_reason != StopReason::ToolUse || tool_calls.is_empty() {
                return Ok(ToolTurnOutcome {
                    text: all_text,
                    usage: total_usage,
                    stop_reason,
                    tool_calls: all_tool_calls,
                    tool_results,
                });
            }
            for tool_call in &tool_calls {
                let summary = self
                    .execute_tool_call(tool_call, tools, context, approver)
                    .await;
                tool_results.push(summary);
            }
            if step + 1 == MAX_TOOL_STEPS {
                return Err(AgentError::StepLimitExceeded);
            }
        }
        Err(AgentError::StepLimitExceeded)
    }

    fn validate(&self, provider: &dyn Provider, model: &Model) -> Result<(), AgentError> {
        if self.cancel.is_cancelled() {
            return Err(AgentError::Cancelled);
        }
        if provider.id() != &model.provider_id || !self.thread.model.matches(model) {
            return Err(AgentError::ModelMismatch);
        }
        Ok(())
    }

    fn build_request(&self, tools: Vec<cgc_agent_provider::ToolSchema>) -> Request {
        let mut messages = Vec::new();
        if let Some(system_prompt) = &self.system_prompt {
            messages.push(Message::system(system_prompt.clone()));
        }
        messages.extend(self.thread.messages());
        Request::new(messages).with_tools(tools)
    }

    fn record_turn(&mut self, text: String, tool_calls: Vec<ToolUse>, usage: TokenUsage) {
        let usage_for_entry = if usage == TokenUsage::default() {
            None
        } else {
            Some(usage)
        };
        self.thread.usage_total.add(usage);
        self.thread
            .push_assistant(text, tool_calls, usage_for_entry);
    }

    async fn execute_tool_call(
        &mut self,
        tool_call: &ToolUse,
        tools: &ToolRegistry,
        context: &ToolContext,
        approver: &dyn Approver,
    ) -> ToolResultSummary {
        let Some(approval) = tools.approval(&tool_call.name, &tool_call.args) else {
            let content = format!("unknown tool: {}", tool_call.name);
            self.thread.push_tool_result(
                tool_call.id.clone(),
                tool_call.name.clone(),
                content.clone(),
                true,
            );
            return ToolResultSummary {
                tool_use_id: tool_call.id.clone(),
                tool_name: tool_call.name.clone(),
                content,
                is_error: true,
            };
        };

        let decision = match approval {
            Approval::Allow => ApprovalDecision::AllowOnce,
            Approval::Deny(reason) => {
                let content = format!("denied by policy: {reason}");
                self.thread.push_tool_result(
                    tool_call.id.clone(),
                    tool_call.name.clone(),
                    content.clone(),
                    true,
                );
                return ToolResultSummary {
                    tool_use_id: tool_call.id.clone(),
                    tool_name: tool_call.name.clone(),
                    content,
                    is_error: true,
                };
            }
            Approval::Ask => {
                if self.session_grants.contains(&tool_call.name) {
                    ApprovalDecision::AllowOnce
                } else {
                    approver
                        .decide(ApprovalRequest {
                            tool_name: tool_call.name.clone(),
                            args: tool_call.args.clone(),
                        })
                        .await
                }
            }
        };

        match decision {
            ApprovalDecision::Deny => {
                let content = "denied by user".to_string();
                self.thread.push_tool_result(
                    tool_call.id.clone(),
                    tool_call.name.clone(),
                    content.clone(),
                    true,
                );
                ToolResultSummary {
                    tool_use_id: tool_call.id.clone(),
                    tool_name: tool_call.name.clone(),
                    content,
                    is_error: true,
                }
            }
            ApprovalDecision::AllowOnce | ApprovalDecision::AllowForSession => {
                if decision == ApprovalDecision::AllowForSession {
                    self.session_grants.insert(tool_call.name.clone());
                }
                let (content, is_error) = match tools
                    .run(&tool_call.name, tool_call.args.clone(), context.clone())
                    .await
                {
                    Ok(result) => (result.content, result.is_error),
                    Err(error) => (error.to_string(), true),
                };
                self.thread.push_tool_result(
                    tool_call.id.clone(),
                    tool_call.name.clone(),
                    content.clone(),
                    is_error,
                );
                ToolResultSummary {
                    tool_use_id: tool_call.id.clone(),
                    tool_name: tool_call.name.clone(),
                    content,
                    is_error,
                }
            }
        }
    }
}

async fn run_stream(
    provider: &dyn Provider,
    model: &Model,
    request: Request,
    cancel: &CancelToken,
) -> Result<(String, TokenUsage, StopReason, Vec<ToolUse>), AgentError> {
    let mut stream = provider.stream(model, request).await?;
    let mut text = String::new();
    let mut usage = TokenUsage::default();
    let mut stop_reason = None;
    let mut tool_calls: Vec<ToolUse> = Vec::new();
    while let Some(event) = stream.next().await {
        if cancel.is_cancelled() {
            return Err(AgentError::Cancelled);
        }
        match event? {
            CompletionEvent::StartMessage { .. } => {}
            CompletionEvent::Text(chunk) => text.push_str(&chunk),
            CompletionEvent::Thinking { .. } => {}
            CompletionEvent::ToolUse(tool_use) => tool_calls.push(tool_use),
            CompletionEvent::Usage(delta) => usage.add(delta),
            CompletionEvent::Stop(reason) => {
                stop_reason = Some(reason);
                break;
            }
        }
    }
    Ok((
        text,
        usage,
        stop_reason.unwrap_or_else(|| StopReason::Other("stream ended".to_string())),
        tool_calls,
    ))
}
