use futures::future::BoxFuture;

use crate::{
    action::AppAction,
    approval::Approval,
    error::ToolError,
    tool::{Tool, ToolContext, ToolResult},
};

/// 打开应用内页面。
pub struct OpenPageTool;

impl Tool for OpenPageTool {
    fn name(&self) -> &'static str {
        "open_page"
    }

    fn description(&self) -> &'static str {
        "Open an in-app page by route (e.g. /courses/42). External URLs are rejected."
    }

    fn schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "properties": {
                "route": { "type": "string", "description": "In-app route starting with /" }
            },
            "required": ["route"]
        })
    }

    fn approval(&self, _args: &serde_json::Value) -> Approval {
        Approval::Allow
    }

    fn run(
        &self,
        args: serde_json::Value,
        context: ToolContext,
    ) -> BoxFuture<'static, Result<ToolResult, ToolError>> {
        Box::pin(async move {
            let route = args
                .get("route")
                .and_then(|value| value.as_str())
                .ok_or_else(|| ToolError::InvalidArgs("missing route".to_string()))?;
            if !route.starts_with('/') || route.contains("://") {
                return Err(ToolError::InvalidArgs(format!(
                    "route must be an in-app path: {route}"
                )));
            }
            context.emit_action(AppAction::OpenPage {
                route: route.to_string(),
            });
            Ok(ToolResult::ok(format!("opened {route}")))
        })
    }
}

/// 高亮工作区文件的一段行。
pub struct HighlightRangeTool;

impl Tool for HighlightRangeTool {
    fn name(&self) -> &'static str {
        "highlight_range"
    }

    fn description(&self) -> &'static str {
        "Highlight a line range of a workspace file in the client."
    }

    fn schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "properties": {
                "path": { "type": "string", "description": "Workspace-relative file path" },
                "start_line": { "type": "integer", "minimum": 1 },
                "end_line": { "type": "integer", "minimum": 1 }
            },
            "required": ["path", "start_line", "end_line"]
        })
    }

    fn approval(&self, _args: &serde_json::Value) -> Approval {
        Approval::Allow
    }

    fn run(
        &self,
        args: serde_json::Value,
        context: ToolContext,
    ) -> BoxFuture<'static, Result<ToolResult, ToolError>> {
        Box::pin(async move {
            let path = args
                .get("path")
                .and_then(|value| value.as_str())
                .ok_or_else(|| ToolError::InvalidArgs("missing path".to_string()))?;
            let start_line = args
                .get("start_line")
                .and_then(|value| value.as_u64())
                .ok_or_else(|| ToolError::InvalidArgs("missing start_line".to_string()))?
                as u32;
            let end_line = args
                .get("end_line")
                .and_then(|value| value.as_u64())
                .ok_or_else(|| ToolError::InvalidArgs("missing end_line".to_string()))?
                as u32;
            if start_line == 0 || end_line < start_line {
                return Err(ToolError::InvalidArgs(
                    "line range must satisfy 1 <= start <= end".to_string(),
                ));
            }
            // 只校验路径在工作区内，不要求文件已存在（刚创建的文件也能高亮）。
            context.resolve_for_write(path)?;
            context.emit_action(AppAction::HighlightRange {
                path: path.to_string(),
                start_line,
                end_line,
            });
            Ok(ToolResult::ok(format!(
                "highlighted {path}:{start_line}-{end_line}"
            )))
        })
    }
}

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Mutex};

    use super::*;

    fn context_with_actions() -> (ToolContext, Arc<Mutex<Vec<AppAction>>>) {
        let actions = Arc::new(Mutex::new(Vec::new()));
        let sink = {
            let actions = actions.clone();
            Arc::new(move |action: AppAction| actions.lock().unwrap().push(action))
                as crate::action::ActionSink
        };
        let workspace = std::env::temp_dir().join(format!(
            "cgc-app-actions-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = std::fs::create_dir_all(&workspace);
        (ToolContext::new(&workspace).with_action_sink(sink), actions)
    }

    #[test]
    fn open_page_emits_action() {
        let (context, actions) = context_with_actions();
        futures::executor::block_on(
            OpenPageTool.run(serde_json::json!({"route": "/courses/42"}), context),
        )
        .expect("run");
        assert_eq!(
            actions.lock().unwrap().as_slice(),
            &[AppAction::OpenPage {
                route: "/courses/42".to_string()
            }]
        );
    }

    #[test]
    fn open_page_rejects_external_url() {
        let (context, actions) = context_with_actions();
        let error = futures::executor::block_on(
            OpenPageTool.run(serde_json::json!({"route": "https://example.com"}), context),
        )
        .unwrap_err();
        assert!(matches!(error, ToolError::InvalidArgs(_)));
        assert!(actions.lock().unwrap().is_empty());
    }

    #[test]
    fn highlight_range_emits_action() {
        let (context, actions) = context_with_actions();
        futures::executor::block_on(HighlightRangeTool.run(
            serde_json::json!({"path": "src/main.rs", "start_line": 3, "end_line": 9}),
            context,
        ))
        .expect("run");
        assert_eq!(
            actions.lock().unwrap().as_slice(),
            &[AppAction::HighlightRange {
                path: "src/main.rs".to_string(),
                start_line: 3,
                end_line: 9
            }]
        );
    }

    #[test]
    fn highlight_rejects_invalid_range_and_escape() {
        let (context, _) = context_with_actions();
        let bad_range = futures::executor::block_on(HighlightRangeTool.run(
            serde_json::json!({"path": "a.rs", "start_line": 5, "end_line": 2}),
            context.clone(),
        ));
        assert!(bad_range.is_err());
        let escape = futures::executor::block_on(HighlightRangeTool.run(
            serde_json::json!({"path": "../outside.rs", "start_line": 1, "end_line": 2}),
            context,
        ));
        assert!(escape.is_err());
    }
}
