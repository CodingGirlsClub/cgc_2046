//! 场次列表（story 3.1）：GraphQL `listEvents` 的传输抽象、fake 数据与列表状态机。
//!
//! - `HttpEventsApi`：真实后端（keyset 分页 + 状态筛选），复用 `platform::api::GraphqlClient`；
//! - `FakeEventsApi`：本地 fake 数据（分页/筛选/错误注入），供 UI 开发与测试；
//! - `EventListService`：UI 可观察的列表状态（idle/loading/ready/empty/failed + next cursor）。

use std::sync::Arc;

use cgc_platform::api::{ApiError, GraphqlClient};
use serde_json::{json, Value};

const LIST_EVENTS_QUERY: &str = r#"
query ListEvents($first: Int!, $after: String, $filter: EventFilterInput) {
  listEvents(first: $first, after: $after, filter: $filter) {
    count
    endKeyset
    results {
      id
      title
      status
      visibility
      enrollmentPolicy
      enrollmentBadge
      registrationDeadline
      startsAt
      venue
      pricingEnabled
    }
  }
}
"#;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StatusFilter {
    All,
    Open,
    Closed,
    Cancelled,
}

impl StatusFilter {
    pub const ALL: [StatusFilter; 4] = [
        StatusFilter::All,
        StatusFilter::Open,
        StatusFilter::Closed,
        StatusFilter::Cancelled,
    ];

    fn status_value(self) -> Option<&'static str> {
        match self {
            StatusFilter::All => None,
            StatusFilter::Open => Some("open"),
            StatusFilter::Closed => Some("closed"),
            StatusFilter::Cancelled => Some("cancelled"),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EventSummary {
    pub id: String,
    pub title: String,
    pub status: String,
    pub visibility: String,
    pub enrollment_policy: String,
    pub capacity: Option<i64>,
    pub confirmed_count: Option<i64>,
    pub enrollment_badge: Option<String>,
    pub registration_deadline: Option<String>,
    pub starts_at: Option<String>,
    pub venue: Option<String>,
    pub pricing_enabled: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EventPage {
    pub items: Vec<EventSummary>,
    pub next_cursor: Option<String>,
    pub total: Option<i64>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum EventsError {
    Transport(String),
    Server(String),
    NotFound,
}

impl From<ApiError> for EventsError {
    fn from(error: ApiError) -> Self {
        match error {
            ApiError::Transport(reason) => EventsError::Transport(reason),
            ApiError::Graphql { message, .. } => EventsError::Server(message),
        }
    }
}

impl EventsError {
    pub fn diagnostic(&self) -> String {
        match self {
            EventsError::Transport(reason) => format!("transport error: {reason}"),
            EventsError::Server(reason) => format!("server error: {reason}"),
            EventsError::NotFound => "not found".to_string(),
        }
    }
}

/// 列表传输端口。`token` 为当前会话 Bearer（匿名可读 open+public）。
pub trait EventsApi: Send + Sync {
    fn list_events(
        &self,
        token: Option<&str>,
        filter: StatusFilter,
        after: Option<&str>,
        first: u32,
    ) -> Result<EventPage, EventsError>;

    fn get_event(
        &self,
        token: Option<&str>,
        id: &str,
    ) -> Result<crate::detail::EventDetail, EventsError>;
}

pub struct HttpEventsApi {
    client: GraphqlClient,
}

impl HttpEventsApi {
    pub fn new(client: GraphqlClient) -> Self {
        Self { client }
    }

    pub fn from_env() -> Self {
        Self::new(GraphqlClient::from_env())
    }

    fn parse_event(value: &Value) -> Option<EventSummary> {
        Some(EventSummary {
            id: value.get("id")?.as_str()?.to_string(),
            title: value.get("title")?.as_str()?.to_string(),
            status: value.get("status")?.as_str().unwrap_or("open").to_string(),
            visibility: value
                .get("visibility")?
                .as_str()
                .unwrap_or("public")
                .to_string(),
            enrollment_policy: value
                .get("enrollmentPolicy")
                .and_then(Value::as_str)
                .unwrap_or("open")
                .to_string(),
            capacity: value.get("capacity").and_then(Value::as_i64),
            confirmed_count: value.get("confirmedCount").and_then(Value::as_i64),
            enrollment_badge: value
                .get("enrollmentBadge")
                .and_then(Value::as_str)
                .map(str::to_string),
            registration_deadline: value
                .get("registrationDeadline")
                .and_then(Value::as_str)
                .map(str::to_string),
            starts_at: value
                .get("startsAt")
                .and_then(Value::as_str)
                .map(str::to_string),
            venue: value
                .get("venue")
                .and_then(Value::as_str)
                .map(str::to_string),
            pricing_enabled: value
                .get("pricingEnabled")
                .and_then(Value::as_bool)
                .unwrap_or(false),
        })
    }
}

const GET_EVENT_QUERY: &str = r#"
query GetEvent($id: ID!) {
  getEvent(id: $id) {
    id
    title
    description
    status
    visibility
    enrollmentPolicy
    enrollmentBadge
    registrationDeadline
    startsAt
    endsAt
    venue
    pricingEnabled
    availablePriceTiers
    depositEnabled
    depositAmountCents
  }
}
"#;

impl EventsApi for HttpEventsApi {
    fn list_events(
        &self,
        token: Option<&str>,
        filter: StatusFilter,
        after: Option<&str>,
        first: u32,
    ) -> Result<EventPage, EventsError> {
        let mut variables = json!({ "first": first });
        if let Some(after) = after {
            variables["after"] = json!(after);
        }
        if let Some(status) = filter.status_value() {
            variables["filter"] = json!({ "status": { "eq": status } });
        }

        let payload = self
            .client
            .post(token, LIST_EVENTS_QUERY, variables)
            .map_err(EventsError::from)?;

        let page = payload
            .get("data")
            .and_then(|data| data.get("listEvents"))
            .ok_or_else(|| EventsError::Server("missing listEvents payload".to_string()))?;

        let items = page
            .get("results")
            .and_then(Value::as_array)
            .map(|results| results.iter().filter_map(Self::parse_event).collect())
            .unwrap_or_default();

        Ok(EventPage {
            items,
            next_cursor: page
                .get("endKeyset")
                .and_then(Value::as_str)
                .filter(|cursor| !cursor.is_empty())
                .map(str::to_string),
            total: page.get("count").and_then(Value::as_i64),
        })
    }

    fn get_event(
        &self,
        token: Option<&str>,
        id: &str,
    ) -> Result<crate::detail::EventDetail, EventsError> {
        let payload = self
            .client
            .post(token, GET_EVENT_QUERY, json!({ "id": id }))
            .map_err(EventsError::from)?;

        let value = payload
            .get("data")
            .and_then(|data| data.get("getEvent"))
            .filter(|value| !value.is_null())
            .ok_or(EventsError::NotFound)?;

        let summary = Self::parse_event(value)
            .ok_or_else(|| EventsError::Server("missing getEvent fields".to_string()))?;
        let mut detail = crate::detail::EventDetail::from_summary(&summary);
        detail.description = value
            .get("description")
            .and_then(Value::as_str)
            .map(str::to_string);
        detail.ends_at = value
            .get("endsAt")
            .and_then(Value::as_str)
            .map(str::to_string);
        detail.pricing_enabled = value
            .get("pricingEnabled")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        detail.available_price_tiers = value
            .get("availablePriceTiers")
            .map(crate::detail::parse_price_tiers)
            .unwrap_or_default();
        detail.deposit_enabled = value
            .get("depositEnabled")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        detail.deposit_amount_cents = value.get("depositAmountCents").and_then(Value::as_i64);
        Ok(detail)
    }
}

/// 本地 fake 数据：固定种子（可按状态筛选、keyset 游标、失败注入）。
pub struct FakeEventsApi {
    events: Vec<EventSummary>,
    fail: bool,
}

impl FakeEventsApi {
    pub fn with_seed(count: usize) -> Self {
        let statuses = ["open", "open", "closed", "cancelled"];
        let events = (0..count)
            .map(|index| EventSummary {
                id: format!("evt-{index:03}"),
                title: format!("场次 {}", index + 1),
                status: statuses[index % statuses.len()].to_string(),
                visibility: "public".to_string(),
                enrollment_policy: "open".to_string(),
                capacity: Some(30),
                confirmed_count: Some((index as i64 * 3) % 30),
                enrollment_badge: Some(
                    match index % 4 {
                        0 => "enrolling",
                        1 => "starting_soon",
                        2 => "closed",
                        _ => "full",
                    }
                    .to_string(),
                ),
                registration_deadline: None,
                starts_at: Some(format!("2026-11-{:02}T10:00:00Z", (index % 28) + 1)),
                venue: Some(r#"{"city":"上海"}"#.to_string()),
                pricing_enabled: index % 2 == 0,
            })
            .collect();
        Self {
            events,
            fail: false,
        }
    }

    pub fn failing() -> Self {
        Self {
            events: Vec::new(),
            fail: true,
        }
    }
}

impl Default for FakeEventsApi {
    fn default() -> Self {
        Self::with_seed(23)
    }
}

impl EventsApi for FakeEventsApi {
    fn list_events(
        &self,
        _token: Option<&str>,
        filter: StatusFilter,
        after: Option<&str>,
        first: u32,
    ) -> Result<EventPage, EventsError> {
        if self.fail {
            return Err(EventsError::Transport("fake network down".to_string()));
        }

        let start = after
            .and_then(|cursor| cursor.parse::<usize>().ok())
            .unwrap_or(0);
        let filtered: Vec<EventSummary> = self
            .events
            .iter()
            .filter(|event| match filter.status_value() {
                Some(status) => event.status == status,
                None => true,
            })
            .cloned()
            .collect();
        let end = (start + first as usize).min(filtered.len());
        let items = filtered.get(start..end).unwrap_or_default().to_vec();
        let next_cursor = (end < filtered.len()).then(|| end.to_string());

        Ok(EventPage {
            items,
            next_cursor,
            total: Some(filtered.len() as i64),
        })
    }

    fn get_event(
        &self,
        _token: Option<&str>,
        id: &str,
    ) -> Result<crate::detail::EventDetail, EventsError> {
        if self.fail {
            return Err(EventsError::Transport("fake network down".to_string()));
        }
        let summary = self
            .events
            .iter()
            .find(|event| event.id == id)
            .ok_or(EventsError::NotFound)?;
        let mut detail = crate::detail::EventDetail::from_summary(summary);
        detail.description = Some(format!("{} 的详情（fake 数据）", summary.title));
        if summary.pricing_enabled {
            detail.available_price_tiers = vec![crate::detail::PriceTier {
                id: "tier-early".to_string(),
                name: "早鸟".to_string(),
                amount_cents: 9900,
            }];
        }
        // 每 5 条造一个押金场（evt-004/009/...），供三态 UI 与测试使用。
        let numeric_id: usize = summary
            .id
            .rsplit('-')
            .next()
            .and_then(|digits| digits.parse().ok())
            .unwrap_or(0);
        if (numeric_id + 1).is_multiple_of(5) {
            detail.deposit_enabled = true;
            detail.deposit_amount_cents = Some(5000);
        }
        Ok(detail)
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ListState {
    Idle,
    Loading,
    Ready,
    Empty,
    Failed(String),
}

pub struct EventListService {
    api: Arc<dyn EventsApi>,
    items: Vec<EventSummary>,
    next_cursor: Option<String>,
    filter: StatusFilter,
    state: ListState,
    loading_more: bool,
    total: Option<i64>,
}

impl EventListService {
    pub fn new(api: Arc<dyn EventsApi>) -> Self {
        Self {
            api,
            items: Vec::new(),
            next_cursor: None,
            filter: StatusFilter::All,
            state: ListState::Idle,
            loading_more: false,
            total: None,
        }
    }

    pub fn api_handle(&self) -> Arc<dyn EventsApi> {
        Arc::clone(&self.api)
    }

    pub fn state(&self) -> &ListState {
        &self.state
    }

    pub fn items(&self) -> &[EventSummary] {
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

    pub fn filter(&self) -> StatusFilter {
        self.filter
    }

    pub fn total(&self) -> Option<i64> {
        self.total
    }

    pub fn set_filter(&mut self, filter: StatusFilter) {
        self.filter = filter;
    }

    /// 首屏/筛选后的加载：清空现有列表，从游标 0 开始。
    pub fn begin_first_load(&mut self) {
        self.items.clear();
        self.next_cursor = None;
        self.state = ListState::Loading;
        self.loading_more = false;
    }

    /// 加载更多：保留现有列表。
    pub fn begin_load_more(&mut self) {
        self.state = ListState::Loading;
        self.loading_more = true;
    }

    /// 后台线程调用：按当前筛选/游标取一页。
    pub fn fetch(&self, token: Option<&str>) -> Result<EventPage, EventsError> {
        self.api.list_events(
            token,
            self.filter,
            if self.loading_more {
                self.next_cursor.as_deref()
            } else {
                None
            },
            10,
        )
    }

    pub fn adopt_page(&mut self, page: EventPage) {
        if self.loading_more {
            self.items.extend(page.items);
        } else {
            self.items = page.items;
        }
        self.total = page.total;
        self.next_cursor = page.next_cursor;
        self.state = if self.items.is_empty() {
            ListState::Empty
        } else {
            ListState::Ready
        };
        self.loading_more = false;
    }

    pub fn fail(&mut self, error: &EventsError) {
        self.state = ListState::Failed(error.diagnostic());
        self.loading_more = false;
    }

    pub fn retry_ready(&mut self) {
        self.state = ListState::Idle;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn service() -> EventListService {
        EventListService::new(Arc::new(FakeEventsApi::with_seed(23)))
    }

    #[test]
    fn first_page_has_items_and_next_cursor() {
        let mut service = service();
        service.begin_first_load();
        let page = service.fetch(None).expect("fake page");
        service.adopt_page(page);

        assert_eq!(service.items().len(), 10);
        assert!(service.next_cursor().is_some());
        assert_eq!(service.state(), &ListState::Ready);
    }

    #[test]
    fn load_more_appends_until_exhausted() {
        let mut service = service();
        service.begin_first_load();
        service.adopt_page(service.fetch(None).expect("page 1"));

        while service.next_cursor().is_some() {
            service.begin_load_more();
            service.adopt_page(service.fetch(None).expect("page n"));
        }

        assert_eq!(service.items().len(), 23);
        assert!(service.next_cursor().is_none());
    }

    #[test]
    fn filter_returns_only_matching_statuses() {
        let mut service = service();
        service.set_filter(StatusFilter::Closed);
        service.begin_first_load();
        service.adopt_page(service.fetch(None).expect("filtered page"));

        assert!(!service.items().is_empty());
        assert!(service.items().iter().all(|event| event.status == "closed"));
    }

    #[test]
    fn has_more_uses_total_not_cursor() {
        let mut service = service();
        service.begin_first_load();
        service.adopt_page(service.fetch(None).expect("page 1"));
        assert!(service.has_more(), "23 items, first page of 10");

        while service.next_cursor().is_some() {
            service.begin_load_more();
            service.adopt_page(service.fetch(None).expect("next page"));
        }
        assert!(!service.has_more(), "all items loaded");
    }

    #[test]
    fn empty_filter_result_sets_empty_state() {
        let mut service = EventListService::new(Arc::new(FakeEventsApi::with_seed(0)));
        service.begin_first_load();
        service.adopt_page(service.fetch(None).expect("empty page"));
        assert_eq!(service.state(), &ListState::Empty);
        assert!(service.items().is_empty());
    }

    #[test]
    fn transport_error_sets_failed_and_retry_returns_idle() {
        let mut service = EventListService::new(Arc::new(FakeEventsApi::failing()));
        service.begin_first_load();
        let error = service.fetch(None).unwrap_err();
        service.fail(&error);

        assert!(matches!(service.state(), ListState::Failed(_)));
        service.retry_ready();
        assert_eq!(service.state(), &ListState::Idle);
    }

    #[test]
    fn http_api_parses_graphql_page() {
        // 用 mock server 钉住真实请求形状与 JSON 解析。
        use std::io::{Read, Write};
        use std::net::TcpListener;

        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let addr = listener.local_addr().expect("addr");
        std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept");
            let mut buffer = [0u8; 4096];
            let read = stream.read(&mut buffer).expect("read");
            let request = String::from_utf8_lossy(&buffer[..read]).to_string();
            assert!(request.contains("listEvents"), "request: {request}");
            let body = r#"{"data":{"listEvents":{"count":1,"endKeyset":"cursor-2","results":[{"id":"e-1","title":"Demo","status":"open","visibility":"public","enrollmentPolicy":"open","capacity":10,"confirmedCount":2,"startsAt":"2026-11-01T10:00:00Z","pricingEnabled":true}]}}}"#;
            let response = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
            stream.write_all(response.as_bytes()).expect("write");
        });

        let api = HttpEventsApi::new(GraphqlClient::new(format!("http://{addr}/api/graphql")));
        let page = api
            .list_events(Some("token"), StatusFilter::Open, None, 10)
            .expect("http page");

        assert_eq!(page.items.len(), 1);
        assert_eq!(page.items[0].title, "Demo");
        assert_eq!(page.next_cursor.as_deref(), Some("cursor-2"));
        assert_eq!(page.total, Some(1));
    }
}
