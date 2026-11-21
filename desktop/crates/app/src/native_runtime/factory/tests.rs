use super::*;
use std::io;
use std::sync::atomic::{AtomicUsize, Ordering};

/// 记录调用次数；`get` 若被调用就说明初始化路径仍在读钥匙串。
struct RecordingBackend {
    gets: Arc<AtomicUsize>,
}

impl cgc_platform::session::SecretBackend for RecordingBackend {
    fn set(&self, _account: &str, _secret: &str) -> io::Result<()> {
        Ok(())
    }
    fn get(&self, _account: &str) -> io::Result<Option<String>> {
        self.gets.fetch_add(1, Ordering::SeqCst);
        Ok(Some("sk-test".to_string()))
    }
    fn delete(&self, _account: &str) -> io::Result<()> {
        Ok(())
    }
}

fn temp_root(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("cgc-factory-{}-{tag}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn host() -> NativePanelHost {
    NativePanelHost::new(
        Arc::new(std::sync::Mutex::new(cgc_agent_tools::AgentState::default())),
        None,
    )
}

/// 关键回归：初始化不得读取钥匙串（真机上未授权时会阻塞 8–11s）。
#[test]
fn initialize_never_touches_the_keychain() {
    let root = temp_root("init");
    let gets = Arc::new(AtomicUsize::new(0));
    let keychain = KeychainStore::new(Arc::new(RecordingBackend {
        gets: Arc::clone(&gets),
    }));
    let scope = AgentScope {
        key: "test".into(),
        root: root.join("workspace"),
    };
    let (_agent, _config, _production) =
        initialize_with_keychain(&scope, root.clone(), host(), keychain, false).expect("init");
    assert_eq!(gets.load(Ordering::SeqCst), 0, "启动路径不得读钥匙串");
    let _ = std::fs::remove_dir_all(root);
}

/// 生产环境没有 Provider 时必须进入未配置状态，且不能回显假回复。
#[test]
fn production_without_provider_is_unconfigured() {
    let root = temp_root("prod-unconfigured");
    let keychain = KeychainStore::new(Arc::new(RecordingBackend {
        gets: Arc::new(AtomicUsize::new(0)),
    }));
    let scope = AgentScope {
        key: "test".into(),
        root: root.join("workspace"),
    };
    let (_agent, config, production) =
        initialize_with_keychain(&scope, root.clone(), host(), keychain, false).expect("init");
    assert_eq!(production.model_setup, ModelSetup::Unconfigured);
    let result = futures::executor::block_on(
        config
            .provider
            .stream(&config.model, cgc_agent_provider::Request::default()),
    );
    let error = match result {
        Ok(_) => panic!("生产环境未配置 Provider 时不得产生 Echo 流"),
        Err(error) => error,
    };
    assert!(error.to_string().contains("未配置模型"));
    let _ = std::fs::remove_dir_all(root);
}

/// demo/dev 环境没有 Provider 时仍保留 Echo，供离线 UI 回归。
#[test]
fn demo_without_provider_keeps_echo() {
    let root = temp_root("demo-echo");
    let keychain = KeychainStore::new(Arc::new(RecordingBackend {
        gets: Arc::new(AtomicUsize::new(0)),
    }));
    let scope = AgentScope {
        key: "test".into(),
        root: root.join("workspace"),
    };
    let (_agent, config, production) =
        initialize_with_keychain(&scope, root.clone(), host(), keychain, true).expect("init");
    assert_eq!(production.model_setup, ModelSetup::DemoEcho);
    assert!(
        futures::executor::block_on(
            config
                .provider
                .stream(&config.model, cgc_agent_provider::Request::default()),
        )
        .is_ok(),
        "demo/dev 应保留 Echo 流"
    );
    let _ = std::fs::remove_dir_all(root);
}

/// 有 Provider 记录但没有 Key 时，启动必须进入未配置状态，而不是 Pending。
#[test]
fn provider_without_key_is_unconfigured_at_startup() {
    let root = temp_root("provider-no-key");
    let seed = summary_production(&root);
    prefs_with_provider(&seed, false, true);
    let scope = AgentScope {
        key: "test".into(),
        root: root.join("workspace"),
    };
    let keychain = KeychainStore::new(Arc::new(RecordingBackend {
        gets: Arc::new(AtomicUsize::new(0)),
    }));
    let (_agent, _config, production) =
        initialize_with_keychain(&scope, root.clone(), host(), keychain, false).expect("init");
    assert_eq!(production.model_setup, ModelSetup::Unconfigured);
    assert!(production.pending.is_none());
    let _ = std::fs::remove_dir_all(root);
}

fn prefs_with_provider(production: &Production, has_key: bool, model_enabled: bool) {
    let prefs = cgc_agent_store::AgentPrefs {
        providers: vec![ProviderPrefs {
            id: "deepseek".to_string(),
            name: "DeepSeek".to_string(),
            base_url: "https://example.invalid".to_string(),
            anthropic_url: None,
            responses_url: None,
            models_url: None,
            models: vec!["chat".to_string(), "flash".to_string()],
            has_key,
            enabled: true,
            model_params: vec![
                cgc_agent_store::ModelPrefs::new("chat"),
                cgc_agent_store::ModelPrefs {
                    enabled: model_enabled,
                    ..cgc_agent_store::ModelPrefs::new("flash")
                },
            ],
            builtin: false,
            protocol: ProviderProtocol::OpenAiCompatible,
            ..Default::default()
        }],
        ..Default::default()
    };
    PrefsStore::new(production.data_root.join("agent_prefs.json"))
        .save(&prefs)
        .expect("save prefs");
}

fn summary_production(root: &std::path::Path) -> Production {
    Production {
        host: host(),
        providers: Arc::new(Vec::new()),
        data_root: root.to_path_buf(),
        keychain: KeychainStore::new(Arc::new(RecordingBackend {
            gets: Arc::new(AtomicUsize::new(0)),
        })),
        allow_echo: false,
        model_setup: ModelSetup::Configured,
        pending: None,
    }
}

fn settings_with_summary(provider: &str, model: &str) -> crate::user_settings::UserSettings {
    serde_json::from_str(&format!(
        r#"{{"agent":{{"thread_summary_model":{{"provider":"{provider}","model":"{model}"}}}}}}"#
    ))
    .expect("settings")
}

#[test]
fn summary_title_model_uses_the_configured_model() {
    let root = temp_root("summary-model");
    let production = summary_production(&root);
    prefs_with_provider(&production, true, true);
    let settings = settings_with_summary("deepseek", "flash");
    let (_, model) = summary_title_model(&production, &settings).expect("summary model");
    assert_eq!(model.provider_id.as_str(), "deepseek");
    assert_eq!(model.id.as_str(), "flash");
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn summary_title_model_falls_back_when_unconfigured_unusable_or_key_missing() {
    let root = temp_root("summary-fallback");
    let production = summary_production(&root);
    prefs_with_provider(&production, true, true);
    assert!(
        summary_title_model(&production, &crate::user_settings::UserSettings::default()).is_none(),
        "设置文件未配置时回退"
    );
    assert!(
        summary_title_model(&production, &settings_with_summary("deepseek", "missing")).is_none(),
        "模型不在 provider 列表时回退"
    );

    prefs_with_provider(&production, false, true);
    assert!(
        summary_title_model(&production, &settings_with_summary("deepseek", "flash")).is_none(),
        "没保存 key 时回退"
    );

    prefs_with_provider(&production, true, false);
    assert!(
        summary_title_model(&production, &settings_with_summary("deepseek", "flash")).is_none(),
        "模型被禁用时回退"
    );
    let _ = std::fs::remove_dir_all(root);
}

/// 待定凭据只解析一次；解析后清空，避免每次发送都阻塞。
#[test]
fn pending_credentials_resolve_once() {
    let root = temp_root("pending");
    let gets = Arc::new(AtomicUsize::new(0));
    let keychain = KeychainStore::new(Arc::new(RecordingBackend {
        gets: Arc::clone(&gets),
    }));
    let mut production = Production {
        host: host(),
        providers: Arc::new(Vec::new()),
        data_root: root.to_path_buf(),
        keychain,
        allow_echo: false,
        model_setup: ModelSetup::PendingCredentials,
        pending: Some(PendingCredentials {
            provider_id: "deepseek".into(),
            base_url: "https://example.invalid".into(),
            protocol: ProviderProtocol::OpenAiCompatible,
        }),
    };
    let model = Model::new(
        ProviderId::new("deepseek"),
        "DeepSeek",
        "m1",
        "m1",
        ModelLimits::new(8_000, 1_000),
    );
    let mut config = NativeRuntimeConfig {
        provider: Arc::new(EchoProvider::new(model.clone())),
        model,
        registry: Arc::new(ToolRegistry::new()),
        context: ToolContext::new(&root),
        context_size: 8_000,
        auto_approve: false,
    };

    assert!(
        resolve_pending_key(&mut production, &mut config),
        "首次应解析成功"
    );
    assert_eq!(gets.load(Ordering::SeqCst), 1);
    assert!(production.pending.is_none());
    assert!(
        !resolve_pending_key(&mut production, &mut config),
        "再次调用不再解析"
    );
    assert_eq!(gets.load(Ordering::SeqCst), 1);
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn startup_without_enabled_models_stays_unconfigured() {
    for allow_echo in [false, true] {
        for empty_catalog in [false, true] {
            let root = temp_root(&format!("disabled-{allow_echo}-{empty_catalog}"));
            let seed = summary_production(&root);
            prefs_with_provider(&seed, true, false);
            let store = PrefsStore::new(root.join("agent_prefs.json"));
            let mut prefs = store.load();
            for model in &mut prefs.providers[0].model_params {
                model.enabled = false;
            }
            if empty_catalog {
                prefs.providers[0].models.clear();
            }
            store.save(&prefs).unwrap();
            let scope = AgentScope {
                key: "test".into(),
                root: root.join("workspace"),
            };
            let keychain = KeychainStore::new(Arc::new(RecordingBackend {
                gets: Arc::new(AtomicUsize::new(0)),
            }));

            let (_agent, config, production) =
                initialize_with_keychain(&scope, root.clone(), host(), keychain, allow_echo)
                    .expect("initialize disabled provider");

            assert_eq!(production.model_setup, ModelSetup::Unconfigured);
            assert!(production.pending.is_none());
            assert!(
                futures::executor::block_on(
                    config
                        .provider
                        .stream(&config.model, cgc_agent_provider::Request::default(),)
                )
                .is_err(),
                "disabled models must not be used after restart"
            );
            let _ = std::fs::remove_dir_all(root);
        }
    }
}

#[test]
fn endpoint_url_follows_protocol() {
    let mut provider = cgc_agent_store::ProviderPrefs {
        base_url: "https://openai.example/v1".into(),
        anthropic_url: Some("https://anthropic.example".into()),
        ..Default::default()
    };
    provider.protocol = cgc_agent_provider::ProviderProtocol::OpenAiCompatible;
    assert_eq!(super::endpoint_url(&provider), "https://openai.example/v1");
    provider.protocol = cgc_agent_provider::ProviderProtocol::AnthropicCompatible;
    assert_eq!(super::endpoint_url(&provider), "https://anthropic.example");
    provider.anthropic_url = None;
    assert_eq!(super::endpoint_url(&provider), "https://openai.example/v1");
}

fn sample_gateway_models() -> Vec<cgc_platform::gateway::GatewayModel> {
    vec![
        cgc_platform::gateway::GatewayModel {
            model_id: "deepseek-chat".into(),
            display_name: "DeepSeek Chat (CGC)".into(),
            context_window: 128_000,
            max_output_tokens: 8_192,
            supports_thinking: false,
            supports_tools: true,
            supports_images: false,
            reasoning_efforts: Vec::new(),
            input_price_mc: 3_000_000,
            cache_hit_price_mc: 300_000,
            output_price_mc: 4_500_000,
        },
        cgc_platform::gateway::GatewayModel {
            model_id: "claude-sonnet-4-5".into(),
            display_name: "Claude Sonnet 4.5 (CGC)".into(),
            context_window: 200_000,
            max_output_tokens: 16_384,
            supports_thinking: true,
            supports_tools: true,
            supports_images: true,
            reasoning_efforts: vec!["low".into(), "high".into()],
            input_price_mc: 30_000_000,
            cache_hit_price_mc: 3_000_000,
            output_price_mc: 150_000_000,
        },
    ]
}

fn sample_managed_provider(saved: Option<&ProviderPrefs>) -> Option<ProviderPrefs> {
    super::cgc_cloud_provider_from_models(&sample_gateway_models(), saved)
}

#[test]
fn login_defaults_to_managed_provider_without_byok() {
    let prefs = AgentPrefs::default();
    let (managed, active) = resolve_active_provider(&prefs, sample_managed_provider(None));
    assert!(managed);
    let active = active.expect("managed provider");
    assert_eq!(active.id, CGC_CLOUD_PROVIDER_ID);
    assert_eq!(active.models, vec!["deepseek-chat", "claude-sonnet-4-5"]);
    assert_eq!(
        active.model_config("deepseek-chat").display_name.as_deref(),
        Some("DeepSeek Chat (CGC)")
    );
}

#[test]
fn login_keeps_configured_byok_provider_while_coexisting_with_cgc_cloud_in_picker() {
    let mut prefs = AgentPrefs::default();
    let byok = ProviderPrefs {
        id: "deepseek".into(),
        name: "DeepSeek".into(),
        models: vec!["deepseek-chat".into()],
        has_key: true,
        enabled: true,
        ..Default::default()
    };
    prefs.providers.push(byok);
    let managed_provider = sample_managed_provider(prefs.provider(CGC_CLOUD_PROVIDER_ID));
    let (managed, active) = resolve_active_provider(&prefs, managed_provider.clone());
    assert!(!managed);
    assert_eq!(active.expect("BYOK provider").id, "deepseek");

    let available = super::merge_available_providers(&prefs.providers, managed_provider);
    let ids: Vec<&str> = available.iter().map(|p| p.id.as_str()).collect();
    assert_eq!(ids, vec![CGC_CLOUD_PROVIDER_ID, "deepseek"]);
}

#[test]
fn signed_out_strips_stale_saved_cgc_cloud_from_available_providers() {
    let mut prefs = AgentPrefs::default();
    prefs.upsert_provider(cgc_cloud_provider_with_models(vec![ModelPrefs::new(
        "stale-model",
    )]));
    prefs.upsert_provider(ProviderPrefs {
        id: "deepseek".into(),
        name: "DeepSeek".into(),
        has_key: true,
        enabled: true,
        ..Default::default()
    });
    let available = super::merge_available_providers(&prefs.providers, None);
    let ids: Vec<&str> = available.iter().map(|p| p.id.as_str()).collect();
    assert_eq!(ids, vec!["deepseek"]);
}

#[test]
fn removed_selected_gateway_model_falls_back_to_next_enabled_model() {
    let mut active = sample_managed_provider(None).expect("managed");
    if let Some(removed) = active
        .model_params
        .iter_mut()
        .find(|m| m.id == "deepseek-chat")
    {
        removed.enabled = false;
    }
    let next_model = active
        .models
        .iter()
        .find(|id| active.model_config(id).enabled)
        .cloned();
    assert_eq!(next_model.as_deref(), Some("claude-sonnet-4-5"));
}

#[test]
fn login_requires_a_key_before_byok_wins() {
    let mut prefs = AgentPrefs::default();
    prefs.providers.push(ProviderPrefs {
        id: "deepseek".into(),
        name: "DeepSeek".into(),
        has_key: false,
        enabled: true,
        ..Default::default()
    });
    let (managed, active) = resolve_active_provider(&prefs, sample_managed_provider(None));
    assert!(managed);
    assert_eq!(active.expect("managed provider").id, CGC_CLOUD_PROVIDER_ID);
}

#[test]
fn login_preserves_saved_managed_model_enablement() {
    let mut prefs = AgentPrefs::default();
    let mut managed = cgc_cloud_provider_with_models(vec![ModelPrefs::new("deepseek-chat")]);
    if let Some(model) = managed
        .model_params
        .iter_mut()
        .find(|model| model.id == "deepseek-chat")
    {
        model.enabled = false;
    }
    prefs.upsert_provider(managed);
    prefs.selected_provider = Some(CGC_CLOUD_PROVIDER_ID.to_string());

    let managed_provider = sample_managed_provider(prefs.provider(CGC_CLOUD_PROVIDER_ID));
    let (is_managed, active) = resolve_active_provider(&prefs, managed_provider);

    assert!(is_managed);
    let active = active.expect("saved managed provider");
    assert!(!active.model_config("deepseek-chat").enabled);
}

#[test]
fn explicitly_disabled_managed_provider_is_not_recreated() {
    let mut prefs = AgentPrefs::default();
    let mut managed = cgc_cloud_provider();
    managed.enabled = false;
    prefs.upsert_provider(managed);
    prefs.selected_provider = Some(CGC_CLOUD_PROVIDER_ID.to_string());

    let managed_provider = sample_managed_provider(prefs.provider(CGC_CLOUD_PROVIDER_ID));
    let (is_managed, active) = resolve_active_provider(&prefs, managed_provider);

    assert!(!is_managed);
    assert!(
        active.is_none(),
        "disabled managed provider must stay disabled"
    );
}

#[test]
fn env_byok_credentials_override_managed_default_when_signed_in() {
    let prefs = AgentPrefs::default();
    assert!(super::has_env_byok(
        &prefs,
        Some("https://byok.example/v1"),
        Some("sk-env-key")
    ));
    let (managed, active) =
        super::resolve_active_provider_with_env(&prefs, sample_managed_provider(None), true);
    assert!(!managed);
    assert!(active.is_none());

    let mut prefs_with_byok = AgentPrefs::default();
    prefs_with_byok.providers.push(ProviderPrefs {
        id: "deepseek".into(),
        name: "DeepSeek".into(),
        has_key: false,
        enabled: true,
        ..Default::default()
    });
    assert!(super::has_env_byok(
        &prefs_with_byok,
        None,
        Some("sk-env-key")
    ));
    let (managed, active) = super::resolve_active_provider_with_env(
        &prefs_with_byok,
        sample_managed_provider(None),
        true,
    );
    assert!(!managed);
    assert_eq!(active.expect("BYOK provider").id, "deepseek");
}
