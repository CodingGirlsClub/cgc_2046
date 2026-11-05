use super::after_authorization;
use futures::{channel::oneshot, FutureExt};
use std::sync::{Arc, Mutex};

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
