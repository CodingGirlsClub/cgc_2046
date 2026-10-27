//! View-local drafts and command callbacks.

use super::*;

impl NativeAgentView {
    pub(super) fn keep_all_changes(&mut self, cx: &mut Context<Self>) {
        self.command(self.runtime.checkpoint(CheckpointAction::KeepAll), cx);
    }
    pub(super) fn reject_all_changes(&mut self, cx: &mut Context<Self>) {
        self.command(self.runtime.checkpoint(CheckpointAction::RestoreAll), cx);
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
        self.runtime
            .set_thinking(enabled, self.metadata().effort_index);
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
        self.runtime
            .set_thinking(self.metadata().thinking_enabled, index);
        self.status = format!("推理档位索引：{index}");
        cx.notify();
    }
    pub(super) fn set_approval_mode(&mut self, mode: ApprovalMode, cx: &mut Context<Self>) {
        self.runtime.set_approval(mode);
        self.status = format!("审批模式：{}", mode.label());
        cx.notify();
    }
}
