//! CGC Desktop 的 app 层：入口、导航壳与路由聚合（脊柱 AD-1 的组合根）。

#![recursion_limit = "512"]
pub mod acp_history;
pub mod agent_ingest;
pub mod approval_rules;
pub mod attachment;
pub mod build_info;
pub mod chat_state;

/// Agent 使用的工作区根目录：`CGC_AGENT_WORKSPACE` 优先，否则用进程当前目录。
pub(crate) fn agent_workspace_root() -> std::path::PathBuf {
    std::env::var("CGC_AGENT_WORKSPACE")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|_| std::env::current_dir().unwrap_or_else(|_| std::env::temp_dir()))
}
pub(crate) mod agent_scope;
pub mod conversation_session;
pub mod deep_link;
pub mod formula;
pub mod i18n;
pub mod icons;
pub mod image_viewer;
pub mod mention;
pub mod mention_chip;
pub mod native_agent_view;
pub mod native_context;
pub mod native_panel_host;
pub mod native_runtime;
pub mod native_view_model;
pub mod notification_center;
pub mod notifications;
pub mod page_context;
pub mod permission_ui;
pub mod preferences;
pub mod qr;
pub mod registration;
pub mod root_view;
pub mod routing;
pub(crate) mod settings_provider;
pub mod settings_window;
pub mod theme;
pub mod user_settings;
pub mod workspace_state;
