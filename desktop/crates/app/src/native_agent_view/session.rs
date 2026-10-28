//! Read-only runtime projection and asynchronous commands; no Agent or store in the view.
use super::*;
use crate::native_runtime::NativeRuntimeError;
use std::future::Future;

impl NativeAgentView {
    pub(super) fn metadata(&self) -> &NativeRuntimeSnapshot {
        self.snapshot
            .as_deref()
            .expect("render and commands require initialized runtime")
    }
    pub fn is_empty_thread(&self) -> bool {
        self.snapshot
            .as_ref()
            .is_none_or(|snapshot| snapshot.thread.entries.is_empty())
    }
    pub fn current_thread_id(&self) -> Option<String> {
        self.snapshot
            .as_ref()
            .map(|snapshot| snapshot.thread.id.clone())
    }
    pub fn display_title(&self) -> String {
        self.snapshot
            .as_ref()
            .and_then(|snapshot| snapshot.display_title.as_deref())
            .unwrap_or("新对话")
            .to_string()
    }
    pub fn set_title_override(&mut self, title: Option<String>, _cx: &mut Context<Self>) {
        self.runtime.rename(title);
    }
    pub fn regenerate_title(&mut self, _cx: &mut Context<Self>) {
        self.runtime.generate_title(true);
    }
    pub(super) fn command(
        &mut self,
        operation: impl Future<Output = Result<Arc<NativeRuntimeSnapshot>, NativeRuntimeError>>
            + Send
            + 'static,
        cx: &mut Context<Self>,
    ) {
        cx.spawn(async move |this, cx| {
            if let Err(error) = operation.await {
                let _ = this.update(cx, |this, cx| {
                    this.status = error.to_string();
                    this.state.push_notice(error.to_string());
                    cx.notify();
                });
            }
        })
        .detach();
    }
    pub fn open_thread(&mut self, thread_id: &str, cx: &mut Context<Self>) -> bool {
        if self.is_generating() {
            self.status = NativeRuntimeError::Busy.to_string();
            cx.notify();
            return false;
        }
        self.command(self.runtime.open_thread(thread_id.to_string()), cx);
        true
    }
    pub fn start_new_thread(&mut self, cx: &mut Context<Self>) {
        self.command(self.runtime.new_thread(), cx);
    }
    fn persist_native(&self, snapshot: &NativeRuntimeSnapshot) {
        let Some(writer) = &self.writer else { return };
        if snapshot.thread.entries.is_empty() {
            return;
        }
        let _ = writer.submit(cgc_agent_store::WriterCommand::Snapshot {
            target: cgc_agent_store::StoreTarget::Native,
            thread: Some(Box::new(snapshot.thread.as_ref().clone())),
            snapshot: Box::new(cgc_agent_store::SavedConversation::from_thread(
                &self.state.session.thread,
                cgc_agent_store::SnapshotSource::Native,
                snapshot.revision,
            )),
        });
    }

    pub(super) fn apply_snapshot(
        &mut self,
        change: RuntimeChange,
        snapshot: Arc<NativeRuntimeSnapshot>,
        cx: &mut Context<Self>,
    ) {
        if self.snapshot.as_ref().is_some_and(|current| {
            snapshot.generation < current.generation || snapshot.revision < current.revision
        }) {
            return;
        }
        let reset = matches!(
            change,
            RuntimeChange::Initialized | RuntimeChange::Opened | RuntimeChange::Rewound
        );
        if reset
            && self.snapshot.as_ref().is_some_and(|current| {
                current.generation == snapshot.generation && current.revision == snapshot.revision
            })
        {
            return;
        }
        if reset {
            self.state.session.disconnect();
            self.state.session.thread =
                cgc_agent_ui::conversation::ConversationThread::new(snapshot.thread.id.clone())
                    .with_capabilities(cgc_agent_ui::conversation::ThreadCapabilities::native());
            self.sent_images =
                apply_thread_entries(&mut self.state.session.thread, &snapshot.thread.entries);
            self.state.subagents.clear();
            self.expanded_tools.clear();
            self.expanded_thinking.clear();
            self.editing_user = None;
            self.user_edit_input = None;
            self.pending_restart_confirm = None;
            self.show_checkpoint_panel = false;
            self.pending_images.clear();
            self.state.session.queue.clear();
            self.workspace_files = collect_workspace_files(&snapshot.workspace);
            self.skills = mention::load_skills(&snapshot.workspace);
        }
        self.state.usage_total = snapshot.thread.usage_total;
        self.state.session.thread.usage.size = snapshot.model.limits.context_window as u64;
        self.state.session.thread.title = snapshot.display_title.as_deref().map(str::to_string);
        let idle = snapshot.phase == RuntimePhase::Idle;
        self.status = match snapshot.phase {
            RuntimePhase::Loading => "正在载入会话…",
            RuntimePhase::Running => "思考中…",
            RuntimePhase::Draining => "正在释放模型连接…",
            RuntimePhase::Idle => "就绪",
        }
        .into();
        // turn 收尾：执行内容与展示投影同事务落盘，未答审批不会被恢复成活跃授权。
        if idle
            && self
                .snapshot
                .as_ref()
                .is_none_or(|current| current.revision != snapshot.revision)
        {
            self.persist_native(&snapshot);
        }
        self.snapshot = Some(snapshot);
        if reset {
            self.connect_native(cx);
        }
        if idle {
            self.state
                .session
                .mark_ready_for_next(self.state.session.generation);
            self.dispatch_queued(cx);
        }
        cx.notify();
    }
}
