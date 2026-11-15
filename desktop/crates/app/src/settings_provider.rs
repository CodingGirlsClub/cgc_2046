//! Provider 表单的草稿数据与模型行解析（从 settings_window 拆出）。

use cgc_agent_provider::probe::RemoteModel;
use cgc_agent_provider::{ProviderError, ProviderProtocol, ThinkingMode};
use cgc_agent_store::{ModelPrefs, ProviderPrefs};
use gpui_kit::component::input::{InputState, TextareaState};
use gpui_kit::*;

use std::collections::BTreeSet;

#[derive(Clone)]
pub(crate) struct ModelFieldInputs {
    pub(crate) model_id: String,
    pub(crate) name_input: Entity<InputState>,
    pub(crate) context_input: Entity<InputState>,
    pub(crate) output_input: Entity<InputState>,
    pub(crate) efforts_input: Entity<InputState>,
    pub(crate) enabled: bool,
    pub(crate) thinking: bool,
    pub(crate) supports_tools: bool,
    pub(crate) supports_images: bool,
    pub(crate) thinking_mode: ThinkingMode,
    pub(crate) budget_input: Entity<InputState>,
}

/// Settings 里的 provider 编辑草稿（输入框懒创建，避免 new() 需要 window）。
#[derive(Clone)]
pub(crate) struct ProviderDraft {
    pub(crate) id: String,
    pub(crate) name: String,
    pub(crate) base_url: String,
    pub(crate) anthropic_url: String,
    pub(crate) responses_url: String,
    pub(crate) models_url: String,
    pub(crate) protocol: ProviderProtocol,
    pub(crate) models: String,
    pub(crate) has_key: bool,
    pub(crate) model_params: Vec<ModelPrefs>,
    pub(crate) builtin: bool,
    pub(crate) enabled: bool,
    pub(crate) base_url_input: Option<Entity<InputState>>,
    pub(crate) models_input: Option<Entity<TextareaState>>,
    pub(crate) api_key_input: Option<Entity<InputState>>,
    pub(crate) name_input: Option<Entity<InputState>>,
    pub(crate) model_fields: Vec<ModelFieldInputs>,
    pub(crate) key_editing: bool,
    pub(crate) confirm_clear: bool,
    /// 最近一次"获取模型"的结果；空表示尚未获取。
    pub(crate) remote_models: Vec<RemoteModel>,
    /// 已勾选的远程模型 id（获取后默认全选）。
    pub(crate) remote_selected: BTreeSet<String>,
    pub(crate) fetching_models: bool,
    pub(crate) fetch_error: Option<String>,
    /// 批量编辑：按文本编辑模型行。
    pub(crate) models_advanced_open: bool,
    /// 逐个检测模型的进行中状态与结果（model id → 是否可用）。
    pub(crate) testing_models: bool,
    pub(crate) model_tests: std::collections::BTreeMap<String, Result<(), ProviderError>>,
    /// 更多端点：Anthropic / Responses / 模型列表地址的输入框与展开状态。
    pub(crate) anthropic_url_input: Option<Entity<InputState>>,
    pub(crate) responses_url_input: Option<Entity<InputState>>,
    pub(crate) models_url_input: Option<Entity<InputState>>,
    pub(crate) endpoints_open: bool,
    /// 协议探测结果与进行中状态。
    pub(crate) protocol_probes: Vec<(ProviderProtocol, cgc_agent_provider::ProbeState)>,
    pub(crate) probing_protocols: bool,
}

/// 空串视为未设置，避免把空白地址写进 prefs。
pub(crate) fn optional(value: &str) -> Option<String> {
    let value = value.trim();
    (!value.is_empty()).then(|| value.to_string())
}

pub(crate) use cgc_agent_store::model_lines::{
    append_reasoning_efforts, format_model_lines, normalized_provider_name, parse_model_lines,
};

/// 从模型行文本里取某个模型的 efforts（卡片没有声明时用它保住用户手写的列）。
pub(crate) fn efforts_in_text(text: &str, id: &str) -> Vec<String> {
    parse_model_lines(text)
        .1
        .into_iter()
        .find(|model| model.id == id)
        .map(|model| model.reasoning_efforts)
        .unwrap_or_default()
}

/// 批量编辑后保存：文本与草稿不同就以文本为准，避免卡片同步把用户刚写的内容覆盖。
pub(crate) fn edited_models(
    draft_models: &str,
    textarea: &str,
) -> Option<(Vec<String>, Vec<ModelPrefs>)> {
    (draft_models != textarea).then(|| parse_model_lines(textarea))
}

/// 复制 Provider 时取一个不重名的显示名：`base 2`、`base 3`…（比较时忽略大小写与首尾空白）。
pub(crate) fn next_provider_name(base: &str, existing: &[String]) -> String {
    let base = base.trim();
    let mut serial = 2;
    loop {
        let candidate = format!("{base} {serial}");
        let taken = existing
            .iter()
            .any(|name| normalized_provider_name(name) == normalized_provider_name(&candidate));
        if !taken {
            return candidate;
        }
        serial += 1;
    }
}

impl ProviderDraft {
    pub(crate) fn from_prefs(provider: &ProviderPrefs) -> Self {
        Self {
            id: provider.id.clone(),
            name: provider.name.clone(),
            base_url: provider.base_url.clone(),
            anthropic_url: provider.anthropic_url.clone().unwrap_or_default(),
            responses_url: provider.responses_url.clone().unwrap_or_default(),
            models_url: provider.models_url.clone().unwrap_or_default(),
            protocol: provider.protocol,
            models: format_model_lines(provider),
            has_key: provider.has_key,
            model_params: provider.model_params.clone(),
            builtin: provider.builtin,
            enabled: provider.enabled,
            base_url_input: None,
            models_input: None,
            api_key_input: None,
            name_input: None,
            model_fields: Vec::new(),
            key_editing: false,
            confirm_clear: false,
            remote_models: Vec::new(),
            remote_selected: BTreeSet::new(),
            fetching_models: false,
            fetch_error: None,
            models_advanced_open: false,
            testing_models: false,
            model_tests: std::collections::BTreeMap::new(),
            anthropic_url_input: None,
            responses_url_input: None,
            models_url_input: None,
            endpoints_open: false,
            protocol_probes: Vec::new(),
            probing_protocols: false,
        }
    }

    pub(crate) fn new_custom(protocol: ProviderProtocol) -> Self {
        let serial = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|duration| duration.as_millis())
            .unwrap_or_default();
        Self {
            id: format!("custom-{serial}"),
            name: String::new(),
            base_url: String::new(),
            anthropic_url: String::new(),
            responses_url: String::new(),
            models_url: String::new(),
            protocol,
            models: String::new(),
            has_key: false,
            model_params: Vec::new(),
            builtin: false,
            enabled: true,
            base_url_input: None,
            models_input: None,
            api_key_input: None,
            name_input: None,
            model_fields: Vec::new(),
            key_editing: false,
            confirm_clear: false,
            remote_models: Vec::new(),
            remote_selected: BTreeSet::new(),
            fetching_models: false,
            fetch_error: None,
            models_advanced_open: false,
            testing_models: false,
            model_tests: std::collections::BTreeMap::new(),
            anthropic_url_input: None,
            responses_url_input: None,
            models_url_input: None,
            endpoints_open: false,
            protocol_probes: Vec::new(),
            probing_protocols: false,
        }
    }

    /// 用调用方当前表单里的 Base URL / Name 构造 ProviderPrefs。
    /// `save_provider_key` 必须先同步输入框，不能拿草稿里的旧值发起验证。
    pub(crate) fn to_prefs_with(&self, base_url: &str, name: &str) -> ProviderPrefs {
        let (models, model_params) = parse_model_lines(&self.models);
        ProviderPrefs {
            id: self.id.clone(),
            name: name.trim().to_string(),
            base_url: base_url.trim().to_string(),
            anthropic_url: optional(&self.anthropic_url),
            responses_url: optional(&self.responses_url),
            models_url: optional(&self.models_url),
            protocol: self.protocol,
            models,
            has_key: self.has_key,
            model_params,
            builtin: self.builtin,
            enabled: self.enabled,
        }
    }

    pub(crate) fn validate_thinking(&self, cx: &App) -> Result<(), String> {
        if self.protocol != ProviderProtocol::AnthropicCompatible {
            return Ok(());
        }
        for field in &self.model_fields {
            if !field.thinking || field.thinking_mode == ThinkingMode::Adaptive {
                continue;
            }
            let budget = field
                .budget_input
                .read(cx)
                .value()
                .trim()
                .parse::<u32>()
                .map_err(|_| "Thinking Budget 必须为整数".to_string())?;
            let context = field
                .context_input
                .read(cx)
                .value()
                .trim()
                .parse::<u32>()
                .unwrap_or(64000)
                .max(1);
            let output = field
                .output_input
                .read(cx)
                .value()
                .trim()
                .parse::<u32>()
                .unwrap_or(8000)
                .max(1)
                .min(context);
            if budget < 1024 || budget >= output {
                return Err("Thinking Budget 必须至少为 1024，且小于 Max Output Tokens".into());
            }
        }
        Ok(())
    }
}

#[derive(Default)]
pub(crate) struct KeyValidation {
    provider: Option<String>,
    serial: u64,
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) enum KeyValidationAction {
    Save,
    Validate(u64),
    Busy,
}

impl KeyValidation {
    pub(crate) fn provider(&self) -> Option<&str> {
        self.provider.as_deref()
    }

    pub(crate) fn begin(&mut self, provider: &ProviderPrefs) -> KeyValidationAction {
        if provider.protocol == ProviderProtocol::AnthropicCompatible {
            self.cancel();
            return KeyValidationAction::Save;
        }
        if self.provider.is_some() {
            return KeyValidationAction::Busy;
        }
        self.serial = self.serial.wrapping_add(1);
        self.provider = Some(provider.id.clone());
        KeyValidationAction::Validate(self.serial)
    }

    pub(crate) fn cancel(&mut self) {
        self.serial = self.serial.wrapping_add(1);
        self.provider = None;
    }

    pub(crate) fn finish(&mut self, provider_id: &str, serial: u64) -> bool {
        if self.provider() != Some(provider_id) || self.serial != serial {
            return false;
        }
        self.provider = None;
        true
    }
}

#[cfg(test)]
mod tests {
    use super::{
        edited_models, efforts_in_text, next_provider_name, KeyValidation, KeyValidationAction,
        ProviderDraft,
    };

    #[test]
    fn copied_provider_gets_a_free_name() {
        assert_eq!(next_provider_name("DeepSeek", &[]), "DeepSeek 2");
        assert_eq!(
            next_provider_name("DeepSeek", &["DeepSeek".to_string()]),
            "DeepSeek 2"
        );
        assert_eq!(
            next_provider_name(
                "DeepSeek",
                &["DeepSeek".to_string(), "deepseek 2".to_string()]
            ),
            "DeepSeek 3"
        );
    }

    #[test]
    fn efforts_in_text_reads_the_written_column() {
        let text = "m | 64000 | 8000 | true | true | true | false | efforts=low,high";
        assert_eq!(efforts_in_text(text, "m"), vec!["low", "high"]);
        assert!(efforts_in_text(text, "other").is_empty());
    }

    #[test]
    fn edited_models_prefer_the_textarea() {
        let draft = "m | 64000 | 8000 | true | true | true | false";
        let edited = "m | 64000 | 8000 | true | true | true | false | efforts=low,high";
        let (models, params) = edited_models(draft, edited).expect("edited");
        assert_eq!(models, vec!["m"]);
        assert_eq!(params[0].reasoning_efforts, vec!["low", "high"]);
        assert!(edited_models(draft, draft).is_none());
    }

    #[test]
    fn blank_endpoints_are_not_saved() {
        let mut draft =
            ProviderDraft::new_custom(cgc_agent_provider::ProviderProtocol::OpenAiCompatible);
        draft.anthropic_url = "   ".into();
        let prefs = draft.to_prefs_with("https://example.test", "Example");
        assert_eq!(prefs.anthropic_url, None);
        draft.anthropic_url = "https://anthropic.example".into();
        let prefs = draft.to_prefs_with("https://example.test", "Example");
        assert_eq!(
            prefs.anthropic_url.as_deref(),
            Some("https://anthropic.example")
        );
    }

    #[test]
    fn draft_keeps_enabled_flag_through_prefs_roundtrip() {
        let mut draft =
            ProviderDraft::new_custom(cgc_agent_provider::ProviderProtocol::OpenAiCompatible);
        draft.enabled = false;
        let prefs = draft.to_prefs_with("https://example.test", "Example");
        assert!(!prefs.enabled);
    }

    #[test]
    fn to_prefs_with_uses_current_form_values() {
        let draft =
            ProviderDraft::new_custom(cgc_agent_provider::ProviderProtocol::OpenAiCompatible);
        assert!(draft.name.is_empty(), "a new provider starts unnamed");
        assert!(
            draft.base_url.is_empty(),
            "a new provider starts without a URL"
        );
        assert!(
            draft.models.is_empty(),
            "a new provider starts without models"
        );
        let prefs = draft.to_prefs_with("https://new.example/v1/", "New Provider");
        assert_eq!(prefs.base_url, "https://new.example/v1/");
        assert_eq!(prefs.name, "New Provider");
        assert!(prefs.models.is_empty());
    }

    #[test]
    fn direct_key_save_rejects_an_older_validation_completion() {
        let mut validation = KeyValidation::default();
        let previous =
            ProviderDraft::new_custom(cgc_agent_provider::ProviderProtocol::OpenAiCompatible)
                .to_prefs_with("https://previous.test", "Previous");
        let current =
            ProviderDraft::new_custom(cgc_agent_provider::ProviderProtocol::AnthropicCompatible)
                .to_prefs_with("https://current.test", "Current");
        let KeyValidationAction::Validate(serial) = validation.begin(&previous) else {
            panic!("OpenAI keys require validation");
        };
        assert_eq!(validation.begin(&current), KeyValidationAction::Save);
        assert!(
            !validation.finish(&previous.id, serial),
            "a direct save supersedes the earlier validation"
        );
        assert!(validation.provider().is_none());
    }

    #[test]
    fn cancelled_validation_cannot_complete_a_newer_request() {
        let mut validation = KeyValidation::default();
        let provider =
            ProviderDraft::new_custom(cgc_agent_provider::ProviderProtocol::OpenAiCompatible)
                .to_prefs_with("https://provider.test", "Provider");
        let KeyValidationAction::Validate(old) = validation.begin(&provider) else {
            panic!()
        };
        assert_eq!(validation.begin(&provider), KeyValidationAction::Busy);
        validation.cancel();
        let KeyValidationAction::Validate(current) = validation.begin(&provider) else {
            panic!()
        };
        assert!(!validation.finish(&provider.id, old));
        assert_eq!(validation.provider(), Some(provider.id.as_str()));
        assert!(validation.finish(&provider.id, current));
        assert!(!validation.finish(&provider.id, current));
    }
}
