//! native composer 渲染（B4b 拆分：从视图模块移出，行为不变）。
//!
//! 作为 `native_agent_view` 的子模块，可直接访问父模块的私有字段与方法。

use super::*;
use crate::i18n::{translate, Key};

use gpui_kit::base::Disableable;
use gpui_kit::component::progress::ProgressCircle;

fn composer_placeholder(setup: ModelSetup) -> &'static str {
    match setup {
        ModelSetup::Unconfigured => {
            "还没有连接模型。先在 Settings → AI → LLM Providers 配置 Provider；DeepSeek API Key 可在 platform.deepseek.com 获取。"
        }
        ModelSetup::DemoEcho => "演示模式（Echo）：输入内容只在本机回显，不会调用真实模型。",
        ModelSetup::Configured | ModelSetup::PendingCredentials => {
            "给 CGC Agent 发消息… @ 引用上下文，/ 查看命令（Enter 发送，Shift+Enter 换行）"
        }
    }
}

impl NativeAgentView {
    pub(super) fn render_model_setup_notice(
        &self,
        setup: ModelSetup,
        palette: theme::Palette,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        if !matches!(setup, ModelSetup::Unconfigured | ModelSetup::DemoEcho) {
            return div().into_any_element();
        }
        let card = div()
            .mx(space(2))
            .mb(space(1))
            .p(space(1))
            .rounded(px(RADIUS_MEDIUM))
            .border_1()
            .border_color(palette.line)
            .bg(palette.soft)
            .flex()
            .flex_col()
            .gap(px(2.0));
        if setup == ModelSetup::DemoEcho {
            return card
                .child(
                    div()
                        .text_size(px(12.0))
                        .text_color(palette.ink_2)
                        .child("演示模式（Echo）"),
                )
                .child(
                    div()
                        .text_size(px(11.0))
                        .text_color(palette.ink_3)
                        .child("当前只会离线回显输入内容，不会调用真实模型。"),
                )
                .into_any_element();
        }
        let open_root = cx.entity().downgrade();
        card.child(
            div()
                .text_size(px(12.0))
                .text_color(palette.ink_2)
                .child("还没有连接模型"),
        )
        .child(
            div()
                .text_size(px(11.0))
                .text_color(palette.ink_3)
                .child("先在 Settings → AI → LLM Providers 配置 Provider；推荐 DeepSeek，API Key 可在 platform.deepseek.com 获取。"),
        )
        .child(
            div()
                .flex()
                .flex_row()
                .items_center()
                .gap(space(1))
                .child(
                    Button::new("native-model-setup-open-settings")
                        .label("去配置模型")
                        .xsmall()
                        .on_click(move |_, _, cx| {
                            let _ = open_root.update(cx, |this, cx| {
                                this.open_model_settings(cx);
                            });
                        }),
                )
                .child(
                    Button::new("native-model-setup-deepseek")
                        .label("获取 DeepSeek API Key")
                        .xsmall()
                        .ghost()
                        .on_click(|_, _, cx| {
                            cx.open_url("https://platform.deepseek.com/api_keys");
                        }),
                ),
        )
        .into_any_element()
    }

    #[rustfmt::skip]
    pub(super) fn render_composer(
        &mut self,
        draft: &ComposerDraft,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let busy = draft.busy;
        let has_input = draft.has_input;
        let model_supports_images = draft.model_supports_images;
        let input = draft.input.clone();
        let add_menu_root = cx.entity().downgrade();
        let palette = theme::palette_from_theme(cx);
        let chip_workspace = self.metadata().workspace.as_ref().clone();
        let can_review_changes = self
            .state
            .session
            .thread
            .capabilities
            .checkpoint_available()
            && !self.metadata().checkpoints.is_empty()
            && !busy;
        let change_count = self.metadata().changes.len();

        let pickers = self.native_composer_pickers(palette, cx);
        let model_setup = self.metadata().model_setup;
        let model_ready = model_setup.allows_send();
        let send_aria = if !model_ready {
            "发送（需先配置模型）"
        } else if busy {
            if has_input {
                "发送（排队）"
            } else {
                "停止"
            }
        } else {
            "发送"
        };
        let send_bg = if !model_ready {
            palette.soft
        } else if busy && !has_input {
            palette.danger
        } else if !busy && !has_input {
            palette.soft
        } else {
            palette.accent
        };
        let send_fg = if !model_ready || (!busy && !has_input) {
            palette.ink_3
        } else {
            palette.canvas
        };
        let send_tip = if !model_ready {
            "先在 Settings → AI → LLM Providers 配置模型"
        } else if busy {
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
        let usage = latest_request_usage(&self.metadata().thread.entries);
        let input_capacity = cgc_agent_core::input_capacity(self.metadata().model.as_ref()) as u64;
        let output_capacity = self.metadata().model.limits.max_output_tokens as u64;
        let input_ratio = token_ratio(usage.map_or(0, |usage| usage.input), input_capacity);
        let output_ratio = token_ratio(usage.map_or(0, |usage| usage.output), output_capacity);
        let progress_color = |ratio: f32| {
            if ratio >= 0.85 {
                palette.warning
            } else {
                palette.ink_3
            }
        };
        let input_color = progress_color(input_ratio);
        let output_color = progress_color(output_ratio);
        let input_label = format!(
            "{} / {}",
            humanize_tokens(usage.map_or(0, |usage| usage.input)),
            humanize_tokens(input_capacity)
        );
        let output_label = format!(
            "{} / {}",
            humanize_tokens(usage.map_or(0, |usage| usage.output)),
            humanize_tokens(output_capacity)
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
                            .with_size(Size::Medium)
                            .value(input_ratio * 100.0)
                            .color(input_color),
                    )
                    .child(
                        Icon::new(gpui_kit::assets::IconName::ArrowDown)
                            .xsmall()
                            .text_color(palette.ink_3),
                    )
                    .child(
                        ProgressCircle::new("native-output-context")
                            .with_size(Size::Medium)
                            .value(output_ratio * 100.0)
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
                    input.read(cx).focus_handle(cx).is_focused(window),
                    palette.composer_style(),
                )
                .relative()
                .mx(space(2))
                .mb(space(2))
                    .capture_key_down(cx.listener(|this, event: &KeyDownEvent, _window, cx| {
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
                        let user_value = crate::composer_context::user_text(&this.input.read(cx).content());
                        if !user_value.starts_with('/') || this.slash_dismissed {
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
                        cgc_agent_ui::message_editor::MessageEditor::new(
                            &input,
                            composer_placeholder(model_setup),
                            palette.ink_3,
                        )
                                    .on_paste({
                                        let view = cx.entity().downgrade();
                                        move |item, _, cx| view.update(cx, |this, cx| this.paste_images(item, cx)).unwrap_or(false)
                                    })
                                    .token({
                                        let attachments = self.composer_context.labels();
                                        let page_context = self.page_context.clone();
                                        let scope = self.conversation_scope();
                                        let language = self.language;
                                        move |context, _window, _cx| {
                                            let resolved = attachments.label(context.token().id(), page_context.chip_context(&scope).as_ref(), language);
                                            crate::mention_chip::render_resolved_chip(context, palette, &chip_workspace, resolved)
                                        }
                                    })
                                    .on_token_click(|event, window, cx| {
                                        crate::composer_context::open_token_source(event.token().id(), window, cx);
                                    }),
                    )
                    .child(
                        cgc_agent_ui::composer::composer_footer()
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
                                        let page_root = root.clone();
                                        let selection_root = root.clone();
                                        let page_dismiss = files_dismiss.clone();
                                        let selection_dismiss = files_dismiss.clone();
                                        let has_selection = root.read_with(cx, |this, _| this.page_context.has_selection()).unwrap_or(false);
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
                                            .child(
                                                Button::new("native-add-current-page").label("Current page").ghost().small()
                                                    .on_click(move |_, window, cx| {
                                                        let _ = page_root.update(cx, |this, cx| this.add_page_context(false, window, cx));
                                                        let _ = page_dismiss.update(cx, |state, cx| state.dismiss(window, cx));
                                                    })
                                            )
                                            .child(
                                                Button::new("native-add-selection").label("Selection").ghost().small().disabled(!has_selection)
                                                    .on_click(move |_, window, cx| {
                                                        let _ = selection_root.update(cx, |this, cx| this.add_page_context(true, window, cx));
                                                        let _ = selection_dismiss.update(cx, |state, cx| state.dismiss(window, cx));
                                                    })
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
                            .children((can_review_changes && change_count > 0).then(|| {
                                div()
                                    .id("native-agent-changes")
                                    .test_support()
                                    .role(Role::Button)
                                    .aria_label(translate(self.language, Key::AgentChatChatFileChanges).replace("{count}", &change_count.to_string()))
                                    .px(space(1))
                                    .py(px(2.0))
                                    .rounded(px(RADIUS_SMALL))
                                    .text_size(px(11.0))
                                    .text_color(palette.ink_2)
                                    .hover(|style| style.bg(palette.soft))
                                    .child(translate(self.language, Key::AgentChatChatFileChanges).replace("{count}", &change_count.to_string()))
                                    .on_click(cx.listener(|this, _, _window, cx| {
                                        this.toggle_checkpoint_panel(cx)
                                    }))
                            }))

                            .children(pickers.approval)
                            .children(pickers.model)
                            .children(pickers.thinking)
                            .children(
                                (usage.is_some()
                                    && self.state.session.thread.capabilities.usage_available())
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
                                    glyph: Icon::default().path(
                                        (if busy {
                                            if has_input {
                                                gpui_kit::assets::IconName::Clock
                                            } else {
                                                gpui_kit::assets::IconName::Square
                                            }
                                        } else {
                                            gpui_kit::assets::IconName::ArrowUp
                                        })
                                        .path(),
                                    ),
                                    bg: send_bg,
                                    fg: send_fg,
                                    radius: RADIUS_SMALL,
                                    ml_auto: false,
                                    on_click: Box::new(move |window, cx| {
                                        if !model_ready {
                                            return;
                                        }
                                        let _ = send_weak.update(cx, |this, cx| {
                                            if busy && !has_input {
                                                this.stop(cx);
                                            } else {
                                                this.send(window, cx);
                                            }
                                        });
                                    }),
                                },
                                cx,
                            )),
                    )
            .into_any_element()
    }
}

#[cfg(test)]
mod tests {
    use super::composer_placeholder;
    use crate::native_runtime::ModelSetup;

    #[test]
    fn placeholder_explains_model_setup_instead_of_echo() {
        let unconfigured = composer_placeholder(ModelSetup::Unconfigured);
        assert!(unconfigured.contains("Settings → AI → LLM Providers"));
        assert!(unconfigured.contains("DeepSeek"));
        assert!(!unconfigured.contains("Echo"));

        let demo = composer_placeholder(ModelSetup::DemoEcho);
        assert!(demo.contains("演示模式"));
        assert!(demo.contains("Echo"));

        let configured = composer_placeholder(ModelSetup::Configured);
        assert!(configured.contains("给 CGC Agent 发消息"));
    }
}
