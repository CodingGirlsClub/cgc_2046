//! 单个 issue 卡的 Pane 内容：由 Outline/Site Tree 打开 Tab 后渲染。
//!
//! 信息层级对齐 web 阅读器：章节 kicker → 单元类型 → 标题 →
//! user story（作为/前提/我能）→ story materials → objective 卡
//! （掌握态、验收、rubric、activity、材料）。
//! checklist 只服务 agent 上下文，不进入阅读器正文。

use super::super::super::*;
use super::super::ScreenContext;
use super::media;
use crate::agent_call::{AgentCall, LearningTarget};
use cgc_courses::content::{AgentActionSpec, AgentIntent, CourseIssue, CourseObjective};
use gpui_kit::base::SelectableText;
use gpui_kit::component::button::{Button, ButtonVariants};
use gpui_kit::component::collapsible::Collapsible;
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
    let has_objectives = !issue.objectives.is_empty();
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
                .flex()
                .flex_col()
                .gap(px(6.0))
                .child(
                    div()
                        .text_size(px(11.0))
                        .text_color(palette.accent_strong)
                        .child(translate(language, Key::CoursesLearningUserStory)),
                )
                .child(
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
                        .child(div().w_full().child(story)),
                )
                .into_any_element(),
        );
        if !issue.story_materials.is_empty() || has_objectives {
            children.push(
                div()
                    .h(px(1.0))
                    .w_full()
                    .bg(palette.line)
                    .into_any_element(),
            );
        }
    }

    if !issue.story_materials.is_empty() {
        let scope = media::material_scope(course_id, content.revision_number, issue_id);
        children.push(media::material_section(
            ctx, issue, &scope, language, palette, cx,
        ));
        if has_objectives {
            children.push(
                div()
                    .h(px(1.0))
                    .w_full()
                    .bg(palette.line)
                    .into_any_element(),
            );
        }
    }

    let objective_scope = media::issue_scope(course_id, content.revision_number, issue_id);
    let active_objective = ctx
        .selected_objective
        .get(&objective_scope)
        .cloned()
        .filter(|id| {
            issue
                .objectives
                .iter()
                .any(|objective| objective.id.as_deref().unwrap_or("objective") == id)
        })
        .or_else(|| {
            issue
                .objectives
                .first()
                .map(|objective| objective.id.clone().unwrap_or_else(|| "objective".into()))
        });

    if !issue.objectives.is_empty() {
        let root = cx.entity().downgrade();
        let mastered = issue
            .objectives
            .iter()
            .filter(|objective| {
                objective
                    .id
                    .as_deref()
                    .and_then(|id| {
                        ctx.projection.projection().and_then(|projection| {
                            projection.objectives.iter().find(|state| state.id == id)
                        })
                    })
                    .is_some_and(|state| state.mastery == "mastered")
            })
            .count();
        let total = issue.objectives.len();
        let practice_count = translate(language, Key::CoursesLearningPracticeMastered)
            .replace("{done}", &mastered.to_string())
            .replace("{total}", &total.to_string());
        let mode_label = match issue.kind.as_deref() {
            Some("thoughtwork") => Some(Key::CoursesLearningBySpeaking),
            Some("handwork") => Some(Key::CoursesLearningByDoing),
            _ => None,
        };
        let mut rows = Vec::new();
        for objective in &issue.objectives {
            let objective_key = objective.id.as_deref().unwrap_or("objective");
            let selected = active_objective.as_deref() == Some(objective_key);
            let state = objective.id.as_deref().and_then(|id| {
                ctx.projection.projection().and_then(|projection| {
                    projection.objectives.iter().find(|state| state.id == id)
                })
            });
            // owned：后续还要 &mut ctx 取 focus handle，不能让 projection 借用跨过去。
            let mastery = state
                .map(|state| state.mastery.clone())
                .unwrap_or_else(|| "unassessed".to_string());
            let mastery = mastery.as_str();
            let scope_for_click = objective_scope.clone();
            let id_for_click = objective_key.to_string();
            let root_for_click = root.clone();
            let required_label = if objective.required {
                translate(language, Key::CoursesLearningObjectiveRequired)
            } else {
                translate(language, Key::CoursesLearningObjectiveElective)
            };
            let description = objective
                .activity
                .clone()
                .filter(|text| !text.trim().is_empty());
            let row_label = objective
                .title
                .clone()
                .unwrap_or_else(|| objective_key.to_string());
            // 持久 FocusHandle：track_focus 后 gpui 对 focusable 元素内置
            // Enter/Space → click（elements/div.rs "Press enter, space to
            // trigger click, when the element is focused"），无需再挂 on_key_down。
            let focus_for_row = ctx
                .objective_row_focus
                .entry(format!("{objective_scope}:{objective_key}"))
                .or_insert_with(|| cx.focus_handle())
                .clone();
            let row = div()
                .id(SharedString::from(format!(
                    "issue-objective-row-{objective_key}"
                )))
                .test_support()
                .role(Role::Button)
                .aria_label(row_label)
                .track_focus(&focus_for_row)
                .flex()
                .flex_col()
                .gap(px(4.0))
                .px(space(2))
                .py(px(8.0))
                .rounded(px(RADIUS_MEDIUM))
                .border_1()
                .border_color(if selected {
                    palette.accent
                } else {
                    palette.line
                })
                .bg(if selected { palette.soft } else { palette.card })
                .hover(|style| style.bg(palette.soft))
                .child(
                    div()
                        .flex()
                        .flex_row()
                        .items_center()
                        .gap(px(8.0))
                        .child(
                            div()
                                .flex_none()
                                .size(px(12.0))
                                .rounded_full()
                                .border_1()
                                .border_color(if selected {
                                    palette.accent
                                } else {
                                    palette.line
                                })
                                .flex()
                                .items_center()
                                .justify_center()
                                .children(selected.then(|| {
                                    div().size(px(6.0)).rounded_full().bg(palette.accent)
                                })),
                        )
                        .child(
                            div()
                                .flex_1()
                                .min_w(px(0.0))
                                .text_size(px(13.0))
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
                                .text_size(px(10.0))
                                .text_color(if objective.required {
                                    palette.accent_strong
                                } else {
                                    palette.ink_3
                                })
                                .child(required_label),
                        )
                        .child(
                            div()
                                .text_size(px(10.0))
                                .text_color(mastery_color(palette, mastery))
                                .child(translate(language, mastery_key(mastery))),
                        ),
                )
                .children(description.map(|text| {
                    div()
                        .id(SharedString::from(format!(
                            "issue-objective-description-{objective_key}"
                        )))
                        .test_support()
                        .pl(px(20.0))
                        .text_size(px(11.0))
                        .text_color(palette.ink_3)
                        .child(text)
                }))
                .on_click(move |_, _, cx| {
                    let _ = root_for_click.update(cx, |this, cx| {
                        this.selected_objective
                            .insert(scope_for_click.clone(), id_for_click.clone());
                        cx.notify();
                    });
                });
            rows.push(row.into_any_element());
        }
        children.push(
            div()
                .id("issue-objective-practice")
                .test_support()
                .flex()
                .flex_col()
                .gap(px(8.0))
                .child(
                    div()
                        .flex()
                        .flex_row()
                        .items_center()
                        .justify_between()
                        .gap(px(8.0))
                        .child(
                            div()
                                .flex()
                                .flex_row()
                                .items_center()
                                .gap(px(6.0))
                                .child(
                                    Icon::default()
                                        .path(AssetIcon::Target.path())
                                        .text_color(palette.accent_strong)
                                        .small(),
                                )
                                .child(
                                    div()
                                        .text_size(px(11.0))
                                        .text_color(palette.accent_strong)
                                        .child(translate(language, Key::CoursesLearningPractice)),
                                )
                                .children(mode_label.map(|key| {
                                    div()
                                        .id("issue-practice-mode")
                                        .test_support()
                                        .px(px(6.0))
                                        .py(px(2.0))
                                        .rounded_full()
                                        .border_1()
                                        .border_color(palette.accent)
                                        .text_size(px(9.0))
                                        .text_color(palette.accent)
                                        .child(translate(language, key))
                                })),
                        )
                        .child(
                            div()
                                .id("issue-practice-mastered")
                                .test_support()
                                .text_size(px(10.0))
                                .text_color(palette.ink_3)
                                .child(practice_count),
                        ),
                )
                .child(div().flex().flex_col().gap(px(4.0)).children(rows))
                .into_any_element(),
        );
    }

    for objective in &issue.objectives {
        let objective_key = objective.id.as_deref().unwrap_or("objective");
        if active_objective.as_deref() != Some(objective_key) {
            continue;
        }
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
                            .child(translate(language, Key::CoursesLearningAnswerPrompt)),
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

        if !objective.materials.is_empty() {
            let key = format!("{objective_scope}:{objective_key}:materials");
            let expanded = ctx.expanded_objective_materials.contains(&key);
            let root = cx.entity().downgrade();
            let key_for_click = key.clone();
            let material_elements = if expanded {
                objective
                    .materials
                    .iter()
                    .enumerate()
                    .filter_map(|(index, material)| {
                        media::material_element(ctx, material, index, language, palette, cx)
                    })
                    .collect::<Vec<_>>()
            } else {
                Vec::new()
            };
            let content = if expanded {
                div()
                    .id(SharedString::from(format!(
                        "issue-objective-material-content-{objective_key}"
                    )))
                    .test_support()
                    .flex()
                    .flex_col()
                    .gap(px(4.0))
                    .children(material_elements)
                    .into_any_element()
            } else {
                div().into_any_element()
            };
            card.push(
                div()
                    .id(SharedString::from(format!(
                        "issue-objective-materials-{objective_key}"
                    )))
                    .test_support()
                    .pt(px(4.0))
                    .child(
                        div()
                            .id(SharedString::from(format!(
                                "issue-objective-materials-toggle-{objective_key}"
                            )))
                            .test_support()
                            .role(Role::Button)
                            .aria_label(translate(language, Key::CoursesLearningObjectiveMaterials))
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap(px(6.0))
                            .py(px(2.0))
                            .text_size(px(11.0))
                            .text_color(palette.accent_strong)
                            .child(if expanded { "▾" } else { "▸" })
                            .child(format!(
                                "{} ({})",
                                translate(language, Key::CoursesLearningObjectiveMaterials),
                                objective.materials.len()
                            ))
                            .on_click(move |_, _, cx| {
                                let _ = root.update(cx, |this, cx| {
                                    if !this.expanded_objective_materials.remove(&key_for_click) {
                                        this.expanded_objective_materials
                                            .insert(key_for_click.clone());
                                    }
                                    cx.notify();
                                });
                            }),
                    )
                    .child(
                        Collapsible::new()
                            .open(expanded)
                            .motion_id(key.clone())
                            .content(content),
                    )
                    .into_any_element(),
            );
        }

        let actions = effective_agent_actions(issue, objective, language);
        if !actions.is_empty() {
            let target = LearningTarget::Objective {
                course_id: course_id.to_string(),
                revision: content.revision_number,
                issue_id: issue_id.to_string(),
                objective_id: objective_key.to_string(),
            };
            let mut buttons = Vec::with_capacity(actions.len());
            for action in actions {
                let call = AgentCall::from_action(&action, target.clone());
                let prompt = agent_prompt(action.intent, language).to_string();
                let label = action.label.clone();
                let root = cx.entity().downgrade();
                let id =
                    SharedString::from(format!("issue-agent-action-{objective_key}-{}", action.id));
                let mut button = Button::new(id).label(label.clone());
                if !action.primary {
                    button = button.ghost();
                }
                buttons.push(
                    button
                        .small()
                        .on_click(move |_, window, cx| {
                            let _ = root.update(cx, |this, cx| {
                                this.apply_agent_call(
                                    call.clone(),
                                    prompt.clone(),
                                    label.clone(),
                                    window,
                                    cx,
                                );
                            });
                        })
                        .into_any_element(),
                );
            }
            card.push(
                div()
                    .id(SharedString::from(format!(
                        "issue-objective-actions-{objective_key}"
                    )))
                    .test_support()
                    .flex()
                    .flex_row()
                    .flex_wrap()
                    .items_center()
                    .gap(space(1))
                    .pt(px(4.0))
                    .children(buttons)
                    .into_any_element(),
            );
        }

        if !objective.rubric.is_empty() {
            let key = format!("{objective_scope}:{objective_key}:rubric");
            let expanded = ctx.expanded_objective_rubric.contains(&key);
            let root = cx.entity().downgrade();
            let key_for_click = key.clone();
            let rubric = if expanded {
                objective
                    .rubric
                    .iter()
                    .enumerate()
                    .map(|(index, item)| {
                        div()
                            .id(SharedString::from(format!(
                                "issue-objective-rubric-item-{objective_key}-{index}"
                            )))
                            .test_support()
                            .text_size(px(12.0))
                            .text_color(palette.ink_3)
                            .child(format!("✓ {}", item.text))
                            .into_any_element()
                    })
                    .collect::<Vec<_>>()
            } else {
                Vec::new()
            };
            let content = if expanded {
                div()
                    .flex()
                    .flex_col()
                    .gap(px(4.0))
                    .pt(px(4.0))
                    .children(rubric)
            } else {
                div()
            };
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
                    .child(
                        div()
                            .id(SharedString::from(format!(
                                "issue-objective-rubric-toggle-{objective_key}"
                            )))
                            .test_support()
                            .role(Role::Button)
                            .aria_label(translate(language, Key::CoursesLearningRubricToggle))
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap(px(6.0))
                            .text_size(px(11.0))
                            .text_color(palette.accent_strong)
                            .child(if expanded { "▾" } else { "▸" })
                            .child(translate(language, Key::CoursesLearningRubricToggle))
                            .on_click(move |_, _, cx| {
                                let _ = root.update(cx, |this, cx| {
                                    if !this.expanded_objective_rubric.remove(&key_for_click) {
                                        this.expanded_objective_rubric
                                            .insert(key_for_click.clone());
                                    }
                                    cx.notify();
                                });
                            }),
                    )
                    .child(
                        Collapsible::new()
                            .open(expanded)
                            .motion_id(key.clone())
                            .content(content),
                    )
                    .into_any_element(),
            );
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

fn effective_agent_actions(
    issue: &CourseIssue,
    objective: &CourseObjective,
    language: Language,
) -> Vec<AgentActionSpec> {
    if !objective.agent_actions.is_empty() {
        return objective.agent_actions.clone();
    }
    match issue.kind.as_deref() {
        Some("thoughtwork") => vec![
            default_agent_action(
                "default-answer",
                Key::CoursesLearningAgentActionAnswer,
                AgentIntent::Answer,
                true,
                language,
            ),
            default_agent_action(
                "default-hint",
                Key::CoursesLearningAgentActionHint,
                AgentIntent::Hint,
                false,
                language,
            ),
        ],
        Some("handwork") => vec![
            default_agent_action(
                "default-inspect-artifact",
                Key::CoursesLearningAgentActionInspectArtifact,
                AgentIntent::InspectArtifact,
                true,
                language,
            ),
            default_agent_action(
                "default-hint",
                Key::CoursesLearningAgentActionHint,
                AgentIntent::Hint,
                false,
                language,
            ),
        ],
        _ => Vec::new(),
    }
}

fn default_agent_action(
    id: &str,
    label: Key,
    intent: AgentIntent,
    primary: bool,
    language: Language,
) -> AgentActionSpec {
    AgentActionSpec {
        id: id.to_string(),
        label: translate(language, label).to_string(),
        intent,
        primary,
    }
}

fn agent_prompt(intent: AgentIntent, language: Language) -> &'static str {
    translate(
        language,
        match intent {
            AgentIntent::Answer => Key::CoursesLearningAgentPromptAnswer,
            AgentIntent::Hint => Key::CoursesLearningAgentPromptHint,
            AgentIntent::Explain => Key::CoursesLearningAgentPromptExplain,
            AgentIntent::Summarize => Key::CoursesLearningAgentPromptSummarize,
            AgentIntent::InspectWorkspace => Key::CoursesLearningAgentPromptInspectWorkspace,
            AgentIntent::CreateFile => Key::CoursesLearningAgentPromptCreateFile,
            AgentIntent::Run => Key::CoursesLearningAgentPromptRun,
            AgentIntent::InspectArtifact => Key::CoursesLearningAgentPromptInspectArtifact,
            AgentIntent::Submit => Key::CoursesLearningAgentPromptSubmit,
            AgentIntent::Review => Key::CoursesLearningAgentPromptReview,
        },
    )
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
