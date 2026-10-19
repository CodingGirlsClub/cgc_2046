//! 课程正文（story 4.2）：`courseContent` 的传输、JsonString 文档解析与内容状态机。
//!
//! - `fetch_course_content` 复用 `platform::api::GraphqlClient`，只取本 story 需要的字段；
//! - `parse_course_content` 对非法 JSON 与未知字段容错：坏数据一律空文档、未知材质
//!   kind 降级为 [`MaterialKind::Unknown`]，绝不 panic；
//! - `CourseContentService`：UI 可观察的 idle/loading/ready/empty/failed 状态。

use std::sync::Arc;

use cgc_platform::api::GraphqlClient;
use serde_json::{json, Value};

use crate::catalog::{CoursesApi, CoursesError};

const COURSE_CONTENT_QUERY: &str = r#"
query CourseContent($courseId: ID!) {
  courseContent(courseId: $courseId) {
    courseId
    title
    description
    revisionNumber
    publishedAt
    content
  }
}
"#;

/// 课程正文（`courseContent` 的 GraphQL 响应 + 解析后的内容文档）。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CourseContent {
    pub course_id: String,
    pub title: String,
    pub description: Option<String>,
    pub revision_number: Option<i64>,
    pub published_at: Option<String>,
    pub document: CourseContentDocument,
}

/// `content` JsonString 中本 story 消费的结构；其余字段忽略。
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct CourseContentDocument {
    pub goals: Vec<String>,
    pub chapters: Vec<CourseChapter>,
    pub issues: Vec<CourseIssue>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CourseChapter {
    pub id: Option<String>,
    pub title: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CourseIssue {
    pub id: Option<String>,
    pub title: Option<String>,
    pub kind: Option<String>,
    pub story_materials: Vec<TypedMaterial>,
    pub objective_materials: Vec<TypedMaterial>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TypedMaterial {
    pub kind: MaterialKind,
    pub title: Option<String>,
    /// 仅 text/markdown 有正文；web/image/video 本 story 只保留 kind/title。
    pub body: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum MaterialKind {
    Text,
    Markdown,
    Web,
    Image,
    Video,
    Unknown(String),
}

impl CourseContentDocument {
    /// 无目标、无章节、任何 issue 下都无材料 ≈ 没有可渲染正文。
    pub fn is_empty(&self) -> bool {
        self.goals.is_empty()
            && self.chapters.is_empty()
            && self.issues.iter().all(|issue| {
                issue.story_materials.is_empty() && issue.objective_materials.is_empty()
            })
    }
}

/// 解析 `courseContent.content`（JsonString）。非法 JSON / 非对象 / 空串 → 空文档。
pub fn parse_course_content(raw: &str) -> CourseContentDocument {
    let Ok(value) = serde_json::from_str::<Value>(raw) else {
        return CourseContentDocument::default();
    };
    let Some(root) = value.as_object() else {
        return CourseContentDocument::default();
    };

    CourseContentDocument {
        goals: root
            .get("goals")
            .and_then(Value::as_array)
            .map(|goals| {
                goals
                    .iter()
                    .filter_map(Value::as_str)
                    .map(str::to_string)
                    .collect()
            })
            .unwrap_or_default(),
        chapters: root
            .get("chapters")
            .and_then(Value::as_array)
            .map(|chapters| chapters.iter().filter_map(parse_chapter).collect())
            .unwrap_or_default(),
        issues: root
            .get("issues")
            .and_then(Value::as_array)
            .map(|issues| issues.iter().filter_map(parse_issue).collect())
            .unwrap_or_default(),
    }
}

fn parse_chapter(value: &Value) -> Option<CourseChapter> {
    value.as_object()?;
    Some(CourseChapter {
        id: string_field(value, "id"),
        title: string_field(value, "title"),
    })
}

fn parse_issue(value: &Value) -> Option<CourseIssue> {
    value.as_object()?;
    let story_materials = value
        .get("story")
        .and_then(|story| story.get("materials"))
        .and_then(Value::as_array)
        .map(|materials| materials.iter().filter_map(parse_material).collect())
        .unwrap_or_default();
    let objective_materials = value
        .get("objectives")
        .and_then(Value::as_array)
        .map(|objectives| {
            objectives
                .iter()
                .filter_map(|objective| objective.get("materials"))
                .filter_map(Value::as_array)
                .flat_map(|materials| materials.iter())
                .filter_map(parse_material)
                .collect()
        })
        .unwrap_or_default();

    Some(CourseIssue {
        id: string_field(value, "id"),
        title: string_field(value, "title"),
        kind: string_field(value, "kind"),
        story_materials,
        objective_materials,
    })
}

fn parse_material(value: &Value) -> Option<TypedMaterial> {
    value.as_object()?;
    let kind = match string_field(value, "kind").as_deref() {
        Some("text") => MaterialKind::Text,
        Some("markdown") => MaterialKind::Markdown,
        Some("web") => MaterialKind::Web,
        Some("image") => MaterialKind::Image,
        Some("video") => MaterialKind::Video,
        Some(other) => MaterialKind::Unknown(other.to_string()),
        None => MaterialKind::Unknown(String::new()),
    };
    let body = match &kind {
        MaterialKind::Text | MaterialKind::Markdown => string_field(value, "body"),
        _ => None,
    };
    Some(TypedMaterial {
        kind,
        title: string_field(value, "title"),
        body,
    })
}

fn string_field(value: &Value, key: &str) -> Option<String> {
    value.get(key).and_then(Value::as_str).map(str::to_string)
}

/// `HttpCoursesApi` 的 `get_course_content` 实现（传输细节留在 content 模块）。
pub(crate) fn fetch_course_content(
    client: &GraphqlClient,
    token: Option<&str>,
    course_id: &str,
) -> Result<CourseContent, CoursesError> {
    let payload = client
        .post(
            token,
            COURSE_CONTENT_QUERY,
            json!({ "courseId": course_id }),
        )
        .map_err(CoursesError::from)?;
    let value = payload
        .get("data")
        .and_then(|data| data.get("courseContent"))
        .filter(|value| !value.is_null())
        .ok_or(CoursesError::NotFound)?;

    let raw = value
        .get("content")
        .and_then(Value::as_str)
        .unwrap_or_default();
    Ok(CourseContent {
        course_id: value
            .get("courseId")
            .and_then(Value::as_str)
            .unwrap_or(course_id)
            .to_string(),
        title: value
            .get("title")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
        description: value
            .get("description")
            .and_then(Value::as_str)
            .map(str::to_string),
        revision_number: value.get("revisionNumber").and_then(Value::as_i64),
        published_at: value
            .get("publishedAt")
            .and_then(Value::as_str)
            .map(str::to_string),
        document: parse_course_content(raw),
    })
}

/// fake 数据：markdown 正文（标题/段落/强调/行内代码/rust 代码块）+ web 材料。
pub(crate) fn fake_course_content(course_id: &str, title: &str, index: usize) -> CourseContent {
    CourseContent {
        course_id: course_id.to_string(),
        title: title.to_string(),
        description: Some(format!("{title} 的课程正文（fake 数据）")),
        revision_number: Some(index as i64 + 1),
        published_at: Some("2026-10-01T09:00:00Z".to_string()),
        document: CourseContentDocument {
            goals: vec![format!("完成「{title}」的正文阅读")],
            chapters: vec![CourseChapter {
                id: Some("ch-1".to_string()),
                title: Some("第一章：开始".to_string()),
            }],
            issues: vec![CourseIssue {
                id: Some("issue-1".to_string()),
                title: Some("第一次运行".to_string()),
                kind: Some("handwork".to_string()),
                story_materials: vec![
                    TypedMaterial {
                        kind: MaterialKind::Markdown,
                        title: Some("正文".to_string()),
                        body: Some(FAKE_MARKDOWN.to_string()),
                    },
                    TypedMaterial {
                        kind: MaterialKind::Web,
                        title: Some("延伸阅读".to_string()),
                        body: None,
                    },
                ],
                objective_materials: Vec::new(),
            }],
        },
    }
}

const FAKE_MARKDOWN: &str = r#"# 标题

这是一个段落，包含 **bold** 与 `inline code`。

```rust
fn main() {
    println!("你好，CGC");
}
```
"#;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CourseContentState {
    Idle,
    Loading,
    Ready,
    Empty,
    Failed(String),
}

pub struct CourseContentService {
    api: Arc<dyn CoursesApi>,
    course_id: Option<String>,
    content: Option<CourseContent>,
    state: CourseContentState,
}

impl CourseContentService {
    pub fn new(api: Arc<dyn CoursesApi>) -> Self {
        Self {
            api,
            course_id: None,
            content: None,
            state: CourseContentState::Idle,
        }
    }

    pub fn api_handle(&self) -> Arc<dyn CoursesApi> {
        Arc::clone(&self.api)
    }

    pub fn state(&self) -> &CourseContentState {
        &self.state
    }

    pub fn content(&self) -> Option<&CourseContent> {
        self.content.as_ref()
    }

    pub fn course_id(&self) -> Option<&str> {
        self.course_id.as_deref()
    }

    /// 换课/重试前清掉旧正文，避免加载期间渲染上一门课的内容。
    pub fn begin_load(&mut self, course_id: &str) {
        self.course_id = Some(course_id.to_string());
        self.content = None;
        self.state = CourseContentState::Loading;
    }

    pub fn adopt(&mut self, content: CourseContent) {
        self.state = if content.document.is_empty() {
            CourseContentState::Empty
        } else {
            CourseContentState::Ready
        };
        self.content = Some(content);
    }

    pub fn fail(&mut self, error: &CoursesError) {
        self.state = CourseContentState::Failed(error.diagnostic());
    }

    pub fn retry_ready(&mut self) {
        self.state = CourseContentState::Idle;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::sync::mpsc;

    use crate::catalog::{FakeCoursesApi, HttpCoursesApi};

    fn sample_document_json() -> String {
        serde_json::json!({
            "goals": ["能读懂 Markdown", "能运行示例"],
            "chapters": [{"id": "ch-1", "title": "第一章"}],
            "issues": [{
                "id": "issue-1",
                "title": "第一次运行",
                "kind": "handwork",
                "story": {
                    "goal": "跑起来",
                    "materials": [
                        {
                            "kind": "markdown",
                            "title": "正文",
                            "body": "# 标题\n\n段落 **bold** `code`"
                        },
                        {
                            "kind": "web",
                            "title": "延伸阅读",
                            "body": "web 不保留正文",
                            "url": "https://example.com"
                        }
                    ]
                },
                "objectives": [{
                    "id": "obj-1",
                    "title": "能运行",
                    "materials": [{"kind": "text", "title": "提示", "body": "先安装工具链"}]
                }],
                "unknown_field": true
            }],
            "extra": {"ignored": true}
        })
        .to_string()
    }

    /// 完整读取请求体（header + Content-Length）后回 GraphQL 响应；请求文本经 channel 交回断言。
    fn spawn_graphql_mock(body: String) -> (String, mpsc::Receiver<String>) {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let addr = listener.local_addr().expect("addr");
        let (sender, receiver) = mpsc::channel();
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
                if let Some(pos) = request.windows(4).position(|window| window == b"\r\n\r\n") {
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
            let response = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
            stream.write_all(response.as_bytes()).expect("write");
        });
        (format!("http://{addr}/api/graphql"), receiver)
    }

    #[test]
    fn parse_course_content_reads_goals_chapters_and_materials() {
        let document = parse_course_content(&sample_document_json());

        assert_eq!(
            document.goals,
            vec!["能读懂 Markdown".to_string(), "能运行示例".to_string()]
        );
        assert_eq!(document.chapters.len(), 1);
        assert_eq!(document.chapters[0].id.as_deref(), Some("ch-1"));
        assert_eq!(document.chapters[0].title.as_deref(), Some("第一章"));

        assert_eq!(document.issues.len(), 1);
        let issue = &document.issues[0];
        assert_eq!(issue.id.as_deref(), Some("issue-1"));
        assert_eq!(issue.title.as_deref(), Some("第一次运行"));
        assert_eq!(issue.kind.as_deref(), Some("handwork"));

        assert_eq!(issue.story_materials.len(), 2);
        assert_eq!(issue.story_materials[0].kind, MaterialKind::Markdown);
        assert_eq!(issue.story_materials[0].title.as_deref(), Some("正文"));
        let body = issue.story_materials[0]
            .body
            .as_deref()
            .expect("markdown body");
        assert!(body.contains("# 标题"));
        assert!(body.contains("**bold**"));
        assert!(body.contains("`code`"));
        assert_eq!(issue.story_materials[1].kind, MaterialKind::Web);
        assert_eq!(
            issue.story_materials[1].body, None,
            "only text/markdown keep body"
        );

        assert_eq!(issue.objective_materials.len(), 1);
        assert_eq!(issue.objective_materials[0].kind, MaterialKind::Text);
        assert_eq!(
            issue.objective_materials[0].body.as_deref(),
            Some("先安装工具链")
        );
        assert!(!document.is_empty());
    }

    #[test]
    fn parse_course_content_degrades_unknown_material_kind() {
        let raw = r#"{"issues":[{"story":{"materials":[{"kind":"audio","title":"录音"},{"title":"缺 kind"}]}}]}"#;
        let document = parse_course_content(raw);
        let material = &document.issues[0].story_materials[0];

        assert_eq!(material.kind, MaterialKind::Unknown("audio".to_string()));
        assert_eq!(material.title.as_deref(), Some("录音"));
        assert_eq!(material.body, None);
        assert_eq!(
            document.issues[0].story_materials[1].kind,
            MaterialKind::Unknown(String::new())
        );
        assert!(
            !document.is_empty(),
            "unknown material still counts as content"
        );
    }

    #[test]
    fn parse_course_content_invalid_json_is_empty() {
        for raw in ["", "not json", "[1,2,3]", "null", "42"] {
            assert_eq!(
                parse_course_content(raw),
                CourseContentDocument::default(),
                "raw: {raw}"
            );
            assert!(parse_course_content(raw).is_empty());
        }
    }

    #[test]
    fn http_api_requests_course_content_and_parses_document() {
        let content = serde_json::json!({
            "goals": ["读懂正文"],
            "chapters": [{"id": "ch-9", "title": "第九章"}],
            "issues": [{
                "id": "issue-9",
                "title": "运行示例",
                "kind": "handwork",
                "story": {
                    "materials": [{
                        "kind": "markdown",
                        "title": "正文",
                        "body": "# 标题\n\n段落"
                    }]
                },
                "objectives": [{
                    "materials": [{"kind": "text", "title": "提示", "body": "短文"}]
                }]
            }]
        })
        .to_string();
        let body = serde_json::json!({
            "data": {
                "courseContent": {
                    "courseId": "crs-002",
                    "title": "课程 3",
                    "description": "课程描述",
                    "revisionNumber": 3,
                    "publishedAt": "2026-10-01T09:00:00Z",
                    "content": content
                }
            }
        })
        .to_string();
        let (endpoint, request) = spawn_graphql_mock(body);
        let api = HttpCoursesApi::new(GraphqlClient::new(endpoint));

        let content = api
            .get_course_content(Some("token"), "crs-002")
            .expect("course content");

        assert_eq!(content.course_id, "crs-002");
        assert_eq!(content.title, "课程 3");
        assert_eq!(content.description.as_deref(), Some("课程描述"));
        assert_eq!(content.revision_number, Some(3));
        assert_eq!(
            content.published_at.as_deref(),
            Some("2026-10-01T09:00:00Z")
        );
        assert_eq!(content.document.goals, vec!["读懂正文".to_string()]);
        assert_eq!(content.document.issues.len(), 1);
        assert_eq!(
            content.document.issues[0].story_materials[0].kind,
            MaterialKind::Markdown
        );
        assert_eq!(
            content.document.issues[0].objective_materials[0]
                .body
                .as_deref(),
            Some("短文")
        );

        let request = request.recv().expect("request");
        assert!(request.contains("courseContent"), "request: {request}");
        assert!(request.contains(r#""courseId""#), "request: {request}");
        assert!(request.contains(r#""crs-002""#), "request: {request}");
    }

    #[test]
    fn http_api_missing_course_content_is_not_found() {
        let body = r#"{"data":{"courseContent":null}}"#.to_string();
        let (endpoint, _request) = spawn_graphql_mock(body);
        let api = HttpCoursesApi::new(GraphqlClient::new(endpoint));

        assert_eq!(
            api.get_course_content(None, "crs-404").unwrap_err(),
            CoursesError::NotFound
        );
    }

    #[test]
    fn http_api_maps_graphql_error_to_server_error() {
        let body =
            r#"{"errors":[{"message":"Not authenticated","code":"unauthorized"}]}"#.to_string();
        let (endpoint, _request) = spawn_graphql_mock(body);
        let api = HttpCoursesApi::new(GraphqlClient::new(endpoint));

        assert_eq!(
            api.get_course_content(None, "crs-002").unwrap_err(),
            CoursesError::Server("Not authenticated".to_string())
        );
    }

    #[test]
    fn fake_course_content_is_deterministic_for_enrolled_course() {
        let api: Arc<dyn CoursesApi> = Arc::new(FakeCoursesApi::with_seed(4));

        let content = api
            .get_course_content(None, "crs-002")
            .expect("fake content");

        assert_eq!(content.course_id, "crs-002");
        assert_eq!(content.title, "课程 3");
        assert_eq!(content.revision_number, Some(3));
        let materials = &content.document.issues[0].story_materials;
        assert_eq!(materials.len(), 2);
        assert_eq!(materials[0].kind, MaterialKind::Markdown);
        let body = materials[0].body.as_deref().expect("markdown body");
        assert!(body.contains("# 标题"));
        assert!(body.contains("这是一个段落"));
        assert!(body.contains("**bold**"));
        assert!(body.contains("`inline code`"));
        assert!(body.contains("```rust"));
        assert!(body.contains("println!"));
        assert_eq!(materials[1].kind, MaterialKind::Web);
        assert_eq!(materials[1].body, None);
    }

    #[test]
    fn fake_course_content_rejects_unenrolled_and_unknown_courses() {
        let api: Arc<dyn CoursesApi> = Arc::new(FakeCoursesApi::with_seed(4));

        assert_eq!(
            api.get_course_content(None, "crs-001").unwrap_err(),
            CoursesError::NotFound
        );
        assert_eq!(
            api.get_course_content(None, "crs-999").unwrap_err(),
            CoursesError::NotFound
        );
    }

    #[test]
    fn service_loads_and_adopts_content() {
        let api: Arc<dyn CoursesApi> = Arc::new(FakeCoursesApi::with_seed(4));
        let mut service = CourseContentService::new(api);

        service.begin_load("crs-002");
        assert_eq!(service.state(), &CourseContentState::Loading);
        assert_eq!(service.course_id(), Some("crs-002"));
        assert!(service.content().is_none());

        let content = service
            .api_handle()
            .get_course_content(None, "crs-002")
            .expect("content");
        service.adopt(content);

        assert_eq!(service.state(), &CourseContentState::Ready);
        assert_eq!(
            service.content().map(|content| content.course_id.as_str()),
            Some("crs-002")
        );
    }

    #[test]
    fn service_marks_document_without_materials_as_empty() {
        let api: Arc<dyn CoursesApi> = Arc::new(FakeCoursesApi::with_seed(4));
        let mut service = CourseContentService::new(api);
        service.begin_load("crs-002");

        service.adopt(CourseContent {
            course_id: "crs-002".to_string(),
            title: "课程 3".to_string(),
            description: None,
            revision_number: Some(3),
            published_at: None,
            document: CourseContentDocument {
                goals: Vec::new(),
                chapters: Vec::new(),
                issues: vec![CourseIssue {
                    id: Some("issue-1".to_string()),
                    title: Some("没有材料的卡".to_string()),
                    kind: Some("handwork".to_string()),
                    story_materials: Vec::new(),
                    objective_materials: Vec::new(),
                }],
            },
        });

        assert_eq!(service.state(), &CourseContentState::Empty);
    }

    #[test]
    fn service_failure_and_retry() {
        let api: Arc<dyn CoursesApi> = Arc::new(FakeCoursesApi::failing());
        let mut service = CourseContentService::new(api);
        service.begin_load("crs-002");

        let error = service
            .api_handle()
            .get_course_content(None, "crs-002")
            .unwrap_err();
        service.fail(&error);

        assert!(matches!(service.state(), CourseContentState::Failed(_)));
        service.retry_ready();
        assert_eq!(service.state(), &CourseContentState::Idle);
    }
}
