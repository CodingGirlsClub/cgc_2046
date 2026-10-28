//! native composer 渲染（B4b 拆分：从视图模块移出，行为不变）。
//!
//! 作为 `native_agent_view` 的子模块，可直接访问父模块的私有字段与方法。

use super::*;

use gpui_kit::component::progress::ProgressCircle;

impl NativeAgentView {
    pub(super) fn render_native_composer_legacy(
        &mut self,
        draft: &ComposerDraft,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let busy = draft.busy;
        let has_input = draft.has_input;
        let usage = draft.usage;
        let model_supports_images = draft.model_supports_images;
        let input = draft.input.clone();
        let input_focus = draft.input_focus.clone();
        let add_menu_root = cx.entity().downgrade();
        let palette = theme::palette_from_theme(cx);
        let chip_workspace = self.metadata().workspace.as_ref().clone();
        let can_undo = self
            .state
            .session
            .thread
            .capabilities
            .checkpoint_available()
            && !self.metadata().checkpoints.is_empty()
            && !busy;
        let change_count = self.metadata().changes.len();

        let pickers = self.native_composer_pickers(palette, cx);
        let send_aria = if busy {
            if has_input {
                "发送（排队）"
            } else {
                "停止"
            }
        } else {
            "发送"
        };
        let send_label = if busy {
            if has_input {
                "⏳"
            } else {
                "■"
            }
        } else {
            "↑"
        };
        let send_bg = if busy && !has_input {
            palette.danger
        } else if !busy && !has_input {
            palette.soft
        } else {
            palette.accent
        };
        let send_fg = if !busy && !has_input {
            palette.ink_3
        } else {
            palette.canvas
        };
        let send_tip = if busy {
            if has_input {
                "排队发送（⌘↩ 立即打断发送）"
            } else {
                "停止生成"
            }
        } else if has_input {
            "发送（Enter）"
        } else {
            "输入内容后可发送"
        };
        let send_weak = cx.entity().downgrade();
        let context_window = self.metadata().model.limits.context_window.max(1) as u64;
        let output_window = self.metadata().model.limits.max_output_tokens.max(1) as u64;
        let usage_total = self.state.usage_total;
        let input_percent = (usage as f64 / context_window as f64 * 100.0).clamp(0.0, 100.0);
        let output_percent =
            (usage_total.output as f64 / output_window as f64 * 100.0).clamp(0.0, 100.0);
        let progress_color = |percent: f64| {
            if percent >= 85.0 {
                palette.danger
            } else {
                palette.ink_3
            }
        };
        let input_color = progress_color(input_percent);
        let output_color = progress_color(output_percent);
        let input_label = format!(
            "{} / {}",
            humanize_tokens(usage),
            humanize_tokens(context_window)
        );
        let output_label = format!(
            "{} / {}",
            humanize_tokens(usage_total.output),
            humanize_tokens(output_window)
        );
        let rules = project_rule_files(self.metadata().workspace.as_ref());
        let rules_count = rules.len();
        let context_usage = HoverCard::new("native-context-usage")
            .anchor(Anchor::BottomCenter)
            .trigger(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap(px(2.0))
                    .flex_shrink_0()
                    .child(
                        Icon::new(gpui_kit::assets::IconName::ArrowUp)
                            .xsmall()
                            .text_color(palette.ink_3),
                    )
                    .child(
                        ProgressCircle::new("native-input-context")
                            .xsmall()
                            .value(input_percent as f32)
                            .color(input_color),
                    )
                    .child(
                        Icon::new(gpui_kit::assets::IconName::ArrowDown)
                            .xsmall()
                            .text_color(palette.ink_3),
                    )
                    .child(
                        ProgressCircle::new("native-output-context")
                            .xsmall()
                            .value(output_percent as f32)
                            .color(output_color),
                    ),
            )
            .content(move |_, _, _| {
                let mut card = div()
                    .w(px(200.0))
                    .p(space(1))
                    .rounded(px(RADIUS_MEDIUM))
                    .border_1()
                    .border_color(palette.line)
                    .bg(palette.card)
                    .child(
                        div()
                            .text_size(px(10.0))
                            .text_color(palette.ink_3)
                            .child("Context"),
                    )
                    .child(
                        div()
                            .flex()
                            .flex_row()
                            .gap(px(3.0))
                            .child(
                                div()
                                    .text_size(px(10.0))
                                    .text_color(palette.ink_3)
                                    .child("Input:"),
                            )
                            .child(
                                div()
                                    .text_size(px(11.0))
                                    .text_color(palette.ink_2)
                                    .child(input_label.clone()),
                            ),
                    )
                    .child(
                        div()
                            .flex()
                            .flex_row()
                            .gap(px(3.0))
                            .child(
                                div()
                                    .text_size(px(10.0))
                                    .text_color(palette.ink_3)
                                    .child("Output:"),
                            )
                            .child(
                                div()
                                    .text_size(px(11.0))
                                    .text_color(palette.ink_2)
                                    .child(output_label.clone()),
                            ),
                    );
                if rules_count > 0 {
                    card = card
                        .child(
                            div()
                                .mt(px(4.0))
                                .pt(px(4.0))
                                .border_t_1()
                                .border_color(palette.line)
                                .text_size(px(10.0))
                                .text_color(palette.ink_3)
                                .child("Rules"),
                        )
                        .child(
                            div()
                                .text_size(px(11.0))
                                .text_color(palette.ink_2)
                                .child(format!("{rules_count} 个项目规则")),
                        );
                }
                card.into_any_element()
            });

        cgc_agent_ui::composer::composer_card(
                    "native-agent-composer",
                    false,
                    native_composer_style(palette),
                )
                .relative()
                .mx(space(2))
                .mb(space(2))
                    .capture_key_down(cx.listener(|this, event: &KeyDownEvent, _window, cx| {
                        if event.keystroke.key == "v" && event.keystroke.modifiers.platform {
                            let has_image = cx
                                .read_from_clipboard()
                                .map(|item| {
                                    item.entries
                                        .iter()
                                        .any(|entry| matches!(entry, ClipboardEntry::Image(_)))
                                })
                                .unwrap_or(false);
                            if has_image {
                                this.add_clipboard_image(cx);
                                cx.stop_propagation();
                                return;
                            }
                        }
                        let value = this.input.read(cx).value().to_string();
                        if trailing_mention(&value).is_some() {
                            match event.keystroke.key.as_str() {
                                "up" => {
                                    this.mention_index = this.mention_index.saturating_sub(1);
                                    cx.stop_propagation();
                                    cx.notify();
                                }
                                "down" => {
                                    this.mention_index += 1;
                                    cx.stop_propagation();
                                    cx.notify();
                                }
                                _ => {}
                            }
                            return;
                        }
                        if !value.trim_start().starts_with('/') || this.slash_dismissed {
                            return;
                        }
                        match event.keystroke.key.as_str() {
                            "up" => {
                                this.slash_index = this.slash_index.saturating_sub(1);
                                cx.stop_propagation();
                                cx.notify();
                            }
                            "down" => {
                                this.slash_index += 1;
                                cx.stop_propagation();
                                cx.notify();
                            }
                            "escape" => {
                                this.slash_dismissed = true;
                                cx.stop_propagation();
                                cx.notify();
                            }
                            _ => {}
                        }
                    }))
                    .children(self.render_slash_menu(cx))
                    .children(self.render_mention_menu(cx))
                    .children((!self.pending_images.is_empty())
                        .then(|| {
                        let rows = self
                            .pending_images
                            .iter()
                            .enumerate()
                            .map(|(index, image)| {
                                let remove_weak = cx.entity().downgrade();
                                let open_weak = cx.entity().downgrade();
                                let open_preview = image.preview.clone();
                                let open_name = image.name.clone();
                                let preview = image.preview.clone();
                                let trigger = div()
                                    .flex()
                                    .flex_row()
                                    .items_center()
                                    .gap(px(4.0))
                                    .child(match image.preview.clone() {
                                        Some(preview) => img(preview)
                                            .max_w(px(16.0))
                                            .max_h(px(16.0))
                                            .rounded(px(2.0))
                                            .into_any_element(),
                                        None => "🖼".into_any_element(),
                                    })
                                    .child(image.name.clone())
                                    .into_any_element();
                                div()
                                    .id(SharedString::from(format!(
                                        "native-image-chip-{index}"
                                    )))
                                    .flex()
                                    .flex_row()
                                    .items_center()
                                    .gap(px(4.0))
                                    .px(space(1))
                                    .py(px(1.0))
                                    .rounded(px(RADIUS_SMALL))
                                    .border_1()
                                    .border_color(palette.line)
                                    .text_size(px(11.0))
                                    .text_color(palette.ink_2)
                                    .on_click(move |_, _, cx| {
                                        if let Some(preview) = open_preview.clone() {
                                            let name = open_name.clone();
                                            let _ = open_weak.update(cx, |this, cx| {
                                                this.open_image_viewer(name, preview, cx);
                                            });
                                        }
                                    })
                                    .child(
                                        HoverCard::new(SharedString::from(format!(
                                            "native-image-hover-{index}"
                                        )))
                                        .anchor(Anchor::BottomCenter)
                                        .open_delay(std::time::Duration::from_millis(80))
                                        .trigger(trigger)
                                        .content(move |_, _, _| match preview.clone() {
                                            Some(preview) => div()
                                                .p(px(4.0))
                                                .rounded(px(RADIUS_SMALL))
                                                .border_1()
                                                .border_color(palette.line)
                                                .bg(palette.card)
                                                .child(
                                                    img(preview)
                                                        .max_w(px(280.0))
                                                        .max_h(px(180.0))
                                                        .rounded(px(RADIUS_SMALL)),
                                                )
                                                .into_any_element(),
                                            None => div().child("无预览").into_any_element(),
                                        }),
                                    )
                                    .child(
                                        div()
                                            .id(SharedString::from(format!(
                                                "native-image-remove-{index}"
                                            )))
                                            .role(Role::Button)
                                            .aria_label("移除图片")
                                            .px(px(3.0))
                                            .hover(|style| style.bg(palette.soft))
                                            .child("×")
                                            .on_click(move |_, _, cx| {
                                                let _ = remove_weak.update(cx, |this, cx| {
                                                    if index < this.pending_images.len() {
                                                        this.pending_images.remove(index);
                                                    }
                                                    cx.notify();
                                                });
                                            }),
                                    )
                                    .into_any_element()
                            })
                            .collect::<Vec<_>>();
                        div()
                            .flex()
                            .flex_row()
                            .flex_wrap()
                            .gap(space(1))
                            .px(space(1))
                            .pt(px(2.0))
                            .children(rows)
                    }))
                    .child(
                        div()
                            .relative()
                            .px(space(1))
                            .py(px(4.0))
                            .child(
                                Textarea::new(&input)
                                    .appearance(false)
                                    .bordered(false)
                                    .w_full()
                                    .token(move |context, _window, _cx| {
                                        crate::mention_chip::render_mention_chip(
                                            context,
                                            palette,
                                            &chip_workspace,
                                        )
                                    }),
                            )
                            .children((!has_input).then(|| {
                                // 自定义可换行 placeholder：gpui-base 的 Textarea
                                // placeholder 只按 \n 分行、不做宽度软换行
                                // （shape_line 未传宽度约束），窄面板会直接裁切；
                                // 上游修好前用 absolute overlay 折行并承担点击聚焦。
                                //
                                // 对齐 Textarea 的文字起点，否则光标与 placeholder 错行：
                                // overlay 从 wrapper 的 border box 顶/左起算，
                                //   top  = wrapper padding（py 4）
                                //        + gpui-component Input 多行编辑区 padding（top 8）
                                //   left = wrapper padding（space(1)）
                                //        + Input 编辑区 padding（left 10）
                                // 字号/行高与 Input 一致：text_sm 0.875rem、line_height 1.25rem。
                                let focus = input_focus.clone();
                                div()
                                    .id("native-agent-placeholder")
                                    .absolute()
                                    .top(px(4.0 + 8.0))
                                    .left(space(1) + px(10.0))
                                    .right(space(1) + px(10.0))
                                    .text_size(rems(0.875))
                                    .line_height(rems(1.25))
                                    .text_color(palette.ink_3)
                                    .child(
                                        "给 CGC Agent 发消息… @ 引用上下文，/ 查看命令（Enter 发送，Shift+Enter 换行）",
                                    )
                                    .on_click(move |_, window, cx| {
                                        window.focus(&focus, cx);
                                    })
                            })),
                    )
                    .child(
                        cgc_agent_ui::composer::composer_footer(
                            native_composer_style(palette),
                        )
                        .id("native-agent-composer-footer")
                            .child(
                                Popover::new("native-agent-add-menu")
                                .anchor(Anchor::BottomLeft)
                                    .trigger(
                                        Button::new("native-agent-add-context")
                                            .label("＋")
                                            .xsmall()
                                            .ghost()
                                            .tooltip("添加上下文"),
                                    )
                                    .content(move |_, _, cx| {
                                        let dismiss = cx.entity().downgrade();
                                        let root = add_menu_root.clone();
                                        let files_root = root.clone();
                                        let files_dismiss = dismiss.clone();
                                        let image_root = root.clone();
                                        let image_dismiss = dismiss;
                                        div()
                                            .w(px(240.0))
                                            .flex()
                                            .flex_col()
                                            .gap(px(1.0))
                                            .child(
                                                div()
                                                    .id("native-add-files")
                                                    .role(Role::Button)
                                                    .flex()
                                                    .flex_row()
                                                    .items_center()
                                                    .gap(space(1))
                                                    .px(space(1))
                                                    .py(px(3.0))
                                                    .rounded(px(RADIUS_MEDIUM))
                                                    .text_size(px(11.0))
                                                    .text_color(palette.ink_2)
                                                    .hover(|style| style.bg(palette.soft))
                                                    .child("📄")
                                                    .child("Files & Directories")
                                                    .on_click(move |_, window, cx| {
                                                        let _ = files_root.update(cx, |this, cx| {
                                                            this.insert_context_marker(window, cx);
                                                        });
                                                        let _ = files_dismiss
                                                            .update(cx, |state, cx| state.dismiss(window, cx));
                                                    }),
                                            )
                                            .children(model_supports_images.then(|| {
                                                div()
                                                    .id("native-add-image-menu")
                                                    .role(Role::Button)
                                                    .flex()
                                                    .flex_row()
                                                    .items_center()
                                                    .gap(space(1))
                                                    .px(space(1))
                                                    .py(px(3.0))
                                                    .rounded(px(RADIUS_MEDIUM))
                                                    .text_size(px(11.0))
                                                    .text_color(palette.ink_2)
                                                    .hover(|style| style.bg(palette.soft))
                                                    .child("🖼")
                                                    .child("Image")
                                                    .on_click(move |_, window, cx| {
                                                        let _ = image_root.update(cx, |this, cx| {
                                                            this.add_images_from_picker(cx);
                                                        });
                                                        let _ = image_dismiss
                                                            .update(cx, |state, cx| state.dismiss(window, cx));
                                                    })
                                            }))
                                            .into_any_element()
                                    }),
                            )
                            .child(div().flex_1())
                            .children((can_undo && change_count > 0).then(|| {
                                div()
                                    .id("native-agent-changes")
                                    .role(Role::Button)
                                    .aria_label("查看变更")
                                    .px(space(1))
                                    .py(px(2.0))
                                    .rounded(px(RADIUS_SMALL))
                                    .text_size(px(11.0))
                                    .text_color(palette.ink_2)
                                    .hover(|style| style.bg(palette.soft))
                                    .child(format!("变更 {change_count}"))
                                    .on_click(cx.listener(|this, _, _window, cx| {
                                        this.toggle_checkpoint_panel(cx)
                                    }))
                            }))
                            .children(can_undo.then(|| {
                                div()
                                    .id("native-agent-undo")
                                    .role(Role::Button)
                                    .aria_label("撤销文件改动")
                                    .px(space(1))
                                    .py(px(2.0))
                                    .rounded(px(RADIUS_SMALL))
                                    .text_size(px(11.0))
                                    .text_color(palette.ink_3)
                                    .hover(|style| style.bg(palette.soft))
                                    .child("撤销")
                                    .on_click(
                                        cx.listener(|this, _, _window, cx| {
                                            this.undo_checkpoint(cx)
                                        }),
                                    )
                            }))
                            .children(pickers.approval)
                            .children(pickers.model)
                            .children(pickers.thinking)
                            .children(
                                self.state.session.thread
                                    .capabilities
                                    .usage_available()
                                    .then_some(context_usage),
                            )
                            .child(cgc_agent_ui::composer::render_send_button(
                                cgc_agent_ui::composer::SendButtonSpec {
                                    id: if busy {
                                        "native-agent-stop"
                                    } else {
                                        "native-agent-send"
                                    }
                                    .into(),
                                    aria: send_aria.into(),
                                    tooltip: send_tip.into(),
                                    glyph: div().child(send_label).into_any_element(),
                                    bg: send_bg,
                                    fg: send_fg,
                                    radius: RADIUS_SMALL,
                                    padding_x: 8.0,
                                    padding_y: 3.0,
                                    text_size: 12.0,
                                    ml_auto: false,
                                    on_click: Box::new(move |window, cx| {
                                        let _ = send_weak.update(cx, |this, cx| {
                                            if busy && !has_input {
                                                this.stop(cx);
                                            } else {
                                                this.send(window, cx);
                                            }
                                        });
                                    }),
                                },
                            )),
                    )
            .into_any_element()
    }
}
