//! Client-side ownership shared by native and external ACP. No execution dependencies.
use crate::{agent_ingest, page_context::PageContext};
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
    AbsorbingCancel,
}

#[derive(Clone)]
pub struct Submission {
    pub id: u64,
    pub display: String,
    pub prompt: String,
    pub context: Option<PageContext>,
    pub images: Vec<ImageAttachment>,
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
        context: Option<PageContext>,
        images: Vec<ImageAttachment>,
        retry: bool,
    ) -> Submission {
        self.next_submission = self.next_submission.wrapping_add(1);
        Submission {
            id: self.next_submission,
            display,
            prompt,
            context,
            images,
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
        self.last_error = None;
        self.ready_for_next = false;
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
            }
            HostEvent::Error { message } => {
                self.last_error = Some(message.clone());
                self.in_flight = None;
            }
            HostEvent::Exited => {
                self.host.take();
                self.in_flight = None;
                self.ready_for_next = false;
                if !matches!(self.phase, ConnectionPhase::Failed(_)) {
                    self.phase = ConnectionPhase::Failed("agent connection exited".into());
                }
            }
            _ => {}
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
    pub fn begin_retry(&mut self) -> bool {
        self.last_error.take().is_some()
    }
}

#[cfg(test)]
mod tests;
