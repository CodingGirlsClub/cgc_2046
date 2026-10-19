//! 学习投影（story 4.6）：courseLearningDetail 的进度/下一步/掌握/复习队列。
//!
//! 只读服务：进入学习页后加载；数据来自后端既有学习循环，不在客户端计算掌握度。

use std::sync::Arc;

use serde_json::Value;

use crate::catalog::CoursesError;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RunSummary {
    pub id: String,
    pub status: String,
    pub revision_number: Option<i64>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ObjectiveState {
    pub id: String,
    pub title: String,
    pub required: bool,
    pub mastery: String,
    pub locked: bool,
    pub attempt_count: i64,
    pub missing_prereq_ids: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NextAction {
    pub kind: String,
    pub objective_id: String,
    pub reason: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LearningProgressSummary {
    pub mastered_required: i64,
    pub total_required: i64,
    pub complete: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ReviewQueueEntry {
    pub objective_id: String,
    pub due_at: String,
    pub needs_review: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LearningProjection {
    pub course_id: String,
    pub title: String,
    pub revision_number: Option<i64>,
    pub stale_revision: bool,
    pub run: Option<RunSummary>,
    pub next_action: Option<NextAction>,
    pub progress: Option<LearningProgressSummary>,
    pub objectives: Vec<ObjectiveState>,
    pub review_queue: Vec<ReviewQueueEntry>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ProjectionState {
    Idle,
    Loading,
    Ready,
    Empty,
    Failed(String),
}

pub struct LearningProjectionService {
    api: Arc<dyn crate::catalog::CoursesApi>,
    course_id: Option<String>,
    projection: Option<LearningProjection>,
    state: ProjectionState,
}

impl LearningProjectionService {
    pub fn new(api: Arc<dyn crate::catalog::CoursesApi>) -> Self {
        Self {
            api,
            course_id: None,
            projection: None,
            state: ProjectionState::Idle,
        }
    }

    pub fn api_handle(&self) -> Arc<dyn crate::catalog::CoursesApi> {
        Arc::clone(&self.api)
    }

    pub fn state(&self) -> &ProjectionState {
        &self.state
    }

    pub fn projection(&self) -> Option<&LearningProjection> {
        self.projection.as_ref()
    }

    pub fn begin_load(&mut self, course_id: &str) {
        self.course_id = Some(course_id.to_string());
        self.state = ProjectionState::Loading;
    }

    pub fn adopt(&mut self, projection: LearningProjection) {
        self.projection = Some(projection);
        self.state = ProjectionState::Ready;
    }

    pub fn fail(&mut self, error: &CoursesError) {
        self.state = ProjectionState::Failed(error.diagnostic());
    }

    pub fn retry_ready(&mut self) {
        self.state = ProjectionState::Idle;
        self.projection = None;
        self.course_id = None;
    }

    pub fn reset(&mut self) {
        self.projection = None;
        self.course_id = None;
        self.state = ProjectionState::Idle;
    }
}

pub fn parse_learning_projection(value: &Value) -> Option<LearningProjection> {
    Some(LearningProjection {
        course_id: value.get("courseId")?.as_str()?.to_string(),
        title: value.get("title")?.as_str()?.to_string(),
        revision_number: value.get("revisionNumber").and_then(Value::as_i64),
        stale_revision: value
            .get("staleRevision")
            .and_then(Value::as_bool)
            .unwrap_or(false),
        run: value.get("run").and_then(parse_run),
        next_action: value.get("nextAction").and_then(parse_next_action),
        progress: value.get("progress").and_then(parse_progress),
        objectives: value
            .get("objectives")
            .and_then(Value::as_array)
            .map(|objectives| objectives.iter().filter_map(parse_objective).collect())
            .unwrap_or_default(),
        review_queue: value
            .get("reviewQueue")
            .and_then(Value::as_array)
            .map(|entries| entries.iter().filter_map(parse_review).collect())
            .unwrap_or_default(),
    })
}

fn parse_run(value: &Value) -> Option<RunSummary> {
    Some(RunSummary {
        id: value.get("id")?.as_str()?.to_string(),
        status: value.get("status")?.as_str()?.to_string(),
        revision_number: value.get("revisionNumber").and_then(Value::as_i64),
    })
}

fn parse_objective(value: &Value) -> Option<ObjectiveState> {
    Some(ObjectiveState {
        id: value.get("id")?.as_str()?.to_string(),
        title: value.get("title")?.as_str()?.to_string(),
        required: value
            .get("required")
            .and_then(Value::as_bool)
            .unwrap_or(false),
        mastery: value
            .get("mastery")
            .and_then(Value::as_str)
            .unwrap_or("unknown")
            .to_string(),
        locked: value
            .get("locked")
            .and_then(Value::as_bool)
            .unwrap_or(false),
        attempt_count: value
            .get("attemptCount")
            .and_then(Value::as_i64)
            .unwrap_or(0),
        missing_prereq_ids: value
            .get("missingPrereqIds")
            .and_then(Value::as_array)
            .map(|items| {
                items
                    .iter()
                    .filter_map(|item| item.get("id").and_then(Value::as_str))
                    .map(str::to_string)
                    .collect()
            })
            .unwrap_or_default(),
    })
}

fn parse_next_action(value: &Value) -> Option<NextAction> {
    Some(NextAction {
        kind: value.get("kind")?.as_str()?.to_string(),
        objective_id: value.get("objectiveId")?.as_str()?.to_string(),
        reason: value.get("reason")?.as_str()?.to_string(),
    })
}

fn parse_progress(value: &Value) -> Option<LearningProgressSummary> {
    Some(LearningProgressSummary {
        mastered_required: value.get("masteredRequired")?.as_i64()?,
        total_required: value.get("totalRequired")?.as_i64()?,
        complete: value
            .get("complete")
            .and_then(Value::as_bool)
            .unwrap_or(false),
    })
}

fn parse_review(value: &Value) -> Option<ReviewQueueEntry> {
    Some(ReviewQueueEntry {
        objective_id: value.get("objectiveId")?.as_str()?.to_string(),
        due_at: value.get("dueAt")?.as_str()?.to_string(),
        needs_review: value
            .get("needsReview")
            .and_then(Value::as_bool)
            .unwrap_or(false),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn payload() -> Value {
        serde_json::json!({
            "courseId": "crs-1",
            "title": "课程 A",
            "revisionNumber": 3,
            "staleRevision": true,
            "run": { "id": "run-1", "status": "active", "revisionNumber": 2 },
            "nextAction": {
                "kind": "learn",
                "objectiveId": "obj-2",
                "reason": "先完成「变量」再继续"
            },
            "progress": { "masteredRequired": 1, "totalRequired": 4, "complete": false },
            "objectives": [
                {
                    "id": "obj-1",
                    "title": "变量",
                    "required": true,
                    "mastery": "mastered",
                    "locked": false,
                    "attemptCount": 2,
                    "missingPrereqIds": []
                },
                {
                    "id": "obj-2",
                    "title": "函数",
                    "required": true,
                    "mastery": "learning",
                    "locked": false,
                    "attemptCount": 1,
                    "missingPrereqIds": [{"id": "obj-1", "title": "变量"}]
                }
            ],
            "reviewQueue": [
                { "objectiveId": "obj-1", "dueAt": "2026-10-20T00:00:00Z", "needsReview": true }
            ]
        })
    }

    #[test]
    fn parses_projection_fields() {
        let projection = parse_learning_projection(&payload()).expect("parse");
        assert_eq!(projection.course_id, "crs-1");
        assert_eq!(projection.revision_number, Some(3));
        assert!(projection.stale_revision);
        assert_eq!(projection.run.expect("run").status, "active");
        assert_eq!(
            projection.next_action.expect("next").reason,
            "先完成「变量」再继续"
        );
        assert_eq!(projection.progress.expect("progress").total_required, 4);
        assert_eq!(projection.objectives.len(), 2);
        assert_eq!(projection.objectives[1].missing_prereq_ids, vec!["obj-1"]);
        assert_eq!(projection.review_queue.len(), 1);
    }

    #[test]
    fn missing_optional_sections_are_tolerated() {
        let projection = parse_learning_projection(&serde_json::json!({
            "courseId": "crs-2",
            "title": "空投影",
            "staleRevision": false
        }))
        .expect("parse");
        assert!(projection.run.is_none());
        assert!(projection.next_action.is_none());
        assert!(projection.objectives.is_empty());
        assert!(!projection.stale_revision);
    }
}
