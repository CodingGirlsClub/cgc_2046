//! 子 agent 进度行（Stage 3.6 B3c：native 与共享视图共用）。
//!
//! 只负责渲染；行交错顺序仍由各视图的 row-kind 列表决定（不得在此重排）。

use gpui_kit::*;

/// 子 agent 行样式（各栈从自己的主题 palette 构造）。
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SubagentRowStyle {
    pub view: Hsla,
    pub ink_2: Hsla,
    pub ink_3: Hsla,
    pub radius: f32,
}

/// 子 agent 行数据（native adapter 把 `SubagentCard` 映射到这里）。
pub struct SubagentRowSpec {
    pub task: String,
    pub text: String,
    /// `None` = 运行中；`Some(true)` = 完成；`Some(false)` = 失败。
    pub finished: Option<bool>,
    pub style: SubagentRowStyle,
}

/// 状态文案（纯函数，可单测）。
pub fn subagent_status_label(finished: Option<bool>) -> &'static str {
    match finished {
        None => "运行中…",
        Some(true) => "完成",
        Some(false) => "失败",
    }
}

/// 进度正文截断（纯函数，可单测）。
pub fn subagent_preview(text: &str) -> String {
    text.chars().take(300).collect()
}

pub fn render_subagent_row(spec: SubagentRowSpec) -> AnyElement {
    let SubagentRowSpec {
        task,
        text,
        finished,
        style,
    } = spec;
    let status = subagent_status_label(finished);
    let preview = subagent_preview(&text);
    div()
        .flex()
        .flex_col()
        .gap(px(2.0))
        .p(px(8.0))
        .rounded(px(style.radius))
        .bg(style.view)
        .child(
            div()
                .text_size(px(11.0))
                .text_color(style.ink_2)
                .child(format!("子 agent · {status}：{task}")),
        )
        .children((!preview.is_empty()).then(|| {
            div()
                .text_size(px(11.0))
                .text_color(style.ink_3)
                .child(preview)
        }))
        .into_any_element()
}

#[cfg(test)]
mod tests {
    use super::{subagent_preview, subagent_status_label};

    #[test]
    fn status_label_covers_running_finished_failed() {
        assert_eq!(subagent_status_label(None), "运行中…");
        assert_eq!(subagent_status_label(Some(true)), "完成");
        assert_eq!(subagent_status_label(Some(false)), "失败");
    }

    #[test]
    fn preview_truncates_to_300_chars() {
        let text = "a".repeat(400);
        assert_eq!(subagent_preview(&text).chars().count(), 300);
        assert_eq!(subagent_preview("ok"), "ok");
    }
}
