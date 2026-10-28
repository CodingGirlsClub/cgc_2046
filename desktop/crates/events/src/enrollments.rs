//! 我的报名列表（story 3.7）：myEnrollments 查询与行模型。

use cgc_platform::api::{ApiError, GraphqlClient};
use serde_json::Value;

const MY_ENROLLMENTS_QUERY: &str = r#"
query MyEnrollments {
  myEnrollments(first: 50) {
    count
    results { id status targetTitle startsAt eventId courseId paymentMode checkInCode }
  }
}
"#;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MyEnrollmentRow {
    pub id: String,
    pub status: String,
    pub target_title: Option<String>,
    pub starts_at: Option<String>,
    pub event_id: Option<String>,
    pub course_id: Option<String>,
    pub payment_mode: Option<String>,
    pub check_in_code: Option<String>,
}

pub trait EnrollmentsApi: Send + Sync {
    fn my_enrollments(
        &self,
        token: Option<&str>,
    ) -> Result<Vec<MyEnrollmentRow>, crate::list::EventsError>;
}

pub struct HttpEnrollmentsApi {
    client: GraphqlClient,
}

impl HttpEnrollmentsApi {
    pub fn new(client: GraphqlClient) -> Self {
        Self { client }
    }
    pub fn from_env() -> Self {
        Self::new(GraphqlClient::from_env())
    }

    fn parse(value: &Value) -> Option<MyEnrollmentRow> {
        Some(MyEnrollmentRow {
            id: value.get("id")?.as_str()?.to_string(),
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
}

impl EnrollmentsApi for HttpEnrollmentsApi {
    fn my_enrollments(
        &self,
        token: Option<&str>,
    ) -> Result<Vec<MyEnrollmentRow>, crate::list::EventsError> {
        let payload = self
            .client
            .post(token, MY_ENROLLMENTS_QUERY, serde_json::json!({}))
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
        Ok(page
            .get("results")
            .and_then(Value::as_array)
            .map(|results| results.iter().filter_map(Self::parse).collect())
            .unwrap_or_default())
    }
}

pub struct FakeEnrollmentsApi;

impl EnrollmentsApi for FakeEnrollmentsApi {
    fn my_enrollments(
        &self,
        _token: Option<&str>,
    ) -> Result<Vec<MyEnrollmentRow>, crate::list::EventsError> {
        Ok(vec![
            MyEnrollmentRow {
                id: "enr-1".to_string(),
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
                status: "payment_pending".to_string(),
                target_title: Some("示例课程".to_string()),
                starts_at: None,
                event_id: None,
                course_id: Some("crs-002".to_string()),
                payment_mode: Some("paid".to_string()),
                check_in_code: None,
            },
        ])
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::TcpListener;

    #[test]
    fn http_parses_my_enrollments() {
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
            assert!(String::from_utf8_lossy(&request).contains("myEnrollments"));
            let body = r#"{"data":{"myEnrollments":{"count":1,"results":[{"id":"enr-1","status":"confirmed","targetTitle":"场次 A","startsAt":"2026-11-01T10:00:00Z","eventId":"evt-1","courseId":null,"paymentMode":null,"checkInCode":"123456"}]}}}"#;
            let response = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
            stream.write_all(response.as_bytes()).expect("write");
        });
        let api = HttpEnrollmentsApi::new(GraphqlClient::new(format!("http://{addr}/api/graphql")));
        let rows = api.my_enrollments(Some("token")).expect("rows");
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].target_title.as_deref(), Some("场次 A"));
        assert_eq!(rows[0].check_in_code.as_deref(), Some("123456"));
    }

    #[test]
    fn fake_has_confirmed_and_pending_rows() {
        let rows = FakeEnrollmentsApi.my_enrollments(None).expect("rows");
        assert_eq!(rows.len(), 2);
        assert!(rows.iter().any(|row| row.status == "confirmed"));
        assert!(rows.iter().any(|row| row.status == "payment_pending"));
    }
}
