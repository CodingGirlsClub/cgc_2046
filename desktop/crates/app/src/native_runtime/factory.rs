use super::*;
use cgc_agent_core::{run_subagent, Agent, SelectedModel};
use cgc_agent_provider::{
    EchoProvider, ModelLimits, OpenAiCompatibleConfig, OpenAiCompatibleProvider, ProviderId,
};
use cgc_agent_store::{provider_key_account, PrefsStore};
use cgc_agent_tools::{
    ActionSink, SandboxPolicy, SubagentEvent, SubagentEventSink, SubagentRunner,
};
use cgc_platform::session::KeychainStore;
use std::sync::Weak;

pub(super) struct Production {
    pub host: NativePanelHost,
    pub providers: Arc<Vec<ProviderPrefs>>,
    pub data_root: PathBuf,
    pub keychain: KeychainStore,
    pub using_echo: bool,
}

pub(super) fn initialize(
    scope: &AgentScope,
    data_root: PathBuf,
    host: NativePanelHost,
) -> Result<(Agent, NativeRuntimeConfig, Production), NativeRuntimeError> {
    std::fs::create_dir_all(&scope.root)
        .map_err(|error| NativeRuntimeError::Storage(error.to_string()))?;
    let prefs = PrefsStore::new(data_root.join("agent_prefs.json")).load();
    let active = prefs.active_provider();
    let keychain = KeychainStore::from_env();
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
                .map(|model| model.model_id.as_str().into())
        })
        .or_else(|| active.and_then(|provider| provider.primary_model().map(str::to_string)))
        .unwrap_or_else(|| "echo".into());
    let model_id = match active {
        Some(provider) if !provider.model_config(&model_id).enabled => provider
            .models
            .iter()
            .find(|id| provider.model_config(id).enabled)
            .cloned()
            .unwrap_or(model_id),
        _ => model_id,
    };
    let model_config = active
        .map(|provider| provider.model_config(&model_id))
        .unwrap_or_default();
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
    let api_key = std::env::var("CGC_AGENT_API_KEY")
        .ok()
        .filter(|value| !value.is_empty())
        .or_else(|| {
            active.and_then(|provider| keychain.load_secret(&provider_key_account(&provider.id)))
        });
    let (provider, using_echo) = provider(&model, base_url, api_key);
    let agent = Agent::new(
        Thread::new(
            format!("native-{}", scope.key),
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
            using_echo,
        },
    ))
}

fn provider(
    model: &Model,
    base_url: Option<String>,
    api_key: Option<String>,
) -> (Arc<dyn Provider>, bool) {
    match (base_url, api_key) {
        (Some(url), Some(key)) if !url.is_empty() && !key.is_empty() => (
            Arc::new(OpenAiCompatibleProvider::new(OpenAiCompatibleConfig::new(
                url,
                key,
                vec![model.clone()],
            ))),
            false,
        ),
        _ => (Arc::new(EchoProvider::new(model.clone())), true),
    }
}

pub(super) fn select_model(
    production: &mut Production,
    provider_id: &str,
    model_id: &str,
) -> Result<(Arc<dyn Provider>, Model), NativeRuntimeError> {
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
    let (provider, using_echo) = provider(&model, Some(configured.base_url.clone()), key);
    production.using_echo = using_echo;
    let store = PrefsStore::new(production.data_root.join("agent_prefs.json"));
    let mut prefs = store.load();
    prefs.selected_provider = Some(configured.id.clone());
    prefs.selected_model = Some(SelectedModel::new(
        model.provider_id.clone(),
        model.id.clone(),
    ));
    store
        .save(&prefs)
        .map_err(|error| NativeRuntimeError::Storage(error.to_string()))?;
    Ok((provider, model))
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
