//! Desktop composition root: one writable native owner and one revocable authorization epoch.
use super::*;
use crate::native_panel_host::{McpContext, NativePanelHost};
use crate::native_runtime::{NativeRuntimeEvent, NativeRuntimeHandle, RuntimePhase};
use futures::StreamExt as _;

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
        let state = Arc::new(std::sync::Mutex::new(cgc_agent_tools::AgentState::default()));
        let mut host = NativePanelHost::new(
            state,
            Some(cgc_agent_store::AuditLog::new(paths.agent_audit_file())),
        );
        host.set_mcp_context(self.agent_mcp.clone());
        let runtime = NativeRuntimeHandle::for_scope(
            scope.clone(),
            paths.data_root,
            host,
            self.workspaces.epoch(),
        );
        let context = self.page_context.clone();
        self.native_agent_view = Some(cx.new(|cx| {
            crate::native_agent_view::NativeAgentView::new(window, cx, runtime.clone(), context)
        }));
        self.native_scope = Some(scope);
        self.native_runtime = Some(runtime);
        self.prepare_agent_authorization(cx);
    }

    pub fn isolated_native_demo(
        window: &mut Window,
        cx: &mut App,
    ) -> Entity<crate::native_agent_view::NativeAgentView> {
        let serial = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        let data_root =
            std::env::temp_dir().join(format!("cgc-native-demo-{}-{serial}", std::process::id()));
        let scope = crate::agent_scope::AgentScope {
            key: "demo".into(),
            root: data_root.join("workspace"),
        };
        let host = NativePanelHost::new(
            Arc::new(std::sync::Mutex::new(cgc_agent_tools::AgentState::default())),
            None,
        );
        let runtime = NativeRuntimeHandle::for_scope(scope, data_root, host, 0);
        cx.new(|cx| {
            crate::native_agent_view::NativeAgentView::new(window, cx, runtime, Default::default())
        })
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
        self.revoke_agent_authorization(cx);
        let Some(session_token) = self.session_token() else {
            return;
        };
        self.agent_lease_pending = Some(epoch);
        let authorization_serial = self.agent_authorization_serial;
        let workspace_id = self.workspaces.current_id().map(str::to_string);
        let task = cx.background_executor().spawn(async move {
            let result = issue_lease(
                build_learning_host_api().as_ref(),
                build_learning_host_vault().as_ref(),
                &session_token,
                "cgc-desktop",
                epoch,
            );
            (result, session_token)
        });
        cx.spawn(async move |this, cx| {
            let (result, session_token) = task.await;
            let _ = this.update(cx, |this, cx| {
                if this.workspaces.epoch() != epoch
                    || !this.is_signed_in()
                    || this.agent_authorization_serial != authorization_serial
                {
                    if let Ok(lease) = result {
                        Self::revoke_lease_with_session(lease, session_token, cx);
                    }
                    return;
                }
                this.agent_lease_pending = None;
                match result {
                    Ok(lease) => {
                        let context = McpContext::for_lease(
                            lease,
                            epoch,
                            std::env::var("CGC_API_URL").ok().as_deref(),
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
                        this.pane_notice =
                            Some(format!("平台工具暂不可用：{}", error.diagnostic()));
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

    pub(in crate::root_view) fn revoke_agent_authorization(&mut self, cx: &mut Context<Self>) {
        self.agent_lease_pending = None;
        self.agent_authorization_serial = self.agent_authorization_serial.wrapping_add(1);
        if let Some(context) = self.agent_mcp.take() {
            context.revoke(); // synchronous: already-captured clients cannot use it again
            if let Some(session_token) = self.session_token() {
                Self::revoke_lease_with_session(context.lease().clone(), session_token, cx);
            }
        }
        if let Some(runtime) = &self.native_runtime {
            runtime.set_mcp_context(None, self.workspaces.epoch());
        }
    }

    fn revoke_lease_with_session(
        lease: LearningHostLease,
        session_token: String,
        cx: &mut Context<Self>,
    ) {
        cx.background_executor()
            .spawn(async move {
                let _ = build_learning_host_api().revoke(&session_token, &lease.token_id);
            })
            .detach();
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
