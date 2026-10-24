//! Provider 表单的草稿数据与模型行解析（从 settings_window 拆出）。

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
}

/// Settings 里的 provider 编辑草稿（输入框懒创建，避免 new() 需要 window）。
#[derive(Clone)]
pub(crate) struct ProviderDraft {
    pub(crate) id: String,
    pub(crate) name: String,
    pub(crate) base_url: String,
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

pub(crate) use cgc_agent_store::model_lines::{format_model_lines, parse_model_lines};

impl ProviderDraft {
    pub(crate) fn from_prefs(provider: &ProviderPrefs) -> Self {
        Self {
            id: provider.id.clone(),
            name: provider.name.clone(),
            base_url: provider.base_url.clone(),
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

    pub(crate) fn new_custom() -> Self {
        let serial = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|duration| duration.as_millis())
            .unwrap_or_default();
        Self {
            id: format!("custom-{serial}"),
            name: "OpenAI Compatible".to_string(),
            base_url: "https://api.openai.com/v1".to_string(),
            models: "gpt-4o-mini | 128000 | 16384 | false | true | true".to_string(),
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

    pub(crate) fn to_prefs(&self) -> ProviderPrefs {
        let (models, model_params) = parse_model_lines(&self.models);
        ProviderPrefs {
            id: self.id.clone(),
            name: self.name.clone(),
            base_url: self.base_url.trim().to_string(),
            models,
            has_key: self.has_key,
            model_params,
            builtin: false,
        }
    }
}
