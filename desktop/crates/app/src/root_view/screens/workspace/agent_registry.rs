//! Agent Registry：只展示内置签名清单里的 agent，安装动作经签名清单进入。

use super::super::super::*;
use super::super::ScreenContext;
use gpui_kit::component::button::{Button, ButtonVariants};
use gpui_kit::component::input::Input;
use gpui_kit::component::skeleton::Skeleton;
use gpui_kit::component::tag::Tag;

pub(in crate::root_view) fn render_agent_registry(
    ctx: &mut ScreenContext<'_>,
    language: Language,
    palette: &theme::Palette,
    cx: &mut Context<RootView>,
) -> AnyElement {
    let rows = ctx.agent_registry_rows.clone();
    let loading = ctx.agent_registry_loading;
    let error = ctx.agent_registry_error.clone();
    let installing = ctx.agent_installing.clone();
    let install_error = ctx.agent_install_error.clone();
    let install_stage = ctx.agent_install_stage.clone();
    let query = ctx.agent_registry_query.clone();
    let filter = ctx.agent_registry_filter;
    let search_input = ctx.agent_registry_search_input.clone();
    let rows = rows
        .into_iter()
        // v1 Registry 只提供签名清单里的 npx agent；OMP 是 BYO native，仍在
        // Agent 选择器/运行路径里支持，但不进入“安装”列表。
        .filter(|row| is_registry_installable(&row.entry))
        .filter(|row| match filter {
            AgentRegistryFilter::All => true,
            AgentRegistryFilter::Installed => matches!(row.status, AgentStatus::Ready { .. }),
            AgentRegistryFilter::NotInstalled => !matches!(row.status, AgentStatus::Ready { .. }),
        })
        .filter(|row| {
            query.trim().is_empty()
                || row
                    .entry
                    .display_name
                    .to_lowercase()
                    .contains(&query.trim().to_lowercase())
        })
        .collect::<Vec<_>>();

    let body = if loading && rows.is_empty() {
        div()
            .flex()
            .flex_col()
            .gap(space(2))
            .children((0..3).map(|_| {
                div()
                    .flex()
                    .flex_col()
                    .gap(px(6.0))
                    .child(Skeleton::new().h(px(16.0)).w(px(180.0)))
                    .child(Skeleton::new().h(px(12.0)).w(px(120.0)))
                    .into_any_element()
            }))
            .into_any_element()
    } else if let Some(error) = error {
        div()
            .flex()
            .flex_col()
            .gap(space(2))
            .child(
                div()
                    .text_size(px(12.0))
                    .text_color(palette.danger)
                    .child(error),
            )
            .child({
                let root = cx.entity().downgrade();
                Button::new("agent-registry-retry")
                    .label(translate(language, Key::AgentRegistryRetry))
                    .primary()
                    .on_click(move |_, _, cx| {
                        let _ = root.update(cx, |this, cx| {
                            this.agent_registry_started = false;
                            this.start_agent_registry_load(cx);
                        });
                    })
            })
            .into_any_element()
    } else if rows.is_empty() {
        div()
            .text_size(px(12.0))
            .text_color(palette.ink_3)
            .child("没有匹配的 agent")
            .into_any_element()
    } else {
        let mut cards = Vec::new();
        for row in rows {
            let entry = row.entry.clone();
            let status_text = match &row.status {
                AgentStatus::Ready { version } => {
                    format!(
                        "{} · {version}",
                        translate(language, Key::AgentRegistryInstalled)
                    )
                }
                AgentStatus::Missing => "未安装".to_string(),
                AgentStatus::Outdated { found, required } => {
                    format!("版本过旧：{found} < {required}")
                }
                AgentStatus::NodeUnavailable { required, found } => format!(
                    "Node {required} 不可用（当前 {}）",
                    found.as_deref().unwrap_or("missing")
                ),
                AgentStatus::Error(error) => format!("检测失败：{error}"),
            };
            let is_npx = matches!(
                entry.distribution,
                cgc_platform::registry::manifest::Distribution::Npx { .. }
            );
            let can_install = !matches!(row.status, AgentStatus::Ready { .. }) && is_npx;
            let status_tag = match &row.status {
                AgentStatus::Ready { .. } => Tag::success(),
                AgentStatus::Missing => Tag::secondary(),
                AgentStatus::Outdated { .. } | AgentStatus::NodeUnavailable { .. } => {
                    Tag::warning()
                }
                AgentStatus::Error(_) => Tag::danger(),
            };
            let is_installing = installing.as_deref() == Some(entry.id.as_str());
            let install_label = if is_installing {
                "安装中…"
            } else {
                translate(language, Key::AgentRegistryInstall)
            };
            let id = entry.id.clone();
            cards.push(
                div()
                    .id(SharedString::from(format!("agent-card-{}", entry.id)))
                    .flex()
                    .flex_col()
                    .gap(space(1))
                    .p(space(2))
                    .rounded(px(RADIUS_MEDIUM))
                    .border_1()
                    .border_color(palette.line)
                    .bg(palette.card)
                    .child(
                        div()
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap(space(2))
                            .child(
                                div()
                                    .flex_1()
                                    .text_size(px(14.0))
                                    .text_color(palette.ink)
                                    .child(entry.display_name.clone()),
                            )
                            .child(
                                status_tag
                                    .child(status_text)
                                    .with_size(gpui_kit::component::Size::Small),
                            )
                            .children(can_install.then(|| {
                                let root = cx.entity().downgrade();
                                Button::new(SharedString::from(format!(
                                    "agent-install-{}",
                                    entry.id
                                )))
                                .label(install_label)
                                .primary()
                                .with_size(gpui_kit::component::Size::Small)
                                .on_click(move |_, _, cx| {
                                    let _ = root.update(cx, |this, cx| {
                                        this.install_agent(&id, cx);
                                    });
                                })
                            })),
                    )
                    .child(
                        div()
                            .text_size(px(11.0))
                            .text_color(palette.ink_3)
                            .child(entry.login_hint.clone()),
                    )
                    .children(if is_installing {
                        install_stage.clone().map(|stage| {
                            div()
                                .text_size(px(10.0))
                                .text_color(palette.accent)
                                .child(stage)
                                .into_any_element()
                        })
                    } else {
                        None
                    })
                    .children(
                        (!is_npx && !matches!(row.status, AgentStatus::Ready { .. })).then(|| {
                            div()
                                .text_size(px(11.0))
                                .text_color(palette.ink_3)
                                .child(translate(language, Key::AgentRegistryNativeHint))
                        }),
                    )
                    .into_any_element(),
            );
        }
        div()
            .flex()
            .flex_col()
            .gap(space(2))
            .children(cards)
            .into_any_element()
    };

    div()
        .id("agent-registry")
        .flex()
        .flex_col()
        .gap(space(2))
        .child(
            div()
                .text_size(px(24.0))
                .text_color(palette.ink)
                .child(translate(language, Key::AgentRegistryTitle)),
        )
        .child(
            div()
                .text_size(px(12.0))
                .text_color(palette.ink_3)
                .child(translate(language, Key::AgentRegistrySubtitle)),
        )
        .child(match search_input {
            Some(input) => Input::new(&input)
                .w_full()
                .with_size(gpui_kit::component::Size::Small)
                .into_any_element(),
            None => div()
                .id("agent-registry-search")
                .flex()
                .items_center()
                .h(px(32.0))
                .px(space(2))
                .rounded(px(RADIUS_MEDIUM))
                .border_1()
                .border_color(palette.line)
                .text_size(px(11.0))
                .text_color(palette.ink_3)
                .child("搜索 agent")
                .into_any_element(),
        })
        .child(
            div().flex().flex_row().gap(space(1)).children(
                [
                    (AgentRegistryFilter::All, "全部"),
                    (AgentRegistryFilter::Installed, "已安装"),
                    (AgentRegistryFilter::NotInstalled, "未安装"),
                ]
                .into_iter()
                .map(|(value, label)| {
                    div()
                        .id(SharedString::from(format!("agent-filter-{label}")))
                        .px(space(2))
                        .py(px(3.0))
                        .rounded(px(RADIUS_SMALL))
                        .bg(if filter == value {
                            palette.accent
                        } else {
                            palette.card
                        })
                        .text_color(if filter == value {
                            palette.canvas
                        } else {
                            palette.ink_2
                        })
                        .text_size(px(11.0))
                        .child(label)
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.set_agent_registry_filter(value, cx);
                        }))
                        .into_any_element()
                }),
            ),
        )
        .children(install_error.map(|error| {
            div()
                .text_size(px(12.0))
                .text_color(palette.danger)
                .child(error)
                .into_any_element()
        }))
        .child(body)
        .into_any_element()
}

fn is_registry_installable(entry: &cgc_platform::registry::manifest::AgentEntry) -> bool {
    matches!(
        entry.distribution,
        cgc_platform::registry::manifest::Distribution::Npx { .. }
    )
}

#[cfg(test)]
mod tests {
    use super::is_registry_installable;
    use cgc_platform::registry::manifest::Registry;

    #[test]
    fn only_npx_agents_are_registry_installable() {
        let registry = Registry::builtin().expect("registry");
        assert!(!is_registry_installable(registry.get("omp").expect("omp")));
        assert!(is_registry_installable(
            registry.get("codex").expect("codex")
        ));
        assert!(is_registry_installable(
            registry.get("claude_code").expect("claude")
        ));
    }
}
