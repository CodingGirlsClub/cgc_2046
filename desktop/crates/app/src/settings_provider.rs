//! Provider 表单的草稿数据与模型行解析（从 settings_window 拆出）。

use cgc_agent_provider::{ProviderProtocol, ThinkingMode};
use cgc_agent_store::{ModelPrefs, ProviderPrefs};
use gpui_kit::component::input::{InputState, TextareaState};
use gpui_kit::*;

#[derive(Clone)]
pub(crate) struct ModelFieldInputs {
    pub(crate) model_id: String,
    pub(crate) name_input: Entity<InputState>,
    pub(crate) context_input: Entity<InputState>,
    pub(crate) output_input: Entity<InputState>,
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
    pub(crate) protocol: ProviderProtocol,
    pub(crate) models: String,
    pub(crate) has_key: bool,
    pub(crate) model_params: Vec<ModelPrefs>,
    pub(crate) builtin: bool,
    pub(crate) base_url_input: Option<Entity<InputState>>,
    pub(crate) models_input: Option<Entity<TextareaState>>,
    pub(crate) api_key_input: Option<Entity<InputState>>,
    pub(crate) name_input: Option<Entity<InputState>>,
    pub(crate) model_fields: Vec<ModelFieldInputs>,
    pub(crate) key_editing: bool,
    pub(crate) confirm_clear: bool,
}

pub(crate) use cgc_agent_store::model_lines::{
    append_reasoning_efforts, format_model_lines, parse_model_lines,
};

impl ProviderDraft {
    pub(crate) fn from_prefs(provider: &ProviderPrefs) -> Self {
        Self {
            id: provider.id.clone(),
            name: provider.name.clone(),
            base_url: provider.base_url.clone(),
            protocol: provider.protocol,
            models: format_model_lines(provider),
            has_key: provider.has_key,
            model_params: provider.model_params.clone(),
            builtin: provider.builtin,
            base_url_input: None,
            models_input: None,
            api_key_input: None,
            name_input: None,
            model_fields: Vec::new(),
            key_editing: false,
            confirm_clear: false,
        }
    }

    pub(crate) fn new_custom(protocol: ProviderProtocol) -> Self {
        let serial = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|duration| duration.as_millis())
            .unwrap_or_default();
        Self {
            id: format!("custom-{serial}"),
            name: protocol.name().to_string(),
            base_url: protocol.default_url().to_string(),
            protocol,
            models: match protocol {
                ProviderProtocol::OpenAiCompatible => {
                    "gpt-4o-mini | 128000 | 16384 | false | true | true".to_string()
                }
                ProviderProtocol::AnthropicCompatible => String::new(),
            },
            has_key: false,
            model_params: Vec::new(),
            builtin: false,
            base_url_input: None,
            models_input: None,
            api_key_input: None,
            name_input: None,
            model_fields: Vec::new(),
            key_editing: false,
            confirm_clear: false,
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
            protocol: self.protocol,
            models,
            has_key: self.has_key,
            model_params,
            builtin: false,
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
    use super::{KeyValidation, KeyValidationAction, ProviderDraft};

    #[test]
    fn to_prefs_with_uses_current_form_values() {
        let draft =
            ProviderDraft::new_custom(cgc_agent_provider::ProviderProtocol::OpenAiCompatible);
        let prefs = draft.to_prefs_with("https://new.example/v1/", "New Provider");
        assert_eq!(prefs.base_url, "https://new.example/v1/");
        assert_eq!(prefs.name, "New Provider");
        assert!(!prefs.models.is_empty());
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
