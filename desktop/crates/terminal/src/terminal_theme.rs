//! 终端配色：由宿主当前的应用主题派生。
//!
//! 只描述 ANSI 0–15 与三个默认色；16–255 的色立方与灰阶由 libghostty
//! 保持标准值，应用主题不覆盖。

use libghostty_vt::style::{PaletteIndex, RgbColor};

use crate::FrameColor;

/// 终端配色，来自宿主当前的应用主题。
///
/// `ansi` 按 ANSI 顺序排列：前 8 个是常规色，后 8 个是亮色。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TerminalTheme {
    pub foreground: FrameColor,
    pub background: FrameColor,
    pub cursor: FrameColor,
    pub ansi: [FrameColor; 16],
}

impl TerminalTheme {
    /// ANSI 0–15 对应的调色板索引，顺序与 [`TerminalTheme::ansi`] 一致。
    pub(crate) const INDICES: [PaletteIndex; 16] = [
        PaletteIndex::BLACK,
        PaletteIndex::RED,
        PaletteIndex::GREEN,
        PaletteIndex::YELLOW,
        PaletteIndex::BLUE,
        PaletteIndex::MAGENTA,
        PaletteIndex::CYAN,
        PaletteIndex::WHITE,
        PaletteIndex::BRIGHT_BLACK,
        PaletteIndex::BRIGHT_RED,
        PaletteIndex::BRIGHT_GREEN,
        PaletteIndex::BRIGHT_YELLOW,
        PaletteIndex::BRIGHT_BLUE,
        PaletteIndex::BRIGHT_MAGENTA,
        PaletteIndex::BRIGHT_CYAN,
        PaletteIndex::BRIGHT_WHITE,
    ];
}

/// 从 `#rrggbb` / `#rrggbbaa` 解析颜色；解析失败返回 `None`。
///
/// 主题 JSON 与测试数据共用这个入口，避免两套解析规则。
pub fn parse_hex(value: &str) -> Option<RgbColor> {
    let trimmed = value.trim();
    let hex = trimmed.strip_prefix('#').unwrap_or(trimmed);
    if hex.len() != 6 && hex.len() != 8 {
        return None;
    }
    let byte = |offset: usize| u8::from_str_radix(&hex[offset..offset + 2], 16).ok();
    Some(RgbColor {
        r: byte(0)?,
        g: byte(2)?,
        b: byte(4)?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_six_and_eight_digit_hex() {
        assert_eq!(
            parse_hex("#EF7177"),
            Some(RgbColor {
                r: 0xEF,
                g: 0x71,
                b: 0x77
            })
        );
        assert_eq!(
            parse_hex("5c6166ff"),
            Some(RgbColor {
                r: 0x5c,
                g: 0x61,
                b: 0x66
            })
        );
    }

    #[test]
    fn rejects_short_or_invalid_values() {
        assert_eq!(parse_hex("#fff"), None);
        assert_eq!(parse_hex("#gggggg"), None);
        assert_eq!(parse_hex("no-hash-000000"), None);
    }
}
