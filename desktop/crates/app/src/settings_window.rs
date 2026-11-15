//! 独立设置窗口（对齐 Zed：`cmd-,` / `ctrl-,` 打开独立 SettingsWindow；
//! 右上角用户菜单的 Settings 也打开它，而不是主窗口内路由）。
//!
//! 参考 Zed `settings_ui/src/settings_ui.rs::open_settings_editor_with`：
//! 已有窗口则激活复用，否则 `open_window` 新开居中窗口；主窗口仍保留自己的
//! 导航壳，设置不再占用 footer 导航位（`app.settings` 路由仅内部保留）。

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use cgc_agent_provider::{
    list_models, list_models_at, list_unsupported, probe::RemoteModel, test_models,
    validate_credentials, ProviderError, ProviderErrorCategory, ProviderProtocol, ThinkingMode,
};
use cgc_agent_store::{
    builtin_providers, is_builtin_provider_id, next_provider_id, normalized_provider_name,
    ModelPrefs, ProviderPrefs,
};
use gpui_kit::component::button::{Button, ButtonVariants};
use gpui_kit::component::checkbox::Checkbox;
use gpui_kit::component::combobox::{Combobox, ComboboxState};
use gpui_kit::component::group_box::GroupBoxVariant;
use gpui_kit::component::input::{Input, InputState, Textarea, TextareaState};
use gpui_kit::component::searchable_list::SearchableVec;
use gpui_kit::component::setting::{
    NumberFieldOptions, SelectIndex, SettingField, SettingGroup, SettingItem, SettingPage, Settings,
};
use gpui_kit::component::switch::Switch;
use gpui_kit::component::Sizable;
use gpui_kit::component::TitleBar;
use gpui_kit::prelude::FluentBuilder;
use gpui_kit::InteractiveElement;
use gpui_kit::*;

use crate::build_info;
use crate::i18n::{translate, Key, Language};
use crate::native_runtime::{NativeRuntimeError, NativeRuntimeHandle};
use crate::preferences::{self, CursorBlinkPreference};
use crate::provider_fetch::merge_remote_models;
use crate::provider_settings::{ProviderPrefsChange, ProviderSettings};
use crate::root_view::{title_bar_left_inset, TITLEBAR_HEIGHT};
use crate::settings_provider::{
    append_reasoning_efforts, format_model_lines, next_provider_name, optional, parse_model_lines,
    KeyValidation, KeyValidationAction, ModelFieldInputs, ProviderDraft,
};
use crate::theme::{self, space, RADIUS_MEDIUM, RADIUS_SMALL};
use cgc_platform::session::AuthApi;

#[derive(Clone, Debug, Default, PartialEq, Eq)]
enum AiRoute {
    #[default]
    General,
    Providers,
    NewProvider(String),
    EditProvider(String),
}

// 页面顺序：账号 / 通用 / Window & Layout / Panels / AI / 关于。
const SETTINGS_PAGE_ACCOUNT: usize = 0;
const SETTINGS_PAGE_AI: usize = 4;

pub struct SettingsWindowView {
    language: Language,
    email: Option<String>,
    user_id: String,
    workspace: Option<String>,
    token: String,
    api: Arc<dyn AuthApi + Send + Sync>,
    focus: FocusHandle,
    close_to_tray: Arc<AtomicBool>,
    revoking: bool,
    revoked: bool,
    error: Option<String>,
    notice: Option<String>,
    provider_drafts: Vec<ProviderDraft>,
    ai_view: AiRoute,
    settings_page: usize,
    settings_nonce: u64,
    key_validation: KeyValidation,
    provider_settings: ProviderSettings,
    runtime: Option<NativeRuntimeHandle>,
    /// Stage 3.3：清空 ACP 对话历史的二次确认状态与结果提示。
    clear_acp_history_armed: Arc<AtomicBool>,
    clear_acp_history_notice: Arc<Mutex<Option<String>>>,
    /// 「重置当前工作台布局」的二次确认状态与结果提示。
    reset_workspace_layout_armed: Arc<AtomicBool>,
    reset_workspace_layout_notice: Arc<Mutex<Option<String>>>,
    /// 主窗口弱引用：显示偏好保存后立即应用。
    root: WeakEntity<crate::root_view::RootView>,
}

impl SettingsWindowView {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        language: Language,
        email: Option<String>,
        user_id: String,
        workspace: Option<String>,
        token: String,
        api: Arc<dyn AuthApi + Send + Sync>,
        close_to_tray: Arc<AtomicBool>,
        runtime: Option<NativeRuntimeHandle>,
        root: WeakEntity<crate::root_view::RootView>,
        cx: &mut Context<Self>,
    ) -> Self {
        let provider_settings = ProviderSettings::new();
        let prefs = provider_settings.load();
        let mut drafts: Vec<ProviderDraft> = builtin_providers()
            .iter()
            .map(ProviderDraft::from_prefs)
            .collect();
        for provider in &prefs.providers {
            match drafts.iter_mut().find(|draft| draft.id == provider.id) {
                Some(slot) => *slot = ProviderDraft::from_prefs(provider),
                None => drafts.push(ProviderDraft::from_prefs(provider)),
            }
        }
        Self {
            language,
            email,
            user_id,
            workspace,
            token,
            api,
            focus: cx.focus_handle(),
            close_to_tray,
            revoking: false,
            revoked: false,
            error: None,
            notice: None,
            provider_drafts: drafts,
            ai_view: AiRoute::General,
            settings_page: SETTINGS_PAGE_ACCOUNT,
            settings_nonce: 0,
            key_validation: KeyValidation::default(),
            provider_settings,
            runtime,
            clear_acp_history_armed: Arc::new(AtomicBool::new(false)),
            clear_acp_history_notice: Arc::new(Mutex::new(None)),
            reset_workspace_layout_armed: Arc::new(AtomicBool::new(false)),
            reset_workspace_layout_notice: Arc::new(Mutex::new(None)),
            root,
        }
    }

    /// 从其他窗口打开 Settings 时直接定位到 AI 页。
    pub fn open_ai(&mut self, cx: &mut Context<Self>) {
        self.ai_view = AiRoute::General;
        self.settings_page = SETTINGS_PAGE_AI;
        self.settings_nonce = self.settings_nonce.wrapping_add(1);
        cx.notify();
    }

    /// 从其他窗口直接定位到 LLM Providers 配置页。
    pub fn open_llm_providers(&mut self, cx: &mut Context<Self>) {
        self.ai_view = AiRoute::Providers;
        self.settings_page = SETTINGS_PAGE_AI;
        self.settings_nonce = self.settings_nonce.wrapping_add(1);
        cx.notify();
    }

    pub fn focus_handle(&self) -> FocusHandle {
        self.focus.clone()
    }

    fn revoke(&mut self, cx: &mut Context<Self>) {
        if self.revoking || self.revoked || self.token.is_empty() {
            return;
        }
        self.revoking = true;
        self.error = None;
        let api = self.api.clone();
        let token = self.token.clone();
        let task = cx
            .background_executor()
            .spawn(async move { api.revoke(&token) });
        cx.spawn(async move |this, cx| {
            let result = task.await;
            let _ = this.update(cx, |this, cx| {
                this.revoking = false;
                match result {
                    Ok(()) => this.revoked = true,
                    Err(error) => this.error = Some(error.diagnostic()),
                }
                cx.notify();
            });
        })
        .detach();
    }

    fn ensure_provider_inputs(
        &mut self,
        index: usize,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(draft) = self.provider_drafts.get(index).cloned() else {
            return;
        };
        if draft.base_url_input.is_none() {
            let value = draft.base_url.clone();
            let input = cx.new(|cx| {
                InputState::new(window, cx)
                    .placeholder("https://api.example.com/v1")
                    .default_value(value)
            });
            self.provider_drafts[index].base_url_input = Some(input);
        }
        if draft.models_input.is_none() {
            let value = draft.models.clone();
            let input = cx.new(|cx| {
                TextareaState::new(window, cx).placeholder(
                    "每行一个模型：模型名 | context | max_output | thinking(\n例：deepseek-flash | 1000000 | 384000 | true)",
                )
            });
            input.update(cx, |state, cx| state.set_value(value, window, cx));
            self.provider_drafts[index].models_input = Some(input);
        }
        let (_, parsed_models) = parse_model_lines(&draft.models);
        let ids_match = self.provider_drafts[index].model_fields.len() == parsed_models.len()
            && self.provider_drafts[index]
                .model_fields
                .iter()
                .zip(&parsed_models)
                .all(|(field, model)| field.model_id == model.id);
        if !ids_match {
            let mut fields = Vec::new();
            for model in &parsed_models {
                let context = model.context_window.to_string();
                let output = model.max_output_tokens.to_string();
                let name = model.id.clone();
                let name_input = cx.new(|cx| InputState::new(window, cx).default_value(name));
                let context_input = cx.new(|cx| InputState::new(window, cx).default_value(context));
                let output_input = cx.new(|cx| InputState::new(window, cx).default_value(output));
                let budget = match model.thinking_mode {
                    ThinkingMode::Budget { budget_tokens } => budget_tokens,
                    _ => 4096,
                };
                let budget_input =
                    cx.new(|cx| InputState::new(window, cx).default_value(budget.to_string()));
                fields.push(ModelFieldInputs {
                    model_id: model.id.clone(),
                    name_input,
                    context_input,
                    output_input,
                    enabled: model.enabled,
                    thinking: model.supports_thinking,
                    supports_tools: model.supports_tools,
                    supports_images: model.supports_images,
                    thinking_mode: model.thinking_mode,
                    budget_input,
                });
            }
            self.provider_drafts[index].model_fields = fields;
        }
        if !draft.builtin && draft.name_input.is_none() {
            let value = draft.name.clone();
            let input = cx.new(|cx| {
                InputState::new(window, cx)
                    .placeholder("Provider Name")
                    .default_value(value)
            });
            self.provider_drafts[index].name_input = Some(input);
        }
        if draft.api_key_input.is_none() {
            let input =
                cx.new(|cx| InputState::new(window, cx).placeholder("API Key（保存到系统钥匙串）"));
            self.provider_drafts[index].api_key_input = Some(input);
        }
        if draft.anthropic_url_input.is_none() {
            let value = draft.anthropic_url.clone();
            let input = cx.new(|cx| {
                InputState::new(window, cx)
                    .placeholder("https://api.example.com/anthropic（可选）")
                    .default_value(value)
            });
            self.provider_drafts[index].anthropic_url_input = Some(input);
        }
        if draft.responses_url_input.is_none() {
            let value = draft.responses_url.clone();
            let input = cx.new(|cx| {
                InputState::new(window, cx)
                    .placeholder("https://api.example.com/v1（可选）")
                    .default_value(value)
            });
            self.provider_drafts[index].responses_url_input = Some(input);
        }
        if draft.models_url_input.is_none() {
            let value = draft.models_url.clone();
            let input = cx.new(|cx| {
                InputState::new(window, cx)
                    .placeholder("https://api.example.com/models（可选）")
                    .default_value(value)
            });
            self.provider_drafts[index].models_url_input = Some(input);
        }
        if !draft.remote_models.is_empty() && draft.remote_picker.is_none() {
            let items: Vec<String> = draft
                .remote_models
                .iter()
                .map(|model| model.id.clone())
                .collect();
            let selected: Vec<gpui_kit::component::IndexPath> = (0..items.len())
                .map(gpui_kit::component::IndexPath::new)
                .collect();
            let picker = cx.new(|cx| {
                ComboboxState::new(SearchableVec::new(items), selected, window, cx)
                    .multiple(true)
                    .searchable(true)
            });
            self.provider_drafts[index].remote_picker = Some(picker);
        }
    }

    fn sync_model_fields(&mut self, index: usize, window: &mut Window, cx: &mut Context<Self>) {
        let Some(draft) = self.provider_drafts.get_mut(index) else {
            return;
        };
        if draft.model_fields.is_empty() {
            return;
        }
        let text = draft
            .model_fields
            .iter()
            .map(|field| {
                let context = field.context_input.read(cx).value().trim().to_string();
                let output = field.output_input.read(cx).value().trim().to_string();
                let name = field.name_input.read(cx).value().trim().to_string();
                let name = if name.is_empty() {
                    field.model_id.clone()
                } else {
                    name
                };
                let context: u32 = context.parse().unwrap_or(64_000).max(1);
                let output: u32 = output.parse().unwrap_or(8_000).max(1).min(context);
                let mut line = format!(
                    "{} | {} | {} | {} | {} | {} | {}",
                    name,
                    context,
                    output,
                    field.thinking,
                    field.enabled,
                    field.supports_tools,
                    field.supports_images
                );
                if draft.protocol == ProviderProtocol::AnthropicCompatible && field.thinking {
                    match field.thinking_mode {
                        ThinkingMode::Adaptive => line.push_str(" | adaptive"),
                        _ => {
                            line.push_str(" | budget | ");
                            line.push_str(field.budget_input.read(cx).value().trim());
                        }
                    }
                }
                if let Some(previous) = draft
                    .model_params
                    .iter()
                    .find(|model| model.id == field.model_id)
                {
                    append_reasoning_efforts(&mut line, &previous.reasoning_efforts);
                }
                line
            })
            .collect::<Vec<_>>()
            .join("\n");
        draft.models = text.clone();
        if let Some(input) = draft.models_input.clone() {
            input.update(cx, |state, cx| state.set_value(text, window, cx));
        }
    }

    fn toggle_model_field(
        &mut self,
        index: usize,
        model_index: usize,
        flag: u8,
        cx: &mut Context<Self>,
    ) {
        let Some(draft) = self.provider_drafts.get_mut(index) else {
            return;
        };
        if let Some(field) = draft.model_fields.get_mut(model_index) {
            match flag {
                1 => field.thinking = !field.thinking,
                2 => field.supports_tools = !field.supports_tools,
                3 => field.supports_images = !field.supports_images,
                4 => {
                    field.thinking_mode = if field.thinking_mode == ThinkingMode::Adaptive {
                        ThinkingMode::Budget {
                            budget_tokens: 4096,
                        }
                    } else {
                        ThinkingMode::Adaptive
                    }
                }
                _ => field.enabled = !field.enabled,
            }
        }
        cx.notify();
    }

    fn remove_model_field(
        &mut self,
        index: usize,
        model_index: usize,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.sync_model_fields(index, window, cx);
        let Some(draft) = self.provider_drafts.get_mut(index) else {
            return;
        };
        let mut lines: Vec<String> = draft.models.lines().map(str::to_string).collect();
        if model_index < lines.len() {
            lines.remove(model_index);
        }
        draft.models = lines.join("\n");
        draft.model_fields.clear();
        if let Some(input) = draft.models_input.clone() {
            input.update(cx, |state, cx| {
                state.set_value(draft.models.clone(), window, cx)
            });
        }
        cx.notify();
    }

    fn add_model(&mut self, index: usize, window: &mut Window, cx: &mut Context<Self>) {
        self.sync_model_fields(index, window, cx);
        let Some(draft) = self.provider_drafts.get_mut(index) else {
            return;
        };
        let mut text = draft.models.clone();
        if !text.trim().is_empty() {
            text.push('\n');
        }
        text.push_str("new-model | 64000 | 8000 | false | true");
        draft.models = text.clone();
        draft.model_fields.clear();
        if let Some(input) = draft.models_input.clone() {
            input.update(cx, |state, cx| state.set_value(text, window, cx));
        }
        cx.notify();
    }

    fn restore_provider_default(
        &mut self,
        index: usize,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(draft) = self.provider_drafts.get(index).cloned() else {
            return;
        };
        self.cancel_validation_for(&draft.id);
        let Some(default) = builtin_providers()
            .into_iter()
            .find(|provider| provider.id == draft.id)
        else {
            return;
        };
        let models = format_model_lines(&default);
        if let Some(input) = draft.models_input.clone() {
            input.update(cx, |state, cx| state.set_value(models.clone(), window, cx));
        }
        if let Some(input) = draft.base_url_input.clone() {
            input.update(cx, |state, cx| {
                state.set_value(default.base_url.clone(), window, cx)
            });
        }
        if let Some(slot) = self.provider_drafts.get_mut(index) {
            slot.base_url = default.base_url.clone();
            slot.models = models;
            slot.model_params = default.model_params.clone();
        }
        self.notice = Some("已恢复内置默认（保存后生效）".to_string());
        cx.notify();
    }

    /// 离开编辑页：丢弃未保存的草稿，回到已保存（或内置默认）的状态。
    fn leave_provider_form(&mut self, cx: &mut Context<Self>) {
        let target = match &self.ai_view {
            AiRoute::EditProvider(id) | AiRoute::NewProvider(id) => Some(id.clone()),
            _ => None,
        };
        if let Some(id) = target {
            self.cancel_validation_for(&id);
            let prefs = self.provider_settings.load();
            let restored = prefs.provider(&id).cloned().or_else(|| {
                builtin_providers()
                    .into_iter()
                    .find(|provider| provider.id == id)
            });
            match restored {
                Some(provider) => {
                    if let Some(slot) = self.provider_drafts.iter_mut().find(|draft| draft.id == id)
                    {
                        *slot = ProviderDraft::from_prefs(&provider);
                    }
                }
                None => self.provider_drafts.retain(|draft| draft.id != id),
            }
        }
        self.ai_view = AiRoute::Providers;
        self.error = None;
        cx.notify();
    }

    fn provider_from_draft_inputs(&self, draft: &ProviderDraft, cx: &App) -> ProviderPrefs {
        let base_url = draft
            .base_url_input
            .as_ref()
            .map(|input| input.read(cx).value().trim().to_string())
            .filter(|value| !value.is_empty())
            .unwrap_or_else(|| draft.base_url.clone());
        let name = draft
            .name_input
            .as_ref()
            .map(|input| input.read(cx).value().trim().to_string())
            .filter(|value| !value.is_empty())
            .unwrap_or_else(|| draft.name.clone());
        draft.to_prefs_with(&base_url, &name)
    }

    fn cancel_key_validation(&mut self) {
        self.key_validation.cancel();
    }

    fn cancel_validation_for(&mut self, provider_id: &str) {
        if self.key_validation.provider() == Some(provider_id) {
            self.cancel_key_validation();
        }
    }

    fn save_provider_key(&mut self, index: usize, window: &mut Window, cx: &mut Context<Self>) {
        if !self.validate_thinking_fields(index, cx) {
            return;
        }
        self.sync_model_fields(index, window, cx);
        self.sync_endpoint_inputs(index, cx);
        let Some(draft) = self.provider_drafts.get(index).cloned() else {
            return;
        };
        let Some(input) = draft.api_key_input.clone() else {
            return;
        };
        let key = input.read(cx).value().trim().to_string();
        if key.is_empty() {
            self.error = Some("API Key 不能为空".to_string());
            cx.notify();
            return;
        }
        let provider = self.provider_from_draft_inputs(&draft, cx);
        self.begin_key_validation(provider, key, cx);
    }

    fn begin_key_validation(
        &mut self,
        provider: ProviderPrefs,
        key: String,
        cx: &mut Context<Self>,
    ) {
        let serial = match self.key_validation.begin(&provider) {
            KeyValidationAction::Save => {
                self.save_key_configuration(provider, key, cx);
                return;
            }
            KeyValidationAction::Busy => {
                self.error = Some("正在验证上一个 API Key，请稍候".to_string());
                cx.notify();
                return;
            }
            KeyValidationAction::Validate(serial) => serial,
        };
        self.error = None;
        self.notice = Some(format!("正在验证 {} API Key…", provider.name));
        cx.notify();
        let task_provider = provider.clone();
        let task_key = key.clone();
        let task = cx
            .background_executor()
            .spawn(async move { validate_credentials(&task_provider.base_url, &task_key) });
        cx.spawn(async move |this, cx| {
            let result = task.await;
            let _ = this.update(cx, |this, cx| {
                this.finish_key_validation(provider, key, serial, result, cx);
            });
        })
        .detach();
    }

    fn finish_key_validation(
        &mut self,
        provider: ProviderPrefs,
        key: String,
        serial: u64,
        result: Result<(), ProviderError>,
        cx: &mut Context<Self>,
    ) {
        if !self.key_validation.finish(&provider.id, serial) {
            return;
        }
        match result {
            Ok(()) => {
                self.save_key_configuration(provider, key, cx);
                return;
            }
            Err(error) => {
                self.notice = None;
                self.error = Some(format!(
                    "API Key 验证失败：{}",
                    provider_validation_message(&error)
                ));
            }
        }
        cx.notify();
    }

    fn save_key_configuration(
        &mut self,
        mut provider: ProviderPrefs,
        key: String,
        cx: &mut Context<Self>,
    ) {
        if let Err(error) = self.provider_settings.apply(ProviderPrefsChange::SaveKey {
            provider: provider.clone(),
            key,
        }) {
            self.error = Some(error.to_string());
            cx.notify();
            return;
        }
        provider.has_key = true;
        if let Some(draft) = self
            .provider_drafts
            .iter_mut()
            .find(|draft| draft.id == provider.id)
        {
            draft.base_url = provider.base_url.clone();
            draft.name = provider.name.clone();
            draft.models = format_model_lines(&provider);
            draft.model_params = provider.model_params.clone();
            draft.has_key = true;
            draft.builtin = provider.builtin;
            draft.enabled = provider.enabled;
            draft.key_editing = false;
            draft.api_key_input = None;
        }
        self.error = None;
        // 保存后留在表单：用户还要接着点「获取模型」或微调模型参数。
        self.ai_view = AiRoute::EditProvider(provider.id.clone());
        let saved = if provider.protocol == ProviderProtocol::AnthropicCompatible {
            format!("{} API Key 已保存", provider.name)
        } else {
            format!("{} API Key 已验证并保存", provider.name)
        };
        let needs_models = self
            .provider_drafts
            .iter()
            .find(|draft| draft.id == provider.id)
            .is_some_and(|draft| draft.models.trim().is_empty());
        if needs_models {
            if let Some(index) = self
                .provider_drafts
                .iter()
                .position(|draft| draft.id == provider.id)
            {
                self.fetch_models(index, cx);
            }
        }
        self.refresh_provider_runtime(saved, cx);
    }

    fn validate_thinking_fields(&mut self, index: usize, cx: &mut Context<Self>) -> bool {
        if let Some(Err(error)) = self
            .provider_drafts
            .get(index)
            .map(|draft| draft.validate_thinking(cx))
        {
            self.error = Some(error);
            cx.notify();
            return false;
        }
        true
    }

    fn refresh_provider_runtime(&mut self, success: String, cx: &mut Context<Self>) {
        let Some(runtime) = self.runtime.clone() else {
            self.notice = Some(format!("{success}；重新打开客户端后生效"));
            cx.notify();
            return;
        };
        self.notice = Some(format!("{success}，正在应用…"));
        cx.notify();
        let operation = runtime.refresh_providers();
        cx.spawn(async move |this, cx| {
            let result = operation.await.map(|_| ());
            let _ = this.update(cx, |this, cx| {
                let (notice, error) = refresh_outcome(&success, result);
                this.notice = notice;
                this.error = error;
                cx.notify();
            });
        })
        .detach();
    }

    fn sync_all_draft_names(&mut self, cx: &mut Context<Self>) {
        for draft in &mut self.provider_drafts {
            if let Some(input) = &draft.name_input {
                let name = input.read(cx).value().trim().to_string();
                if !name.is_empty() {
                    draft.name = name;
                }
            }
        }
    }

    fn save_provider(&mut self, index: usize, window: &mut Window, cx: &mut Context<Self>) {
        if !self.validate_thinking_fields(index, cx) {
            return;
        }
        self.sync_all_draft_names(cx);
        let Some(draft) = self.provider_drafts.get(index).cloned() else {
            return;
        };
        self.cancel_validation_for(&draft.id);
        let Some(base_url_input) = draft.base_url_input.clone() else {
            return;
        };
        let Some(models_input) = draft.models_input.clone() else {
            return;
        };
        self.sync_model_fields(index, window, cx);
        let Some(draft) = self.provider_drafts.get(index).cloned() else {
            return;
        };
        let base_url = base_url_input.read(cx).value().trim().to_string();
        let name = draft
            .name_input
            .as_ref()
            .map(|input| input.read(cx).value().trim().to_string())
            .unwrap_or_else(|| draft.name.clone());
        let models_text = models_input.read(cx).value().to_string();
        let (models, model_params) = parse_model_lines(&models_text);
        if base_url.is_empty() || models.is_empty() || name.is_empty() {
            self.error = Some("Provider Name、Base URL 与至少一个 Model 不能为空".to_string());
            cx.notify();
            return;
        }
        if self
            .provider_drafts
            .iter()
            .enumerate()
            .any(|(other_index, other)| {
                other_index != index
                    && normalized_provider_name(&other.name) == normalized_provider_name(&name)
            })
        {
            self.error = Some(format!("Provider Name「{name}」已存在，请换一个名称"));
            cx.notify();
            return;
        }
        let mut provider = ProviderPrefs {
            id: draft.id.clone(),
            name: name.clone(),
            base_url,
            anthropic_url: optional(&draft.anthropic_url),
            responses_url: optional(&draft.responses_url),
            models_url: optional(&draft.models_url),
            models,
            has_key: draft.has_key,
            model_params,
            builtin: draft.builtin || is_builtin_provider_id(&draft.id),
            enabled: draft.enabled,
            protocol: draft.protocol,
        };
        if let Some(api_key_input) = draft.api_key_input.clone() {
            let api_key = api_key_input.read(cx).value().trim().to_string();
            if api_key.is_empty() && self.provider_settings.has_key(&provider.id) {
                provider.has_key = true;
            }
            if !api_key.is_empty() {
                self.begin_key_validation(provider, api_key, cx);
                return;
            }
        }
        match self
            .provider_settings
            .apply(ProviderPrefsChange::SaveProvider(provider.clone()))
        {
            Ok(()) => {
                self.error = None;
                self.ai_view = AiRoute::EditProvider(provider.id.clone());
                if let Some(draft) = self.provider_drafts.get_mut(index) {
                    draft.base_url = provider.base_url.clone();
                    draft.name = provider.name.clone();
                    draft.models = format_model_lines(&provider);
                    draft.model_params = provider.model_params.clone();
                    draft.has_key = provider.has_key;
                    draft.builtin = provider.builtin;
                }
                self.refresh_provider_runtime("Provider 已保存".to_string(), cx);
                return;
            }
            Err(error) => self.error = Some(error.to_string()),
        }
        cx.notify();
    }

    fn reset_provider_key(&mut self, index: usize, cx: &mut Context<Self>) {
        let Some(draft) = self.provider_drafts.get(index).cloned() else {
            return;
        };
        self.cancel_validation_for(&draft.id);
        match self.provider_settings.apply(ProviderPrefsChange::ClearKey {
            provider_id: draft.id.clone(),
        }) {
            Ok(()) => {
                if let Some(draft) = self.provider_drafts.get_mut(index) {
                    draft.has_key = false;
                    draft.key_editing = false;
                    draft.confirm_clear = false;
                    draft.api_key_input = None;
                }
                self.error = None;
                self.refresh_provider_runtime("API Key 已清除".to_string(), cx);
                return;
            }
            Err(error) => self.error = Some(error.to_string()),
        }
        cx.notify();
    }

    fn add_provider(&mut self, protocol: ProviderProtocol, cx: &mut Context<Self>) {
        let draft = ProviderDraft::new_custom(protocol);
        let id = draft.id.clone();
        self.provider_drafts.push(draft);
        self.ai_view = AiRoute::NewProvider(id);
        self.notice = Some("新增 Provider：填写名称/URL/模型后保存".to_string());
        cx.notify();
    }

    /// 停用/启用：只改开关并落盘，不读取输入框，避免把未保存的表单编辑一并提交。
    fn set_provider_enabled(&mut self, index: usize, enabled: bool, cx: &mut Context<Self>) {
        let Some(draft) = self.provider_drafts.get(index).cloned() else {
            return;
        };
        let mut provider = draft.to_prefs_with(&draft.base_url, &draft.name);
        provider.enabled = enabled;
        provider.builtin |= is_builtin_provider_id(&provider.id);
        match self
            .provider_settings
            .apply(ProviderPrefsChange::SaveProvider(provider.clone()))
        {
            Ok(()) => {
                if let Some(slot) = self.provider_drafts.get_mut(index) {
                    slot.enabled = enabled;
                    slot.builtin = provider.builtin;
                }
                self.error = None;
                let message = if enabled {
                    format!("{} 已启用", provider.name)
                } else {
                    format!("{} 已停用", provider.name)
                };
                self.refresh_provider_runtime(message, cx);
            }
            Err(error) => {
                self.error = Some(error.to_string());
                cx.notify();
            }
        }
    }

    /// 复制一个 Provider：新 id/名称、独立输入框、不复制 Key。
    fn clone_provider(&mut self, index: usize, cx: &mut Context<Self>) {
        let Some(source) = self.provider_drafts.get(index).cloned() else {
            return;
        };
        let ids: Vec<String> = self
            .provider_drafts
            .iter()
            .map(|draft| draft.id.clone())
            .collect();
        let names: Vec<String> = self
            .provider_drafts
            .iter()
            .map(|draft| draft.name.clone())
            .collect();
        let mut copy = source.clone();
        copy.id = next_provider_id(&source.id, &ids);
        copy.name = next_provider_name(&source.name, &names);
        copy.has_key = false;
        copy.enabled = true;
        copy.builtin = false;
        copy.key_editing = true;
        copy.confirm_clear = false;
        // 输入框 Entity 共享会导致编辑副本时改到原件，全部丢弃由 ensure_provider_inputs 重建。
        copy.base_url_input = None;
        copy.models_input = None;
        copy.name_input = None;
        copy.api_key_input = None;
        copy.model_fields.clear();
        copy.remote_models.clear();
        copy.remote_picker = None;
        copy.fetching_models = false;
        copy.fetch_error = None;
        copy.models_advanced_open = false;
        copy.testing_models = false;
        copy.model_tests.clear();
        copy.anthropic_url_input = None;
        copy.responses_url_input = None;
        copy.models_url_input = None;
        copy.endpoints_open = false;
        let provider = copy.to_prefs_with(&copy.base_url, &copy.name);
        match self
            .provider_settings
            .apply(ProviderPrefsChange::SaveProvider(provider))
        {
            Ok(()) => {
                let id = copy.id.clone();
                let name = copy.name.clone();
                self.provider_drafts.push(copy);
                self.error = None;
                self.ai_view = AiRoute::EditProvider(id);
                self.notice = Some(format!("已复制为 {name}：填入 API Key 后保存"));
                cx.notify();
            }
            Err(error) => {
                self.error = Some(error.to_string());
                cx.notify();
            }
        }
    }

    /// 用当前表单里的 URL / Key（或已保存的 Key）读取供应商模型列表。
    fn fetch_models(&mut self, index: usize, cx: &mut Context<Self>) {
        let Some(draft) = self.provider_drafts.get(index).cloned() else {
            return;
        };
        if draft.fetching_models {
            return;
        }
        let base_url = draft
            .base_url_input
            .as_ref()
            .map(|input| input.read(cx).value().trim().to_string())
            .filter(|value| !value.is_empty())
            .unwrap_or_else(|| draft.base_url.clone());
        let typed = draft
            .api_key_input
            .as_ref()
            .map(|input| input.read(cx).value().trim().to_string())
            .unwrap_or_default();
        let key = if typed.is_empty() {
            self.provider_settings.key(&draft.id).unwrap_or_default()
        } else {
            typed
        };
        if base_url.is_empty() {
            self.error = Some("请先填写 API URL".to_string());
            cx.notify();
            return;
        }
        if key.is_empty() {
            self.error = Some("请先填写 API Key（保存前也可以用来获取）".to_string());
            cx.notify();
            return;
        }
        if let Some(slot) = self.provider_drafts.get_mut(index) {
            slot.fetching_models = true;
            slot.fetch_error = None;
        }
        self.error = None;
        cx.notify();
        let list_url = optional(&draft.models_url);
        let task = cx.background_executor().spawn(async move {
            match list_url {
                Some(url) => list_models_at(&url, &key),
                None => list_models(&base_url, &key),
            }
        });
        cx.spawn(async move |this, cx| {
            let result = task.await;
            let _ = this.update(cx, |this, cx| this.finish_fetch_models(index, result, cx));
        })
        .detach();
    }

    fn finish_fetch_models(
        &mut self,
        index: usize,
        result: Result<Vec<RemoteModel>, ProviderError>,
        cx: &mut Context<Self>,
    ) {
        let Some(draft) = self.provider_drafts.get_mut(index) else {
            return;
        };
        draft.fetching_models = false;
        draft.remote_picker = None;
        match result {
            Ok(models) if models.is_empty() => {
                draft.remote_models.clear();
                draft.fetch_error =
                    Some("供应商返回了空列表：请检查 URL，或用批量编辑手填模型".to_string());
            }
            Ok(models) => {
                draft.remote_models = models;
                draft.fetch_error = None;
            }
            Err(error) if list_unsupported(&error) => {
                draft.remote_models.clear();
                draft.fetch_error = Some("该服务不提供模型列表，请用批量编辑手填".to_string());
            }
            Err(error) => {
                draft.remote_models.clear();
                let detail: String = error.to_string().chars().take(140).collect();
                draft.fetch_error = Some(format!(
                    "获取失败：{}（{detail}）",
                    provider_validation_message(&error)
                ));
            }
        }
        cx.notify();
    }

    /// 对当前启用中的模型各发一次最小对话请求，标出供应商列表里其实不可用的模型。
    fn test_all_models(&mut self, index: usize, cx: &mut Context<Self>) {
        let Some(draft) = self.provider_drafts.get(index).cloned() else {
            return;
        };
        if draft.testing_models {
            return;
        }
        let base_url = draft
            .base_url_input
            .as_ref()
            .map(|input| input.read(cx).value().trim().to_string())
            .filter(|value| !value.is_empty())
            .unwrap_or_else(|| draft.base_url.clone());
        let typed = draft
            .api_key_input
            .as_ref()
            .map(|input| input.read(cx).value().trim().to_string())
            .unwrap_or_default();
        let key = if typed.is_empty() {
            self.provider_settings.key(&draft.id).unwrap_or_default()
        } else {
            typed
        };
        if key.is_empty() {
            self.error = Some("请先填写或保存 API Key".to_string());
            cx.notify();
            return;
        }
        let mut models: Vec<String> = draft
            .model_params
            .iter()
            .filter(|model| model.enabled)
            .map(|model| model.id.clone())
            .collect();
        if models.is_empty() {
            models = parse_model_lines(&draft.models).0;
        }
        if models.is_empty() {
            self.error = Some("没有可检测的模型".to_string());
            cx.notify();
            return;
        }
        if let Some(slot) = self.provider_drafts.get_mut(index) {
            slot.testing_models = true;
            slot.model_tests.clear();
        }
        self.error = None;
        cx.notify();
        let task = cx
            .background_executor()
            .spawn(async move { test_models(&base_url, &key, &models) });
        cx.spawn(async move |this, cx| {
            let results = task.await;
            let _ = this.update(cx, |this, cx| this.finish_test_models(index, results, cx));
        })
        .detach();
    }

    fn finish_test_models(
        &mut self,
        index: usize,
        results: Vec<(String, Result<(), ProviderError>)>,
        cx: &mut Context<Self>,
    ) {
        if let Some(draft) = self.provider_drafts.get_mut(index) {
            draft.testing_models = false;
            draft.model_tests = results.into_iter().collect();
        }
        cx.notify();
    }

    /// 把勾选的远程模型并入草稿（本地已有参数保留），随后由 ensure 重建模型卡片。
    fn apply_fetched_models(&mut self, index: usize, cx: &mut Context<Self>) {
        let Some(draft) = self.provider_drafts.get(index).cloned() else {
            return;
        };
        let Some(picker) = draft.remote_picker.clone() else {
            return;
        };
        let chosen: std::collections::BTreeSet<String> =
            picker.read(cx).selected_values().into_iter().collect();
        if chosen.is_empty() {
            self.error = Some("请至少选择一个模型".to_string());
            cx.notify();
            return;
        }
        let catalog: Vec<ModelPrefs> = builtin_providers()
            .into_iter()
            .flat_map(|provider| provider.model_params)
            .collect();
        let (models, params) =
            merge_remote_models(&draft.remote_models, &draft.model_params, &chosen, &catalog);
        let text = format_model_lines(&ProviderPrefs {
            models: models.clone(),
            model_params: params.clone(),
            ..Default::default()
        });
        if let Some(slot) = self.provider_drafts.get_mut(index) {
            slot.models = text;
            slot.model_params = params;
            slot.model_fields.clear();
            slot.remote_models.clear();
            slot.remote_picker = None;
            slot.fetch_error = None;
        }
        self.error = None;
        self.notice = Some(format!("已加入 {} 个模型（保存后生效）", models.len()));
        cx.notify();
    }

    fn dismiss_fetched_models(&mut self, index: usize, cx: &mut Context<Self>) {
        if let Some(slot) = self.provider_drafts.get_mut(index) {
            slot.remote_models.clear();
            slot.remote_picker = None;
            slot.fetch_error = None;
        }
        cx.notify();
    }

    fn toggle_models_advanced(&mut self, index: usize, cx: &mut Context<Self>) {
        if let Some(slot) = self.provider_drafts.get_mut(index) {
            slot.models_advanced_open = !slot.models_advanced_open;
        }
        cx.notify();
    }

    /// 把“更多端点”输入框的当前值写回草稿（保存与验证前调用）。
    fn sync_endpoint_inputs(&mut self, index: usize, cx: &App) {
        let Some(draft) = self.provider_drafts.get(index).cloned() else {
            return;
        };
        let read = |input: &Option<Entity<InputState>>| {
            input
                .as_ref()
                .map(|input| input.read(cx).value().trim().to_string())
                .unwrap_or_default()
        };
        let anthropic_url = read(&draft.anthropic_url_input);
        let responses_url = read(&draft.responses_url_input);
        let models_url = read(&draft.models_url_input);
        if let Some(slot) = self.provider_drafts.get_mut(index) {
            slot.anthropic_url = anthropic_url;
            slot.responses_url = responses_url;
            slot.models_url = models_url;
        }
    }

    fn set_provider_protocol(
        &mut self,
        index: usize,
        protocol: ProviderProtocol,
        cx: &mut Context<Self>,
    ) {
        if let Some(slot) = self.provider_drafts.get_mut(index) {
            slot.protocol = protocol;
        }
        cx.notify();
    }

    fn toggle_endpoints(&mut self, index: usize, cx: &mut Context<Self>) {
        if let Some(slot) = self.provider_drafts.get_mut(index) {
            slot.endpoints_open = !slot.endpoints_open;
        }
        cx.notify();
    }

    fn remove_provider(&mut self, index: usize, cx: &mut Context<Self>) {
        let Some(draft) = self.provider_drafts.get(index).cloned() else {
            return;
        };
        self.cancel_validation_for(&draft.id);
        self.provider_drafts.remove(index);
        match self
            .provider_settings
            .apply(ProviderPrefsChange::RemoveProvider {
                provider_id: draft.id,
            }) {
            Ok(()) => {
                self.error = None;
                self.refresh_provider_runtime("Provider 已删除".to_string(), cx);
                return;
            }
            Err(error) => self.error = Some(error.to_string()),
        }
        cx.notify();
    }

    fn render_provider_field(
        label: &'static str,
        description: Option<&'static str>,
        input: Entity<InputState>,
        palette: &theme::Palette,
    ) -> AnyElement {
        let mut column = div().flex().flex_col().gap(px(2.0)).child(
            div()
                .text_size(px(12.0))
                .text_color(palette.ink_2)
                .child(label),
        );
        if let Some(description) = description {
            column = column.child(
                div()
                    .text_size(px(10.0))
                    .text_color(palette.ink_3)
                    .child(description),
            );
        }
        column.child(Input::new(&input)).into_any_element()
    }

    fn breadcrumb_item(text: String) -> SettingItem {
        SettingItem::render(move |_options, _window, cx| {
            let palette = theme::palette_from_theme(cx);
            div()
                .text_size(px(12.0))
                .text_color(palette.ink_2)
                .child(text.clone())
                .into_any_element()
        })
    }

    fn build_settings(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> AnyElement {
        let language = self.language;
        let shortcut = if cfg!(target_os = "macos") {
            "⌘,"
        } else {
            "Ctrl+,"
        };
        let account = self.email.clone().unwrap_or_else(|| self.user_id.clone());
        let user_id = self.user_id.clone();
        let workspace = self.workspace.clone().unwrap_or_else(|| "—".to_string());
        let error = self.error.clone();
        let notice = self.notice.clone();
        let revoking = self.revoking;
        let revoked = self.revoked;
        let drafts = self.provider_drafts.clone();
        let weak = cx.entity().downgrade();
        let root = self.root.clone();

        let account_item = SettingItem::render(move |_options, _window, cx| {
            let palette = theme::palette_from_theme(cx);
            div()
                .flex()
                .flex_col()
                .gap(px(2.0))
                .child(div().text_size(px(13.0)).child(account.clone()))
                .child(
                    div()
                        .text_size(px(11.0))
                        .text_color(palette.ink_3)
                        .child(format!("user_id: {user_id}")),
                )
                .child(
                    div()
                        .text_size(px(11.0))
                        .text_color(palette.ink_3)
                        .child(format!("Workspace: {workspace}")),
                )
                .into_any_element()
        });
        let close_to_tray_flag = self.close_to_tray.clone();
        let close_to_tray = SettingItem::new(
            translate(language, Key::AppSettingsCloseToTray),
            SettingField::switch(
                |_cx: &App| preferences::load().close_to_tray,
                move |value: bool, _cx: &mut App| {
                    close_to_tray_flag.store(value, Ordering::Relaxed);
                    preferences::update(|preferences| preferences.close_to_tray = value);
                },
            ),
        )
        .description(translate(language, Key::AppSettingsCloseToTrayHint));
        let cursor_blink = SettingItem::new(
            translate(language, Key::AppSettingsCursorBlink),
            SettingField::dropdown(
                vec![
                    (
                        SharedString::from(CursorBlinkPreference::Blinking.as_str()),
                        SharedString::from(translate(
                            language,
                            Key::AppSettingsCursorBlinkBlinking,
                        )),
                    ),
                    (
                        SharedString::from(CursorBlinkPreference::Steady.as_str()),
                        SharedString::from(translate(language, Key::AppSettingsCursorBlinkSteady)),
                    ),
                ],
                |_cx: &App| SharedString::from(preferences::load().cursor_blink.as_str()),
                |value: SharedString, cx: &mut App| {
                    let preference = CursorBlinkPreference::from_value(Some(value.as_ref()));
                    preferences::update(|preferences| {
                        if preferences.cursor_blink != preference {
                            preferences.cursor_blink = preference;
                        }
                    });
                    theme::apply_cursor_blink(preference, cx);
                },
            ),
        )
        .description(translate(language, Key::AppSettingsCursorBlinkHint));

        let title_bar_brand = SettingItem::new(
            translate(language, Key::AppSettingsTitleBarBrand),
            SettingField::switch(
                |_cx: &App| preferences::load().title_bar_brand,
                save_display_preference(root.clone(), |prefs, value: bool| {
                    prefs.title_bar_brand = value;
                }),
            ),
        )
        .description(translate(language, Key::AppSettingsTitleBarBrandHint));
        let title_bar_breadcrumb = SettingItem::new(
            translate(language, Key::AppSettingsTitleBarBreadcrumb),
            SettingField::switch(
                |_cx: &App| preferences::load().title_bar_breadcrumb,
                save_display_preference(root.clone(), |prefs, value: bool| {
                    prefs.title_bar_breadcrumb = value;
                }),
            ),
        )
        .description(translate(language, Key::AppSettingsTitleBarBreadcrumbHint));
        let title_bar_notifications = SettingItem::new(
            translate(language, Key::AppSettingsTitleBarNotifications),
            SettingField::switch(
                |_cx: &App| preferences::load().title_bar_notifications,
                save_display_preference(root.clone(), |prefs, value: bool| {
                    prefs.title_bar_notifications = value;
                }),
            ),
        )
        .description(translate(
            language,
            Key::AppSettingsTitleBarNotificationsHint,
        ));
        let status_bar_history_button = SettingItem::new(
            translate(language, Key::AppSettingsStatusBarHistoryButton),
            SettingField::switch(
                |_cx: &App| preferences::load().status_bar_history_button,
                save_display_preference(root.clone(), |prefs, value: bool| {
                    prefs.status_bar_history_button = value;
                }),
            ),
        )
        .description(translate(
            language,
            Key::AppSettingsStatusBarHistoryButtonHint,
        ));
        let agent_panel_button = SettingItem::new(
            translate(language, Key::AppSettingsAgentPanelButton),
            SettingField::switch(
                |_cx: &App| preferences::load().agent_panel_button,
                save_display_preference(root.clone(), |prefs, value: bool| {
                    prefs.agent_panel_button = value;
                }),
            ),
        )
        .description(translate(language, Key::AppSettingsAgentPanelButtonHint));
        let agent_panel_width = SettingItem::new(
            translate(language, Key::AppSettingsAgentPanelWidth),
            SettingField::number_input(
                NumberFieldOptions {
                    min: 240.0,
                    max: 560.0,
                    step: 20.0,
                },
                |_cx: &App| preferences::load().agent_panel_width,
                save_display_width(root.clone(), |prefs, value: f64| {
                    prefs.agent_panel_width = value.clamp(240.0, 560.0);
                }),
            ),
        )
        .description(translate(language, Key::AppSettingsAgentPanelWidthHint));
        let agent_panel_side = SettingItem::new(
            translate(language, Key::AppSettingsDockPosition),
            SettingField::dropdown(
                vec![
                    (
                        SharedString::from("left"),
                        SharedString::from(translate(language, Key::AppSettingsDockLeft)),
                    ),
                    (
                        SharedString::from("right"),
                        SharedString::from(translate(language, Key::AppSettingsDockRight)),
                    ),
                ],
                |_cx: &App| SharedString::from(preferences::load().agent_panel_side.as_str()),
                save_display_preference(root.clone(), |prefs, value: SharedString| {
                    prefs.agent_panel_side =
                        crate::preferences::PanelSide::from_value(Some(value.as_ref()));
                }),
            ),
        );
        let dock_starts_open = SettingItem::new(
            translate(language, Key::AppSettingsDockStartsOpen),
            SettingField::switch(
                |_cx: &App| preferences::load().dock_starts_open,
                save_display_preference(root.clone(), |prefs, value: bool| {
                    prefs.dock_starts_open = value;
                }),
            ),
        )
        .description(translate(language, Key::AppSettingsDockStartsOpenHint));
        let dock_width = SettingItem::new(
            translate(language, Key::AppSettingsDockWidth),
            SettingField::number_input(
                NumberFieldOptions {
                    min: 200.0,
                    max: 480.0,
                    step: 16.0,
                },
                |_cx: &App| preferences::load().dock_width,
                save_display_width(root.clone(), |prefs, value: f64| {
                    prefs.dock_width = value.clamp(200.0, 480.0);
                }),
            ),
        )
        .description(translate(language, Key::AppSettingsDockWidthHint));
        let dock_side = SettingItem::new(
            translate(language, Key::AppSettingsDockPosition),
            SettingField::dropdown(
                vec![
                    (
                        SharedString::from("left"),
                        SharedString::from(translate(language, Key::AppSettingsDockLeft)),
                    ),
                    (
                        SharedString::from("right"),
                        SharedString::from(translate(language, Key::AppSettingsDockRight)),
                    ),
                ],
                |_cx: &App| SharedString::from(preferences::load().dock_side.as_str()),
                save_display_preference(root.clone(), |prefs, value: SharedString| {
                    prefs.dock_side =
                        crate::preferences::PanelSide::from_value(Some(value.as_ref()));
                }),
            ),
        );
        let dock_navigation_button = SettingItem::new(
            translate(language, Key::AppSettingsDockNavigationButton),
            SettingField::switch(
                |_cx: &App| preferences::load().dock_navigation_button,
                save_display_preference(root.clone(), |prefs, value: bool| {
                    prefs.dock_navigation_button = value;
                }),
            ),
        )
        .description(translate(
            language,
            Key::AppSettingsDockNavigationButtonHint,
        ));
        let dock_outline_button = SettingItem::new(
            translate(language, Key::AppSettingsDockOutlineButton),
            SettingField::switch(
                |_cx: &App| preferences::load().dock_outline_button,
                save_display_preference(root.clone(), |prefs, value: bool| {
                    prefs.dock_outline_button = value;
                }),
            ),
        )
        .description(translate(language, Key::AppSettingsDockOutlineButtonHint));
        let dock_show_unenrolled = SettingItem::new(
            translate(language, Key::AppSettingsDockShowUnenrolled),
            SettingField::switch(
                |_cx: &App| preferences::load().dock_show_unenrolled,
                save_display_preference(root.clone(), |prefs, value: bool| {
                    prefs.dock_show_unenrolled = value;
                }),
            ),
        )
        .description(translate(language, Key::AppSettingsDockShowUnenrolledHint));
        // 重置当前工作台布局：只清布局字段，保留已打开标签（与 Zed 的
        // ResetActiveDockSize 同语义，不碰 tabs）。二次确认防止误触。
        let reset_armed = self.reset_workspace_layout_armed.clone();
        let reset_notice = self.reset_workspace_layout_notice.clone();
        let reset_root = self.root.clone();
        let reset_weak = weak.clone();
        let reset_workspace_layout =
            SettingItem::render(move |_options, _window, cx| {
                let palette = theme::palette_from_theme(cx);
                let armed = reset_armed.load(Ordering::Relaxed);
                let notice = reset_notice.lock().ok().and_then(|notice| notice.clone());
                let armed_for_click = reset_armed.clone();
                let notice_for_click = reset_notice.clone();
                let weak_for_click = reset_weak.clone();
                let root_for_click = reset_root.clone();
                let mut column =
                    div()
                        .flex()
                        .flex_col()
                        .gap(px(3.0))
                        .child(div().text_size(px(11.0)).text_color(palette.ink_3).child(
                            translate(language, Key::AppSettingsResetWorkspaceLayoutHint),
                        ))
                        .child(
                            Button::new("settings-reset-workspace-layout")
                                .outline()
                                .small()
                                .when(armed, |button| button.danger())
                                .label(translate(
                                    language,
                                    if armed {
                                        Key::AppSettingsResetWorkspaceLayoutArmed
                                    } else {
                                        Key::AppSettingsResetWorkspaceLayout
                                    },
                                ))
                                .on_click(move |_, _, cx| {
                                    if !armed_for_click.load(Ordering::Relaxed) {
                                        armed_for_click.store(true, Ordering::Relaxed);
                                    } else {
                                        let reset = root_for_click
                                            .update(cx, |view, cx| view.reset_workspace_layout(cx))
                                            .unwrap_or(false);
                                        armed_for_click.store(false, Ordering::Relaxed);
                                        if let Ok(mut notice) = notice_for_click.lock() {
                                            *notice = Some(
                                        translate(
                                            language,
                                            if reset {
                                                Key::AppSettingsResetWorkspaceLayoutDone
                                            } else {
                                                Key::AppSettingsResetWorkspaceLayoutNoWorkspace
                                            },
                                        )
                                        .to_string(),
                                    );
                                        }
                                    }
                                    let _ = weak_for_click.update(cx, |_this, cx| cx.notify());
                                }),
                        );
                if let Some(notice) = notice {
                    column = column.child(
                        div()
                            .text_size(px(10.0))
                            .text_color(palette.ink_3)
                            .child(notice),
                    );
                }
                column.into_any_element()
            });
        let native_agent = SettingItem::new(
            "使用 Native Agent 运行时",
            SettingField::switch(
                |_cx: &App| preferences::load().native_agent_enabled,
                |value: bool, _cx: &mut App| {
                    preferences::update(|preferences| preferences.native_agent_enabled = value);
                },
            ),
        )
        .description(
            "默认开启；关闭后 Agent Panel 使用 External Agent 运行时（Native 工具/MCP 不可用）",
        );
        let course_action_delivery = SettingItem::new(
            "课程动作自动发送",
            SettingField::switch(
                |_cx: &App| {
                    preferences::load().course_action_delivery
                        == crate::agent_call::DeliveryMode::AutoSend
                },
                |value: bool, _cx: &mut App| {
                    preferences::update(|preferences| {
                        preferences.course_action_delivery = if value {
                            crate::agent_call::DeliveryMode::AutoSend
                        } else {
                            crate::agent_call::DeliveryMode::FillOnly
                        };
                    });
                },
            ),
        )
        .description("开启后课程 CTA 直接发送并保留已有草稿；回答类动作始终填充");
        // Stage 3.3：清空 ACP 对话历史（二次确认；只清 conversations.db，
        // native threads.db 完全不碰）。
        let clear_armed = self.clear_acp_history_armed.clone();
        let clear_notice = self.clear_acp_history_notice.clone();
        let clear_history_weak = weak.clone();
        let clear_acp_history = SettingItem::render(move |_options, _window, cx| {
            let palette = theme::palette_from_theme(cx);
            let armed = clear_armed.load(Ordering::Relaxed);
            let notice = clear_notice.lock().ok().and_then(|notice| notice.clone());
            let armed_for_click = clear_armed.clone();
            let notice_for_click = clear_notice.clone();
            let weak_for_click = clear_history_weak.clone();
            let mut column = div()
                .flex()
                .flex_col()
                .gap(px(3.0))
                .child(div().text_size(px(11.0)).text_color(palette.ink_3).child(
                    "永久删除外部 ACP agent 的本地记录（conversations.db，不可恢复）；native 历史不受影响。Archive 仅隐藏条目。",
                ))
                .child(
                    div()
                        .id("settings-clear-acp-history")
                        .role(Role::Button)
                        .aria_label("清空 ACP 对话历史")
                        .px(space(2))
                        .py(px(4.0))
                        .rounded(px(RADIUS_MEDIUM))
                        .border_1()
                        .border_color(if armed { palette.danger } else { palette.line })
                        .text_size(px(12.0))
                        .text_color(if armed { palette.danger } else { palette.ink_2 })
                        .child(if armed {
                            "再次点击确认清空"
                        } else {
                            "清空 ACP 对话历史"
                        })
                        .on_click(move |_, _, cx| {
                            if !armed_for_click.load(Ordering::Relaxed) {
                                armed_for_click.store(true, Ordering::Relaxed);
                            } else {
                                let removed = crate::acp_history::clear_acp_history();
                                armed_for_click.store(false, Ordering::Relaxed);
                                if let Ok(mut notice) = notice_for_click.lock() {
                                    *notice = Some(format!("已清空 ACP 对话历史（{removed} 条）"));
                                }
                                // 主窗口的 chat.history 是缓存：直接通知 RootView 重载，
                                // 并处理"清掉的正是当前 ACP 会话"的回到新会话场景。
                                crate::root_view::notify_history_changed(cx);
                            }
                            let _ = weak_for_click.update(cx, |_this, cx| cx.notify());
                        }),
                );
            if let Some(notice) = notice {
                column = column.child(
                    div()
                        .text_size(px(10.0))
                        .text_color(palette.ink_3)
                        .child(notice),
                );
            }
            column.into_any_element()
        });
        let providers_weak = weak.clone();
        let providers_drafts = drafts.clone();
        let providers_validating = self.key_validation.provider().map(str::to_owned);
        let providers_item = SettingItem::render(move |_options, _window, cx| {
            let palette = theme::palette_from_theme(cx);
            render_provider_list(
                cx,
                &providers_weak,
                &providers_drafts,
                &palette,
                notice.clone(),
                error.clone(),
                providers_validating.as_deref(),
            )
        });
        let providers_header = {
            let header_weak = weak.clone();
            SettingItem::render(move |_options, _window, cx| {
                let palette = theme::palette_from_theme(cx);
                let weak = header_weak.clone();
                let add_weak = header_weak.clone();
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .justify_between()
                    .gap(space(2))
                    .child(
                        div()
                            .id("settings-providers-back")
                            .role(Role::Button)
                            .aria_label("返回 AI 设置")
                            .px(space(1))
                            .py(px(2.0))
                            .rounded(px(RADIUS_SMALL))
                            .text_size(px(12.0))
                            .text_color(palette.ink_2)
                            .hover(|style| style.bg(palette.soft))
                            .child("← 设置 / AI / 通用 / LLM Providers")
                            .on_click(move |_, _, cx| {
                                let _ = weak.update(cx, |this, cx| {
                                    this.ai_view = AiRoute::General;
                                    cx.notify();
                                });
                            }),
                    )
                    .child(
                        div().flex().gap(space(1)).children(
                            [
                                ProviderProtocol::OpenAiCompatible,
                                ProviderProtocol::AnthropicCompatible,
                            ]
                            .into_iter()
                            .map(|protocol| {
                                let add_weak = add_weak.clone();
                                div()
                                    .id(SharedString::from(format!(
                                        "settings-providers-add-{protocol:?}"
                                    )))
                                    .role(Role::Button)
                                    .aria_label(format!("添加 {} Provider", protocol.name()))
                                    .px(space(2))
                                    .py(px(4.0))
                                    .rounded(px(RADIUS_MEDIUM))
                                    .bg(palette.accent)
                                    .text_color(palette.canvas)
                                    .text_size(px(11.0))
                                    .child(format!("＋ {}", protocol.name()))
                                    .on_click(move |_, _, cx| {
                                        let _ = add_weak
                                            .update(cx, |this, cx| this.add_provider(protocol, cx));
                                    })
                            }),
                        ),
                    )
                    .into_any_element()
            })
        };
        let (form_target, form_is_new) = match &self.ai_view {
            AiRoute::NewProvider(id) => (Some(id.clone()), true),
            AiRoute::EditProvider(id) => (Some(id.clone()), false),
            _ => (None, false),
        };
        let form_name = form_target
            .as_ref()
            .and_then(|id| drafts.iter().find(|draft| &draft.id == id))
            .map(|draft| draft.name.clone())
            .unwrap_or_default();
        let form_back = {
            let back_weak = weak.clone();
            let form_name = form_name.clone();
            SettingItem::render(move |_options, _window, cx| {
                let palette = theme::palette_from_theme(cx);
                let weak = back_weak.clone();
                div()
                    .child(
                        div()
                            .flex()
                            .flex_row()
                            .items_center()
                            .justify_between()
                            .gap(space(2))
                            .child(
                                div()
                                    .id("settings-provider-form-back")
                                    .role(Role::Button)
                                    .aria_label("返回 LLM Providers")
                                    .px(space(1))
                                    .py(px(2.0))
                                    .rounded(px(RADIUS_SMALL))
                                    .text_size(px(12.0))
                                    .text_color(palette.ink_2)
                                    .hover(|style| style.bg(palette.soft))
                                    .child(format!(
                                        "← 设置 / AI / 通用 / LLM Providers / {}",
                                        if form_is_new || form_name.is_empty() {
                                            "添加 Provider"
                                        } else {
                                            form_name.as_str()
                                        }
                                    ))
                                    .on_click(move |_, _, cx| {
                                        let _ = weak.update(cx, |this, cx| {
                                            this.leave_provider_form(cx);
                                        });
                                    }),
                            )
                            .into_any_element(),
                    )
                    .into_any_element()
            })
        };
        let form_item = form_target.as_ref().map(|target_id| {
            let form_drafts: Vec<(usize, ProviderDraft)> = drafts
                .iter()
                .enumerate()
                .filter(|(_, draft)| &draft.id == target_id)
                .map(|(index, draft)| (index, draft.clone()))
                .collect();
            let form_weak = weak.clone();
            SettingItem::render(move |_options, _window, cx| {
                let palette = theme::palette_from_theme(cx);
                render_provider_cards(
                    cx,
                    &form_weak,
                    &form_drafts,
                    &palette,
                    None,
                    None,
                    if form_is_new {
                        "添加 Provider"
                    } else {
                        "保存"
                    },
                )
            })
        });
        let about_item = SettingItem::render(move |_options, _window, cx| {
            let palette = theme::palette_from_theme(cx);
            div()
                .flex()
                .flex_col()
                .gap(px(2.0))
                .child(div().text_size(px(13.0)).child(build_info::about_line()))
                .child(
                    div()
                        .text_size(px(11.0))
                        .text_color(palette.ink_3)
                        .child(format!(
                            "{} {}",
                            translate(language, Key::AppSettingsShortcutHint),
                            shortcut
                        )),
                )
                .into_any_element()
        });
        let revoke_weak = weak.clone();
        let revoke_item = SettingItem::render(move |_options, _window, cx| {
            let palette = theme::palette_from_theme(cx);
            let weak = revoke_weak.clone();
            let label = if revoking {
                translate(language, Key::AppSettingsRevoking)
            } else if revoked {
                translate(language, Key::AppSettingsRevoked)
            } else {
                translate(language, Key::AppSettingsRevokeDevice)
            };
            div()
                .flex()
                .flex_row()
                .items_center()
                .justify_between()
                .gap(space(2))
                .child(
                    div()
                        .flex()
                        .flex_col()
                        .gap(px(2.0))
                        .child(
                            div()
                                .text_size(px(13.0))
                                .child(translate(language, Key::AppSettingsRevokeDevice)),
                        )
                        .child(
                            div()
                                .text_size(px(11.0))
                                .text_color(palette.ink_3)
                                .child(translate(language, Key::AppSettingsRevokeHint)),
                        ),
                )
                .child(
                    div()
                        .id("settings-window-revoke")
                        .role(Role::Button)
                        .aria_label(label)
                        .px(space(2))
                        .py(px(6.0))
                        .rounded(px(RADIUS_MEDIUM))
                        .bg(if revoking || revoked {
                            palette.soft
                        } else {
                            palette.danger
                        })
                        .text_color(if revoking || revoked {
                            palette.ink_3
                        } else {
                            palette.canvas
                        })
                        .child(label)
                        .on_click(move |_, _, cx| {
                            let _ = weak.update(cx, |this, cx| this.revoke(cx));
                        }),
                )
                .into_any_element()
        });

        let llm_link_weak = weak.clone();
        let llm_link = SettingItem::render(move |_options, _window, cx| {
            let palette = theme::palette_from_theme(cx);
            let weak = llm_link_weak.clone();
            div()
                .flex()
                .flex_row()
                .items_center()
                .justify_between()
                .gap(space(2))
                .child(
                    div()
                        .flex()
                        .flex_col()
                        .gap(px(2.0))
                        .child(div().text_size(px(13.0)).child("LLM Providers"))
                        .child(
                            div()
                                .text_size(px(11.0))
                                .text_color(palette.ink_3)
                                .child("配置内置与自定义模型 provider"),
                        ),
                )
                .child(
                    div()
                        .id("settings-ai-llm-providers")
                        .role(Role::Button)
                        .aria_label("配置 LLM Providers")
                        .px(space(2))
                        .py(px(5.0))
                        .rounded(px(RADIUS_MEDIUM))
                        .border_1()
                        .border_color(palette.line)
                        .text_size(px(12.0))
                        .child("Configure >")
                        .on_click(move |_, _, cx| {
                            let _ = weak.update(cx, |this, cx| {
                                this.ai_view = AiRoute::Providers;
                                cx.notify();
                            });
                        }),
                )
                .into_any_element()
        });
        let hidden_header = gpui_kit::StyleRefinement {
            display: Some(gpui_kit::Display::None),
            ..Default::default()
        };
        let ai_page = match &self.ai_view {
            AiRoute::General => SettingPage::new("AI")
                .header_style(&hidden_header)
                .groups(vec![
                    SettingGroup::new()
                        .variant(GroupBoxVariant::Normal)
                        .item(Self::breadcrumb_item("设置 / AI".to_string())),
                    SettingGroup::new().title("通用").items(vec![
                        llm_link,
                        native_agent,
                        course_action_delivery,
                        clear_acp_history,
                    ]),
                ]),
            AiRoute::Providers => SettingPage::new("AI")
                .header_style(&hidden_header)
                .groups(vec![
                    SettingGroup::new()
                        .variant(GroupBoxVariant::Normal)
                        .item(providers_header),
                    SettingGroup::new()
                        .title("LLM Providers")
                        .item(providers_item),
                ]),
            AiRoute::NewProvider(_) | AiRoute::EditProvider(_) => SettingPage::new("AI")
                .header_style(&hidden_header)
                .groups(vec![
                    SettingGroup::new()
                        .variant(GroupBoxVariant::Normal)
                        .item(form_back),
                    SettingGroup::new()
                        .title("Provider")
                        .items(form_item.into_iter().collect::<Vec<SettingItem>>()),
                ]),
        };

        let settings = Settings::new(SharedString::from(format!(
            "cgc-settings-{}",
            self.settings_nonce
        )))
        .default_selected_index(SelectIndex {
            page_ix: self.settings_page,
            group_ix: None,
        })
        .page(
            SettingPage::new(translate(language, Key::AppSettingsAccount))
                .header_style(&hidden_header)
                .groups(vec![
                    SettingGroup::new()
                        .variant(GroupBoxVariant::Normal)
                        .item(Self::breadcrumb_item("设置 / 账号".to_string())),
                    SettingGroup::new()
                        .title(translate(language, Key::AppSettingsAccount))
                        .item(account_item),
                ]),
        )
        .page(
            SettingPage::new("通用")
                .header_style(&hidden_header)
                .groups(vec![
                    SettingGroup::new()
                        .variant(GroupBoxVariant::Normal)
                        .item(Self::breadcrumb_item("设置 / 通用".to_string())),
                    SettingGroup::new().title("通用").items(vec![cursor_blink]),
                ]),
        )
        .page(
            SettingPage::new(translate(language, Key::AppSettingsWindowLayout))
                .header_style(&hidden_header)
                .groups(vec![
                    SettingGroup::new()
                        .variant(GroupBoxVariant::Normal)
                        .item(Self::breadcrumb_item("设置 / 窗口与布局".to_string())),
                    SettingGroup::new()
                        .title(translate(language, Key::AppSettingsTitleBar))
                        .items(vec![
                            title_bar_brand,
                            title_bar_breadcrumb,
                            title_bar_notifications,
                        ]),
                    SettingGroup::new()
                        .title(translate(language, Key::AppSettingsStatusBar))
                        .items(vec![
                            status_bar_history_button,
                            agent_panel_button,
                            dock_navigation_button,
                            dock_outline_button,
                        ]),
                    SettingGroup::new()
                        .title(translate(language, Key::AppSettingsBehavior))
                        .item(close_to_tray),
                ]),
        )
        .page(
            SettingPage::new(translate(language, Key::AppSettingsPanels))
                .header_style(&hidden_header)
                .groups(vec![
                    SettingGroup::new()
                        .variant(GroupBoxVariant::Normal)
                        .item(Self::breadcrumb_item("设置 / 面板".to_string())),
                    SettingGroup::new()
                        .title(translate(language, Key::AppSettingsAgentPanel))
                        .items(vec![agent_panel_side, agent_panel_width]),
                    SettingGroup::new()
                        .title(translate(language, Key::AppSettingsDock))
                        .items(vec![
                            dock_side,
                            dock_starts_open,
                            dock_width,
                            dock_show_unenrolled,
                        ]),
                    SettingGroup::new()
                        .title(translate(language, Key::AppSettingsWorkspace))
                        .item(reset_workspace_layout),
                ]),
        )
        .page(ai_page)
        .page(
            SettingPage::new("关于")
                .header_style(&hidden_header)
                .groups(vec![
                    SettingGroup::new()
                        .variant(GroupBoxVariant::Normal)
                        .item(Self::breadcrumb_item("设置 / 关于".to_string())),
                    SettingGroup::new()
                        .title("关于")
                        .items(vec![about_item, revoke_item]),
                ]),
        );
        div().size_full().child(settings).into_any_element()
    }
}

/// 保存显示偏好后刷新主窗口快照；不改当前窗口宽度。
fn save_display_preference<T, U>(
    root: WeakEntity<crate::root_view::RootView>,
    update: U,
) -> impl Fn(T, &mut App) + 'static
where
    T: Clone + 'static,
    U: Fn(&mut preferences::Preferences, T) + 'static,
{
    move |value: T, cx: &mut App| {
        preferences::update(|prefs| update(prefs, value.clone()));
        let _ = root.update(cx, |view, cx| view.apply_display_snapshot(cx));
    }
}

/// 保存默认宽度后刷新快照并应用宽度。
fn save_display_width(
    root: WeakEntity<crate::root_view::RootView>,
    update: impl Fn(&mut preferences::Preferences, f64) + 'static,
) -> impl Fn(f64, &mut App) + 'static {
    move |value: f64, cx: &mut App| {
        preferences::update(|prefs| update(prefs, value));
        let _ = root.update(cx, |view, cx| view.apply_default_panel_widths(cx));
    }
}

fn refresh_outcome(
    success: &str,
    result: Result<(), NativeRuntimeError>,
) -> (Option<String>, Option<String>) {
    match result {
        Ok(()) => (Some(success.to_string()), None),
        Err(NativeRuntimeError::Busy) => (
            None,
            Some("配置已保存，但当前会话正在运行；请结束当前对话后重试或重启客户端".to_string()),
        ),
        Err(error) => (None, Some(format!("配置已保存，但应用失败：{error}"))),
    }
}

fn provider_validation_message(error: &ProviderError) -> &'static str {
    match error.category() {
        ProviderErrorCategory::Authentication => "API Key 无效或已过期",
        ProviderErrorCategory::Permission => "API Key 没有访问权限",
        ProviderErrorCategory::PaymentRequired => "账户余额不足",
        ProviderErrorCategory::RateLimit => "请求过于频繁，请稍后重试",
        ProviderErrorCategory::Overloaded => "Provider 服务暂时不可用，请稍后重试",
        ProviderErrorCategory::Transport => "网络连接失败，请检查网络后重试",
        ProviderErrorCategory::InvalidRequest => "Provider 不接受该 API Key 或模型配置",
        ProviderErrorCategory::ContextTooLong => "验证请求超出模型上下文",
        ProviderErrorCategory::Cancelled => "验证已取消",
        ProviderErrorCategory::Other => "无法验证 API Key，请稍后重试",
    }
}

fn render_provider_list(
    _cx: &mut App,
    weak: &WeakEntity<SettingsWindowView>,
    drafts: &[ProviderDraft],
    palette: &theme::Palette,
    notice: Option<String>,
    error: Option<String>,
    validating_provider: Option<&str>,
) -> AnyElement {
    let mut rows: Vec<AnyElement> = Vec::new();
    for (index, draft) in drafts.iter().enumerate() {
        let total = parse_model_lines(&draft.models).0.len();
        let enabled = draft
            .model_params
            .iter()
            .filter(|model| model.enabled)
            .count();
        let validating = validating_provider == Some(draft.id.as_str());
        let status = if validating {
            "正在验证 API Key…"
        } else if draft.has_key {
            "✓ API Key 已配置"
        } else {
            "未配置 API Key"
        };
        let weak_row = weak.clone();
        let reset_weak = weak.clone();
        let target = draft.id.clone();
        rows.push(
            div()
                .flex()
                .flex_row()
                .flex_wrap()
                .items_center()
                .gap(space(2))
                .p(space(1))
                .child(
                    div()
                        .flex_1()
                        .flex()
                        .flex_col()
                        .gap(px(1.0))
                        .child(div().text_size(px(13.0)).child(draft.name.clone()))
                        .child(
                            div()
                                .text_size(px(10.0))
                                .text_color(palette.ink_3)
                                .child(format!("{status} · 已启用 {enabled}/{total} 模型")),
                        ),
                )
                .children((!draft.has_key).then(|| {
                    let input = draft.api_key_input.clone().expect("key input created");
                    let save_weak = weak.clone();
                    div()
                        .flex()
                        .flex_row()
                        .items_center()
                        .gap(space(1))
                        .child(div().w(px(220.0)).child(Input::new(&input)))
                        .child(
                            div()
                                .id(SharedString::from(format!(
                                    "settings-provider-save-key-{index}"
                                )))
                                .role(Role::Button)
                                .aria_label("保存 API Key")
                                .px(space(2))
                                .py(px(3.0))
                                .rounded(px(RADIUS_SMALL))
                                .bg(if validating {
                                    palette.soft
                                } else {
                                    palette.accent
                                })
                                .text_color(if validating {
                                    palette.ink_3
                                } else {
                                    palette.canvas
                                })
                                .text_size(px(10.0))
                                .child(if validating {
                                    "验证中…"
                                } else {
                                    "保存 Key"
                                })
                                .on_click(move |_, window, cx| {
                                    if validating {
                                        return;
                                    }
                                    let _ = save_weak.update(cx, |this, cx| {
                                        this.save_provider_key(index, window, cx);
                                    });
                                }),
                        )
                }))
                .children(draft.has_key.then(|| {
                    div()
                        .id(SharedString::from(format!(
                            "settings-provider-reset-key-{index}"
                        )))
                        .role(Role::Button)
                        .aria_label("重置 API Key")
                        .px(space(2))
                        .py(px(3.0))
                        .rounded(px(RADIUS_SMALL))
                        .text_size(px(10.0))
                        .text_color(palette.ink_3)
                        .hover(|style| style.bg(palette.soft))
                        .child("清除 Key")
                        .on_click(move |_, _, cx| {
                            let _ = reset_weak.update(cx, |this, cx| {
                                this.reset_provider_key(index, cx);
                            });
                        })
                }))
                .child(
                    div()
                        .id(SharedString::from(format!(
                            "settings-provider-open-{index}"
                        )))
                        .role(Role::Button)
                        .aria_label("编辑配置")
                        .px(space(2))
                        .py(px(4.0))
                        .rounded(px(RADIUS_MEDIUM))
                        .border_1()
                        .border_color(palette.line)
                        .text_size(px(11.0))
                        .child("编辑配置 >")
                        .on_click(move |_, _, cx| {
                            let _ = weak_row.update(cx, |this, cx| {
                                this.ai_view = AiRoute::EditProvider(target.clone());
                                cx.notify();
                            });
                        }),
                )
                .into_any_element(),
        );
    }
    div()
        .flex()
        .flex_col()
        .gap(space(1))
        .child(
            div()
                .id("settings-cgc-placeholder")
                .flex()
                .flex_row()
                .items_center()
                .gap(space(2))
                .p(space(1))
                .rounded(px(RADIUS_MEDIUM))
                .border_1()
                .border_color(palette.line)
                .child(
                    div()
                        .flex_1()
                        .flex()
                        .flex_col()
                        .gap(px(1.0))
                        .child(div().text_size(px(13.0)).child("CGC - 程序媛汇"))
                        .child(
                            div()
                                .text_size(px(10.0))
                                .text_color(palette.ink_3)
                                .child("程序媛汇账号托管模型（网关接入中，占位）"),
                        ),
                )
                .child(
                    div()
                        .id("settings-cgc-start")
                        .role(Role::Button)
                        .aria_label("开始使用 CGC")
                        .px(space(2))
                        .py(px(4.0))
                        .rounded(px(RADIUS_MEDIUM))
                        .bg(palette.accent)
                        .text_color(palette.canvas)
                        .text_size(px(11.0))
                        .child("开始使用")
                        .on_click(move |_, _, cx| {
                            cx.open_url("https://codingirlsclub.com/");
                        }),
                ),
        )
        .children(rows)
        .children(notice.map(|notice| {
            div()
                .text_size(px(11.0))
                .text_color(palette.ink_3)
                .child(notice)
        }))
        .children(error.map(|error| {
            div()
                .text_size(px(11.0))
                .text_color(palette.danger)
                .child(error)
        }))
        .into_any_element()
}

fn render_provider_cards(
    _cx: &mut App,
    weak: &WeakEntity<SettingsWindowView>,
    drafts: &[(usize, ProviderDraft)],
    palette: &theme::Palette,
    notice: Option<String>,
    error: Option<String>,
    save_label: &'static str,
) -> AnyElement {
    let mut cards: Vec<AnyElement> = Vec::new();
    for (index, draft) in drafts.iter().map(|(index, draft)| (*index, draft)) {
        let (Some(base_input), Some(models_input), Some(key_input)) = (
            draft.base_url_input.clone(),
            draft.models_input.clone(),
            draft.api_key_input.clone(),
        ) else {
            continue;
        };
        let status_color = if draft.has_key {
            palette.ink_2
        } else {
            palette.ink_3
        };
        let status = if draft.has_key {
            "API Key 已保存"
        } else {
            "未保存 API Key"
        };
        let remove_weak = weak.clone();
        let save_weak = weak.clone();
        let enable_weak = weak.clone();
        let clone_weak = weak.clone();
        let restore_weak = weak.clone();
        cards.push(
            div()
                .flex()
                .flex_col()
                .gap(space(1))
                .p(space(1))
                .child(
                    div()
                        .flex()
                        .flex_row()
                        .items_center()
                        .gap(space(2))
                        .child(div().flex_1().text_size(px(13.0)).child(draft.name.clone()))
                        .child(
                            div()
                                .text_size(px(10.0))
                                .text_color(status_color)
                                .child(status),
                        )
                        .child(
                            Switch::new(SharedString::from(format!(
                                "settings-provider-enabled-{index}"
                            )))
                            .checked(draft.enabled)
                            .accessibility_label("启用 provider")
                            .tooltip(if draft.enabled {
                                "已启用：模型出现在模型选择器"
                            } else {
                                "已停用：保留 Key 与配置，模型不出现在选择器"
                            })
                            .on_change(move |checked, _, cx| {
                                let _ = enable_weak.update(cx, |this, cx| {
                                    this.set_provider_enabled(index, *checked, cx);
                                });
                            }),
                        )
                        .children(draft.builtin.then(|| {
                            div()
                                .id(SharedString::from(format!(
                                    "settings-provider-restore-{index}"
                                )))
                                .role(Role::Button)
                                .aria_label("恢复内置默认")
                                .px(space(2))
                                .py(px(3.0))
                                .rounded(px(RADIUS_SMALL))
                                .text_size(px(11.0))
                                .text_color(palette.ink_3)
                                .hover(|style| style.bg(palette.soft))
                                .child("恢复内置默认")
                                .on_click(move |_, window, cx| {
                                    let _ = restore_weak.update(cx, |this, cx| {
                                        this.restore_provider_default(index, window, cx);
                                    });
                                })
                        }))
                        .child(
                            div()
                                .id(SharedString::from(format!(
                                    "settings-provider-remove-{index}"
                                )))
                                .role(Role::Button)
                                .aria_label("删除 provider")
                                .px(space(1))
                                .py(px(2.0))
                                .rounded(px(RADIUS_SMALL))
                                .text_size(px(11.0))
                                .text_color(palette.ink_3)
                                .hover(|style| style.bg(palette.soft))
                                .child("删除")
                                .on_click(move |_, _, cx| {
                                    let _ = remove_weak
                                        .update(cx, |this, cx| this.remove_provider(index, cx));
                                }),
                        ),
                )
                .children(draft.name_input.clone().map(|input| {
                    SettingsWindowView::render_provider_field(
                        "Provider Name *",
                        Some("用于识别此 Provider 的唯一名称。"),
                        input,
                        palette,
                    )
                }))
                .child(div().text_size(px(11.0)).text_color(palette.ink_3).child(draft.protocol.name()))
                .child(SettingsWindowView::render_provider_field(
                    "API URL *",
                    Some(if draft.protocol == ProviderProtocol::AnthropicCompatible { "Anthropic API 根地址，可包含网关路径前缀或 /v1。" } else { "兼容 API 的基础 URL。" }),
                    base_input,
                    palette,
                ))
                .child(
                    div()
                        .flex()
                        .flex_row()
                        .items_center()
                        .gap(space(1))
                        .child(div().text_size(px(11.0)).text_color(palette.ink_3).child("协议"))
                        .children(
                            [
                                (ProviderProtocol::OpenAiCompatible, "OpenAI 兼容"),
                                (ProviderProtocol::AnthropicCompatible, "Anthropic 兼容"),
                            ]
                            .into_iter()
                            .map(|(protocol, label)| {
                                let selected = draft.protocol == protocol;
                                let protocol_weak = weak.clone();
                                div()
                                    .id(SharedString::from(format!(
                                        "settings-provider-protocol-{index}-{label}"
                                    )))
                                    .role(Role::Button)
                                    .aria_label(label)
                                    .px(space(2))
                                    .py(px(3.0))
                                    .rounded(px(RADIUS_SMALL))
                                    .border_1()
                                    .border_color(if selected {
                                        palette.accent
                                    } else {
                                        palette.line
                                    })
                                    .text_size(px(11.0))
                                    .text_color(if selected {
                                        palette.accent
                                    } else {
                                        palette.ink_2
                                    })
                                    .child(label)
                                    .on_click(move |_, _, cx| {
                                        let _ = protocol_weak.update(cx, |this, cx| {
                                            this.set_provider_protocol(index, protocol, cx);
                                        });
                                    })
                            }),
                        )
                        .child(div().flex_1())
                        .child(
                            div()
                                .id(SharedString::from(format!(
                                    "settings-provider-endpoints-{index}"
                                )))
                                .role(Role::Button)
                                .aria_label("更多端点")
                                .px(space(2))
                                .py(px(3.0))
                                .rounded(px(RADIUS_SMALL))
                                .border_1()
                                .border_color(palette.line)
                                .text_size(px(11.0))
                                .text_color(if draft.endpoints_open {
                                    palette.accent
                                } else {
                                    palette.ink_2
                                })
                                .child(if draft.endpoints_open {
                                    "更多端点 ▴"
                                } else {
                                    "更多端点 ▾"
                                })
                                .on_click({
                                    let endpoints_weak = weak.clone();
                                    move |_, _, cx| {
                                        let _ = endpoints_weak.update(cx, |this, cx| {
                                            this.toggle_endpoints(index, cx);
                                        });
                                    }
                                }),
                        ),
                )
                .children(draft.endpoints_open.then(|| {
                    div()
                        .flex()
                        .flex_col()
                        .gap(space(1))
                        .children(draft.anthropic_url_input.clone().map(|input| {
                            SettingsWindowView::render_provider_field(
                                "Anthropic 地址（可选）",
                                Some("选 Anthropic 协议时优先使用；留空则用 API URL。"),
                                input,
                                palette,
                            )
                        }))
                        .children(draft.responses_url_input.clone().map(|input| {
                            SettingsWindowView::render_provider_field(
                                "Responses 地址（可选）",
                                Some("预留字段，当前 native 运行时暂不使用。"),
                                input,
                                palette,
                            )
                        }))
                        .children(draft.models_url_input.clone().map(|input| {
                            SettingsWindowView::render_provider_field(
                                "模型列表地址（可选）",
                                Some("完整 URL；留空则用 API URL/models。"),
                                input,
                                palette,
                            )
                        }))
                        .into_any_element()
                }))
                .children({
                    let edit_weak = weak.clone();
                    let reset_weak = weak.clone();
                    let save_weak = weak.clone();
                    let cancel_weak = weak.clone();
                    let confirm_weak = weak.clone();
                    let cancel_clear_weak = weak.clone();
                    if draft.has_key && !draft.key_editing {
                        Some(
                            div()
                                .flex()
                                .flex_row()
                                .items_center()
                                .gap(space(2))
                                .child(
                                    div()
                                        .text_size(px(11.0))
                                        .text_color(palette.ink_2)
                                        .child("✓ API Key 已配置"),
                                )
                                .child(
                                    div()
                                        .id(SharedString::from(format!(
                                            "settings-provider-change-key-{index}"
                                        )))
                                        .role(Role::Button)
                                        .px(space(2))
                                        .py(px(3.0))
                                        .rounded(px(RADIUS_SMALL))
                                        .text_size(px(11.0))
                                        .text_color(palette.accent)
                                        .hover(|style| style.bg(palette.soft))
                                        .child("替换 Key")
                                        .on_click(move |_, _, cx| {
                                            let _ = edit_weak.update(cx, |this, cx| {
                                                if let Some(draft) =
                                                    this.provider_drafts.get_mut(index)
                                                {
                                                    draft.key_editing = true;
                                                }
                                                cx.notify();
                                            });
                                        }),
                                )
                                .child(
                                    div()
                                        .id(SharedString::from(format!(
                                            "settings-provider-reset-key-{index}"
                                        )))
                                        .role(Role::Button)
                                        .px(space(2))
                                        .py(px(3.0))
                                        .rounded(px(RADIUS_SMALL))
                                        .text_size(px(11.0))
                                        .text_color(palette.ink_3)
                                        .hover(|style| style.bg(palette.soft))
                                        .child("清除 Key")
                                        .on_click(move |_, _, cx| {
                                            let _ = reset_weak.update(cx, |this, cx| {
                                                if let Some(draft) =
                                                    this.provider_drafts.get_mut(index)
                                                {
                                                    draft.confirm_clear = true;
                                                }
                                                cx.notify();
                                            });
                                        }),
                                )
                                .children(draft.confirm_clear.then(|| {
                                    div()
                                        .flex()
                                        .flex_row()
                                        .items_center()
                                        .gap(space(2))
                                        .child(
                                            div()
                                                .text_size(px(11.0))
                                                .text_color(palette.danger)
                                                .child("确认清除 API Key？"),
                                        )
                                        .child(
                                            div()
                                                .id(SharedString::from(format!(
                                                    "settings-provider-confirm-clear-{index}"
                                                )))
                                                .role(Role::Button)
                                                .px(space(2))
                                                .py(px(3.0))
                                                .rounded(px(RADIUS_SMALL))
                                                .bg(palette.danger)
                                                .text_color(palette.canvas)
                                                .text_size(px(11.0))
                                                .child("确认清除")
                                                .on_click(move |_, _, cx| {
                                                    let _ = confirm_weak.update(cx, |this, cx| {
                                                        this.reset_provider_key(index, cx);
                                                    });
                                                }),
                                        )
                                        .child(
                                            div()
                                                .id(SharedString::from(format!(
                                                    "settings-provider-cancel-clear-{index}"
                                                )))
                                                .role(Role::Button)
                                                .px(space(2))
                                                .py(px(3.0))
                                                .rounded(px(RADIUS_SMALL))
                                                .text_size(px(11.0))
                                                .text_color(palette.ink_3)
                                                .hover(|style| style.bg(palette.soft))
                                                .child("取消")
                                                .on_click(move |_, _, cx| {
                                                    let _ = cancel_clear_weak.update(
                                                        cx,
                                                        |this, cx| {
                                                            if let Some(draft) = this
                                                                .provider_drafts
                                                                .get_mut(index)
                                                            {
                                                                draft.confirm_clear = false;
                                                            }
                                                            cx.notify();
                                                        },
                                                    );
                                                }),
                                        )
                                }))
                                .into_any_element(),
                        )
                    } else {
                        Some(
                            div()
                                .flex()
                                .flex_col()
                                .gap(px(2.0))
                                .child(
                                    div()
                                        .text_size(px(11.0))
                                        .text_color(palette.ink_3)
                                        .child(if draft.has_key {
                                            "输入新 Key 将替换现有 Key"
                                        } else {
                                            "API Key（保存到系统钥匙串）"
                                        }),
                                )
                                .child(div().w(px(360.0)).child(Input::new(&key_input)))
                                .child(
                                    div()
                                        .flex()
                                        .flex_row()
                                        .items_center()
                                        .gap(space(2))
                                        .child(
                                            div()
                                                .id(SharedString::from(format!(
                                                    "settings-provider-save-key-{index}"
                                                )))
                                                .role(Role::Button)
                                                .px(space(2))
                                                .py(px(3.0))
                                                .rounded(px(RADIUS_SMALL))
                                                .bg(palette.accent)
                                                .text_color(palette.canvas)
                                                .text_size(px(11.0))
                                                .child("保存 Key")
                                                .on_click(move |_, window, cx| {
                                                    let _ = save_weak.update(cx, |this, cx| {
                                                        this.save_provider_key(index, window, cx);
                                                    });
                                                }),
                                        )
                                        .children(draft.has_key.then(|| {
                                            div()
                                                .id(SharedString::from(format!(
                                                    "settings-provider-cancel-key-{index}"
                                                )))
                                                .role(Role::Button)
                                                .px(space(2))
                                                .py(px(3.0))
                                                .rounded(px(RADIUS_SMALL))
                                                .text_size(px(11.0))
                                                .text_color(palette.ink_3)
                                                .hover(|style| style.bg(palette.soft))
                                                .child("取消")
                                                .on_click(move |_, _, cx| {
                                                    let _ = cancel_weak.update(cx, |this, cx| {
                                                        if let Some(draft) =
                                                            this.provider_drafts.get_mut(index)
                                                        {
                                                            draft.key_editing = false;
                                                        }
                                                        cx.notify();
                                                    });
                                                })
                                        })),
                                )
                                .into_any_element(),
                        )
                    }
                })
                .child(
                    div()
                        .flex()
                        .flex_col()
                        .gap(px(2.0))
                        .child(
                            div()
                                .flex()
                                .flex_row()
                                .items_center()
                                .justify_between()
                                .gap(space(2))
                                .child(
                                    div()
                                        .text_size(px(11.0))
                                        .text_color(palette.ink_3)
                                        .child("Models"),
                                )
                                .child(
                                    div()
                                        .flex()
                                        .flex_row()
                                        .items_center()
                                        .gap(space(1))
                                        .child(
                                            div()
                                                .id(SharedString::from(format!(
                                                    "settings-model-fetch-{index}"
                                                )))
                                                .role(Role::Button)
                                                .aria_label("获取模型")
                                                .px(space(2))
                                                .py(px(3.0))
                                                .rounded(px(RADIUS_SMALL))
                                                .border_1()
                                                .border_color(palette.line)
                                                .text_size(px(11.0))
                                                .child(if draft.fetching_models {
                                                    "获取中…"
                                                } else {
                                                    "⟳ 获取模型"
                                                })
                                                .on_click({
                                                    let fetch_weak = weak.clone();
                                                    move |_, _, cx| {
                                                        let _ = fetch_weak.update(cx, |this, cx| {
                                                            this.fetch_models(index, cx);
                                                        });
                                                    }
                                                }),
                                        )
                                        .child(
                                            div()
                                                .id(SharedString::from(format!(
                                                    "settings-models-test-{index}"
                                                )))
                                                .role(Role::Button)
                                                .aria_label("检测模型")
                                                .px(space(2))
                                                .py(px(3.0))
                                                .rounded(px(RADIUS_SMALL))
                                                .border_1()
                                                .border_color(palette.line)
                                                .text_size(px(11.0))
                                                .child(if draft.testing_models {
                                                    "检测中…"
                                                } else {
                                                    "检测模型"
                                                })
                                                .on_click({
                                                    let test_weak = weak.clone();
                                                    move |_, _, cx| {
                                                        let _ = test_weak.update(cx, |this, cx| {
                                                            this.test_all_models(index, cx);
                                                        });
                                                    }
                                                }),
                                        )
                                        .child(
                                            div()
                                                .id(SharedString::from(format!(
                                                    "settings-models-advanced-{index}"
                                                )))
                                                .role(Role::Button)
                                                .aria_label("批量编辑模型配置")
                                                .px(space(2))
                                                .py(px(3.0))
                                                .rounded(px(RADIUS_SMALL))
                                                .border_1()
                                                .border_color(palette.line)
                                                .bg(palette.canvas)
                                                .text_size(px(11.0))
                                                .text_color(if draft.models_advanced_open {
                                                    palette.accent
                                                } else {
                                                    palette.ink_2
                                                })
                                                .child(if draft.models_advanced_open {
                                                    "批量编辑 ▴"
                                                } else {
                                                    "批量编辑 ▾"
                                                })
                                                .on_click({
                                                    let advanced_weak = weak.clone();
                                                    move |_, _, cx| {
                                                        let _ = advanced_weak.update(cx, |this, cx| {
                                                            this.toggle_models_advanced(index, cx);
                                                        });
                                                    }
                                                }),
                                        )
                                        .child(
                                            div()
                                                .id(SharedString::from(format!(
                                                    "settings-model-add-{index}"
                                                )))
                                                .role(Role::Button)
                                                .px(space(2))
                                                .py(px(3.0))
                                                .rounded(px(RADIUS_SMALL))
                                                .border_1()
                                                .border_color(palette.line)
                                                .text_size(px(11.0))
                                                .child("＋ Add Model")
                                                .on_click({
                                                    let add_weak = weak.clone();
                                                    move |_, window, cx| {
                                                        let _ = add_weak.update(cx, |this, cx| {
                                                            this.add_model(index, window, cx);
                                                        });
                                                    }
                                                }),
                                        ),
                                ),
                        )
                        .children(draft.models_advanced_open.then(|| {
                            div()
                                .w_full()
                                .flex()
                                .flex_col()
                                .gap(space(1))
                                .pt(space(1))
                                .child(
                                    div()
                                        .text_size(px(10.0))
                                        .text_color(palette.ink_3)
                                        .child("批量编辑：每行一个模型，列之间用 | 分隔"),
                                )
                                .child(
                                    div()
                                        .text_size(px(10.0))
                                        .text_color(palette.ink_3)
                                        .child("格式：模型名 | context | max output | thinking | enabled | tools | images"),
                                )
                                .child(
                                    div()
                                        .text_size(px(10.0))
                                        .text_color(palette.ink_3)
                                        .child("示例：deepseek-flash | 1048576 | 393216 | true | true | true | true"),
                                )
                                .child(
                                    div().w_full().min_w(px(0.0)).child(
                                        Textarea::new(&models_input).w_full().h(px(120.)),
                                    ),
                                )
                                .into_any_element()
                        }))
                        .children(draft.remote_picker.clone().map(|picker| {
                            let apply_weak = weak.clone();
                            let dismiss_weak = weak.clone();
                            div()
                                .flex()
                                .flex_col()
                                .gap(space(1))
                                .p(space(1))
                                .rounded(px(RADIUS_MEDIUM))
                                .border_1()
                                .border_color(palette.line)
                                .child(
                                    div()
                                        .text_size(px(10.0))
                                        .text_color(palette.ink_3)
                                        .child(format!(
                                            "已获取 {} 个模型，默认全选；取消不需要的再点加入",
                                            draft.remote_models.len()
                                        )),
                                )
                                .child(div().w(px(420.0)).child(
                                    Combobox::new(&picker)
                                        .placeholder("选择模型")
                                        .search_placeholder("搜索模型…")
                                        .menu_width(px(360.0))
                                        .cleanable(true),
                                ))
                                .child(
                                    div()
                                        .flex()
                                        .flex_row()
                                        .items_center()
                                        .gap(space(1))
                                        .child(
                                            div()
                                                .id(SharedString::from(format!(
                                                    "settings-model-fetch-apply-{index}"
                                                )))
                                                .role(Role::Button)
                                                .aria_label("加入选中的模型")
                                                .px(space(2))
                                                .py(px(3.0))
                                                .rounded(px(RADIUS_SMALL))
                                                .bg(palette.accent)
                                                .text_color(palette.canvas)
                                                .text_size(px(11.0))
                                                .child("加入选中模型")
                                                .on_click(move |_, _, cx| {
                                                    let _ = apply_weak.update(cx, |this, cx| {
                                                        this.apply_fetched_models(index, cx);
                                                    });
                                                }),
                                        )
                                        .child(
                                            div()
                                                .id(SharedString::from(format!(
                                                    "settings-model-fetch-dismiss-{index}"
                                                )))
                                                .role(Role::Button)
                                                .px(space(2))
                                                .py(px(3.0))
                                                .rounded(px(RADIUS_SMALL))
                                                .text_size(px(11.0))
                                                .text_color(palette.ink_3)
                                                .hover(|style| style.bg(palette.soft))
                                                .child("取消")
                                                .on_click(move |_, _, cx| {
                                                    let _ = dismiss_weak.update(cx, |this, cx| {
                                                        this.dismiss_fetched_models(index, cx);
                                                    });
                                                }),
                                        ),
                                )
                                .into_any_element()
                        }))
                        .children(draft.fetching_models.then(|| {
                            div()
                                .text_size(px(10.0))
                                .text_color(palette.ink_3)
                                .child("正在向供应商获取模型列表…")
                                .into_any_element()
                        }))
                        .children(draft.fetch_error.clone().map(|error| {
                            div()
                                .text_size(px(10.0))
                                .text_color(palette.danger)
                                .child(error)
                                .into_any_element()
                        }))
                        .children(draft.model_fields.iter().enumerate().map(
                            |(model_index, field)| {
                                let enabled = field.enabled;
                                let thinking = field.thinking;
                                let supports_tools = field.supports_tools;
                                let supports_images = field.supports_images;
                                let images_cb_weak = weak.clone();
                                let toggle_weak = weak.clone();
                                let thinking_weak = weak.clone();
                                let thinking_cb_weak = thinking_weak.clone();
                                let tools_cb_weak = weak.clone();
                                let remove_weak = weak.clone();
                                let context_input = field.context_input.clone();
                                let output_input = field.output_input.clone();
                                div()
                                    .flex()
                                    .flex_col()
                                    .gap(space(1))
                                    .p(space(2))
                                    .rounded(px(RADIUS_MEDIUM))
                                    .border_1()
                                    .border_color(palette.line)
                                    .child(
                                        div()
                                            .flex()
                                            .flex_row()
                                            .items_center()
                                            .gap(space(1))
                                            .child(
                                                Checkbox::new(SharedString::from(format!(
                                                    "settings-model-enable-{index}-{model_index}"
                                                )))
                                                .large()
                                                .checked(enabled)
                                                .on_click(move |_checked, _, cx| {
                                                    let _ = toggle_weak.update(cx, |this, cx| {
                                                        this.toggle_model_field(
                                                            index,
                                                            model_index,
                                                            0,
                                                            cx,
                                                        );
                                                    });
                                                }),
                                            )
                                            .child(
                                                div()
                                                    .text_size(px(12.0))
                                                    .text_color(palette.ink_2)
                                                    .child(format!("Model {}", model_index + 1)),
                                            )
                                            .children(
                                                draft
                                                    .model_tests
                                                    .get(&field.model_id)
                                                    .map(|result| match result {
                                                        Ok(()) => div()
                                                            .text_size(px(10.0))
                                                            .text_color(palette.accent)
                                                            .child("✓ 可用")
                                                            .into_any_element(),
                                                        Err(error) => div()
                                                            .text_size(px(10.0))
                                                            .text_color(palette.danger)
                                                            .child(format!(
                                                                "✗ {}",
                                                                provider_validation_message(error)
                                                            ))
                                                            .into_any_element(),
                                                    }),
                                            )
                                            .child(div().flex_1())
                                            .child(
                                                div()
                                                    .id(SharedString::from(format!(
                                                        "settings-model-remove-{index}-{model_index}"
                                                    )))
                                                    .role(Role::Button)
                                                    .px(space(1))
                                                    .text_size(px(11.0))
                                                    .text_color(palette.ink_3)
                                                    .hover(|style| style.bg(palette.soft))
                                                    .child("删除")
                                                    .on_click(move |_, window, cx| {
                                                        let _ = remove_weak.update(cx, |this, cx| {
                                                            this.remove_model_field(
                                                                index,
                                                                model_index,
                                                                window,
                                                                cx,
                                                            );
                                                        });
                                                    }),
                                            ),
                                    )
                                    .child(SettingsWindowView::render_provider_field(
                                        "Model Name *",
                                        Some("该模型在 Provider API 中的名称。"),
                                        field.name_input.clone(),
                                        palette,
                                    ))
                                    .child(SettingsWindowView::render_provider_field(
                                        "Context Window *",
                                        Some("模型上下文窗口大小（tokens）。"),
                                        context_input,
                                        palette,
                                    ))
                                    .child(SettingsWindowView::render_provider_field(
                                        "Max Output Tokens *",
                                        Some("模型单次可输出的最大 tokens。"),
                                        output_input,
                                        palette,
                                    ))
                                    .child(
                                        div()
                                            .flex()
                                            .flex_col()
                                            .gap(px(1.0))
                                            .child(
                                                div()
                                                    .flex()
                                                    .flex_row()
                                                    .items_center()
                                                    .gap(px(4.0))
                                                    .child(
                                                        Checkbox::new(SharedString::from(format!(
                                                            "settings-model-thinking-{index}-{model_index}"
                                                        )))
                                                        .large()
                                                        .checked(thinking)
                                                        .on_click(move |_checked, _, cx| {
                                                            let _ = thinking_cb_weak.update(cx, |this, cx| {
                                                                this.toggle_model_field(
                                                                    index,
                                                                    model_index,
                                                                    1,
                                                                    cx,
                                                                );
                                                            });
                                                        }),
                                                    )
                                                    .child(
                                                        div()
                                                            .text_size(px(11.0))
                                                            .text_color(palette.ink_2)
                                                            .child("Supports thinking"),
                                                    ),
                                            )
                                            .child(
                                                div()
                                                    .pl(px(26.0))
                                                    .text_size(px(10.0))
                                                    .text_color(palette.ink_3)
                                                    .child("模型会输出推理内容。"),
                                            ),
                                    )
                                    .children((draft.protocol == ProviderProtocol::AnthropicCompatible && thinking).then(|| {
                                        let mode_weak = weak.clone();
                                        div().flex().flex_col().gap(space(1))
                                            .child(div().flex().items_center().gap(space(1))
                                                .child(Checkbox::new(SharedString::from(format!("settings-model-adaptive-{index}-{model_index}")))
                                                    .checked(field.thinking_mode == ThinkingMode::Adaptive)
                                                    .on_click(move |_, _, cx| { let _ = mode_weak.update(cx, |this, cx| this.toggle_model_field(index, model_index, 4, cx)); }))
                                                .child(div().text_size(px(11.0)).child("Adaptive thinking")))
                                            .children((field.thinking_mode != ThinkingMode::Adaptive).then(|| {
                                                SettingsWindowView::render_provider_field("Thinking Budget", Some("至少 1024，且小于 Max Output Tokens。"), field.budget_input.clone(), palette)
                                            }))
                                    }))
                                    .child(
                                        div()
                                            .flex()
                                            .flex_col()
                                            .gap(px(1.0))
                                            .child(
                                                div()
                                                    .flex()
                                                    .flex_row()
                                                    .items_center()
                                                    .gap(px(4.0))
                                                    .child(
                                                        Checkbox::new(SharedString::from(format!(
                                                            "settings-model-tools-{index}-{model_index}"
                                                        )))
                                                        .large()
                                                        .checked(supports_tools)
                                                        .on_click(move |_checked, _, cx| {
                                                            let _ = tools_cb_weak.update(cx, |this, cx| {
                                                                this.toggle_model_field(
                                                                    index,
                                                                    model_index,
                                                                    2,
                                                                    cx,
                                                                );
                                                            });
                                                        }),
                                                    )
                                                    .child(
                                                        div()
                                                            .text_size(px(11.0))
                                                            .text_color(palette.ink_2)
                                                            .child("Supports tools"),
                                                    ),
                                            )
                                            .child(
                                                div()
                                                    .pl(px(26.0))
                                                    .text_size(px(10.0))
                                                    .text_color(palette.ink_3)
                                                    .child("允许模型调用工具。"),
                                            ),
                                    )
                                    .child(
                                        div()
                                            .flex()
                                            .flex_col()
                                            .gap(px(1.0))
                                            .child(
                                                div()
                                                    .flex()
                                                    .flex_row()
                                                    .items_center()
                                                    .gap(px(4.0))
                                                    .child(
                                                        Checkbox::new(SharedString::from(format!(
                                                            "settings-model-images-{index}-{model_index}"
                                                        )))
                                                        .large()
                                                        .checked(supports_images)
                                                        .on_click(move |_checked, _, cx| {
                                                            let _ = images_cb_weak.update(cx, |this, cx| {
                                                                this.toggle_model_field(
                                                                    index,
                                                                    model_index,
                                                                    3,
                                                                    cx,
                                                                );
                                                            });
                                                        }),
                                                    )
                                                    .child(
                                                        div()
                                                            .text_size(px(11.0))
                                                            .text_color(palette.ink_2)
                                                            .child("Supports images"),
                                                    ),
                                            )
                                            .child(
                                                div()
                                                    .pl(px(26.0))
                                                    .text_size(px(10.0))
                                                    .text_color(palette.ink_3)
                                                    .child("模型支持图片输入。"),
                                            ),
                                    )
                            },
                        ))
                )
                .child(
                    div()
                        .flex()
                        .flex_row()
                        .items_center()
                        .gap(space(2))
                        .child(
                            div()
                                .id(SharedString::from(format!(
                                    "settings-provider-clone-{index}"
                                )))
                                .role(Role::Button)
                                .aria_label("再添加一个 provider")
                                .px(space(2))
                                .py(px(5.0))
                                .rounded(px(RADIUS_MEDIUM))
                                .border_1()
                                .border_color(palette.line)
                                .text_color(palette.ink_2)
                                .text_size(px(11.0))
                                .child("再添加一个")
                                .on_click(move |_, _, cx| {
                                    let _ = clone_weak.update(cx, |this, cx| {
                                        this.clone_provider(index, cx);
                                    });
                                }),
                        )
                        .child(
                            div()
                                .id(SharedString::from(format!(
                                    "settings-provider-save-{index}"
                                )))
                                .role(Role::Button)
                                .aria_label("保存 provider")
                                .px(space(2))
                                .py(px(5.0))
                                .rounded(px(RADIUS_MEDIUM))
                                .bg(palette.accent)
                                .text_color(palette.canvas)
                                .text_size(px(11.0))
                                .child(save_label)
                                .on_click(move |_, window, cx| {
                                    let _ = save_weak.update(cx, |this, cx| {
                                        this.save_provider(index, window, cx);
                                    });
                                }),
                        )
                )
                .into_any_element(),
        );
    }
    div()
        .flex()
        .flex_col()
        .gap(space(2))
        .children(cards)
        .children(notice.map(|notice| {
            div()
                .text_size(px(11.0))
                .text_color(palette.ink_3)
                .child(notice)
        }))
        .children(error.map(|error| {
            div()
                .text_size(px(11.0))
                .text_color(palette.danger)
                .child(error)
        }))
        .into_any_element()
}

impl Render for SettingsWindowView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let fullscreen = window.is_fullscreen() || window.is_simple_fullscreen();
        let language = self.language;
        let palette = theme::palette_from_theme(cx);
        let focus = self.focus.clone();

        for index in 0..self.provider_drafts.len() {
            self.ensure_provider_inputs(index, window, cx);
        }

        div()
            .size_full()
            .flex()
            .flex_col()
            .bg(palette.canvas)
            .text_color(palette.ink)
            .font_family(theme::FONT_SANS)
            .text_size(px(14.0))
            .track_focus(&focus)
            .on_key_down(cx.listener(
                |_this: &mut Self,
                 event: &KeyDownEvent,
                 window: &mut Window,
                 _: &mut Context<Self>| {
                    if event.keystroke.key == "escape" {
                        window.remove_window();
                    }
                },
            ))
            .child(
                TitleBar::new()
                    .h(px(TITLEBAR_HEIGHT))
                    .pl(title_bar_left_inset(fullscreen))
                    .pr(space(2))
                    .gap(space(2))
                    .bg(palette.frame)
                    .border_b_1()
                    .border_color(palette.line)
                    .child(
                        div()
                            .text_size(px(14.0))
                            .text_color(palette.ink)
                            .child(translate(language, Key::AppSettingsTitle)),
                    )
                    .child(div().flex_1())
                    .child(
                        div()
                            .id("settings-close")
                            .role(Role::Button)
                            .aria_label(translate(language, Key::AppSettingsClose))
                            .px(space(2))
                            .py(px(4.0))
                            .rounded(px(RADIUS_MEDIUM))
                            .text_size(px(12.0))
                            .text_color(palette.ink_3)
                            .hover(|style| style.bg(palette.soft))
                            .child(translate(language, Key::AppSettingsClose))
                            .on_click(|_, window, _| window.remove_window()),
                    ),
            )
            .child(
                div()
                    .id("settings-content")
                    .flex_1()
                    .min_h(px(0.0))
                    .child(self.build_settings(window, cx)),
            )
    }
}

#[cfg(test)]
mod settings_provider_validation_tests {
    use super::{provider_validation_message, refresh_outcome};
    use crate::native_runtime::NativeRuntimeError;
    use cgc_agent_provider::{ProviderError, ProviderErrorCategory};

    #[test]
    fn validation_errors_are_user_readable() {
        assert_eq!(
            provider_validation_message(&ProviderError::api(401, "invalid key")),
            "API Key 无效或已过期"
        );
        assert_eq!(
            provider_validation_message(&ProviderError::transport("offline")),
            "网络连接失败，请检查网络后重试"
        );
        assert_eq!(
            provider_validation_message(&ProviderError::api_with_category(
                ProviderErrorCategory::PaymentRequired,
                Some(402),
                "balance",
            )),
            "账户余额不足"
        );
    }

    #[test]
    fn refresh_outcomes_distinguish_success_busy_and_failure() {
        let (notice, error) = refresh_outcome("Provider 已保存", Ok(()));
        assert_eq!(notice.as_deref(), Some("Provider 已保存"));
        assert!(error.is_none());

        let (notice, error) = refresh_outcome("Provider 已保存", Err(NativeRuntimeError::Busy));
        assert!(notice.is_none());
        assert!(error
            .as_deref()
            .is_some_and(|message| message.contains("当前会话正在运行")));

        let (notice, error) = refresh_outcome(
            "Provider 已保存",
            Err(NativeRuntimeError::Configuration("bad model".into())),
        );
        assert!(notice.is_none());
        assert!(error
            .as_deref()
            .is_some_and(|message| message.contains("bad model")));
    }
}
