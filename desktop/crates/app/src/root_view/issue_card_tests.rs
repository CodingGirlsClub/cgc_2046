//! issue 卡信息层级：章节 kicker、单元类型、objective 掌握态/验收/rubric。

use super::RootView;
use crate::i18n::Language;
use crate::root_view::screens::workspace::card::required_mastery_counts;
use crate::root_view::state::MediaState;
use crate::theme::ThemePreference;
use cgc_courses::catalog::{CourseCatalogService, CoursesApi, FakeCoursesApi};
use cgc_courses::content::{
    AgentActionSpec, AgentIntent, CourseChecklistItem, CourseObjective, MaterialKind, TypedMaterial,
};
use cgc_courses::notes::{
    CourseNote, CourseNotesService, FakeNotesApi, NewCourseNote, NoteKind, NotesApi, NotesError,
};
use cgc_courses::projection::{LearningProjection, LearningProjectionService, ObjectiveState};
use cgc_platform::session::{FakeAuthApi, MemoryStore, SessionService};
use gpui_kit::test::TestWindowExt;
use gpui_kit::{
    div, px, size, AppContext, Bounds, Context, Entity, IntoElement, ParentElement, Render, Styled,
    TestAppContext, Window, WindowBounds, WindowOptions,
};
use std::sync::Arc;

struct IssueCardProbe {
    root: Entity<RootView>,
}

impl Render for IssueCardProbe {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let area = self.root.update(cx, |root, cx| {
            let palette = crate::theme::palette(gpui_kit::component::ThemeMode::Light);
            let mut context = crate::root_view::screens::ScreenContext::new(&mut root.state);
            crate::root_view::screens::render_issue_card(
                &mut context,
                "crs-000",
                "issue-1",
                Language::Zh,
                &palette,
                cx,
            )
        });
        div().size(px(760.0)).flex().flex_col().child(area)
    }
}

fn issue_card_window(cx: &mut TestAppContext) -> (gpui_kit::AnyWindowHandle, Entity<RootView>) {
    cx.update(gpui_kit::init);
    cx.update(|cx| {
        let (handle, probe) = gpui_kit::open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(Bounds::centered(
                    None,
                    size(px(960.), px(1600.)),
                    cx,
                ))),
                ..Default::default()
            },
            cx,
            |_, cx| {
                let root = cx.new(|_| {
                    RootView::with_session_from(
                        crate::registration::build_registry().expect("registry"),
                        Language::Zh,
                        ThemePreference::Light,
                        SessionService::new(
                            Box::new(FakeAuthApi::demo()),
                            Box::new(MemoryStore::default()),
                        ),
                        "/w/2046/courses",
                    )
                });
                cx.new(|_| IssueCardProbe { root: root.clone() })
            },
        )
        .expect("issue card window");
        let root = probe.read(cx).root.clone();
        (handle, root)
    })
}

const IMAGE_URL: &str = "https://cdn.example.com/a.png";

fn card_content() -> cgc_courses::content::CourseContent {
    let api = FakeCoursesApi::with_seed(5);
    let mut content = api
        .get_course_content(None, "crs-000")
        .expect("published course content");
    let issue = content
        .document
        .issues
        .first_mut()
        .expect("fake content has one issue");
    issue.chapter_id = Some("ch-1".into());
    issue.kind = Some("thoughtwork".into());
    issue.goal = Some("理解物理学的研究对象与学科定位".into());
    issue.as_a = Some("刚接触物理的八年级学员".into());
    issue.given = vec!["已读完第一章".into()];
    issue.checklist = vec![CourseChecklistItem {
        id: Some("check-1".into()),
        text: "只给 agent 的清单".into(),
    }];
    issue.objectives = vec![CourseObjective {
        id: Some("obj-1".into()),
        title: Some("理解物理学的对象".into()),
        required: true,
        prereq_ids: Vec::new(),
        activity: Some("阅读教材".into()),
        assessment: Some("回答诊断问题".into()),
        rubric: vec![CourseChecklistItem {
            id: Some("rubric-1".into()),
            text: "优秀：准确说出".into(),
        }],
        materials: Vec::new(),
        agent_actions: Vec::new(),
    }];
    issue.story_materials.push(TypedMaterial {
        id: Some("mat-video".into()),
        kind: MaterialKind::Video,
        title: Some("讲解视频".into()),
        body: None,
        url: None,
        alt_text: None,
        caption: None,
        provider: Some("bilibili".into()),
        external_id: Some("BV1xx411c7mD".into()),
    });
    issue.story_materials.push(TypedMaterial {
        id: Some("mat-image".into()),
        kind: MaterialKind::Image,
        title: None,
        body: None,
        url: Some(IMAGE_URL.into()),
        alt_text: Some("插图".into()),
        caption: Some("图 1".into()),
        provider: None,
        external_id: None,
    });
    issue.story_materials.push(TypedMaterial {
        id: Some("mat-text".into()),
        kind: MaterialKind::Text,
        title: Some("一句话".into()),
        body: Some("物理学研究物质及其运动规律。".into()),
        url: None,
        alt_text: None,
        caption: None,
        provider: None,
        external_id: None,
    });
    content
}

fn projection() -> LearningProjection {
    LearningProjection {
        course_id: "crs-000".into(),
        title: "八年级物理".into(),
        revision_number: Some(1),
        stale_revision: false,
        run: None,
        next_action: None,
        progress: None,
        objectives: vec![ObjectiveState {
            id: "obj-1".into(),
            title: "理解物理学的对象".into(),
            required: true,
            mastery: "mastered".into(),
            locked: false,
            attempt_count: 1,
            missing_prereq_ids: Vec::new(),
        }],
        review_queue: Vec::new(),
    }
}

#[gpui_kit::test]
fn issue_card_renders_chapter_kind_assessment_and_rubric(cx: &mut TestAppContext) {
    let (handle, root) = issue_card_window(cx);
    root.update(cx, |root, _| {
        root.courses = CourseCatalogService::new(Arc::new(FakeCoursesApi::with_seed(5)));
        root.content.adopt(card_content());
        // 避免测试触发真实网络下载；图片走失败态分支。
        root.media_cache
            .insert(IMAGE_URL.into(), MediaState::Failed);
        root.projection = LearningProjectionService::new(Arc::new(FakeCoursesApi::with_seed(5)));
        root.projection.adopt(projection());
    });
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        assert!(root.read(cx).content.content().is_some(), "content adopted");
        assert!(
            window.try_find("issue-card").is_some(),
            "card root rendered"
        );
        assert!(window.try_find("issue-card-kicker").is_some());
        assert!(window.try_find("issue-card-kind").is_some());
        assert!(window.try_find("issue-card-user-story").is_some());
        assert!(window.try_find("issue-card-story-as").is_some());
        assert!(window.try_find("issue-card-story-given").is_some());
        assert!(window.try_find("issue-card-story-goal").is_some());
        assert!(window.try_find("issue-card-objective-obj-1").is_some());
        assert!(window.try_find("issue-card-assessment-obj-1").is_some());
        assert!(window.try_find("issue-card-rubric-obj-1").is_some());
        assert!(window.try_find("issue-card-mastery-obj-1").is_some());
        assert!(window.try_find("issue-materials").is_some());
        for index in 0..5 {
            assert!(
                window
                    .try_find(format!("issue-material-issue-1-{index}"))
                    .is_some(),
                "material row {index}"
            );
        }
        assert!(window.try_find("material-expand-issue-1-0").is_some());
        assert!(window.try_find("material-body-issue-1-4").is_some());
        assert!(window.try_find("material-open-issue-1-1").is_some());
        assert!(window.try_find("material-open-issue-1-2").is_some());
        assert!(window.try_find("material-open-issue-1-3").is_some());
        assert_eq!(
            window.find("material-expand-issue-1-0").role(),
            Some(gpui_kit::Role::Button)
        );
        for id in [
            "material-open-issue-1-1",
            "material-open-issue-1-2",
            "material-open-issue-1-3",
        ] {
            assert_eq!(
                window.find(id).role(),
                Some(gpui_kit::Role::Button),
                "{id} should expose Button role"
            );
        }
        window.click("material-expand-issue-1-0", cx);
        assert!(root
            .read(cx)
            .expanded_material
            .values()
            .any(|key| key.ends_with(":mat-md")));
        window.click("material-done-issue-1-0", cx);
        assert!(root
            .read(cx)
            .completed_materials
            .iter()
            .any(|key| key.ends_with(":mat-md")));
    })
    .unwrap();
}

#[gpui_kit::test]
fn issue_card_renders_notes_with_source_material(cx: &mut TestAppContext) {
    let (handle, root) = issue_card_window(cx);
    root.update(cx, |root, _| {
        root.courses = CourseCatalogService::new(Arc::new(FakeCoursesApi::with_seed(5)));
        root.content.adopt(card_content());
        root.notes = CourseNotesService::new(Arc::new(FakeNotesApi::default()));
        root.notes.begin_load("crs-000");
        root.notes.adopt(vec![CourseNote {
            id: "n1".into(),
            course_id: "crs-000".into(),
            issue_id: "issue-1".into(),
            source_material_id: Some("mat-text".into()),
            kind: NoteKind::Note,
            text: "选中材料后记下的重点".into(),
            created_at: "2026-11-11T00:00:00Z".into(),
            updated_at: None,
        }]);
    });
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        assert!(window.try_find("issue-notes").is_some());
        assert!(window.try_find("issue-note-n1").is_some());
        assert!(window.try_find("issue-notes-empty").is_none());
    })
    .unwrap();
}

#[gpui_kit::test]
fn selection_add_note_writes_through_notes_api(cx: &mut TestAppContext) {
    let (handle, root) = issue_card_window(cx);
    root.update(cx, |root, _| {
        root.courses = CourseCatalogService::new(Arc::new(FakeCoursesApi::with_seed(5)));
        root.content.adopt(card_content());
        root.notes = CourseNotesService::new(Arc::new(FakeNotesApi::default()));
        root.notes.begin_load("crs-000");
    });

    root.update(cx, |root, cx| {
        root.add_note_from_selection(
            "材料重点".into(),
            Some("mat-text".into()),
            crate::agent_call::LearningTarget::Material {
                course_id: "crs-000".into(),
                revision: Some(1),
                issue_id: "issue-1".into(),
                objective_id: None,
                material_id: "mat-text".into(),
            },
            cx,
        );
    });
    cx.run_until_parked();

    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        let notes = root.read(cx).notes.notes_for_issue("issue-1");
        assert_eq!(notes.len(), 1);
        assert_eq!(notes[0].text, "材料重点");
        assert_eq!(notes[0].source_material_id.as_deref(), Some("mat-text"));
        assert!(
            window.try_find("issue-notes").is_some(),
            "notes section renders"
        );
        assert!(
            window.try_find("issue-note-note-1").is_some(),
            "note row renders: {:?}",
            notes.iter().map(|note| note.id.clone()).collect::<Vec<_>>()
        );
    })
    .unwrap();
}

#[gpui_kit::test]
fn issue_note_crud_uses_inline_edit_and_confirm_delete(cx: &mut TestAppContext) {
    let (handle, root) = issue_card_window(cx);
    let note = CourseNote {
        id: "n1".into(),
        course_id: "crs-000".into(),
        issue_id: "issue-1".into(),
        source_material_id: Some("mat-text".into()),
        kind: NoteKind::Note,
        text: "before".into(),
        created_at: "2026-11-11T00:00:00Z".into(),
        updated_at: None,
    };
    root.update(cx, move |root, _| {
        root.courses = CourseCatalogService::new(Arc::new(FakeCoursesApi::with_seed(5)));
        root.content.adopt(card_content());
        root.notes =
            CourseNotesService::new(Arc::new(FakeNotesApi::with_notes(vec![note.clone()])));
        root.notes.begin_load("crs-000");
        root.notes.adopt(vec![note.clone()]);
    });

    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        window.click("note-edit-n1", cx);
        assert!(root.read(cx).note_edit.is_some());

        let input = root
            .read(cx)
            .note_edit
            .as_ref()
            .expect("edit state")
            .input
            .clone();
        input.update(cx, |state, cx| state.set_value("after", window, cx));
        assert_eq!(input.read(cx).value().to_string(), "after");
        window.render_frame(cx);
        assert!(
            root.read(cx).note_edit.is_some(),
            "edit state survives render"
        );
        window.click("note-save-n1", cx);
    })
    .unwrap();
    cx.run_until_parked();

    cx.update_window(handle, |_, window, cx| {
        assert_eq!(
            root.read(cx).notes.notes_for_issue("issue-1")[0].text,
            "after",
            "notice={:?}",
            root.read(cx).notes_notice
        );
        window.render_frame(cx);
        window.click("note-delete-n1", cx);
        assert!(root.read(cx).note_pending_delete.as_deref() == Some("n1"));
        window.render_frame(cx);
        window.click("note-confirm-n1", cx);
    })
    .unwrap();
    cx.run_until_parked();
    cx.update_window(handle, |_, _, cx| {
        assert!(root.read(cx).notes.notes_for_issue("issue-1").is_empty());
    })
    .unwrap();
}

#[gpui_kit::test]
fn completed_issue_triggers_retro_once(cx: &mut TestAppContext) {
    let (_handle, root) = issue_card_window(cx);
    root.update(cx, |root, _| {
        root.courses = CourseCatalogService::new(Arc::new(FakeCoursesApi::with_seed(5)));
        root.content.adopt(card_content());
        root.projection = LearningProjectionService::new(Arc::new(FakeCoursesApi::with_seed(5)));
        root.projection.adopt(projection());
        root.notes = CourseNotesService::new(Arc::new(FakeNotesApi::default()));
        root.notes.begin_load("crs-000");
    });
    root.update(cx, |root, cx| {
        root.ensure_retro_for_course(cx);
        root.ensure_retro_for_course(cx);
    });
    cx.run_until_parked();

    root.update(cx, |root, _| {
        let retros = root
            .notes
            .notes_for_issue("issue-1")
            .into_iter()
            .filter(|note| note.kind == NoteKind::Retro)
            .count();
        assert_eq!(retros, 1);
    });
}

#[gpui_kit::test]
fn stale_add_note_result_is_dropped_after_course_switch(cx: &mut TestAppContext) {
    let (_handle, root) = issue_card_window(cx);
    let (release, gate) = std::sync::mpsc::channel();
    root.update(cx, move |root, _| {
        root.notes = CourseNotesService::new(Arc::new(BlockingNotesApi {
            inner: FakeNotesApi::default(),
            gate: std::sync::Mutex::new(gate),
        }));
        root.notes.begin_load("crs-000");
    });

    root.update(cx, |root, cx| {
        root.add_note_from_selection(
            "旧课程笔记".into(),
            Some("mat-text".into()),
            crate::agent_call::LearningTarget::Material {
                course_id: "crs-000".into(),
                revision: Some(1),
                issue_id: "issue-1".into(),
                objective_id: None,
                material_id: "mat-text".into(),
            },
            cx,
        );
    });
    root.update(cx, |root, _| root.notes.begin_load("crs-001"));
    release.send(()).expect("release note request");
    cx.run_until_parked();

    root.update(cx, |root, _| {
        assert!(root.notes.notes_for_issue("issue-1").is_empty());
    });
}

struct BlockingNotesApi {
    inner: FakeNotesApi,
    gate: std::sync::Mutex<std::sync::mpsc::Receiver<()>>,
}

impl NotesApi for BlockingNotesApi {
    fn list_notes(
        &self,
        token: Option<&str>,
        course_id: &str,
    ) -> Result<Vec<CourseNote>, NotesError> {
        self.inner.list_notes(token, course_id)
    }

    fn create_note(
        &self,
        token: Option<&str>,
        input: NewCourseNote,
    ) -> Result<CourseNote, NotesError> {
        let gate = self
            .gate
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        gate.recv().ok();
        self.inner.create_note(token, input)
    }

    fn update_note(
        &self,
        token: Option<&str>,
        note_id: &str,
        text: &str,
    ) -> Result<CourseNote, NotesError> {
        self.inner.update_note(token, note_id, text)
    }

    fn delete_note(&self, token: Option<&str>, note_id: &str) -> Result<(), NotesError> {
        self.inner.delete_note(token, note_id)
    }

    fn ensure_retro(
        &self,
        token: Option<&str>,
        course_id: &str,
        issue_id: &str,
    ) -> Result<Option<CourseNote>, NotesError> {
        self.inner.ensure_retro(token, course_id, issue_id)
    }
}

#[gpui_kit::test]
fn delete_completion_removes_only_the_deleted_note(cx: &mut TestAppContext) {
    let (_handle, root) = issue_card_window(cx);
    let note_one = CourseNote {
        id: "n1".into(),
        course_id: "crs-000".into(),
        issue_id: "issue-1".into(),
        source_material_id: None,
        kind: NoteKind::Note,
        text: "first".into(),
        created_at: "2026-11-11T00:00:00Z".into(),
        updated_at: None,
    };
    let note_two = CourseNote {
        id: "n2".into(),
        course_id: "crs-000".into(),
        issue_id: "issue-1".into(),
        source_material_id: None,
        kind: NoteKind::Note,
        text: "second".into(),
        created_at: "2026-11-11T00:01:00Z".into(),
        updated_at: None,
    };
    let (release, gate) = std::sync::mpsc::channel();
    root.update(cx, move |root, _| {
        root.notes = CourseNotesService::new(Arc::new(BlockingDeleteNotesApi {
            inner: FakeNotesApi::with_notes(vec![note_one.clone(), note_two.clone()]),
            gate: std::sync::Mutex::new(gate),
        }));
        root.notes.begin_load("crs-000");
        root.notes.adopt(vec![note_one, note_two]);
    });

    root.update(cx, |root, cx| {
        root.confirm_delete_note("n1", cx);
        root.request_delete_note("n2", cx);
    });
    release.send(()).expect("release delete request");
    cx.run_until_parked();

    root.update(cx, |root, _| {
        let ids = root
            .notes
            .notes_for_issue("issue-1")
            .into_iter()
            .map(|note| note.id.clone())
            .collect::<Vec<_>>();
        assert_eq!(ids, vec!["n2".to_string()]);
    });
}

struct BlockingDeleteNotesApi {
    inner: FakeNotesApi,
    gate: std::sync::Mutex<std::sync::mpsc::Receiver<()>>,
}

impl NotesApi for BlockingDeleteNotesApi {
    fn list_notes(
        &self,
        token: Option<&str>,
        course_id: &str,
    ) -> Result<Vec<CourseNote>, NotesError> {
        self.inner.list_notes(token, course_id)
    }

    fn create_note(
        &self,
        token: Option<&str>,
        input: NewCourseNote,
    ) -> Result<CourseNote, NotesError> {
        self.inner.create_note(token, input)
    }

    fn update_note(
        &self,
        token: Option<&str>,
        note_id: &str,
        text: &str,
    ) -> Result<CourseNote, NotesError> {
        self.inner.update_note(token, note_id, text)
    }

    fn delete_note(&self, token: Option<&str>, note_id: &str) -> Result<(), NotesError> {
        let gate = self
            .gate
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        gate.recv().ok();
        self.inner.delete_note(token, note_id)
    }

    fn ensure_retro(
        &self,
        token: Option<&str>,
        course_id: &str,
        issue_id: &str,
    ) -> Result<Option<CourseNote>, NotesError> {
        self.inner.ensure_retro(token, course_id, issue_id)
    }
}

#[gpui_kit::test]
fn send_note_prefills_composer_without_agent_call(cx: &mut TestAppContext) {
    let (handle, root) = issue_card_window(cx);
    let note = CourseNote {
        id: "n1".into(),
        course_id: "crs-000".into(),
        issue_id: "issue-1".into(),
        source_material_id: None,
        kind: NoteKind::Note,
        text: "需要回顾的重点".into(),
        created_at: "2026-11-11T00:00:00Z".into(),
        updated_at: None,
    };

    cx.update_window(handle, |_, window, cx| {
        root.update(cx, |root, cx| {
            root.send_note_to_agent(&note, window, cx);
        });
        assert!(root.read(cx).chat.input.contains("需要回顾的重点"));
        assert!(root.read(cx).chat.pending_agent_call.is_none());
    })
    .unwrap();
}

#[gpui_kit::test]
fn issue_card_switches_selected_objective(cx: &mut TestAppContext) {
    let (handle, root) = issue_card_window(cx);
    root.update(cx, |root, _| {
        root.courses = CourseCatalogService::new(Arc::new(FakeCoursesApi::with_seed(5)));
        let mut content = card_content();
        content
            .document
            .issues
            .first_mut()
            .expect("fake content has one issue")
            .objectives
            .push(CourseObjective {
                id: Some("obj-2".into()),
                title: Some("理解测量单位".into()),
                required: false,
                prereq_ids: Vec::new(),
                activity: None,
                assessment: None,
                rubric: Vec::new(),
                materials: Vec::new(),
                agent_actions: Vec::new(),
            });
        root.content.adopt(content);
        root.projection = LearningProjectionService::new(Arc::new(FakeCoursesApi::with_seed(5)));
        root.projection.adopt(projection());
    });
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        assert!(window.try_find("issue-objective-practice").is_some());
        assert!(window.try_find("issue-objective-row-obj-1").is_some());
        assert!(window.try_find("issue-objective-row-obj-2").is_some());
        assert!(window.try_find("issue-card-objective-obj-1").is_some());
        assert!(window.try_find("issue-card-objective-obj-2").is_none());

        window.click("issue-objective-row-obj-2", cx);
        assert!(root
            .read(cx)
            .selected_objective
            .values()
            .any(|id| id == "obj-2"));
        assert!(window.try_find("issue-card-objective-obj-2").is_some());
        assert!(window.try_find("issue-card-objective-obj-1").is_none());
    })
    .unwrap();
}

/// objective 行可聚焦并用 Enter/Space 激活（#40：不能只有鼠标）。
#[gpui_kit::test]
fn issue_card_objective_row_activates_with_keyboard(cx: &mut TestAppContext) {
    let (handle, root) = issue_card_window(cx);
    root.update(cx, |root, _| {
        root.courses = CourseCatalogService::new(Arc::new(FakeCoursesApi::with_seed(5)));
        root.content.adopt(card_content());
        root.projection = LearningProjectionService::new(Arc::new(FakeCoursesApi::with_seed(5)));
        root.projection.adopt(projection());
    });
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        assert!(window.try_find("issue-objective-row-obj-1").is_some());
        let focus = root
            .read(cx)
            .objective_row_focus
            .get("crs-000:1:issue-1:obj-1")
            .cloned()
            .expect("objective row registers a persistent focus handle");
        focus.focus(window, cx);
        window.render_frame(cx);
        assert!(focus.is_focused(window), "objective row can take focus");
        window.press("enter", cx);
        assert_eq!(
            root.read(cx).selected_objective.get("crs-000:1:issue-1"),
            Some(&"obj-1".to_string()),
            "Enter activates the focused objective row"
        );
        window.press("space", cx);
        assert_eq!(
            root.read(cx).selected_objective.get("crs-000:1:issue-1"),
            Some(&"obj-1".to_string()),
            "Space activates the focused objective row"
        );
    })
    .unwrap();
}

/// 材料动作行可聚焦并用 Enter/Space 展开/收起（#40：open/retry/expand 不能只有鼠标）。
#[gpui_kit::test]
fn issue_card_shows_missing_agent_action_state(cx: &mut TestAppContext) {
    let (handle, root) = issue_card_window(cx);
    root.update(cx, |root, _| {
        root.courses = CourseCatalogService::new(Arc::new(FakeCoursesApi::with_seed(5)));
        let mut content = card_content();
        content.document.issues[0].kind = Some("unknown-kind".into());
        content.document.issues[0].objectives[0]
            .agent_actions
            .clear();
        root.content.adopt(content);
    });

    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        assert!(
            window
                .try_find("issue-agent-actions-missing-obj-1")
                .is_some(),
            "unknown kind without authored actions must show a failure state"
        );
    })
    .unwrap();
}

#[gpui_kit::test]
fn issue_card_shows_invalid_material_url_state(cx: &mut TestAppContext) {
    let (handle, root) = issue_card_window(cx);
    root.update(cx, |root, _| {
        root.courses = CourseCatalogService::new(Arc::new(FakeCoursesApi::with_seed(5)));
        let mut content = card_content();
        content.document.issues[0].story_materials = vec![TypedMaterial {
            id: Some("mat-bad".into()),
            kind: MaterialKind::Web,
            title: Some("坏链接".into()),
            body: None,
            url: Some("http://insecure.example/a".into()),
            alt_text: None,
            caption: None,
            provider: None,
            external_id: None,
        }];
        root.content.adopt(content);
    });

    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        assert!(
            window.try_find("material-error-issue-1-0").is_some(),
            "invalid material URL must render an explicit failure state"
        );
    })
    .unwrap();
}

#[gpui_kit::test]
fn issue_card_material_action_activates_with_keyboard(cx: &mut TestAppContext) {
    let (handle, root) = issue_card_window(cx);
    root.update(cx, |root, _| {
        root.courses = CourseCatalogService::new(Arc::new(FakeCoursesApi::with_seed(5)));
        root.content.adopt(card_content());
        root.projection = LearningProjectionService::new(Arc::new(FakeCoursesApi::with_seed(5)));
        root.projection.adopt(projection());
    });
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        let focus = root
            .read(cx)
            .material_action_focus
            .get("crs-000:1:issue-1:0")
            .cloned()
            .expect("material action registers a persistent focus handle");
        focus.focus(window, cx);
        window.render_frame(cx);
        assert!(focus.is_focused(window), "material action can take focus");
        window.press("enter", cx);
        assert!(
            root.read(cx)
                .expanded_material
                .values()
                .any(|key| key.ends_with(":mat-md")),
            "Enter expands the focused markdown material"
        );
        window.press("space", cx);
        assert!(
            !root
                .read(cx)
                .expanded_material
                .values()
                .any(|key| key.ends_with(":mat-md")),
            "Space collapses the focused markdown material"
        );
    })
    .unwrap();
}

#[gpui_kit::test]
fn issue_card_cta_dispatches_agent_call_to_composer(cx: &mut TestAppContext) {
    let (handle, root) = issue_card_window(cx);
    root.update(cx, |root, _| {
        root.courses = CourseCatalogService::new(Arc::new(FakeCoursesApi::with_seed(5)));
        let mut content = card_content();
        content.document.issues[0].objectives[0].agent_actions = vec![
            AgentActionSpec {
                id: "a-answer".into(),
                label: "回答当前问题".into(),
                intent: AgentIntent::Answer,
                primary: true,
            },
            AgentActionSpec {
                id: "a-hint".into(),
                label: "给我一个提示".into(),
                intent: AgentIntent::Hint,
                primary: false,
            },
        ];
        root.content.adopt(content);
        root.projection = LearningProjectionService::new(Arc::new(FakeCoursesApi::with_seed(5)));
        root.projection.adopt(projection());
        root.native_chat_mode = false;
    });
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        assert!(window.try_find("issue-objective-actions-obj-1").is_some());
        assert!(window
            .try_find("issue-agent-action-obj-1-a-answer")
            .is_some());
        assert!(window.try_find("issue-agent-action-obj-1-a-hint").is_some());

        window.click("issue-agent-action-obj-1-a-answer", cx);
        let input = root.read(cx).chat.input.clone();
        assert!(input.contains("请根据当前目标的验收标准向我提问"));
        assert!(root.read(cx).chat.pending_agent_call.is_some());
        assert!(root.read(cx).agent_panel_open);
    })
    .unwrap();
}

#[gpui_kit::test]
fn issue_card_cta_does_not_flip_native_mode_when_initializing(cx: &mut TestAppContext) {
    let (handle, root) = issue_card_window(cx);
    root.update(cx, |root, _| {
        root.courses = CourseCatalogService::new(Arc::new(FakeCoursesApi::with_seed(5)));
        let mut content = card_content();
        content.document.issues[0].objectives[0].agent_actions = vec![AgentActionSpec {
            id: "a-hint".into(),
            label: "给我一个提示".into(),
            intent: AgentIntent::Hint,
            primary: false,
        }];
        root.content.adopt(content);
        root.projection = LearningProjectionService::new(Arc::new(FakeCoursesApi::with_seed(5)));
        root.projection.adopt(projection());
        root.native_chat_mode = true;
        root.native_agent_view = None;
    });
    cx.update_window(handle, |_, window, cx| {
        std::env::set_var("CGC_NATIVE_AGENT", "1");
        window.render_frame(cx);
        window.click("issue-agent-action-obj-1-a-hint", cx);
        let root = root.read(cx);
        assert!(root.native_chat_mode, "mode must stay native");
        assert!(
            root.pane_notice.is_some(),
            "user must see initializing notice"
        );
        assert!(root.chat.input.is_empty(), "no ACP fallback prefill");
    })
    .unwrap();
}

#[gpui_kit::test]
fn issue_card_practice_uses_prototype_hierarchy(cx: &mut TestAppContext) {
    let (handle, root) = issue_card_window(cx);
    root.update(cx, |root, _| {
        root.courses = CourseCatalogService::new(Arc::new(FakeCoursesApi::with_seed(5)));
        let mut content = card_content();
        let objective = &mut content.document.issues[0].objectives[0];
        objective.materials.push(TypedMaterial {
            id: Some("obj-mat-1".into()),
            kind: MaterialKind::Text,
            title: Some("任务材料".into()),
            body: Some("任务材料正文".into()),
            url: None,
            alt_text: None,
            caption: None,
            provider: None,
            external_id: None,
        });
        root.content.adopt(content);
        root.projection = LearningProjectionService::new(Arc::new(FakeCoursesApi::with_seed(5)));
        root.projection.adopt(projection());
    });
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        assert!(window.try_find("issue-practice-mastered").is_some());
        assert!(window.try_find("issue-practice-mode").is_some());
        assert!(window
            .try_find("issue-objective-description-obj-1")
            .is_some());
        assert!(window.try_find("issue-card-assessment-obj-1").is_some());

        assert!(window.try_find("issue-objective-materials-obj-1").is_some());
        assert!(window
            .try_find("issue-objective-materials-toggle-obj-1")
            .is_some());
        assert!(window
            .find_all("issue-objective-material-content-obj-1")
            .is_empty());
        window.click("issue-objective-materials-toggle-obj-1", cx);
        assert!(!root.read(cx).expanded_objective_materials.is_empty());
        window.render_frame(cx);
        assert!(!window
            .find_all("issue-objective-material-content-obj-1")
            .is_empty());

        assert!(window
            .find_all("issue-objective-rubric-item-obj-1-0")
            .is_empty());
        let revision = root
            .read(cx)
            .content
            .content()
            .and_then(|content| content.revision_number)
            .map(|value| value.to_string())
            .unwrap_or_else(|| "unversioned".into());
        root.update(cx, |root, _| {
            root.expanded_objective_rubric
                .insert(format!("crs-000:{revision}:issue-1:obj-1:rubric"));
        });
        window.render_frame(cx);
        assert!(!window
            .find_all("issue-objective-rubric-item-obj-1-0")
            .is_empty());
    })
    .unwrap();
}

#[gpui_kit::test]
fn issue_card_user_story_falls_back_to_goal_only(cx: &mut TestAppContext) {
    let (handle, root) = issue_card_window(cx);
    root.update(cx, |root, _| {
        root.courses = CourseCatalogService::new(Arc::new(FakeCoursesApi::with_seed(5)));
        let mut content = card_content();
        let issue = content
            .document
            .issues
            .first_mut()
            .expect("fake content has one issue");
        issue.as_a = None;
        issue.given.clear();
        issue.goal = Some("只写 goal 的旧内容".into());
        root.content.adopt(content);
        root.projection = LearningProjectionService::new(Arc::new(FakeCoursesApi::with_seed(5)));
        root.projection.adopt(projection());
    });
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        assert!(window.try_find("issue-card-user-story").is_some());
        assert!(window.try_find("issue-card-story-goal").is_some());
        assert!(window.try_find("issue-card-story-as").is_none());
        assert!(window.try_find("issue-card-story-given").is_none());
    })
    .unwrap();
}

/// #22：选修不计入「必修掌握」计数；必修全掌握 + 选修未做时头部显示 1/1。
#[test]
fn practice_mastery_counts_required_only() {
    use cgc_courses::content::CourseIssue;

    let objective = |id: &str, required: bool| CourseObjective {
        id: Some(id.into()),
        title: Some(id.into()),
        required,
        prereq_ids: Vec::new(),
        activity: None,
        assessment: None,
        rubric: Vec::new(),
        materials: Vec::new(),
        agent_actions: Vec::new(),
    };
    let state = |id: &str, mastery: &str, required: bool| ObjectiveState {
        id: id.into(),
        title: id.into(),
        required,
        mastery: mastery.into(),
        locked: false,
        attempt_count: 0,
        missing_prereq_ids: Vec::new(),
    };
    let issue = CourseIssue {
        id: Some("issue-1".into()),
        title: Some("t".into()),
        chapter_id: None,
        kind: Some("handwork".into()),
        goal: None,
        as_a: None,
        given: Vec::new(),
        checklist: Vec::new(),
        objectives: vec![
            objective("obj-required", true),
            objective("obj-elective", false),
        ],
        story_materials: Vec::new(),
        objective_materials: Vec::new(),
    };
    let projection = LearningProjection {
        course_id: "crs-000".into(),
        title: "Course".into(),
        revision_number: Some(1),
        stale_revision: false,
        run: None,
        next_action: None,
        progress: None,
        objectives: vec![
            state("obj-required", "mastered", true),
            state("obj-elective", "unassessed", false),
        ],
        review_queue: Vec::new(),
    };
    assert_eq!(
        required_mastery_counts(&issue, Some(&projection)),
        (1, 1),
        "electives must not dilute required completion"
    );
}
