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

/// 视图首帧读 `latest` 镜像；镜像若只在 Subscribe 时写，调用方拿到 `inspect()` 结果后
/// 立刻构造视图仍可能读到 `None`（依赖 owner 线程调度，见 #1246）。构建快照即发布。
#[test]
fn inspect_publishes_the_latest_snapshot() {
    let root = std::env::temp_dir().join("cgc-inspect-publishes-latest");
    let mut owner = configured_owner(&root);
    let (reply, result) = oneshot::channel();
    owner.command(Command::Inspect(reply));
    let snapshot = block_on(result)
        .expect("inspect reply")
        .expect("inspect snapshot");
    let latest = owner
        .latest
        .lock()
        .expect("latest slot")
        .clone()
        .expect("inspect 必须把快照写进 latest 镜像");
    assert!(
        Arc::ptr_eq(&latest, &snapshot),
        "latest 必须是 inspect 返回的同一份快照"
    );
}

#[test]
fn cancelled_turn_does_not_replay_unconsumed_context_steers_in_the_next_turn() {
    use cgc_agent_core::{AutoApprover, NoopObserver};
    use cgc_agent_host::acp_server::CancelSwitch;
    let mut owner = configured_owner(&std::env::temp_dir());
    owner.production = None;
    owner
        .agent
        .as_mut()
        .unwrap()
        .set_thread_title(Some("Existing title".into()));
    let turn = |prompt: &str| NativeTurn {
        session_id: "session".into(),
        prompt: prompt.into(),
        observer: Box::new(NoopObserver),
        approver: Arc::new(AutoApprover),
        cancel: CancelSwitch::new(),
    };
    let (reply, result) = oneshot::channel();
    owner.start_turn(
        owner.generation,
        owner.frozen.id.clone(),
        turn("first question"),
        reply,
    );
    owner
        .active
        .as_ref()
        .unwrap()
        .steer
        .send(cgc_agent_core::session::SteerMessage {
            prompt: "stale page content".into(),
            display: "stale question".into(),
            draft: None,
        })
        .unwrap();
    owner.active.as_ref().unwrap().cancel.cancel();
    let job = block_on(owner.jobs.next()).unwrap();
    owner.completed(job);
    assert!(matches!(
        block_on(result).unwrap(),
        Err(AgentError::Cancelled)
    ));
    let (reply, result) = oneshot::channel();
    owner.start_turn(
        owner.generation,
        owner.frozen.id.clone(),
        turn("next question"),
        reply,
    );
    let job = block_on(owner.jobs.next()).unwrap();
    owner.completed(job);
    block_on(result).unwrap().unwrap();
    let users = owner
        .frozen
        .entries
        .iter()
        .filter_map(|entry| match entry {
            cgc_agent_core::Entry::User { text, .. } => Some(text.as_str()),
            _ => None,
        })
        .collect::<Vec<_>>();
    assert!(users.contains(&"next question"));
    assert!(!users.contains(&"stale page content"));
}

#[test]
fn retry_after_consumed_steer_uses_its_saved_selection_and_preserves_images() {
    use crate::{
        composer_context::ComposerContext,
        conversation_session::ConversationSession,
        page_context::{ConversationScope, PageBody, PageContext, PageContextState},
    };
    use cgc_agent_core::{AutoApprover, NoopObserver};
    use cgc_agent_host::acp_server::CancelSwitch;
    use cgc_agent_provider::{CompletionEvent, FakeProvider, ProviderError, StopReason};
    use gpui_kit::component::input::InputContent;

    let root = std::env::temp_dir();
    let mut owner = configured_owner(&root);
    owner.production = None;
    owner
        .agent
        .as_mut()
        .unwrap()
        .set_thread_title(Some("Existing title".into()));
    let provider = Arc::new(FakeProvider::new(
        ProviderId::new("test"),
        "Test",
        vec![owner.config.model.clone()],
    ));
    provider.push_script(vec![
        Ok(CompletionEvent::Text("partial answer".into())),
        Ok(CompletionEvent::Stop(StopReason::EndTurn)),
    ]);
    provider.push_script(vec![Err(ProviderError::InvalidResponse(
        "failed after steer".into(),
    ))]);
    owner.config.provider = provider.clone();
    let state = PageContextState::default();
    let scope = ConversationScope::new(owner.frozen.id.clone(), "native");
    let page = PageContext {
        workspace_id: None,
        tab_id: "tab-B".into(),
        route: "/courses/B/learn".into(),
        title: "Course B".into(),
        version: "v1".into(),
        body: PageBody::Ready("full body B".into()),
        course: None,
    };
    let mut composer = ComposerContext::default();
    let token = composer.add_selection(page, "selected task B".into());
    let input = InputContent::new(format!("{}explain B", token.text()))
        .with_token(0..token.text().len(), token)
        .unwrap();
    let (draft, prompt, _) = composer.freeze(&input, None, &root, &state, scope.clone());
    let mut session = ConversationSession::native();
    let first = session.submission(
        "question A".into(),
        "question A".into(),
        None,
        Vec::new(),
        false,
    );
    session.accepted(first);
    owner.prepared = Some(PreparedNativeTurn {
        thread_id: owner.frozen.id.clone(),
        generation: owner.generation,
        display: "question A".into(),
        draft: None,
        images: Vec::new(),
        retry: false,
    });
    let (reply, result) = oneshot::channel();
    owner.start_turn(
        owner.generation,
        owner.frozen.id.clone(),
        NativeTurn {
            session_id: "session".into(),
            prompt: "question A".into(),
            observer: Box::new(NoopObserver),
            approver: Arc::new(AutoApprover),
            cancel: CancelSwitch::new(),
        },
        reply,
    );
    let (reply, steered) = oneshot::channel();
    owner.command(Command::Steer(
        cgc_agent_core::session::SteerMessage {
            prompt,
            display: draft.text.clone(),
            draft: Some(serde_json::to_value(&draft).unwrap()),
        },
        reply,
    ));
    block_on(steered).unwrap().unwrap();
    let job = block_on(owner.jobs.next()).unwrap();
    owner.completed(job);
    assert!(block_on(result).unwrap().is_err());
    session.ingest(
        session.generation,
        &cgc_platform::acp::connection::HostEvent::UserMessage(draft.text.clone()),
    );
    session.ingest(
        session.generation,
        &cgc_platform::acp::connection::HostEvent::Error {
            message: "failed after steer".into(),
        },
    );
    assert!(session.sync_native_drafts(&owner.frozen, 1));
    assert_eq!(session.thread.user_drafts, vec![None, Some(draft.clone())]);
    let retry = session
        .native_retry(&owner.frozen, &root, &state, scope.clone())
        .unwrap();
    assert_eq!(retry.display, draft.text);
    assert_eq!(retry.draft, Some(draft.clone()));
    assert!(retry.prompt.contains("selected task B"));
    assert!(!retry.prompt.contains("question A"));
    assert!(!retry.prompt.contains("full body B"));
    session.accepted(retry.clone());
    owner.prepared = Some(PreparedNativeTurn {
        thread_id: owner.frozen.id.clone(),
        generation: owner.generation,
        display: retry.display,
        draft: retry
            .draft
            .map(|draft| serde_json::to_value(draft).unwrap()),
        images: retry.images,
        retry: true,
    });
    let (reply, result) = oneshot::channel();
    owner.start_turn(
        owner.generation,
        owner.frozen.id.clone(),
        NativeTurn {
            session_id: "session".into(),
            prompt: retry.prompt,
            observer: Box::new(NoopObserver),
            approver: Arc::new(AutoApprover),
            cancel: CancelSwitch::new(),
        },
        reply,
    );
    let job = block_on(owner.jobs.next()).unwrap();
    owner.completed(job);
    block_on(result).unwrap().unwrap();
    let requests = provider.requests();
    assert_eq!(requests.len(), 3);
    assert!(requests[2]
        .messages
        .last()
        .unwrap()
        .text()
        .contains("selected task B"));
    assert_eq!(
        owner
            .frozen
            .entries
            .iter()
            .filter(|entry| matches!(entry, cgc_agent_core::Entry::User { .. }))
            .count(),
        3
    );
    assert_eq!(
        owner.frozen.user_drafts[2],
        Some(serde_json::to_value(draft).unwrap())
    );

    let image = ImageAttachment {
        name: "diagram.png".into(),
        mime_type: "image/png".into(),
        data: "aW1hZ2U=".into(),
    };
    owner
        .agent
        .as_mut()
        .unwrap()
        .thread_mut()
        .attach_images_to_last_user(vec![image.clone()]);
    owner.freeze();
    let retry = session
        .native_retry(&owner.frozen, &root, &state, scope)
        .unwrap();
    assert_eq!(retry.images, vec![image]);
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
fn conversation_rewind_succeeds_with_an_empty_checkpoint_or_without_git() {
    for with_checkpoint in [false, true] {
        let root = std::env::temp_dir().join(format!(
            "cgc-empty-rewind-{}-{with_checkpoint}",
            std::process::id()
        ));
        std::fs::create_dir_all(&root).unwrap();
        let mut owner = configured_owner(&root);
        owner.store = Some(SessionStore::open_in_memory().unwrap());
        owner
            .agent
            .as_mut()
            .unwrap()
            .thread_mut()
            .user_drafts
            .push(Some(serde_json::json!({"text": "saved draft"})));
        owner.freeze();
        if with_checkpoint {
            owner.checkpoint_manager = Some(CheckpointManager::initialize(&root).unwrap());
            let thread_id = owner.frozen.id.clone();
            owner.capture_checkpoint(&thread_id, 1);
            assert_eq!(owner.checkpoints.len(), 1);
        }
        let generation = owner.generation;
        let snapshot = owner
            .rewind(1, with_checkpoint)
            .expect("rewind a chat-only conversation");
        assert!(snapshot.thread.entries.is_empty());
        assert!(snapshot.thread.user_drafts.is_empty());
        assert!(owner.checkpoints.is_empty());
        assert_eq!(snapshot.generation, generation + 1);
        if with_checkpoint {
            assert_eq!(
                owner
                    .store
                    .as_ref()
                    .unwrap()
                    .list_checkpoints(&snapshot.thread.id)
                    .unwrap()[0]
                    .state,
                "invalid"
            );
        }
        std::fs::remove_dir_all(root).unwrap();
    }
}

#[test]
fn failed_file_restore_preserves_conversation_and_workspace() {
    for invalid_head in [false, true] {
        let root = std::env::temp_dir().join(format!(
            "cgc-failed-rewind-{}-{invalid_head}",
            std::process::id()
        ));
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(root.join("note.txt"), "before").unwrap();
        let mut owner = configured_owner(&root);
        owner.store = Some(SessionStore::open_in_memory().unwrap());
        owner
            .agent
            .as_mut()
            .unwrap()
            .thread_mut()
            .user_drafts
            .push(Some(serde_json::json!({
                "text": "a question with an attachment",
                "attachments": [{"label": "saved-selection", "text": "preserve this source"}]
            })));
        owner.freeze();
        owner.checkpoint_manager = Some(CheckpointManager::initialize(&root).unwrap());
        let thread_id = owner.frozen.id.clone();
        owner.capture_checkpoint(&thread_id, 1);
        assert_eq!(owner.checkpoints.len(), 1);
        if invalid_head {
            let output = std::process::Command::new("git")
                .arg("-C")
                .arg(&root)
                .args(["update-ref", "HEAD", &owner.checkpoints[0].1.sha])
                .output()
                .unwrap();
            assert!(output.status.success());
        } else {
            Arc::make_mut(&mut owner.checkpoints)[0].1.sha = "0".repeat(40);
        }
        std::fs::write(root.join("note.txt"), "after").unwrap();
        let before = owner.frozen.clone();
        let generation = owner.generation;
        assert!(matches!(
            owner.rewind(1, true),
            Err(NativeRuntimeError::Checkpoint(_))
        ));
        assert_eq!(owner.frozen.entries, before.entries);
        assert_eq!(owner.frozen.user_drafts, before.user_drafts);
        assert_eq!(
            owner.agent.as_ref().unwrap().thread().entries,
            before.entries
        );
        assert_eq!(
            owner.agent.as_ref().unwrap().thread().user_drafts,
            before.user_drafts
        );
        assert_eq!(owner.generation, generation);
        assert_eq!(
            std::fs::read_to_string(root.join("note.txt")).unwrap(),
            "after"
        );
        std::fs::remove_dir_all(root).unwrap();
    }
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
        anthropic_url: None,
        responses_url: None,
        models_url: None,
        models: vec!["m1".into(), "m2".into()],
        model_params: Vec::new(),
        has_key: true,
        builtin: false,
        enabled: true,
        protocol: cgc_agent_provider::ProviderProtocol::OpenAiCompatible,
        ..Default::default()
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
                anthropic_url: None,
                responses_url: None,
                models_url: None,
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
                enabled: true,
                protocol: cgc_agent_provider::ProviderProtocol::OpenAiCompatible,
                ..Default::default()
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

#[test]
fn managed_provider_turn_errors_emit_structured_turn_error_events() {
    use cgc_agent_core::{AutoApprover, NoopObserver};
    use cgc_agent_host::acp_server::CancelSwitch;
    use cgc_agent_provider::{FakeProvider, ProviderError};

    let root = std::env::temp_dir().join(format!(
        "cgc-turn-error-events-{}",
        uuid::Uuid::new_v4().simple()
    ));
    std::fs::create_dir_all(&root).unwrap();

    let model = Model::new(
        ProviderId::new(CGC_CLOUD_PROVIDER_ID),
        "CGC Cloud",
        "deepseek-chat",
        "DeepSeek Chat",
        ModelLimits::new(8_000, 1_000),
    );
    let provider = Arc::new(FakeProvider::new(
        ProviderId::new(CGC_CLOUD_PROVIDER_ID),
        "CGC Cloud",
        vec![model.clone()],
    ));
    let thread = Thread::new(
        "managed-thread-1",
        cgc_agent_core::SelectedModel::new(model.provider_id.clone(), model.id.clone()),
    );
    let mut owner = Owner::initialize(
        Initialization::Explicit {
            thread: Box::new(thread),
            system_prompt: None,
            config: Box::new(NativeRuntimeConfig {
                provider: provider.clone(),
                model,
                registry: Arc::new(ToolRegistry::new()),
                context: ToolContext::new(&root),
                context_size: 8_000,
                auto_approve: true,
            }),
            store: None,
        },
        Weak::new(),
        Arc::new(std::sync::Mutex::new(None)),
    )
    .expect("initialize owner");

    let (sub_tx, mut sub_rx) = mpsc::unbounded();
    owner.command(Command::Subscribe(sub_tx));
    // Drain initial snapshot event.
    let _ = sub_rx.try_recv();

    let run_failing_turn = |owner: &mut Owner, error: ProviderError| {
        provider.push_script(vec![Err(error)]);
        let (reply, result) = oneshot::channel();
        owner.start_turn(
            owner.generation,
            owner.frozen.id.clone(),
            NativeTurn {
                session_id: "session".into(),
                prompt: "hello".into(),
                observer: Box::new(NoopObserver),
                approver: Arc::new(AutoApprover),
                cancel: CancelSwitch::new(),
            },
            reply,
        );
        let job = block_on(owner.jobs.next()).expect("turn job");
        owner.completed(job);
        let turn_result = block_on(result).expect("reply");
        assert!(turn_result.is_err());
    };

    run_failing_turn(&mut owner, ProviderError::insufficient_quota("no credits"));
    let mut events = Vec::new();
    while let Ok(event) = sub_rx.try_recv() {
        events.push(event);
    }
    assert!(
        events.iter().any(|event| matches!(
            event.as_ref(),
            NativeRuntimeEvent::TurnError {
                kind: NativeTurnErrorKind::InsufficientQuota,
                ..
            }
        )),
        "HTTP 402 on managed provider must emit InsufficientQuota TurnError"
    );

    run_failing_turn(&mut owner, ProviderError::api(403, "wallet frozen"));
    events.clear();
    while let Ok(event) = sub_rx.try_recv() {
        events.push(event);
    }
    assert!(
        events.iter().any(|event| matches!(
            event.as_ref(),
            NativeRuntimeEvent::TurnError {
                kind: NativeTurnErrorKind::WalletFrozen,
                ..
            }
        )),
        "HTTP 403 on managed provider must emit WalletFrozen TurnError"
    );

    std::fs::remove_dir_all(root).ok();
}

#[test]
fn base_tools_subagent_inherits_active_thread_affinity_session_id() {
    use cgc_agent_provider::{CompletionEvent, FakeProvider, StopReason};

    let root = std::env::temp_dir().join(format!(
        "cgc-subagent-affinity-{}",
        uuid::Uuid::new_v4().simple()
    ));
    std::fs::create_dir_all(&root).unwrap();

    let model = Model::new(
        ProviderId::new(CGC_CLOUD_PROVIDER_ID),
        "CGC Cloud",
        "deepseek-chat",
        "DeepSeek Chat",
        ModelLimits::new(8_000, 1_000),
    );
    let provider = Arc::new(FakeProvider::new(
        ProviderId::new(CGC_CLOUD_PROVIDER_ID),
        "CGC Cloud",
        vec![model.clone()],
    ));
    provider.push_script(vec![
        Ok(CompletionEvent::Text("subagent answer".to_string())),
        Ok(CompletionEvent::Stop(StopReason::EndTurn)),
    ]);

    let thread = Thread::new(
        "native-parent-thread-99",
        cgc_agent_core::SelectedModel::new(model.provider_id.clone(), model.id.clone()),
    );
    let mut owner = Owner::initialize(
        Initialization::Explicit {
            thread: Box::new(thread),
            system_prompt: None,
            config: Box::new(NativeRuntimeConfig {
                provider: provider.clone(),
                model,
                registry: Arc::new(ToolRegistry::new()),
                context: ToolContext::new(&root),
                context_size: 8_000,
                auto_approve: true,
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
        data_root: root.clone(),
        keychain: KeychainStore::new(Arc::new(MemoryKeychain(AtomicBool::new(true)))),
        allow_echo: false,
        model_setup: ModelSetup::Configured,
        pending: None,
    });
    owner.rebuild_tools();

    let task_tool = owner
        .config
        .registry
        .get("task")
        .expect("base_tools registers task subagent tool");
    let output = block_on(task_tool.run(
        serde_json::json!({"task": "check workspace"}),
        owner.config.context.clone(),
    ))
    .expect("task tool succeeds");
    assert!(!output.is_error);
    assert_eq!(output.content, "subagent answer");

    let requests = provider.requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(
        requests[0].session_id.as_deref(),
        Some("native-parent-thread-99"),
        "task subagent must inherit parent thread ID as x-session-affinity"
    );

    std::fs::remove_dir_all(root).ok();
}

#[test]
fn checkpoint_prune_invalidates_sqlite_and_memory_entries() {
    let root = std::env::temp_dir().join(format!("cgc-rt-prune-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(&root).unwrap();
    let mut owner = configured_owner(&root);
    owner.store = Some(SessionStore::open_in_memory().unwrap());
    owner.freeze();
    owner.checkpoint_manager = Some(
        CheckpointManager::initialize(&root)
            .unwrap()
            .with_max_refs(2)
            .with_max_total_refs(2),
    );
    let thread_id = owner.frozen.id.clone();
    for seq in 1..=3 {
        std::fs::write(root.join("note.txt"), format!("turn-{seq}")).unwrap();
        owner.capture_checkpoint(&thread_id, seq);
    }

    let in_mem: Vec<usize> = owner.checkpoints.iter().map(|(seq, _)| *seq).collect();
    assert_eq!(in_mem, vec![2, 3]);

    let records = owner
        .store
        .as_ref()
        .unwrap()
        .list_checkpoints(&thread_id)
        .unwrap();
    assert_eq!(records.len(), 3);
    assert_eq!(records[0].user_entry_seq, 1);
    assert_eq!(records[0].state, "invalid");
    assert_eq!(records[1].state, "active");
    assert_eq!(records[2].state, "active");
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn rewind_deletes_git_refs_from_ordinal_and_marks_sqlite_invalid() {
    let root = std::env::temp_dir().join(format!("cgc-rt-rewind-refs-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(&root).unwrap();
    let mut owner = configured_owner(&root);
    owner.store = Some(SessionStore::open_in_memory().unwrap());
    owner.checkpoint_manager = Some(CheckpointManager::initialize(&root).unwrap());
    let thread_id = owner.frozen.id.clone();

    std::fs::write(root.join("note.txt"), "v1").unwrap();
    owner.capture_checkpoint(&thread_id, 1);

    {
        let thread = owner.agent.as_mut().unwrap().thread_mut();
        thread.push_user("second user prompt");
    }
    std::fs::write(root.join("note.txt"), "v2").unwrap();
    owner.capture_checkpoint(&thread_id, 2);

    {
        let thread = owner.agent.as_mut().unwrap().thread_mut();
        thread.push_user("third user prompt");
    }
    std::fs::write(root.join("note.txt"), "v3").unwrap();
    owner.capture_checkpoint(&thread_id, 3);
    owner.freeze();

    assert_eq!(
        owner
            .checkpoint_manager
            .as_ref()
            .unwrap()
            .list(&thread_id)
            .unwrap()
            .into_iter()
            .map(|c| c.seq)
            .collect::<Vec<_>>(),
        vec![1, 2, 3]
    );

    owner.rewind(2, true).expect("rewind to ordinal 2");

    assert_eq!(
        std::fs::read_to_string(root.join("note.txt")).unwrap(),
        "v2"
    );
    let remaining_refs: Vec<u64> = owner
        .checkpoint_manager
        .as_ref()
        .unwrap()
        .list(&thread_id)
        .unwrap()
        .into_iter()
        .map(|c| c.seq)
        .collect();
    assert_eq!(remaining_refs, vec![1]);

    let records = owner
        .store
        .as_ref()
        .unwrap()
        .list_checkpoints(&thread_id)
        .unwrap();
    assert_eq!(records[0].state, "active");
    assert_eq!(records[1].state, "invalid");
    assert_eq!(records[2].state, "invalid");
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn checkpoint_budget_circuit_breaker_dedups_notices_and_recovers_after_background_gc() {
    use futures::StreamExt as _;

    let root = std::env::temp_dir().join(format!("cgc-rt-budget-gc-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(&root).unwrap();

    let manager = CheckpointManager::initialize(&root)
        .unwrap()
        .with_max_refs(50)
        .with_max_total_refs(200)
        .with_max_object_bytes(250 * 1024);

    let mut state: u64 = 0x1234_5678_9ABC_DEF0;
    let mut base = String::with_capacity(120 * 1024);
    while base.len() < 120 * 1024 {
        state = state.wrapping_mul(6364136223846793005).wrapping_add(1);
        use std::fmt::Write as _;
        let _ = writeln!(base, "{state:016x}");
    }
    for seq in 1..=5 {
        std::fs::write(root.join("data.txt"), format!("{base}seq={seq}\n")).unwrap();
        let _ = manager.snapshot_with_report("old-thread", seq);
    }

    let mut owner = configured_owner(&root);
    owner.store = Some(SessionStore::open_in_memory().unwrap());
    owner.freeze();
    owner.checkpoint_manager = Some(manager.clone());

    let (sub_tx, mut sub_rx) = mpsc::unbounded();
    owner.command(Command::Subscribe(sub_tx));
    let _ = block_on(sub_rx.next()); // initial snapshot

    let thread_id = owner.frozen.id.clone();
    owner.capture_checkpoint(&thread_id, 1);
    assert!(owner.checkpoint_budget_exceeded);
    assert!(owner.checkpoints.is_empty());

    // 第二轮仍处于熔断状态时，不能重复弹 notice。
    owner.capture_checkpoint(&thread_id, 2);

    let mut notices = Vec::new();
    while let Ok(event) = sub_rx.try_recv() {
        if let NativeRuntimeEvent::Notice { message, .. } = &*event {
            notices.push(message.clone());
        }
    }
    assert_eq!(notices.len(), 1, "budget notice should be deduplicated");

    // 触发并完成后台 reclaim GC 后，应自动解除熔断并重新放行快照。
    owner.maybe_start_checkpoint_gc();
    assert!(owner.checkpoint_gc_running);
    let job = block_on(owner.jobs.next()).expect("checkpoint gc job");
    owner.completed(job);

    assert!(!owner.checkpoint_gc_running);
    assert!(!owner.checkpoint_budget_exceeded);
    assert!(owner.last_checkpoint_gc_at.is_some());

    owner.capture_checkpoint(&thread_id, 1);
    assert_eq!(owner.checkpoints.len(), 1);

    // 不可恢复场景（用户 HEAD 自己已超限）：保持熔断，仅发一次不可恢复通知，绝不碰 HEAD。
    std::fs::write(root.join("committed.txt"), &base).unwrap();
    for args in [
        &["add", "--all"][..],
        &[
            "-c",
            "user.name=Test",
            "-c",
            "user.email=test@example.com",
            "commit",
            "-m",
            "user commit",
        ][..],
    ] {
        let out = std::process::Command::new("git")
            .arg("-C")
            .arg(&root)
            .args(args)
            .output()
            .unwrap();
        assert!(out.status.success());
    }
    let impossible = manager.with_max_object_bytes(1);
    owner.checkpoint_manager = Some(impossible);
    owner.capture_checkpoint(&thread_id, 2);
    assert!(owner.checkpoint_budget_exceeded);
    owner.maybe_start_checkpoint_gc();
    let job = block_on(owner.jobs.next()).expect("unrecoverable gc job");
    owner.completed(job);
    assert!(owner.checkpoint_budget_exceeded);

    owner.capture_checkpoint(&thread_id, 3);
    // 冷却时间内，不可恢复状态下不应重复触发后台 reclaim。
    owner.maybe_start_checkpoint_gc();
    assert!(!owner.checkpoint_gc_running);

    owner.last_checkpoint_gc_at = None;
    owner.maybe_start_checkpoint_gc();
    let job2 = block_on(owner.jobs.next()).expect("second unrecoverable gc job");
    owner.completed(job2);
    assert!(owner.checkpoint_budget_exceeded);

    let mut post_notices = Vec::new();
    while let Ok(event) = sub_rx.try_recv() {
        if let NativeRuntimeEvent::Notice { message, .. } = &*event {
            post_notices.push(message.clone());
        }
    }
    // 1 条首次超限 notice + 1 条不可恢复 notice（第二次仍不可恢复不重复刷屏）
    assert_eq!(
        post_notices.len(),
        2,
        "expected exactly 1 budget notice + 1 unrecoverable notice, got: {post_notices:?}"
    );
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn manual_checkpoint_cleanup_purges_history_syncs_sqlite_clears_budget_and_rejects_when_busy() {
    use futures::StreamExt as _;

    let root = std::env::temp_dir().join(format!("cgc-rt-manual-purge-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(&root).unwrap();

    let manager = CheckpointManager::initialize(&root)
        .unwrap()
        .with_max_refs(50)
        .with_max_total_refs(200)
        .with_max_object_bytes(250 * 1024);

    let mut state: u64 = 0x55AA_55AA_1234_5678;
    let mut base = String::with_capacity(120 * 1024);
    while base.len() < 120 * 1024 {
        state = state.wrapping_mul(6364136223846793005).wrapping_add(1);
        use std::fmt::Write as _;
        let _ = writeln!(base, "{state:016x}");
    }

    // 提交一个用户 HEAD 文件，确保手动清理绝不触碰用户历史。
    std::fs::write(root.join("user.txt"), "keep user commit\n").unwrap();
    for args in [
        &["add", "--all"][..],
        &[
            "-c",
            "user.name=Test",
            "-c",
            "user.email=test@example.com",
            "commit",
            "-m",
            "user base",
        ][..],
    ] {
        let out = std::process::Command::new("git")
            .arg("-C")
            .arg(&root)
            .args(args)
            .output()
            .unwrap();
        assert!(out.status.success());
    }
    let head_before = manager.head().unwrap().expect("head");

    let mut owner = configured_owner(&root);
    owner.store = Some(SessionStore::open_in_memory().unwrap());
    owner.freeze();
    owner.checkpoint_manager = Some(manager.clone());

    let thread_id = owner.frozen.id.clone();
    std::fs::write(root.join("data.txt"), format!("{base}current=1\n")).unwrap();
    owner.capture_checkpoint(&thread_id, 1);
    std::fs::write(root.join("data.txt"), format!("{base}current=2\n")).unwrap();
    owner.capture_checkpoint(&thread_id, 2);

    // 另一条旧线程塞入多条快照（用未限额句柄模拟历史累积）后再触发当前会话预算超限熔断。
    let seed_manager = CheckpointManager::open(&root).unwrap();
    for seq in 1..=3 {
        std::fs::write(root.join("data.txt"), format!("{base}other={seq}\n")).unwrap();
        seed_manager.snapshot("old-thread", seq).unwrap();
    }
    owner.capture_checkpoint(&thread_id, 3);
    assert!(owner.checkpoint_budget_exceeded);

    let (inspect_tx, inspect_rx) = oneshot::channel();
    owner.command(Command::InspectCheckpointStorage(inspect_tx));
    let summary = block_on(inspect_rx)
        .unwrap()
        .unwrap()
        .expect("storage summary");
    assert_eq!(summary.total_refs, 5);
    assert!(summary.stats.total_bytes() > 250 * 1024);

    // 运行中（active 或 checkpoint_gc_running）拒绝手动清理。
    owner.checkpoint_gc_running = true;
    let (busy_tx, busy_rx) = oneshot::channel();
    owner.command(Command::PurgeCheckpointHistory(busy_tx));
    assert_eq!(
        block_on(busy_rx).unwrap().unwrap_err(),
        NativeRuntimeError::Busy
    );
    owner.checkpoint_gc_running = false;

    // 空闲态执行手动清理。
    let (purge_tx, purge_rx) = oneshot::channel();
    owner.command(Command::PurgeCheckpointHistory(purge_tx));
    assert!(owner.checkpoint_gc_running);
    let job = block_on(owner.jobs.next()).expect("manual cleanup job");
    owner.completed(job);

    let report = block_on(purge_rx).unwrap().expect("purge report");
    assert!(!owner.checkpoint_gc_running);
    assert_eq!(report.pruned.len(), 4);
    assert_eq!(report.remaining_refs, 1);
    assert!(report.within_budget);
    assert!(!owner.checkpoint_budget_exceeded);

    let remaining_seqs: Vec<usize> = owner.checkpoints.iter().map(|(seq, _)| *seq).collect();
    assert_eq!(remaining_seqs, vec![2]);
    assert!(manager.list("old-thread").unwrap().is_empty());

    let records = owner
        .store
        .as_ref()
        .unwrap()
        .list_checkpoints(&thread_id)
        .unwrap();
    assert_eq!(records[0].state, "invalid");
    assert_eq!(records[1].state, "active");
    assert_eq!(
        manager.head().unwrap().as_deref(),
        Some(head_before.as_str())
    );

    let _ = std::fs::remove_dir_all(root);
}
