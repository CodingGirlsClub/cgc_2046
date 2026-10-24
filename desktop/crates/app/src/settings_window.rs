//! 独立设置窗口（对齐 Zed：`cmd-,` / `ctrl-,` 打开独立 SettingsWindow；
//! 右上角用户菜单的 Settings 也打开它，而不是主窗口内路由）。
//!
//! 参考 Zed `settings_ui/src/settings_ui.rs::open_settings_editor_with`：
//! 已有窗口则激活复用，否则 `open_window` 新开居中窗口；主窗口仍保留自己的
//! 导航壳，设置不再占用 footer 导航位（`app.settings` 路由仅内部保留）。

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use cgc_agent_store::{
    builtin_providers, normalized_provider_name, provider_key_account, PrefsStore, ProviderPrefs,
};
use cgc_platform::paths::AppPaths;
use cgc_platform::session::KeychainStore;
use gpui_kit::component::checkbox::Checkbox;
use gpui_kit::component::group_box::GroupBoxVariant;
use gpui_kit::component::input::{Input, InputState, TextareaState};
use gpui_kit::component::setting::{
    SettingField, SettingGroup, SettingItem, SettingPage, Settings,
};
use gpui_kit::component::Sizable;
use gpui_kit::InteractiveElement;
use gpui_kit::*;

use crate::build_info;
use crate::i18n::{translate, Key, Language};
use crate::preferences;
use crate::settings_provider::{
    format_model_lines, parse_model_lines, ModelFieldInputs, ProviderDraft,
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
    prefs_store: PrefsStore,
    keychain: KeychainStore,
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
        cx: &mut Context<Self>,
    ) -> Self {
        let prefs_store = PrefsStore::new(AppPaths::from_env().agent_prefs_file());
        let prefs = prefs_store.load();
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
            prefs_store,
            keychain: KeychainStore::from_env(),
        }
    }

    /// 从其他窗口打开 Settings 时直接定位到 AI 页。
    pub fn open_ai(&mut self, cx: &mut Context<Self>) {
        self.ai_view = AiRoute::General;
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
                fields.push(ModelFieldInputs {
                    model_id: model.id.clone(),
                    name_input,
                    context_input,
                    output_input,
                    enabled: model.enabled,
                    thinking: model.supports_thinking,
                    supports_tools: model.supports_tools,
                    supports_images: model.supports_images,
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
                format!(
                    "{} | {} | {} | {} | {} | {} | {}",
                    name,
                    context,
                    output,
                    field.thinking,
                    field.enabled,
                    field.supports_tools,
                    field.supports_images
                )
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
        self.notice = Some("已恢复默认参数（保存后生效）".to_string());
        cx.notify();
    }

    fn save_provider_key(&mut self, index: usize, window: &mut Window, cx: &mut Context<Self>) {
        self.sync_model_fields(index, window, cx);
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
        match self
            .keychain
            .save_secret(&provider_key_account(&draft.id), &key)
        {
            Ok(()) => {
                input.update(cx, |state, cx| state.set_value("", window, cx));
                if let Some(draft) = self.provider_drafts.get_mut(index) {
                    draft.has_key = true;
                    draft.key_editing = false;
                    let provider = draft.to_prefs();
                    let mut prefs = self.prefs_store.load();
                    prefs.upsert_provider(provider);
                    if prefs.selected_provider.as_deref().is_none() {
                        prefs.selected_provider = Some(self.provider_drafts[index].id.clone());
                    }
                    let _ = self.prefs_store.save(&prefs);
                }
                self.notice = Some("API Key 已保存；重新打开 Agent 面板后生效".to_string());
                self.error = None;
            }
            Err(error) => self.error = Some(format!("API Key 保存失败：{error}")),
        }
        cx.notify();
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
        self.sync_all_draft_names(cx);
        let Some(draft) = self.provider_drafts.get(index).cloned() else {
            return;
        };
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
        let (models, mut model_params) = parse_model_lines(&models_text);
        for model in &mut model_params {
            if let Some(previous) = draft
                .model_params
                .iter()
                .find(|previous| previous.id == model.id)
            {
                model.reasoning_efforts = previous.reasoning_efforts.clone();
            }
        }
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
            models,
            has_key: draft.has_key,
            model_params,
            builtin: false,
        };
        if let Some(api_key_input) = draft.api_key_input.clone() {
            let api_key = api_key_input.read(cx).value().trim().to_string();
            if api_key.is_empty()
                && self
                    .keychain
                    .load_secret(&provider_key_account(&provider.id))
                    .is_some_and(|key| !key.is_empty())
            {
                provider.has_key = true;
            }
            if !api_key.is_empty() {
                match self
                    .keychain
                    .save_secret(&provider_key_account(&provider.id), &api_key)
                {
                    Ok(()) => {
                        provider.has_key = true;
                        api_key_input.update(cx, |state, cx| {
                            state.set_value("", window, cx);
                        });
                    }
                    Err(error) => {
                        self.error = Some(format!("API Key 保存失败：{error}"));
                        cx.notify();
                        return;
                    }
                }
            }
        }
        let mut prefs = self.prefs_store.load();
        prefs.upsert_provider(provider.clone());
        if prefs.selected_provider.as_deref().is_none()
            || prefs.provider(&provider.id).map(|item| item.id.clone()) == Some(provider.id.clone())
        {
            prefs.selected_provider = Some(provider.id.clone());
        }
        match self.prefs_store.save(&prefs) {
            Ok(()) => {
                self.error = None;
                self.notice = Some("Provider 已保存".to_string());
                self.ai_view = AiRoute::Providers;
                if let Some(draft) = self.provider_drafts.get_mut(index) {
                    draft.base_url = provider.base_url.clone();
                    draft.name = provider.name.clone();
                    draft.models = format_model_lines(&provider);
                    draft.model_params = provider.model_params.clone();
                    draft.has_key = provider.has_key;
                    draft.builtin = false;
                }
            }
            Err(error) => self.error = Some(format!("保存失败：{error}")),
        }
        cx.notify();
    }

    fn reset_provider_key(&mut self, index: usize, cx: &mut Context<Self>) {
        let Some(draft) = self.provider_drafts.get(index).cloned() else {
            return;
        };
        match self.keychain.clear_secret(&provider_key_account(&draft.id)) {
            Ok(()) => {
                let mut provider = draft.to_prefs();
                provider.has_key = false;
                let mut prefs = self.prefs_store.load();
                prefs.upsert_provider(provider);
                let _ = self.prefs_store.save(&prefs);
                if let Some(draft) = self.provider_drafts.get_mut(index) {
                    draft.has_key = false;
                    draft.key_editing = false;
                    draft.confirm_clear = false;
                }
                self.notice = Some("API Key 已清除；重新打开 Agent 面板后生效".to_string());
                self.error = None;
            }
            Err(error) => self.error = Some(format!("清除 API Key 失败：{error}")),
        }
        cx.notify();
    }

    fn add_provider(&mut self, cx: &mut Context<Self>) {
        let draft = ProviderDraft::new_custom();
        let id = draft.id.clone();
        self.provider_drafts.push(draft);
        self.ai_view = AiRoute::NewProvider(id);
        self.notice = Some("新增 Provider：填写名称/URL/模型后保存".to_string());
        cx.notify();
    }

    fn remove_provider(&mut self, index: usize, cx: &mut Context<Self>) {
        let Some(draft) = self.provider_drafts.get(index).cloned() else {
            return;
        };
        self.provider_drafts.remove(index);
        let mut prefs = self.prefs_store.load();
        prefs.remove_provider(&draft.id);
        let _ = self.prefs_store.save(&prefs);
        self.notice = Some("Provider 已删除".to_string());
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
                    let mut prefs = preferences::load();
                    prefs.close_to_tray = value;
                    preferences::save(prefs);
                },
            ),
        )
        .description(translate(language, Key::AppSettingsCloseToTrayHint));
        let native_agent = SettingItem::new(
            "启用 Native Agent 入口",
            SettingField::switch(
                |_cx: &App| preferences::load().native_agent_enabled,
                |value: bool, _cx: &mut App| {
                    let mut prefs = preferences::load();
                    prefs.native_agent_enabled = value;
                    preferences::save(prefs);
                },
            ),
        )
        .description("灰度开关：账号菜单与课程页显示 Native Agent（Beta）");
        let providers_weak = weak.clone();
        let providers_drafts = drafts.clone();
        let providers_item = SettingItem::render(move |_options, _window, cx| {
            let palette = theme::palette_from_theme(cx);
            render_provider_list(
                cx,
                &providers_weak,
                &providers_drafts,
                &palette,
                notice.clone(),
                error.clone(),
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
                        div()
                            .id("settings-providers-add")
                            .role(Role::Button)
                            .aria_label("添加 Provider")
                            .px(space(2))
                            .py(px(4.0))
                            .rounded(px(RADIUS_MEDIUM))
                            .bg(palette.accent)
                            .text_color(palette.canvas)
                            .text_size(px(11.0))
                            .child("＋ 添加 Provider")
                            .on_click(move |_, _, cx| {
                                let _ = add_weak.update(cx, |this, cx| {
                                    this.add_provider(cx);
                                });
                            }),
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
        let form_index = form_target
            .as_ref()
            .and_then(|id| drafts.iter().position(|draft| &draft.id == id))
            .unwrap_or(0);
        let form_is_builtin = drafts
            .get(form_index)
            .map(|draft| draft.builtin)
            .unwrap_or(false);
        let form_back = {
            let back_weak = weak.clone();
            let form_name = form_name.clone();
            SettingItem::render(move |_options, _window, cx| {
                let palette = theme::palette_from_theme(cx);
                let weak = back_weak.clone();
                let restore_weak_outer = weak.clone();
                let cancel_weak = weak.clone();
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
                                            this.ai_view = AiRoute::Providers;
                                            cx.notify();
                                        });
                                    }),
                            )
                            .child(
                                div()
                                    .id("settings-provider-form-cancel")
                                    .role(Role::Button)
                                    .aria_label("取消")
                                    .px(space(2))
                                    .py(px(3.0))
                                    .rounded(px(RADIUS_SMALL))
                                    .text_size(px(11.0))
                                    .text_color(palette.ink_3)
                                    .hover(|style| style.bg(palette.soft))
                                    .child("取消")
                                    .on_click(move |_, _, cx| {
                                        let _ = cancel_weak.update(cx, |this, cx| {
                                            this.ai_view = AiRoute::Providers;
                                            cx.notify();
                                        });
                                    }),
                            )
                            .children(form_is_builtin.then(|| {
                                let restore_weak = restore_weak_outer.clone();
                                div()
                                    .id("settings-provider-form-restore")
                                    .role(Role::Button)
                                    .aria_label("恢复默认")
                                    .px(space(2))
                                    .py(px(3.0))
                                    .rounded(px(RADIUS_SMALL))
                                    .text_size(px(11.0))
                                    .text_color(palette.ink_2)
                                    .hover(|style| style.bg(palette.soft))
                                    .child("恢复默认")
                                    .on_click(move |_, window, cx| {
                                        let _ = restore_weak.update(cx, |this, cx| {
                                            this.restore_provider_default(form_index, window, cx);
                                        });
                                    })
                            }))
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
                    SettingGroup::new()
                        .title("通用")
                        .items(vec![llm_link, native_agent]),
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

        let settings = Settings::new("cgc-settings")
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
                        SettingGroup::new().title("通用").item(close_to_tray),
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

fn render_provider_list(
    _cx: &mut App,
    weak: &WeakEntity<SettingsWindowView>,
    drafts: &[ProviderDraft],
    palette: &theme::Palette,
    notice: Option<String>,
    error: Option<String>,
) -> AnyElement {
    let mut rows: Vec<AnyElement> = Vec::new();
    for (index, draft) in drafts.iter().enumerate() {
        let total = parse_model_lines(&draft.models).0.len();
        let enabled = draft
            .model_params
            .iter()
            .filter(|model| model.enabled)
            .count();
        let status = if draft.has_key {
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
                                .bg(palette.accent)
                                .text_color(palette.canvas)
                                .text_size(px(10.0))
                                .child("保存 Key")
                                .on_click(move |_, window, cx| {
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
                        .aria_label("高级配置")
                        .px(space(2))
                        .py(px(4.0))
                        .rounded(px(RADIUS_MEDIUM))
                        .border_1()
                        .border_color(palette.line)
                        .text_size(px(11.0))
                        .child("高级配置 >")
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
                            cx.open_url("https://codinggirlsclub.com/");
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
        let (Some(base_input), Some(_models_input), Some(key_input)) = (
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
                .child(SettingsWindowView::render_provider_field(
                    "API URL *",
                    Some("兼容 API 的基础 URL。"),
                    base_input,
                    palette,
                ))
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
                        )
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
                div()
                    .id("settings-titlebar")
                    .flex()
                    .items_center()
                    .h(px(44.0))
                    .pl(if cfg!(target_os = "macos") {
                        px(84.0)
                    } else {
                        space(3)
                    })
                    .pr(space(2))
                    .gap(space(2))
                    .bg(palette.frame)
                    .border_b_1()
                    .border_color(palette.line)
                    .on_mouse_down(MouseButton::Left, |_, window, _| {
                        window.start_window_move();
                    })
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
