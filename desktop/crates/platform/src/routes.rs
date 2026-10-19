//! 路由契约：domain crate 用它在自己的 `registration` 模块里声明路由，
//! app 只做聚合与校验（脊柱 AD-9 的注册式 seam）。
//!
//! 路径暂不支持动态段（含 `:` 的路径会被注册表拒绝），等确有需要再设计；
//! 这样「动态路由遮蔽」不会在无校验的情况下悄悄出现。

/// 一条可注册的路由：稳定 id、路径与标题词表 key。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Route {
    pub id: &'static str,
    pub path: &'static str,
    pub title_key: &'static str,
}

impl Route {
    pub const fn new(id: &'static str, path: &'static str, title_key: &'static str) -> Self {
        Self {
            id,
            path,
            title_key,
        }
    }

    /// 动态路由段（`:`）在 v1 未支持：注册表据此拒绝，避免遮蔽规则未定义。
    pub fn has_dynamic_segment(&self) -> bool {
        self.path.split('/').any(|segment| segment.starts_with(':'))
    }
}
