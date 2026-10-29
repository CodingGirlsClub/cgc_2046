//! Story 2.11：登录/工作台 e2e 回归套件（headless）。
//! 覆盖登录成功/失败、重启恢复、登出清凭证、工作台加载/切换/epoch、无工作台、
//! i18n 双语完整性与路由注册校验。a11y 的 AccessKit 语义需真机，登记 epic-7。

use std::sync::Arc;

use cgc_desktop_app::i18n::Language;
use cgc_desktop_app::registration::{build_registry, validate};
use cgc_platform::session::{
    AuthError, CredentialStore, FakeAuthApi, MemoryStore, SessionService, SessionState,
};
use cgc_platform::workspace::{FakeWorkspaceApi, WorkspaceListState, WorkspaceService};

fn session(store: &MemoryStore) -> SessionService {
    SessionService::new(Box::new(FakeAuthApi::demo()), Box::new(store.clone()))
}

#[test]
fn login_persist_restore_and_sign_out() {
    let store = MemoryStore::default();
    let mut service = session(&store);
    let signed_in = service
        .sign_in("demo@example.com", "demo")
        .expect("step 1: login");
    assert_eq!(
        signed_in.email.as_deref(),
        Some("demo@example.com"),
        "step 1: email"
    );
    assert!(
        matches!(service.state(), SessionState::SignedIn(_)),
        "step 2: state"
    );

    let restored = session(&store).restore();
    assert!(
        restored.signed_in().is_some(),
        "step 3: restore after restart"
    );

    service.sign_out();
    assert!(
        matches!(service.state(), SessionState::SignedOut),
        "step 4: signed out"
    );
    assert!(store.load().is_none(), "step 5: credential cleared");
}

#[test]
fn invalid_credentials_fail_without_persisting() {
    let store = MemoryStore::default();
    let mut service = session(&store);
    let error = service
        .sign_in("demo@example.com", "wrong")
        .expect_err("step 1: wrong password");
    assert!(
        matches!(error, AuthError::InvalidCredentials),
        "step 1: invalid"
    );
    assert!(
        matches!(service.state(), SessionState::Failed(_)),
        "step 2: failed state"
    );
    assert!(store.load().is_none(), "step 3: nothing persisted");
}

#[test]
fn workspace_load_switch_epoch_and_reset() {
    let mut workspaces = WorkspaceService::new(Arc::new(FakeWorkspaceApi::demo()));
    workspaces.begin_load();
    let list = workspaces
        .fetch(Some("token"))
        .expect("step 1: fetch workspaces");
    workspaces.adopt(list);
    assert!(
        matches!(workspaces.state(), WorkspaceListState::Ready),
        "step 1: ready"
    );
    assert_eq!(
        workspaces.current_id(),
        Some("ws-2046"),
        "step 2: default first"
    );
    let first_epoch = workspaces.epoch();
    assert!(workspaces.scope().is_some(), "step 2: scope");
    assert!(
        workspaces.is_current_epoch(first_epoch),
        "step 2: epoch current"
    );

    assert!(workspaces.switch_to("ws-demo"), "step 3: switch");
    assert_eq!(workspaces.current_id(), Some("ws-demo"), "step 3: switched");
    assert_eq!(workspaces.epoch(), first_epoch + 1, "step 3: epoch bumped");
    assert!(
        !workspaces.is_current_epoch(first_epoch),
        "step 4: old epoch invalid"
    );

    workspaces.reset();
    assert!(
        matches!(workspaces.state(), WorkspaceListState::Idle),
        "step 5: reset"
    );
    assert!(workspaces.scope().is_none(), "step 5: no scope after reset");
}

#[test]
fn account_without_workspace_is_empty_not_faked() {
    let mut workspaces = WorkspaceService::new(Arc::new(FakeWorkspaceApi::empty()));
    workspaces.begin_load();
    let list = workspaces.fetch(None).expect("step 1: fetch empty");
    workspaces.adopt(list);
    assert!(
        matches!(workspaces.state(), WorkspaceListState::Empty),
        "step 1: empty"
    );
    assert!(workspaces.scope().is_none(), "step 2: no fabricated scope");
}

#[test]
fn i18n_and_routes_are_complete() {
    let registry = build_registry().expect("step 1: registry builds");
    validate(&registry).expect("step 2: i18n registry validates");
    for language in Language::ALL {
        let catalog = language.catalog();
        assert!(
            !catalog.is_empty(),
            "step 3: catalog for {}",
            language.code()
        );
        assert!(
            catalog.iter().all(|(_, value)| !value.trim().is_empty()),
            "step 3: no empty translations for {}",
            language.code()
        );
    }
    let zh_keys: Vec<_> = Language::Zh.catalog().iter().map(|(key, _)| *key).collect();
    let en_keys: Vec<_> = Language::En.catalog().iter().map(|(key, _)| *key).collect();
    assert_eq!(zh_keys.len(), en_keys.len(), "step 4: same key count");
    assert_eq!(
        Language::Zh.toggle(),
        Language::En,
        "step 5: language toggles"
    );
}

#[test]
fn login_and_settings_routes_are_registered() {
    let registry = build_registry().expect("registry");
    let ids = registry
        .routes()
        .iter()
        .map(|route| route.id)
        .collect::<Vec<_>>();
    assert!(ids.contains(&"app.home"), "step 1: home");
    assert!(
        ids.contains(&"app.settings"),
        "step 1: settings（键盘/设置页入口）"
    );
    assert!(ids.contains(&"events.list"), "step 2: events");
    assert!(ids.contains(&"courses.catalog"), "step 2: courses");
    assert!(ids.contains(&"agent_chat.panel"), "step 2: companion");
}
