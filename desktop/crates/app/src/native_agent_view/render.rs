//! 面板渲染主体（B4b 结构拆分第六片：从视图模块移出，行为不变）。
//!
//! 子模块可直接访问父模块私有字段。

use super::*;

impl Render for NativeAgentView {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        // 页面 scope 变化时先切换工作区/线程，再渲染。
        self.ensure_scope(cx);
        let _add_menu_root = cx.entity().downgrade();
        let draft = self.composer_draft(cx);
        let palette = theme::palette_from_theme(cx);
        let _chip_workspace = self.context.workspace().to_path_buf();
        let pending = self.state.thread.pending_permission.clone();
        let _model_supports_images = draft.model_supports_images;
        let busy = draft.busy;
        let _usage = draft.usage;
        let _input = draft.input.clone();
        let _input_focus = draft.input_focus.clone();
        let input_value = draft.input_value.clone();
        let _has_input = draft.has_input;
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
        let _can_undo = self.state.thread.capabilities.checkpoint_available()
            && self.last_checkpoint.is_some()
            && !busy;
        let change_count = self.checkpoint_changes.len();
        let plan_state = self
            .host
            .agent_state
            .lock()
            .map(|state| state.clone())
            .unwrap_or_default();
        let queued_messages = self.queued_messages.clone();
        let show_plan_card = self.state.thread.capabilities.plan_available()
            && (!plan_state.todos.is_empty()
                || !plan_state.plan.is_empty()
                || plan_state.goal.is_some());
        let show_changes = checkpoint_panel_visible(
            self.state.thread.capabilities.checkpoint_available(),
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
                (!queued_messages.is_empty() && self.state.thread.capabilities.queue_available())
                    .then(|| {
                        use cgc_agent_ui::queue_panel::{
                            queue_preview, render_queue_panel, QueuePanelItem, QueuePanelSpec,
                            QueuePanelStyle,
                        };
                        let items = queued_messages
                            .iter()
                            .enumerate()
                            .map(|(index, queued)| {
                                let remove_view = cx.entity().downgrade();
                                QueuePanelItem {
                                    preview: queue_preview(&queued.display, 160),
                                    remove_id: SharedString::from(format!(
                                        "native-queue-remove-{index}"
                                    )),
                                    on_remove: Box::new(move |cx: &mut App| {
                                        let _ = remove_view.update(cx, |this, cx| {
                                            if index < this.queued_messages.len() {
                                                this.queued_messages.remove(index);
                                                cx.notify();
                                            }
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
            .child({
                // B4b-b'1：两条 composer 渲染路径已合一，这是唯一实现
                // （附件/queue/slash/mention/pickers/checkpoint/usage 均在）。
                self.render_native_composer_legacy(&draft, cx)
            })
    }
}
