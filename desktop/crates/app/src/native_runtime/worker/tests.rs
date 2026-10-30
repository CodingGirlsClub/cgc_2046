use super::*;
use cgc_agent_provider::{EchoProvider, ModelLimits, ProviderId};
use cgc_agent_store::{provider_key_account, AgentPrefs, ModelPrefs, PrefsStore};
use cgc_platform::session::{KeychainStore, SecretBackend};
use futures::executor::block_on;
use std::sync::atomic::{AtomicBool, Ordering};

struct MemoryKeychain(AtomicBool);

impl SecretBackend for MemoryKeychain {
    fn set(&self, _account: &str, _secret: &str) -> std::io::Result<()> {
        self.0.store(true, Ordering::SeqCst);
        Ok(())
    }

    fn get(&self, _account: &str) -> std::io::Result<Option<String>> {
        Ok(self.0.load(Ordering::SeqCst).then(|| "test-key".into()))
    }

    fn delete(&self, _account: &str) -> std::io::Result<()> {
        self.0.store(false, Ordering::SeqCst);
        Ok(())
    }
}

fn configured_owner(root: &std::path::Path) -> Owner {
    let model = Model::new(
        ProviderId::new("test"),
        "Test",
        "m1",
        "m1",
        ModelLimits::new(8_000, 1_000),
    );
    let mut thread = Thread::new(
        "refresh-thread",
        cgc_agent_core::SelectedModel::new(model.provider_id.clone(), model.id.clone()),
    );
    thread.push_user("preserve this conversation");
    let mut owner = Owner::initialize(
        Initialization::Explicit {
            thread: Box::new(thread),
            system_prompt: None,
            config: Box::new(NativeRuntimeConfig {
                provider: Arc::new(EchoProvider::new(model.clone())),
                model,
                registry: Arc::new(ToolRegistry::new()),
                context: ToolContext::new(root),
                context_size: 8_000,
                auto_approve: false,
            }),
            store: None,
        },
        Weak::new(),
        Arc::new(std::sync::Mutex::new(None)),
    )
    .expect("initialize owner");
    owner.production = Some(factory::Production {
        host: NativePanelHost::new(Arc::new(std::sync::Mutex::new(AgentState::default())), None),
        providers: Arc::new(Vec::new()),
        data_root: root.to_path_buf(),
        keychain: KeychainStore::new(Arc::new(MemoryKeychain(AtomicBool::new(true)))),
        allow_echo: false,
        model_setup: ModelSetup::Configured,
        pending: None,
    });
    owner.rebuild_tools();
    owner
}

fn refresh(owner: &mut Owner) -> Arc<NativeRuntimeSnapshot> {
    let (reply, result) = oneshot::channel();
    owner.command(Command::RefreshProviders(reply));
    block_on(result)
        .expect("refresh reply")
        .expect("refresh provider settings")
}

#[test]
fn no_enabled_models_unconfigures_refresh_and_allows_reconfiguration() {
    for empty_catalog in [false, true] {
        let root = std::env::temp_dir().join(format!(
            "cgc-refresh-disabled-{}-{empty_catalog}",
            std::process::id()
        ));
        std::fs::create_dir_all(&root).unwrap();
        let mut owner = configured_owner(&root);
        let original = owner.snapshot();
        assert_eq!(original.model_setup, ModelSetup::Configured);
        assert!(block_on(
            owner
                .config
                .provider
                .stream(&owner.config.model, cgc_agent_provider::Request::default(),)
        )
        .is_ok());
        let mut prefs = AgentPrefs {
            selected_provider: Some("test".into()),
            selected_model: Some(original.thread.model.clone()),
            providers: vec![ProviderPrefs {
                id: "test".into(),
                name: "Test".into(),
                base_url: "https://example.invalid/v1".into(),
                models: if empty_catalog {
                    Vec::new()
                } else {
                    vec!["m1".into()]
                },
                model_params: vec![ModelPrefs {
                    enabled: false,
                    ..ModelPrefs::new("m1")
                }],
                has_key: true,
                builtin: false,
            }],
            ..AgentPrefs::default()
        };
        let store = PrefsStore::new(root.join("agent_prefs.json"));
        store.save(&prefs).unwrap();

        let snapshot = refresh(&mut owner);
        assert_eq!(snapshot.model_setup, ModelSetup::Unconfigured);
        assert!(!snapshot.model_setup.allows_send());
        assert_eq!(snapshot.thread.entries, original.thread.entries);
        assert!(owner.production.as_ref().unwrap().pending.is_none());
        assert!(
            block_on(
                owner
                    .config
                    .provider
                    .stream(&owner.config.model, cgc_agent_provider::Request::default(),)
            )
            .is_err(),
            "disabled models must not keep the previous live provider"
        );

        owner
            .production
            .as_ref()
            .unwrap()
            .keychain
            .clear_secret(&provider_key_account("test"))
            .unwrap();
        prefs.providers[0].has_key = false;
        store.save(&prefs).unwrap();
        assert_eq!(refresh(&mut owner).model_setup, ModelSetup::Unconfigured);

        prefs.providers[0].models.push("m2".into());
        prefs.providers[0].model_params.push(ModelPrefs::new("m2"));
        prefs.providers[0].has_key = true;
        owner
            .production
            .as_ref()
            .unwrap()
            .keychain
            .save_secret(&provider_key_account("test"), "replacement-key")
            .unwrap();
        store.save(&prefs).unwrap();
        let restored = refresh(&mut owner);
        assert_eq!(restored.model_setup, ModelSetup::Configured);
        assert_eq!(restored.model.id.as_str(), "m2");
        assert_eq!(restored.thread.entries, original.thread.entries);
        drop(owner);
        std::fs::remove_dir_all(root).unwrap();
    }
}
