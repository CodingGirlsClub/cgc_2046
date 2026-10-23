use std::{
    collections::{HashSet, VecDeque},
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc, Arc,
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

/// 一次 prompt 内最多连续跟进（follow-up）的轮数。
pub const MAX_FOLLOW_UP_TURNS: usize = 4;

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
    pub tool_call_id: String,
    pub tool_name: String,
    pub args: serde_json::Value,
}

/// 审批回调。UI 在后台任务里等待用户点击，然后 resolve。
pub trait Approver: Send + Sync {
    fn decide(&self, request: ApprovalRequest) -> BoxFuture<'static, ApprovalDecision>;
}

/// 一轮 turn 的过程事件。UI/Host 通过它把流式过程渲染出来。
pub trait TurnObserver: Send {
    fn on_turn_started(&mut self, _thread_id: &str) {}
    fn on_follow_up_started(&mut self, _text: &str) {}
    fn on_text(&mut self, _delta: &str) {}
    fn on_tool_call(&mut self, _tool_use: &ToolUse) {}
    fn on_permission_request(&mut self, _request: &ApprovalRequest) {}
    fn on_tool_result(&mut self, _summary: &ToolResultSummary) {}
    fn on_usage(&mut self, _usage: TokenUsage, _total: TokenUsage) {}
    fn on_finished(&mut self, _outcome: &ToolTurnOutcome) {}
}

/// 不关心过程的调用方（测试、无 UI 场景）。
pub struct NoopObserver;

impl TurnObserver for NoopObserver {}

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
    follow_ups: VecDeque<String>,
    follow_up_tx: mpsc::Sender<String>,
    follow_up_rx: mpsc::Receiver<String>,
}

impl Agent {
    pub fn new(thread: Thread, system_prompt: Option<String>) -> Self {
        let (follow_up_tx, follow_up_rx) = mpsc::channel();
        Self {
            thread,
            system_prompt,
            cancel: CancelToken::new(),
            session_grants: HashSet::new(),
            follow_ups: VecDeque::new(),
            follow_up_tx,
            follow_up_rx,
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

    /// 运行中也能用的 follow-up 投递口；UI 在 turn 进行时把新消息发进来。
    pub fn follow_up_sender(&self) -> mpsc::Sender<String> {
        self.follow_up_tx.clone()
    }

    pub fn queue_follow_up(&mut self, text: impl Into<String>) {
        self.follow_ups.push_back(text.into());
    }

    pub fn pending_follow_ups(&self) -> usize {
        self.follow_ups.len()
    }

    fn drain_follow_ups(&mut self) {
        while let Ok(text) = self.follow_up_rx.try_recv() {
            self.follow_ups.push_back(text);
        }
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
        let mut observer = NoopObserver;
        let (text, usage, stop_reason, tool_calls) =
            run_stream(provider, model, request, &self.cancel, &mut observer).await?;
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
        let mut observer = NoopObserver;
        self.prompt_with_tools_observed(
            provider,
            model,
            text,
            tools,
            context,
            approver,
            &mut observer,
        )
        .await
    }

    /// 与 `prompt_with_tools` 相同，但把过程事件推给 observer。
    #[allow(clippy::too_many_arguments)]
    pub async fn prompt_with_tools_observed(
        &mut self,
        provider: &dyn Provider,
        model: &Model,
        text: impl Into<String>,
        tools: &ToolRegistry,
        context: &ToolContext,
        approver: &dyn Approver,
        observer: &mut dyn TurnObserver,
    ) -> Result<ToolTurnOutcome, AgentError> {
        self.validate(provider, model)?;
        self.thread.push_user(text);
        observer.on_turn_started(&self.thread.id);

        let mut all_text = String::new();
        let mut total_usage = TokenUsage::default();
        let mut all_tool_calls = Vec::new();
        let mut tool_results = Vec::new();

        let mut follow_up_turns = 0;
        'turns: loop {
            for step in 0..MAX_TOOL_STEPS {
                if self.cancel.is_cancelled() {
                    return Err(AgentError::Cancelled);
                }
                let request = self.build_request(tools.schemas());
                let (text, usage, stop_reason, tool_calls) =
                    run_stream(provider, model, request, &self.cancel, observer).await?;
                self.record_turn(text.clone(), tool_calls.clone(), usage);
                observer.on_usage(usage, self.thread.usage_total);
                all_text.push_str(&text);
                total_usage.add(usage);
                all_tool_calls.extend(tool_calls.clone());
                if stop_reason != StopReason::ToolUse || tool_calls.is_empty() {
                    self.drain_follow_ups();
                    if follow_up_turns < MAX_FOLLOW_UP_TURNS {
                        if let Some(next) = self.follow_ups.pop_front() {
                            follow_up_turns += 1;
                            observer.on_follow_up_started(&next);
                            self.thread.push_user(next);
                            continue 'turns;
                        }
                    }
                    let outcome = ToolTurnOutcome {
                        text: all_text,
                        usage: total_usage,
                        stop_reason,
                        tool_calls: all_tool_calls,
                        tool_results,
                    };
                    observer.on_finished(&outcome);
                    return Ok(outcome);
                }
                for tool_call in &tool_calls {
                    observer.on_tool_call(tool_call);
                    let summary = self
                        .execute_tool_call(tool_call, tools, context, approver, observer)
                        .await;
                    observer.on_tool_result(&summary);
                    tool_results.push(summary);
                }
                if step + 1 == MAX_TOOL_STEPS {
                    return Err(AgentError::StepLimitExceeded);
                }
            }
            return Err(AgentError::StepLimitExceeded);
        }
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
        observer: &mut dyn TurnObserver,
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
                    let request = ApprovalRequest {
                        tool_call_id: tool_call.id.clone(),
                        tool_name: tool_call.name.clone(),
                        args: tool_call.args.clone(),
                    };
                    observer.on_permission_request(&request);
                    approver.decide(request).await
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
    observer: &mut dyn TurnObserver,
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
            CompletionEvent::Text(chunk) => {
                observer.on_text(&chunk);
                text.push_str(&chunk);
            }
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
