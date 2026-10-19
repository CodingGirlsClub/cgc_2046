//! workspace 上下文与课程上下文端口（story 4.1）。
//!
//! `CourseContextPort` 是 courses 实现、companion 消费的跨 feature 端口（脊柱 AD-1）：
//! 上下文缺失/过期必须 fail-closed，调用方不得用空 workspace 或空 revision 启动
//! 学习会话/agent。真正的 account/workspace epoch 由 story 2.4/2.5 提供，本 story
//! 先固定端口形状与 fail-closed 语义（缺失即错误）。

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CourseContext {
    pub user_id: String,
    pub workspace_id: String,
    pub course_id: String,
    pub course_revision_id: String,
    pub account_epoch: u64,
    pub workspace_epoch: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ContextError {
    MissingUser,
    MissingWorkspace,
    MissingCourse,
    MissingRevision,
}

/// 课程上下文端口：由 courses 域实现，learning/companion 侧只依赖此 trait。
pub trait CourseContextPort {
    fn current(&self) -> Result<CourseContext, ContextError>;
}

/// 课程上下文提供者：拿到什么就放什么，`current` 逐项 fail-closed。
#[derive(Clone, Debug, Default)]
pub struct CourseContextProvider {
    pub user_id: Option<String>,
    pub workspace_id: Option<String>,
    pub course_id: Option<String>,
    pub course_revision_id: Option<String>,
    pub account_epoch: Option<u64>,
    pub workspace_epoch: Option<u64>,
}

impl CourseContextProvider {
    pub fn from_parts(
        user_id: impl Into<Option<String>>,
        workspace_id: impl Into<Option<String>>,
        course_id: impl Into<Option<String>>,
        course_revision_id: impl Into<Option<String>>,
    ) -> Self {
        Self {
            user_id: user_id.into(),
            workspace_id: workspace_id.into(),
            course_id: course_id.into(),
            course_revision_id: course_revision_id.into(),
            account_epoch: Some(1),
            workspace_epoch: Some(1),
        }
    }

    fn non_empty(value: &Option<String>) -> Option<String> {
        value
            .as_ref()
            .map(|value| value.trim().to_string())
            .filter(|value| !value.is_empty())
    }
}

impl CourseContextPort for CourseContextProvider {
    fn current(&self) -> Result<CourseContext, ContextError> {
        let user_id = Self::non_empty(&self.user_id).ok_or(ContextError::MissingUser)?;
        let workspace_id =
            Self::non_empty(&self.workspace_id).ok_or(ContextError::MissingWorkspace)?;
        let course_id = Self::non_empty(&self.course_id).ok_or(ContextError::MissingCourse)?;
        let course_revision_id =
            Self::non_empty(&self.course_revision_id).ok_or(ContextError::MissingRevision)?;

        Ok(CourseContext {
            user_id,
            workspace_id,
            course_id,
            course_revision_id,
            account_epoch: self.account_epoch.unwrap_or(0),
            workspace_epoch: self.workspace_epoch.unwrap_or(0),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn complete() -> CourseContextProvider {
        CourseContextProvider::from_parts(
            Some("u-1".to_string()),
            Some("ws-1".to_string()),
            Some("course-1".to_string()),
            Some("rev-3".to_string()),
        )
    }

    #[test]
    fn complete_parts_produce_context() {
        let context = complete().current().expect("context");
        assert_eq!(context.workspace_id, "ws-1");
        assert_eq!(context.course_revision_id, "rev-3");
        assert_eq!(context.account_epoch, 1);
    }

    #[test]
    fn missing_workspace_fails_closed() {
        let mut provider = complete();
        provider.workspace_id = None;
        assert_eq!(provider.current(), Err(ContextError::MissingWorkspace));
    }

    #[test]
    fn missing_revision_fails_closed() {
        let mut provider = complete();
        provider.course_revision_id = None;
        assert_eq!(provider.current(), Err(ContextError::MissingRevision));
    }

    #[test]
    fn blank_values_treated_as_missing() {
        let mut provider = complete();
        provider.course_id = Some("   ".to_string());
        assert_eq!(provider.current(), Err(ContextError::MissingCourse));
    }
}

// ---------------------------------------------------------------------------
// 工作台列表与切换（story 2.4）：meWorkspaces 的传输抽象、fake 与 epoch 服务。
// ---------------------------------------------------------------------------

use crate::api::{ApiError, GraphqlClient};

const ME_WORKSPACES_QUERY: &str = r#"
query MeWorkspaces {
  meWorkspaces {
    id
    slug
    name
    joinPolicy
    sponsorshipEnabled
    myRoleNames
    myMembershipId
    canAccess
    memberCount
  }
}
"#;

/// 当前 workspace 作用域（2.5）：id + 发送请求时的 epoch，响应按 epoch 守卫。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WorkspaceScope {
    pub workspace_id: String,
    pub epoch: u64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WorkspaceSummary {
    pub id: String,
    pub slug: String,
    pub name: String,
    pub my_role_names: Vec<String>,
    pub member_count: Option<i64>,
    pub can_access: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum WorkspaceError {
    Transport(String),
    Server(String),
    Unauthorized,
}

impl From<ApiError> for WorkspaceError {
    fn from(error: ApiError) -> Self {
        match error {
            ApiError::Transport(reason) => WorkspaceError::Transport(reason),
            ApiError::Timeout(reason) => WorkspaceError::Transport(format!("timeout: {reason}")),
            ApiError::Unauthorized => WorkspaceError::Unauthorized,
            ApiError::Graphql { message, .. } => WorkspaceError::Server(message),
        }
    }
}

impl WorkspaceError {
    pub fn diagnostic(&self) -> String {
        match self {
            WorkspaceError::Transport(reason) => format!("transport error: {reason}"),
            WorkspaceError::Server(reason) => format!("server error: {reason}"),
            WorkspaceError::Unauthorized => "unauthorized".to_string(),
        }
    }

    pub fn is_unauthorized(&self) -> bool {
        matches!(self, WorkspaceError::Unauthorized)
    }
}

pub trait WorkspaceApi: Send + Sync {
    fn list_workspaces(&self, token: Option<&str>)
        -> Result<Vec<WorkspaceSummary>, WorkspaceError>;
}

pub struct HttpWorkspaceApi {
    client: GraphqlClient,
}

impl HttpWorkspaceApi {
    pub fn new(client: GraphqlClient) -> Self {
        Self { client }
    }

    pub fn from_env() -> Self {
        Self::new(GraphqlClient::from_env())
    }
}

impl WorkspaceApi for HttpWorkspaceApi {
    fn list_workspaces(
        &self,
        token: Option<&str>,
    ) -> Result<Vec<WorkspaceSummary>, WorkspaceError> {
        let payload = self
            .client
            .post(token, ME_WORKSPACES_QUERY, serde_json::json!({}))
            .map_err(WorkspaceError::from)?;
        let values = payload
            .get("data")
            .and_then(|data| data.get("meWorkspaces"))
            .and_then(serde_json::Value::as_array)
            .ok_or_else(|| WorkspaceError::Server("missing meWorkspaces payload".to_string()))?;

        Ok(values
            .iter()
            .filter_map(|value| {
                Some(WorkspaceSummary {
                    id: value.get("id")?.as_str()?.to_string(),
                    slug: value.get("slug")?.as_str()?.to_string(),
                    name: value.get("name")?.as_str()?.to_string(),
                    my_role_names: value
                        .get("myRoleNames")
                        .and_then(serde_json::Value::as_array)
                        .map(|roles| {
                            roles
                                .iter()
                                .filter_map(|role| role.as_str().map(str::to_string))
                                .collect()
                        })
                        .unwrap_or_default(),
                    member_count: value.get("memberCount").and_then(serde_json::Value::as_i64),
                    can_access: value
                        .get("canAccess")
                        .and_then(serde_json::Value::as_bool)
                        .unwrap_or(false),
                })
            })
            .collect())
    }
}

pub struct FakeWorkspaceApi {
    workspaces: Vec<WorkspaceSummary>,
    fail: bool,
}

impl FakeWorkspaceApi {
    pub fn demo() -> Self {
        Self {
            workspaces: vec![
                WorkspaceSummary {
                    id: "ws-2046".to_string(),
                    slug: "2046".to_string(),
                    name: "2046 社区".to_string(),
                    my_role_names: vec!["learner".to_string()],
                    member_count: Some(128),
                    can_access: true,
                },
                WorkspaceSummary {
                    id: "ws-demo".to_string(),
                    slug: "demo".to_string(),
                    name: "示例工作台".to_string(),
                    my_role_names: vec!["owner".to_string(), "tutor".to_string()],
                    member_count: Some(12),
                    can_access: true,
                },
            ],
            fail: false,
        }
    }

    pub fn failing() -> Self {
        Self {
            workspaces: Vec::new(),
            fail: true,
        }
    }

    pub fn empty() -> Self {
        Self {
            workspaces: Vec::new(),
            fail: false,
        }
    }
}

impl WorkspaceApi for FakeWorkspaceApi {
    fn list_workspaces(
        &self,
        _token: Option<&str>,
    ) -> Result<Vec<WorkspaceSummary>, WorkspaceError> {
        if self.fail {
            return Err(WorkspaceError::Transport("fake network down".to_string()));
        }
        Ok(self.workspaces.clone())
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum WorkspaceListState {
    Idle,
    Loading,
    Ready,
    Empty,
    Failed(String),
}

pub struct WorkspaceService {
    api: std::sync::Arc<dyn WorkspaceApi>,
    workspaces: Vec<WorkspaceSummary>,
    current: Option<WorkspaceSummary>,
    epoch: u64,
    state: WorkspaceListState,
}

impl WorkspaceService {
    pub fn new(api: std::sync::Arc<dyn WorkspaceApi>) -> Self {
        Self {
            api,
            workspaces: Vec::new(),
            current: None,
            epoch: 0,
            state: WorkspaceListState::Idle,
        }
    }

    pub fn api_handle(&self) -> std::sync::Arc<dyn WorkspaceApi> {
        std::sync::Arc::clone(&self.api)
    }

    pub fn begin_load(&mut self) {
        self.state = WorkspaceListState::Loading;
    }

    pub fn fetch(&self, token: Option<&str>) -> Result<Vec<WorkspaceSummary>, WorkspaceError> {
        self.api.list_workspaces(token)
    }

    /// 采纳列表：保留当前选择（若仍可访问），否则用 `CGC_WORKSPACE_ID`/第一个可访问工作台。
    pub fn adopt(&mut self, workspaces: Vec<WorkspaceSummary>) {
        self.workspaces = workspaces;
        let preferred = std::env::var("CGC_WORKSPACE_ID").ok();
        let selected = self
            .current
            .as_ref()
            .and_then(|current| {
                self.workspaces
                    .iter()
                    .find(|candidate| candidate.id == current.id && candidate.can_access)
                    .cloned()
            })
            .or_else(|| {
                preferred.and_then(|id| {
                    self.workspaces
                        .iter()
                        .find(|candidate| candidate.id == id && candidate.can_access)
                        .cloned()
                })
            })
            .or_else(|| {
                self.workspaces
                    .iter()
                    .find(|candidate| candidate.can_access)
                    .cloned()
            });

        if let Some(workspace) = selected {
            self.current = Some(workspace);
            self.epoch = self.epoch.saturating_add(1);
            self.state = WorkspaceListState::Ready;
        } else {
            self.current = None;
            self.state = WorkspaceListState::Empty;
        }
    }

    pub fn fail(&mut self, error: &WorkspaceError) {
        self.state = WorkspaceListState::Failed(error.diagnostic());
    }

    pub fn retry_ready(&mut self) {
        self.state = WorkspaceListState::Idle;
    }

    /// 登出/换账号：清空列表与当前选择，递增 epoch 使所有在途响应失效。
    pub fn reset(&mut self) {
        self.workspaces.clear();
        self.current = None;
        self.epoch = self.epoch.saturating_add(1);
        self.state = WorkspaceListState::Idle;
    }

    pub fn workspaces(&self) -> &[WorkspaceSummary] {
        &self.workspaces
    }

    pub fn current(&self) -> Option<&WorkspaceSummary> {
        self.current.as_ref()
    }

    pub fn current_id(&self) -> Option<&str> {
        self.current.as_ref().map(|workspace| workspace.id.as_str())
    }

    pub fn epoch(&self) -> u64 {
        self.epoch
    }

    /// 当前请求作用域；无工作台时为 None（不伪造）。
    pub fn scope(&self) -> Option<WorkspaceScope> {
        self.current.as_ref().map(|workspace| WorkspaceScope {
            workspace_id: workspace.id.clone(),
            epoch: self.epoch,
        })
    }

    pub fn state(&self) -> &WorkspaceListState {
        &self.state
    }

    pub fn is_current_epoch(&self, epoch: u64) -> bool {
        self.epoch == epoch
    }

    /// 切换当前工作台：变更成功才递增 epoch（旧 in-flight 响应随后被守卫丢弃）。
    pub fn switch_to(&mut self, workspace_id: &str) -> bool {
        if self.current_id() == Some(workspace_id) {
            return false;
        }
        let Some(target) = self
            .workspaces
            .iter()
            .find(|workspace| workspace.id == workspace_id && workspace.can_access)
            .cloned()
        else {
            return false;
        };
        self.current = Some(target);
        self.epoch = self.epoch.saturating_add(1);
        true
    }
}

#[cfg(test)]
mod workspace_tests {
    use super::*;
    use std::sync::Arc;

    fn service() -> WorkspaceService {
        WorkspaceService::new(Arc::new(FakeWorkspaceApi::demo()))
    }

    #[test]
    fn default_selection_is_first_accessible_and_bumps_epoch() {
        let mut service = service();
        service.begin_load();
        service.adopt(service.fetch(None).expect("workspaces"));
        assert_eq!(service.state(), &WorkspaceListState::Ready);
        assert_eq!(
            service.current().map(|workspace| workspace.slug.as_str()),
            Some("2046")
        );
        assert_eq!(service.epoch(), 1);
    }

    #[test]
    fn switch_changes_current_and_invalidates_old_epoch() {
        let mut service = service();
        service.begin_load();
        service.adopt(service.fetch(None).expect("workspaces"));
        let before = service.epoch();
        assert!(service.switch_to("ws-demo"));
        assert_eq!(service.current_id(), Some("ws-demo"));
        assert_eq!(service.epoch(), before + 1);
        assert!(!service.is_current_epoch(before));
        assert!(!service.switch_to("missing"));
    }

    #[test]
    fn empty_account_is_empty_state() {
        let mut service = WorkspaceService::new(Arc::new(FakeWorkspaceApi::empty()));
        service.begin_load();
        service.adopt(service.fetch(None).expect("empty"));
        assert_eq!(service.state(), &WorkspaceListState::Empty);
        assert!(service.current().is_none());
    }

    #[test]
    fn failure_sets_failed_and_retry_resets() {
        let mut service = WorkspaceService::new(Arc::new(FakeWorkspaceApi::failing()));
        service.begin_load();
        let error = service.fetch(None).unwrap_err();
        service.fail(&error);
        assert!(matches!(service.state(), WorkspaceListState::Failed(_)));
        service.retry_ready();
        assert_eq!(service.state(), &WorkspaceListState::Idle);
    }

    #[test]
    fn http_api_parses_me_workspaces() {
        use std::io::{Read, Write};
        use std::net::TcpListener;

        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let addr = listener.local_addr().expect("addr");
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
            let request = String::from_utf8_lossy(&request).to_string();
            assert!(request.contains("meWorkspaces"), "request: {request}");
            let body = r#"{"data":{"meWorkspaces":[{"id":"ws-1","slug":"a","name":"A 工作台","myRoleNames":["learner"],"canAccess":true,"memberCount":7}]}}"#;
            let response = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
            stream.write_all(response.as_bytes()).expect("write");
        });

        let api = HttpWorkspaceApi::new(GraphqlClient::new(format!("http://{addr}/api/graphql")));
        let workspaces = api.list_workspaces(Some("token")).expect("workspaces");
        assert_eq!(workspaces.len(), 1);
        assert_eq!(workspaces[0].name, "A 工作台");
        assert_eq!(workspaces[0].member_count, Some(7));
        assert_eq!(workspaces[0].my_role_names, vec!["learner".to_string()]);
    }
}
