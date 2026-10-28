//! 组合面板渲染：slash/mention 菜单、pickers、checkpoint 面板（B4b 拆分第三片）。
//!
//! 子模块可直接访问父模块私有字段。

use super::*;

impl NativeAgentView {
    /// Phase B2b-3b：native composer 的 legacy 渲染（render 内联链纯搬迁，行为不变）。
    /// Phase B2b-3d-2a：slash 菜单（legacy 与 shared composer 共用）。
    pub(super) fn render_slash_menu(&mut self, cx: &mut Context<Self>) -> Option<AnyElement> {
        let input_value = self.input.read(cx).value().to_string();
        let slash_open = input_value.trim_start().starts_with('/') && !self.slash_dismissed;
        let slash_matches = self.slash_entries(&input_value);
        let slash_selected = self.slash_index.min(slash_matches.len().saturating_sub(1));
        if !(slash_open && !slash_matches.is_empty()) {
            return None;
        }
        let palette = theme::palette_from_theme(cx);
        let items: Vec<CommandMenuItem> = slash_matches
            .iter()
            .enumerate()
            .map(|(index, entry)| CommandMenuItem {
                id: SharedString::from(format!("native-slash-{index}")),
                label: entry.label.clone(),
                description: entry.description.clone(),
                scope: entry.scope.clone(),
                group: entry.category.to_string(),
                selected: index == slash_selected,
            })
            .collect();
        let entries = slash_matches.clone();
        let hover_root = cx.entity().downgrade();
        let click_root = cx.entity().downgrade();
        let menu = render_command_menu(CommandMenuSpec {
            menu_id: SharedString::from("native-agent-slash-menu"),
            items,
            style: native_command_menu_style(palette),
            label_width: 150.0,
            width: Some(300.0),
            max_height: 320.0,
            row_height: None,
            on_hover: Some(Box::new(move |index, cx| {
                let _ = hover_root.update(cx, |this, cx| {
                    if this.slash_index != index {
                        this.slash_index = index;
                        cx.notify();
                    }
                });
            })),
            on_click: Box::new(move |index, window, cx| {
                let _ = click_root.update(cx, |this, cx| {
                    this.run_slash_entry(entries.clone(), index, window, cx);
                });
            }),
        });
        let detail = slash_matches.get(slash_selected).map(|entry| {
            div()
                .id("native-slash-detail")
                .w(px(280.0))
                .flex_1()
                .min_w(px(0.0))
                .max_h(px(320.0))
                .overflow_y_scroll()
                .p(space(1))
                .mt(space(1))
                .rounded(px(RADIUS_SMALL))
                .border_1()
                .border_color(palette.line)
                .bg(palette.view)
                .child(
                    div()
                        .text_size(px(9.0))
                        .text_color(palette.ink_3)
                        .child(entry.category),
                )
                .child(
                    div()
                        .flex()
                        .flex_row()
                        .items_center()
                        .gap(space(1))
                        .child(
                            div()
                                .text_size(px(11.0))
                                .text_color(palette.ink)
                                .child(entry.label.clone()),
                        )
                        .children(entry.scope.clone().map(|scope| {
                            div()
                                .text_size(px(9.0))
                                .text_color(palette.ink_3)
                                .child(scope)
                        })),
                )
                .child(
                    div()
                        .line_height(px(16.0))
                        .text_size(px(10.0))
                        .text_color(palette.ink_3)
                        .child(entry.description.clone()),
                )
        });
        let element = div()
            .absolute()
            .left(space(1))
            .right(space(1))
            .bottom(px(132.0))
            .flex()
            .flex_row()
            .items_start()
            .gap(space(2))
            .child(
                div()
                    .flex_none()
                    .mx(space(1))
                    .mt(space(1))
                    .mb(px(2.0))
                    .child(menu),
            )
            .children(detail);
        Some(element.into_any_element())
    }

    /// Phase B2b-3d-2b：@mention 菜单（legacy 与 shared composer 共用）。
    pub(super) fn render_mention_menu(&mut self, cx: &mut Context<Self>) -> Option<AnyElement> {
        let input_value = self.input.read(cx).value().to_string();
        let mention = trailing_mention(&input_value);
        let mention_matches = mention
            .as_ref()
            .map(|(_, query)| self.mention_matches(query))
            .unwrap_or_default();
        let slash_open = input_value.trim_start().starts_with('/') && !self.slash_dismissed;
        if !(mention.is_some() && !slash_open && !mention_matches.is_empty()) {
            return None;
        }
        let mention_selected = self
            .mention_index
            .min(mention_matches.len().saturating_sub(1));
        let palette = theme::palette_from_theme(cx);
        let query = mention
            .as_ref()
            .map(|(_, query)| query.clone())
            .unwrap_or_default();
        let element = div()
            .id("native-agent-mention-menu")
            .flex()
            .flex_col()
            .gap(px(1.0))
            .mx(space(1))
            .mt(space(1))
            .mb(px(2.0))
            .rounded(px(RADIUS_SMALL))
            .border_1()
            .border_color(palette.line)
            .bg(palette.card)
            .occlude()
            .child(
                div()
                    .px(space(1))
                    .py(px(2.0))
                    .text_size(px(9.0))
                    .text_color(palette.ink_3)
                    .child(format!("@{query} 匹配文件")),
            )
            .children(mention_matches.iter().enumerate().map(|(index, path)| {
                let selected = index == mention_selected;
                let path = path.clone();
                div()
                    .id(SharedString::from(format!("native-mention-{index}")))
                    .role(Role::Button)
                    .aria_label(path.clone())
                    .px(space(1))
                    .py(px(3.0))
                    .rounded(px(RADIUS_SMALL))
                    .bg(if selected { palette.soft } else { palette.card })
                    .text_size(px(11.0))
                    .text_color(if selected {
                        palette.accent
                    } else {
                        palette.ink_2
                    })
                    .child(path.clone())
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.insert_mention(path.clone(), window, cx);
                    }))
            }))
            .into_any_element();
        Some(element)
    }

    /// Phase B2b-3c/3d：native 主 composer 的共享版（flag=1 时使用）。
    /// 共享 send/stop + 附件 chips + attach + slash/mention 菜单 + queue 提示；
    /// context chip 为 ACP 面板能力，native 本就没有，不在此渲染。
    /// B3a：native 模型 / 推理强度 / 审批模式 picker（legacy 与 shared composer 共用）。
    /// capability gated：config options 不可用时三个 picker 都不渲染。
    pub(super) fn native_composer_pickers(
        &self,
        palette: theme::Palette,
        cx: &mut Context<Self>,
    ) -> NativeComposerPickers {
        let gating =
            NativeComposerGating::from_capabilities(self.state.session.thread.capabilities);
        if !gating.pickers_available() {
            return NativeComposerPickers::default();
        }
        let current_provider_id = self.metadata().model.provider_id.as_str().to_string();
        let current_model_id = self.metadata().model.id.as_str().to_string();
        let current_model_config = self
            .metadata()
            .providers
            .iter()
            .find(|provider| provider.id == self.metadata().model.provider_id.as_str())
            .map(|provider| provider.model_config(self.metadata().model.id.as_str()))
            .unwrap_or_default();
        let thinking_supported = current_model_config.supports_thinking;
        let effort_levels = current_model_config.reasoning_efforts.clone();
        let providers_for_menu = self.metadata().providers.clone();
        let model_root = cx.entity().downgrade();
        let thinking_root = cx.entity().downgrade();
        let approval_root = cx.entity().downgrade();
        let model_id_for_label = current_model_id.clone();
        let model_groups: Vec<PickerGroup> = providers_for_menu
            .iter()
            .filter_map(|provider| {
                let items: Vec<PickerItem> = provider
                    .models
                    .iter()
                    .filter(|model| provider.model_config(model).enabled)
                    .map(|model| {
                        PickerItem::new(
                            format!("native-model-{}-{}", provider.id, model),
                            model.clone(),
                        )
                        .selected(provider.id == current_provider_id && *model == current_model_id)
                    })
                    .collect();
                (!items.is_empty()).then(|| PickerGroup::titled(provider.name.clone(), items))
            })
            .collect();
        let model_targets: Vec<(String, String)> = providers_for_menu
            .iter()
            .flat_map(|provider| {
                provider
                    .models
                    .iter()
                    .filter(|model| provider.model_config(model).enabled)
                    .map(|model| (provider.id.clone(), model.clone()))
                    .collect::<Vec<_>>()
            })
            .collect();
        let model_picker = render_picker_popover(PickerPopoverSpec {
            popover_id: SharedString::from("native-model-picker"),
            trigger_id: SharedString::from("native-model-trigger"),
            trigger_label: model_id_for_label,
            trigger_tooltip: "选择模型".to_string(),
            trigger_max_width: None,
            anchor: Some(Anchor::BottomRight),
            groups: model_groups,
            style: native_picker_style(palette),
            width: 240.0,
            list_max_height: Some(280.0),
            search: None,
            on_select: Box::new(move |index, _window, cx| {
                let Some((provider_id, model_id)) = model_targets.get(index).cloned() else {
                    return;
                };
                let _ = model_root.update(cx, |this, cx| {
                    this.select_model(provider_id, model_id, cx);
                });
            }),
        });
        let current_effort = self
            .metadata()
            .effort_index
            .min(effort_levels.len().saturating_sub(1));
        let thinking_enabled = self.metadata().thinking_enabled;
        let thinking_label = if thinking_supported {
            if thinking_enabled {
                effort_levels
                    .get(current_effort)
                    .map(String::as_str)
                    .unwrap_or("Thinking")
            } else {
                "Off"
            }
        } else {
            "推理 —"
        };
        let effort_picker = (thinking_supported && !effort_levels.is_empty()).then(|| {
            let levels_len = effort_levels.len();
            let mut items: Vec<PickerItem> = effort_levels
                .iter()
                .enumerate()
                .map(|(level_index, label)| {
                    PickerItem::new(format!("native-thinking-{label}"), label.clone())
                        .selected(thinking_enabled && level_index == current_effort)
                })
                .collect();
            items.push(PickerItem::new("native-thinking-off", "Off").selected(!thinking_enabled));
            let root = thinking_root.clone();
            render_picker_popover(PickerPopoverSpec {
                popover_id: SharedString::from("native-thinking-picker"),
                trigger_id: SharedString::from("native-thinking-trigger"),
                trigger_label: thinking_label.to_string(),
                trigger_tooltip: "推理强度".to_string(),
                trigger_max_width: None,
                anchor: Some(Anchor::BottomRight),
                groups: vec![PickerGroup::flat(items)],
                style: native_picker_style(palette),
                width: 160.0,
                list_max_height: None,
                search: None,
                on_select: Box::new(move |index, _window, cx| {
                    let _ = root.update(cx, |this, cx| {
                        if index < levels_len {
                            if !this.metadata().thinking_enabled {
                                this.set_thinking_enabled(true, cx);
                            }
                            this.set_effort_index(index, cx);
                        } else {
                            this.set_thinking_enabled(false, cx);
                        }
                    });
                }),
            })
        });
        let current_approval = self.metadata().approval_mode;
        let approval_picker = {
            let modes = [ApprovalMode::Ask, ApprovalMode::Auto];
            let items: Vec<PickerItem> = modes
                .iter()
                .map(|mode| {
                    let label = match mode {
                        ApprovalMode::Ask => "Ask（逐次审批）",
                        ApprovalMode::Auto => "Auto（自动允许）",
                    };
                    PickerItem::new(format!("native-approval-{}", mode.label()), label)
                        .selected(*mode == current_approval)
                })
                .collect();
            let root = approval_root.clone();
            render_picker_popover(PickerPopoverSpec {
                popover_id: SharedString::from("native-approval-picker"),
                trigger_id: SharedString::from("native-approval-trigger"),
                trigger_label: current_approval.label().to_string(),
                trigger_tooltip: "审批模式".to_string(),
                trigger_max_width: None,
                anchor: Some(Anchor::BottomRight),
                groups: vec![PickerGroup::flat(items)],
                style: native_picker_style(palette),
                width: 200.0,
                list_max_height: None,
                search: None,
                on_select: Box::new(move |index, _window, cx| {
                    let Some(mode) = modes.get(index).copied() else {
                        return;
                    };
                    let _ = root.update(cx, |this, cx| {
                        this.set_approval_mode(mode, cx);
                    });
                }),
            })
        };
        NativeComposerPickers {
            model: Some(model_picker),
            thinking: effort_picker,
            approval: Some(approval_picker),
        }
    }
}
