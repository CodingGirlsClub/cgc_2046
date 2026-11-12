//! 课程 Notes 的客户端读面与写入端口。
//!
//! 服务端是唯一真源；本模块不落盘，只保留会话内列表与加载状态。
//! `NotesApi` 由 app 持有，UI 通过 `CourseNotesService` 读取/替换内存缓存。

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use cgc_platform::api::{ApiError, GraphqlClient};
use serde_json::{json, Value};

use crate::catalog::CoursesError;

const LIST_NOTES_QUERY: &str = r#"
query MyCourseNotes($courseId: ID!) {
  myCourseNotes(courseId: $courseId) {
    id courseId issueId sourceMaterialId kind text createdAt updatedAt
  }
}
"#;

const CREATE_NOTE_MUTATION: &str = r#"
mutation CreateCourseNote($input: CreateCourseNoteInput!) {
  createCourseNote(input: $input) {
    id courseId issueId sourceMaterialId kind text createdAt updatedAt
  }
}
"#;

const UPDATE_NOTE_MUTATION: &str = r#"
mutation UpdateCourseNote($id: ID!, $input: UpdateCourseNoteInput!) {
  updateCourseNote(id: $id, input: $input) {
    id courseId issueId sourceMaterialId kind text createdAt updatedAt
  }
}
"#;

const DELETE_NOTE_MUTATION: &str = r#"
mutation DeleteCourseNote($id: ID!) {
  deleteCourseNote(id: $id)
}
"#;

const ENSURE_RETRO_MUTATION: &str = r#"
mutation EnsureCourseRetro($courseId: ID!, $issueId: String!) {
  ensureCourseRetro(courseId: $courseId, issueId: $issueId) {
    id courseId issueId sourceMaterialId kind text createdAt updatedAt
  }
}
"#;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum NoteKind {
    Note,
    Retro,
}

impl NoteKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Note => "note",
            Self::Retro => "retro",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "note" => Some(Self::Note),
            "retro" => Some(Self::Retro),
            _ => None,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CourseNote {
    pub id: String,
    pub course_id: String,
    pub issue_id: String,
    pub source_material_id: Option<String>,
    pub kind: NoteKind,
    pub text: String,
    pub created_at: String,
    pub updated_at: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NewCourseNote {
    pub course_id: String,
    pub issue_id: String,
    pub source_material_id: Option<String>,
    pub text: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum NotesError {
    Unauthorized,
    NotFound,
    Duplicate,
    CourseNotAccessible,
    InvalidText,
    Transport(String),
    Server(String),
}

impl NotesError {
    pub fn diagnostic(&self) -> String {
        match self {
            Self::Unauthorized => "unauthorized".into(),
            Self::NotFound => "not found".into(),
            Self::Duplicate => "duplicate note".into(),
            Self::CourseNotAccessible => "course not accessible".into(),
            Self::InvalidText => "invalid note text".into(),
            Self::Transport(reason) => format!("transport error: {reason}"),
            Self::Server(reason) => reason.clone(),
        }
    }

    pub fn is_unauthorized(&self) -> bool {
        matches!(self, Self::Unauthorized)
    }
}

impl std::fmt::Display for NotesError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.diagnostic())
    }
}

impl std::error::Error for NotesError {}

impl From<ApiError> for NotesError {
    fn from(error: ApiError) -> Self {
        match error {
            ApiError::Unauthorized => Self::Unauthorized,
            ApiError::Graphql {
                code: Some(code), ..
            } => match code.as_str() {
                "duplicate_note" => Self::Duplicate,
                "course_not_accessible" => Self::CourseNotAccessible,
                "invalid_text" => Self::InvalidText,
                "not_found" => Self::NotFound,
                _ => Self::Server(code),
            },
            ApiError::Graphql { message, .. } => Self::Server(message),
            ApiError::Transport(reason) => Self::Transport(reason),
            ApiError::Timeout(reason) => Self::Transport(reason),
        }
    }
}

impl From<CoursesError> for NotesError {
    fn from(error: CoursesError) -> Self {
        match error {
            CoursesError::Unauthorized => Self::Unauthorized,
            CoursesError::NotFound => Self::NotFound,
            CoursesError::Transport(reason) => Self::Transport(reason),
            CoursesError::Server(reason) => Self::Server(reason),
        }
    }
}

pub trait NotesApi: Send + Sync {
    fn list_notes(
        &self,
        token: Option<&str>,
        course_id: &str,
    ) -> Result<Vec<CourseNote>, NotesError>;

    fn create_note(
        &self,
        token: Option<&str>,
        input: NewCourseNote,
    ) -> Result<CourseNote, NotesError>;

    fn update_note(
        &self,
        token: Option<&str>,
        note_id: &str,
        text: &str,
    ) -> Result<CourseNote, NotesError>;

    fn delete_note(&self, token: Option<&str>, note_id: &str) -> Result<(), NotesError>;

    fn ensure_retro(
        &self,
        token: Option<&str>,
        course_id: &str,
        issue_id: &str,
    ) -> Result<Option<CourseNote>, NotesError>;
}

/// 本地开发/UI 测试用的内存 Notes API；不落盘，进程结束即丢。
pub struct FakeNotesApi {
    notes: Mutex<Vec<CourseNote>>,
    next_id: AtomicU64,
}

impl Default for FakeNotesApi {
    fn default() -> Self {
        Self {
            notes: Mutex::new(Vec::new()),
            next_id: AtomicU64::new(1),
        }
    }
}

impl FakeNotesApi {
    pub fn with_notes(notes: Vec<CourseNote>) -> Self {
        Self {
            notes: Mutex::new(notes),
            next_id: AtomicU64::new(1),
        }
    }
}

impl NotesApi for FakeNotesApi {
    fn list_notes(
        &self,
        _token: Option<&str>,
        course_id: &str,
    ) -> Result<Vec<CourseNote>, NotesError> {
        let notes = self
            .notes
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        Ok(notes
            .iter()
            .filter(|note| note.course_id == course_id)
            .cloned()
            .collect())
    }

    fn create_note(
        &self,
        _token: Option<&str>,
        input: NewCourseNote,
    ) -> Result<CourseNote, NotesError> {
        let mut notes = self
            .notes
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        if let Some(existing) = notes.iter().find(|note| {
            note.course_id == input.course_id
                && note.issue_id == input.issue_id
                && note.source_material_id == input.source_material_id
                && note.text == input.text
        }) {
            return Ok(existing.clone());
        }

        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let note = CourseNote {
            id: format!("note-{id}"),
            course_id: input.course_id,
            issue_id: input.issue_id,
            source_material_id: input.source_material_id,
            kind: NoteKind::Note,
            text: input.text,
            created_at: format!("2026-11-11T00:00:{id:02}Z"),
            updated_at: None,
        };
        notes.push(note.clone());
        Ok(note)
    }

    fn update_note(
        &self,
        _token: Option<&str>,
        note_id: &str,
        text: &str,
    ) -> Result<CourseNote, NotesError> {
        let mut notes = self
            .notes
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        let note = notes
            .iter_mut()
            .find(|note| note.id == note_id)
            .ok_or(NotesError::NotFound)?;
        note.text = text.to_string();
        note.updated_at = Some("2026-11-11T00:01:00Z".into());
        Ok(note.clone())
    }

    fn delete_note(&self, _token: Option<&str>, note_id: &str) -> Result<(), NotesError> {
        let mut notes = self
            .notes
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        let before = notes.len();
        notes.retain(|note| note.id != note_id);
        if notes.len() == before {
            Err(NotesError::NotFound)
        } else {
            Ok(())
        }
    }

    fn ensure_retro(
        &self,
        _token: Option<&str>,
        course_id: &str,
        issue_id: &str,
    ) -> Result<Option<CourseNote>, NotesError> {
        let mut notes = self
            .notes
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        if let Some(note) = notes.iter().find(|note| {
            note.course_id == course_id && note.issue_id == issue_id && note.kind == NoteKind::Retro
        }) {
            return Ok(Some(note.clone()));
        }
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let note = CourseNote {
            id: format!("retro-{id}"),
            course_id: course_id.to_string(),
            issue_id: issue_id.to_string(),
            source_material_id: None,
            kind: NoteKind::Retro,
            text: "【复盘】测试复盘".into(),
            created_at: format!("2026-11-11T00:02:{id:02}Z"),
            updated_at: None,
        };
        notes.push(note.clone());
        Ok(Some(note))
    }
}

pub struct HttpNotesApi {
    client: GraphqlClient,
}

impl HttpNotesApi {
    pub fn new(client: GraphqlClient) -> Self {
        Self { client }
    }

    pub fn from_env() -> Self {
        Self::new(GraphqlClient::from_env())
    }

    fn parse_note(value: &Value) -> Option<CourseNote> {
        Some(CourseNote {
            id: value.get("id")?.as_str()?.to_string(),
            course_id: value.get("courseId")?.as_str()?.to_string(),
            issue_id: value.get("issueId")?.as_str()?.to_string(),
            source_material_id: value
                .get("sourceMaterialId")
                .and_then(Value::as_str)
                .map(str::to_string),
            kind: NoteKind::parse(value.get("kind")?.as_str()?)?,
            text: value.get("text")?.as_str()?.to_string(),
            created_at: value.get("createdAt")?.as_str()?.to_string(),
            updated_at: value
                .get("updatedAt")
                .and_then(Value::as_str)
                .map(str::to_string),
        })
    }

    fn parse_note_payload(payload: &Value, field: &str) -> Result<CourseNote, NotesError> {
        payload
            .get("data")
            .and_then(|data| data.get(field))
            .and_then(Self::parse_note)
            .ok_or_else(|| NotesError::Server(format!("missing {field} payload")))
    }
}

impl NotesApi for HttpNotesApi {
    fn list_notes(
        &self,
        token: Option<&str>,
        course_id: &str,
    ) -> Result<Vec<CourseNote>, NotesError> {
        let payload = self
            .client
            .post(token, LIST_NOTES_QUERY, json!({ "courseId": course_id }))
            .map_err(NotesError::from)?;

        let notes = payload
            .get("data")
            .and_then(|data| data.get("myCourseNotes"))
            .and_then(Value::as_array)
            .ok_or_else(|| NotesError::Server("missing myCourseNotes payload".into()))?;

        Ok(notes.iter().filter_map(Self::parse_note).collect())
    }

    fn create_note(
        &self,
        token: Option<&str>,
        input: NewCourseNote,
    ) -> Result<CourseNote, NotesError> {
        let payload = self
            .client
            .post(
                token,
                CREATE_NOTE_MUTATION,
                json!({
                    "input": {
                        "courseId": input.course_id,
                        "issueId": input.issue_id,
                        "sourceMaterialId": input.source_material_id,
                        "text": input.text,
                    }
                }),
            )
            .map_err(NotesError::from)?;

        Self::parse_note_payload(&payload, "createCourseNote")
    }

    fn update_note(
        &self,
        token: Option<&str>,
        note_id: &str,
        text: &str,
    ) -> Result<CourseNote, NotesError> {
        let payload = self
            .client
            .post(
                token,
                UPDATE_NOTE_MUTATION,
                json!({ "id": note_id, "input": { "text": text } }),
            )
            .map_err(NotesError::from)?;

        Self::parse_note_payload(&payload, "updateCourseNote")
    }

    fn delete_note(&self, token: Option<&str>, note_id: &str) -> Result<(), NotesError> {
        let payload = self
            .client
            .post(token, DELETE_NOTE_MUTATION, json!({ "id": note_id }))
            .map_err(NotesError::from)?;

        match payload
            .get("data")
            .and_then(|data| data.get("deleteCourseNote"))
            .and_then(Value::as_bool)
        {
            Some(true) => Ok(()),
            Some(false) => Err(NotesError::NotFound),
            None => Err(NotesError::Server(
                "missing deleteCourseNote payload".into(),
            )),
        }
    }

    fn ensure_retro(
        &self,
        token: Option<&str>,
        course_id: &str,
        issue_id: &str,
    ) -> Result<Option<CourseNote>, NotesError> {
        let payload = self
            .client
            .post(
                token,
                ENSURE_RETRO_MUTATION,
                json!({ "courseId": course_id, "issueId": issue_id }),
            )
            .map_err(NotesError::from)?;

        match payload
            .get("data")
            .and_then(|data| data.get("ensureCourseRetro"))
        {
            Some(Value::Null) => Ok(None),
            Some(note) => Self::parse_note(note)
                .map(Some)
                .ok_or_else(|| NotesError::Server("invalid ensureCourseRetro payload".into())),
            None => Err(NotesError::Server(
                "missing ensureCourseRetro payload".into(),
            )),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum NotesState {
    Idle,
    Loading,
    Ready,
    Empty,
    Failed(String),
}

pub struct CourseNotesService {
    api: Arc<dyn NotesApi>,
    course_id: Option<String>,
    notes: Vec<CourseNote>,
    state: NotesState,
}

impl CourseNotesService {
    pub fn new(api: Arc<dyn NotesApi>) -> Self {
        Self {
            api,
            course_id: None,
            notes: Vec::new(),
            state: NotesState::Idle,
        }
    }

    pub fn api_handle(&self) -> Arc<dyn NotesApi> {
        Arc::clone(&self.api)
    }

    pub fn state(&self) -> &NotesState {
        &self.state
    }

    pub fn notes(&self) -> &[CourseNote] {
        &self.notes
    }

    pub fn course_id(&self) -> Option<&str> {
        self.course_id.as_deref()
    }

    pub fn begin_load(&mut self, course_id: &str) {
        self.course_id = Some(course_id.to_string());
        self.notes.clear();
        self.state = NotesState::Loading;
    }

    pub fn adopt(&mut self, notes: Vec<CourseNote>) {
        self.state = if notes.is_empty() {
            NotesState::Empty
        } else {
            NotesState::Ready
        };
        self.notes = notes;
    }

    pub fn fail(&mut self, error: &NotesError) {
        self.state = NotesState::Failed(error.diagnostic());
    }

    pub fn reset(&mut self) {
        self.course_id = None;
        self.notes.clear();
        self.state = NotesState::Idle;
    }

    pub fn upsert(&mut self, note: CourseNote) {
        if let Some(existing) = self.notes.iter_mut().find(|item| item.id == note.id) {
            *existing = note;
        } else {
            self.notes.push(note);
        }
        self.notes
            .sort_by(|left, right| right.created_at.cmp(&left.created_at));
        self.state = if self.notes.is_empty() {
            NotesState::Empty
        } else {
            NotesState::Ready
        };
    }

    pub fn remove(&mut self, note_id: &str) {
        self.notes.retain(|note| note.id != note_id);
        self.state = if self.notes.is_empty() {
            NotesState::Empty
        } else {
            NotesState::Ready
        };
    }

    pub fn notes_for_issue(&self, issue_id: &str) -> Vec<&CourseNote> {
        self.notes
            .iter()
            .filter(|note| note.issue_id == issue_id)
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn note(id: &str, issue: &str, text: &str) -> CourseNote {
        CourseNote {
            id: id.into(),
            course_id: "course-1".into(),
            issue_id: issue.into(),
            source_material_id: None,
            kind: NoteKind::Note,
            text: text.into(),
            created_at: "2026-11-11T00:00:00Z".into(),
            updated_at: None,
        }
    }

    #[test]
    fn service_replaces_and_removes_notes_by_id() {
        let mut service = CourseNotesService::new(Arc::new(EmptyNotesApi));
        service.begin_load("course-1");
        service.adopt(vec![note("n1", "issue-1", "old")]);

        service.upsert(note("n1", "issue-1", "new"));
        assert_eq!(service.notes().len(), 1);
        assert_eq!(service.notes()[0].text, "new");

        service.upsert(note("n2", "issue-2", "second"));
        assert_eq!(service.notes_for_issue("issue-2").len(), 1);

        service.remove("n1");
        assert_eq!(service.notes().len(), 1);
        assert_eq!(service.notes()[0].id, "n2");
    }

    #[test]
    fn parses_note_payload_and_kind() {
        let value = json!({
            "id": "n1",
            "courseId": "course-1",
            "issueId": "issue-1",
            "sourceMaterialId": "mat-1",
            "kind": "retro",
            "text": "复盘",
            "createdAt": "2026-11-11T00:00:00Z",
            "updatedAt": null
        });

        let parsed = HttpNotesApi::parse_note(&value).expect("note");
        assert_eq!(parsed.kind, NoteKind::Retro);
        assert_eq!(parsed.source_material_id.as_deref(), Some("mat-1"));
        assert_eq!(parsed.updated_at, None);
    }

    struct EmptyNotesApi;

    impl NotesApi for EmptyNotesApi {
        fn list_notes(
            &self,
            _token: Option<&str>,
            _course_id: &str,
        ) -> Result<Vec<CourseNote>, NotesError> {
            Ok(Vec::new())
        }

        fn create_note(
            &self,
            _token: Option<&str>,
            _input: NewCourseNote,
        ) -> Result<CourseNote, NotesError> {
            Err(NotesError::Server("not used".into()))
        }

        fn update_note(
            &self,
            _token: Option<&str>,
            _note_id: &str,
            _text: &str,
        ) -> Result<CourseNote, NotesError> {
            Err(NotesError::Server("not used".into()))
        }

        fn delete_note(&self, _token: Option<&str>, _note_id: &str) -> Result<(), NotesError> {
            Err(NotesError::Server("not used".into()))
        }

        fn ensure_retro(
            &self,
            _token: Option<&str>,
            _course_id: &str,
            _issue_id: &str,
        ) -> Result<Option<CourseNote>, NotesError> {
            Ok(None)
        }
    }
}
