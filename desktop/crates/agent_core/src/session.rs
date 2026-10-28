use std::{
    collections::{HashSet, VecDeque},
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc, Arc, Mutex,
    },
};

use cgc_agent_provider::{
    CompletionEvent, Message, Model, Provider, ProviderError, Request, StopReason, TokenUsage,
    ToolUse,
};
use cgc_agent_tools::{
    Approval, ApprovalDecision, SubagentEvent, SubagentEventSink, ToolContext, ToolRegistry,
};
use futures::StreamExt;

use crate::thread::{Entry, ImageAttachment, SelectedModel, Thread};

mod context;
mod events;
mod stream;
mod subagent;
mod tools;

pub use events::{
    ApprovalRequest, Approver, AutoApprover, DenyApprover, NoopObserver, ToolResultSummary,
    ToolTurnOutcome, TurnObserver, TurnOutcome,
};
use stream::{run_stream, StreamOutcome};
pub use subagent::run_subagent;

/// 单轮工具循环的上限，防止模型无限调工具。
pub const MAX_TOOL_STEPS: usize = 8;

/// 一次 prompt 内最多连续跟进（follow-up）的轮数。
pub const MAX_FOLLOW_UP_TURNS: usize = 4;

/// 一次 prompt 内最多被 steer 打断的次数。
pub const MAX_STEERS: usize = 4;

/// 取消句柄：UI 点击停止时调用 `cancel()`。
///
/// 既能轮询（`is_cancelled`）也能等待（`cancelled()`）：模型长时间不吐 delta 时，
/// 流消费要能立刻被唤醒，而不是等下一个事件才发现已取消。
#[derive(Clone, Debug)]
pub struct CancelToken {
    flag: Arc<AtomicBool>,
    waiters: Arc<Mutex<Vec<std::task::Waker>>>,
}

impl Default for CancelToken {
    fn default() -> Self {
        Self {
            flag: Arc::new(AtomicBool::new(false)),
            waiters: Arc::new(Mutex::new(Vec::new())),
        }
    }
}

impl CancelToken {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn cancel(&self) {
        self.flag.store(true, Ordering::SeqCst);
        let waiters: Vec<_> = self
            .waiters
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .drain(..)
            .collect();
        for waiter in waiters {
            waiter.wake();
        }
    }

    pub fn reset(&self) {
        self.flag.store(false, Ordering::SeqCst);
    }

    pub fn is_cancelled(&self) -> bool {
        self.flag.load(Ordering::SeqCst)
    }

    /// 等待取消；已取消时立即就绪。与轮询共用同一个标志，注册无竞态。
    pub async fn cancelled(&self) {
        futures::future::poll_fn(|cx| {
            if self.is_cancelled() {
                return std::task::Poll::Ready(());
            }
            let mut waiters = self
                .waiters
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            // 持锁后再检查一次：cancel 可能刚好发生在检查与入队之间。
            if self.is_cancelled() {
                return std::task::Poll::Ready(());
            }
            waiters.push(cx.waker().clone());
            std::task::Poll::Pending
        })
        .await
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
    #[error("context too large: estimated {estimated_tokens} tokens, window {context_window}; image cost unknown: {image_cost_unknown}")]
    ContextTooLarge {
        estimated_tokens: usize,
        context_window: u32,
        image_cost_unknown: bool,
    },
    #[error("native runtime is busy")]
    RuntimeBusy,
    #[error("native connection no longer owns this thread")]
    StaleConnection,
    #[error("native runtime is closed")]
    RuntimeClosed,
}

/// 一个 native agent 会话。P1a 先内存态。
pub struct Agent {
    thread: Thread,
    system_prompt: Option<String>,
    cancel: CancelToken,
    session_grants: HashSet<String>,
    session_patterns: Vec<(String, String)>,
    follow_ups: VecDeque<String>,
    follow_up_tx: mpsc::Sender<String>,
    follow_up_rx: mpsc::Receiver<String>,
    steer_tx: mpsc::Sender<String>,
    steer_rx: mpsc::Receiver<String>,
    reasoning_effort: Option<String>,
    /// 下一轮用户消息要携带的图片附件（MIME, base64）；发送一次后清空。
    pending_images: Vec<(String, String, String)>,
    /// 下一条用户消息的 UI 展示文本（不含注入上下文）；发送一次后清空。
    pending_user_display: Option<String>,
}

impl Agent {
    pub fn new(thread: Thread, system_prompt: Option<String>) -> Self {
        let (follow_up_tx, follow_up_rx) = mpsc::channel();
        let (steer_tx, steer_rx) = mpsc::channel();
        Self {
            thread,
            system_prompt,
            cancel: CancelToken::new(),
            session_grants: HashSet::new(),
            session_patterns: Vec::new(),
            follow_ups: VecDeque::new(),
            follow_up_tx,
            follow_up_rx,
            steer_tx,
            steer_rx,
            reasoning_effort: None,
            pending_images: Vec::new(),
            pending_user_display: None,
        }
    }

    /// 设置下一轮要随用户消息发送的图片（MIME, base64）；只生效一次。
    pub fn set_pending_images(&mut self, images: Vec<(String, String, String)>) {
        self.pending_images = images;
    }

    /// 设置下一条用户消息的 UI 展示文本（不含注入上下文）；只生效一次。
    pub fn set_pending_user_display(&mut self, display: Option<String>) {
        self.pending_user_display = display;
    }

    /// 把待发送图片挂到最近一条用户消息上（随 thread 持久化）。
    fn persist_pending_images(&mut self) {
        if self.pending_images.is_empty() {
            return;
        }
        let images = std::mem::take(&mut self.pending_images)
            .into_iter()
            .map(|(name, mime_type, data)| ImageAttachment {
                name,
                mime_type,
                data,
            })
            .collect::<Vec<_>>();
        self.thread.attach_images_to_last_user(images);
    }

    pub fn thread(&self) -> &Thread {
        &self.thread
    }

    /// 更新线程生成标题（LLM 标题使用）。
    pub fn set_thread_title(&mut self, title: Option<String>) {
        self.thread.title = title;
    }

    /// 更新用户标题覆盖（优先于生成标题）。
    pub fn set_thread_title_override(&mut self, title: Option<String>) {
        self.thread.title_override = title;
    }

    pub fn thread_mut(&mut self) -> &mut Thread {
        &mut self.thread
    }

    pub fn cancel_token(&self) -> CancelToken {
        self.cancel.clone()
    }

    /// 设置本轮请求的 reasoning 档位（`low`/`medium`/`high`）；`None` 表示不下发。
    pub fn set_reasoning_effort(&mut self, reasoning_effort: Option<String>) {
        self.reasoning_effort = reasoning_effort;
    }

    /// 用磁盘上最新的 thread 替换当前会话（多视图共享会话）。
    pub fn replace_thread(&mut self, thread: Thread) {
        self.thread = thread;
        self.session_grants.clear();
        self.session_patterns.clear();
        self.follow_ups.clear();
        while self.follow_up_rx.try_recv().is_ok() {}
        while self.steer_rx.try_recv().is_ok() {}
        self.cancel.reset();
    }

    /// 运行中也能用的 follow-up 投递口；UI 在 turn 进行时把新消息发进来。
    pub fn follow_up_sender(&self) -> mpsc::Sender<String> {
        self.follow_up_tx.clone()
    }

    /// 运行中打断当前生成并插入一条消息。
    pub fn steer_sender(&self) -> mpsc::Sender<String> {
        self.steer_tx.clone()
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
        let display = self.pending_user_display.take();
        self.thread.push_user_with_display(text, display);
        self.persist_pending_images();
        let mut observer = NoopObserver;
        let mut steers = 0;
        loop {
            let request = self
                .build_request_with_compaction(provider, model, Vec::new(), &mut observer)
                .await?;
            let outcome = run_stream(provider, model, request, &self.cancel, &mut observer).await?;
            match outcome {
                StreamOutcome::Finished {
                    text,
                    thinking,
                    usage,
                    stop_reason,
                    tool_calls,
                } => {
                    self.record_thinking(thinking);
                    self.record_turn(text.clone(), tool_calls.clone(), usage);
                    // 插话只在 turn 边界生效（对齐 Zed 的 end_turn_at_next_boundary）：
                    // 已产生的文本保留，本轮结果不返回，直接进入下一轮。
                    if let Ok(steer_text) = self.steer_rx.try_recv() {
                        self.thread.push_user(steer_text);
                        steers += 1;
                        if steers >= MAX_STEERS {
                            return Err(AgentError::StepLimitExceeded);
                        }
                        continue;
                    }
                    return Ok(TurnOutcome {
                        text,
                        usage,
                        stop_reason,
                        tool_calls,
                    });
                }
            }
        }
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
        let display = self.pending_user_display.take();
        self.thread.push_user_with_display(text, display);
        self.persist_pending_images();
        observer.on_turn_started(&self.thread.id);

        let mut all_text = String::new();
        let mut total_usage = TokenUsage::default();
        let mut all_tool_calls = Vec::new();
        let mut tool_results = Vec::new();

        let mut follow_up_turns = 0;
        let mut steers = 0;
        'turns: loop {
            for step in 0..MAX_TOOL_STEPS {
                if self.cancel.is_cancelled() {
                    return Err(AgentError::Cancelled);
                }
                let request = self
                    .build_request_with_compaction(provider, model, tools.schemas(), observer)
                    .await?;
                let stream_outcome =
                    run_stream(provider, model, request, &self.cancel, observer).await?;
                let (text, thinking, usage, stop_reason, tool_calls) = match stream_outcome {
                    StreamOutcome::Finished {
                        text,
                        thinking,
                        usage,
                        stop_reason,
                        tool_calls,
                    } => (text, thinking, usage, stop_reason, tool_calls),
                };
                self.record_thinking(thinking);
                self.record_turn(text.clone(), tool_calls.clone(), usage);
                observer.on_usage(usage, self.thread.usage_total);
                all_text.push_str(&text);
                total_usage.add(usage);
                all_tool_calls.extend(tool_calls.clone());
                if stop_reason != StopReason::ToolUse || tool_calls.is_empty() {
                    // turn 边界：此刻没有待执行工具，插话可以安全地成为下一条用户消息。
                    if let Ok(steer_text) = self.steer_rx.try_recv() {
                        observer.on_steer_started(&steer_text);
                        self.thread.push_user(steer_text);
                        steers += 1;
                        if steers >= MAX_STEERS {
                            return Err(AgentError::StepLimitExceeded);
                        }
                        continue 'turns;
                    }
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

    fn record_thinking(&mut self, thinking: String) {
        if !thinking.is_empty() {
            self.thread.push_thinking(thinking);
        }
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
}
