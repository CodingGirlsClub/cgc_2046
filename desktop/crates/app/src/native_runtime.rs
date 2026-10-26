//! app 侧的 native 运行时实现（[`NativeTurnRuntime`]）。
//!
//! Phase A 的接法：native 面板仍持有现有 `Agent`（provider/tools/context/checkpoint
//! 都在 app 侧不变），只是每个 turn 把 Agent 交给进程内 ACP server 的运行时出口，
//! 过程事件经 `AgentEvent → SessionUpdate → HostEvent` 回到 UI。于是 native 与外部
//! ACP agent 在客户端侧共享同一份 ingestion，而 native 专属能力（附件、queue、
//! steer、checkpoint、模型选择器）完全留在原处，不经过 ACP。
//!
//! 本模块只有两个职责：把一份 per-turn 快照交给 runtime、把 cancel 转给 Agent
//! 自己的 `CancelToken`。

use std::sync::{Arc, Mutex};

use cgc_agent_core::{Agent, AgentError, Approver, AutoApprover, ToolTurnOutcome};
use cgc_agent_host::{NativeTurn, NativeTurnRuntime};
use cgc_agent_provider::{Model, Provider};
use cgc_agent_tools::{ToolContext, ToolRegistry};
use futures::future::BoxFuture;

/// 一个 turn 的运行时快照：视图在发 prompt 前更新（凭据/模型/工具/工作区都可能变）。
#[derive(Clone)]
pub struct NativeRuntimeConfig {
    pub provider: Arc<dyn Provider>,
    pub model: Model,
    pub registry: Arc<ToolRegistry>,
    pub context: ToolContext,
    pub context_size: u64,
    /// Auto 模式在 runtime 内直接放行，不产生审批往返（保持旧行为：Auto 不留审批行）。
    pub auto_approve: bool,
}

/// native ACP server 的运行时句柄；`NativeAgentView` 持有同一组 Arc，
/// turn 前把 Agent 与配置放进 slot、turn 后把 Agent 取回。
#[derive(Clone, Default)]
pub struct NativeRuntimeHandle {
    agent: Arc<Mutex<Option<Agent>>>,
    config: Arc<Mutex<Option<NativeRuntimeConfig>>>,
}

impl NativeRuntimeHandle {
    pub fn new() -> Self {
        Self::default()
    }

    /// turn 前放入 Agent（视图随后不再直接使用它）。
    pub fn put_agent(&self, agent: Agent) {
        *self.agent.lock().expect("native runtime agent") = Some(agent);
    }

    /// turn 后取回 Agent；还没交回时返回 None。
    pub fn take_agent(&self) -> Option<Agent> {
        self.agent.lock().expect("native runtime agent").take()
    }

    pub fn put_config(&self, config: NativeRuntimeConfig) {
        *self.config.lock().expect("native runtime config") = Some(config);
    }
}

impl NativeTurnRuntime for NativeRuntimeHandle {
    fn run_turn(
        &mut self,
        turn: NativeTurn,
    ) -> BoxFuture<'static, Result<ToolTurnOutcome, AgentError>> {
        let agent_slot = Arc::clone(&self.agent);
        let config_slot = Arc::clone(&self.config);
        Box::pin(async move {
            // Agent/配置缺失说明 turn 已被取消或视图重建：按 Cancelled 收尾，
            // 不把内部状态错误暴露成用户可见的失败。
            let Some(mut agent) = agent_slot.lock().expect("native runtime agent").take() else {
                return Err(AgentError::Cancelled);
            };
            let config = config_slot.lock().expect("native runtime config").take();
            let Some(config) = config else {
                *agent_slot.lock().expect("native runtime agent") = Some(agent);
                return Err(AgentError::Cancelled);
            };
            let native_cancel = agent.cancel_token();
            turn.cancel.on_cancel(move || native_cancel.cancel());
            let mut observer = turn.observer;
            let auto_approver = AutoApprover;
            let approver: &dyn Approver = if config.auto_approve {
                &auto_approver
            } else {
                turn.approver.as_ref()
            };
            let result = agent
                .prompt_with_tools_observed(
                    config.provider.as_ref(),
                    &config.model,
                    turn.prompt,
                    config.registry.as_ref(),
                    &config.context,
                    approver,
                    &mut *observer,
                )
                .await;
            // 无论成功/取消/失败都把 Agent 交回视图（保存线程、checkpoint 依赖它）。
            *agent_slot.lock().expect("native runtime agent") = Some(agent);
            result
        })
    }
}
