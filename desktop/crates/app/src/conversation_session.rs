//! Client-side ownership shared by native and external ACP. No execution dependencies.
use crate::{
    agent_ingest,
    page_context::{ConversationScope, FrozenPageContext, PageContextState},
};
use cgc_agent_core::ImageAttachment;
use cgc_agent_ui::conversation::{ConversationThread, ThreadCapabilities, ThreadStatus};
use cgc_platform::acp::connection::{AcpHost, CommandView, ConfigOptionView, HostEvent};

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub enum ConnectionPhase {
    #[default]
    Idle,
    Starting,
    Ready,
    Failed(String),
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum QueueMode {
    #[default]
    Auto,
    Paused,
}

#[derive(Clone)]
pub struct Submission {
    pub id: u64,
    pub display: String,
    pub prompt: String,
    pub context: Option<FrozenPageContext>,
    pub draft: Option<cgc_agent_ui::conversation::MessageDraft>,
    pub images: Vec<ImageAttachment>,
    /// 本次消息携带的结构化学习动作；发送一次后消费。
    pub agent_call: Option<crate::agent_call::AgentCall>,
    pub retry: bool,
}

#[derive(Default)]
pub struct ConversationSession {
    pub thread: ConversationThread,
    pub phase: ConnectionPhase,
    pub host: Option<AcpHost>,
    pub generation: u64,
    pub session_id: Option<String>,
    pub configs: Vec<ConfigOptionView>,
    pub commands: Vec<CommandView>,
    pub last_error: Option<String>,
    pub queue: Vec<Submission>,
    pub queue_mode: QueueMode,
    pub editing_submission: Option<u64>,
    next_submission: u64,
    in_flight: Option<Submission>,
    ready_for_next: bool,
    /// 本轮是否已到终态；迟到事件不得复活生成态。
    turn_closed: bool,
}

/// 只属于「一轮进行中」的事件：终态之后到达时应丢弃，而不是重新拉起生成中。
fn is_late_stream_event(event: &HostEvent) -> bool {
    matches!(
        event,
        HostEvent::Delta(_)
            | HostEvent::ThoughtDelta(_)
            | HostEvent::ToolCall { .. }
            | HostEvent::ToolCallUpdated { .. }
            | HostEvent::PlanUpdated { .. }
            | HostEvent::UsageUpdated { .. }
            | HostEvent::CompactionUpdated { .. }
    )
}

impl ConversationSession {
    pub fn new(thread: ConversationThread) -> Self {
        Self {
            thread,
            ..Self::default()
        }
    }
    pub fn native() -> Self {
        Self::new(ConversationThread::new("native").with_capabilities(ThreadCapabilities::native()))
    }
    pub fn is_busy(&self) -> bool {
        self.in_flight.is_some() || self.thread.is_generating()
    }
    pub fn can_submit(&self) -> bool {
        self.phase == ConnectionPhase::Ready && self.ready_for_next && !self.is_busy()
    }
    pub fn submission(
        &mut self,
        display: String,
        prompt: String,
        context: Option<FrozenPageContext>,
        images: Vec<ImageAttachment>,
        retry: bool,
    ) -> Submission {
        self.next_submission = self.next_submission.wrapping_add(1);
        Submission {
            id: self.next_submission,
            display,
            prompt,
            context,
            draft: None,
            images,
            agent_call: None,
            retry,
        }
    }
    pub fn reserve(&mut self) {
        self.ready_for_next = false;
    }
    /// Replacing a host invalidates all callbacks before dropping its nonblocking handle.
    pub fn attach(&mut self, host: AcpHost) -> u64 {
        self.disconnect();
        self.host = Some(host);
        self.phase = ConnectionPhase::Starting;
        self.generation
    }
    pub fn disconnect(&mut self) {
        self.generation = self.generation.wrapping_add(1);
        self.host.take();
        self.in_flight = None;
        self.ready_for_next = false;
        self.phase = ConnectionPhase::Idle;
    }
    pub fn mark_ready_for_next(&mut self, generation: u64) {
        if generation != self.generation {
            return;
        }
        self.ready_for_next = true;
    }
    pub fn accepted(&mut self, submission: Submission) {
        if !submission.retry {
            agent_ingest::apply_user_turn(&mut self.thread, submission.display.clone());
        } else {
            self.thread.status = ThreadStatus::Generating;
        }
        let users = self
            .thread
            .entries
            .iter()
            .filter(|entry| matches!(entry, cgc_agent_ui::conversation::Entry::User { .. }))
            .count();
        self.thread.user_drafts.resize(users, None);
        if let Some(slot) = self.thread.user_drafts.last_mut() {
            *slot = submission.draft.clone();
        }
        self.last_error = None;
        self.ready_for_next = false;
        self.turn_closed = false;
        self.in_flight = Some(submission);
    }
    /// The caller keeps ownership when the connection refuses the prompt.
    pub fn send(&mut self, submission: &Submission) -> bool {
        if !self.can_submit() {
            return false;
        }
        if !self
            .host
            .as_ref()
            .is_some_and(|host| host.prompt(submission.prompt.clone()))
        {
            self.phase = ConnectionPhase::Failed("agent channel closed".into());
            return false;
        }
        self.accepted(submission.clone());
        true
    }
    pub(crate) fn send_with_context(
        &mut self,
        submission: &mut Submission,
        page_context: &PageContextState,
        scope: &ConversationScope,
    ) -> bool {
        (submission.prompt, submission.context) = page_context.refresh(
            scope.clone(),
            std::mem::take(&mut submission.prompt),
            submission.context.take(),
        );
        let agent_call = submission.agent_call.take();
        let prompt_without_action = submission.prompt.clone();
        if let Some(call) = &agent_call {
            submission.prompt = crate::agent_call::prompt_with_agent_call(&submission.prompt, call);
        }
        if !self.send(submission) {
            submission.prompt = prompt_without_action;
            submission.agent_call = agent_call;
            return false;
        }
        page_context.mark_sent(scope, &submission.context);
        true
    }

    pub fn stop(&mut self) {
        self.queue_mode = QueueMode::Paused;
        if let Some(host) = &self.host {
            host.stop();
        }
    }
    pub fn next_queued(&mut self) -> Option<Submission> {
        if !self.can_submit()
            || self.queue_mode != QueueMode::Auto
            || self.queue.is_empty()
            || self.editing_submission == self.queue.first().map(|submission| submission.id)
        {
            return None;
        }
        Some(self.queue.remove(0))
    }
    /// Generation is checked before ingestion, metadata, or terminal bookkeeping.
    pub fn ingest(&mut self, generation: u64, event: &HostEvent) -> bool {
        if generation != self.generation {
            return false;
        }
        // 终态只记录一次：本轮已经结束时，迟到的流式事件不得把界面重新拉回生成中。
        if self.turn_closed && is_late_stream_event(event) {
            return false;
        }
        agent_ingest::apply_thread_event(&mut self.thread, event);
        match event {
            HostEvent::Ready { session_id, .. } => {
                self.phase = ConnectionPhase::Ready;
                self.session_id = Some(session_id.clone());
                self.ready_for_next = true;
            }
            HostEvent::ConfigOptions { options } => self.configs = options.clone(),
            HostEvent::AvailableCommands { commands } => self.commands = commands.clone(),
            HostEvent::TurnEnd { .. } => {
                self.in_flight = None;
                self.turn_closed = true;
            }
            HostEvent::Error { message } => {
                self.last_error = Some(message.clone());
                self.in_flight = None;
                self.turn_closed = true;
            }
            HostEvent::Exited => {
                self.host.take();
                self.in_flight = None;
                self.ready_for_next = false;
                self.turn_closed = true;
                if !matches!(self.phase, ConnectionPhase::Failed(_)) {
                    self.phase = ConnectionPhase::Failed("agent connection exited".into());
                }
            }
            _ => {}
        }
        true
    }

    pub(crate) fn ingest_external(&mut self, generation: u64, event: &HostEvent) -> bool {
        if !self.ingest(generation, event) {
            return false;
        }
        if matches!(event, HostEvent::TurnEnd { .. }) {
            self.mark_ready_for_next(generation);
        }
        true
    }

    pub fn drain(&self, generation: u64) -> Vec<HostEvent> {
        if generation != self.generation {
            return Vec::new();
        }
        let mut events = Vec::new();
        if let Some(host) = &self.host {
            while let Some(event) = host.try_recv() {
                events.push(event);
            }
        }
        events
    }
    pub fn resolve_permission(&mut self, option_id: &str) -> bool {
        let Some(pending) = self.thread.pending_permission.as_ref() else {
            return false;
        };
        let allowed = agent_ingest::permission_option_allowed(&pending.options, option_id);
        if !self
            .host
            .as_ref()
            .is_some_and(|host| host.respond_permission_option(&pending.request_id, option_id))
        {
            return false;
        }
        let request_id = pending.request_id.clone();
        agent_ingest::apply_permission_resolved(&mut self.thread, request_id, allowed);
        true
    }
    pub(crate) fn restore_thread(&mut self, mut thread: ConversationThread) {
        thread.status = ThreadStatus::Idle;
        thread.pending_permission = None;
        self.thread = thread;
        self.in_flight = None;
        self.last_error = None;
        self.turn_closed = true;
    }

    pub fn begin_retry(&mut self) -> bool {
        self.last_error.take().is_some()
    }

    pub(crate) fn sync_native_drafts(
        &mut self,
        source: &cgc_agent_core::Thread,
        hidden_users: usize,
    ) -> bool {
        let source_users = source
            .entries
            .iter()
            .filter_map(|entry| match entry {
                cgc_agent_core::Entry::User { text, display, .. } => {
                    Some(display.as_deref().unwrap_or(text))
                }
                _ => None,
            })
            .collect::<Vec<_>>();
        let visible_users = self.thread.entries.iter().filter_map(|entry| match entry {
            cgc_agent_ui::conversation::Entry::User { text } => Some(text.as_str()),
            _ => None,
        });
        if self.is_busy()
            || source_users
                .get(hidden_users..)
                .is_none_or(|users| !visible_users.eq(users.iter().copied()))
        {
            return false;
        }
        self.thread.user_drafts = (hidden_users..source_users.len())
            .map(|ordinal| {
                source
                    .user_drafts
                    .get(ordinal)
                    .and_then(|draft| draft.as_ref())
                    .and_then(|value| serde::Deserialize::deserialize(value).ok())
            })
            .collect();
        true
    }

    pub(crate) fn native_retry(
        &mut self,
        source: &cgc_agent_core::Thread,
        workspace: &std::path::Path,
        page_context: &PageContextState,
        scope: ConversationScope,
    ) -> Option<Submission> {
        let cgc_agent_core::Entry::User {
            text,
            display,
            images,
            ..
        } = source
            .entries
            .iter()
            .rev()
            .find(|entry| matches!(entry, cgc_agent_core::Entry::User { .. }))?
        else {
            return None;
        };
        let ordinal = source
            .entries
            .iter()
            .filter(|entry| matches!(entry, cgc_agent_core::Entry::User { .. }))
            .count()
            - 1;
        let saved_draft = source
            .user_drafts
            .get(ordinal)
            .and_then(|draft| draft.as_ref())
            .and_then(|draft| serde::Deserialize::deserialize(draft).ok());
        page_context.invalidate_loaded(&scope);
        let (draft, prompt, context) = if let Some(draft) = saved_draft {
            let mut composer = crate::composer_context::ComposerContext::default();
            let content = composer.restore(&draft);
            let (draft, prompt, context) =
                composer.freeze(&content, None, workspace, page_context, scope);
            (Some(draft), prompt, context)
        } else {
            (None, text.clone(), None)
        };
        let mut submission = self.submission(
            display.as_ref().unwrap_or(text).clone(),
            prompt,
            context,
            images.clone(),
            true,
        );
        submission.draft = draft;
        Some(submission)
    }
}

#[cfg(test)]
mod tests;
