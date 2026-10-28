//! plan/goal/todos 卡片（B4b-b'2：从 native 视图抽出的共享渲染）。
//!
//! 纯 spec 入参；状态 glyph/颜色由各栈映射好传入，共享层不感知 ItemStatus。

use gpui_kit::*;

/// plan 卡样式（各栈从自己的 theme 构造）。
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PlanCardStyle {
    pub line: Hsla,
    pub card: Hsla,
    pub ink_2: Hsla,
    pub ink_3: Hsla,
    pub radius: f32,
}

#[derive(Clone, Debug, PartialEq)]
pub struct PlanStepView {
    pub title: String,
    pub glyph: &'static str,
    pub color: Hsla,
}

#[derive(Clone, Debug, PartialEq)]
pub struct PlanTodoView {
    pub content: String,
    pub glyph: &'static str,
    pub color: Hsla,
}

pub struct PlanCardSpec {
    pub row_id: SharedString,
    pub goal: Option<String>,
    pub plan_done: usize,
    pub plan_total: usize,
    pub todo_done: usize,
    pub todo_total: usize,
    pub steps: Vec<PlanStepView>,
    pub todos: Vec<PlanTodoView>,
    pub style: PlanCardStyle,
}

/// 进度文案（纯函数，可单测）。
pub fn plan_progress_text(
    plan_done: usize,
    plan_total: usize,
    todo_done: usize,
    todo_total: usize,
) -> String {
    format!("计划 {plan_done}/{plan_total} · 待办 {todo_done}/{todo_total}")
}

pub fn render_plan_card(spec: PlanCardSpec) -> AnyElement {
    let PlanCardSpec {
        row_id,
        goal,
        plan_done,
        plan_total,
        todo_done,
        todo_total,
        steps,
        todos,
        style,
    } = spec;
    let show_todo_label = !steps.is_empty() && !todos.is_empty();
    div()
        .id(row_id)
        .flex()
        .flex_col()
        .gap(px(3.0))
        .mx(px(8.0))
        .mb(px(4.0))
        .p(px(8.0))
        .rounded(px(style.radius))
        .border_1()
        .border_color(style.line)
        .bg(style.card)
        .child(
            div()
                .flex()
                .flex_row()
                .items_center()
                .gap(px(8.0))
                .child(div().text_size(px(12.0)).child("计划"))
                .children(goal.map(|goal| {
                    div()
                        .flex_1()
                        .text_size(px(11.0))
                        .text_color(style.ink_2)
                        .child(format!("目标：{goal}"))
                }))
                .child(div().text_size(px(10.0)).text_color(style.ink_3).child(
                    plan_progress_text(plan_done, plan_total, todo_done, todo_total),
                )),
        )
        .children(steps.into_iter().take(6).map(|step| {
            div()
                .flex()
                .flex_row()
                .items_center()
                .gap(px(4.0))
                .child(
                    div()
                        .w(px(12.0))
                        .text_size(px(11.0))
                        .text_color(step.color)
                        .child(step.glyph),
                )
                .child(
                    div()
                        .text_size(px(11.0))
                        .text_color(style.ink_2)
                        .child(step.title),
                )
        }))
        .children(show_todo_label.then(|| {
            div()
                .text_size(px(10.0))
                .text_color(style.ink_3)
                .child("待办")
        }))
        .children(todos.into_iter().take(5).map(|todo| {
            div()
                .flex()
                .flex_row()
                .items_center()
                .gap(px(4.0))
                .child(
                    div()
                        .w(px(12.0))
                        .text_size(px(11.0))
                        .text_color(todo.color)
                        .child(todo.glyph),
                )
                .child(
                    div()
                        .text_size(px(11.0))
                        .text_color(style.ink_2)
                        .child(todo.content),
                )
        }))
        .into_any_element()
}

#[cfg(test)]
mod tests {
    use super::plan_progress_text;

    #[test]
    fn progress_text_includes_counts() {
        assert_eq!(plan_progress_text(1, 3, 2, 5), "计划 1/3 · 待办 2/5");
        assert_eq!(plan_progress_text(0, 0, 0, 0), "计划 0/0 · 待办 0/0");
    }
}
