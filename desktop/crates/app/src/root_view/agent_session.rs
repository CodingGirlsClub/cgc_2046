//! Desktop composition root: one writable native owner and one revocable authorization epoch.
use super::*;
use crate::native_panel_host::{McpContext, NativePanelHost};
use crate::native_runtime::{NativeRuntimeEvent, NativeRuntimeHandle, RuntimePhase};
use futures::{FutureExt as _, StreamExt as _};

#[cfg(test)]
mod tests;

pub(super) type AuthorizationTail =
    futures::future::Shared<futures::future::BoxFuture<'static, ()>>;

pub(super) async fn after_authorization<T>(
    previous: Option<AuthorizationTail>,
    operation: impl FnOnce() -> T,
) -> T {
    if let Some(previous) = previous {
        previous.await;
    }
    operation()
}

impl RootView {
    pub fn initialize_agent_session(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.native_runtime.is_some() {
            return;
        }
        let scope = crate::agent_scope::resolve(
            self.session
                .signed_in()
                .map(|session| session.user_id.as_str()),
        );
        let paths = AppPaths::from_env();
        let allow_echo = paths.environment == cgc_platform::paths::AppEnvironment::Dev;
        let state = Arc::new(std::sync::Mutex::new(cgc_agent_tools::AgentState::default()));
        let mut host = NativePanelHost::new(
            state,
            Some(cgc_agent_store::AuditLog::new(paths.agent_audit_file())),
        );
        host.set_mcp_context(self.agent_mcp.clone());
        let runtime = NativeRuntimeHandle::for_scope(
            scope.clone(),
            paths.data_root.clone(),
            host,
            self.workspaces.epoch(),
            allow_echo,
        );
        let context = self.page_context.clone();
        if self.store_writer.is_none() {
            self.store_writer = Some(cgc_agent_store::StoreWriter::spawn(
                paths.data_root.join(cgc_agent_store::CONVERSATIONS_DB),
                paths.data_root.join("agent").join("threads.db"),
            ));
        }
        let writer = self.store_writer.clone();
        let language = self.language;
        self.native_agent_view = Some(cx.new(|cx| {
            crate::native_agent_view::NativeAgentView::new(
                window,
                cx,
                runtime.clone(),
                context,
                language,
                writer,
            )
        }));
        if let Some(view) = self.native_agent_view.clone() {
            self.native_agent_view_subscription = Some(cx.subscribe_in(
                &view,
                window,
                |_this,
                 _view,
                 _event: &crate::native_agent_view::NativeAgentViewEvent,
                 _window,
                 cx| {
                    // header 的标题/生成态读的是 view 快照；子实体重绘不会带父级。
                    cx.notify();
                },
            ));
        }
        self.native_scope = Some(scope);
        self.native_runtime = Some(runtime);
        self.prepare_agent_authorization(cx);
    }

    pub(in crate::root_view) fn prepare_agent_authorization(&mut self, cx: &mut Context<Self>) {
        self.update_native_scope(cx);
        let epoch = self.workspaces.epoch();
        if self
            .agent_mcp
            .as_ref()
            .is_some_and(|context| context.epoch() == epoch && !context.is_revoked())
            || self.agent_lease_pending == Some(epoch)
        {
            return;
        }
        self.invalidate_agent_clients(cx);
        let Some(session_token) = self.session_token() else {
            return;
        };
        let Some(scope) = self.agent_lease_scope() else {
            return;
        };
        self.agent_lease_pending = Some(epoch);
        let authorization_serial = self.agent_authorization_serial;
        // 工具固定参数随页面：工作区路由 > 站点级课程归属 > 当前工作区；
        // 作用域变化由 sync_agent_workspace_scope 重建上下文。
        let workspace_id = self.agent_workspace_id();
        let previous = self.agent_authorization_tail.take();
        let api = build_learning_host_api(&scope);
        let vault = build_learning_host_vault(&scope);
        let requested_scope = scope.clone();
        let task = cx
            .background_executor()
            .spawn(async move {
                after_authorization(previous, || {
                    issue_lease(
                        api.as_ref(),
                        vault.as_ref(),
                        &session_token,
                        "cgc-desktop",
                        epoch,
                        &scope,
                    )
                })
                .await
            })
            .shared();
        let completion = task.clone();
        self.agent_authorization_tail = Some(
            async move {
                let _ = completion.await;
            }
            .boxed()
            .shared(),
        );
        cx.spawn(async move |this, cx| {
            let result = task.await;
            let _ = this.update(cx, |this, cx| {
                if this.workspaces.epoch() != epoch
                    || !this.is_signed_in()
                    || this.agent_authorization_serial != authorization_serial
                    || this.agent_lease_scope().as_ref() != Some(&requested_scope)
                {
                    return;
                }
                this.agent_lease_pending = None;
                this.agent_authorization_tail = None;
                match result {
                    Ok(lease) => {
                        this.agent_authorization_error = None;
                        let context = McpContext::for_lease(
                            lease,
                            epoch,
                            Some(&requested_scope.endpoint),
                            workspace_id.as_deref(),
                        );
                        this.agent_mcp = context.clone();
                        if let Some(runtime) = &this.native_runtime {
                            runtime.set_mcp_context(context, epoch);
                        }
                        if this.chat.start_after_authorization {
                            this.chat.start_after_authorization = false;
                            this.start_chat(cx);
                        }
                    }
                    Err(error) => {
                        // 授权失败只进横幅 tooltip 时，用户与内测日志都看不出失败类别
                        // （后台不可达 vs 凭据不可用）。这里落一条可定位的 WARN；lease
                        // 明文从不进错误类型，logger 另有 redact 兜底（issue #1238）。
                        log::warn!(
                            target: "mcp",
                            "平台授权失败 endpoint={} epoch={epoch}：{}",
                            requested_scope.endpoint,
                            error.diagnostic()
                        );
                        this.agent_authorization_error = Some(error.clone());
                        if this.chat.start_after_authorization {
                            this.chat.start_after_authorization = false;
                            this.chat.session.phase = ConnectionPhase::Failed(error.diagnostic());
                        }
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    fn agent_lease_scope(&self) -> Option<LeaseScope> {
        let session = self.session.signed_in()?;
        Some(LeaseScope::new(
            &session.user_id,
            &cgc_platform::runtime::api_endpoint(),
        ))
    }

    /// Agent/MCP 固定参数的工作区：工作区路由 > 站点级课程归属 > 当前工作区。
    pub(in crate::root_view) fn agent_workspace_id(&self) -> Option<String> {
        if let Some(id) = self.route_workspace_id() {
            return Some(id);
        }
        if let Some(id) = self
            .current
            .as_ref()
            .filter(|route_match| {
                matches!(
                    route_match.route.id,
                    "courses.detail"
                        | "courses.learning"
                        | "courses.public_detail"
                        | "courses.public_learning"
                )
            })
            .and_then(|_| self.course_detail.detail())
            .and_then(|detail| detail.workspace_id.clone())
        {
            if self
                .workspaces
                .workspaces()
                .iter()
                .any(|workspace| workspace.id == id && workspace.can_access)
            {
                return Some(id);
            }
        }
        self.workspaces.current_id().map(str::to_string)
    }

    /// 页面作用域变化（同 epoch 内换工作区/进站点级课程页）时重建工具上下文。
    pub(in crate::root_view) fn sync_agent_workspace_scope(&mut self, cx: &mut Context<Self>) {
        let Some(context) = self.agent_mcp.as_ref() else {
            return;
        };
        let current = context.workspace_id().map(str::to_string);
        if current != self.agent_workspace_id() {
            self.invalidate_agent_clients(cx);
            self.prepare_agent_authorization(cx);
        }
    }

    fn invalidate_agent_clients(&mut self, _cx: &mut Context<Self>) {
        self.agent_lease_pending = None;
        self.agent_authorization_serial = self.agent_authorization_serial.wrapping_add(1);
        self.agent_authorization_error = None;
        if let Some(context) = self.agent_mcp.take() {
            context.revoke();
        }
        if let Some(runtime) = &self.native_runtime {
            runtime.set_mcp_context(None, self.workspaces.epoch());
        }
    }

    pub(in crate::root_view) fn revoke_agent_authorization(&mut self, cx: &mut Context<Self>) {
        let credentials = self.session_token().zip(self.agent_lease_scope());
        self.invalidate_agent_clients(cx);
        let Some((session_token, scope)) = credentials else {
            return;
        };
        let previous = self.agent_authorization_tail.take();
        let api = build_learning_host_api(&scope);
        let vault = build_learning_host_vault(&scope);
        let task = cx
            .background_executor()
            .spawn(async move {
                after_authorization(previous, || {
                    let _ =
                        revoke_saved_lease(api.as_ref(), vault.as_ref(), &session_token, &scope);
                })
                .await;
            })
            .shared();
        let completion = task.clone();
        self.agent_authorization_tail = Some(
            async move {
                completion.await;
            }
            .boxed()
            .shared(),
        );
        cx.spawn(async move |_, _| {
            task.await;
        })
        .detach();
    }

    pub(in crate::root_view) fn retry_agent_authorization(&mut self, cx: &mut Context<Self>) {
        self.prepare_agent_authorization(cx);
    }

    fn update_native_scope(&mut self, cx: &mut Context<Self>) {
        let scope = crate::agent_scope::resolve(
            self.session
                .signed_in()
                .map(|session| session.user_id.as_str()),
        );
        if self.native_scope.as_ref() == Some(&scope) {
            return;
        }
        let Some(runtime) = self.native_runtime.clone() else {
            return;
        };
        self.native_scope = Some(scope.clone());
        let epoch = self.workspaces.epoch();
        runtime.stop();
        runtime.set_mcp_context(None, epoch);
        let mut events = runtime.subscribe();
        cx.spawn(async move |this, cx| {
            while let Some(event) = events.next().await {
                if let NativeRuntimeEvent::Snapshot { snapshot, .. } = event.as_ref() {
                    if snapshot.authorization_epoch > epoch {
                        break;
                    }
                    if snapshot.phase == RuntimePhase::Idle && snapshot.authorization_epoch == epoch
                    {
                        let current = this
                            .read_with(cx, |this, _| this.workspaces.epoch() == epoch)
                            .unwrap_or(false);
                        if current {
                            if let Err(error) = runtime.switch_scope(scope).await {
                                let _ = this.update(cx, |this, cx| {
                                    this.pane_notice = Some(error.to_string());
                                    cx.notify();
                                });
                            }
                        }
                        break;
                    }
                }
            }
        })
        .detach();
    }
}
