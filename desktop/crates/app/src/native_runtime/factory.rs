use super::*;
use cgc_agent_core::{run_subagent, Agent, SelectedModel};
use cgc_agent_provider::{
    EchoProvider, ModelLimits, OpenAiCompatibleConfig, OpenAiCompatibleProvider, ProviderId,
    UnconfiguredProvider,
};
use cgc_agent_store::{provider_key_account, PrefsStore};
use cgc_agent_tools::{
    ActionSink, SandboxPolicy, SubagentEvent, SubagentEventSink, SubagentRunner,
};
use cgc_platform::session::KeychainStore;
use std::sync::Weak;

/// 启动时**不读钥匙串**：先发布快照让界面可用，首次 turn 前再解析（见 `resolve_pending_key`）。
/// 真机上钥匙串读取在无授权时会阻塞 8–11s，放在初始化路径会让窗口一直停在载入态。
#[derive(Clone, Debug)]
pub(super) struct PendingCredentials {
    pub provider_id: String,
    pub base_url: String,
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
    let active = prefs.active_provider();
    let provider_id = active
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
                    active.is_some_and(|provider| provider.id == selection.provider_id.as_str())
                })
                .map(|model| model.model_id.as_str().into())
        })
        .or_else(|| active.and_then(|provider| provider.primary_model().map(str::to_string)))
        .unwrap_or_else(|| "echo".into());
    let model_id = match active {
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
        .map(|provider| provider.model_config(&model_id))
        .unwrap_or_default();
    let model_available =
        model_config.enabled && active.is_none_or(|provider| provider.models.contains(&model_id));
    let name = std::env::var("CGC_AGENT_PROVIDER_NAME")
        .ok()
        .or_else(|| active.map(|provider| provider.name.clone()))
        .filter(|name| !name.is_empty())
        .unwrap_or_else(|| "OpenAI Compatible".into());
    let model = Model::new(
        ProviderId::new(provider_id),
        name,
        model_id.clone(),
        model_id,
        ModelLimits::new(model_config.context_window, model_config.max_output_tokens),
    );
    let base_url = std::env::var("CGC_AGENT_BASE_URL")
        .ok()
        .filter(|value| !value.is_empty())
        .or_else(|| active.map(|provider| provider.base_url.clone()));
    // 只读环境变量：钥匙串留到首次 turn（Production::pending）。
    let env_key = std::env::var("CGC_AGENT_API_KEY")
        .ok()
        .filter(|value| !value.is_empty());
    let active_has_key = active.is_some_and(|provider| provider.has_key);
    let pending = match (&env_key, &base_url) {
        (Some(_), _) => None,
        (None, Some(url)) if !url.is_empty() && active_has_key && model_available => {
            Some(PendingCredentials {
                provider_id: model.provider_id.as_str().to_string(),
                base_url: url.clone(),
            })
        }
        _ => None,
    };
    let (provider, mut model_setup) = if model_available {
        provider(&model, base_url, env_key, allow_echo)
    } else {
        provider(&model, None, None, false)
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
    Ok((
        agent,
        config,
        Production {
            host,
            providers: Arc::new(prefs.providers),
            data_root,
            keychain,
            allow_echo,
            model_setup,
            pending,
        },
    ))
}

fn provider(
    model: &Model,
    base_url: Option<String>,
    api_key: Option<String>,
    allow_echo: bool,
) -> (Arc<dyn Provider>, ModelSetup) {
    match (base_url, api_key) {
        (Some(url), Some(key)) if !url.is_empty() && !key.is_empty() => (
            Arc::new(OpenAiCompatibleProvider::new(OpenAiCompatibleConfig::new(
                url,
                key,
                vec![model.clone()],
            ))),
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
    if !configured.models.iter().any(|id| id == model_id)
        || !configured.model_config(model_id).enabled
    {
        return Err(NativeRuntimeError::Configuration(
            "模型不可用或已禁用".into(),
        ));
    }
    let limits = configured.model_config(model_id);
    let model = Model::new(
        ProviderId::new(configured.id.clone()),
        configured.name.clone(),
        model_id,
        model_id,
        ModelLimits::new(limits.context_window, limits.max_output_tokens),
    );
    let key = production
        .keychain
        .load_secret(&provider_key_account(&configured.id));
    let (provider, model_setup) = provider(
        &model,
        Some(configured.base_url.clone()),
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
    let configured = prefs.provider(selection.provider.as_str())?;
    let model = summary_model_for(configured, selection.model.as_str())?;
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
        Some(configured.base_url.clone()),
        Some(key),
        production.allow_echo,
    );
    (model_setup == ModelSetup::Configured).then_some((provider, model))
}

/// 只做「配置是否可用」的判定，便于单测（不读钥匙串、不建 provider）。
fn summary_model_for(configured: &ProviderPrefs, model_id: &str) -> Option<Model> {
    if !configured.models.iter().any(|id| id == model_id) {
        return None;
    }
    let limits = configured.model_config(model_id);
    if !limits.enabled {
        return None;
    }
    Some(Model::new(
        ProviderId::new(configured.id.clone()),
        configured.name.clone(),
        model_id,
        model_id,
        ModelLimits::new(limits.context_window, limits.max_output_tokens),
    ))
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
        Arc::new(move |request, events| {
            let provider = provider.clone();
            let model = model.clone();
            let workspace = workspace.clone();
            Box::pin(async move {
                run_subagent(
                    provider,
                    model,
                    request.task,
                    request.system_prompt,
                    workspace,
                    events,
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
