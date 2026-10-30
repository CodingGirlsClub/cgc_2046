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
        Some(PageLoadState::Ready) => "待加载",
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

#[derive(Default)]
struct Slot {
    context: Option<PageContext>,
    dismissed: bool,
    invalidated: bool,
    loaded: HashMap<(String, String, String, String), LoadCompleteness>,
}

#[derive(Clone, Default)]
pub(crate) struct PageContextState(Arc<Mutex<Slot>>);

impl PageContextState {
    fn lock(&self) -> std::sync::MutexGuard<'_, Slot> {
        self.0
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn load_key(
        scope: &ConversationScope,
        context: &PageContext,
    ) -> (String, String, String, String) {
        (
            scope.thread_id.clone(),
            scope.agent_id.clone(),
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
    pub(crate) fn invalidate_loaded(&self) {
        let mut slot = self.lock();
        slot.invalidated = !slot.loaded.is_empty();
        slot.loaded.clear();
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
                if slot.invalidated {
                    return Some(PageLoadState::NeedsReload);
                }
                let key = Self::load_key(scope, context);
                if let Some(completeness) = slot.loaded.get(&key) {
                    return Some(match completeness {
                        LoadCompleteness::Full => PageLoadState::Loaded,
                        LoadCompleteness::Partial => PageLoadState::Partial,
                    });
                }
                let loaded_another_version = slot.loaded.keys().any(|(thread, agent, tab, _)| {
                    thread == &scope.thread_id && agent == &scope.agent_id && tab == &context.tab_id
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
    ) -> (String, Option<PageContext>) {
        let slot = self.lock();
        if slot.dismissed {
            return (text, None);
        }
        let Some(context) = slot.context.clone() else {
            return (text, None);
        };
        let key = Self::load_key(&scope, &context);
        if !slot.invalidated && slot.loaded.contains_key(&key) {
            return (text, Some(context));
        }
        match context.body {
            PageBody::Ready(_) => {
                let mut prompt = context_note(&context, scope.body_budget);
                prompt.reserve(text.len() + 2);
                prompt.push_str("\n\n");
                prompt.push_str(&text);
                (prompt, Some(context))
            }
            // 课程正文尚未投影前保留原有课程标识上下文；不得把空正文记为已加载。
            _ if context.course.is_some() => {
                let mut prompt = context_note(&context, scope.body_budget);
                prompt.reserve(text.len() + 2);
                prompt.push_str("\n\n");
                prompt.push_str(&text);
                (prompt, Some(context))
            }
            _ => (text, Some(context)),
        }
    }

    /// 只有真实发送成功才记录正文已加载；失败或排队中的提交不会骗过后续去重。
    pub(crate) fn mark_sent(&self, scope: &ConversationScope, context: &Option<PageContext>) {
        let Some(context) = context else {
            return;
        };
        if !matches!(context.body, PageBody::Ready(_)) {
            return;
        }
        let completeness = match &context.body {
            PageBody::Ready(body) if body.chars().count() > scope.body_budget => {
                LoadCompleteness::Partial
            }
            _ => LoadCompleteness::Full,
        };
        let mut slot = self.lock();
        slot.loaded
            .insert(Self::load_key(scope, context), completeness);
        slot.invalidated = false;
    }
}

/// 上下文提示文本（确定性，供 native/ACP prompt 前置与单测）。
pub(crate) fn context_note(context: &PageContext, body_budget: usize) -> String {
    let mut note = format!(
        "[当前页面上下文] route={}；页面：《{}》（tab_id={}，version={}）",
        context.route, context.title, context.tab_id, context.version
    );
    if let Some(course) = &context.course {
        note.push_str(&format!(
            "；课程：《{}》（course_id={}",
            course.title, course.id
        ));
        if let Some(revision) = course.revision {
            note.push_str(&format!("，revision={revision}"));
        }
        note.push('）');
        if let Some(unit) = &course.unit {
            note.push_str(&format!(
                "；当前单元：《{}》（unit_id={}）",
                unit.title, unit.id
            ));
        }
    }
    note.push_str("。回答时优先结合当前页面；需要更多资料时向用户说明。");
    if let PageBody::Ready(body) = &context.body {
        let truncated = body.chars().count() > body_budget;
        let payload = if truncated {
            body.chars().take(body_budget).collect::<String>()
        } else {
            body.to_string()
        };
        if truncated {
            note.push_str("\n\n[正文已截断，仅包含当前 tab 的前部分]");
        }
        note.push_str("\n\n<active_tab_body>\n");
        note.push_str(&payload);
        note.push_str("\n</active_tab_body>");
    }
    note
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scope() -> ConversationScope {
        ConversationScope::new("thread-1", "native")
    }

    fn course(id: &str) -> PageContext {
        PageContext {
            tab_id: format!("issue:{id}:unit-A"),
            route: format!("/courses/{id}/learn"),
            title: "Rust".into(),
            version: "3".into(),
            body: PageBody::Loading,
            course: Some(CourseContext {
                id: id.into(),
                title: "Rust".into(),
                revision: Some(3),
                unit: Some(PageUnit {
                    id: "unit-A".into(),
                    title: "Ownership".into(),
                }),
            }),
        }
    }

    #[test]
    fn queued_prompt_keeps_the_context_at_submission() {
        let state = PageContextState::default();
        state.set_current(Some(course("course-A")));
        let (queued, frozen) = state.freeze(scope(), "explain ownership".into());
        state.set_current(Some(course("course-B")));

        assert!(queued.contains("course-A"));
        assert!(!queued.contains("course-B"));
        assert!(state.freeze(scope(), "next".into()).0.contains("course-B"));
        assert_eq!(frozen.unwrap().course.unwrap().id, "course-A");
    }

    #[test]
    fn independent_controllers_do_not_share_context_or_dismissal() {
        let first = PageContextState::default();
        let second = PageContextState::default();
        first.set_current(Some(course("course-A")));
        second.set_current(Some(course("course-B")));
        first.dismiss();
        assert_eq!(
            first.freeze(scope(), "question".into()),
            ("question".into(), None)
        );
        assert!(second
            .freeze(scope(), "question".into())
            .0
            .contains("course-B"));

        let reopened_window = first.clone();
        reopened_window.reset_dismissed();
        assert!(
            first
                .freeze(scope(), "question".into())
                .0
                .contains("course-A"),
            "windows explicitly sharing the same root retain its context"
        );
        second.dismiss();
        assert!(first.visible().is_some());
    }

    #[test]
    fn changing_page_removes_stale_unit_context_and_resets_dismissal() {
        let state = PageContextState::default();
        state.set_current(Some(course("course-A")));
        state.dismiss();
        let mut next = course("course-B");
        next.tab_id = "page:/courses/course-B/learn".into();
        next.version = "unversioned".into();
        next.course.as_mut().unwrap().unit = None;
        next.course.as_mut().unwrap().revision = None;
        state.set_current(Some(next));

        let (prompt, snapshot) = state.freeze(scope(), "next exercise".into());
        assert!(prompt.contains("course-B"));
        assert!(!prompt.contains("unit-A"));
        assert_eq!(snapshot.unwrap().course.unwrap().unit, None);
        assert!(prompt.ends_with("next exercise"));
    }

    #[test]
    fn same_tab_version_loads_body_only_once_per_thread_and_agent() {
        let state = PageContextState::default();
        state.set_current(Some(PageContext {
            tab_id: "tab-event-1".into(),
            route: "/events/event-1".into(),
            title: "Reading Rust".into(),
            version: "v1".into(),
            body: PageBody::Ready("complete event body".into()),
            course: None,
        }));
        let scope = ConversationScope::new("thread-1", "acp");

        let (first, snapshot) = state.freeze(scope.clone(), "first question".into());
        assert!(first.contains("complete event body"));
        state.mark_sent(&scope, &snapshot);

        let (second, _) = state.freeze(scope, "follow up".into());
        assert_eq!(second, "follow up");
        assert!(!second.contains("complete event body"));
    }

    #[test]
    fn chip_distinguishes_ready_loaded_and_needs_reload() {
        let state = PageContextState::default();
        let mut context = PageContext {
            tab_id: "tab-event-1".into(),
            route: "/events/event-1".into(),
            title: "Reading Rust".into(),
            version: "v1".into(),
            body: PageBody::Ready("version one".into()),
            course: None,
        };
        let scope = ConversationScope::new("thread-1", "native");
        state.set_current(Some(context.clone()));
        assert_eq!(state.chip_state(&scope), Some(PageLoadState::Ready));

        let (_, snapshot) = state.freeze(scope.clone(), "first".into());
        state.mark_sent(&scope, &snapshot);
        assert_eq!(state.chip_state(&scope), Some(PageLoadState::Loaded));

        context.version = "v2".into();
        context.body = PageBody::Ready("version two".into());
        state.set_current(Some(context));
        assert_eq!(state.chip_state(&scope), Some(PageLoadState::NeedsReload));
    }

    #[test]
    fn invalidating_before_any_load_keeps_the_chip_ready() {
        let state = PageContextState::default();
        state.set_current(Some(PageContext {
            tab_id: "tab-event-1".into(),
            route: "/events/event-1".into(),
            title: "Reading Rust".into(),
            version: "v1".into(),
            body: PageBody::Ready("event body".into()),
            course: None,
        }));
        let scope = ConversationScope::new("thread-1", "native");

        state.invalidate_loaded();
        assert_eq!(state.chip_state(&scope), Some(PageLoadState::Ready));
    }

    #[test]
    fn invalidated_history_requires_one_reload_then_returns_to_loaded() {
        let state = PageContextState::default();
        state.set_current(Some(PageContext {
            tab_id: "tab-event-1".into(),
            route: "/events/event-1".into(),
            title: "Reading Rust".into(),
            version: "v1".into(),
            body: PageBody::Ready("event body".into()),
            course: None,
        }));
        let scope = ConversationScope::new("thread-1", "native");

        let (_, snapshot) = state.freeze(scope.clone(), "first".into());
        state.mark_sent(&scope, &snapshot);
        assert_eq!(state.chip_state(&scope), Some(PageLoadState::Loaded));

        state.invalidate_loaded();
        assert_eq!(state.chip_state(&scope), Some(PageLoadState::NeedsReload));

        let (reloaded, snapshot) = state.freeze(scope.clone(), "again".into());
        assert!(reloaded.contains("event body"));
        state.mark_sent(&scope, &snapshot);
        assert_eq!(state.chip_state(&scope), Some(PageLoadState::Loaded));
    }

    #[test]
    fn over_budget_body_is_truncated_and_marked_partial() {
        let full_body = "abcdefghijklmnopqrstuvwxyz0123456789".repeat(4);
        let state = PageContextState::default();
        state.set_current(Some(PageContext {
            tab_id: "tab-long".into(),
            route: "/events/long".into(),
            title: "Long page".into(),
            version: "v1".into(),
            body: PageBody::Ready(full_body.clone().into()),
            course: None,
        }));
        let scope = ConversationScope::with_body_budget("thread-1", "acp", 24);

        let (prompt, snapshot) = state.freeze(scope.clone(), "summarize".into());
        assert!(prompt.contains("正文已截断"));
        assert!(!prompt.contains(&full_body));
        state.mark_sent(&scope, &snapshot);
        assert_eq!(state.chip_state(&scope), Some(PageLoadState::Partial));

        let (follow_up, _) = state.freeze(scope, "follow up".into());
        assert_eq!(follow_up, "follow up");
    }
}
