//! 全局页面上下文（Stage 3.5a）：任意页面共用同一个 Agent Panel / thread；
//! 课程页不再拥有专用会话或工作区，只把 course/revision/unit 作为上下文附加到
//! 发出 prompt（native 与 ACP 两轨共用同一段文本）。
//!
//! `RootView::refresh_page_context` 在每帧渲染前写入当前上下文；prompt 发送时
//! 读取并前置（用户气泡只显示原始输入）。上下文可被用户 dismiss，直到换页或新开会话。

use std::sync::{Mutex, OnceLock};

/// 当前页面上下文（只在课程学习页有值）。
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct PageContext {
    pub course_id: String,
    pub course_title: String,
    pub revision: Option<i64>,
    pub unit: Option<PageUnit>,
}

/// 当前单元（issue 卡）引用。
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct PageUnit {
    pub id: String,
    pub title: String,
}

#[derive(Default)]
struct Slot {
    context: Option<PageContext>,
    dismissed: bool,
}

fn slot() -> &'static Mutex<Slot> {
    static CURRENT: OnceLock<Mutex<Slot>> = OnceLock::new();
    CURRENT.get_or_init(|| Mutex::new(Slot::default()))
}

fn lock() -> std::sync::MutexGuard<'static, Slot> {
    slot()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// 写入当前页面上下文；上下文变化时清除 dismissed。返回是否发生变化。
pub(crate) fn set_current(context: Option<PageContext>) -> bool {
    let mut slot = lock();
    if slot.context == context {
        return false;
    }
    slot.context = context;
    slot.dismissed = false;
    true
}

pub(crate) fn current() -> Option<PageContext> {
    lock().context.clone()
}

/// 用户点击上下文 chip 的 ×：本次上下文不再附加，直到换页/新会话。
pub(crate) fn dismiss() {
    lock().dismissed = true;
}

pub(crate) fn reset_dismissed() {
    lock().dismissed = false;
}

pub(crate) fn is_dismissed() -> bool {
    lock().dismissed
}

/// 上下文提示文本（确定性，供 native/ACP prompt 前置与单测）。
pub(crate) fn context_note(context: &PageContext) -> String {
    let mut note = format!(
        "[当前学习上下文] 课程：《{}》（course_id={}",
        context.course_title, context.course_id
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

/// 若当前页面有上下文且未被 dismiss，返回要附加的文本；否则 None。
pub(crate) fn current_note() -> Option<String> {
    let slot = lock();
    if slot.dismissed {
        return None;
    }
    slot.context.as_ref().map(context_note)
}

/// 把上下文附加到 prompt（无上下文时原样返回）。
pub(crate) fn attach_to_prompt(text: &str) -> String {
    match current_note() {
        Some(note) => format!("{note}\n\n{text}"),
        None => text.to_string(),
    }
}

#[cfg(test)]
mod page_context_tests {
    use super::*;

    fn unit() -> PageUnit {
        PageUnit {
            id: "unit-1".to_string(),
            title: "第一单元".to_string(),
        }
    }

    fn course() -> PageContext {
        PageContext {
            course_id: "course-1".to_string(),
            course_title: "Rust 入门".to_string(),
            revision: Some(3),
            unit: Some(unit()),
        }
    }

    #[test]
    fn note_includes_course_revision_and_unit() {
        let note = context_note(&course());
        assert!(note.contains("课程：《Rust 入门》"));
        assert!(note.contains("course_id=course-1"));
        assert!(note.contains("revision=3"));
        assert!(note.contains("当前单元：《第一单元》"));
        assert!(note.contains("unit_id=unit-1"));
    }

    #[test]
    fn note_omits_absent_optional_parts() {
        let context = PageContext {
            course_id: "c".to_string(),
            course_title: "课程".to_string(),
            revision: None,
            unit: None,
        };
        let note = context_note(&context);
        assert!(!note.contains("revision="));
        assert!(!note.contains("当前单元"));
    }

    #[test]
    fn attach_to_prompt_respects_context_and_dismiss() {
        // 清空全局态后附加：无上下文 → 原文。
        reset_dismissed();
        assert!(set_current(None) || current().is_none());
        assert_eq!(attach_to_prompt("hi"), "hi");

        assert!(set_current(Some(course())));
        let attached = attach_to_prompt("hi");
        assert!(attached.starts_with("[当前学习上下文]"));
        assert!(attached.ends_with("hi"));

        dismiss();
        assert_eq!(attach_to_prompt("hi"), "hi");

        // 换页（上下文变化）会重置 dismiss。
        let other = PageContext {
            course_id: "course-2".to_string(),
            ..course()
        };
        assert!(set_current(Some(other)));
        assert!(!is_dismissed());
        assert!(attach_to_prompt("hi").starts_with("[当前学习上下文]"));
        let _ = set_current(None);
    }
}
