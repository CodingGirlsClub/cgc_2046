//! Notes 的写入动作：选区 → 服务端；失败保留浮层/编辑内容，不做本地写入。

use super::*;
use cgc_courses::notes::{CourseNote, NewCourseNote, NotesError};

impl RootView {
    pub(in crate::root_view) fn add_note_from_selection(
        &mut self,
        text: String,
        source_material_id: Option<String>,
        target: crate::agent_call::LearningTarget,
        cx: &mut Context<Self>,
    ) {
        let Some((course_id, issue_id)) = note_target_ids(&target) else {
            self.notes_notice =
                Some(translate(self.language, Key::CoursesLearningNotesFailed).into());
            cx.notify();
            return;
        };

        let api = self.notes.api_handle();
        let token = self.session_token();
        let epoch = self.workspace_bound_epoch();
        let session_epoch = self.session_epoch;
        let language = self.language;
        let requested_course = course_id.clone();
        let input = NewCourseNote {
            course_id,
            issue_id,
            source_material_id,
            text,
        };
        let task = cx
            .background_executor()
            .spawn(async move { api.create_note(token.as_deref(), input) });
        cx.spawn(async move |this, cx| {
            let result = task.await;
            let _ = this.update(cx, |this, cx| {
                let stale_epoch =
                    epoch.is_some_and(|epoch| !this.workspaces.is_current_epoch(epoch));
                let stale_course = !this.course_is_current(&requested_course);
                if stale_epoch || this.session_epoch != session_epoch || stale_course {
                    return;
                }

                match result {
                    Ok(note) => {
                        this.notes.upsert(note);
                        this.notes_notice =
                            Some(translate(language, Key::CoursesLearningNotesAdded).into());
                        this.selection_popover = None;
                    }
                    Err(NotesError::Duplicate) => {
                        this.notes_notice =
                            Some(translate(language, Key::CoursesLearningNotesDuplicate).into());
                        this.selection_popover = None;
                    }
                    Err(NotesError::Unauthorized) => this.force_sign_out(cx),
                    Err(_) => {
                        this.notes_notice =
                            Some(translate(language, Key::CoursesLearningNotesSaveFailed).into());
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    pub(in crate::root_view) fn begin_note_edit(
        &mut self,
        note: &CourseNote,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let input = cx.new(|cx| {
            gpui_kit::component::input::InputState::new(window, cx).default_value(note.text.clone())
        });
        self.note_edit = Some(super::state::NoteEditState {
            note_id: note.id.clone(),
            input,
        });
        self.notes_notice = None;
        cx.notify();
    }

    pub(in crate::root_view) fn cancel_note_edit(&mut self, cx: &mut Context<Self>) {
        self.note_edit = None;
        cx.notify();
    }

    pub(in crate::root_view) fn save_note_edit(&mut self, cx: &mut Context<Self>) {
        let Some(edit) = self.note_edit.clone() else {
            return;
        };
        let note_id = edit.note_id.clone();
        let text = edit.input.read(cx).value().to_string();
        if text.trim().is_empty() {
            self.notes_notice =
                Some(translate(self.language, Key::CoursesLearningNotesSaveFailed).into());
            cx.notify();
            return;
        }

        let api = self.notes.api_handle();
        let token = self.session_token();
        let epoch = self.workspace_bound_epoch();
        let session_epoch = self.session_epoch;
        let language = self.language;
        let requested_course = self.notes.course_id().map(str::to_string);
        let result_note_id = note_id.clone();
        let task = cx
            .background_executor()
            .spawn(async move { api.update_note(token.as_deref(), &note_id, text.trim()) });
        cx.spawn(async move |this, cx| {
            let result = task.await;
            let _ = this.update(cx, |this, cx| {
                let stale_epoch =
                    epoch.is_some_and(|epoch| !this.workspaces.is_current_epoch(epoch));
                let stale_course = this.notes.course_id() != requested_course.as_deref();
                if stale_epoch || this.session_epoch != session_epoch || stale_course {
                    return;
                }
                match result {
                    Ok(note) => {
                        this.notes.upsert(note);
                        if this
                            .note_edit
                            .as_ref()
                            .is_some_and(|edit| edit.note_id == result_note_id)
                        {
                            this.note_edit = None;
                        }
                        this.notes_notice =
                            Some(translate(language, Key::CoursesLearningNotesSaved).into());
                    }
                    Err(NotesError::Unauthorized) => this.force_sign_out(cx),
                    Err(NotesError::Duplicate) => {
                        this.notes_notice =
                            Some(translate(language, Key::CoursesLearningNotesDuplicate).into());
                    }
                    Err(_) => {
                        this.notes_notice =
                            Some(translate(language, Key::CoursesLearningNotesSaveFailed).into());
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    pub(in crate::root_view) fn request_delete_note(
        &mut self,
        note_id: &str,
        cx: &mut Context<Self>,
    ) {
        self.note_pending_delete = Some(note_id.to_string());
        cx.notify();
    }

    pub(in crate::root_view) fn cancel_delete_note(&mut self, cx: &mut Context<Self>) {
        self.note_pending_delete = None;
        cx.notify();
    }

    pub(in crate::root_view) fn confirm_delete_note(
        &mut self,
        note_id: &str,
        cx: &mut Context<Self>,
    ) {
        let note_id = note_id.to_string();
        let result_note_id = note_id.clone();
        let api = self.notes.api_handle();
        let token = self.session_token();
        let epoch = self.workspace_bound_epoch();
        let session_epoch = self.session_epoch;
        let language = self.language;
        let requested_course = self.notes.course_id().map(str::to_string);
        let task = cx
            .background_executor()
            .spawn(async move { api.delete_note(token.as_deref(), &note_id) });
        cx.spawn(async move |this, cx| {
            let result = task.await;
            let _ = this.update(cx, |this, cx| {
                let stale_epoch =
                    epoch.is_some_and(|epoch| !this.workspaces.is_current_epoch(epoch));
                let stale_course = this.notes.course_id() != requested_course.as_deref();
                if stale_epoch || this.session_epoch != session_epoch || stale_course {
                    return;
                }
                match result {
                    Ok(()) => {
                        this.notes.remove(&result_note_id);
                        if this.note_pending_delete.as_deref() == Some(result_note_id.as_str()) {
                            this.note_pending_delete = None;
                        }
                        this.notes_notice =
                            Some(translate(language, Key::CoursesLearningNotesDeleted).into());
                    }
                    Err(NotesError::Unauthorized) => this.force_sign_out(cx),
                    Err(_) => {
                        this.notes_notice =
                            Some(translate(language, Key::CoursesLearningNotesSaveFailed).into());
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    pub(in crate::root_view) fn send_note_to_agent(
        &mut self,
        note: &CourseNote,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let prompt = format!("请结合当前课程上下文，帮我回顾这条笔记：\n\n{}", note.text);
        self.agent_panel_open = true;
        if self.native_chat_mode && Self::native_agent_enabled() {
            if let Some(view) = self.native_agent_view.clone() {
                view.update(cx, |view, cx| {
                    view.compose_note(prompt, window, cx);
                });
                cx.notify();
                return;
            }
        }
        {
            self.chat.pending_agent_call = None;
            self.chat.composer_context.reset();
            self.chat.input = prompt.clone();
            if let Some(input) = self.chat_input.clone() {
                input.update(cx, |input, cx| {
                    input.set_value(prompt, window, cx);
                    input.focus(window, cx);
                });
            }
        }
        cx.notify();
    }

    /// 投影就绪后检查每个 Issue 的必修完成度；只对完成 Issue 触发服务端幂等
    /// `ensureCourseRetro`。客户端不生成 Retro 文本，也不信任本地判断做写入。
    pub(in crate::root_view) fn ensure_retro_for_course(&mut self, cx: &mut Context<Self>) {
        let Some(projection) = self.projection.projection().cloned() else {
            return;
        };
        let Some(content) = self.content.content().cloned() else {
            return;
        };
        let course_id = projection.course_id.clone();
        let revision = projection.revision_number;
        let mut issue_ids = Vec::new();

        for issue in &content.document.issues {
            let Some(issue_id) = issue.id.as_deref() else {
                continue;
            };
            let required = issue
                .objectives
                .iter()
                .filter(|objective| objective.required)
                .collect::<Vec<_>>();
            if required.is_empty() {
                continue;
            }
            let complete = required.iter().all(|objective| {
                objective.id.as_deref().is_some_and(|id| {
                    projection
                        .objectives
                        .iter()
                        .find(|state| state.id == id)
                        .is_some_and(|state| state.mastery == "mastered")
                })
            });
            if !complete {
                continue;
            }
            let key = format!("{course_id}:{}:{issue_id}", revision.unwrap_or(-1));
            if self.retro_checked.insert(key) {
                issue_ids.push(issue_id.to_string());
            }
        }

        if issue_ids.is_empty() {
            return;
        }

        let api = self.notes.api_handle();
        let token = self.session_token();
        let epoch = self.workspace_bound_epoch();
        let session_epoch = self.session_epoch;
        let requested_course = course_id.clone();
        let task = cx.background_executor().spawn(async move {
            issue_ids
                .into_iter()
                .filter_map(|issue_id| {
                    api.ensure_retro(token.as_deref(), &course_id, &issue_id)
                        .ok()
                        .flatten()
                })
                .collect::<Vec<_>>()
        });
        cx.spawn(async move |this, cx| {
            let notes = task.await;
            let _ = this.update(cx, |this, cx| {
                let stale_epoch =
                    epoch.is_some_and(|epoch| !this.workspaces.is_current_epoch(epoch));
                let stale_course = !this.course_is_current(&requested_course);
                if stale_epoch || this.session_epoch != session_epoch || stale_course {
                    return;
                }
                for note in notes {
                    this.notes.upsert(note);
                }
                cx.notify();
            });
        })
        .detach();
    }

    pub(in crate::root_view) fn open_notes_panel(&mut self, cx: &mut Context<Self>) {
        self.right_panel = RightPanel::Notes;
        self.right_panel_open = true;
        self.panel_memory.panel = RightPanel::Notes;
        self.panel_memory.open = true;
        self.persist_current_workspace_state();
        cx.notify();
    }

    fn current_course_id(&self) -> Option<String> {
        self.current
            .as_ref()
            .and_then(|route| route.params.get("id"))
            .cloned()
    }

    fn course_is_current(&self, course_id: &str) -> bool {
        match self.current_course_id() {
            Some(current) => current == course_id,
            None => self.notes.course_id() == Some(course_id),
        }
    }

    pub(in crate::root_view) fn retry_notes(&mut self, cx: &mut Context<Self>) {
        if let Some(course_id) = self
            .current
            .as_ref()
            .and_then(|route| route.params.get("id"))
            .cloned()
        {
            self.start_notes_load(cx, course_id);
        }
    }
}

fn note_target_ids(target: &crate::agent_call::LearningTarget) -> Option<(String, String)> {
    match target {
        crate::agent_call::LearningTarget::Issue {
            course_id,
            issue_id,
            ..
        }
        | crate::agent_call::LearningTarget::Objective {
            course_id,
            issue_id,
            ..
        }
        | crate::agent_call::LearningTarget::Material {
            course_id,
            issue_id,
            ..
        } => Some((course_id.clone(), issue_id.clone())),
    }
}
