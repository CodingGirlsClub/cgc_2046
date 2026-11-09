//! R2 回归：列表迟到响应的落地判定（纯函数，不需要 UI gate）。
//!
//! 三个分支对应三种真实场景：更新的请求在途（只丢弃）、scope/epoch 越界（丢弃并复位
//! 闸门）、代次与 scope 都匹配（落地）。账号代数（session epoch）越界的公开面响应
//! 同样丢弃并复位——公开路由没有 workspace epoch 可依赖。

use super::{list_response_disposition, ListResponseDisposition};
use crate::routing::ListScope;

#[test]
fn stale_generation_does_not_apply_to_newer_request() {
    assert_eq!(
        list_response_disposition(
            7,
            6,
            Some(ListScope::Public),
            ListScope::Public,
            None,
            true,
            true
        ),
        ListResponseDisposition::Ignore,
        "有更新的请求在途时，旧代次的响应不得落地"
    );
}

#[test]
fn stale_callback_does_not_reset_newer_request() {
    // 代次过期时连复位都不许做：`courses.reset()` 会把在途的新请求打回 Idle 并触发重复拉取。
    assert_eq!(
        list_response_disposition(
            2,
            1,
            Some(ListScope::Workspace),
            ListScope::Workspace,
            Some(3),
            false,
            true
        ),
        ListResponseDisposition::Ignore,
        "旧代次回调不得复位新请求的状态机"
    );
}

#[test]
fn cross_scope_or_stale_epoch_response_is_discarded_and_resets() {
    assert_eq!(
        list_response_disposition(1, 1, None, ListScope::Workspace, Some(4), true, true),
        ListResponseDisposition::DiscardAndReset,
        "工作区→公开的反向切换会清空列表 scope，迟到的公开响应不得串台"
    );
    assert_eq!(
        list_response_disposition(
            1,
            1,
            Some(ListScope::Workspace),
            ListScope::Workspace,
            Some(4),
            false,
            true
        ),
        ListResponseDisposition::DiscardAndReset,
        "epoch 前移后工作区列表响应越界，丢弃并复位闸门"
    );
    assert_eq!(
        list_response_disposition(
            1,
            1,
            Some(ListScope::Public),
            ListScope::Public,
            None,
            true,
            true
        ),
        ListResponseDisposition::Apply,
        "代次与完整 scope 都匹配时才落地（公开面 epoch 恒为 None）"
    );
}

#[test]
fn signed_out_response_is_discarded_even_on_public_routes() {
    // 公开面没有 workspace epoch 可拦；登出/换账号必须在账号代数上拦住旧响应。
    assert_eq!(
        list_response_disposition(
            1,
            1,
            Some(ListScope::Public),
            ListScope::Public,
            None,
            true,
            false
        ),
        ListResponseDisposition::DiscardAndReset,
        "账号代数变化后，公开列表的迟到响应不得落地"
    );
}
