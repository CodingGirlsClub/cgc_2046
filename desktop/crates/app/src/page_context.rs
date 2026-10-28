//! RootView-owned page context. Explicit clones share one controller's context;
//! independent roots and demos never share a process-global slot.
//! Each submission freezes both the structured context and its prompt prefix.

use std::sync::{Arc, Mutex};

/// 当前页面上下文（只在课程学习页有值）。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PageContext {
    pub route: String,
    pub course_id: String,
    pub course_title: String,
    pub revision: Option<i64>,
    pub unit: Option<PageUnit>,
}

/// 当前单元（issue 卡）引用。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PageUnit {
    pub id: String,
    pub title: String,
}

#[derive(Default)]
struct Slot {
    context: Option<PageContext>,
    dismissed: bool,
}

#[derive(Clone, Default)]
pub(crate) struct PageContextState(Arc<Mutex<Slot>>);

impl PageContextState {
    fn lock(&self) -> std::sync::MutexGuard<'_, Slot> {
        self.0
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
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

    pub(crate) fn freeze(&self, text: String) -> (String, Option<PageContext>) {
        let context = self.visible();
        match context {
            Some(context) => {
                let mut prompt = context_note(&context);
                prompt.reserve(text.len() + 2);
                prompt.push_str("\n\n");
                prompt.push_str(&text);
                (prompt, Some(context))
            }
            None => (text, None),
        }
    }
}

/// 上下文提示文本（确定性，供 native/ACP prompt 前置与单测）。
pub(crate) fn context_note(context: &PageContext) -> String {
    let mut note = format!(
        "[当前学习上下文] route={}；课程：《{}》（course_id={}",
        context.route, context.course_title, context.course_id
    );
    if let Some(revision) = context.revision {
        note.push_str(&format!("，revision={revision}"));
    }
    note.push('）');
    if let Some(unit) = &context.unit {
        note.push_str(&format!(
            "；当前单元：《{}》（unit_id={}）",
            unit.title, unit.id
        ));
    }
    note.push_str("。回答时优先结合该课程与单元；需要更多课程资料时向用户说明。");
    note
}

#[cfg(test)]
mod tests {
    use super::*;

    fn course(id: &str) -> PageContext {
        PageContext {
            route: "courses.learning".into(),
            course_id: id.into(),
            course_title: "Rust".into(),
            revision: Some(3),
            unit: Some(PageUnit {
                id: "unit-A".into(),
                title: "Ownership".into(),
            }),
        }
    }

    #[test]
    fn queued_prompt_keeps_the_context_at_submission() {
        let state = PageContextState::default();
        state.set_current(Some(course("course-A")));
        let (queued, frozen) = state.freeze("explain ownership".into());
        state.set_current(Some(course("course-B")));

        assert!(queued.contains("course-A"));
        assert!(!queued.contains("course-B"));
        assert!(state.freeze("next".into()).0.contains("course-B"));
        assert_eq!(frozen.unwrap().course_id, "course-A");
    }

    #[test]
    fn independent_controllers_do_not_share_context_or_dismissal() {
        let first = PageContextState::default();
        let second = PageContextState::default();
        first.set_current(Some(course("course-A")));
        second.set_current(Some(course("course-B")));
        first.dismiss();
        assert_eq!(first.freeze("question".into()), ("question".into(), None));
        assert!(second.freeze("question".into()).0.contains("course-B"));

        let reopened_window = first.clone();
        reopened_window.reset_dismissed();
        assert!(
            first.freeze("question".into()).0.contains("course-A"),
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
        next.unit = None;
        next.revision = None;
        state.set_current(Some(next));

        let (prompt, snapshot) = state.freeze("next exercise".into());
        assert!(prompt.contains("course-B"));
        assert!(!prompt.contains("unit-A"));
        assert_eq!(snapshot.unwrap().unit, None);
        assert!(prompt.ends_with("next exercise"));
    }
}
