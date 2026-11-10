//! 单个 issue 卡的 Pane 内容：由 Outline/Site Tree 打开 Tab 后渲染。
//!
//! 信息层级对齐 web 阅读器：章节 kicker → 单元类型 → 标题 →
//! user story（作为/前提/我能）→ story materials → objective 卡
//! （掌握态、验收、rubric、activity、材料）。
//! checklist 只服务 agent 上下文，不进入阅读器正文。

use super::super::super::*;
use super::super::ScreenContext;
use super::media;
use gpui_kit::base::SelectableText;
use gpui_kit::component::description_list::{DescriptionItem, DescriptionList};

pub(in crate::root_view) fn render_issue_card(
    ctx: &mut ScreenContext<'_>,
    course_id: &str,
    issue_id: &str,
    language: Language,
    palette: &theme::Palette,
    cx: &mut Context<RootView>,
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

    if let Some((index, title)) = issue.chapter_id.as_deref().and_then(|chapter_id| {
        content
            .document
            .chapters
            .iter()
            .position(|chapter| chapter.id.as_deref() == Some(chapter_id))
            .map(|index| (index, content.document.chapters[index].title.clone()))
    }) {
        let chapter_title = title
            .clone()
            .filter(|title| !title.trim().is_empty())
            .unwrap_or_else(|| {
                translate(language, Key::CoursesLearningChapterFallback).to_string()
            });
        children.push(
            div()
                .id("issue-card-kicker")
                .test_support()
                .text_size(px(11.0))
                .text_color(palette.accent_strong)
                .child(
                    translate(language, Key::CoursesLearningChapterKicker)
                        .replace("{index}", &format!("{:02}", index + 1))
                        .replace("{title}", &chapter_title),
                )
                .into_any_element(),
        );
    }

    if let Some(kind_key) = issue.kind.as_deref().and_then(kind_label_key) {
        children.push(
            div()
                .id("issue-card-kind")
                .test_support()
                .text_size(px(11.0))
                .text_color(palette.accent_strong)
                .child(
                    translate(language, Key::CoursesLearningUnitMeta)
                        .replace("{kind}", translate(language, kind_key)),
                )
                .into_any_element(),
        );
    }

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
    let story_as = issue
        .as_a
        .as_deref()
        .filter(|value| !value.trim().is_empty());
    let story_given = issue
        .given
        .iter()
        .filter(|value| !value.trim().is_empty())
        .cloned()
        .collect::<Vec<_>>();
    let story_goal = issue
        .goal
        .as_deref()
        .filter(|value| !value.trim().is_empty());
    if story_as.is_some() || !story_given.is_empty() || story_goal.is_some() {
        let story_label = |key: Key| {
            div()
                .text_size(px(11.0))
                .text_color(palette.accent)
                .child(translate(language, key))
                .into_any_element()
        };
        let story_value = |id: &str, text: String, color: gpui_kit::Hsla| {
            div()
                .id(SharedString::from(id.to_string()))
                .test_support()
                .text_size(px(13.0))
                .text_color(color)
                .child(SelectableText::new(
                    SharedString::from(format!("{id}-text")),
                    text,
                ))
                .into_any_element()
        };

        let mut story = DescriptionList::horizontal()
            .columns(1)
            .label_width(px(36.0))
            .bordered(false)
            .with_size(gpui_kit::component::Size::Small);
        if let Some(as_a) = story_as {
            story =
                story.child(
                    DescriptionItem::new(story_label(Key::CoursesLearningStoryAs)).value(
                        story_value("issue-card-story-as", as_a.to_string(), palette.ink_2),
                    ),
                );
        }
        if !story_given.is_empty() {
            story = story.child(
                DescriptionItem::new(story_label(Key::CoursesLearningStoryGiven)).value(
                    story_value(
                        "issue-card-story-given",
                        story_given.join("、"),
                        palette.ink_2,
                    ),
                ),
            );
        }
        if let Some(goal) = story_goal {
            story = story.child(
                DescriptionItem::new(story_label(Key::CoursesLearningStoryGoal)).value(
                    story_value("issue-card-story-goal", goal.to_string(), palette.ink),
                ),
            );
        }

        children.push(
            div()
                .id("issue-card-user-story")
                .test_support()
                .role(Role::Group)
                .aria_label(translate(language, Key::CoursesLearningUserStory))
                .flex()
                .flex_col()
                .gap(px(4.0))
                .p(space(2))
                .rounded(px(RADIUS_MEDIUM))
                .border_1()
                .border_color(palette.line)
                .bg(palette.card)
                .child(
                    div()
                        .text_size(px(11.0))
                        .text_color(palette.accent_strong)
                        .child(translate(language, Key::CoursesLearningUserStory)),
                )
                .child(div().w_full().child(story))
                .into_any_element(),
        );
    }

    for (material_index, material) in issue.story_materials.iter().enumerate() {
        if let Some(element) =
            media::material_element(ctx, material, material_index, language, palette, cx)
        {
            children.push(element);
        }
    }

    for objective in &issue.objectives {
        let objective_key = objective.id.as_deref().unwrap_or("objective");
        let state = objective.id.as_deref().and_then(|id| {
            ctx.projection
                .projection()
                .and_then(|projection| projection.objectives.iter().find(|state| state.id == id))
        });
        let mastery = state
            .map(|state| state.mastery.as_str())
            .unwrap_or("unassessed");

        let mut card = Vec::new();
        card.push(
            div()
                .flex()
                .flex_row()
                .items_center()
                .gap(px(8.0))
                .child(div().size(px(7.0)).rounded_full().bg(palette.accent))
                .child(
                    div()
                        .flex_1()
                        .min_w(px(0.0))
                        .text_size(px(14.0))
                        .text_color(palette.ink)
                        .child(
                            objective
                                .title
                                .clone()
                                .unwrap_or_else(|| "Objective".to_string()),
                        ),
                )
                .child(
                    div()
                        .id(SharedString::from(format!(
                            "issue-card-mastery-{objective_key}"
                        )))
                        .test_support()
                        .text_size(px(10.0))
                        .text_color(mastery_color(palette, mastery))
                        .child(translate(language, mastery_key(mastery))),
                )
                .into_any_element(),
        );

        if let Some(assessment) = objective
            .assessment
            .clone()
            .filter(|text| !text.trim().is_empty())
        {
            card.push(
                div()
                    .id(SharedString::from(format!(
                        "issue-card-assessment-{objective_key}"
                    )))
                    .test_support()
                    .flex()
                    .flex_row()
                    .items_start()
                    .gap(px(8.0))
                    .text_size(px(13.0))
                    .text_color(palette.ink_2)
                    .child(
                        div()
                            .flex_none()
                            .text_size(px(10.0))
                            .text_color(palette.accent_strong)
                            .child(translate(language, Key::CoursesLearningAssessment)),
                    )
                    .child(div().flex_1().min_w(px(0.0)).child(SelectableText::new(
                        SharedString::from(format!(
                            "issue-assessment-{course_id}-{issue_id}-{}",
                            objective.id.as_deref().unwrap_or("objective")
                        )),
                        assessment,
                    )))
                    .into_any_element(),
            );
        }

        if !objective.rubric.is_empty() {
            let mut rubric = Vec::with_capacity(objective.rubric.len() + 1);
            rubric.push(
                div()
                    .text_size(px(10.0))
                    .text_color(palette.accent_strong)
                    .child(translate(language, Key::CoursesLearningRubric))
                    .into_any_element(),
            );
            for item in &objective.rubric {
                rubric.push(
                    div()
                        .text_size(px(12.0))
                        .text_color(palette.ink_3)
                        .child(format!("✓ {}", item.text))
                        .into_any_element(),
                );
            }
            card.push(
                div()
                    .id(SharedString::from(format!(
                        "issue-card-rubric-{objective_key}"
                    )))
                    .test_support()
                    .mt(px(4.0))
                    .pt(px(8.0))
                    .border_t_1()
                    .border_color(palette.line)
                    .flex()
                    .flex_col()
                    .gap(px(4.0))
                    .children(rubric)
                    .into_any_element(),
            );
        }

        if let Some(activity) = objective
            .activity
            .clone()
            .filter(|text| !text.trim().is_empty())
        {
            card.push(
                div()
                    .text_size(px(13.0))
                    .text_color(palette.ink_3)
                    .child(SelectableText::new(
                        SharedString::from(format!(
                            "issue-activity-{course_id}-{issue_id}-{}",
                            objective.id.as_deref().unwrap_or("objective")
                        )),
                        activity,
                    ))
                    .into_any_element(),
            );
        }

        for (material_index, material) in objective.materials.iter().enumerate() {
            if let Some(element) =
                media::material_element(ctx, material, material_index, language, palette, cx)
            {
                card.push(element);
            }
        }

        children.push(
            div()
                .id(SharedString::from(format!(
                    "issue-card-objective-{objective_key}"
                )))
                .test_support()
                .flex()
                .flex_col()
                .gap(px(8.0))
                .p(space(2))
                .rounded(px(RADIUS_MEDIUM))
                .border_1()
                .border_color(palette.line)
                .bg(palette.card)
                .children(card)
                .into_any_element(),
        );
    }

    div()
        .id("issue-card")
        .test_support()
        .flex()
        .flex_col()
        .gap(space(2))
        .children(children)
        .into_any_element()
}

fn kind_label_key(kind: &str) -> Option<Key> {
    match kind {
        "thoughtwork" => Some(Key::CoursesLearningKindThoughtwork),
        "handwork" => Some(Key::CoursesLearningKindHandwork),
        _ => None,
    }
}

fn mastery_key(mastery: &str) -> Key {
    match mastery {
        "mastered" => Key::CoursesLearningMasteryMastered,
        "developing" | "learning" => Key::CoursesLearningMasteryDeveloping,
        "needs_review" => Key::CoursesLearningMasteryNeedsReview,
        _ => Key::CoursesLearningMasteryUnassessed,
    }
}

fn mastery_color(palette: &theme::Palette, mastery: &str) -> gpui_kit::Hsla {
    match mastery {
        "mastered" => palette.accent,
        "developing" | "learning" => palette.accent_strong,
        "needs_review" => palette.warning,
        _ => palette.ink_3,
    }
}
