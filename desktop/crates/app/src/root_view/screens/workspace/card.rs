//! 单个 issue 卡的 Pane 内容：由 Outline/Site Tree 打开 Tab 后渲染。
//!
//! 与旧 learning 页面不同，这里只渲染当前卡，不再把所有 issue 平铺。

use super::super::super::*;
use super::super::ScreenContext;

pub(in crate::root_view) fn render_issue_card(
    ctx: &mut ScreenContext<'_>,
    course_id: &str,
    issue_id: &str,
    language: Language,
    palette: &theme::Palette,
) -> AnyElement {
    let Some(content) = ctx.content.content().cloned() else {
        return render_loading_state(language, Key::CoursesLearningContentLoading, palette)
            .into_any_element();
    };
    if content.course_id != course_id {
        return div()
            .text_color(palette.ink_3)
            .child(translate(language, Key::CoursesLearningContextRequired))
            .into_any_element();
    }
    let Some(issue) = content
        .document
        .issues
        .iter()
        .find(|issue| issue.id.as_deref() == Some(issue_id))
    else {
        return div()
            .text_color(palette.ink_3)
            .child(translate(language, Key::CoursesLearningContentEmpty))
            .into_any_element();
    };

    let mut children = Vec::new();
    children.push(
        div()
            .text_size(px(12.0))
            .text_color(palette.ink_3)
            .child(content.title.clone())
            .into_any_element(),
    );
    children.push(
        div()
            .text_size(px(24.0))
            .text_color(palette.ink)
            .child(
                issue
                    .title
                    .clone()
                    .unwrap_or_else(|| "Untitled".to_string()),
            )
            .into_any_element(),
    );
    if let Some(goal) = issue.goal.clone() {
        children.push(
            div()
                .text_size(px(13.0))
                .text_color(palette.ink_2)
                .child(goal)
                .into_any_element(),
        );
    }
    if !issue.checklist.is_empty() {
        let mut checklist = Vec::new();
        checklist.push(
            div()
                .text_size(px(12.0))
                .text_color(palette.ink_3)
                .child(translate(language, Key::WorkspaceOutlineTitle))
                .into_any_element(),
        );
        for item in &issue.checklist {
            checklist.push(
                div()
                    .text_size(px(12.0))
                    .text_color(palette.ink_2)
                    .child(format!("· {}", item.text))
                    .into_any_element(),
            );
        }
        children.push(
            div()
                .flex()
                .flex_col()
                .gap(px(2.0))
                .children(checklist)
                .into_any_element(),
        );
    }

    for material in issue.story_materials.iter() {
        if let Some(element) = material_element(material, palette, children.len()) {
            children.push(element);
        }
    }
    for objective in &issue.objectives {
        let mut header = format!(
            "{} · {}",
            objective
                .title
                .clone()
                .unwrap_or_else(|| "Objective".to_string()),
            if objective.required {
                "required"
            } else {
                "optional"
            }
        );
        if let Some(activity) = &objective.activity {
            header.push_str(&format!(" · {activity}"));
        }
        children.push(
            div()
                .text_size(px(12.0))
                .text_color(palette.ink_3)
                .child(header)
                .into_any_element(),
        );
        for material in &objective.materials {
            if let Some(element) = material_element(material, palette, children.len()) {
                children.push(element);
            }
        }
    }

    div()
        .id("issue-card")
        .flex()
        .flex_col()
        .gap(space(2))
        .children(children)
        .into_any_element()
}

fn material_element(
    material: &cgc_courses::content::TypedMaterial,
    palette: &theme::Palette,
    index: usize,
) -> Option<AnyElement> {
    if matches!(
        material.kind,
        cgc_courses::content::MaterialKind::Text | cgc_courses::content::MaterialKind::Markdown
    ) {
        let body = material.body.as_deref()?;
        if body.trim().is_empty() {
            return None;
        }
        return Some(
            cgc_agent_ui::markdown_view::markdown_text_view_plain(
                format!("issue-material-{index}"),
                body,
            )
            .into_any_element(),
        );
    }
    let url = material.url.clone()?;
    Some(
        div()
            .text_size(px(12.0))
            .text_color(palette.accent)
            .child(url)
            .into_any_element(),
    )
}
