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
