//! 供应商模型列表的探测：`GET {base}/models` 的解析与错误分类。
//!
//! 只做只读取证，不发起对话请求。字段缺失是正常情况（多数网关只回 id），
//! 解析必须宽容：单条坏数据不能拖垮整张列表。

use crate::error::ProviderError;

/// 远程列表里的一个模型；`None` 表示供应商没有说明该字段。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RemoteModel {
    pub id: String,
    pub name: Option<String>,
    pub context_window: Option<u32>,
    pub max_output_tokens: Option<u32>,
    pub supports_images: Option<bool>,
    pub reasoning_efforts: Vec<String>,
}

/// 一个模型 id 不能破坏 `name | context | …` 的行格式，也不能是空或超长。
fn valid_model_id(id: &str) -> bool {
    !id.is_empty() && id.chars().count() <= 128 && !id.chars().any(|c| c == '|' || c.is_control())
}

fn number(value: Option<&serde_json::Value>) -> Option<u32> {
    match value? {
        serde_json::Value::Number(n) => n.as_u64().and_then(|n| u32::try_from(n).ok()),
        serde_json::Value::String(s) => s.trim().parse::<u32>().ok(),
        _ => None,
    }
}

fn images(row: &serde_json::Value) -> Option<bool> {
    let list = row.get("input_modalities")?.as_array()?;
    Some(list.iter().any(|value| value.as_str() == Some("image")))
}

fn efforts(row: &serde_json::Value) -> Vec<String> {
    let levels = row
        .get("effort")
        .and_then(|effort| effort.get("supported_levels"))
        .and_then(serde_json::Value::as_array)
        .or_else(|| {
            row.get("supported_reasoning_levels")
                .and_then(serde_json::Value::as_array)
        });
    levels
        .map(|levels| {
            levels
                .iter()
                .filter_map(|value| match value {
                    serde_json::Value::String(level) => Some(level.clone()),
                    serde_json::Value::Object(object) => {
                        object.get("effort")?.as_str().map(str::to_string)
                    }
                    _ => None,
                })
                .filter(|level| !level.is_empty() && level.chars().count() <= 32)
                .collect()
        })
        .unwrap_or_default()
}

/// 解析 `/models` 的响应体：`data[]` 或 `models[]`，字段缺失即 `None`。
pub fn parse_models(body: &str) -> Result<Vec<RemoteModel>, ProviderError> {
    let value: serde_json::Value = serde_json::from_str(body)
        .map_err(|_| ProviderError::invalid_response("not a model list"))?;
    let rows = value
        .get("data")
        .and_then(serde_json::Value::as_array)
        .or_else(|| value.get("models").and_then(serde_json::Value::as_array))
        .ok_or_else(|| ProviderError::invalid_response("not a model list"))?;
    let mut out = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for row in rows {
        let id = row
            .get("id")
            .and_then(serde_json::Value::as_str)
            .or_else(|| row.get("name").and_then(serde_json::Value::as_str))
            .unwrap_or_default()
            .trim()
            .to_string();
        if !valid_model_id(&id) || !seen.insert(id.clone()) {
            continue;
        }
        out.push(RemoteModel {
            name: row
                .get("name")
                .and_then(serde_json::Value::as_str)
                .map(str::to_string),
            context_window: number(row.get("context_window"))
                .or_else(|| number(row.get("context_length"))),
            max_output_tokens: number(row.get("max_output_tokens")),
            supports_images: images(row),
            reasoning_efforts: efforts(row),
            id,
        });
    }
    Ok(out)
}

/// 该错误是否表示"这个端点没有模型列表"，而不是 Key 被拒。
pub fn list_unsupported(error: &ProviderError) -> bool {
    match error {
        ProviderError::Api {
            status: Some(404), ..
        } => true,
        ProviderError::InvalidResponse(message) => message.contains("not a model list"),
        _ => false,
    }
}

fn map_ureq_error(error: ureq::Error) -> ProviderError {
    match error {
        ureq::Error::StatusCode(status) => ProviderError::api(status, "http status error"),
        ureq::Error::Timeout(_) => ProviderError::transport("request timed out"),
        ureq::Error::Io(error) => ProviderError::transport(error.to_string()),
        other => ProviderError::transport(other.to_string()),
    }
}

fn truncate(text: &str, max_chars: usize) -> String {
    text.chars().take(max_chars).collect()
}

/// `/models` 的地址：去掉 Base URL 末尾的斜杠再拼接。
pub fn models_url(base_url: &str) -> String {
    format!("{}/models", base_url.trim_end_matches('/'))
}

/// 当前构建的 ureq 没启用 `socks-proxy`：环境里有 SOCKS 代理时请求必然失败，
/// 且底层报错含义不明。发请求前直接给出可操作的提示。
fn socks_proxy_note() -> Option<String> {
    ["ALL_PROXY", "all_proxy", "HTTPS_PROXY", "https_proxy"]
        .iter()
        .filter_map(|key| std::env::var(key).ok())
        .find(|value| is_socks_url(value))
        .map(|_| {
            "检测到 SOCKS 代理（ALL_PROXY/HTTPS_PROXY），当前客户端不支持；请清除该环境变量后重启再试"
                .to_string()
        })
}

fn is_socks_url(value: &str) -> bool {
    let value = value.trim().to_ascii_lowercase();
    value.starts_with("socks4://")
        || value.starts_with("socks4a://")
        || value.starts_with("socks5://")
        || value.starts_with("socks5h://")
}

/// 用当前 Base URL 与 API Key 读取供应商的模型列表；同时验证 Key 是否被接受。
pub fn list_models(base_url: &str, api_key: &str) -> Result<Vec<RemoteModel>, ProviderError> {
    if let Some(note) = socks_proxy_note() {
        return Err(ProviderError::transport(note));
    }
    let url = models_url(base_url);
    let agent = ureq::Agent::new_with_config(
        ureq::Agent::config_builder()
            .http_status_as_error(false)
            .timeout_global(Some(std::time::Duration::from_secs(10)))
            .build(),
    );
    let mut response = agent
        .get(&url)
        .header("authorization", format!("Bearer {api_key}"))
        .call()
        .map_err(map_ureq_error)?;
    let status = response.status();
    let text = response
        .body_mut()
        .read_to_string()
        .map_err(|error| ProviderError::transport(error.to_string()))?;
    if !status.is_success() {
        return Err(ProviderError::api(status.as_u16(), truncate(&text, 500)));
    }
    parse_models(&text)
}

/// 检测单个模型的最小对话请求地址。
pub fn chat_url(base_url: &str) -> String {
    format!("{}/chat/completions", base_url.trim_end_matches('/'))
}

/// 检测用的最小对话请求体：一句话，最多 1 个 token。
pub fn chat_body(model: &str) -> serde_json::Value {
    serde_json::json!({
        "model": model,
        "messages": [{"role": "user", "content": "ping"}],
        "max_tokens": 1,
        "stream": false
    })
}

/// 逐个模型发最小对话请求，找出供应商列表里其实不可用的模型。
/// 每批 4 个并发；结果顺序与输入一致。
pub fn test_models(
    base_url: &str,
    api_key: &str,
    models: &[String],
) -> Vec<(String, Result<(), String>)> {
    if let Some(note) = socks_proxy_note() {
        return models
            .iter()
            .map(|model| (model.clone(), Err(note.clone())))
            .collect();
    }
    let mut results = Vec::with_capacity(models.len());
    for chunk in models.chunks(4) {
        let mut batch: Vec<(String, Result<(), String>)> = std::thread::scope(|scope| {
            let handles: Vec<_> = chunk
                .iter()
                .map(|model| {
                    let model = model.clone();
                    scope.spawn(move || {
                        let result =
                            test_model(base_url, api_key, &model).map_err(|error| error.to_string());
                        (model, result)
                    })
                })
                .collect();
            handles
                .into_iter()
                .map(|handle| handle.join().expect("model probe thread"))
                .collect()
        });
        results.append(&mut batch);
    }
    results
}

fn test_model(base_url: &str, api_key: &str, model: &str) -> Result<(), ProviderError> {
    let agent = ureq::Agent::new_with_config(
        ureq::Agent::config_builder()
            .http_status_as_error(false)
            .timeout_global(Some(std::time::Duration::from_secs(20)))
            .build(),
    );
    let mut response = agent
        .post(&chat_url(base_url))
        .header("authorization", format!("Bearer {api_key}"))
        .header("content-type", "application/json")
        .send_json(chat_body(model))
        .map_err(map_ureq_error)?;
    let status = response.status();
    if status.is_success() {
        return Ok(());
    }
    let text = response.body_mut().read_to_string().unwrap_or_default();
    Err(ProviderError::api(status.as_u16(), truncate(&text, 300)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_deepseek_model_metadata() {
        let body = r#"{"object":"list","data":[
            {"id":"deepseek-flash","object":"model","owned_by":"deepseek","name":"DeepSeek-V4.1-Flash",
             "context_window":1048576,"max_output_tokens":393216,
             "input_modalities":["text","image"],
             "effort":{"supported_levels":["low","high","max"],"default_level":"high"}},
            {"id":"deepseek-v4-pro","context_window":1048576,"max_output_tokens":393216,
             "input_modalities":["text"],
             "effort":{"supported_levels":["low","high","max"]}}
        ]}"#;
        let models = parse_models(body).expect("parse");
        assert_eq!(models.len(), 2);
        assert_eq!(models[0].id, "deepseek-flash");
        assert_eq!(models[0].context_window, Some(1_048_576));
        assert_eq!(models[0].max_output_tokens, Some(393_216));
        assert_eq!(models[0].supports_images, Some(true));
        assert_eq!(models[0].reasoning_efforts, vec!["low", "high", "max"]);
        assert_eq!(models[1].supports_images, Some(false));
    }

    #[test]
    fn parses_a_list_of_ids_alone() {
        let body = r#"{"object":"list","data":[{"id":"gpt-x"},{"id":"gpt-y"}]}"#;
        let models = parse_models(body).expect("parse");
        assert_eq!(models.len(), 2);
        assert_eq!(models[0].context_window, None);
        assert_eq!(models[0].supports_images, None);
        assert!(models[0].reasoning_efforts.is_empty());
    }

    #[test]
    fn accepts_models_array_and_numeric_strings() {
        let body = r#"{"models":[{"id":"m1","context_window":"128000","max_output_tokens":8192}]}"#;
        let models = parse_models(body).expect("parse");
        assert_eq!(models[0].context_window, Some(128_000));
        assert_eq!(models[0].max_output_tokens, Some(8_192));
    }

    #[test]
    fn reads_openrouter_style_context_length() {
        let body = r#"{"data":[{"id":"claude-x","context_length":200000}]}"#;
        let models = parse_models(body).expect("parse");
        assert_eq!(models[0].context_window, Some(200_000));
    }

    #[test]
    fn drops_ids_that_would_corrupt_the_model_lines() {
        let body = r#"{"data":[{"id":"ok"},{"id":"bad|pipe"},{"id":"bad\nnewline"},{"id":""}]}"#;
        let models = parse_models(body).expect("parse");
        assert_eq!(
            models.iter().map(|m| m.id.as_str()).collect::<Vec<_>>(),
            vec!["ok"]
        );
    }

    #[test]
    fn a_non_list_body_is_an_unsupported_endpoint() {
        let error = parse_models("<html>nope</html>").expect_err("not a list");
        assert!(list_unsupported(&error));
    }

    #[test]
    fn not_found_is_an_unsupported_endpoint() {
        assert!(list_unsupported(&ProviderError::api(404, "not found")));
        assert!(!list_unsupported(&ProviderError::api(401, "unauthorized")));
    }

    #[test]
    fn chat_probe_targets_completions_with_a_tiny_body() {
        assert_eq!(
            chat_url("https://api.deepseek.com/"),
            "https://api.deepseek.com/chat/completions"
        );
        let body = chat_body("deepseek-flash");
        assert_eq!(body["model"], "deepseek-flash");
        assert_eq!(body["max_tokens"], 1);
        assert_eq!(body["stream"], false);
        assert_eq!(body["messages"][0]["content"], "ping");
    }

    #[test]
    fn socks_proxy_urls_are_recognized() {
        assert!(is_socks_url("socks5h://127.0.0.1:7890"));
        assert!(is_socks_url("SOCKS5://host:1080"));
        assert!(is_socks_url(" socks4a://x "));
        assert!(!is_socks_url("http://127.0.0.1:8080"));
        assert!(!is_socks_url(""));
    }

    #[test]
    fn models_url_normalizes_trailing_slashes() {
        assert_eq!(
            models_url("https://api.deepseek.com"),
            "https://api.deepseek.com/models"
        );
        assert_eq!(
            models_url("https://api.moonshot.cn/v1/"),
            "https://api.moonshot.cn/v1/models"
        );
    }
}
