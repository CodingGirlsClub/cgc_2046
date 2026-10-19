//! 下单与扫码支付（story 3.4）：createOrder / orderStatus 传输抽象与支付状态机。

use cgc_platform::api::{ApiError, GraphqlClient};
use serde_json::{json, Value};

const CREATE_ORDER_MUTATION: &str = r#"
mutation CreateOrder($input: CreateOrderInput!) {
  createOrder(input: $input) {
    result { id enrollmentId provider amountCents status expireAt }
    errors { code message }
    metadata { credential }
  }
}
"#;

const ORDER_STATUS_QUERY: &str = r#"
query OrderStatus($id: ID!) {
  orderStatus(id: $id) { id status expireAt amountCents provider }
}
"#;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PaymentOrder {
    pub id: String,
    pub status: String,
    pub provider: String,
    pub amount_cents: i64,
    pub expire_at: Option<String>,
    pub credential: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PaymentError {
    Transport(String),
    Server(String),
    Unauthorized,
    Domain { code: String, message: String },
}

impl From<ApiError> for PaymentError {
    fn from(error: ApiError) -> Self {
        match error {
            ApiError::Transport(reason) => PaymentError::Transport(reason),
            ApiError::Timeout(reason) => PaymentError::Transport(format!("timeout: {reason}")),
            ApiError::Unauthorized => PaymentError::Unauthorized,
            ApiError::Graphql { code, message } => match code {
                Some(code) => PaymentError::Domain { code, message },
                None => PaymentError::Server(message),
            },
        }
    }
}

impl PaymentError {
    pub fn diagnostic(&self) -> String {
        match self {
            PaymentError::Transport(reason) => format!("transport error: {reason}"),
            PaymentError::Server(reason) => format!("server error: {reason}"),
            PaymentError::Unauthorized => "unauthorized".to_string(),
            PaymentError::Domain { code, message } => format!("domain {code}: {message}"),
        }
    }

    pub fn is_unauthorized(&self) -> bool {
        matches!(self, PaymentError::Unauthorized)
    }

    pub fn code(&self) -> Option<&str> {
        match self {
            PaymentError::Domain { code, .. } => Some(code),
            _ => None,
        }
    }
}

pub trait OrdersApi: Send + Sync {
    fn create_order(
        &self,
        token: Option<&str>,
        enrollment_id: &str,
        provider: &str,
        deposit_consent: bool,
    ) -> Result<PaymentOrder, PaymentError>;
    fn order_status(
        &self,
        token: Option<&str>,
        order_id: &str,
    ) -> Result<PaymentOrder, PaymentError>;
}

pub struct HttpOrdersApi {
    client: GraphqlClient,
}

impl HttpOrdersApi {
    pub fn new(client: GraphqlClient) -> Self {
        Self { client }
    }
    pub fn from_env() -> Self {
        Self::new(GraphqlClient::from_env())
    }

    fn parse_order(value: &Value) -> Option<PaymentOrder> {
        Some(PaymentOrder {
            id: value.get("id")?.as_str()?.to_string(),
            status: value
                .get("status")?
                .as_str()
                .unwrap_or("pending")
                .to_string(),
            provider: value
                .get("provider")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string(),
            amount_cents: value
                .get("amountCents")
                .and_then(Value::as_i64)
                .unwrap_or(0),
            expire_at: value
                .get("expireAt")
                .and_then(Value::as_str)
                .map(str::to_string),
            credential: None,
        })
    }
}

impl OrdersApi for HttpOrdersApi {
    fn create_order(
        &self,
        token: Option<&str>,
        enrollment_id: &str,
        provider: &str,
        deposit_consent: bool,
    ) -> Result<PaymentOrder, PaymentError> {
        let mut input = json!({ "enrollmentId": enrollment_id, "provider": provider });
        if deposit_consent {
            input["depositConsent"] = json!(true);
        }
        let payload = self
            .client
            .post(token, CREATE_ORDER_MUTATION, json!({ "input": input }))
            .map_err(PaymentError::from)?;
        let data = payload
            .get("data")
            .and_then(|data| data.get("createOrder"))
            .ok_or_else(|| PaymentError::Server("missing createOrder payload".to_string()))?;
        if let Some(error) = data
            .get("errors")
            .and_then(Value::as_array)
            .and_then(|errors| errors.first())
        {
            return Err(PaymentError::Domain {
                code: error
                    .get("code")
                    .and_then(Value::as_str)
                    .unwrap_or("order_failed")
                    .to_string(),
                message: error
                    .get("message")
                    .and_then(Value::as_str)
                    .unwrap_or("order failed")
                    .to_string(),
            });
        }
        let mut order = data
            .get("result")
            .and_then(Self::parse_order)
            .ok_or_else(|| PaymentError::Server("missing order result".to_string()))?;
        order.credential = data
            .get("metadata")
            .and_then(|metadata| metadata.get("credential"))
            .and_then(Value::as_str)
            .map(str::to_string);
        Ok(order)
    }

    fn order_status(
        &self,
        token: Option<&str>,
        order_id: &str,
    ) -> Result<PaymentOrder, PaymentError> {
        let payload = self
            .client
            .post(token, ORDER_STATUS_QUERY, json!({ "id": order_id }))
            .map_err(PaymentError::from)?;
        payload
            .get("data")
            .and_then(|data| data.get("orderStatus"))
            .filter(|value| !value.is_null())
            .and_then(Self::parse_order)
            .ok_or_else(|| PaymentError::Server("missing orderStatus payload".to_string()))
    }
}

pub struct FakeOrdersApi {
    polls: std::sync::Mutex<u32>,
}

impl FakeOrdersApi {
    pub fn demo() -> Self {
        Self {
            polls: std::sync::Mutex::new(0),
        }
    }
}

impl OrdersApi for FakeOrdersApi {
    fn create_order(
        &self,
        _token: Option<&str>,
        _enrollment_id: &str,
        provider: &str,
        _deposit_consent: bool,
    ) -> Result<PaymentOrder, PaymentError> {
        let credential = json!({
            "type": "qr_code",
            "code_url": format!("https://fake.cgc2046.local/pay/{provider}")
        })
        .to_string();
        Ok(PaymentOrder {
            id: "ord-fake".to_string(),
            status: "pending".to_string(),
            provider: provider.to_string(),
            amount_cents: 9900,
            expire_at: Some("2026-11-01T00:00:00Z".to_string()),
            credential: Some(credential),
        })
    }

    fn order_status(
        &self,
        _token: Option<&str>,
        order_id: &str,
    ) -> Result<PaymentOrder, PaymentError> {
        let mut polls = self.polls.lock().expect("polls");
        *polls += 1;
        let paid = *polls >= 2;
        Ok(PaymentOrder {
            id: order_id.to_string(),
            status: if paid {
                "paid".to_string()
            } else {
                "pending".to_string()
            },
            provider: "wechat_native".to_string(),
            amount_cents: 9900,
            expire_at: Some("2026-11-01T00:00:00Z".to_string()),
            credential: None,
        })
    }
}

/// 轮询终止条件（终态即停；pending/未知继续轮）。
pub fn is_terminal_status(status: &str) -> bool {
    matches!(
        status,
        "paid" | "refunding" | "refunded" | "refund_failed" | "cancelled" | "expired" | "forfeited"
    )
}

/// 解析 credential JsonString 里的二维码 URL（typ=qr_code）；不支持形态返回 None。
pub fn qr_code_url(credential: &str) -> Option<String> {
    let value: Value = serde_json::from_str(credential).ok()?;
    if value.get("type")?.as_str()? != "qr_code" {
        return None;
    }
    value
        .get("code_url")
        .and_then(Value::as_str)
        .filter(|url| !url.is_empty())
        .map(str::to_string)
}

/// RFC3339 `YYYY-MM-DDTHH:MM:SS(.f)?Z` → epoch 秒（足够支付倒计时；解析失败 None）。
pub fn parse_rfc3339_epoch(raw: &str) -> Option<i64> {
    let bytes = raw.as_bytes();
    if bytes.len() < 20 || bytes[4] != b'-' || bytes[7] != b'-' || bytes[10] != b'T' {
        return None;
    }
    let year: i64 = raw.get(0..4)?.parse().ok()?;
    let month: i64 = raw.get(5..7)?.parse().ok()?;
    let day: i64 = raw.get(8..10)?.parse().ok()?;
    let hour: i64 = raw.get(11..13)?.parse().ok()?;
    let minute: i64 = raw.get(14..16)?.parse().ok()?;
    let second: i64 = raw.get(17..19)?.parse().ok()?;
    if !(1..=12).contains(&month) || !(1..=31).contains(&day) {
        return None;
    }
    // days since epoch (civil from days algorithm, Howard Hinnant)
    let y = if month <= 2 { year - 1 } else { year };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let mp = (month + 9) % 12;
    let doy = (153 * mp + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146097 + doe - 719468;
    Some(days * 86400 + hour * 3600 + minute * 60 + second)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_qr_credential_and_rejects_other_types() {
        let qr = r#"{"type":"qr_code","code_url":"https://pay.example/qr"}"#;
        assert_eq!(qr_code_url(qr), Some("https://pay.example/qr".to_string()));
        let redirect = r#"{"type":"redirect","url":"https://pay.example"}"#;
        assert_eq!(qr_code_url(redirect), None);
        assert_eq!(qr_code_url("not-json"), None);
    }

    #[test]
    fn parses_rfc3339_epoch() {
        assert_eq!(parse_rfc3339_epoch("1970-01-01T00:00:00Z"), Some(0));
        assert_eq!(
            parse_rfc3339_epoch("2026-10-19T12:00:00Z"),
            Some(1_792_411_200)
        );
        assert_eq!(parse_rfc3339_epoch("bad"), None);
    }

    #[test]
    fn terminal_statuses_stop_polling() {
        assert!(is_terminal_status("paid"));
        assert!(is_terminal_status("expired"));
        assert!(is_terminal_status("refunded"));
        assert!(!is_terminal_status("pending"));
    }

    #[test]
    fn fake_order_is_pending_then_paid() {
        let api = FakeOrdersApi::demo();
        let order = api
            .create_order(None, "enr-1", "wechat_native", false)
            .expect("create");
        assert!(order.credential.is_some());
        assert_eq!(
            api.order_status(None, &order.id).expect("poll").status,
            "pending"
        );
        assert_eq!(
            api.order_status(None, &order.id).expect("poll").status,
            "paid"
        );
    }

    #[test]
    fn http_create_order_sends_deposit_consent_and_parses_credential() {
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
            let body = r#"{"data":{"createOrder":{"result":{"id":"ord-1","provider":"wechat_native","amountCents":9900,"status":"pending","expireAt":"2026-11-01T00:00:00Z"},"errors":[],"metadata":{"credential":"{\"type\":\"qr_code\",\"code_url\":\"https://pay.example/qr\"}"}}}}"#;
            let response = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
            stream.write_all(response.as_bytes()).expect("write");
        });

        let api = HttpOrdersApi::new(GraphqlClient::new(format!("http://{addr}/api/graphql")));
        let order = api
            .create_order(Some("token"), "enr-1", "wechat_native", true)
            .expect("order");
        assert_eq!(order.status, "pending");
        assert_eq!(
            qr_code_url(order.credential.as_deref().unwrap_or_default()),
            Some("https://pay.example/qr".to_string())
        );
        let sent = receiver.recv().expect("request");
        assert!(sent.contains("depositConsent"));
        assert!(sent.contains("enr-1"));
    }
}
