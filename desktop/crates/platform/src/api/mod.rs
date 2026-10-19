//! GraphQL 传输层（story 3.1 起）：统一的 HTTP/GraphQL 客户端，供各 domain 的 API 实现复用。
//!
//! 只做「发请求 + 解 errors」，不解释业务实体；实体解析放在对应 domain crate，
//! 保证 GraphQL 单一来源（脊柱 AD-2）且各 feature 不各写一套传输。

use serde_json::Value;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ApiError {
    /// 网络不可达 / 超时 / 响应不是合法 JSON。
    Transport(String),
    /// GraphQL errors 非空（带可选业务 code）。
    Graphql {
        code: Option<String>,
        message: String,
    },
}

impl ApiError {
    pub fn diagnostic(&self) -> String {
        match self {
            ApiError::Transport(reason) => format!("transport error: {reason}"),
            ApiError::Graphql { code, message } => match code {
                Some(code) => format!("graphql error {code}: {message}"),
                None => format!("graphql error: {message}"),
            },
        }
    }
}

#[derive(Clone, Debug)]
pub struct GraphqlClient {
    endpoint: String,
}

impl GraphqlClient {
    pub fn new(endpoint: impl Into<String>) -> Self {
        Self {
            endpoint: endpoint.into(),
        }
    }

    pub fn from_env() -> Self {
        let endpoint = std::env::var("CGC_API_URL")
            .unwrap_or_else(|_| "http://localhost:4000/api/graphql".to_string());
        Self::new(endpoint)
    }

    pub fn endpoint(&self) -> &str {
        &self.endpoint
    }

    /// POST 一个 GraphQL 请求；`token` 存在时加 `Authorization: Bearer`。
    /// GraphQL errors 非空 → `ApiError::Graphql`（HTTP 仍是 200 的语义）。
    pub fn post(
        &self,
        token: Option<&str>,
        query: &str,
        variables: Value,
    ) -> Result<Value, ApiError> {
        let mut request = ureq::post(&self.endpoint).header("content-type", "application/json");
        if let Some(token) = token {
            request = request.header("authorization", format!("Bearer {token}"));
        }

        let body = serde_json::json!({ "query": query, "variables": variables });
        let mut response = request
            .send_json(&body)
            .map_err(|error| ApiError::Transport(error.to_string()))?;
        let payload = response
            .body_mut()
            .read_json::<Value>()
            .map_err(|error| ApiError::Transport(error.to_string()))?;

        if let Some(errors) = payload.get("errors").and_then(Value::as_array) {
            if let Some(first) = errors.first() {
                let code = first
                    .get("code")
                    .and_then(Value::as_str)
                    .or_else(|| first.get("extensions")?.get("code")?.as_str())
                    .map(str::to_string);
                let message = first
                    .get("message")
                    .and_then(Value::as_str)
                    .unwrap_or("graphql request failed")
                    .to_string();
                return Err(ApiError::Graphql { code, message });
            }
        }

        Ok(payload)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::TcpListener;

    fn spawn_mock(status: u16, body: &'static str) -> (String, std::sync::mpsc::Receiver<String>) {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let addr = listener.local_addr().expect("addr");
        let (sender, receiver) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept");
            let mut request = Vec::new();
            let mut buf = [0u8; 2048];
            let header_end = loop {
                let read = stream.read(&mut buf).expect("read");
                if read == 0 {
                    break request.len();
                }
                request.extend_from_slice(&buf[..read]);
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
                let read = stream.read(&mut buf).expect("read body");
                if read == 0 {
                    break;
                }
                request.extend_from_slice(&buf[..read]);
            }
            let _ = sender.send(String::from_utf8_lossy(&request).to_string());
            let response = format!(
                "HTTP/1.1 {status} OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
            stream.write_all(response.as_bytes()).expect("write");
        });
        (format!("http://{addr}/api/graphql"), receiver)
    }

    #[test]
    fn post_sends_bearer_and_parses_data() {
        let (endpoint, received) = spawn_mock(200, r#"{"data":{"ok":true}}"#);
        let client = GraphqlClient::new(endpoint);
        let value = client
            .post(Some("jwt.token"), "query { ok }", serde_json::json!({}))
            .expect("post ok");

        assert_eq!(value["data"]["ok"], true);
        let request = received.recv().expect("request");
        assert!(
            request.contains("authorization: Bearer jwt.token")
                || request
                    .to_ascii_lowercase()
                    .contains("authorization: bearer jwt.token")
        );
    }

    #[test]
    fn graphql_errors_map_to_api_error_with_code() {
        let (endpoint, _rx) = spawn_mock(
            200,
            r#"{"errors":[{"message":"Not authenticated","code":"unauthorized"}]}"#,
        );
        let client = GraphqlClient::new(endpoint);
        let error = client
            .post(None, "mutation { x }", serde_json::json!({}))
            .unwrap_err();
        assert_eq!(
            error,
            ApiError::Graphql {
                code: Some("unauthorized".to_string()),
                message: "Not authenticated".to_string(),
            }
        );
    }
}
