//! 服务端通知 feed 的 GraphQL 访问与深链映射。
//!
//! 通知的展示由 app 层通过 GPUI `SystemNotification` 完成；本模块只负责传输、
//! 解析，以及把后端的小程序路径转换为客户端 `cgc://` 深链。

use serde_json::{json, Value};

use crate::api::{ApiError, GraphqlClient};

const FEED_QUERY: &str = r#"
query NotificationFeed($first: Int!, $after: String) {
  notificationFeed(first: $first, after: $after) {
    count
    endKeyset
    results {
      id
      type
      deepLink
      readAt
      insertedAt
      title
      body
    }
  }
}
"#;

const MARK_READ_MUTATION: &str = r#"
mutation MarkNotificationRead($id: ID!) {
  markNotificationRead(id: $id) {
    errors { code message }
  }
}
"#;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NotificationPage {
    pub items: Vec<Notification>,
    pub total: Option<i64>,
    pub next_cursor: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Notification {
    pub id: String,
    pub kind: String,
    pub deep_link: Option<String>,
    pub read_at: Option<String>,
    pub inserted_at: String,
    pub title: String,
    pub body: String,
}

impl Notification {
    /// 转换为客户端深链；未知路径返回 None，由调用方降级到工作台。
    pub fn client_deep_link(&self) -> Option<String> {
        desktop_deep_link(self.deep_link.as_deref())
    }
}

pub trait NotificationsApi: Send + Sync {
    fn feed_page(
        &self,
        token: &str,
        first: u32,
        after: Option<&str>,
    ) -> Result<NotificationPage, ApiError>;

    fn feed(&self, token: &str, first: u32) -> Result<Vec<Notification>, ApiError> {
        Ok(self.feed_page(token, first, None)?.items)
    }

    fn mark_read(&self, token: &str, id: &str) -> Result<(), ApiError>;
}

pub struct HttpNotificationsApi {
    client: GraphqlClient,
}

impl HttpNotificationsApi {
    pub fn new(client: GraphqlClient) -> Self {
        Self { client }
    }

    pub fn from_env() -> Self {
        Self::new(GraphqlClient::from_env())
    }
}

impl NotificationsApi for HttpNotificationsApi {
    fn feed_page(
        &self,
        token: &str,
        first: u32,
        after: Option<&str>,
    ) -> Result<NotificationPage, ApiError> {
        let payload = self.client.post(
            Some(token),
            FEED_QUERY,
            json!({ "first": first.clamp(1, 50), "after": after }),
        )?;
        parse_page(&payload)
    }

    fn mark_read(&self, token: &str, id: &str) -> Result<(), ApiError> {
        let payload = self
            .client
            .post(Some(token), MARK_READ_MUTATION, json!({ "id": id }))?;
        let errors = payload
            .get("data")
            .and_then(|data| data.get("markNotificationRead"))
            .and_then(|result| result.get("errors"))
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        if let Some(error) = errors.first() {
            return Err(ApiError::Graphql {
                code: error
                    .get("code")
                    .and_then(Value::as_str)
                    .map(str::to_string),
                message: error
                    .get("message")
                    .and_then(Value::as_str)
                    .unwrap_or("mark notification read failed")
                    .to_string(),
            });
        }
        Ok(())
    }
}

pub fn parse_page(payload: &Value) -> Result<NotificationPage, ApiError> {
    let feed = payload
        .get("data")
        .and_then(|data| data.get("notificationFeed"));
    let items = feed
        .and_then(|feed| feed.get("results"))
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default()
        .iter()
        .filter_map(|item| {
            Some(Notification {
                id: item.get("id")?.as_str()?.to_string(),
                kind: item.get("type")?.as_str()?.to_string(),
                deep_link: item
                    .get("deepLink")
                    .and_then(Value::as_str)
                    .map(str::to_string),
                read_at: item
                    .get("readAt")
                    .and_then(Value::as_str)
                    .map(str::to_string),
                inserted_at: item.get("insertedAt")?.as_str()?.to_string(),
                title: item.get("title")?.as_str()?.to_string(),
                body: item.get("body")?.as_str()?.to_string(),
            })
        })
        .collect();
    Ok(NotificationPage {
        items,
        total: feed
            .and_then(|feed| feed.get("count"))
            .and_then(Value::as_i64),
        next_cursor: feed
            .and_then(|feed| feed.get("endKeyset"))
            .and_then(Value::as_str)
            .map(str::to_string),
    })
}

pub fn parse_feed(payload: &Value) -> Result<Vec<Notification>, ApiError> {
    Ok(parse_page(payload)?.items)
}

/// 后端通知 deepLink 是微信小程序路径；未知路径返回 None。
pub fn desktop_deep_link(deep_link: Option<&str>) -> Option<String> {
    let deep_link = deep_link?.trim();
    match deep_link {
        "/pages/workspace/index" => Some("cgc://workspace".to_string()),
        "/pages/my-enrollments/index" => Some("cgc://events/mine".to_string()),
        _ if deep_link.starts_with("/pages/event-detail/index?") => {
            let id = deep_link
                .split_once('?')?
                .1
                .split('&')
                .find_map(|pair| pair.strip_prefix("id="))?;
            if id.is_empty() {
                None
            } else {
                Some(format!("cgc://events/{id}"))
            }
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_notification_feed_and_skips_incomplete_rows() {
        let payload = json!({
            "data": { "notificationFeed": { "results": [
                {
                    "id": "n1",
                    "type": "event_reminder",
                    "deepLink": "/pages/event-detail/index?id=3f2b0f9e-0c1d-4c7a-9b0e-8f6d5a4c3b2a",
                    "readAt": null,
                    "insertedAt": "2026-10-22T10:00:00Z",
                    "title": "开始提醒",
                    "body": "即将开始"
                },
                { "id": "broken" }
            ] } }
        });
        let items = parse_feed(&payload).expect("parse");
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].id, "n1");
        assert_eq!(
            items[0].client_deep_link().as_deref(),
            Some("cgc://events/3f2b0f9e-0c1d-4c7a-9b0e-8f6d5a4c3b2a")
        );
    }

    #[test]
    fn http_feed_sends_bearer_and_parses_results() {
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
                if let Some(position) = request.windows(4).position(|window| window == b"\r\n\r\n")
                {
                    break position + 4;
                }
            };
            let headers = String::from_utf8_lossy(&request[..header_end]).to_string();
            let length = headers
                .lines()
                .find_map(|line| {
                    let (name, value) = line.split_once(':')?;
                    name.eq_ignore_ascii_case("content-length")
                        .then(|| value.trim().parse::<usize>().ok())
                        .flatten()
                })
                .unwrap_or(0);
            while request.len() < header_end + length {
                let read = stream.read(&mut buffer).expect("read body");
                if read == 0 {
                    break;
                }
                request.extend_from_slice(&buffer[..read]);
            }
            let _ = sender.send(String::from_utf8_lossy(&request).to_string());
            let body = r#"{"data":{"notificationFeed":{"results":[{"id":"n1","type":"event_reminder","deepLink":"/pages/workspace/index","readAt":null,"insertedAt":"2026-10-22T10:00:00Z","title":"提醒","body":"正文"}]}}}"#;
            let response = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
            stream.write_all(response.as_bytes()).expect("write");
        });
        let api =
            HttpNotificationsApi::new(GraphqlClient::new(format!("http://{addr}/api/graphql")));
        let feed = api
            .feed_page("jwt.token", 20, Some("cursor-1"))
            .expect("feed");
        assert_eq!(feed.items.len(), 1);
        assert_eq!(feed.items[0].id, "n1");
        let request = receiver.recv().expect("request");
        assert!(request.contains("authorization: Bearer jwt.token"));
        assert!(request.contains("NotificationFeed"));
        assert!(request.contains("cursor-1"));
    }

    #[test]
    fn parses_page_count_and_cursor() {
        let payload = json!({
            "data": { "notificationFeed": {
                "count": 41,
                "endKeyset": "cursor-2",
                "results": [{
                    "id": "n1",
                    "type": "event_reminder",
                    "deepLink": null,
                    "readAt": "2026-10-22T11:00:00Z",
                    "insertedAt": "2026-10-22T10:00:00Z",
                    "title": "提醒",
                    "body": "正文"
                }]
            } }
        });
        let page = parse_page(&payload).expect("page");
        assert_eq!(page.total, Some(41));
        assert_eq!(page.next_cursor.as_deref(), Some("cursor-2"));
        assert_eq!(page.items.len(), 1);
        assert!(page.items[0].read_at.is_some());
    }

    #[test]
    fn maps_known_notification_paths() {
        assert_eq!(
            desktop_deep_link(Some("/pages/workspace/index")).as_deref(),
            Some("cgc://workspace")
        );
        assert_eq!(
            desktop_deep_link(Some("/pages/my-enrollments/index")).as_deref(),
            Some("cgc://events/mine")
        );
        assert_eq!(desktop_deep_link(Some("/pages/unknown/index")), None);
        assert_eq!(desktop_deep_link(None), None);
    }
}
