//! 课程目录 → 详情 → 学习页壳（story 4.1）。
//!
//! - `CoursesApi`：真实 GraphQL（listCourses / getCourse / myEnrollment / courseLearningDetail）
//!   与 fake 数据（本地开发）；
//! - 详情携带本人报名状态与 `revisionNumber`，学习入口按报名状态显示；
//! - 学习页通过 `CourseContextPort` 校验上下文，缺失时 fail-closed 给引导。

use std::sync::Arc;

use cgc_platform::api::{apply_workspace_scope, ApiError, GraphqlClient};
use cgc_platform::workspace::WorkspaceScope;
use cgc_platform::workspace::{
    ContextError, CourseContext, CourseContextPort, CourseContextProvider,
};
use serde_json::{json, Value};

use crate::content::CourseContent;

const LIST_COURSES_QUERY: &str = r#"
query ListCourses($first: Int!, $after: String, $filter: CourseFilterInput) {
  listCourses(first: $first, after: $after, filter: $filter) {
    count
    endKeyset
    results { id title status visibility registrationDeadline startsAt endsAt pricingEnabled }
  }
}
"#;

const GET_COURSE_QUERY: &str = r#"
query GetCourse($id: ID!) {
  getCourse(id: $id) {
    id workspaceId title description status visibility enrollmentPolicy
    registrationDeadline startsAt endsAt pricingEnabled availablePriceTiers
  }
}
"#;

const MY_ENROLLMENT_QUERY: &str = r#"
query MyEnrollment($offeringId: ID!) {
  myEnrollment(kind: "course", offeringId: $offeringId) { id status }
}
"#;

const COURSE_LEARNING_QUERY: &str = r#"
query CourseLearning($courseId: ID!) {
  courseLearningDetail(courseId: $courseId) { courseId title revisionNumber staleRevision }
}
"#;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CourseSummary {
    pub id: String,
    pub title: String,
    pub status: String,
    pub workspace_id: Option<String>,
    pub pricing_enabled: bool,
    pub starts_at: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CoursePage {
    pub items: Vec<CourseSummary>,
    pub next_cursor: Option<String>,
    pub total: Option<i64>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CourseDetail {
    pub id: String,
    pub title: String,
    pub description: Option<String>,
    pub status: String,
    pub visibility: String,
    pub workspace_id: Option<String>,
    pub pricing_enabled: bool,
    /// 本人报名状态（confirmed/pending/...；None = 未报名或未登录）。
    pub enrollment_status: Option<String>,
    /// 学习 revision；None 表示后端没有可用学习数据（学习页 fail-closed 引导）。
    pub revision_number: Option<i64>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CoursesError {
    Transport(String),
    Server(String),
    NotFound,
}

impl From<ApiError> for CoursesError {
    fn from(error: ApiError) -> Self {
        match error {
            ApiError::Transport(reason) => CoursesError::Transport(reason),
            ApiError::Timeout(reason) => CoursesError::Transport(format!("timeout: {reason}")),
            ApiError::Graphql { message, .. } => CoursesError::Server(message),
        }
    }
}

impl CoursesError {
    pub fn diagnostic(&self) -> String {
        match self {
            CoursesError::Transport(reason) => format!("transport error: {reason}"),
            CoursesError::Server(reason) => format!("server error: {reason}"),
            CoursesError::NotFound => "not found".to_string(),
        }
    }
}

pub trait CoursesApi: Send + Sync {
    fn list_courses(
        &self,
        token: Option<&str>,
        scope: Option<&WorkspaceScope>,
        after: Option<&str>,
        first: u32,
    ) -> Result<CoursePage, CoursesError>;
    fn get_course(&self, token: Option<&str>, id: &str) -> Result<CourseDetail, CoursesError>;
    /// 已发布课程正文；未报名 / 课程不存在 / 未发布 → `CoursesError::NotFound`。
    fn get_course_content(
        &self,
        token: Option<&str>,
        course_id: &str,
    ) -> Result<CourseContent, CoursesError>;
}

pub struct HttpCoursesApi {
    client: GraphqlClient,
}

impl HttpCoursesApi {
    pub fn new(client: GraphqlClient) -> Self {
        Self { client }
    }

    pub fn from_env() -> Self {
        Self::new(GraphqlClient::from_env())
    }

    fn parse_summary(value: &Value) -> Option<CourseSummary> {
        Some(CourseSummary {
            id: value.get("id")?.as_str()?.to_string(),
            title: value.get("title")?.as_str()?.to_string(),
            status: value.get("status")?.as_str().unwrap_or("open").to_string(),
            workspace_id: value
                .get("workspaceId")
                .and_then(Value::as_str)
                .map(str::to_string),
            pricing_enabled: value
                .get("pricingEnabled")
                .and_then(Value::as_bool)
                .unwrap_or(false),
            starts_at: value
                .get("startsAt")
                .and_then(Value::as_str)
                .map(str::to_string),
        })
    }
}

impl CoursesApi for HttpCoursesApi {
    fn list_courses(
        &self,
        token: Option<&str>,
        scope: Option<&WorkspaceScope>,
        after: Option<&str>,
        first: u32,
    ) -> Result<CoursePage, CoursesError> {
        let mut variables = json!({ "first": first });
        if let Some(after) = after {
            variables["after"] = json!(after);
        }
        apply_workspace_scope(&mut variables, scope);
        let payload = self
            .client
            .post(token, LIST_COURSES_QUERY, variables)
            .map_err(CoursesError::from)?;
        let page = payload
            .get("data")
            .and_then(|data| data.get("listCourses"))
            .ok_or_else(|| CoursesError::Server("missing listCourses payload".to_string()))?;

        Ok(CoursePage {
            items: page
                .get("results")
                .and_then(Value::as_array)
                .map(|results| results.iter().filter_map(Self::parse_summary).collect())
                .unwrap_or_default(),
            next_cursor: page
                .get("endKeyset")
                .and_then(Value::as_str)
                .filter(|cursor| !cursor.is_empty())
                .map(str::to_string),
            total: page.get("count").and_then(Value::as_i64),
        })
    }

    fn get_course(&self, token: Option<&str>, id: &str) -> Result<CourseDetail, CoursesError> {
        let payload = self
            .client
            .post(token, GET_COURSE_QUERY, json!({ "id": id }))
            .map_err(CoursesError::from)?;
        let value = payload
            .get("data")
            .and_then(|data| data.get("getCourse"))
            .filter(|value| !value.is_null())
            .ok_or(CoursesError::NotFound)?;

        let enrollment_status = self
            .client
            .post(token, MY_ENROLLMENT_QUERY, json!({ "offeringId": id }))
            .ok()
            .and_then(|payload| {
                payload
                    .get("data")
                    .and_then(|data| data.get("myEnrollment"))
                    .and_then(|enrollment| enrollment.get("status"))
                    .and_then(Value::as_str)
                    .map(str::to_string)
            });

        let revision_number = self
            .client
            .post(token, COURSE_LEARNING_QUERY, json!({ "courseId": id }))
            .ok()
            .and_then(|payload| {
                payload
                    .get("data")
                    .and_then(|data| data.get("courseLearningDetail"))
                    .and_then(|detail| detail.get("revisionNumber"))
                    .and_then(Value::as_i64)
            });

        let id = value
            .get("id")
            .and_then(Value::as_str)
            .ok_or_else(|| CoursesError::Server("missing course id".to_string()))?
            .to_string();
        let title = value
            .get("title")
            .and_then(Value::as_str)
            .ok_or_else(|| CoursesError::Server("missing course title".to_string()))?
            .to_string();
        Ok(CourseDetail {
            id,
            title,
            description: value
                .get("description")
                .and_then(Value::as_str)
                .map(str::to_string),
            status: value
                .get("status")
                .and_then(Value::as_str)
                .unwrap_or("open")
                .to_string(),
            visibility: value
                .get("visibility")
                .and_then(Value::as_str)
                .unwrap_or("public")
                .to_string(),
            workspace_id: value
                .get("workspaceId")
                .and_then(Value::as_str)
                .map(str::to_string),
            pricing_enabled: value
                .get("pricingEnabled")
                .and_then(Value::as_bool)
                .unwrap_or(false),
            enrollment_status,
            revision_number,
        })
    }

    fn get_course_content(
        &self,
        token: Option<&str>,
        course_id: &str,
    ) -> Result<CourseContent, CoursesError> {
        crate::content::fetch_course_content(&self.client, token, course_id)
    }
}

pub struct FakeCoursesApi {
    courses: Vec<CourseSummary>,
    fail: bool,
}

impl FakeCoursesApi {
    pub fn with_seed(count: usize) -> Self {
        let courses = (0..count)
            .map(|index| CourseSummary {
                id: format!("crs-{index:03}"),
                title: format!("课程 {}", index + 1),
                status: "open".to_string(),
                workspace_id: Some("ws-demo".to_string()),
                pricing_enabled: index % 3 == 0,
                starts_at: Some(format!("2026-12-{:02}T09:00:00Z", (index % 28) + 1)),
            })
            .collect();
        Self {
            courses,
            fail: false,
        }
    }

    pub fn failing() -> Self {
        Self {
            courses: Vec::new(),
            fail: true,
        }
    }
}

impl Default for FakeCoursesApi {
    fn default() -> Self {
        Self::with_seed(15)
    }
}

fn fake_index(id: &str) -> Option<usize> {
    id.rsplit('-').next()?.parse().ok()
}

impl CoursesApi for FakeCoursesApi {
    fn list_courses(
        &self,
        _token: Option<&str>,
        _scope: Option<&WorkspaceScope>,
        after: Option<&str>,
        first: u32,
    ) -> Result<CoursePage, CoursesError> {
        if self.fail {
            return Err(CoursesError::Transport("fake network down".to_string()));
        }
        let start = after
            .and_then(|cursor| cursor.parse::<usize>().ok())
            .unwrap_or(0);
        let end = (start + first as usize).min(self.courses.len());
        Ok(CoursePage {
            items: self.courses.get(start..end).unwrap_or_default().to_vec(),
            next_cursor: (end < self.courses.len()).then(|| end.to_string()),
            total: Some(self.courses.len() as i64),
        })
    }

    fn get_course(&self, _token: Option<&str>, id: &str) -> Result<CourseDetail, CoursesError> {
        if self.fail {
            return Err(CoursesError::Transport("fake network down".to_string()));
        }
        let summary = self
            .courses
            .iter()
            .find(|course| course.id == id)
            .ok_or(CoursesError::NotFound)?;
        let index = fake_index(&summary.id).unwrap_or(0);
        let enrolled = index.is_multiple_of(2);
        Ok(CourseDetail {
            id: summary.id.clone(),
            title: summary.title.clone(),
            description: Some(format!("{} 的课程详情（fake 数据）", summary.title)),
            status: summary.status.clone(),
            visibility: "public".to_string(),
            workspace_id: summary.workspace_id.clone(),
            pricing_enabled: summary.pricing_enabled,
            enrollment_status: enrolled.then(|| "confirmed".to_string()),
            revision_number: enrolled.then(|| (index as i64) + 1),
        })
    }

    fn get_course_content(
        &self,
        _token: Option<&str>,
        id: &str,
    ) -> Result<CourseContent, CoursesError> {
        if self.fail {
            return Err(CoursesError::Transport("fake network down".to_string()));
        }
        let summary = self
            .courses
            .iter()
            .find(|course| course.id == id)
            .ok_or(CoursesError::NotFound)?;
        let index = fake_index(&summary.id).unwrap_or(0);
        if !index.is_multiple_of(2) {
            return Err(CoursesError::NotFound);
        }
        Ok(crate::content::fake_course_content(
            &summary.id,
            &summary.title,
            index,
        ))
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CoursesListState {
    Idle,
    Loading,
    Ready,
    Empty,
    Failed(String),
}

pub struct CourseCatalogService {
    api: Arc<dyn CoursesApi>,
    items: Vec<CourseSummary>,
    next_cursor: Option<String>,
    state: CoursesListState,
    loading_more: bool,
    total: Option<i64>,
}

impl CourseCatalogService {
    pub fn new(api: Arc<dyn CoursesApi>) -> Self {
        Self {
            api,
            items: Vec::new(),
            next_cursor: None,
            state: CoursesListState::Idle,
            loading_more: false,
            total: None,
        }
    }

    pub fn api_handle(&self) -> Arc<dyn CoursesApi> {
        Arc::clone(&self.api)
    }

    pub fn state(&self) -> &CoursesListState {
        &self.state
    }

    pub fn items(&self) -> &[CourseSummary] {
        &self.items
    }

    pub fn next_cursor(&self) -> Option<&str> {
        self.next_cursor.as_deref()
    }

    pub fn has_more(&self) -> bool {
        self.next_cursor.is_some()
            && self
                .total
                .is_none_or(|total| self.items.len() < total as usize)
    }

    pub fn begin_first_load(&mut self) {
        self.items.clear();
        self.next_cursor = None;
        self.loading_more = false;
        self.state = CoursesListState::Loading;
    }

    pub fn begin_load_more(&mut self) {
        self.loading_more = true;
        self.state = CoursesListState::Loading;
    }

    pub fn fetch(&self, token: Option<&str>) -> Result<CoursePage, CoursesError> {
        self.api.list_courses(
            token,
            None,
            if self.loading_more {
                self.next_cursor.as_deref()
            } else {
                None
            },
            10,
        )
    }

    pub fn adopt_page(&mut self, page: CoursePage) {
        if self.loading_more {
            self.items.extend(page.items);
        } else {
            self.items = page.items;
        }
        self.next_cursor = page.next_cursor;
        self.total = page.total;
        self.state = if self.items.is_empty() {
            CoursesListState::Empty
        } else {
            CoursesListState::Ready
        };
        self.loading_more = false;
    }

    pub fn fail(&mut self, error: &CoursesError) {
        self.state = CoursesListState::Failed(error.diagnostic());
        self.loading_more = false;
    }

    pub fn retry_ready(&mut self) {
        self.state = CoursesListState::Idle;
    }

    pub fn reset(&mut self) {
        self.items.clear();
        self.next_cursor = None;
        self.total = None;
        self.state = CoursesListState::Idle;
        self.loading_more = false;
    }
}

pub struct CourseDetailService {
    api: Arc<dyn CoursesApi>,
    detail: Option<CourseDetail>,
    state: CoursesListState,
}

impl CourseDetailService {
    pub fn new(api: Arc<dyn CoursesApi>) -> Self {
        Self {
            api,
            detail: None,
            state: CoursesListState::Idle,
        }
    }

    pub fn api_handle(&self) -> Arc<dyn CoursesApi> {
        Arc::clone(&self.api)
    }

    pub fn state(&self) -> &CoursesListState {
        &self.state
    }

    pub fn detail(&self) -> Option<&CourseDetail> {
        self.detail.as_ref()
    }

    pub fn begin_load(&mut self) {
        self.state = CoursesListState::Loading;
    }

    pub fn adopt(&mut self, detail: CourseDetail) {
        self.detail = Some(detail);
        self.state = CoursesListState::Ready;
    }

    pub fn fail(&mut self, error: &CoursesError) {
        self.state = CoursesListState::Failed(error.diagnostic());
    }

    pub fn retry_ready(&mut self) {
        self.state = CoursesListState::Idle;
    }

    pub fn reset(&mut self) {
        self.detail = None;
        self.state = CoursesListState::Idle;
    }
}

/// 学习页上下文：从课程详情 + 当前用户构造 `CourseContextPort`，缺失即错误。
pub fn learning_context(
    user_id: Option<String>,
    detail: &CourseDetail,
) -> Result<CourseContext, ContextError> {
    let provider = CourseContextProvider::from_parts(
        user_id,
        detail.workspace_id.clone(),
        Some(detail.id.clone()),
        detail.revision_number.map(|revision| revision.to_string()),
    );
    provider.current()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn catalog() -> CourseCatalogService {
        CourseCatalogService::new(Arc::new(FakeCoursesApi::with_seed(15)))
    }

    #[test]
    fn catalog_pages_and_appends() {
        let mut service = catalog();
        service.begin_first_load();
        service.adopt_page(service.fetch(None).expect("page 1"));
        assert_eq!(service.items().len(), 10);
        assert!(service.next_cursor().is_some());

        service.begin_load_more();
        service.adopt_page(service.fetch(None).expect("page 2"));
        assert_eq!(service.items().len(), 15);
        assert!(service.next_cursor().is_none());
    }

    #[test]
    fn http_list_courses_injects_workspace_scope() {
        use std::io::{Read, Write};
        use std::net::TcpListener;

        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let addr = listener.local_addr().expect("addr");
        let (sender, receiver) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
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
            let _ = sender.send(String::from_utf8_lossy(&request).to_string());
            let body = r#"{"data":{"listCourses":{"count":0,"endKeyset":null,"results":[]}}}"#;
            let response = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
            stream.write_all(response.as_bytes()).expect("write");
        });

        let api = HttpCoursesApi::new(GraphqlClient::new(format!("http://{addr}/api/graphql")));
        let scope = WorkspaceScope {
            workspace_id: "ws-9".into(),
            epoch: 2,
        };
        let _ = api
            .list_courses(None, Some(&scope), None, 10)
            .expect("page");
        let sent = receiver.recv().expect("request");
        assert!(sent.contains("ListCourses"));
        assert!(sent.contains(r#""workspaceId""#), "scope missing: {sent}");
        assert!(sent.contains("ws-9"));
    }

    #[test]
    fn catalog_empty_and_failure_states() {
        let mut empty = CourseCatalogService::new(Arc::new(FakeCoursesApi::with_seed(0)));
        empty.begin_first_load();
        empty.adopt_page(empty.fetch(None).expect("empty"));
        assert_eq!(empty.state(), &CoursesListState::Empty);

        let mut failing = CourseCatalogService::new(Arc::new(FakeCoursesApi::failing()));
        failing.begin_first_load();
        let error = failing.fetch(None).unwrap_err();
        failing.fail(&error);
        assert!(matches!(failing.state(), CoursesListState::Failed(_)));
        failing.retry_ready();
        assert_eq!(failing.state(), &CoursesListState::Idle);
    }

    #[test]
    fn has_more_uses_total_not_cursor() {
        let mut service = catalog();
        service.begin_first_load();
        service.adopt_page(service.fetch(None).expect("page 1"));
        assert!(service.has_more(), "15 items, first page of 10");

        while service.next_cursor().is_some() {
            service.begin_load_more();
            service.adopt_page(service.fetch(None).expect("next page"));
        }
        assert!(!service.has_more(), "all items loaded");
    }

    #[test]
    fn enrolled_course_has_confirmed_status_and_revision() {
        let api: Arc<dyn CoursesApi> = Arc::new(FakeCoursesApi::with_seed(4));
        let detail = api.get_course(None, "crs-002").expect("detail");
        assert_eq!(detail.enrollment_status.as_deref(), Some("confirmed"));
        assert_eq!(detail.revision_number, Some(3));
    }

    #[test]
    fn unenrolled_course_has_no_revision_and_context_fails_closed() {
        let api: Arc<dyn CoursesApi> = Arc::new(FakeCoursesApi::with_seed(4));
        let detail = api.get_course(None, "crs-001").expect("detail");
        assert!(detail.enrollment_status.is_none());
        assert_eq!(
            learning_context(Some("u-1".to_string()), &detail),
            Err(ContextError::MissingRevision)
        );
    }

    #[test]
    fn learning_context_ok_for_enrolled_course() {
        let api: Arc<dyn CoursesApi> = Arc::new(FakeCoursesApi::with_seed(4));
        let detail = api.get_course(None, "crs-002").expect("detail");
        let context = learning_context(Some("u-1".to_string()), &detail).expect("context");
        assert_eq!(context.workspace_id, "ws-demo");
        assert_eq!(context.course_revision_id, "3");
        assert_eq!(context.user_id, "u-1");
    }
}
