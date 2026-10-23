use std::sync::Arc;

use serde::{Deserialize, Serialize};

/// agent 对客户端发起的应用内动作（P1a AppAction）。
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub enum AppAction {
    /// 打开应用内路由（仅 `/` 开头，禁止外部 URL）。
    OpenPage { route: String },
    /// 高亮工作区文件的某段行。
    HighlightRange {
        path: String,
        start_line: u32,
        end_line: u32,
    },
}

impl AppAction {
    pub fn summary(&self) -> String {
        match self {
            Self::OpenPage { route } => format!("打开页面 {route}"),
            Self::HighlightRange {
                path,
                start_line,
                end_line,
            } => format!("高亮 {path}:{start_line}-{end_line}"),
        }
    }
}

/// 向客户端投递动作的出口；由 UI 提供实现。
pub type ActionSink = Arc<dyn Fn(AppAction) + Send + Sync>;
