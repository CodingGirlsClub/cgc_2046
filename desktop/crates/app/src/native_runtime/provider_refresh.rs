//! 网关目录与 native runtime 的统一刷新顺序。
//!
//! 拉目录必须走 background executor；runtime 刷新由 actor 串行执行。
//! 调用方只负责把两个结果映射成自己的提示，避免三处各写一遍顺序。

use std::future::Future;

use cgc_platform::gateway::{GatewayError, GatewayModel};

use super::{NativeRuntimeError, NativeRuntimeHandle};

#[derive(Debug)]
pub(crate) struct CatalogRefreshOutcome {
    /// `None` 表示本次未拉取目录（未登录），不是失败。
    pub(crate) catalog: Option<Result<Vec<GatewayModel>, GatewayError>>,
    pub(crate) runtime: Result<(), NativeRuntimeError>,
}

/// 先等目录请求结束，再让 runtime 重新读取 provider/model 选择。
pub(crate) async fn refresh_catalog_and_providers<F>(
    runtime: NativeRuntimeHandle,
    catalog: Option<F>,
) -> CatalogRefreshOutcome
where
    F: Future<Output = Result<Vec<GatewayModel>, GatewayError>> + Send,
{
    let catalog = match catalog {
        Some(catalog) => Some(catalog.await),
        None => None,
    };
    let runtime = runtime.refresh_providers().await.map(|_| ());
    CatalogRefreshOutcome { catalog, runtime }
}
