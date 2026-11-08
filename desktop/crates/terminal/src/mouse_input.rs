//! 鼠标输入编码：终端程序（vim / htop / less）通过 DECSET 开启鼠标上报后，
//! 把宿主的鼠标事件转成 xterm 序列写回 PTY。
//!
//! 是否上报由终端当前模式决定（`is_mouse_tracking`），所以每次编码前都要
//! 从终端同步一次选项。未开启上报时返回 `None`，调用方应改用本地选区/滚动。

use libghostty_vt::mouse;

use crate::{Mods, Result, TerminalCore};

/// 鼠标动作。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MouseAction {
    Press,
    Release,
    Motion,
}

/// 参与上报的按键与滚轮方向。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MouseButton {
    Left,
    Right,
    Middle,
    WheelUp,
    WheelDown,
}

/// 一次鼠标事件；`x`/`y` 是相对内容区左上角的像素坐标。
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct MouseEvent {
    pub action: MouseAction,
    pub button: Option<MouseButton>,
    pub mods: Mods,
    pub x: f32,
    pub y: f32,
}

/// 可复用的鼠标编码器（`!Send`，与 [`TerminalCore`] 同线程）。
pub struct MouseInput {
    encoder: mouse::Encoder<'static>,
    event: mouse::Event<'static>,
    buffer: Vec<u8>,
    size: mouse::EncoderSize,
    pressed: bool,
}

impl MouseInput {
    pub fn new() -> Result<Self> {
        Ok(Self {
            encoder: mouse::Encoder::new()?,
            event: mouse::Event::new()?,
            buffer: Vec::new(),
            size: mouse::EncoderSize {
                screen_width: 0,
                screen_height: 0,
                cell_width: 1,
                cell_height: 1,
                padding_top: 0,
                padding_bottom: 0,
                padding_right: 0,
                padding_left: 0,
            },
            pressed: false,
        })
    }

    /// 更新渲染几何：屏幕像素尺寸、cell 像素尺寸与内边距。
    pub fn set_geometry(
        &mut self,
        screen_width: u32,
        screen_height: u32,
        cell_width: u32,
        cell_height: u32,
        padding: u32,
    ) {
        self.size = mouse::EncoderSize {
            screen_width,
            screen_height,
            cell_width: cell_width.max(1),
            cell_height: cell_height.max(1),
            padding_top: padding,
            padding_bottom: padding,
            padding_right: padding,
            padding_left: padding,
        };
    }

    /// 编码一次鼠标事件。
    ///
    /// 终端未开启鼠标上报时返回 `None`（事件应交给本地选区/滚动处理）。
    pub fn encode(&mut self, core: &TerminalCore, event: MouseEvent) -> Result<Option<&[u8]>> {
        let terminal = core.terminal();
        if !terminal.is_mouse_tracking()? {
            return Ok(None);
        }

        self.encoder.set_options_from_terminal(terminal);
        self.encoder.set_size(self.size);
        self.encoder.set_any_button_pressed(self.pressed);

        self.event
            .set_action(match event.action {
                MouseAction::Press => mouse::Action::Press,
                MouseAction::Release => mouse::Action::Release,
                MouseAction::Motion => mouse::Action::Motion,
            })
            .set_button(event.button.map(encoder_button))
            .set_mods(event.mods)
            .set_position(mouse::Position {
                x: event.x,
                y: event.y,
            });

        self.buffer.clear();
        self.encoder.encode_to_vec(&self.event, &mut self.buffer)?;

        match event.action {
            MouseAction::Press => self.pressed = true,
            MouseAction::Release => self.pressed = false,
            MouseAction::Motion => {}
        }

        if self.buffer.is_empty() {
            Ok(None)
        } else {
            Ok(Some(&self.buffer))
        }
    }
}

/// 宿主的按键/滚轮 → 编码器的按键身份。
fn encoder_button(button: MouseButton) -> mouse::Button {
    match button {
        MouseButton::Left => mouse::Button::Left,
        MouseButton::Right => mouse::Button::Right,
        MouseButton::Middle => mouse::Button::Middle,
        // xterm 用按键 4/5 表示滚轮上下。
        MouseButton::WheelUp => mouse::Button::Four,
        MouseButton::WheelDown => mouse::Button::Five,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::GridSize;

    fn tracked_terminal() -> TerminalCore {
        let mut core = TerminalCore::new(GridSize { cols: 80, rows: 24 }).expect("terminal");
        // 1000 = 普通鼠标上报，1006 = SGR 格式。
        core.feed(b"\x1b[?1000h\x1b[?1006h");
        core
    }

    fn input() -> MouseInput {
        let mut input = MouseInput::new().expect("encoder");
        // 640x384 屏幕、8x16 的 cell、无内边距。
        input.set_geometry(640, 384, 8, 16, 0);
        input
    }

    #[test]
    fn ignores_events_when_tracking_is_off() {
        let core = TerminalCore::new(GridSize { cols: 80, rows: 24 }).expect("terminal");
        let mut input = input();

        let bytes = input
            .encode(
                &core,
                MouseEvent {
                    action: MouseAction::Press,
                    button: Some(MouseButton::Left),
                    mods: Mods::empty(),
                    x: 41.0,
                    y: 49.0,
                },
            )
            .expect("encode");
        assert_eq!(bytes, None, "未开启上报时不应该产生字节");
    }

    #[test]
    fn encodes_sgr_press_and_release() {
        let core = tracked_terminal();
        let mut input = input();

        // cell (5, 3) 的中心 → SGR 坐标为 1-based 的 6;4。
        let press = input
            .encode(
                &core,
                MouseEvent {
                    action: MouseAction::Press,
                    button: Some(MouseButton::Left),
                    mods: Mods::empty(),
                    x: 41.0,
                    y: 49.0,
                },
            )
            .expect("encode")
            .expect("press produces bytes");
        assert_eq!(press, b"\x1b[<0;6;4M");

        let release = input
            .encode(
                &core,
                MouseEvent {
                    action: MouseAction::Release,
                    button: Some(MouseButton::Left),
                    mods: Mods::empty(),
                    x: 41.0,
                    y: 49.0,
                },
            )
            .expect("encode")
            .expect("release produces bytes");
        assert_eq!(release, b"\x1b[<0;6;4m");
    }

    #[test]
    fn encodes_wheel_as_buttons_four_and_five() {
        let core = tracked_terminal();
        let mut input = input();

        let up = input
            .encode(
                &core,
                MouseEvent {
                    action: MouseAction::Press,
                    button: Some(MouseButton::WheelUp),
                    mods: Mods::empty(),
                    x: 41.0,
                    y: 49.0,
                },
            )
            .expect("encode")
            .expect("wheel up produces bytes");
        assert_eq!(up, b"\x1b[<64;6;4M");

        let down = input
            .encode(
                &core,
                MouseEvent {
                    action: MouseAction::Press,
                    button: Some(MouseButton::WheelDown),
                    mods: Mods::empty(),
                    x: 41.0,
                    y: 49.0,
                },
            )
            .expect("encode")
            .expect("wheel down produces bytes");
        assert_eq!(down, b"\x1b[<65;6;4M");
    }
}
