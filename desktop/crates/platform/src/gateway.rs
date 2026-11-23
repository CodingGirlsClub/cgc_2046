//! CGC Cloud managed gateway 客户端（Phase 4）。
//!
//! `/v1/chat/completions` 使用第一方登录会话 Bearer（`SignedInSession` JWT）。
//! 这条会话本来就用于同域 GraphQL，`/v1` 与 `/mcp` 鉴权物理隔离：桌面端不再
//! 自动签发 terminal MCP token，也不会把学习型 `learning_host` lease 带进算力消费。
//!
//! 同一模块承载 `myLlmWallet`、`createLlmPaymentOrder`、`llmPaymentOrder` 的
//! GraphQL 读写，供 native agent 状态栏与 402 续费卡使用。

use std::sync::{Condvar, LazyLock, Mutex, MutexGuard, RwLock};

use serde_json::{json, Value};
use url::Url;

use crate::api::{ApiError, GraphqlClient};
use crate::runtime;
use crate::session::SignedInSession;

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

const AVAILABLE_LLM_MODELS: &str = r#"query AvailableLlmModels {
  availableLlmModels {
    modelId
    displayName
    contextWindow
    maxOutputTokens
    supportsThinking
    supportsTools
    supportsImages
    reasoningEfforts
    inputPriceMc
    cacheHitPriceMc
    outputPriceMc
  }
}"#;

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

/// 登录会话快照；由 `SessionService` 在登录/恢复/登出时同步到全局。
#[derive(Clone, PartialEq, Eq)]
struct GatewaySession {
    token: String,
    user_id: String,
}

impl std::fmt::Debug for GatewaySession {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("GatewaySession")
            .field("token", &"<redacted>")
            .field("user_id", &self.user_id)
            .finish()
    }
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
            ApiError::UpgradeRequired(notice) => Self::Transport(notice.message),
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

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GatewayModel {
    pub model_id: String,
    pub display_name: String,
    pub context_window: u32,
    pub max_output_tokens: u32,
    pub supports_thinking: bool,
    pub supports_tools: bool,
    pub supports_images: bool,
    pub reasoning_efforts: Vec<String>,
    pub input_price_mc: i64,
    pub cache_hit_price_mc: i64,
    pub output_price_mc: i64,
}

static SESSION: LazyLock<RwLock<Option<GatewaySession>>> = LazyLock::new(|| RwLock::new(None));
static GATEWAY_CATALOG: LazyLock<GatewayCatalog> = LazyLock::new(|| GatewayCatalog {
    state: Mutex::new(GatewayCatalogState::default()),
    finished: Condvar::new(),
});

#[derive(Clone, Debug, Default)]
struct GatewayCatalogState {
    models: Vec<GatewayModel>,
    fetched_at: Option<u64>,
    last_error: Option<String>,
    syncing: bool,
}

/// 目录缓存 + 同步完成通知：并发调用者等待正在进行的请求，而不是拿旧缓存提前返回。
struct GatewayCatalog {
    state: Mutex<GatewayCatalogState>,
    finished: Condvar,
}

/// 目录同步快照：供 Settings 卡片区分「同步中 / 空目录 / 失败」。
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct GatewayCatalogStatus {
    pub models: Vec<GatewayModel>,
    pub fetched_at: Option<u64>,
    pub last_error: Option<String>,
    pub syncing: bool,
}

fn catalog_cache_path() -> std::path::PathBuf {
    crate::paths::AppPaths::from_env().gateway_models_cache_file()
}

fn model_json(model: &GatewayModel) -> Value {
    json!({
        "modelId": model.model_id,
        "displayName": model.display_name,
        "contextWindow": model.context_window,
        "maxOutputTokens": model.max_output_tokens,
        "supportsThinking": model.supports_thinking,
        "supportsTools": model.supports_tools,
        "supportsImages": model.supports_images,
        "reasoningEfforts": model.reasoning_efforts,
        "inputPriceMc": model.input_price_mc,
        "cacheHitPriceMc": model.cache_hit_price_mc,
        "outputPriceMc": model.output_price_mc,
    })
}

enum CatalogCacheAction {
    Write(String),
    Remove,
}

fn catalog_cache_action(
    user_id: &str,
    fetched_at: u64,
    models: &[GatewayModel],
) -> CatalogCacheAction {
    match cached_catalog_json(user_id, fetched_at, models) {
        Some(raw) => CatalogCacheAction::Write(raw),
        None => CatalogCacheAction::Remove,
    }
}

fn cached_catalog_json(user_id: &str, fetched_at: u64, models: &[GatewayModel]) -> Option<String> {
    if models.is_empty() {
        return None;
    }
    let models: Vec<Value> = models.iter().map(model_json).collect();
    serde_json::to_string(&json!({
        "user_id": user_id,
        "fetched_at": fetched_at,
        "models": models,
    }))
    .ok()
}

fn parse_cached_catalog(raw: &str, user_id: &str) -> Option<(Vec<GatewayModel>, u64)> {
    let value: Value = serde_json::from_str(raw).ok()?;
    if value.get("user_id").and_then(Value::as_str) != Some(user_id) {
        return None;
    }
    let fetched_at = value.get("fetched_at").and_then(Value::as_u64)?;
    let payload = json!({"data": {"availableLlmModels": value.get("models")?.clone()}});
    let models = parse_models(&payload).ok()?;
    (!models.is_empty()).then_some((models, fetched_at))
}

fn load_cached_catalog(user_id: &str) -> Option<(Vec<GatewayModel>, u64)> {
    let raw = std::fs::read_to_string(catalog_cache_path()).ok()?;
    parse_cached_catalog(&raw, user_id)
}

fn persist_catalog(user_id: &str, models: &[GatewayModel], fetched_at: u64) {
    let path = catalog_cache_path();
    match catalog_cache_action(user_id, fetched_at, models) {
        // 成功但为空：删除旧快照，避免重启后恢复已被撤下的模型。
        CatalogCacheAction::Remove => {
            let _ = std::fs::remove_file(&path);
        }
        CatalogCacheAction::Write(raw) => {
            let Some(parent) = path.parent() else {
                return;
            };
            if std::fs::create_dir_all(parent).is_err() {
                return;
            }
            let temp_path = path.with_extension("json.tmp");
            if std::fs::write(&temp_path, raw).is_ok() {
                let _ = std::fs::rename(&temp_path, &path);
            }
        }
    }
}

/// 登出时清空内存目录并删除本地快照；下一次登录按 user_id 恢复。
pub fn clear_catalog_cache() {
    reset_catalog();
    let _ = std::fs::remove_file(catalog_cache_path());
}

fn session_slot() -> &'static RwLock<Option<GatewaySession>> {
    &SESSION
}

fn catalog() -> &'static GatewayCatalog {
    &GATEWAY_CATALOG
}

fn catalog_state() -> MutexGuard<'static, GatewayCatalogState> {
    catalog()
        .state
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn now_unix() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .unwrap_or_default()
}

/// 读取最近一次从后端同步到的官方网关模型列表。
pub fn cached_models() -> Vec<GatewayModel> {
    catalog_state().models.clone()
}

/// 读取目录同步状态（模型、同步时间、最近错误、是否进行中）。
pub fn catalog_status() -> GatewayCatalogStatus {
    let slot = catalog_state();
    GatewayCatalogStatus {
        models: slot.models.clone(),
        fetched_at: slot.fetched_at,
        last_error: slot.last_error.clone(),
        syncing: slot.syncing,
    }
}

/// 更新内存中的官方网关模型缓存（测试与恢复缓存用）。
pub fn set_cached_models(models: Vec<GatewayModel>) {
    let fetched_at = (!models.is_empty()).then(now_unix);
    restore_catalog(models, fetched_at);
}

fn restore_catalog(models: Vec<GatewayModel>, fetched_at: Option<u64>) {
    let mut slot = catalog_state();
    slot.models = models;
    slot.fetched_at = fetched_at;
    slot.last_error = None;
}

fn reset_catalog() {
    let mut slot = catalog_state();
    slot.models.clear();
    slot.fetched_at = None;
    slot.last_error = None;
}

/// 登录态同步入口；只保留当前会话 token，不派生或持久化第二份凭据。
pub fn set_session(session: Option<&SignedInSession>) {
    let user_changed = if let Ok(mut slot) = session_slot().write() {
        let user_changed = match (slot.as_ref(), session) {
            (_, None) => true,
            (Some(prev), Some(next)) => prev.user_id != next.user_id,
            (None, Some(_)) => true,
        };
        *slot = session.map(|session| GatewaySession {
            token: session.token.clone(),
            user_id: session.user_id.clone(),
        });
        user_changed
    } else {
        session.is_none()
    };
    if user_changed {
        match session.and_then(|next| load_cached_catalog(&next.user_id)) {
            Some((models, fetched_at)) => restore_catalog(models, Some(fetched_at)),
            None => reset_catalog(),
        }
    }
}

/// 当前登录账号 id（不含 token）；用于丢弃跨账号的异步响应。
pub fn current_user_id() -> Option<String> {
    session().map(|session| session.user_id)
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

/// 单飞：正在同步时后来者等待同一次请求结束，再依次拉取，避免返回旧缓存后
/// 调用方把 `syncing = true` 写进自己的 UI 状态而永远等不到完成通知。
struct CatalogSyncGuard;

impl CatalogSyncGuard {
    fn acquire() -> Self {
        let mut slot = catalog_state();
        while slot.syncing {
            slot = catalog()
                .finished
                .wait(slot)
                .unwrap_or_else(|poisoned| poisoned.into_inner());
        }
        slot.syncing = true;
        Self
    }
}

impl Drop for CatalogSyncGuard {
    fn drop(&mut self) {
        {
            let mut slot = catalog_state();
            slot.syncing = false;
        }
        catalog().finished.notify_all();
    }
}

/// `/v1/chat/completions` 的 Bearer：直接复用当前登录会话 JWT。
pub fn gateway_token() -> Result<String, GatewayError> {
    session()
        .map(|session| session.token)
        .ok_or(GatewayError::Unauthenticated)
}

fn graphql_client() -> GraphqlClient {
    GraphqlClient::from_env()
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
    gateway_base_url_from(&runtime::api_endpoint())
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

/// 拉取官方网关当前可用模型目录并更新本地内存缓存。
///
/// 已有同步在途时等待它结束后再拉取；失败保留上次成功的目录，
/// 只记录 `last_error`，供 Settings 展示。
pub fn fetch_models() -> Result<Vec<GatewayModel>, GatewayError> {
    let _guard = CatalogSyncGuard::acquire();
    let active_session = session().ok_or(GatewayError::Unauthenticated)?;
    let result = (|| {
        let value = graphql_client().post(
            Some(&active_session.token),
            AVAILABLE_LLM_MODELS,
            serde_json::json!({}),
        )?;
        parse_models(&value)
    })();
    if session().as_ref().is_some_and(|cur| {
        cur.user_id == active_session.user_id && cur.token == active_session.token
    }) {
        apply_catalog_fetch_result(&result);
        if let Ok(models) = &result {
            persist_catalog(&active_session.user_id, models, now_unix());
        }
    }
    result
}

fn apply_catalog_fetch_result(result: &Result<Vec<GatewayModel>, GatewayError>) {
    let mut slot = catalog_state();
    match result {
        Ok(models) => {
            slot.models = models.clone();
            slot.fetched_at = Some(now_unix());
            slot.last_error = None;
        }
        Err(error) => slot.last_error = Some(error.diagnostic()),
    }
}

/// 当前钱包摘要（`myLlmWallet`）。
pub fn wallet() -> Result<WalletSummary, GatewayError> {
    let session = session().ok_or(GatewayError::Unauthenticated)?;
    let value =
        graphql_client().post(Some(&session.token), MY_LLM_WALLET, serde_json::json!({}))?;
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
    let value = graphql_client().post(
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
    let value =
        graphql_client().post(Some(&session.token), LLM_PAYMENT_ORDER, json!({ "id": id }))?;
    let order = value
        .get("data")
        .and_then(|data| data.get("llmPaymentOrder"))
        .ok_or_else(|| GatewayError::Graphql {
            code: None,
            message: "missing llmPaymentOrder payload".into(),
        })?;
    parse_order(order)
}

fn parse_models(value: &Value) -> Result<Vec<GatewayModel>, GatewayError> {
    let items = value
        .get("data")
        .and_then(|data| data.get("availableLlmModels"))
        .and_then(Value::as_array)
        .ok_or_else(|| GatewayError::Graphql {
            code: None,
            message: "missing availableLlmModels payload".into(),
        })?;
    items.iter().map(parse_model).collect()
}

fn parse_model(value: &Value) -> Result<GatewayModel, GatewayError> {
    let context_window_i64 = int_field(value, "contextWindow")?;
    let max_output_i64 = int_field(value, "maxOutputTokens")?;
    let context_window = u32::try_from(context_window_i64).map_err(|_| GatewayError::Graphql {
        code: None,
        message: "invalid contextWindow".into(),
    })?;
    let max_output_tokens = u32::try_from(max_output_i64).map_err(|_| GatewayError::Graphql {
        code: None,
        message: "invalid maxOutputTokens".into(),
    })?;
    Ok(GatewayModel {
        model_id: string_field(value, "modelId")?,
        display_name: string_field(value, "displayName")?,
        context_window,
        max_output_tokens,
        supports_thinking: bool_field(value, "supportsThinking")?,
        supports_tools: bool_field(value, "supportsTools")?,
        supports_images: bool_field(value, "supportsImages")?,
        reasoning_efforts: string_array_field(value, "reasoningEfforts")?,
        input_price_mc: bigint_field(value, "inputPriceMc")?,
        cache_hit_price_mc: bigint_field(value, "cacheHitPriceMc")?,
        output_price_mc: bigint_field(value, "outputPriceMc")?,
    })
}

fn bool_field(value: &Value, key: &str) -> Result<bool, GatewayError> {
    value
        .get(key)
        .and_then(Value::as_bool)
        .ok_or_else(|| GatewayError::Graphql {
            code: None,
            message: format!("missing {key}"),
        })
}

fn string_array_field(value: &Value, key: &str) -> Result<Vec<String>, GatewayError> {
    let items = value
        .get(key)
        .and_then(Value::as_array)
        .ok_or_else(|| GatewayError::Graphql {
            code: None,
            message: format!("missing {key}"),
        })?;
    items
        .iter()
        .map(|entry| {
            entry
                .as_str()
                .map(str::to_string)
                .ok_or_else(|| GatewayError::Graphql {
                    code: None,
                    message: format!("invalid {key} entry"),
                })
        })
        .collect()
}

fn bigint_field(value: &Value, key: &str) -> Result<i64, GatewayError> {
    let field = value.get(key).ok_or_else(|| GatewayError::Graphql {
        code: None,
        message: format!("missing {key}"),
    })?;
    if let Some(num) = field.as_i64() {
        return Ok(num);
    }
    if let Some(text) = field.as_str() {
        if let Ok(num) = text.parse::<i64>() {
            return Ok(num);
        }
    }
    Err(GatewayError::Graphql {
        code: None,
        message: format!("invalid {key}"),
    })
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

    fn test_state_lock() -> std::sync::MutexGuard<'static, ()> {
        static LOCK: LazyLock<std::sync::Mutex<()>> = LazyLock::new(|| std::sync::Mutex::new(()));
        LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn sample_gateway_models() -> Vec<GatewayModel> {
        vec![GatewayModel {
            model_id: "deepseek-chat".to_string(),
            display_name: "DeepSeek Chat".to_string(),
            context_window: 128_000,
            max_output_tokens: 8_192,
            supports_thinking: false,
            supports_tools: true,
            supports_images: false,
            reasoning_efforts: Vec::new(),
            input_price_mc: 3_000_000,
            cache_hit_price_mc: 300_000,
            output_price_mc: 4_500_000,
        }]
    }

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

    #[test]
    fn wallet_and_order_payloads_parse_64bit_bigint_fields() {
        let large_mc: i64 = 5_000_000_000;
        let half_mc: i64 = 2_500_000_000;
        assert!(large_mc > i64::from(i32::MAX));

        let wallet_value = json!({
            "data": {"myLlmWallet": {
                "walletId": "w-big",
                "cachedBalanceMc": large_mc,
                "heldMc": half_mc,
                "availableMc": half_mc,
                "maxConcurrentStreams": 3,
                "status": "active",
                "remainingPercentage": 100,
                "activeGrants": [{
                    "id": "g-big",
                    "sourceType": "workspace_grant",
                    "initialMc": large_mc,
                    "remainingMc": large_mc,
                    "expiresAt": null,
                    "status": "active"
                }]
            }}
        });
        let wallet = parse_wallet(&wallet_value).expect("64-bit wallet");
        assert_eq!(wallet.cached_balance_mc, large_mc);
        assert_eq!(wallet.held_mc, half_mc);
        assert_eq!(wallet.available_mc, half_mc);
        assert_eq!(wallet.active_grants.len(), 1);
        assert_eq!(wallet.active_grants[0].initial_mc, large_mc);
        assert_eq!(wallet.active_grants[0].remaining_mc, large_mc);

        let order_value = json!({
            "id": "ord-big",
            "workspaceId": "ws-1",
            "orderKind": "llm_workspace_pool_topup",
            "provider": "wechat_native",
            "outTradeNo": "LLM_0123456789abcdef0123456789ab",
            "amountCents": 500_000,
            "creditsMc": large_mc,
            "status": "pending",
            "expiresAt": null,
            "paidAt": null
        });
        let order = parse_order(&order_value).expect("64-bit order");
        assert_eq!(order.amount_cents, 500_000);
        assert_eq!(order.credits_mc, large_mc);
    }

    #[test]
    fn gateway_session_debug_redacts_login_token() {
        let token = concat!("dummy", "-", "fixture");
        let session = GatewaySession {
            token: token.to_string(),
            user_id: "user-1".to_string(),
        };
        let debug = format!("{session:?}");
        assert!(!debug.contains(token));
        assert!(debug.contains("<redacted>"));
    }

    #[test]
    fn available_llm_models_payload_parses_capabilities_and_bigint_prices() {
        let large_price_mc: i64 = 5_000_000_000;
        let payload = json!({
            "data": {
                "availableLlmModels": [
                    {
                        "modelId": "deepseek-reasoner",
                        "displayName": "DeepSeek Reasoner",
                        "contextWindow": 128000,
                        "maxOutputTokens": 32768,
                        "supportsThinking": true,
                        "supportsTools": true,
                        "supportsImages": false,
                        "reasoningEfforts": ["low", "high"],
                        "inputPriceMc": large_price_mc,
                        "cacheHitPriceMc": 300000,
                        "outputPriceMc": "6000000000"
                    }
                ]
            }
        });
        let models = parse_models(&payload).expect("models");
        assert_eq!(models.len(), 1);
        assert_eq!(models[0].model_id, "deepseek-reasoner");
        assert_eq!(models[0].display_name, "DeepSeek Reasoner");
        assert_eq!(models[0].context_window, 128_000);
        assert_eq!(models[0].max_output_tokens, 32_768);
        assert!(models[0].supports_thinking);
        assert!(models[0].supports_tools);
        assert!(!models[0].supports_images);
        assert_eq!(models[0].reasoning_efforts, vec!["low", "high"]);
        assert_eq!(models[0].input_price_mc, large_price_mc);
        assert_eq!(models[0].cache_hit_price_mc, 300_000);
        assert_eq!(models[0].output_price_mc, 6_000_000_000);
    }

    #[test]
    fn catalog_failure_keeps_previous_models_and_records_error() {
        let _lock = test_state_lock();
        let sample = sample_gateway_models();
        set_cached_models(sample.clone());
        let fetched_at = catalog_status().fetched_at;
        assert!(fetched_at.is_some());

        apply_catalog_fetch_result(&Err(GatewayError::Transport("offline".into())));

        let status = catalog_status();
        assert_eq!(status.models, sample);
        assert_eq!(status.fetched_at, fetched_at);
        assert!(status
            .last_error
            .as_deref()
            .is_some_and(|error| error.contains("offline")));
    }

    #[test]
    fn catalog_sync_guard_waits_for_in_flight_fetch() {
        let _lock = test_state_lock();
        reset_catalog();
        let first = CatalogSyncGuard::acquire();
        assert!(catalog_status().syncing);

        let (tx, rx) = std::sync::mpsc::channel();
        let waiter = std::thread::spawn(move || {
            let _guard = CatalogSyncGuard::acquire();
            tx.send(()).expect("notify acquired");
        });
        assert!(
            rx.recv_timeout(std::time::Duration::from_millis(150))
                .is_err(),
            "second caller must wait for the first fetch"
        );
        drop(first);
        rx.recv_timeout(std::time::Duration::from_secs(2))
            .expect("second caller proceeds after completion");
        waiter.join().expect("waiter thread");
        assert!(!catalog_status().syncing);
    }

    #[test]
    fn current_user_id_tracks_account_switches() {
        let _lock = test_state_lock();
        let session_a = SignedInSession {
            token: "tok-a".to_string(),
            user_id: "user-a".to_string(),
            email: None,
            is_platform_admin: false,
        };
        let session_b = SignedInSession {
            token: "tok-b".to_string(),
            user_id: "user-b".to_string(),
            email: None,
            is_platform_admin: false,
        };
        set_session(Some(&session_a));
        assert_eq!(current_user_id().as_deref(), Some("user-a"));
        set_session(Some(&session_b));
        assert_eq!(current_user_id().as_deref(), Some("user-b"));
        set_session(None);
        assert!(current_user_id().is_none());
    }

    #[test]
    fn empty_successful_fetch_invalidates_the_persisted_catalog() {
        assert!(matches!(
            catalog_cache_action("user-a", 1, &[]),
            CatalogCacheAction::Remove
        ));
        assert!(matches!(
            catalog_cache_action("user-a", 1, &sample_gateway_models()),
            CatalogCacheAction::Write(_)
        ));
    }

    #[test]
    fn cached_catalog_restores_only_for_matching_user() {
        let _lock = test_state_lock();
        let raw =
            cached_catalog_json("user-a", 42, &sample_gateway_models()).expect("serialize cache");

        let (models, fetched_at) = parse_cached_catalog(&raw, "user-a").expect("matching user");
        assert_eq!(models, sample_gateway_models());
        assert_eq!(fetched_at, 42);
        assert!(parse_cached_catalog(&raw, "user-b").is_none());

        assert!(cached_catalog_json("user-a", 42, &[]).is_none());
    }

    #[test]
    fn catalog_success_clears_error_and_updates_fetched_at() {
        let _lock = test_state_lock();
        reset_catalog();
        apply_catalog_fetch_result(&Err(GatewayError::Transport("offline".into())));
        assert!(catalog_status().last_error.is_some());

        let sample = sample_gateway_models();
        apply_catalog_fetch_result(&Ok(sample.clone()));

        let status = catalog_status();
        assert_eq!(status.models, sample);
        assert!(status.fetched_at.is_some());
        assert!(status.last_error.is_none());
    }

    #[test]
    fn set_session_clears_cached_models_on_sign_out_and_account_switch() {
        let _lock = test_state_lock();
        let session_a = SignedInSession {
            token: "tok-a".to_string(),
            user_id: "user-a".to_string(),
            email: None,
            is_platform_admin: false,
        };
        let session_b = SignedInSession {
            token: "tok-b".to_string(),
            user_id: "user-b".to_string(),
            email: None,
            is_platform_admin: false,
        };
        let sample = vec![GatewayModel {
            model_id: "deepseek-chat".to_string(),
            display_name: "DeepSeek Chat".to_string(),
            context_window: 128_000,
            max_output_tokens: 8_192,
            supports_thinking: false,
            supports_tools: true,
            supports_images: false,
            reasoning_efforts: Vec::new(),
            input_price_mc: 3_000_000,
            cache_hit_price_mc: 300_000,
            output_price_mc: 4_500_000,
        }];

        set_session(Some(&session_a));
        set_cached_models(sample.clone());
        assert_eq!(cached_models(), sample);

        // Same user token refresh preserves cached models.
        set_session(Some(&SignedInSession {
            token: "tok-a-2".to_string(),
            ..session_a
        }));
        assert_eq!(cached_models(), sample);

        // Switching user clears cached models.
        set_session(Some(&session_b));
        assert!(cached_models().is_empty());

        // Sign out clears cached models.
        set_cached_models(sample);
        set_session(None);
        assert!(cached_models().is_empty());
    }
}
