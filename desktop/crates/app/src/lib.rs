//! CGC Desktop 的 app 层：入口、导航壳与路由聚合（脊柱 AD-1 的组合根）。

pub mod agent_ingest;
pub mod build_info;
pub mod chat_state;

/// Agent 使用的工作区根目录：`CGC_AGENT_WORKSPACE` 优先，否则用进程当前目录。
pub(crate) fn agent_workspace_root() -> std::path::PathBuf {
    std::env::var("CGC_AGENT_WORKSPACE")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|_| std::env::current_dir().unwrap_or_else(|_| std::env::temp_dir()))
}
pub(crate) mod agent_scope;
pub mod deep_link;
pub mod formula;
pub mod i18n;
pub mod mention;
pub mod native_agent_view;
pub mod notification_center;
pub mod notifications;
pub mod preferences;
pub mod qr;
pub mod registration;
pub mod root_view;
pub mod routing;
pub(crate) mod settings_provider;
pub mod settings_window;
pub mod theme;
pub mod workspace_state;
