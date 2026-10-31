//! 面板渲染主体（B4b 结构拆分第六片：从视图模块移出，行为不变）。
//!
//! 子模块可直接访问父模块私有字段。

use super::*;

impl Render for NativeAgentView {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        if self.snapshot.is_none() {
            // 兜底：即使订阅错过了首个快照，首帧也要主动取一次，避免永久停在载入态。
            self.ensure_initial_snapshot(cx);
            return div()
                .size_full()
                .p(space(3))
                .child(self.status.clone())
                .into_any_element();
        }
        let _add_menu_root = cx.entity().downgrade();
        let draft = self.composer_draft(cx);
        let palette = theme::palette_from_theme(cx);
        let pending = self.state.session.thread.pending_permission.clone();
        let _model_supports_images = draft.model_supports_images;
        let busy = draft.busy;
        let _usage = draft.usage;
        let _input = draft.input.clone();
        let _input_focus = draft.input_focus.clone();
        let input_value = draft.input_value.clone();
        let _has_input = draft.has_input;
        let model_setup = self.metadata().model_setup;
        let slash_open = input_value.trim_start().starts_with('/') && !self.slash_dismissed;
        let slash_matches = self.slash_entries(&input_value);
        let _slash_selected = self.slash_index.min(slash_matches.len().saturating_sub(1));
        let mention = trailing_mention(&input_value);
        let mention_matches = mention
            .as_ref()
            .map(|(_, query)| self.mention_matches(query))
            .unwrap_or_default();
        let _mention_open = mention.is_some() && !slash_open && !mention_matches.is_empty();
        let _mention_selected = self
            .mention_index
            .min(mention_matches.len().saturating_sub(1));
        let _can_undo = self
            .state
            .session
            .thread
            .capabilities
            .checkpoint_available()
            && !self.metadata().checkpoints.is_empty()
            && !busy;
        let change_count = self.metadata().changes.len();
        let plan_state = self.metadata().agent_state.clone();
        let queued_messages: Vec<_> = self
            .state
            .session
            .queue
            .iter()
            .map(|queued| (queued.id, queued.display.clone()))
            .collect();
        let show_plan_card = self.state.session.thread.capabilities.plan_available()
            && (!plan_state.todos.is_empty()
                || !plan_state.plan.is_empty()
                || plan_state.goal.is_some());
        let show_changes = checkpoint_panel_visible(
            self.state
                .session
                .thread
                .capabilities
                .checkpoint_available(),
            self.show_checkpoint_panel,
            change_count,
        );
        let row_kinds = self.message_row_kinds();
        self.sync_message_scroller(&row_kinds, cx);
        let row_kinds = Arc::new(row_kinds);
        let weak_view = cx.entity().downgrade();
        let message_menu_root = cx.entity().downgrade();

        div()
            .size_full()
            .flex()
            .flex_col()
            .bg(palette.canvas)
            .text_color(palette.ink)
            .font_family(theme::FONT_SANS)
            .text_size(px(13.0))
            .child(
                div().flex_1().min_h(px(0.0)).child(
                    MessageScroller::new(
                        "native-agent-messages",
                        self.message_scroller.clone(),
                        move |index, _window, cx| {
                            let Some(kind) = row_kinds.get(index).copied() else {
                                return div().into_any_element();
                            };
                            let menu_root = message_menu_root.clone();
                            let row = weak_view
                                .update(cx, |view, cx| {
                                    view.render_message_row(kind, &menu_root, cx)
                                })
                                .unwrap_or_else(|_| div().into_any_element());
                            div().w_full().child(row).into_any_element()
                        },
                    )
                    .scrollbar(true)
                    .jump_button(true)
                    .with_jump_button_label("回到最新")
                    .with_list_style(StyleRefinement::default().p(space(2)))
                    .with_row_style(StyleRefinement::default().pb(space(2))),
                ),
            )
            .children(show_changes.then(|| self.render_checkpoint_panel(palette, change_count, cx)))
            .children(pending.map(|request| {
                let view = cx.entity().downgrade();
                let on_select: PermissionSelectCallback =
                    Arc::new(move |option_id: &str, cx: &mut App| {
                        let _ = view
                            .update(cx, |this, cx| this.resolve_permission_option(option_id, cx));
                    });
                render_permission_card(PermissionCardSpec {
                    id: SharedString::from("native-agent-permission"),
                    model: PermissionCardModel::from_request(&request),
                    hint: None,
                    style: crate::permission_ui::card_style(&palette),
                    on_select: Some(on_select),
                })
            }))
            .children(
                (!queued_messages.is_empty()
                    && self.state.session.thread.capabilities.queue_available())
                .then(|| {
                    use cgc_agent_ui::queue_panel::{
                        queue_preview, render_queue_panel, QueuePanelItem, QueuePanelSpec,
                        QueuePanelStyle,
                    };
                    let items = queued_messages
                        .iter()
                        .enumerate()
                        .map(|(index, (submission_id, display))| {
                            let submission_id = *submission_id;
                            let remove_view = cx.entity().downgrade();
                            QueuePanelItem {
                                preview: queue_preview(display, 160),
                                remove_id: SharedString::from(format!(
                                    "native-queue-remove-{index}"
                                )),
                                on_remove: Box::new(move |cx: &mut App| {
                                    let _ = remove_view.update(cx, |this, cx| {
                                        this.state
                                            .session
                                            .queue
                                            .retain(|submission| submission.id != submission_id);
                                        cx.notify();
                                    });
                                }),
                            }
                        })
                        .collect();
                    render_queue_panel(QueuePanelSpec {
                        row_id: SharedString::from("native-agent-queue"),
                        header: queued_panel_header_text(queued_messages.len()),
                        items,
                        style: QueuePanelStyle {
                            line: palette.line,
                            view: palette.view,
                            ink_2: palette.ink_2,
                            ink_3: palette.ink_3,
                            soft: palette.soft,
                            radius: RADIUS_MEDIUM,
                        },
                    })
                }),
            )
            .children(show_plan_card.then(|| {
                use cgc_agent_ui::plan_card::{
                    render_plan_card, PlanCardSpec, PlanCardStyle, PlanStepView, PlanTodoView,
                };
                let status = |status: ItemStatus| match status {
                    ItemStatus::Completed => ("✓", palette.ink_3),
                    ItemStatus::InProgress => ("◐", palette.accent),
                    ItemStatus::Blocked => ("!", palette.danger),
                    ItemStatus::Pending => ("○", palette.ink_3),
                };
                let plan_done = plan_state
                    .plan
                    .iter()
                    .filter(|step| step.status == ItemStatus::Completed)
                    .count();
                let todo_done = plan_state
                    .todos
                    .iter()
                    .filter(|todo| todo.status == ItemStatus::Completed)
                    .count();
                let steps = plan_state
                    .plan
                    .iter()
                    .map(|step| {
                        let (glyph, color) = status(step.status);
                        PlanStepView {
                            title: step.title.clone(),
                            glyph,
                            color,
                        }
                    })
                    .collect();
                let todos = plan_state
                    .todos
                    .iter()
                    .map(|todo| {
                        let (glyph, color) = status(todo.status);
                        PlanTodoView {
                            content: todo.content.clone(),
                            glyph,
                            color,
                        }
                    })
                    .collect();
                render_plan_card(PlanCardSpec {
                    row_id: SharedString::from("native-agent-plan-card"),
                    goal: plan_state.goal.as_ref().map(|goal| goal.objective.clone()),
                    plan_done,
                    plan_total: plan_state.plan.len(),
                    todo_done,
                    todo_total: plan_state.todos.len(),
                    steps,
                    todos,
                    style: PlanCardStyle {
                        line: palette.line,
                        card: palette.card,
                        ink_2: palette.ink_2,
                        ink_3: palette.ink_3,
                        radius: RADIUS_MEDIUM,
                    },
                })
            }))
            .children(
                matches!(model_setup, ModelSetup::Unconfigured | ModelSetup::DemoEcho)
                    .then(|| self.render_model_setup_notice(model_setup, palette, cx)),
            )
            .children(self.page_context_chip(palette, cx))
            .child({
                // B4b-b'1：两条 composer 渲染路径已合一，这是唯一实现
                // （附件/queue/slash/mention/pickers/checkpoint/usage 均在）。
                self.render_native_composer_legacy(&draft, cx)
            })
            .into_any_element()
    }
}

impl NativeAgentView {
    fn page_context_chip(
        &self,
        palette: theme::Palette,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        let context = self.page_context.visible()?;
        let scope = self.conversation_scope();
        let dismiss = cx.entity().downgrade();
        Some(
            div()
                .mx(space(2))
                .child(cgc_agent_ui::context_chip::render_context_chip(
                    cgc_agent_ui::context_chip::ContextChipSpec {
                        id: "native-context-chip".into(),
                        dismiss_id: "native-context-dismiss".into(),
                        title: context.chip_title(),
                        state_label: crate::page_context::page_load_state_label(
                            self.page_context.chip_state(&scope),
                        )
                        .into(),
                        style: cgc_agent_ui::context_chip::ContextChipStyle {
                            background: palette.soft,
                            foreground: palette.ink_3,
                            hover: palette.card,
                            radius: RADIUS_SMALL,
                            text_size: 11.0,
                            gap: 4.0,
                            padding_x: 4.0,
                            padding_y: 2.0,
                        },
                        on_dismiss: Box::new(move |_, cx| {
                            let _ = dismiss.update(cx, |this, cx| {
                                this.page_context.dismiss();
                                cx.notify();
                            });
                        }),
                    },
                ))
                .into_any_element(),
        )
    }
}
