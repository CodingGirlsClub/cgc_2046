//! CGC Cloud managed gateway 客户端（Phase 4）。
//!
//! 桌面端不把登录 JWT 直接发给 `/v1/chat/completions`：后端只接受
//! `mcp_token_kind == :terminal` 的 MCP token。这里通过 GraphQL
//! `createMcpToken` 签发一个名为 `CGC Desktop Gateway` 的 terminal token，
//! 明文只保存在 OS keychain（或本次进程内存），供 OpenAI-compatible provider
//! 作为 Bearer 使用；401 时清掉旧 token 并重签。
//!
//! 同一模块也承载 `myLlmWallet`、`createLlmPaymentOrder`、`llmPaymentOrder`
//! 的 GraphQL 读写，供 native agent 状态栏与 402 续费卡使用。

use std::sync::{Arc, LazyLock, Mutex, RwLock};

use serde_json::{json, Value};
use url::Url;

use crate::api::{ApiError, GraphqlClient};
use crate::runtime;
use crate::session::{KeychainStore, SignedInSession};

const CREATE_MCP_TOKEN: &str = r#"
mutation CreateGatewayTerminalToken($name: String!) {
  createMcpToken(name: $name, kind: TERMINAL) {
    plainToken
    errors { message code }
  }
}
"#;

const MY_LLM_WALLET: &str = r#"
query MyLlmWallet {
  myLlmWallet {
    walletId
    cachedBalanceMc
    heldMc
    availableMc
    maxConcurrentStreams
    status
    remainingPercentage
    activeGrants { id sourceType initialMc remainingMc expiresAt status }
  }
}
"#;

const CREATE_LLM_PAYMENT_ORDER: &str = r#"
mutation CreateLlmPaymentOrder(
  $orderKind: String!
  $provider: String!
  $amountCents: Int!
  $workspaceId: ID
  $idempotencyKey: String!
) {
  createLlmPaymentOrder(
    orderKind: $orderKind
    provider: $provider
    amountCents: $amountCents
    workspaceId: $workspaceId
    idempotencyKey: $idempotencyKey
  ) {
    order {
      id
      workspaceId
      orderKind
      provider
      outTradeNo
      amountCents
      creditsMc
      status
      expiresAt
      paidAt
    }
    credential
  }
}
"#;

const LLM_PAYMENT_ORDER: &str = r#"
query LlmPaymentOrder($id: ID!) {
  llmPaymentOrder(id: $id) {
    id
    workspaceId
    orderKind
    provider
    outTradeNo
    amountCents
    creditsMc
    status
    expiresAt
    paidAt
  }
}
"#;

const GATEWAY_TOKEN_NAME: &str = "CGC Desktop Gateway";

/// 登录会话快照；由 `SessionService` 在登录/恢复/登出时同步到全局。
#[derive(Clone, Debug, PartialEq, Eq)]
struct GatewaySession {
    token: String,
    user_id: String,
}

/// Gateway 调用的可展示错误分类（不含 token）。
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum GatewayError {
    Unauthenticated,
    Transport(String),
    Graphql {
        code: Option<String>,
        message: String,
    },
}

impl GatewayError {
    pub fn diagnostic(&self) -> String {
        match self {
            Self::Unauthenticated => "not signed in".to_string(),
            Self::Transport(reason) => format!("transport error: {reason}"),
            Self::Graphql { code, message } => match code {
                Some(code) => format!("graphql error {code}: {message}"),
                None => format!("graphql error: {message}"),
            },
        }
    }
}

impl From<ApiError> for GatewayError {
    fn from(error: ApiError) -> Self {
        match error {
            ApiError::Unauthorized => Self::Unauthenticated,
            ApiError::Transport(reason) | ApiError::Timeout(reason) => Self::Transport(reason),
            ApiError::Graphql { code, message } => Self::Graphql { code, message },
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WalletGrant {
    pub id: String,
    pub source_type: String,
    pub initial_mc: i64,
    pub remaining_mc: i64,
    pub expires_at: Option<String>,
    pub status: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WalletSummary {
    pub wallet_id: String,
    pub cached_balance_mc: i64,
    pub held_mc: i64,
    pub available_mc: i64,
    pub max_concurrent_streams: i64,
    pub status: String,
    pub remaining_percentage: i64,
    pub active_grants: Vec<WalletGrant>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PaymentOrderSummary {
    pub id: String,
    pub workspace_id: Option<String>,
    pub order_kind: String,
    pub provider: String,
    pub out_trade_no: String,
    pub amount_cents: i64,
    pub credits_mc: i64,
    pub status: String,
    pub expires_at: Option<String>,
    pub paid_at: Option<String>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct PaymentCheckout {
    pub order: PaymentOrderSummary,
    pub credential: Value,
}

static SESSION: LazyLock<RwLock<Option<GatewaySession>>> = LazyLock::new(|| RwLock::new(None));
static AUTH: LazyLock<Arc<GatewayAuth>> = LazyLock::new(|| {
    Arc::new(GatewayAuth {
        client: GraphqlClient::from_env(),
        keychain: KeychainStore::from_env(),
        cached: Mutex::new(None),
    })
});

fn session_slot() -> &'static RwLock<Option<GatewaySession>> {
    &SESSION
}

/// 登录态同步入口；同一用户保留 keychain token，换用户/登出时清掉旧缓存。
pub fn set_session(session: Option<&SignedInSession>) {
    let next = session.map(|session| GatewaySession {
        token: session.token.clone(),
        user_id: session.user_id.clone(),
    });
    let previous = session_slot()
        .write()
        .ok()
        .and_then(|mut slot| std::mem::replace(&mut *slot, next));
    if let Some(previous) = previous {
        let current_user = session_slot()
            .read()
            .ok()
            .and_then(|slot| slot.as_ref().map(|session| session.user_id.clone()));
        if current_user.as_deref() != Some(previous.user_id.as_str()) {
            auth().clear_cached_token(&previous.user_id);
        }
    }
}

/// 当前进程是否持有登录会话。
pub fn signed_in() -> bool {
    session_slot()
        .read()
        .map(|slot| slot.is_some())
        .unwrap_or(false)
}

fn session() -> Option<GatewaySession> {
    session_slot().read().ok().and_then(|slot| slot.clone())
}

/// CGC Gateway 根地址：`CGC_GATEWAY_BASE_URL` 覆盖，否则由 GraphQL 端点推导并追加 `/v1`。
///
/// 端点仍走 `runtime::is_allowed_endpoint` 白名单：Bearer 与支付请求都走这条通道。
pub fn gateway_base_url() -> Option<String> {
    if let Ok(raw) = std::env::var("CGC_GATEWAY_BASE_URL") {
        let trimmed = raw.trim().trim_end_matches('/');
        if !trimmed.is_empty() && runtime::is_allowed_endpoint(trimmed) {
            return Some(trimmed.to_string());
        }
    }
    let api = runtime::api_endpoint();
    gateway_base_url_from(&api)
}

fn gateway_base_url_from(api: &str) -> Option<String> {
    let mut url = Url::parse(api).ok()?;
    if !runtime::is_allowed_endpoint(api) {
        return None;
    }
    url.set_path("/v1");
    url.set_query(None);
    url.set_fragment(None);
    Some(url.to_string().trim_end_matches('/').to_string())
}

/// 解析 `createMcpToken` 返回的 terminal token。
pub fn resolve_terminal_token() -> Result<String, GatewayError> {
    auth().resolve_terminal_token()
}

/// 401 后刷新 terminal token；调用方用返回的新 token 重发一次。
pub fn refresh_terminal_token(rejected: &str) -> Result<String, GatewayError> {
    auth().refresh_terminal_token(rejected)
}

/// 当前钱包摘要（`myLlmWallet`）。
pub fn wallet() -> Result<WalletSummary, GatewayError> {
    let session = session().ok_or(GatewayError::Unauthenticated)?;
    let value = auth()
        .client
        .post(Some(&session.token), MY_LLM_WALLET, serde_json::json!({}))?;
    parse_wallet(&value)
}

/// 创建 LLM 收银台订单并返回渠道凭据。
pub fn create_payment_order(
    order_kind: &str,
    provider: &str,
    amount_cents: i64,
    workspace_id: Option<&str>,
    idempotency_key: &str,
) -> Result<PaymentCheckout, GatewayError> {
    let session = session().ok_or(GatewayError::Unauthenticated)?;
    let value = auth().client.post(
        Some(&session.token),
        CREATE_LLM_PAYMENT_ORDER,
        json!({
            "orderKind": order_kind,
            "provider": provider,
            "amountCents": amount_cents,
            "workspaceId": workspace_id,
            "idempotencyKey": idempotency_key,
        }),
    )?;
    let checkout = value
        .get("data")
        .and_then(|data| data.get("createLlmPaymentOrder"))
        .ok_or_else(|| GatewayError::Graphql {
            code: None,
            message: "missing createLlmPaymentOrder payload".into(),
        })?;
    let order = parse_order(checkout.get("order").ok_or_else(|| GatewayError::Graphql {
        code: None,
        message: "missing LLM payment order".into(),
    })?)?;
    Ok(PaymentCheckout {
        order,
        credential: checkout.get("credential").cloned().unwrap_or(Value::Null),
    })
}

/// 轮询 LLM 收银台订单状态。
pub fn payment_order(id: &str) -> Result<PaymentOrderSummary, GatewayError> {
    let session = session().ok_or(GatewayError::Unauthenticated)?;
    let value = auth()
        .client
        .post(Some(&session.token), LLM_PAYMENT_ORDER, json!({ "id": id }))?;
    let order = value
        .get("data")
        .and_then(|data| data.get("llmPaymentOrder"))
        .ok_or_else(|| GatewayError::Graphql {
            code: None,
            message: "missing llmPaymentOrder payload".into(),
        })?;
    parse_order(order)
}

struct GatewayAuth {
    client: GraphqlClient,
    keychain: KeychainStore,
    cached: Mutex<Option<String>>,
}

fn auth() -> &'static Arc<GatewayAuth> {
    &AUTH
}

impl GatewayAuth {
    fn resolve_terminal_token(&self) -> Result<String, GatewayError> {
        let session = session().ok_or(GatewayError::Unauthenticated)?;
        if let Some(token) = self.cached.lock().ok().and_then(|token| token.clone()) {
            return Ok(token);
        }
        let account = token_account(&session.user_id);
        if let Some(token) = self
            .keychain
            .load_secret(&account)
            .filter(|t| !t.is_empty())
        {
            if let Ok(mut cached) = self.cached.lock() {
                *cached = Some(token.clone());
            }
            return Ok(token);
        }
        let token = self.issue_token(&session)?;
        if let Ok(mut cached) = self.cached.lock() {
            *cached = Some(token.clone());
        }
        let _ = self.keychain.save_secret(&account, &token);
        Ok(token)
    }

    fn refresh_terminal_token(&self, _rejected: &str) -> Result<String, GatewayError> {
        let session = session().ok_or(GatewayError::Unauthenticated)?;
        self.clear_cached_token(&session.user_id);
        let token = self.issue_token(&session)?;
        if let Ok(mut cached) = self.cached.lock() {
            *cached = Some(token.clone());
        }
        let _ = self
            .keychain
            .save_secret(&token_account(&session.user_id), &token);
        Ok(token)
    }

    fn issue_token(&self, session: &GatewaySession) -> Result<String, GatewayError> {
        let value = self.client.post(
            Some(&session.token),
            CREATE_MCP_TOKEN,
            json!({ "name": GATEWAY_TOKEN_NAME }),
        )?;
        let payload = value
            .get("data")
            .and_then(|data| data.get("createMcpToken"))
            .ok_or_else(|| GatewayError::Graphql {
                code: None,
                message: "missing createMcpToken payload".into(),
            })?;
        if let Some(errors) = payload.get("errors").and_then(Value::as_array) {
            if let Some(first) = errors.first() {
                return Err(GatewayError::Graphql {
                    code: first
                        .get("code")
                        .and_then(Value::as_str)
                        .map(str::to_string),
                    message: first
                        .get("message")
                        .and_then(Value::as_str)
                        .unwrap_or("createMcpToken failed")
                        .to_string(),
                });
            }
        }
        payload
            .get("plainToken")
            .and_then(Value::as_str)
            .filter(|token| !token.is_empty())
            .map(str::to_string)
            .ok_or_else(|| GatewayError::Graphql {
                code: None,
                message: "createMcpToken returned no plainToken".into(),
            })
    }

    fn clear_cached_token(&self, user_id: &str) {
        if let Ok(mut cached) = self.cached.lock() {
            *cached = None;
        }
        let _ = self.keychain.clear_secret(&token_account(user_id));
    }
}

fn token_account(user_id: &str) -> String {
    format!("gateway_terminal_mcp_token:{user_id}")
}

fn parse_wallet(value: &Value) -> Result<WalletSummary, GatewayError> {
    let wallet = value
        .get("data")
        .and_then(|data| data.get("myLlmWallet"))
        .ok_or_else(|| GatewayError::Graphql {
            code: None,
            message: "missing myLlmWallet payload".into(),
        })?;
    Ok(WalletSummary {
        wallet_id: string_field(wallet, "walletId")?,
        cached_balance_mc: int_field(wallet, "cachedBalanceMc")?,
        held_mc: int_field(wallet, "heldMc")?,
        available_mc: int_field(wallet, "availableMc")?,
        max_concurrent_streams: int_field(wallet, "maxConcurrentStreams")?,
        status: string_field(wallet, "status")?,
        remaining_percentage: int_field(wallet, "remainingPercentage")?,
        active_grants: wallet
            .get("activeGrants")
            .and_then(Value::as_array)
            .map(|grants| {
                grants
                    .iter()
                    .filter_map(|grant| {
                        Some(WalletGrant {
                            id: grant.get("id")?.as_str()?.to_string(),
                            source_type: grant.get("sourceType")?.as_str()?.to_string(),
                            initial_mc: grant.get("initialMc")?.as_i64()?,
                            remaining_mc: grant.get("remainingMc")?.as_i64()?,
                            expires_at: grant
                                .get("expiresAt")
                                .and_then(Value::as_str)
                                .map(str::to_string),
                            status: grant.get("status")?.as_str()?.to_string(),
                        })
                    })
                    .collect()
            })
            .unwrap_or_default(),
    })
}

fn parse_order(value: &Value) -> Result<PaymentOrderSummary, GatewayError> {
    Ok(PaymentOrderSummary {
        id: string_field(value, "id")?,
        workspace_id: value
            .get("workspaceId")
            .and_then(Value::as_str)
            .map(str::to_string),
        order_kind: string_field(value, "orderKind")?,
        provider: string_field(value, "provider")?,
        out_trade_no: string_field(value, "outTradeNo")?,
        amount_cents: int_field(value, "amountCents")?,
        credits_mc: int_field(value, "creditsMc")?,
        status: string_field(value, "status")?,
        expires_at: value
            .get("expiresAt")
            .and_then(Value::as_str)
            .map(str::to_string),
        paid_at: value
            .get("paidAt")
            .and_then(Value::as_str)
            .map(str::to_string),
    })
}

fn string_field(value: &Value, key: &str) -> Result<String, GatewayError> {
    value
        .get(key)
        .and_then(Value::as_str)
        .map(str::to_string)
        .ok_or_else(|| GatewayError::Graphql {
            code: None,
            message: format!("missing {key}"),
        })
}

fn int_field(value: &Value, key: &str) -> Result<i64, GatewayError> {
    value
        .get(key)
        .and_then(Value::as_i64)
        .ok_or_else(|| GatewayError::Graphql {
            code: None,
            message: format!("missing {key}"),
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gateway_base_url_is_derived_from_api_endpoint() {
        assert_eq!(
            gateway_base_url_from("https://api.codingirlsclub.com/api/graphql"),
            Some("https://api.codingirlsclub.com/v1".to_string())
        );
        assert_eq!(
            gateway_base_url_from("http://localhost:4000/api/graphql"),
            Some("http://localhost:4000/v1".to_string())
        );
        assert_eq!(
            gateway_base_url_from("https://evil.example/api/graphql"),
            None
        );
    }

    #[test]
    fn wallet_payload_parses_numeric_fields() {
        let value = json!({
            "data": {"myLlmWallet": {
                "walletId": "w1",
                "cachedBalanceMc": 100,
                "heldMc": 10,
                "availableMc": 90,
                "maxConcurrentStreams": 3,
                "status": "active",
                "remainingPercentage": 50,
                "activeGrants": [{
                    "id": "g1", "sourceType": "pack", "initialMc": 100,
                    "remainingMc": 100, "expiresAt": null, "status": "active"
                }]
            }}
        });
        let wallet = parse_wallet(&value).expect("wallet");
        assert_eq!(wallet.available_mc, 90);
        assert_eq!(wallet.active_grants.len(), 1);
    }
}
