//! 双栈共用的 Markdown 视图构造（Stage 1c）。
//!
//! 从 native 面板抽出：安全净化 + TextView 构造（可选中、代码块右上角 Copy）。
//! ACP 面板此前用裸 `TextView::markdown`，没有代码块 Copy；统一后两栈渲染一致。

use gpui_kit::component::button::{Button, ButtonVariants};
use gpui_kit::component::text::{SelectionFormat, TextView};
use gpui_kit::component::Sizable as _;
use gpui_kit::*;

use crate::safe_markdown::sanitize_markdown;

/// 构造 Markdown TextView（代码块右上角 Copy 按钮、文本可选中复制）。
///
/// `id` 决定 element state：流式渲染时复用同一个 id，gpui-base 会对追加的文本
/// 走 `push_str` 增量解析，而不是每帧重新 parse 全文。
pub fn markdown_text_view(id: impl Into<ElementId>, text: &str) -> TextView {
    TextView::markdown(id, sanitize_markdown(text))
        .selectable(true)
        .selection_format(SelectionFormat::Source)
        .code_block_actions(|code_block, _window, _cx| {
            let code = code_block.code().to_string();
            let id = code_block_copy_id(&code, code_block.lang().as_deref());
            Button::new(SharedString::from(id))
                .label("Copy")
                .xsmall()
                .ghost()
                .tooltip("Copy Code")
                .on_click(move |_, _, cx| {
                    cx.write_to_clipboard(ClipboardItem::new_string(code.clone()));
                })
        })
}

/// 代码块 Copy 按钮的稳定 id（同内容同 id，不同内容不同 id，避免元素状态串台）。
fn code_block_copy_id(code: &str, lang: Option<&str>) -> String {
    use std::hash::{Hash as _, Hasher as _};
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    code.hash(&mut hasher);
    lang.unwrap_or_default().hash(&mut hasher);
    format!("ds-copy-code-{:016x}", hasher.finish())
}

#[cfg(test)]
mod tests {
    #[test]
    fn code_block_copy_id_is_stable_and_unique() {
        let first = super::code_block_copy_id("fn main() {}", Some("rust"));
        let same = super::code_block_copy_id("fn main() {}", Some("rust"));
        let other = super::code_block_copy_id("fn main() { }", Some("rust"));
        assert_eq!(first, same);
        assert_ne!(first, other);
        assert!(first.starts_with("ds-copy-code-"));
    }
}
