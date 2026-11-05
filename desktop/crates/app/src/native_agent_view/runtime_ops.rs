//! Native capabilities issue owner commands; rendering only reads immutable metadata.
use super::*;
use crate::i18n::{translate, Key};

impl NativeAgentView {
    pub(super) fn is_generating(&self) -> bool {
        self.snapshot
            .as_ref()
            .is_none_or(|snapshot| snapshot.phase != RuntimePhase::Idle)
            || self.state.session.is_busy()
    }
    pub(super) fn select_model(&mut self, provider: String, model: String, cx: &mut Context<Self>) {
        self.command(self.runtime.select_model(provider, model), cx);
    }
    pub(super) fn checkpoint_for_message(&self, index: usize) -> Option<Checkpoint> {
        let ordinal = thread_entry_ordinal(&self.state.session.thread.entries, index)?
            + self.hidden_user_count;
        self.metadata()
            .checkpoints
            .iter()
            .find(|(candidate, _)| *candidate == ordinal)
            .map(|(_, checkpoint)| checkpoint.clone())
    }
    pub(super) fn rewind_to_message(&mut self, index: usize, cx: &mut Context<Self>) {
        let Some(ordinal) = thread_entry_ordinal(&self.state.session.thread.entries, index) else {
            return;
        };
        let ordinal = ordinal + self.hidden_user_count;
        let restore_files = self.checkpoint_for_message(index).is_some();
        self.command(
            self.runtime
                .rewind_thread(self.metadata().thread.id.clone(), ordinal, restore_files),
            cx,
        );
    }
    pub(super) fn keep_checkpoint_file(&mut self, path: String, cx: &mut Context<Self>) {
        self.command(
            self.runtime.checkpoint(CheckpointAction::KeepFile(path)),
            cx,
        );
    }
    pub(super) fn restore_checkpoint_file(&mut self, path: String, cx: &mut Context<Self>) {
        self.command(
            self.runtime.checkpoint(CheckpointAction::RestoreFile(path)),
            cx,
        );
    }

    pub(super) fn resolve_permission_option(&mut self, option: &str, cx: &mut Context<Self>) {
        if !self.state.session.resolve_permission(option) {
            self.status = "审批已失效或连接已关闭".into();
        }
        cx.notify();
    }
    pub(super) fn render_operation_error(&self, cx: &mut Context<Self>) -> Option<AnyElement> {
        let error = self.operation_error.clone()?;
        Some(
            div()
                .id("native-operation-error")
                .test_support()
                .role(Role::Alert)
                .aria_label(translate(self.language, Key::AgentChatChatOperationFailed))
                .mx(space(2))
                .mb(space(1))
                .p(space(1))
                .flex()
                .flex_row()
                .items_start()
                .gap(space(1))
                .text_size(px(12.0))
                .text_color(theme::palette_from_theme(cx).danger)
                .child(div().flex_1().min_w(px(0.0)).child(error))
                .child(
                    Button::new("native-dismiss-operation-error")
                        .label("×")
                        .tooltip(translate(self.language, Key::AgentChatChatDismissError))
                        .accessibility_label(translate(
                            self.language,
                            Key::AgentChatChatDismissError,
                        ))
                        .xsmall()
                        .ghost()
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.begin_operation(cx);
                        })),
                )
                .into_any_element(),
        )
    }

    pub(super) fn render_checkpoint_panel(
        &mut self,
        palette: theme::Palette,
        change_count: usize,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let changes = self.metadata().changes.clone();
        div()
            .id("native-agent-checkpoint-panel")
            .test_support()
            .flex()
            .flex_col()
            .gap(space(1))
            .px(space(3))
            .py(space(2))
            .border_t_1()
            .border_color(palette.line)
            .bg(palette.view)
            .child(
                div()
                    .flex()
                    .flex_row()
                    .flex_wrap()
                    .items_center()
                    .gap(space(1))
                    .child(
                        div()
                            .w_full()
                            .text_size(px(12.0))
                            .child(format!("本轮文件变更（{change_count}）")),
                    )
                    .child(
                        div()
                            .id("native-keep-all")
                            .role(Role::Button)
                            .aria_label(translate(self.language, Key::AgentChatChatKeepFiles))
                            .px(space(1))
                            .py(px(2.0))
                            .rounded(px(RADIUS_SMALL))
                            .text_size(px(10.0))
                            .text_color(palette.ink_2)
                            .hover(|style| style.bg(palette.soft))
                            .child(translate(self.language, Key::AgentChatChatKeepFiles))
                            .on_click(
                                cx.listener(|this, _, _window, cx| this.keep_all_changes(cx)),
                            ),
                    )
                    .child(
                        div()
                            .id("native-reject-all")
                            .role(Role::Button)
                            .aria_label(translate(self.language, Key::AgentChatChatRevertFiles))
                            .px(space(1))
                            .py(px(2.0))
                            .rounded(px(RADIUS_SMALL))
                            .text_size(px(10.0))
                            .text_color(palette.danger)
                            .hover(|style| style.bg(palette.soft))
                            .child(translate(self.language, Key::AgentChatChatRevertFiles))
                            .on_click(
                                cx.listener(|this, _, _window, cx| this.reject_all_changes(cx)),
                            ),
                    ),
            )
            .children(changes.iter().map(|change| {
                let keep = change.path.clone();
                let restore = change.path.clone();
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap(space(2))
                    .child(
                        div()
                            .flex_1()
                            .text_size(px(12.0))
                            .child(checkpoint_change_label(change)),
                    )
                    .child(
                        div()
                            .id(SharedString::from(format!(
                                "checkpoint-keep-{}",
                                change.path
                            )))
                            .role(Role::Button)
                            .aria_label("保留")
                            .px(space(1))
                            .py(px(2.0))
                            .rounded(px(RADIUS_MEDIUM))
                            .bg(palette.soft)
                            .child("保留")
                            .on_click(cx.listener(move |this, _, _window, cx| {
                                this.keep_checkpoint_file(keep.clone(), cx)
                            })),
                    )
                    .child(
                        div()
                            .id(SharedString::from(format!(
                                "checkpoint-restore-{}",
                                change.path
                            )))
                            .role(Role::Button)
                            .aria_label("回退")
                            .px(space(1))
                            .py(px(2.0))
                            .rounded(px(RADIUS_MEDIUM))
                            .bg(palette.accent)
                            .text_color(palette.canvas)
                            .child("回退")
                            .on_click(cx.listener(move |this, _, _window, cx| {
                                this.restore_checkpoint_file(restore.clone(), cx)
                            })),
                    )
            }))
            .into_any_element()
    }
}
