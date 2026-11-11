use super::after_authorization;
use crate::conversation_session::ConnectionPhase;
use crate::i18n::Language;
use crate::theme::ThemePreference;
use cgc_platform::session::{FakeAuthApi, MemoryStore, SessionService};
use futures::{channel::oneshot, FutureExt};
use std::sync::{Arc, Mutex};

fn test_view() -> crate::root_view::RootView {
    // 不读本机 Keychain：这个测试只验证 lease 状态机，使用固定 fake session。
    crate::root_view::RootView::with_session_from(
        crate::registration::build_registry().expect("registry builds"),
        Language::Zh,
        ThemePreference::Light,
        SessionService::new(
            Box::new(FakeAuthApi::demo()),
            Box::new(MemoryStore::default()),
        ),
        "/w/2046/courses",
    )
}

#[test]
fn stale_lease_callback_clears_pending_and_rearms_start() {
    let mut view = test_view();
    view.chat.session.phase = ConnectionPhase::Starting;
    view.note_agent_start_interrupted();
    assert!(
        view.chat.start_after_authorization,
        "刷新授权时必须记住待重启，否则 ACP 面板停在 Starting"
    );

    // serial 推进说明已有接替授权，pending 属于新任务，旧回调不得清。
    view.agent_lease_pending = Some(7);
    view.agent_authorization_serial = 9;
    view.clear_stale_agent_lease_pending(7, 8);
    assert_eq!(
        view.agent_lease_pending,
        Some(7),
        "过期回调不能清掉接替任务的 pending"
    );
    // 没有接替任务时，过期回调必须自清 pending，避免同 epoch 再也发不出授权。
    view.clear_stale_agent_lease_pending(7, 9);
    assert_eq!(view.agent_lease_pending, None);

    assert!(view.take_pending_agent_restart());
    assert!(!view.chat.start_after_authorization);
    assert_eq!(
        view.chat.session.phase,
        ConnectionPhase::Idle,
        "start_chat 对 Starting 早退，重启前必须先复位"
    );
}

#[test]
fn sign_out_waits_for_pending_issuance_then_revokes_mcp_before_login() {
    let events = Arc::new(Mutex::new(Vec::new()));
    let (release, pending) = oneshot::channel::<()>();
    let issued = events.clone();
    let issuance = async move {
        pending.await.unwrap();
        issued.lock().unwrap().push("lease-saved");
    }
    .boxed()
    .shared();
    let revoked = events.clone();
    let mcp_revocation = async move {
        after_authorization(Some(issuance), || {
            revoked.lock().unwrap().push("mcp-revoked");
        })
        .await;
    }
    .boxed()
    .shared();
    let logged_out = events.clone();
    let mut logout = Box::pin(after_authorization(Some(mcp_revocation), || {
        logged_out.lock().unwrap().push("login-revoked");
    }));
    futures::executor::block_on(async {
        assert!(futures::poll!(logout.as_mut()).is_pending());
        assert!(events.lock().unwrap().is_empty());
        release.send(()).unwrap();
        logout.await;
    });
    assert_eq!(
        *events.lock().unwrap(),
        vec!["lease-saved", "mcp-revoked", "login-revoked"]
    );
}
