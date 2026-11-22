use super::*;
use cgc_agent_core::{run_subagent_with_affinity, Agent, SelectedModel};
use cgc_agent_provider::{
    AnthropicCompatibleConfig, AnthropicCompatibleProvider, EchoProvider, ModelCapabilities,
    ModelLimits, OpenAiCompatibleConfig, OpenAiCompatibleProvider, ProviderId, ProviderProtocol,
    ResponsesCompatibleConfig, ResponsesCompatibleProvider, ThinkingMode, UnconfiguredProvider,
};
use cgc_agent_store::{
    cgc_cloud_provider, cgc_cloud_provider_with_models, provider_key_account, AgentPrefs,
    ModelPrefs, PrefsStore, CGC_CLOUD_PROVIDER_ID,
};
use cgc_agent_tools::{
    ActionSink, SandboxPolicy, SubagentEvent, SubagentEventSink, SubagentRunner,
};
use cgc_platform::gateway::GatewayModel;
use cgc_platform::session::KeychainStore;
use std::sync::Weak;

/// 启动时**不读钥匙串**：先发布快照让界面可用，首次 turn 前再解析（见 `resolve_pending_key`）。
/// 真机上钥匙串读取在无授权时会阻塞 8–11s，放在初始化路径会让窗口一直停在载入态。
#[derive(Clone, Debug)]
pub(super) struct PendingCredentials {
    pub provider_id: String,
    pub base_url: String,
    pub protocol: ProviderProtocol,
}

/// 按协议取地址：Anthropic 协议优先用单独的 Anthropic 地址，空则回落到主地址。
fn endpoint_url(provider: &ProviderPrefs) -> String {
    match provider.protocol {
        ProviderProtocol::AnthropicCompatible => provider
            .anthropic_url
            .clone()
            .filter(|url| !url.trim().is_empty())
            .unwrap_or_else(|| provider.base_url.clone()),
        ProviderProtocol::OpenAiCompatible | ProviderProtocol::OpenAiResponses => {
            provider.base_url.clone()
        }
    }
}

/// 登录态下的有效 Provider：显式选择的 BYOK 优先；没有可用 BYOK 时默认 CGC Cloud。
/// 工厂初始化与运行时 refresh 共用，避免登录后两条路径给出不同选择。
///
/// 已保存的 CGC 配置优先于新造默认值：用户禁用的模型/Provider 不能被登录
/// 默认逻辑悄悄重新启用；若用户明确禁用了 CGC 且没有可用 BYOK，则保持
pub(super) fn env_byok_credentials() -> (Option<String>, Option<String>) {
    let base_url = std::env::var("CGC_AGENT_BASE_URL")
        .ok()
        .filter(|value| !value.is_empty());
    let api_key = std::env::var("CGC_AGENT_API_KEY")
        .ok()
        .filter(|value| !value.is_empty());
    (base_url, api_key)
}

pub(super) fn has_env_byok(
    prefs: &AgentPrefs,
    env_base_url: Option<&str>,
    env_key: Option<&str>,
) -> bool {
    match (env_base_url, env_key) {
        (Some(_), Some(_)) => true,
        (None, Some(_)) => prefs
            .active_provider()
            .is_some_and(|provider| provider.id != CGC_CLOUD_PROVIDER_ID),
        _ => false,
    }
}

pub(super) fn cgc_cloud_provider_from_models(
    remote: &[GatewayModel],
    saved_managed: Option<&ProviderPrefs>,
) -> Option<ProviderPrefs> {
    if remote.is_empty() {
        return None;
    }
    let models = remote
        .iter()
        .map(|item| {
            let enabled = saved_managed
                .and_then(|provider| provider.model_params.iter().find(|m| m.id == item.model_id))
                .is_none_or(|saved| saved.enabled);
            ModelPrefs {
                id: item.model_id.clone(),
                display_name: (!item.display_name.trim().is_empty())
                    .then(|| item.display_name.clone()),
                context_window: item.context_window,
                max_output_tokens: item.max_output_tokens,
                supports_thinking: item.supports_thinking,
                enabled,
                supports_tools: item.supports_tools,
                supports_images: item.supports_images,
                reasoning_efforts: item.reasoning_efforts.clone(),
                thinking_mode: ThinkingMode::Disabled,
            }
        })
        .collect();
    let mut provider = cgc_cloud_provider_with_models(models);
    provider.enabled = saved_managed.is_none_or(|saved| saved.enabled);
    Some(provider)
}

pub(super) fn cgc_cloud_provider_from_gateway(
    saved_managed: Option<&ProviderPrefs>,
) -> Option<ProviderPrefs> {
    if !cgc_platform::gateway::signed_in() {
        return None;
    }
    let remote = cgc_platform::gateway::cached_models();
    cgc_cloud_provider_from_models(&remote, saved_managed)
}

pub(super) fn merge_available_providers(
    saved: &[ProviderPrefs],
    managed_provider: Option<ProviderPrefs>,
) -> Vec<ProviderPrefs> {
    let mut available = Vec::new();
    if let Some(managed) = managed_provider {
        if managed.enabled && !managed.models.is_empty() {
            available.push(managed);
        }
    }
    available.extend(
        saved
            .iter()
            .filter(|provider| provider.id != CGC_CLOUD_PROVIDER_ID && provider.enabled)
            .cloned(),
    );
    available
}

/// 测试用包装：由 `resolve_active_provider_with_env` 复用真实逻辑。
#[cfg(test)]
pub(super) fn resolve_active_provider(
    prefs: &AgentPrefs,
    managed_provider: Option<ProviderPrefs>,
) -> (bool, Option<ProviderPrefs>) {
    resolve_active_provider_with_env(prefs, managed_provider, false)
}

pub(super) fn resolve_active_provider_with_env(
    prefs: &AgentPrefs,
    managed_provider: Option<ProviderPrefs>,
    env_byok_configured: bool,
) -> (bool, Option<ProviderPrefs>) {
    if env_byok_configured {
        let byok_active = prefs
            .active_provider()
            .filter(|provider| provider.id != CGC_CLOUD_PROVIDER_ID)
            .cloned();
        return (false, byok_active);
    }
    let saved_managed = prefs.provider(CGC_CLOUD_PROVIDER_ID);
    let managed_available = managed_provider
        .as_ref()
        .is_some_and(|provider| provider.enabled && !provider.models.is_empty());
    let configured_byok = prefs
        .providers
        .iter()
        .find(|provider| {
            prefs.selected_provider.as_deref() == Some(provider.id.as_str())
                && provider.id != CGC_CLOUD_PROVIDER_ID
                && provider.enabled
        })
        .or_else(|| {
            prefs
                .providers
                .iter()
                .find(|provider| provider.id != CGC_CLOUD_PROVIDER_ID && provider.enabled)
        })
        .filter(|provider| provider.has_key || !managed_available)
        .cloned();

    if prefs.selected_provider.as_deref() == Some(CGC_CLOUD_PROVIDER_ID) {
        if saved_managed.is_some_and(|provider| !provider.enabled) {
            return (false, configured_byok);
        }
        if managed_available {
            return (true, managed_provider);
        }
        return (false, configured_byok);
    }

    if let Some(byok) = configured_byok {
        return (false, Some(byok));
    }
    if managed_available {
        return (true, managed_provider);
    }
    (false, None)
}

pub(super) struct Production {
    pub host: NativePanelHost,
    pub providers: Arc<Vec<ProviderPrefs>>,
    pub data_root: PathBuf,
    pub keychain: KeychainStore,
    pub allow_echo: bool,
    pub model_setup: ModelSetup,
    pub pending: Option<PendingCredentials>,
}

pub(super) fn initialize(
    scope: &AgentScope,
    data_root: PathBuf,
    host: NativePanelHost,
    allow_echo: bool,
) -> Result<(Agent, NativeRuntimeConfig, Production), NativeRuntimeError> {
    initialize_with_keychain(
        scope,
        data_root,
        host,
        KeychainStore::from_env(),
        allow_echo,
    )
}

/// 可注入钥匙串的构造入口：测试用它断言「初始化不读钥匙串」。
pub(super) fn initialize_with_keychain(
    scope: &AgentScope,
    data_root: PathBuf,
    host: NativePanelHost,
    keychain: KeychainStore,
    allow_echo: bool,
) -> Result<(Agent, NativeRuntimeConfig, Production), NativeRuntimeError> {
    std::fs::create_dir_all(&scope.root)
        .map_err(|error| NativeRuntimeError::Storage(error.to_string()))?;
    let prefs = PrefsStore::new(data_root.join("agent_prefs.json")).load();
    let managed_prefs = cgc_cloud_provider_from_gateway(prefs.provider(CGC_CLOUD_PROVIDER_ID));
    let (env_base_url, env_key) = env_byok_credentials();
    let env_byok = has_env_byok(&prefs, env_base_url.as_deref(), env_key.as_deref());
    let (managed, active) =
        resolve_active_provider_with_env(&prefs, managed_prefs.clone(), env_byok);
    let protocol = std::env::var("CGC_AGENT_PROTOCOL")
        .ok()
        .map(|value| value.parse::<ProviderProtocol>())
        .transpose()
        .map_err(|error| NativeRuntimeError::Configuration(error.into()))?
        .unwrap_or_else(|| {
            active
                .as_ref()
                .map_or(ProviderProtocol::default(), |provider| provider.protocol)
        });
    let provider_id = active
        .as_ref()
        .map(|provider| provider.id.clone())
        .filter(|id| !id.is_empty())
        .unwrap_or_else(|| "custom".into());
    let model_id = std::env::var("CGC_AGENT_MODEL")
        .ok()
        .filter(|value| !value.is_empty())
        .or_else(|| {
            prefs
                .selected_model
                .as_ref()
                .filter(|selection| {
                    active
                        .as_ref()
                        .is_some_and(|provider| provider.id == selection.provider_id.as_str())
                })
                .map(|model| model.model_id.as_str().into())
        })
        .or_else(|| {
            active
                .as_ref()
                .and_then(|provider| provider.primary_model().map(str::to_string))
        })
        .unwrap_or_else(|| "echo".into());
    let model_id = match active.as_ref() {
        Some(provider)
            if !provider.models.contains(&model_id)
                || !provider.model_config(&model_id).enabled =>
        {
            provider
                .models
                .iter()
                .find(|id| provider.model_config(id).enabled)
                .cloned()
                .unwrap_or(model_id)
        }
        _ => model_id,
    };
    let model_config = active
        .as_ref()
        .map(|provider| provider.model_config(&model_id))
        .unwrap_or_default();
    let model_available = model_config.enabled
        && active
            .as_ref()
            .is_none_or(|provider| provider.models.contains(&model_id));
    let name = std::env::var("CGC_AGENT_PROVIDER_NAME")
        .ok()
        .or_else(|| active.as_ref().map(|provider| provider.name.clone()))
        .filter(|name| !name.is_empty())
        .unwrap_or_else(|| "OpenAI Compatible".into());
    let model_display_name = model_config
        .display_name
        .clone()
        .filter(|display| !display.trim().is_empty())
        .unwrap_or_else(|| model_id.clone());
    let model = Model::new(
        ProviderId::new(provider_id),
        name,
        model_id,
        model_display_name,
        ModelLimits::new(model_config.context_window, model_config.max_output_tokens),
    )
    .with_thinking_mode(model_config.thinking_mode)
    .with_capabilities(ModelCapabilities {
        tools: model_config.supports_tools,
        images: model_config.supports_images,
        thinking: model_config.supports_thinking,
    });
    let base_url = if managed {
        cgc_platform::gateway::gateway_base_url()
    } else {
        env_base_url.or_else(|| active.as_ref().map(endpoint_url))
    };
    // 只读环境变量：钥匙串留到首次 turn（Production::pending）。
    let active_has_key = active.as_ref().is_some_and(|provider| provider.has_key);
    let pending = match (&env_key, &base_url) {
        (Some(_), _) => None,
        (None, Some(url)) if !managed && !url.is_empty() && active_has_key && model_available => {
            Some(PendingCredentials {
                provider_id: model.provider_id.as_str().to_string(),
                base_url: url.clone(),
                protocol,
            })
        }
        _ => None,
    };
    let (provider, mut model_setup) = if model_available {
        if managed {
            (
                managed_provider(&model, base_url.as_deref().unwrap_or_default()),
                ModelSetup::Configured,
            )
        } else {
            provider(&model, protocol, base_url, env_key, allow_echo)
        }
    } else {
        provider(&model, protocol, None, None, false)
    };
    if pending.is_some() {
        model_setup = ModelSetup::PendingCredentials;
    }
    let agent = Agent::new(
        Thread::new(
            fresh_thread_id(),
            SelectedModel::new(model.provider_id.clone(), model.id.clone()),
        ),
        Some(crate::native_context::build_workspace_system_prompt(
            &scope.root,
        )),
    );
    let config = NativeRuntimeConfig {
        provider,
        model,
        registry: Arc::new(ToolRegistry::new()),
        context: ToolContext::new(&scope.root).with_sandbox(SandboxPolicy::new(&scope.root)),
        context_size: model_config.context_window as u64,
        auto_approve: false,
    };
    let available_providers = merge_available_providers(&prefs.providers, managed_prefs);
    Ok((
        agent,
        config,
        Production {
            host,
            providers: Arc::new(available_providers),
            data_root,
            keychain,
            allow_echo,
            model_setup,
            pending,
        },
    ))
}

pub(super) fn managed_provider_config(model: &Model, base_url: &str) -> OpenAiCompatibleConfig {
    OpenAiCompatibleConfig::new(base_url.to_string(), String::new(), vec![model.clone()])
        .with_token_source(super::gateway::token_source())
        .with_extra_headers(cgc_platform::runtime::client_headers())
}

fn managed_provider(model: &Model, base_url: &str) -> Arc<dyn Provider> {
    Arc::new(OpenAiCompatibleProvider::new(managed_provider_config(
        model, base_url,
    )))
}

fn provider(
    model: &Model,
    protocol: ProviderProtocol,
    base_url: Option<String>,
    api_key: Option<String>,
    allow_echo: bool,
) -> (Arc<dyn Provider>, ModelSetup) {
    match (base_url, api_key) {
        (Some(url), Some(key)) if !url.is_empty() && !key.is_empty() => (
            match protocol {
                ProviderProtocol::OpenAiCompatible => Arc::new(OpenAiCompatibleProvider::new(
                    OpenAiCompatibleConfig::new(url, key, vec![model.clone()]),
                )),
                ProviderProtocol::OpenAiResponses => Arc::new(ResponsesCompatibleProvider::new(
                    ResponsesCompatibleConfig::new(url, key, vec![model.clone()]),
                )),
                ProviderProtocol::AnthropicCompatible => {
                    Arc::new(AnthropicCompatibleProvider::new(
                        AnthropicCompatibleConfig::new(url, key, vec![model.clone()]),
                    ))
                }
            },
            ModelSetup::Configured,
        ),
        _ if allow_echo => (
            Arc::new(EchoProvider::new(model.clone())),
            ModelSetup::DemoEcho,
        ),
        _ => (
            Arc::new(UnconfiguredProvider::new(model.clone())),
            ModelSetup::Unconfigured,
        ),
    }
}

pub(super) fn prepare_model(
    production: &Production,
    provider_id: &str,
    model_id: &str,
) -> Result<(Arc<dyn Provider>, Model, ModelSetup), NativeRuntimeError> {
    let configured = production
        .providers
        .iter()
        .find(|provider| provider.id == provider_id)
        .ok_or_else(|| NativeRuntimeError::Configuration("Provider 不在当前配置中".into()))?;
    if !configured.enabled {
        return Err(NativeRuntimeError::Configuration("Provider 已停用".into()));
    }
    let model = configured_model(configured, model_id)
        .ok_or_else(|| NativeRuntimeError::Configuration("模型不可用或已禁用".into()))?;
    if configured.id == CGC_CLOUD_PROVIDER_ID {
        let base_url = cgc_platform::gateway::gateway_base_url().ok_or_else(|| {
            NativeRuntimeError::Configuration("CGC Gateway 地址不可用（未登录或端点被拒绝）".into())
        })?;
        return Ok((
            managed_provider(&model, &base_url),
            model,
            ModelSetup::Configured,
        ));
    }
    let key = production
        .keychain
        .load_secret(&provider_key_account(&configured.id));
    let (provider, model_setup) = provider(
        &model,
        configured.protocol,
        Some(endpoint_url(configured)),
        key,
        production.allow_echo,
    );
    Ok((provider, model, model_setup))
}

pub(super) fn select_model(
    production: &mut Production,
    provider_id: &str,
    model_id: &str,
) -> Result<(Arc<dyn Provider>, Model), NativeRuntimeError> {
    let (provider, model, model_setup) = prepare_model(production, provider_id, model_id)?;
    save_model_selection(production, &model)?;
    production.model_setup = model_setup;
    production.pending = None;
    Ok((provider, model))
}

pub(super) fn save_model_selection(
    production: &Production,
    model: &Model,
) -> Result<(), NativeRuntimeError> {
    let store = PrefsStore::new(production.data_root.join("agent_prefs.json"));
    let mut prefs = store.load();
    if model.provider_id.as_str() == CGC_CLOUD_PROVIDER_ID
        && prefs.provider(CGC_CLOUD_PROVIDER_ID).is_none()
    {
        let fallback = cgc_cloud_provider_from_gateway(None).unwrap_or_else(cgc_cloud_provider);
        prefs.upsert_provider(fallback);
    }
    prefs.selected_provider = Some(model.provider_id.as_str().to_string());
    prefs.selected_model = Some(SelectedModel::new(
        model.provider_id.clone(),
        model.id.clone(),
    ));
    store
        .save(&prefs)
        .map_err(|error| NativeRuntimeError::Storage(error.to_string()))
}

/// 会话标题生成模型：读用户设置文件的 `agent.thread_summary_model`（对齐 Zed 的
/// thread summary model），未配置或不可用时由调用方回退当前对话模型。
pub(super) fn summary_title_model(
    production: &Production,
    settings: &crate::user_settings::UserSettings,
) -> Option<(Arc<dyn Provider>, Model)> {
    let selection = settings.agent.thread_summary_model.as_ref()?;
    let store = PrefsStore::new(production.data_root.join("agent_prefs.json"));
    let prefs = store.load();
    let configured = if selection.provider.as_str() == CGC_CLOUD_PROVIDER_ID {
        cgc_cloud_provider_from_gateway(prefs.provider(CGC_CLOUD_PROVIDER_ID))
    } else {
        prefs.provider(selection.provider.as_str()).cloned()
    }?;
    if !configured.enabled {
        return None;
    }
    let model = configured_model(&configured, selection.model.as_str())?;
    if configured.id == CGC_CLOUD_PROVIDER_ID {
        let base_url = cgc_platform::gateway::gateway_base_url()?;
        return Some((managed_provider(&model, &base_url), model));
    }
    if !configured.has_key {
        return None;
    }
    let key = production
        .keychain
        .load_secret(&provider_key_account(&configured.id))?;
    if key.is_empty() {
        return None;
    }
    let (provider, model_setup) = provider(
        &model,
        configured.protocol,
        Some(endpoint_url(&configured)),
        Some(key),
        production.allow_echo,
    );
    (model_setup == ModelSetup::Configured).then_some((provider, model))
}

/// 只做「配置是否可用」的判定，便于单测（不读钥匙串、不建 provider）。
fn configured_model(configured: &ProviderPrefs, model_id: &str) -> Option<Model> {
    if !configured.models.iter().any(|id| id == model_id) {
        return None;
    }
    let limits = configured.model_config(model_id);
    if !limits.enabled {
        return None;
    }
    let display_name = limits
        .display_name
        .filter(|display| !display.trim().is_empty())
        .unwrap_or_else(|| model_id.to_string());
    Some(
        Model::new(
            ProviderId::new(configured.id.clone()),
            configured.name.clone(),
            model_id,
            display_name,
            ModelLimits::new(limits.context_window, limits.max_output_tokens),
        )
        .with_thinking_mode(limits.thinking_mode)
        .with_capabilities(ModelCapabilities {
            tools: limits.supports_tools,
            images: limits.supports_images,
            thinking: limits.supports_thinking,
        }),
    )
}

/// 首次 turn 前解析一次待定的钥匙串凭据（可能阻塞，但此时用户已主动发送）。
pub(super) fn resolve_pending_key(
    production: &mut Production,
    config: &mut NativeRuntimeConfig,
) -> bool {
    let Some(pending) = production.pending.clone() else {
        return false;
    };
    let key = production
        .keychain
        .load_secret(&provider_key_account(&pending.provider_id))
        .filter(|key| !key.is_empty());
    production.pending = None;
    let Some(key) = key else {
        // 失败不重试，避免每次发送都阻塞；生产环境不再回退到 Echo。
        production.model_setup = if production.allow_echo {
            ModelSetup::DemoEcho
        } else {
            ModelSetup::Unconfigured
        };
        config.provider = if production.allow_echo {
            Arc::new(EchoProvider::new(config.model.clone()))
        } else {
            Arc::new(UnconfiguredProvider::new(config.model.clone()))
        };
        return false;
    };
    let (provider, model_setup) = provider(
        &config.model,
        pending.protocol,
        Some(pending.base_url),
        Some(key),
        production.allow_echo,
    );
    production.model_setup = model_setup;
    config.provider = provider;
    true
}

pub(super) fn base_tools(
    production: &Production,
    config: &mut NativeRuntimeConfig,
    commands: &Weak<mpsc::UnboundedSender<Command>>,
    generation: u64,
    affinity_session_id: Option<String>,
) -> ToolRegistry {
    let workspace = config.context.workspace().to_path_buf();
    let actions: ActionSink = {
        let commands = commands.clone();
        let workspace = workspace.clone();
        Arc::new(move |action| {
            if let Some(sender) = commands.upgrade() {
                let _ = sender.unbounded_send(Command::AppAction {
                    generation,
                    workspace: workspace.clone(),
                    action,
                });
            }
        })
    };
    config.context = ToolContext::new(&workspace)
        .with_sandbox(SandboxPolicy::new(&workspace))
        .with_action_sink(actions);
    let runner: SubagentRunner = {
        let provider = config.provider.clone();
        let model = config.model.clone();
        let affinity_session_id = affinity_session_id
            .map(|id| id.trim().to_string())
            .filter(|id| !id.is_empty());
        Arc::new(move |request, events| {
            let provider = provider.clone();
            let model = model.clone();
            let workspace = workspace.clone();
            let affinity_session_id = affinity_session_id.clone();
            Box::pin(async move {
                run_subagent_with_affinity(
                    provider,
                    model,
                    request.task,
                    request.system_prompt,
                    workspace,
                    events,
                    affinity_session_id,
                )
                .await
                .map_err(|error| error.to_string())
            })
        })
    };
    let subagents: SubagentEventSink = {
        let commands = commands.clone();
        Arc::new(move |event| {
            let event = match event {
                SubagentEvent::Started { task } => AgentEvent::SubagentStarted { task },
                SubagentEvent::TextDelta { text } => AgentEvent::SubagentProgress { text },
                SubagentEvent::Finished { ok } => AgentEvent::SubagentFinished { ok },
            };
            if let Some(sender) = commands.upgrade() {
                let _ = sender.unbounded_send(Command::Subagent { generation, event });
            }
        })
    };
    ToolRegistry::with_agent_state(production.host.agent_state.clone())
        .with_app_actions()
        .with_subagent(runner, subagents)
}

pub(super) fn state(production: Option<&Production>) -> AgentState {
    production
        .map(|production| {
            production
                .host
                .agent_state
                .lock()
                .expect("native tool state")
                .clone()
        })
        .unwrap_or_default()
}

#[cfg(test)]
mod tests;
