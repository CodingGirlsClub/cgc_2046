//! 我的报名列表（story 3.7）：myEnrollments 查询与行模型。

use cgc_platform::api::{ApiError, GraphqlClient};
use serde_json::Value;

/// `myEnrollments` 后端单页上限（schema：Maximum 250）。
pub const MY_ENROLLMENTS_PAGE_SIZE: i64 = 250;

const MY_ENROLLMENTS_QUERY: &str = r#"
query MyEnrollments($first: Int, $after: String) {
  myEnrollments(first: $first, after: $after) {
    count
    endKeyset
    results { id workspaceId status targetTitle startsAt eventId courseId paymentMode checkInCode }
  }
}
"#;

const MY_ENROLLMENT_FOR_COURSE_QUERY: &str = r#"
query MyEnrollmentForCourse($offeringId: ID!) {
  myEnrollment(kind: "course", offeringId: $offeringId) {
    id workspaceId status targetTitle startsAt eventId courseId paymentMode checkInCode
  }
}
"#;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MyEnrollmentRow {
    pub id: String,
    pub workspace_id: String,
    pub status: String,
    pub target_title: Option<String>,
    pub starts_at: Option<String>,
    pub event_id: Option<String>,
    pub course_id: Option<String>,
    pub payment_mode: Option<String>,
    pub check_in_code: Option<String>,
}

/// `myEnrollments` 的一页；`next_cursor` 来自 `endKeyset`，为空表示没有下一页。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MyEnrollmentsPage {
    pub rows: Vec<MyEnrollmentRow>,
    pub total: Option<i64>,
    pub next_cursor: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EnrollmentPaginationMeta {
    pub total: Option<i64>,
    pub next_cursor: Option<String>,
}

/// 是否还有下一页：优先用 `count` 与已加载行数判定，缺 count 时退回 cursor 存在性。
pub fn has_more_enrollments(
    meta: Option<&EnrollmentPaginationMeta>,
    loaded_rows: usize,
) -> bool {
    let Some(meta) = meta else {
        return false;
    };
    meta.next_cursor.is_some()
        && meta
            .total
            .is_none_or(|total| (loaded_rows as i64) < total)
}

impl MyEnrollmentsPage {
    pub fn pagination(&self) -> EnrollmentPaginationMeta {
        EnrollmentPaginationMeta {
            total: self.total,
            next_cursor: self.next_cursor.clone(),
        }
    }
}

/// run 的 enrollment 归属：先按 `enrollment_id`，找不到时用补查追加的
/// `course_id + confirmed` 行兜底（R13：不能因分页缺失丢工作区徽标）。
pub fn enrollment_for_run<'a>(
    rows: &'a [MyEnrollmentRow],
    run: &MyLearningRunRow,
) -> Option<&'a MyEnrollmentRow> {
    rows.iter()
        .find(|row| row.id == run.enrollment_id)
        .or_else(|| {
            rows.iter().find(|row| {
                row.status == "confirmed"
                    && row.course_id.as_deref() == Some(run.course_id.as_str())
            })
        })
}

pub trait EnrollmentsApi: Send + Sync {
    fn my_enrollments_page(
        &self,
        token: Option<&str>,
        after: Option<&str>,
    ) -> Result<MyEnrollmentsPage, crate::list::EventsError>;

    /// 首屏（向后兼容旧调用点）；分页请用 `my_enrollments_page`。
    fn my_enrollments(
        &self,
        token: Option<&str>,
    ) -> Result<Vec<MyEnrollmentRow>, crate::list::EventsError> {
        self.my_enrollments_page(token, None)
            .map(|page| page.rows)
    }

    /// 按课程补查本人报名（run 的 enrollment 不在已加载页时兜底）。
    fn my_enrollment_for_course(
        &self,
        token: Option<&str>,
        course_id: &str,
    ) -> Result<Option<MyEnrollmentRow>, crate::list::EventsError>;

    /// 最近一次 `my_enrollments_page` 的分页元信息（UI load-more 用）。
    fn enrollment_pagination(&self) -> Option<EnrollmentPaginationMeta> {
        None
    }

    /// 本人 confirmed 课程报名的学习 run 进度；event 报名不返回。
    fn my_learning_runs(
        &self,
        token: Option<&str>,
    ) -> Result<Vec<MyLearningRunRow>, crate::list::EventsError>;
}

const MY_LEARNING_RUNS_QUERY: &str = r#"
query MyLearningRuns {
  myLearningRuns {
    runId enrollmentId courseId targetTitle status staleRevision
    progress { masteredRequired totalRequired complete }
    nextAction { kind objectiveId reason }
  }
}
"#;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LearningProgress {
    pub mastered_required: i64,
    pub total_required: i64,
    pub complete: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LearningNextAction {
    pub kind: String,
    pub objective_id: String,
    pub reason: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MyLearningRunRow {
    pub run_id: String,
    pub enrollment_id: String,
    pub course_id: String,
    pub target_title: Option<String>,
    pub status: String,
    pub stale_revision: bool,
    pub progress: LearningProgress,
    pub next_action: Option<LearningNextAction>,
}

pub struct HttpEnrollmentsApi {
    client: GraphqlClient,
    last_page: std::sync::Mutex<Option<EnrollmentPaginationMeta>>,
}

impl HttpEnrollmentsApi {
    pub fn new(client: GraphqlClient) -> Self {
        Self {
            client,
            last_page: std::sync::Mutex::new(None),
        }
    }
    pub fn from_env() -> Self {
        Self::new(GraphqlClient::from_env())
    }

    fn parse(value: &Value) -> Option<MyEnrollmentRow> {
        Some(MyEnrollmentRow {
            id: value.get("id")?.as_str()?.to_string(),
            workspace_id: value.get("workspaceId")?.as_str()?.to_string(),
            status: value
                .get("status")?
                .as_str()
                .unwrap_or("pending")
                .to_string(),
            target_title: value
                .get("targetTitle")
                .and_then(Value::as_str)
                .map(str::to_string),
            starts_at: value
                .get("startsAt")
                .and_then(Value::as_str)
                .map(str::to_string),
            event_id: value
                .get("eventId")
                .and_then(Value::as_str)
                .map(str::to_string),
            course_id: value
                .get("courseId")
                .and_then(Value::as_str)
                .map(str::to_string),
            payment_mode: value
                .get("paymentMode")
                .and_then(Value::as_str)
                .map(str::to_string),
            check_in_code: value
                .get("checkInCode")
                .and_then(Value::as_str)
                .map(str::to_string),
        })
    }
    fn parse_run(value: &Value) -> Option<MyLearningRunRow> {
        let progress = value.get("progress")?;
        let next_action = value
            .get("nextAction")
            .filter(|action| !action.is_null())
            .and_then(|action| {
                Some(LearningNextAction {
                    kind: action.get("kind")?.as_str()?.to_string(),
                    objective_id: action
                        .get("objectiveId")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_string(),
                    reason: action
                        .get("reason")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_string(),
                })
            });
        Some(MyLearningRunRow {
            run_id: value.get("runId")?.as_str()?.to_string(),
            enrollment_id: value.get("enrollmentId")?.as_str()?.to_string(),
            course_id: value.get("courseId")?.as_str()?.to_string(),
            target_title: value
                .get("targetTitle")
                .and_then(Value::as_str)
                .map(str::to_string),
            status: value
                .get("status")
                .and_then(Value::as_str)
                .unwrap_or("running")
                .to_string(),
            stale_revision: value
                .get("staleRevision")
                .and_then(Value::as_bool)
                .unwrap_or(false),
            progress: LearningProgress {
                mastered_required: progress
                    .get("masteredRequired")
                    .and_then(Value::as_i64)
                    .unwrap_or(0),
                total_required: progress
                    .get("totalRequired")
                    .and_then(Value::as_i64)
                    .unwrap_or(0),
                complete: progress
                    .get("complete")
                    .and_then(Value::as_bool)
                    .unwrap_or(false),
            },
            next_action,
        })
    }
}

impl EnrollmentsApi for HttpEnrollmentsApi {
    fn my_enrollments_page(
        &self,
        token: Option<&str>,
        after: Option<&str>,
    ) -> Result<MyEnrollmentsPage, crate::list::EventsError> {
        let payload = self
            .client
            .post(
                token,
                MY_ENROLLMENTS_QUERY,
                serde_json::json!({ "first": MY_ENROLLMENTS_PAGE_SIZE, "after": after }),
            )
            .map_err(|error: ApiError| match error {
                ApiError::Transport(reason) => crate::list::EventsError::Transport(reason),
                ApiError::Timeout(reason) => {
                    crate::list::EventsError::Transport(format!("timeout: {reason}"))
                }
                ApiError::Unauthorized => crate::list::EventsError::Unauthorized,
                ApiError::Graphql { message, .. } => crate::list::EventsError::Server(message),
            })?;
        let page = payload
            .get("data")
            .and_then(|data| data.get("myEnrollments"))
            .ok_or_else(|| crate::list::EventsError::Server("missing myEnrollments".to_string()))?;
        let result = MyEnrollmentsPage {
            rows: page
                .get("results")
                .and_then(Value::as_array)
                .map(|results| results.iter().filter_map(Self::parse).collect())
                .unwrap_or_default(),
            total: page.get("count").and_then(Value::as_i64),
            next_cursor: page
                .get("endKeyset")
                .and_then(Value::as_str)
                .map(str::to_string),
        };
        *self
            .last_page
            .lock()
            .unwrap_or_else(|poison| poison.into_inner()) = Some(result.pagination());
        Ok(result)
    }

    fn enrollment_pagination(&self) -> Option<EnrollmentPaginationMeta> {
        self.last_page
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .clone()
    }

    fn my_enrollment_for_course(
        &self,
        token: Option<&str>,
        course_id: &str,
    ) -> Result<Option<MyEnrollmentRow>, crate::list::EventsError> {
        let payload = self
            .client
            .post(
                token,
                MY_ENROLLMENT_FOR_COURSE_QUERY,
                serde_json::json!({ "offeringId": course_id }),
            )
            .map_err(|error: ApiError| match error {
                ApiError::Transport(reason) => crate::list::EventsError::Transport(reason),
                ApiError::Timeout(reason) => {
                    crate::list::EventsError::Transport(format!("timeout: {reason}"))
                }
                ApiError::Unauthorized => crate::list::EventsError::Unauthorized,
                ApiError::Graphql { message, .. } => crate::list::EventsError::Server(message),
            })?;
        Ok(payload
            .get("data")
            .and_then(|data| data.get("myEnrollment"))
            .filter(|row| !row.is_null())
            .and_then(Self::parse))
    }

    fn my_learning_runs(
        &self,
        token: Option<&str>,
    ) -> Result<Vec<MyLearningRunRow>, crate::list::EventsError> {
        let payload = self
            .client
            .post(token, MY_LEARNING_RUNS_QUERY, serde_json::json!({}))
            .map_err(|error: ApiError| match error {
                ApiError::Transport(reason) => crate::list::EventsError::Transport(reason),
                ApiError::Timeout(reason) => {
                    crate::list::EventsError::Transport(format!("timeout: {reason}"))
                }
                ApiError::Unauthorized => crate::list::EventsError::Unauthorized,
                ApiError::Graphql { message, .. } => crate::list::EventsError::Server(message),
            })?;
        let rows = payload
            .get("data")
            .and_then(|data| data.get("myLearningRuns"))
            .ok_or_else(|| {
                crate::list::EventsError::Server("missing myLearningRuns".to_string())
            })?;
        Ok(rows
            .as_array()
            .map(|runs| runs.iter().filter_map(Self::parse_run).collect())
            .unwrap_or_default())
    }
}

pub struct FakeEnrollmentsApi;

impl EnrollmentsApi for FakeEnrollmentsApi {
    fn my_enrollments_page(
        &self,
        _token: Option<&str>,
        _after: Option<&str>,
    ) -> Result<MyEnrollmentsPage, crate::list::EventsError> {
        let rows = vec![
            MyEnrollmentRow {
                id: "enr-1".to_string(),
                workspace_id: "ws-2046".to_string(),
                status: "confirmed".to_string(),
                target_title: Some("示例场次".to_string()),
                starts_at: Some("2026-11-01T10:00:00Z".to_string()),
                event_id: Some("evt-001".to_string()),
                course_id: None,
                payment_mode: None,
                check_in_code: Some("123456".to_string()),
            },
            MyEnrollmentRow {
                id: "enr-2".to_string(),
                workspace_id: "ws-demo".to_string(),
                status: "confirmed".to_string(),
                target_title: Some("示例课程".to_string()),
                starts_at: None,
                event_id: None,
                course_id: Some("crs-002".to_string()),
                payment_mode: Some("paid".to_string()),
                check_in_code: None,
            },
            MyEnrollmentRow {
                id: "enr-3".to_string(),
                workspace_id: "ws-demo".to_string(),
                status: "payment_pending".to_string(),
                target_title: Some("待支付课程".to_string()),
                starts_at: None,
                event_id: None,
                course_id: Some("crs-004".to_string()),
                payment_mode: Some("paid".to_string()),
                check_in_code: None,
            },
        ];
        Ok(MyEnrollmentsPage {
            total: Some(rows.len() as i64),
            rows,
            next_cursor: None,
        })
    }

    fn my_enrollment_for_course(
        &self,
        _token: Option<&str>,
        course_id: &str,
    ) -> Result<Option<MyEnrollmentRow>, crate::list::EventsError> {
        Ok(self
            .my_enrollments_page(None, None)?
            .rows
            .into_iter()
            .find(|row| row.course_id.as_deref() == Some(course_id)))
    }

    fn my_learning_runs(
        &self,
        _token: Option<&str>,
    ) -> Result<Vec<MyLearningRunRow>, crate::list::EventsError> {
        Ok(vec![MyLearningRunRow {
            run_id: "run-1".to_string(),
            enrollment_id: "enr-2".to_string(),
            course_id: "crs-002".to_string(),
            target_title: Some("示例课程".to_string()),
            status: "active".to_string(),
            stale_revision: true,
            progress: LearningProgress {
                mastered_required: 2,
                total_required: 4,
                complete: false,
            },
            next_action: Some(LearningNextAction {
                kind: "review".to_string(),
                objective_id: "obj-1".to_string(),
                reason: "复习到期".to_string(),
            }),
        }])
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::TcpListener;

    /// 单次 GraphQL 响应夹具；返回端点与「服务端收到的请求体」。
    fn serve_once(body: String) -> (String, std::thread::JoinHandle<Value>) {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let addr = listener.local_addr().expect("addr");
        let handle = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept");
            let mut request = Vec::new();
            let mut buffer = [0u8; 4096];
            let header_end = loop {
                let read = stream.read(&mut buffer).expect("read");
                if read == 0 {
                    break request.len();
                }
                request.extend_from_slice(&buffer[..read]);
                if let Some(pos) = request.windows(4).position(|w| w == b"\r\n\r\n") {
                    break pos + 4;
                }
            };
            let headers = String::from_utf8_lossy(&request[..header_end]).to_string();
            let content_length = headers
                .lines()
                .find_map(|line| {
                    let (name, value) = line.split_once(':')?;
                    name.eq_ignore_ascii_case("content-length")
                        .then(|| value.trim().parse::<usize>().ok())
                        .flatten()
                })
                .unwrap_or(0);
            while request.len() < header_end + content_length {
                let read = stream.read(&mut buffer).expect("read body");
                if read == 0 {
                    break;
                }
                request.extend_from_slice(&buffer[..read]);
            }
            let request: Value = serde_json::from_slice(&request[header_end..]).expect("json body");
            let response = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
            stream.write_all(response.as_bytes()).expect("write");
            request
        });
        (format!("http://{addr}/api/graphql"), handle)
    }

    #[test]
    fn http_parses_my_enrollments() {
        let (endpoint, server) = serve_once(
            r#"{"data":{"myEnrollments":{"count":1,"results":[{"id":"enr-1","workspaceId":"ws-own","status":"confirmed","targetTitle":"场次 A","startsAt":"2026-11-01T10:00:00Z","eventId":"evt-1","courseId":null,"paymentMode":null,"checkInCode":"123456"}]}}}"#
                .to_string(),
        );
        let api = HttpEnrollmentsApi::new(GraphqlClient::new(endpoint));
        let rows = api.my_enrollments(Some("token")).expect("rows");
        let request = server.join().expect("fixture");
        assert!(request["query"].as_str().unwrap().contains("myEnrollments"));
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].target_title.as_deref(), Some("场次 A"));
        assert_eq!(rows[0].check_in_code.as_deref(), Some("123456"));
        assert_eq!(rows[0].workspace_id, "ws-own");
    }

    #[test]
    fn http_my_enrollments_page_uses_after_and_reports_next_cursor() {
        let (endpoint, server) = serve_once(
            r#"{"data":{"myEnrollments":{"count":260,"endKeyset":"cursor-2","results":[{"id":"enr-1","workspaceId":"ws-own","status":"confirmed","targetTitle":"场次 A","startsAt":null,"eventId":"evt-1","courseId":null,"paymentMode":null,"checkInCode":null}]}}}"#
                .to_string(),
        );
        let api = HttpEnrollmentsApi::new(GraphqlClient::new(endpoint));
        let page = api
            .my_enrollments_page(Some("token"), Some("cursor-1"))
            .expect("page");
        let request = server.join().expect("fixture");
        assert_eq!(request["variables"]["first"], 250);
        assert_eq!(request["variables"]["after"], "cursor-1");
        assert!(request["query"]
            .as_str()
            .unwrap()
            .contains("endKeyset"));
        assert_eq!(page.rows.len(), 1);
        assert_eq!(page.total, Some(260));
        assert_eq!(page.next_cursor.as_deref(), Some("cursor-2"));
        assert!(page.pagination().next_cursor.is_some());
    }

    #[test]
    fn has_more_enrollments_prefers_total_over_cursor_existence() {
        let meta = |total: Option<i64>, next: Option<&str>| EnrollmentPaginationMeta {
            total,
            next_cursor: next.map(str::to_string),
        };
        assert!(!has_more_enrollments(None, 0));
        assert!(has_more_enrollments(Some(&meta(Some(260), Some("c"))), 250));
        assert!(
            !has_more_enrollments(Some(&meta(Some(250), Some("c"))), 250),
            "count 已全部加载时不得继续显示加载更多"
        );
        assert!(!has_more_enrollments(Some(&meta(None, None)), 0));
        assert!(
            has_more_enrollments(Some(&meta(None, Some("c"))), 10),
            "缺 count 时 cursor 是唯一分页依据"
        );
    }

    #[test]
    fn http_my_enrollment_for_course_parses_single_row() {
        let (endpoint, server) = serve_once(
            r#"{"data":{"myEnrollment":{"id":"enr-9","workspaceId":"ws-owner","status":"confirmed","targetTitle":"课程 A","startsAt":null,"eventId":null,"courseId":"crs-9","paymentMode":null,"checkInCode":null}}}"#
                .to_string(),
        );
        let api = HttpEnrollmentsApi::new(GraphqlClient::new(endpoint));
        let row = api
            .my_enrollment_for_course(Some("token"), "crs-9")
            .expect("lookup")
            .expect("row");
        let request = server.join().expect("fixture");
        assert_eq!(request["variables"]["offeringId"], "crs-9");
        assert!(request["query"].as_str().unwrap().contains("myEnrollment("));
        assert_eq!(row.id, "enr-9");
        assert_eq!(row.workspace_id, "ws-owner");
    }

    fn enrollment_row(id: &str, course_id: Option<&str>, workspace_id: &str) -> MyEnrollmentRow {
        MyEnrollmentRow {
            id: id.to_string(),
            workspace_id: workspace_id.to_string(),
            status: "confirmed".to_string(),
            target_title: None,
            starts_at: None,
            event_id: None,
            course_id: course_id.map(str::to_string),
            payment_mode: None,
            check_in_code: None,
        }
    }

    fn learning_run(enrollment_id: &str, course_id: &str) -> MyLearningRunRow {
        MyLearningRunRow {
            run_id: "run-1".to_string(),
            enrollment_id: enrollment_id.to_string(),
            course_id: course_id.to_string(),
            target_title: None,
            status: "active".to_string(),
            stale_revision: false,
            progress: LearningProgress {
                mastered_required: 0,
                total_required: 1,
                complete: false,
            },
            next_action: None,
        }
    }

    #[test]
    fn enrollment_for_run_prefers_enrollment_id() {
        let rows = vec![
            enrollment_row("enr-other", Some("crs-1"), "ws-wrong"),
            enrollment_row("enr-1", None, "ws-own"),
        ];
        let found = enrollment_for_run(&rows, &learning_run("enr-1", "crs-1")).expect("by id");
        assert_eq!(found.workspace_id, "ws-own");
    }

    #[test]
    fn enrollment_for_run_falls_back_to_course_owner_row() {
        // 分页只加载了部分报名；补查按 course_id 追加的 confirmed 行应兜底工作区归属。
        let rows = vec![enrollment_row("enr-supplemented", Some("crs-9"), "ws-owner")];
        let found = enrollment_for_run(&rows, &learning_run("enr-missing", "crs-9"))
            .expect("补查行必须按 course_id 兜底");
        assert_eq!(found.workspace_id, "ws-owner");
    }

    #[test]
    fn http_parses_learning_runs_with_progress_and_next_action() {
        let (endpoint, server) = serve_once(
            r#"{"data":{"myLearningRuns":[{"runId":"run-1","enrollmentId":"enr-2","courseId":"crs-2","targetTitle":"课程 A","status":"active","staleRevision":true,"progress":{"masteredRequired":2,"totalRequired":4,"complete":false},"nextAction":{"kind":"review","objectiveId":"obj-1","reason":"复习到期"}},{"runId":"run-2","enrollmentId":"enr-3","courseId":"crs-3","targetTitle":"课程 B","status":"active","staleRevision":false,"progress":{"masteredRequired":3,"totalRequired":3,"complete":true},"nextAction":null}]}}"#
                .to_string(),
        );
        let api = HttpEnrollmentsApi::new(GraphqlClient::new(endpoint));
        let runs = api.my_learning_runs(Some("token")).expect("runs");
        let request = server.join().expect("fixture");
        let document = request["query"].as_str().unwrap();
        for field in [
            "myLearningRuns",
            "staleRevision",
            "masteredRequired",
            "nextAction",
        ] {
            assert!(document.contains(field), "query must select {field}");
        }
        assert_eq!(runs.len(), 2);
        assert_eq!(runs[0].progress.mastered_required, 2);
        assert_eq!(runs[0].progress.total_required, 4);
        assert!(!runs[0].progress.complete);
        assert!(runs[0].stale_revision);
        assert_eq!(
            runs[0]
                .next_action
                .as_ref()
                .map(|action| action.kind.as_str()),
            Some("review")
        );
        assert!(runs[1].progress.complete);
        assert!(runs[1].next_action.is_none());
    }

    #[test]
    fn fake_has_confirmed_and_pending_rows() {
        let rows = FakeEnrollmentsApi.my_enrollments(None).expect("rows");
        assert_eq!(rows.len(), 3);
        assert!(rows.iter().any(|row| row.status == "confirmed"));
        assert!(rows.iter().any(|row| row.status == "payment_pending"));
    }
}
