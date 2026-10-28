use super::worker::{Job, Owner};
use super::*;
use crate::native_panel_host::McpContext;
use cgc_agent_tools::Tool;
use cgc_platform::mcp::client::McpClientError;
use futures::FutureExt;

pub(super) struct McpTools {
    context: McpContext,
    tools: Vec<Arc<dyn Tool>>,
}

impl Owner {
    pub(super) fn update_mcp(&mut self, context: Option<McpContext>, epoch: u64) {
        if epoch < self.authorization_epoch {
            if let Some(context) = context {
                let current = self
                    .production
                    .as_ref()
                    .and_then(|production| production.host.mcp_context());
                if !current.is_some_and(|current| current.same_authority(&context)) {
                    context.revoke();
                }
            }
            return;
        }
        let context = context.filter(|context| {
            if context.epoch() == epoch {
                true
            } else {
                context.revoke();
                false
            }
        });
        let epoch_changed = epoch != self.authorization_epoch;
        self.authorization_epoch = epoch;
        let Some(production) = &mut self.production else {
            return;
        };
        let had_authority = production.host.mcp_context().is_some();
        let changed = production.host.set_mcp_context(context);
        if !changed && !epoch_changed {
            return;
        }
        if epoch_changed || had_authority {
            if let Some(active) = &self.active {
                active.cancel.cancel();
            }
            self.generation = self.generation.wrapping_add(1);
            self.cancel_title();
            self.prepared = None;
        }
        self.rebuild_tools();
        self.publish(RuntimeChange::Tools);
    }

    pub(super) fn rebuild_tools(&mut self) {
        if let Some(production) = &self.production {
            let mut registry = factory::base_tools(
                production,
                &mut self.config,
                &self.commands,
                self.generation,
            );
            let context = production
                .host
                .mcp_context()
                .filter(|context| !context.is_revoked());
            let cached = match (&self.mcp_tools, context) {
                (Some(cached), Some(current)) if cached.context.same_authority(current) => {
                    Some(&cached.tools)
                }
                _ => None,
            };
            if let Some(tools) = cached {
                for tool in tools {
                    registry.register(tool.clone());
                }
                self.mcp_unavailable_reason = tools
                    .is_empty()
                    .then(|| Arc::from("当前授权没有可用的学习工具"));
            } else {
                self.mcp_tools = None;
                self.mcp_unavailable_reason = Some(if context.is_some() {
                    Arc::from("正在准备当前授权可见的平台工具")
                } else {
                    Arc::from("学习授权尚未就绪，平台工具不可用")
                });
            }
            self.config.registry = Arc::new(registry);
        }
        self.schemas = Arc::new(self.config.registry.schemas());
        if self.model_meta.as_ref() != &self.config.model {
            self.model_meta = Arc::new(self.config.model.clone());
        }
        if self.workspace_meta.as_path() != self.config.context.workspace() {
            self.workspace_meta = Arc::new(self.config.context.workspace().to_path_buf());
        }
        self.prepare_mcp();
    }

    fn prepare_mcp(&mut self) {
        if self.mcp_tools.is_some() {
            return;
        }
        let context = self
            .production
            .as_ref()
            .and_then(|production| production.host.mcp_context())
            .filter(|context| !context.is_revoked())
            .cloned();
        let Some(context) = context else {
            self.mcp_probe_pending = false;
            return;
        };
        if self.mcp_probe_running {
            self.mcp_probe_pending = !self
                .mcp_probe_context
                .as_ref()
                .is_some_and(|active| active.same_authority(&context));
            return;
        }
        self.mcp_probe_running = true;
        self.mcp_probe_pending = false;
        self.mcp_probe_context = Some(context.clone());
        let (sender, receiver) = oneshot::channel();
        let request_context = context.clone();
        let spawned = std::thread::Builder::new()
            .name("native-mcp-discovery".into())
            .spawn(move || {
                let _ = sender.send(request_context.discover_tools());
            });
        if let Err(error) = spawned {
            self.mcp_probe_running = false;
            self.mcp_probe_context = None;
            self.mcp_unavailable_reason = Some(Arc::from(format!("无法准备平台工具：{error}")));
            return;
        }
        self.jobs.push(
            async move {
                let result = receiver.await.unwrap_or_else(|_| {
                    Err(McpClientError::Transport("平台工具准备任务已关闭".into()))
                });
                Job::Mcp { context, result }
            }
            .boxed(),
        );
    }

    pub(super) fn mcp_prepared(
        &mut self,
        context: McpContext,
        result: Result<Vec<Arc<dyn Tool>>, McpClientError>,
    ) {
        self.mcp_probe_running = false;
        self.mcp_probe_context = None;
        let current = self
            .production
            .as_ref()
            .and_then(|production| production.host.mcp_context());
        let current = current
            .is_some_and(|current| !current.is_revoked() && current.same_authority(&context));
        if current {
            match result {
                Ok(tools) => {
                    self.mcp_tools = Some(McpTools { context, tools });
                    self.rebuild_tools();
                }
                Err(error) => {
                    self.mcp_unavailable_reason =
                        Some(Arc::from(format!("平台工具不可用：{error}")))
                }
            }
            self.publish(RuntimeChange::Tools);
        }
        if self.mcp_probe_pending {
            self.prepare_mcp();
        }
    }
}
