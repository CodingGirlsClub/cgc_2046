//! Agent Registry：只展示内置签名清单里的 agent，安装动作经签名清单进入。

use super::super::super::*;
use super::super::ScreenContext;

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

    let body = if loading && rows.is_empty() {
        div()
            .text_size(px(12.0))
            .text_color(palette.ink_3)
            .child(translate(language, Key::AgentRegistryLoading))
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
            .child(
                div()
                    .id("agent-registry-retry")
                    .px(space(2))
                    .py(px(5.0))
                    .rounded(px(RADIUS_MEDIUM))
                    .bg(palette.accent)
                    .text_color(palette.canvas)
                    .child(translate(language, Key::AgentRegistryRetry))
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.agent_registry_started = false;
                        this.start_agent_registry_load(cx);
                    })),
            )
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
                                div()
                                    .text_size(px(11.0))
                                    .text_color(palette.ink_3)
                                    .child(status_text),
                            )
                            .children(can_install.then(|| {
                                div()
                                    .id(SharedString::from(format!("agent-install-{}", entry.id)))
                                    .px(space(2))
                                    .py(px(4.0))
                                    .rounded(px(RADIUS_SMALL))
                                    .bg(palette.accent)
                                    .text_color(palette.canvas)
                                    .text_size(px(11.0))
                                    .child(install_label)
                                    .on_click(cx.listener(move |this, _, _, cx| {
                                        this.install_agent(&id, cx);
                                    }))
                            })),
                    )
                    .child(
                        div()
                            .text_size(px(11.0))
                            .text_color(palette.ink_3)
                            .child(entry.login_hint.clone()),
                    )
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
