//! 公式渲染（stories 4.3/4.4）：ratex-gpui（MIT，纯 CPU 排版）把 Markdown 中的
//! `$…$` / `$$…$$` 渲染成图片；错误公式降级为原文文本。
//!
//! 选择依据见 story 4.3 计划：ratex-gpui 与 `gpui-pre` 0.3 兼容、MIT、渲染是纯 CPU，
//! 无需 WebView/KaTeX/网络字体；SVG 预渲染方案保留为备用（见决策记录）。

use gpui_kit::component::text::TextView;
use gpui_kit::{div, img, px, AnyElement, Hsla, IntoElement, ParentElement, Styled};

use crate::safe_markdown::sanitize_markdown;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum MathSegment {
    Text(String),
    Math { latex: String, display: bool },
}

/// 解析 Markdown 中的数学片段；代码围栏内的 `$` 不解析，`\$` 转义为普通 `$`。
pub fn split_math(markdown: &str) -> Vec<MathSegment> {
    let mut segments = Vec::new();
    let mut text = String::new();
    let mut chars = markdown.char_indices().peekable();
    let mut in_fence = false;

    while let Some((index, ch)) = chars.next() {
        if ch == '`' {
            // 代码围栏：连续三个反引号切换状态，原样保留。
            let rest = &markdown[index..];
            if rest.starts_with("```") {
                text.push_str("```");
                chars.next();
                chars.next();
                in_fence = !in_fence;
                continue;
            }
        }
        if ch == '\\' {
            if let Some((_, next)) = chars.peek().copied() {
                if next == '$' {
                    text.push('$');
                    chars.next();
                    continue;
                }
            }
            text.push('\\');
            continue;
        }
        if ch == '$' && !in_fence {
            let display = markdown[index + 1..].starts_with('$');
            let mut latex = String::new();
            let mut closing = None;
            let mut cursor = index + if display { 2 } else { 1 };
            while cursor < markdown.len() {
                let byte = markdown[cursor..].chars().next().expect("char boundary");
                if byte == '\\' {
                    latex.push(byte);
                    cursor += 1;
                    if cursor < markdown.len() {
                        let next = markdown[cursor..].chars().next().expect("char");
                        latex.push(next);
                        cursor += next.len_utf8();
                    }
                    continue;
                }
                if byte == '$' {
                    if display {
                        if markdown[cursor..].starts_with("$$") {
                            closing = Some((cursor, 2));
                            break;
                        }
                    } else {
                        closing = Some((cursor, 1));
                        break;
                    }
                }
                if !display && byte == '\n' {
                    break;
                }
                latex.push(byte);
                cursor += byte.len_utf8();
            }
            let Some((close_at, close_len)) = closing else {
                text.push('$');
                continue;
            };
            let latex = latex.trim().to_string();
            if latex.is_empty() {
                text.push('$');
                continue;
            }
            if !text.is_empty() {
                segments.push(MathSegment::Text(std::mem::take(&mut text)));
            }
            segments.push(MathSegment::Math { latex, display });
            // 跳过 closing 的 `$`。
            for _ in 0..close_len {
                chars.next();
            }
            let _ = close_at;
        } else {
            text.push(ch);
        }
    }
    if !text.is_empty() {
        segments.push(MathSegment::Text(text));
    }
    segments
}

/// 单个公式 → 图片元素；失败降级为原文（danger 色、等宽）。
pub fn render_formula(latex: &str, font_size: f32, dpr: f32, color: Hsla) -> AnyElement {
    match ratex_gpui::render::render_latex(latex, font_size, dpr, color) {
        Some(rendered) => img(rendered.image)
            .w(px(rendered.width))
            .h(px(rendered.height))
            .into_any_element(),
        None => div()
            .px(px(4.0))
            .py(px(2.0))
            .text_color(color)
            .child(format!("${latex}$"))
            .into_any_element(),
    }
}

/// Markdown + 数学混排：文本走安全 markdown，块级公式居中，行内公式与文本同排。
pub fn render_markdown_with_math(
    markdown: &str,
    id_prefix: &str,
    font_size: f32,
    dpr: f32,
    color: Hsla,
) -> Vec<AnyElement> {
    let mut elements = Vec::new();
    let mut inline_row: Vec<AnyElement> = Vec::new();
    let mut text_index = 0usize;
    for segment in split_math(markdown) {
        match segment {
            MathSegment::Text(text) => {
                if text.trim().is_empty() {
                    continue;
                }
                text_index += 1;
                inline_row.push(
                    TextView::markdown(
                        format!("{id_prefix}-md-{text_index}"),
                        sanitize_markdown(&text),
                    )
                    .into_any_element(),
                );
            }
            MathSegment::Math { latex, display } => {
                if display {
                    if !inline_row.is_empty() {
                        elements.push(
                            div()
                                .flex()
                                .flex_row()
                                .flex_wrap()
                                .items_center()
                                .gap(px(4.0))
                                .children(std::mem::take(&mut inline_row))
                                .into_any_element(),
                        );
                    }
                    elements.push(
                        div()
                            .w_full()
                            .flex()
                            .justify_center()
                            .child(render_formula(&latex, font_size, dpr, color))
                            .into_any_element(),
                    );
                } else {
                    inline_row.push(render_formula(&latex, font_size, dpr, color));
                }
            }
        }
    }
    if !inline_row.is_empty() {
        elements.push(
            div()
                .flex()
                .flex_row()
                .flex_wrap()
                .items_center()
                .gap(px(4.0))
                .children(inline_row)
                .into_any_element(),
        );
    }
    elements
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_inline_and_display_math() {
        let segments = split_math("质能方程 $E=mc^2$ 与\n\n$$\n\\frac{a}{b}\n$$");
        assert!(segments.contains(&MathSegment::Math {
            latex: "E=mc^2".to_string(),
            display: false
        }));
        assert!(segments.contains(&MathSegment::Math {
            latex: "\\frac{a}{b}".to_string(),
            display: true
        }));
    }

    #[test]
    fn code_fence_and_escaped_dollar_are_not_math() {
        let segments = split_math("```bash\necho $HOME\ndf $x\n```\n价格 \\$5 与 $x$");
        assert!(segments
            .iter()
            .all(|segment| !matches!(segment, MathSegment::Math { latex, .. } if latex == "HOME")));
        assert!(segments
            .iter()
            .any(|segment| matches!(segment, MathSegment::Math { latex, .. } if latex == "x")));
        let text = segments
            .iter()
            .filter_map(|segment| match segment {
                MathSegment::Text(text) => Some(text.as_str()),
                _ => None,
            })
            .collect::<String>();
        assert!(text.contains("$HOME"));
        assert!(text.contains("$5"));
    }

    #[test]
    fn unmatched_dollar_stays_text() {
        assert_eq!(
            split_math("价格 $5 不是公式"),
            vec![MathSegment::Text("价格 $5 不是公式".to_string())]
        );
    }

    #[test]
    fn empty_display_math_is_text() {
        assert_eq!(
            split_math("空的 $$ $$"),
            vec![MathSegment::Text("空的 $$ $$".to_string())]
        );
    }
}
