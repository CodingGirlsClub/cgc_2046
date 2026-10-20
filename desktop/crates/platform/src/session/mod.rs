//! 会话层（story 2.1 起点）：登录、凭证持久化与恢复、撤销。
//!
//! 依赖方向：UI（app）→ `SessionService` → `AuthApi` / `CredentialStore`。
//! 真实后端实现是 `HttpAuthApi`（GraphQL `signInForDesktop` / `revokeToken`）；
//! 本地开发与测试用 `FakeAuthApi` + `MemoryStore`。

use std::sync::Arc;

mod auth_api;
mod credential_store;

pub use auth_api::{
    AuthApi, AuthError, FakeAuthApi, HttpAuthApi, PhoneCodePurpose, PhoneCodeSent, SignedInSession,
    WechatLoginPoll, WechatLoginStart, WechatLoginStatus,
};
pub use credential_store::{CredentialStore, FileStore, KeychainStore, MemoryStore};

/// UI 可观察的会话状态。
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SessionState {
    SignedOut,
    SigningIn,
    SignedIn(SignedInSession),
    Failed(String),
}

pub struct SessionService {
    api: Arc<dyn AuthApi + Send + Sync>,
    store: Arc<dyn CredentialStore + Send + Sync>,
    state: SessionState,
}

impl SessionService {
    pub fn new(
        api: Box<dyn AuthApi + Send + Sync>,
        store: Box<dyn CredentialStore + Send + Sync>,
    ) -> Self {
        Self {
            api: Arc::from(api),
            store: Arc::from(store),
            state: SessionState::SignedOut,
        }
    }

    /// 默认运行时装配：`CGC_AUTH=http`（或设置了 `CGC_API_URL`）走真实后端，
    /// 否则用 fake auth（本地 UI 开发无需 backend）；凭证默认存 OS keychain（2.7 fail-closed），
    /// `CGC_SESSION_FILE` 保留为 QA/离线演示覆盖。
    pub fn from_runtime() -> Self {
        let use_http = std::env::var("CGC_AUTH").as_deref() == Ok("http")
            || std::env::var("CGC_API_URL").is_ok();
        let api: Box<dyn AuthApi + Send + Sync> = if use_http {
            Box::new(HttpAuthApi::from_env())
        } else {
            Box::new(FakeAuthApi::demo())
        };
        let store: Box<dyn CredentialStore + Send + Sync> =
            match std::env::var_os("CGC_SESSION_FILE") {
                Some(path) => Box::new(FileStore::new(path)),
                None => Box::new(KeychainStore::from_env()),
            };
        Self::new(api, store).restore()
    }

    /// 后台线程用：克隆一份 api 句柄（阻塞调用不占 UI 线程）。
    pub fn api_handle(&self) -> Arc<dyn AuthApi + Send + Sync> {
        Arc::clone(&self.api)
    }

    pub fn begin_sign_in(&mut self) {
        self.state = SessionState::SigningIn;
    }

    /// 登录成功回填（由后台结果调用）：持久化并转 SignedIn。
    pub fn adopt_signed_in(&mut self, session: SignedInSession) -> Result<(), AuthError> {
        if let Err(err) = self.store.save(&session) {
            self.state = SessionState::Failed(format!("cannot persist session: {err}"));
            return Err(AuthError::Storage(format!("cannot persist session: {err}")));
        }
        self.state = SessionState::SignedIn(session);
        Ok(())
    }

    /// 登录失败回填：保留 Failed 诊断，UI 显示统一错误。
    pub fn fail_sign_in(&mut self, error: &AuthError) {
        self.state = SessionState::Failed(error.diagnostic());
    }

    /// 立即本地登出（清存储/状态），返回被撤销的 token 供后台 best-effort 撤销。
    pub fn sign_out_local(&mut self) -> Option<String> {
        let token = self.signed_in().map(|session| session.token.clone());
        let _ = self.store.clear();
        self.state = SessionState::SignedOut;
        token
    }

    /// 启动时尝试从存储恢复（重启后仍登录）。
    pub fn restore(mut self) -> Self {
        self.state = match self.store.load() {
            Some(session) => SessionState::SignedIn(session),
            None => SessionState::SignedOut,
        };
        self
    }

    /// 启动恢复后校验持久 token；网络错误保持会话，确定失效由 UI 统一登出。
    pub fn validate_current(&self) -> Result<bool, AuthError> {
        match self.signed_in() {
            Some(session) => self.api.validate(&session.token),
            None => Ok(false),
        }
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
                    return Err(AuthError::Storage(format!("cannot persist session: {err}")));
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

    struct UnavailableStore;

    impl CredentialStore for UnavailableStore {
        fn load(&self) -> Option<SignedInSession> {
            None
        }
        fn save(&self, _session: &SignedInSession) -> std::io::Result<()> {
            Err(std::io::Error::new(
                std::io::ErrorKind::Unsupported,
                "keychain unavailable",
            ))
        }
        fn clear(&self) -> std::io::Result<()> {
            Ok(())
        }
    }

    #[test]
    fn sign_in_fails_closed_when_store_unavailable() {
        let mut service =
            SessionService::new(Box::new(FakeAuthApi::demo()), Box::new(UnavailableStore));
        let error = service.sign_in("demo@example.com", "demo").unwrap_err();
        assert!(matches!(error, AuthError::Storage(_)));
        assert!(service.signed_in().is_none());
        assert!(matches!(service.state(), SessionState::Failed(_)));
        assert!(!error.diagnostic().contains("jwt"));
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
