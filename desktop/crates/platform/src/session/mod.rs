//! 会话层（story 2.1 起点）：登录、凭证持久化与恢复、撤销。
//!
//! 依赖方向：UI（app）→ `SessionService` → `AuthApi` / `CredentialStore`。
//! 真实后端实现是 `HttpAuthApi`（GraphQL `signInForDesktop` / `revokeToken`）；
//! 本地开发与测试用 `FakeAuthApi` + `MemoryStore`。

mod auth_api;
mod credential_store;

pub use auth_api::{AuthApi, AuthError, FakeAuthApi, HttpAuthApi, SignedInSession};
pub use credential_store::{CredentialStore, FileStore, MemoryStore};

/// UI 可观察的会话状态。
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SessionState {
    SignedOut,
    SigningIn,
    SignedIn(SignedInSession),
    Failed(String),
}

pub struct SessionService {
    api: Box<dyn AuthApi + Send + Sync>,
    store: Box<dyn CredentialStore + Send + Sync>,
    state: SessionState,
}

impl SessionService {
    pub fn new(
        api: Box<dyn AuthApi + Send + Sync>,
        store: Box<dyn CredentialStore + Send + Sync>,
    ) -> Self {
        Self {
            api,
            store,
            state: SessionState::SignedOut,
        }
    }

    /// 启动时尝试从存储恢复（重启后仍登录）。
    pub fn restore(mut self) -> Self {
        self.state = match self.store.load() {
            Some(session) => SessionState::SignedIn(session),
            None => SessionState::SignedOut,
        };
        self
    }

    pub fn state(&self) -> &SessionState {
        &self.state
    }

    pub fn signed_in(&self) -> Option<&SignedInSession> {
        match &self.state {
            SessionState::SignedIn(session) => Some(session),
            _ => None,
        }
    }

    /// 登录：先置 SigningIn，成功则持久化并转 SignedIn；失败转 Failed 并保留可重试。
    pub fn sign_in(&mut self, login: &str, password: &str) -> Result<&SignedInSession, AuthError> {
        self.state = SessionState::SigningIn;
        match self.api.sign_in(login, password) {
            Ok(session) => {
                if let Err(err) = self.store.save(&session) {
                    self.state = SessionState::Failed(format!("cannot persist session: {err}"));
                    return Err(AuthError::Server("cannot persist session".to_string()));
                }
                self.state = SessionState::SignedIn(session);
                match &self.state {
                    SessionState::SignedIn(session) => Ok(session),
                    _ => unreachable!("state just set to SignedIn"),
                }
            }
            Err(err) => {
                self.state = SessionState::Failed(err.diagnostic());
                Err(err)
            }
        }
    }

    /// 登出：撤销当前 Bearer（失败不阻断本地清理），然后清空存储。
    pub fn sign_out(&mut self) {
        if let SessionState::SignedIn(session) = &self.state {
            let _ = self.api.revoke(&session.token);
        }
        let _ = self.store.clear();
        self.state = SessionState::SignedOut;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fake_login_persists_and_restores() {
        let store = MemoryStore::default();
        let mut service =
            SessionService::new(Box::new(FakeAuthApi::demo()), Box::new(store.clone()));
        assert_eq!(service.state(), &SessionState::SignedOut);

        service
            .sign_in("demo@example.com", "demo")
            .expect("fake login succeeds");
        assert_eq!(
            service.signed_in().map(|s| s.token.as_str()),
            Some("fake-desktop-token")
        );

        // 同一个 store 重建服务 = 模拟重启后恢复。
        let restored =
            SessionService::new(Box::new(FakeAuthApi::demo()), Box::new(store)).restore();
        assert!(restored.signed_in().is_some());
    }

    #[test]
    fn sign_in_failure_keeps_signed_out_with_diagnostic() {
        let mut service = SessionService::new(
            Box::new(FakeAuthApi::demo()),
            Box::new(MemoryStore::default()),
        );
        assert!(matches!(
            service.sign_in("demo@example.com", "wrong"),
            Err(AuthError::InvalidCredentials)
        ));
        assert!(matches!(service.state(), SessionState::Failed(_)));
        assert!(service.signed_in().is_none());
    }

    #[test]
    fn sign_out_revokes_and_clears_persisted_session() {
        let store = MemoryStore::default();
        let mut service =
            SessionService::new(Box::new(FakeAuthApi::demo()), Box::new(store.clone()));
        service.sign_in("demo@example.com", "demo").expect("login");
        service.sign_out();

        assert_eq!(service.state(), &SessionState::SignedOut);
        assert!(
            store.load().is_none(),
            "signOut must clear persisted credential"
        );
    }
}
