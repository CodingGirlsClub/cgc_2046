//! 公式渲染（stories 4.3/4.4）：ratex-gpui（MIT，纯 CPU 排版）把 Markdown 中的
//! `$…$` / `$$…$$` 渲染成图片；错误公式降级为原文文本。
//!
//! 选择依据见 story 4.3 计划：ratex-gpui 与 `gpui-pre` 0.3 兼容、MIT、渲染是纯 CPU，
//! 无需 WebView/KaTeX/网络字体；SVG 预渲染方案保留为备用（见决策记录）。

use gpui_kit::component::text::TextView;
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

use gpui_kit::{div, img, px, AnyElement, Hsla, IntoElement, ParentElement, RenderImage, Styled};

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

#[derive(Clone, PartialEq, Eq, Hash)]
struct FormulaKey {
    latex: String,
    font_size_bits: u32,
    dpr_bits: u32,
    color_bits: String,
}

struct CachedFormula {
    image: Arc<RenderImage>,
    width: f32,
    height: f32,
}

static CACHE: OnceLock<Mutex<HashMap<FormulaKey, CachedFormula>>> = OnceLock::new();
static CACHE_BYTES: AtomicU64 = AtomicU64::new(0);
static CACHE_HITS: AtomicU64 = AtomicU64::new(0);
static CACHE_MISSES: AtomicU64 = AtomicU64::new(0);
const CACHE_CAPACITY: usize = 256;

fn cache() -> &'static Mutex<HashMap<FormulaKey, CachedFormula>> {
    CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

fn render_latex_cached(
    latex: &str,
    font_size: f32,
    dpr: f32,
    color: Hsla,
) -> Option<(Arc<RenderImage>, f32, f32)> {
    let key = FormulaKey {
        latex: latex.to_string(),
        font_size_bits: font_size.to_bits(),
        dpr_bits: dpr.to_bits(),
        color_bits: format!("{color:?}"),
    };
    if let Some(hit) = cache().lock().expect("formula cache").get(&key) {
        CACHE_HITS.fetch_add(1, Ordering::Relaxed);
        return Some((Arc::clone(&hit.image), hit.width, hit.height));
    }
    CACHE_MISSES.fetch_add(1, Ordering::Relaxed);
    let rendered = ratex_gpui::render::render_latex(latex, font_size, dpr, color)?;
    let width = rendered.width;
    let height = rendered.height;
    let mut guard = cache().lock().expect("formula cache");
    if guard.len() >= CACHE_CAPACITY {
        guard.clear();
        CACHE_BYTES.store(0, Ordering::Relaxed);
    }
    guard.insert(
        key,
        CachedFormula {
            image: Arc::clone(&rendered.image),
            width,
            height,
        },
    );
    CACHE_BYTES.fetch_add((width * height * 4.0) as u64, Ordering::Relaxed);
    Some((rendered.image, width, height))
}

/// 清空公式图片缓存（测试/主题切换/内存回收）。
pub fn clear_formula_cache() {
    cache().lock().expect("formula cache").clear();
    CACHE_BYTES.store(0, Ordering::Relaxed);
    CACHE_HITS.store(0, Ordering::Relaxed);
    CACHE_MISSES.store(0, Ordering::Relaxed);
}

/// `(hits, misses, approximate_bytes)`：供基准/诊断。
pub fn formula_cache_stats() -> (u64, u64, u64) {
    (
        CACHE_HITS.load(Ordering::Relaxed),
        CACHE_MISSES.load(Ordering::Relaxed),
        CACHE_BYTES.load(Ordering::Relaxed),
    )
}

/// 单个公式 → 图片元素；失败降级为原文（danger 色、等宽）。渲染结果按
/// `(latex, font_size, dpr, color)` 缓存，长文重复公式不重复排版。
pub fn render_formula(latex: &str, font_size: f32, dpr: f32, color: Hsla) -> AnyElement {
    match render_latex_cached(latex, font_size, dpr, color) {
        Some((image, width, height)) => img(image).w(px(width)).h(px(height)).into_any_element(),
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
    fn formula_cache_reuses_render_results() {
        clear_formula_cache();
        let color: Hsla = gpui_kit::rgb(0xffffff).into();
        let first = render_latex_cached(r"\frac{1}{2}", 14.0, 2.0, color);
        let second = render_latex_cached(r"\frac{1}{2}", 14.0, 2.0, color);
        assert!(
            first.is_some() && second.is_some(),
            "formula renders headless"
        );
        assert!(Arc::ptr_eq(
            &first.expect("first").0,
            &second.expect("second").0
        ));
        let (hits, misses, _) = formula_cache_stats();
        assert_eq!((hits, misses), (1, 1));
        let other = render_latex_cached(r"E=mc^2", 14.0, 2.0, color);
        assert!(other.is_some());
        assert_eq!(formula_cache_stats().1, 2);
    }

    #[test]
    fn empty_display_math_is_text() {
        assert_eq!(
            split_math("空的 $$ $$"),
            vec![MathSegment::Text("空的 $$ $$".to_string())]
        );
    }
}
