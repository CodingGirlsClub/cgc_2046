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
fn new_conversations_preserve_history_and_checkpoints() {
    for scoped in [false, true] {
        let root =
            std::env::temp_dir().join(format!("cgc-new-thread-{}-{scoped}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        let mut owner = configured_owner(&root);
        owner.store = Some(SessionStore::open_in_memory().unwrap());
        if scoped {
            owner.scope = Some(Arc::new(AgentScope {
                key: "assistant-test".into(),
                root: root.clone(),
            }));
        }
        owner.persist();
        let original = owner.frozen.clone();
        let checkpoint = Checkpoint {
            thread_id: original.id.clone(),
            seq: 1,
            ref_name: format!("refs/cgc/checkpoints/{}/1", original.id),
            sha: "test-sha".into(),
            base_head: None,
        };
        owner
            .store
            .as_mut()
            .unwrap()
            .save_checkpoint(&checkpoint, 1, 1)
            .unwrap();
        owner.reload_checkpoints();
        let mut ids = vec![original.id.clone()];
        for _ in 0..2 {
            let (reply, result) = oneshot::channel();
            owner.command(Command::New(reply));
            let snapshot = block_on(result).unwrap().unwrap();
            assert!(
                !ids.contains(&snapshot.thread.id),
                "new conversations need independent identities"
            );
            ids.push(snapshot.thread.id.clone());
            assert!(snapshot.thread.entries.is_empty());
        }
        let store = owner.store.as_ref().unwrap();
        assert_eq!(
            store.load_thread(&original.id).unwrap().unwrap().entries,
            original.entries
        );
        assert_eq!(
            store.list_checkpoints(&original.id).unwrap()[0].state,
            "active"
        );
        assert_eq!(store.list_threads(10).unwrap().len(), 3);
        std::fs::remove_dir_all(root).unwrap();
    }
}

#[test]
fn scope_restore_keeps_legacy_history_and_new_current_selection_across_model_changes() {
    let scope = AgentScope {
        key: "assistant-test".into(),
        root: std::env::temp_dir().join("cgc-scope-restore"),
    };
    let mut store = SessionStore::open_in_memory().unwrap();
    let selected = cgc_agent_core::SelectedModel::new(
        ProviderId::new("test"),
        cgc_agent_provider::ModelId::new("m1"),
    );
    let mut legacy = Thread::new("native-assistant-test", selected.clone());
    legacy.push_user("preserved legacy course context");
    store.save_thread(&legacy).unwrap();
    let restored = restore_scope_thread(Some(&mut store), &scope, selected.clone()).unwrap();
    assert_eq!(restored, legacy);
    let empty = Thread::new(fresh_thread_id(), selected.clone());
    store
        .activate_scope_thread(&scope_storage_key(&scope), &empty)
        .unwrap();
    store.save_thread(&legacy).unwrap();
    let changed_model = cgc_agent_core::SelectedModel::new(
        ProviderId::new("test"),
        cgc_agent_provider::ModelId::new("m2"),
    );
    let restored = restore_scope_thread(Some(&mut store), &scope, changed_model.clone()).unwrap();
    assert_eq!(restored.id, empty.id);
    assert!(restored.entries.is_empty());
    store
        .activate_scope_thread(&scope_storage_key(&scope), &legacy)
        .unwrap();
    let restored = restore_scope_thread(Some(&mut store), &scope, changed_model).unwrap();
    assert_eq!(restored.entries, legacy.entries);
    assert_eq!(restored.id, legacy.id);
}

#[test]
fn stale_rewind_cannot_truncate_a_new_conversation() {
    let root = std::env::temp_dir().join(format!("cgc-stale-rewind-{}", std::process::id()));
    std::fs::create_dir_all(&root).unwrap();
    let mut owner = configured_owner(&root);
    let original_id = owner.frozen.id.clone();
    let (reply, result) = oneshot::channel();
    owner.command(Command::New(reply));
    block_on(result).unwrap().unwrap();
    owner
        .agent
        .as_mut()
        .unwrap()
        .thread_mut()
        .push_user("new thread content");
    owner.freeze();
    let before = owner.frozen.clone();
    let (reply, result) = oneshot::channel();
    owner.command(Command::Rewind {
        thread_id: Some(original_id),
        ordinal: 1,
        restore_files: false,
        reply,
    });
    assert_eq!(
        block_on(result).unwrap().err(),
        Some(NativeRuntimeError::StaleConnection)
    );
    assert_eq!(owner.frozen.entries, before.entries);
    std::fs::remove_dir_all(root).unwrap();
}

#[cfg(unix)]
#[test]
fn scope_identity_accepts_non_unicode_workspace_paths_without_collisions() {
    use std::{ffi::OsString, os::unix::ffi::OsStringExt};
    let first = AgentScope {
        key: "env-workspace".into(),
        root: PathBuf::from(OsString::from_vec(vec![b'/', 0x80])),
    };
    let second = AgentScope {
        key: first.key.clone(),
        root: PathBuf::from(OsString::from_vec(vec![b'/', 0x81])),
    };
    assert_ne!(scope_storage_key(&first), scope_storage_key(&second));
}

#[test]
fn model_switch_and_history_open_preserve_contents_and_restore_selection() {
    let root = std::env::temp_dir().join(format!("cgc-model-history-{}", std::process::id()));
    std::fs::create_dir_all(&root).unwrap();
    let mut owner = configured_owner(&root);
    owner.store = Some(SessionStore::open_in_memory().unwrap());
    owner.scope = Some(Arc::new(AgentScope {
        key: "assistant-test".into(),
        root: root.clone(),
    }));
    owner.production.as_mut().unwrap().providers = Arc::new(vec![ProviderPrefs {
        id: "test".into(),
        name: "Test".into(),
        base_url: "https://example.invalid".into(),
        models: vec!["m1".into(), "m2".into()],
        model_params: Vec::new(),
        has_key: true,
        builtin: false,
    }]);
    owner.persist();
    let original = owner.frozen.clone();
    let (reply, result) = oneshot::channel();
    owner.command(Command::SelectModel {
        provider: "test".into(),
        model: "m2".into(),
        reply,
    });
    let switched = block_on(result).unwrap().unwrap();
    assert_eq!(switched.thread.id, original.id);
    assert_eq!(switched.thread.entries, original.entries);
    assert_eq!(switched.thread.model.model_id.as_str(), "m2");
    let (reply, result) = oneshot::channel();
    owner.command(Command::New(reply));
    block_on(result).unwrap().unwrap();
    owner
        .store
        .as_mut()
        .unwrap()
        .save_thread(&original)
        .unwrap();
    let (reply, result) = oneshot::channel();
    owner.command(Command::Open(original.id.clone(), reply));
    let opened = block_on(result).unwrap().unwrap();
    assert_eq!(opened.thread.entries, original.entries);
    assert_eq!(opened.thread.model, original.model);
    assert_eq!(
        owner
            .store
            .as_ref()
            .unwrap()
            .load_scope_thread(&scope_storage_key(owner.scope.as_ref().unwrap()))
            .unwrap()
            .unwrap()
            .id,
        original.id
    );
    assert_eq!(
        PrefsStore::new(root.join("agent_prefs.json"))
            .load()
            .selected_model,
        Some(original.model.clone())
    );
    std::fs::remove_dir_all(root).unwrap();
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
