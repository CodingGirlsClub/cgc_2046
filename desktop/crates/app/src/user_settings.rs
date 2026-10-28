//! 用户可编辑的桌面端设置文件（`~/.cgc2046/settings.json`）。
//!
//! 对齐 Zed 的 `settings.json` 习惯：GUI 不管理的参数放这里，手改即生效。
//! 当前承载 `agent.thread_summary_model`（标题摘要模型）与
//! `agent.model_parameters`（每次请求的温度）；文件缺失按默认值，非法 JSON
//! 打诊断并回退默认，不阻塞启动。

use serde::Deserialize;
use std::path::Path;

/// 设置文件根结构。未知字段忽略，方便后续扩展新 section。
#[derive(Clone, Debug, Default, Deserialize, PartialEq)]
#[serde(default)]
pub struct UserSettings {
    pub agent: AgentSettings,
    pub api: ApiSettings,
}

/// 后端端点覆盖（`api.url`）。
///
/// 内测包把生产端点编进二进制（`CGC_DEFAULT_API_URL`）；这里给测试/排查留一个
/// 不改包就能切后端（staging、本机）的出口，手改后重启生效。空白视为未设置。
#[derive(Clone, Debug, Default, Deserialize, PartialEq)]
#[serde(default)]
pub struct ApiSettings {
    pub url: Option<String>,
}

#[derive(Clone, Debug, Default, Deserialize, PartialEq)]
#[serde(default)]
pub struct AgentSettings {
    /// Thread Title 使用的独立摘要模型；未配置/不可用时回退当前对话模型。
    pub thread_summary_model: Option<LanguageModelSelection>,
    /// 语言模型请求参数；从后往前第一条匹配 provider/model 的条目生效。
    pub model_parameters: Vec<LanguageModelParameters>,
}

/// 对齐 Zed `LanguageModelSelection`（标题摘要只需要 provider/model）。
#[derive(Clone, Debug, Deserialize, PartialEq)]
pub struct LanguageModelSelection {
    pub provider: String,
    pub model: String,
}

/// 对齐 Zed `LanguageModelParameters`：provider/model 都可选。
#[derive(Clone, Debug, Default, Deserialize, PartialEq)]
#[serde(default)]
pub struct LanguageModelParameters {
    pub provider: Option<String>,
    pub model: Option<String>,
    pub temperature: Option<f32>,
}

impl UserSettings {
    /// 读取设置文件；文件不存在视为默认设置。
    pub fn load(path: &Path) -> Result<Self, String> {
        match std::fs::read_to_string(path) {
            Ok(text) => serde_json::from_str(&text)
                .map_err(|error| format!("解析用户设置失败（{}）：{error}", path.display())),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(Self::default()),
            Err(error) => Err(format!("读取用户设置失败（{}）：{error}", path.display())),
        }
    }

    /// 对齐 Zed `AgentSettings::temperature_for_model`：从末尾往前扫，第一条
    /// provider/model 都匹配的条目生效（两者都可省略）；命中即返回该条的
    /// `temperature`，即使它是 `None` 也不再继续向前找。
    pub fn temperature_for_model(&self, provider: &str, model: &str) -> Option<f32> {
        for entry in self.agent.model_parameters.iter().rev() {
            if entry
                .provider
                .as_deref()
                .is_some_and(|value| value != provider)
            {
                continue;
            }
            if entry.model.as_deref().is_some_and(|value| value != model) {
                continue;
            }
            return entry.temperature;
        }
        None
    }
}

/// 运行时入口：每次请求前调用，手改设置文件无需重启。
pub fn load_default() -> UserSettings {
    let path = cgc_platform::paths::AppPaths::user_settings_file();
    match UserSettings::load(&path) {
        Ok(settings) => settings,
        Err(error) => {
            log::warn!(target: "settings", "{error}");
            UserSettings::default()
        }
    }
}

#[cfg(test)]
mod tests {
    // 显式导入：避免 `use super::*` 的 glob 展开在 rustc 下触发 SIGBUS。
    use super::UserSettings;
    use std::path::PathBuf;

    fn temp_path(name: &str) -> PathBuf {
        std::env::temp_dir().join(format!("cgc-user-settings-{name}-{}", std::process::id()))
    }

    fn settings(json: &str) -> UserSettings {
        serde_json::from_str(json).expect("parse settings")
    }

    #[test]
    fn parses_api_url_override() {
        let parsed = settings(
            r#"{
                "api": { "url": "https://settings.example/api/graphql" }
            }"#,
        );
        assert_eq!(
            parsed.api.url.as_deref(),
            Some("https://settings.example/api/graphql")
        );
    }

    #[test]
    fn api_section_is_optional() {
        let parsed = settings(r#"{"agent":{}}"#);
        assert_eq!(parsed.api.url, None);
        let parsed = settings(r#"{"api":{}}"#);
        assert_eq!(parsed.api.url, None);
    }

    #[test]
    fn missing_file_returns_defaults() {
        let path = temp_path("missing");
        let _ = std::fs::remove_file(&path);
        assert_eq!(
            UserSettings::load(&path).expect("load"),
            UserSettings::default()
        );
    }

    #[test]
    fn parses_zed_style_model_parameters() {
        let parsed = settings(
            r#"{
                "agent": {
                    "model_parameters": [
                        { "provider": "deepseek", "model": "deepseek-flash", "temperature": 0.2 }
                    ]
                }
            }"#,
        );
        assert_eq!(
            parsed.temperature_for_model("deepseek", "deepseek-flash"),
            Some(0.2)
        );
        assert_eq!(parsed.temperature_for_model("deepseek", "other"), None);
        assert_eq!(
            parsed.temperature_for_model("other", "deepseek-flash"),
            None
        );
    }

    #[test]
    fn parses_thread_summary_model() {
        let parsed = settings(
            r#"{
                "agent": {
                    "thread_summary_model": { "provider": "deepseek", "model": "deepseek-flash" }
                }
            }"#,
        );
        let selected = parsed.agent.thread_summary_model.expect("summary model");
        assert_eq!(selected.provider, "deepseek");
        assert_eq!(selected.model, "deepseek-flash");

        let none = settings(r#"{"agent":{}}"#);
        assert!(none.agent.thread_summary_model.is_none());
    }

    #[test]
    fn provider_or_model_may_be_omitted() {
        let parsed = settings(
            r#"{
                "agent": {
                    "model_parameters": [
                        { "provider": "deepseek", "temperature": 0.1 },
                        { "model": "deepseek-flash", "temperature": 0.2 },
                        { "temperature": 0.3 }
                    ]
                }
            }"#,
        );
        // 最后一条（两者都省略）匹配所有模型。
        assert_eq!(
            parsed.temperature_for_model("deepseek", "deepseek-flash"),
            Some(0.3)
        );
        assert_eq!(parsed.temperature_for_model("any", "model"), Some(0.3));
    }

    #[test]
    fn later_entries_win_and_matched_none_stops_the_scan() {
        let parsed = settings(
            r#"{
                "agent": {
                    "model_parameters": [
                        { "provider": "deepseek", "temperature": 0.1 },
                        { "provider": "deepseek", "model": "deepseek-flash", "temperature": 0.5 }
                    ]
                }
            }"#,
        );
        assert_eq!(
            parsed.temperature_for_model("deepseek", "deepseek-flash"),
            Some(0.5),
            "更靠后的具体条目覆盖 provider 级配置"
        );

        let parsed = settings(
            r#"{
                "agent": {
                    "model_parameters": [
                        { "provider": "deepseek", "temperature": 0.1 },
                        { "provider": "deepseek", "model": "deepseek-flash" }
                    ]
                }
            }"#,
        );
        assert_eq!(
            parsed.temperature_for_model("deepseek", "deepseek-flash"),
            None,
            "命中但 temperature 为 null 时停止扫描，不回退到更早条目"
        );
    }

    #[test]
    fn unknown_fields_are_ignored_for_forward_compatibility() {
        let parsed = settings(
            r#"{
                "agent": {
                    "future_setting": true,
                    "model_parameters": [{ "provider": "p", "temperature": 0.4 }]
                },
                "unknown_section": { "x": 1 }
            }"#,
        );
        assert_eq!(parsed.temperature_for_model("p", "m"), Some(0.4));
    }

    #[test]
    fn invalid_json_is_reported_with_path() {
        let path = temp_path("invalid");
        std::fs::write(&path, "{ not json").expect("write");
        let error = UserSettings::load(&path).expect_err("invalid json must fail");
        assert!(error.contains("解析用户设置失败"), "diagnostic: {error}");
        assert!(error.contains(&path.display().to_string()));
        let _ = std::fs::remove_file(&path);
    }
}
