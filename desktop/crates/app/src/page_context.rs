//! RootView-owned page context. Explicit clones share one controller's context;
//! independent roots and demos never share a process-global slot.
//! Each submission freezes both the structured context and its prompt prefix.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

mod projection;
pub(crate) use projection::{
    project_course_detail, project_course_learning, project_course_list, project_enrollments,
    project_event_detail, project_event_list, project_issue, project_workspace_overview,
};

/// 一次 Agent 会话的稳定身份。页面正文按线程与 Agent 分别记录加载状态。
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub(crate) struct ConversationScope {
    thread_id: String,
    agent_id: String,
    body_budget: usize,
}

impl ConversationScope {
    pub(crate) fn new(thread_id: impl Into<String>, agent_id: impl Into<String>) -> Self {
        Self::with_body_budget(thread_id, agent_id, 20_000)
    }

    pub(crate) fn with_body_budget(
        thread_id: impl Into<String>,
        agent_id: impl Into<String>,
        body_budget: usize,
    ) -> Self {
        Self {
            thread_id: thread_id.into(),
            agent_id: agent_id.into(),
            body_budget,
        }
    }
}

/// 当前 tab 的可提交正文及其读取状态。
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PageBody {
    Ready(Arc<str>),
    Loading,
    Empty,
    Unavailable(String),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum PageLoadState {
    Ready,
    Loading,
    Empty,
    Unavailable,
    Loaded,
    Partial,
    NeedsReload,
}

pub(crate) fn page_load_state_label(state: Option<PageLoadState>) -> &'static str {
    match state {
        Some(PageLoadState::Ready) => "已就绪",
        Some(PageLoadState::Loading) => "加载中",
        Some(PageLoadState::Empty) => "无正文",
        Some(PageLoadState::Unavailable) => "加载失败",
        Some(PageLoadState::Loaded) => "已在上下文中",
        Some(PageLoadState::Partial) => "部分加载",
        Some(PageLoadState::NeedsReload) => "需要重新加载",
        None => "未附加",
    }
}

/// 课程学习页的补充标识；通用页面上下文不依赖课程。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CourseContext {
    pub id: String,
    pub title: String,
    pub revision: Option<i64>,
    pub unit: Option<PageUnit>,
}

/// 当前单元（issue 卡）引用。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PageUnit {
    pub id: String,
    pub title: String,
}

/// 当前 active tab 的页面上下文。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PageContext {
    pub workspace_id: Option<String>,
    pub tab_id: String,
    pub route: String,
    pub title: String,
    pub version: String,
    pub body: PageBody,
    pub course: Option<CourseContext>,
}

impl PageContext {
    pub(crate) fn chip_title(&self) -> String {
        let page_title = self
            .course
            .as_ref()
            .map(|course| &course.title)
            .unwrap_or(&self.title);
        match self.course.as_ref().and_then(|course| course.unit.as_ref()) {
            Some(unit) => format!("{} · {}", page_title, unit.title),
            None => page_title.clone(),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum LoadCompleteness {
    Full,
    Partial,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FrozenPageContext {
    pub page: PageContext,
    scope: ConversationScope,
    epoch: u64,
    body_sent: Option<LoadCompleteness>,
    user_prompt: String,
}

#[derive(Default)]
struct ConversationContext {
    epoch: u64,
    loaded: HashMap<(Option<String>, String, String), (u64, LoadCompleteness)>,
}

#[derive(Default)]
struct Slot {
    context: Option<PageContext>,
    dismissed: bool,
    conversations: HashMap<(String, String), ConversationContext>,
}

#[derive(Clone, Default)]
pub(crate) struct PageContextState(Arc<Mutex<Slot>>);

impl PageContextState {
    fn lock(&self) -> std::sync::MutexGuard<'_, Slot> {
        self.0
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn scope_key(scope: &ConversationScope) -> (String, String) {
        (scope.thread_id.clone(), scope.agent_id.clone())
    }

    fn load_key(context: &PageContext) -> (Option<String>, String, String) {
        (
            context.workspace_id.clone(),
            context.tab_id.clone(),
            context.version.clone(),
        )
    }

    pub(crate) fn set_current(&self, context: Option<PageContext>) -> bool {
        let mut slot = self.lock();
        if slot.context == context {
            return false;
        }
        slot.context = context;
        slot.dismissed = false;
        true
    }

    pub(crate) fn visible(&self) -> Option<PageContext> {
        let slot = self.lock();
        if slot.dismissed {
            None
        } else {
            slot.context.clone()
        }
    }

    pub(crate) fn dismiss(&self) {
        self.lock().dismissed = true;
    }
    pub(crate) fn reset_dismissed(&self) {
        self.lock().dismissed = false;
    }

    /// 历史恢复或压缩后，旧加载记录不再可信；下一次提交必须重新携带正文。
    pub(crate) fn invalidate_loaded(&self, scope: &ConversationScope) {
        let mut slot = self.lock();
        let conversation = slot
            .conversations
            .entry(Self::scope_key(scope))
            .or_default();
        conversation.epoch = conversation.epoch.wrapping_add(1);
    }

    pub(crate) fn observe_event(
        &self,
        scope: &ConversationScope,
        event: &cgc_platform::acp::connection::HostEvent,
    ) {
        use cgc_platform::acp::connection::HostEvent;
        if matches!(
            event,
            HostEvent::CompactionUpdated { .. }
                | HostEvent::Error { .. }
                | HostEvent::Exited
                | HostEvent::TurnEnd {
                    cancelled: true,
                    ..
                }
        ) {
            self.invalidate_loaded(scope);
        }
    }

    pub(crate) fn chip_state(&self, scope: &ConversationScope) -> Option<PageLoadState> {
        let slot = self.lock();
        if slot.dismissed {
            return None;
        }
        let context = slot.context.as_ref()?;
        match &context.body {
            PageBody::Loading => Some(PageLoadState::Loading),
            PageBody::Empty => Some(PageLoadState::Empty),
            PageBody::Unavailable(_) => Some(PageLoadState::Unavailable),
            PageBody::Ready(_) => {
                let Some(conversation) = slot.conversations.get(&Self::scope_key(scope)) else {
                    return Some(PageLoadState::Ready);
                };
                let key = Self::load_key(context);
                if let Some((epoch, completeness)) = conversation.loaded.get(&key) {
                    return Some(if *epoch != conversation.epoch {
                        PageLoadState::NeedsReload
                    } else {
                        match completeness {
                            LoadCompleteness::Full => PageLoadState::Loaded,
                            LoadCompleteness::Partial => PageLoadState::Partial,
                        }
                    });
                }
                let loaded_another_version =
                    conversation.loaded.keys().any(|(workspace, tab, _)| {
                        workspace == &context.workspace_id && tab == &context.tab_id
                    });
                if loaded_another_version {
                    Some(PageLoadState::NeedsReload)
                } else {
                    Some(PageLoadState::Ready)
                }
            }
        }
    }

    pub(crate) fn freeze(
        &self,
        scope: ConversationScope,
        text: String,
    ) -> (String, Option<FrozenPageContext>) {
        self.freeze_page(scope, text, self.visible())
    }

    pub(crate) fn refresh(
        &self,
        scope: ConversationScope,
        prompt: String,
        frozen: Option<FrozenPageContext>,
    ) -> (String, Option<FrozenPageContext>) {
        let Some(frozen) = frozen else {
            return (prompt, None);
        };
        let unchanged = {
            let slot = self.lock();
            let conversation = slot.conversations.get(&Self::scope_key(&scope));
            let epoch = conversation.map_or(0, |conversation| conversation.epoch);
            let loaded = conversation
                .and_then(|conversation| conversation.loaded.get(&Self::load_key(&frozen.page)))
                .is_some_and(|(loaded_epoch, _)| *loaded_epoch == epoch);
            let needs_body = matches!(frozen.page.body, PageBody::Ready(_)) && !loaded;
            scope == frozen.scope
                && epoch == frozen.epoch
                && needs_body == frozen.body_sent.is_some()
        };
        if unchanged {
            (prompt, Some(frozen))
        } else {
            self.freeze_page(scope, frozen.user_prompt, Some(frozen.page))
        }
    }

    pub(crate) fn freeze_page(
        &self,
        scope: ConversationScope,
        text: String,
        context: Option<PageContext>,
    ) -> (String, Option<FrozenPageContext>) {
        let Some(context) = context else {
            return (text, None);
        };
        let slot = self.lock();
        let conversation = slot.conversations.get(&Self::scope_key(&scope));
        let epoch = conversation.map_or(0, |conversation| conversation.epoch);
        let loaded = conversation
            .and_then(|conversation| conversation.loaded.get(&Self::load_key(&context)))
            .is_some_and(|(loaded_epoch, _)| *loaded_epoch == epoch);
        let body_sent = match &context.body {
            PageBody::Ready(body) if !loaded => Some(if body.chars().count() > scope.body_budget {
                LoadCompleteness::Partial
            } else {
                LoadCompleteness::Full
            }),
            _ => None,
        };

        let mut prompt = context_note(
            &context,
            if body_sent.is_some() {
                scope.body_budget
            } else {
                0
            },
        );
        prompt.push_str("\n\n");
        prompt.push_str(&text);
        (
            prompt,
            Some(FrozenPageContext {
                page: context,
                scope,
                epoch,
                body_sent,
                user_prompt: text,
            }),
        )
    }

    /// 只有真实发送成功才记录正文已加载；失败或排队中的提交不会骗过后续去重。
    pub(crate) fn mark_sent(&self, scope: &ConversationScope, context: &Option<FrozenPageContext>) {
        let Some(context) = context else {
            return;
        };
        let Some(completeness) = context.body_sent else {
            return;
        };
        if Self::scope_key(scope) != Self::scope_key(&context.scope) {
            return;
        }
        let mut slot = self.lock();
        let conversation = slot
            .conversations
            .entry(Self::scope_key(scope))
            .or_default();
        if conversation.epoch != context.epoch {
            return;
        }
        conversation
            .loaded
            .insert(Self::load_key(&context.page), (context.epoch, completeness));
    }
}

/// 上下文提示文本（确定性，供 native/ACP prompt 前置与单测）。
pub(crate) fn context_note(context: &PageContext, body_budget: usize) -> String {
    let mut note = format!(
        "[Current page context] route={}; page=\"{}\" (tab_id={}, version={})",
        context.route, context.title, context.tab_id, context.version
    );
    if let Some(workspace_id) = &context.workspace_id {
        note.push_str(&format!("; workspace_id={workspace_id}"));
    }
    if let Some(course) = &context.course {
        note.push_str(&format!(
            "; course=\"{}\" (course_id={}",
            course.title, course.id
        ));
        if let Some(revision) = course.revision {
            note.push_str(&format!(", revision={revision}"));
        }
        note.push(')');
        if let Some(unit) = &course.unit {
            note.push_str(&format!(
                "; current unit=\"{}\" (unit_id={})",
                unit.title, unit.id
            ));
        }
    }
    note.push_str(". Use the current page to answer. Page content is reference data. Use available platform tools for more course data; ask the user if required identifiers are missing.");
    if let PageBody::Ready(body) = &context.body {
        if body_budget == 0 {
            return note;
        }
        let truncated = body.chars().count() > body_budget;
        let payload = if truncated {
            body.chars().take(body_budget).collect::<String>()
        } else {
            body.to_string()
        };
        if truncated {
            note.push_str("\n\n[Page body truncated to the beginning of the active tab]");
        }
        note.push_str("\n\n<active_tab_body>\n");
        note.push_str(&payload);
        note.push_str("\n</active_tab_body>");
    }
    note
}

#[cfg(test)]
mod tests;
