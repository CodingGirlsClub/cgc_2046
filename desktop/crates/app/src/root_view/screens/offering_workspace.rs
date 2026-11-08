use super::super::*;
use cgc_platform::workspace::WorkspaceSummary;

pub(in crate::root_view) fn render_workspace_badge(
    workspaces: &[WorkspaceSummary],
    workspace_id: Option<&str>,
    language: Language,
    palette: &theme::Palette,
) -> Option<AnyElement> {
    let workspace = workspaces
        .iter()
        .find(|workspace| Some(workspace.id.as_str()) == workspace_id)?;
    let label = format!(
        "{} · {}",
        translate(language, Key::NavWorkspaceOrigin),
        workspace.name
    );
    Some(
        div()
            .id(format!("workspace-origin-{}", workspace.id))
            .test_support()
            .role(Role::Status)
            .aria_label(label.clone())
            .text_size(px(11.0))
            .text_color(palette.ink_3)
            .child(label)
            .into_any_element(),
    )
}

pub(in crate::root_view) fn render_workspace_link(
    workspaces: &[WorkspaceSummary],
    workspace_id: Option<&str>,
    suffix: &str,
    title: &str,
    language: Language,
    palette: &theme::Palette,
    cx: &mut Context<RootView>,
) -> Option<AnyElement> {
    let workspace = workspaces
        .iter()
        .find(|workspace| Some(workspace.id.as_str()) == workspace_id && workspace.can_access)?;
    let path = crate::routing::workspace_path(&workspace.slug, suffix);
    let label = translate(language, Key::CoursesOpenWorkspace);
    let title = title.to_string();
    Some(
        div()
            .id("course-open-workspace")
            .test_support()
            .role(Role::Link)
            .aria_label(label)
            .text_size(px(12.0))
            .text_color(palette.accent)
            .child(label)
            .on_click(cx.listener(move |this, _, _, cx| {
                // 跨台打开走统一 tab 生命周期：先持久化源台 → 切台恢复目标台 →
                // 插入并持久化目标 tab；只 navigate 会让目标页没有 tab 归属（R10）。
                this.open_page_tab(&path, title.clone(), cx);
                cx.notify();
            }))
            .into_any_element(),
    )
}
