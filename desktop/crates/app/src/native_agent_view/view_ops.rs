//! 视图层状态开关（B4b-a：从 runtime_ops 分出的纯 UI 操作，行为不变）。
//!
//! 这些方法只改视图状态并 notify，不参与运行时编排。

use super::*;

impl NativeAgentView {
    pub(super) fn keep_all_changes(&mut self, cx: &mut Context<Self>) {
        self.checkpoint_changes.clear();
        self.status = "已全部保留本轮改动".to_string();
        cx.notify();
    }
    pub(super) fn reject_all_changes(&mut self, cx: &mut Context<Self>) {
        let paths = paths_for_restore_all(&self.checkpoint_changes);
        for path in &paths {
            self.restore_checkpoint_file(path.clone(), cx);
        }
        self.status = format!("已回退 {} 个文件", paths.len());
        self.checkpoint_changes.clear();
        cx.notify();
    }
    pub(super) fn toggle_checkpoint_panel(&mut self, cx: &mut Context<Self>) {
        self.show_checkpoint_panel = !self.show_checkpoint_panel;
        cx.notify();
    }
    /// 当前滚动位置是否已在底部。
    /// 消息区滚动到顶部（同时停止自动跟随输出）。
    pub(super) fn scroll_messages_to_top(&mut self, cx: &mut Context<Self>) {
        self.message_scroller.update(cx, |state, cx| {
            let _ = state.scroll_to_item(0, cx);
        });
        cx.notify();
    }
    /// 回到最新：恢复 tail 跟随并滚到列表末尾。
    pub(super) fn scroll_messages_to_bottom(&mut self, cx: &mut Context<Self>) {
        self.message_scroller
            .update(cx, |state, cx| state.scroll_to_end(cx));
        cx.notify();
    }
    pub(super) fn set_thinking_enabled(&mut self, enabled: bool, cx: &mut Context<Self>) {
        self.thinking_enabled = enabled;
        self.status = if enabled {
            "Thinking 开".to_string()
        } else {
            "Thinking 关".to_string()
        };
        cx.notify();
    }
    pub(super) fn insert_context_marker(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let current = self.input.read(cx).value().to_string();
        let next = if current.trim().is_empty() {
            "@".to_string()
        } else if current.ends_with(char::is_whitespace) {
            format!("{current}@")
        } else {
            format!("{current} @")
        };
        self.input
            .update(cx, |state, cx| state.set_value(next, window, cx));
        self.status = "输入 @ 引用工作区文件".to_string();
        cx.notify();
    }
    pub(super) fn set_effort_index(&mut self, index: usize, cx: &mut Context<Self>) {
        self.effort_index = index;
        self.status = format!("推理档位索引：{index}");
        cx.notify();
    }
    pub(super) fn set_approval_mode(&mut self, mode: ApprovalMode, cx: &mut Context<Self>) {
        self.approval_mode = mode;
        self.status = format!("审批模式：{}", mode.label());
        cx.notify();
    }
}
