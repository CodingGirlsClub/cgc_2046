//! 内置字体：与 Zed 的 `load_embedded_fonts` 同构。
//!
//! 字体随 binary 打包、启动时注册，不依赖用户机器安装——此前 `FONT_MONO`
//! 声明的 "Geist Mono" 在系统里并不存在，终端回退到默认字体，等宽度量丢失
//! （ASCII art 错位）、Nerd Font 图标缺字形（显示为 `?`）。
//!
//! 终端正文用 Geist Mono，图标由 Symbols Nerd Font 兜底。
//! 许可见 `resources/fonts/LICENSE-*` 与 `OFL-*.txt`（OFL-1.1 / MIT）。

use gpui_kit::*;
use std::borrow::Cow;

/// 终端等宽字体家族（`theme::FONT_MONO` 声明同名）。
pub const TERMINAL_FAMILY: &str = "Geist Mono";

/// 图标回退字体：symbols-only，补 Nerd Font 私有区字形。
pub const SYMBOL_FAMILY: &str = "Symbols Nerd Font";

const FONTS: [&[u8]; 2] = [
    include_bytes!("../../../resources/fonts/GeistMono-Variable.ttf"),
    include_bytes!("../../../resources/fonts/SymbolsNerdFont-Regular.ttf"),
];

/// 注册内置字体。`TextSystem::add_fonts` 会清空字体缓存，重复调用是幂等的。
///
/// 注册结果写日志：headless 测试平台（`NoopTextSystem`）解析不出真实字体，
/// 字体是否生效只能看真实平台启动日志（或肉眼验收终端 logo/图标）。
pub fn register(cx: &App) {
    cx.text_system()
        .add_fonts(FONTS.iter().map(|bytes| Cow::Borrowed(*bytes)).collect())
        .expect("内置字体必须能加载");
    let text_system = cx.text_system();
    let missing = text_system.resolve_font(&font("__cgc_missing_family__"));
    for family in [TERMINAL_FAMILY, SYMBOL_FAMILY] {
        let id = text_system.resolve_font(&font(family));
        if id == missing {
            log::warn!(target: "fonts", "内置字体 {family} 未注册成功，将回退系统字体");
        } else {
            log::info!(target: "fonts", "{family} -> {id:?}");
        }
    }
}

/// 终端字体：等宽正文 + 图标回退链。
pub fn terminal_font() -> Font {
    let mut font = font(TERMINAL_FAMILY);
    font.fallbacks = Some(FontFallbacks::from_fonts(vec![
        SYMBOL_FAMILY.to_string(),
        "Apple Color Emoji".to_string(),
        "Apple Symbols".to_string(),
    ]));
    font
}

#[cfg(test)]
mod tests {
    use super::FONTS;

    /// 抓「字体文件漏提交 / 被截断」：`include_bytes!` 在构建期就会失败，
    /// 但空壳或非 TTF 内容只有跑测试才能发现。
    ///
    /// 这里只显式导入 `FONTS`：`use super::*;` 会把 2.4 MB 的常量拖进
    /// proc-macro 展开，rustc 曾因此栈溢出（SIGBUS）。
    #[test]
    fn bundled_font_bytes_are_valid_ttf() {
        for (index, bytes) in FONTS.iter().enumerate() {
            assert!(bytes.len() > 1024, "字体 {index} 疑似缺失或截断");
            let magic = &bytes[..4];
            assert!(
                matches!(magic, [0, 1, 0, 0] | b"true" | b"OTTO"),
                "字体 {index} 首 4 字节不是 TTF/OTF 魔数: {magic:?}"
            );
        }
    }
}
