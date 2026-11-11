//! 键盘输入编码：把按键转成终端能理解的字节。
//!
//! 编码规则由终端当前模式决定（应用光标键、Kitty keyboard protocol 等），
//! 所以每次编码前都要从终端同步一次选项。

use libghostty_vt::key::{Action, Encoder, Event, Key, Mods};

use crate::{Result, TerminalCore};

/// 可复用的按键编码器（`!Send`，与 [`TerminalCore`] 同线程）。
pub struct KeyInput {
    encoder: Encoder<'static>,
    event: Event<'static>,
    buffer: Vec<u8>,
}

impl KeyInput {
    pub fn new() -> Result<Self> {
        Ok(Self {
            encoder: Encoder::new()?,
            event: Event::new()?,
            buffer: Vec::new(),
        })
    }

    /// 编码一次按键；返回的字节可能为空（例如单独的修饰键）。
    ///
    /// `text` 是按键产生的文本（用于 Kitty protocol 的关联文本与 IME）。
    pub fn encode(
        &mut self,
        core: &TerminalCore,
        key: Key,
        mods: Mods,
        text: Option<&str>,
    ) -> Result<&[u8]> {
        // Ctrl+字母（不含 Alt/Super/Shift）在所有终端协议里都是 C0 控制字符。
        // Kitty 协议下编码器会把 Ctrl+C 退化成普通 "c"（丢修饰），TUI 因此
        // 收不到中断；这里直接给出确定的控制字节。
        if let Some(byte) = text.and_then(|text| control_byte_for_text(text, mods)) {
            self.buffer.clear();
            self.buffer.push(byte);
            return Ok(&self.buffer);
        }

        self.encoder.set_options_from_terminal(core.terminal());
        self.event
            .set_action(Action::Press)
            .set_key(key)
            .set_mods(mods)
            .set_utf8(text);

        self.buffer.clear();
        self.encoder.encode_to_vec(&self.event, &mut self.buffer)?;
        Ok(&self.buffer)
    }
}

/// 纯 Ctrl + 单个 ASCII 字母 → C0 控制字节（`Ctrl+A`=0x01 … `Ctrl+Z`=0x1A）。
///
/// 带 Shift/Alt/Super 的组合不走这条路径：它们在 Kitty 协议下是独立键。
fn control_byte_for_text(text: &str, mods: Mods) -> Option<u8> {
    if !mods.contains(Mods::CTRL) || mods.intersects(Mods::ALT | Mods::SUPER | Mods::SHIFT) {
        return None;
    }
    let mut chars = text.chars();
    let ch = chars.next()?;
    if chars.next().is_some() {
        return None;
    }
    let lower = ch.to_ascii_lowercase();
    lower.is_ascii_lowercase().then(|| lower as u8 - b'a' + 1)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{GridSize, TerminalCore};

    fn core() -> TerminalCore {
        TerminalCore::new(GridSize { cols: 10, rows: 2 }).expect("terminal")
    }

    #[test]
    fn encodes_plain_text() {
        let core = core();
        let mut input = KeyInput::new().expect("encoder");
        assert_eq!(
            input
                .encode(&core, Key::A, Mods::empty(), Some("a"))
                .expect("encode"),
            b"a"
        );
    }

    #[test]
    fn encodes_control_keys() {
        let core = core();
        let mut input = KeyInput::new().expect("encoder");
        assert_eq!(
            input
                .encode(&core, Key::C, Mods::CTRL, None)
                .expect("encode"),
            b"\x03"
        );
    }

    #[test]
    fn ctrl_c_with_text_still_encodes_etx() {
        let core = core();
        let mut input = KeyInput::new().expect("encoder");
        assert_eq!(
            input
                .encode(&core, Key::C, Mods::CTRL, Some("c"))
                .expect("encode"),
            b"\x03",
            "带 text 的 Ctrl+C 必须仍是 ETX，否则程序收不到中断"
        );
    }

    #[test]
    fn ctrl_c_under_kitty_keyboard() {
        let mut core = core();
        core.feed(b"\x1b[>1u");
        let mut input = KeyInput::new().expect("encoder");
        let bytes = input
            .encode(&core, Key::C, Mods::CTRL, Some("c"))
            .expect("encode")
            .to_vec();
        assert_eq!(
            String::from_utf8_lossy(&bytes),
            "\u{3}".to_string(),
            "kitty disambiguate 模式下 Ctrl+C 仍应是 ETX"
        );
    }

    #[test]
    fn ctrl_shift_c_is_left_to_the_encoder() {
        // Kitty 协议下 Ctrl+Shift+C 是独立键；兜底只处理纯 Ctrl。
        let mut core = core();
        core.feed(b"\x1b[>1u");
        let mut input = KeyInput::new().expect("encoder");
        let bytes = input
            .encode(&core, Key::C, Mods::CTRL | Mods::SHIFT, Some("c"))
            .expect("encode");
        assert_ne!(bytes, b"\x03", "带 Shift 的 Ctrl+C 是独立键，不能压成 ETX");
    }

    #[test]
    fn encodes_arrow_keys() {
        let core = core();
        let mut input = KeyInput::new().expect("encoder");
        assert_eq!(
            input
                .encode(&core, Key::ArrowUp, Mods::empty(), None)
                .expect("encode"),
            b"\x1b[A"
        );
    }

    #[test]
    fn modifier_only_produces_nothing() {
        let core = core();
        let mut input = KeyInput::new().expect("encoder");
        assert!(input
            .encode(&core, Key::ShiftLeft, Mods::SHIFT, None)
            .expect("encode")
            .is_empty());
    }
}
