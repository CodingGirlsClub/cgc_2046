//! 终端核心：libghostty-vt（VT 解析 / 屏幕状态 / 渲染快照）+ PTY 会话。
//!
//! libghostty-vt 的句柄全部是 `!Send + !Sync`（C API 不承诺线程安全），
//! 因此本 crate 的类型必须在同一线程创建、使用和释放；PTY 读线程只通过
//! channel 把字节送进来，不能共享终端。
//!
//! 这一层不依赖 GPUI；渲染与面板集成在 `terminal_view`。

use std::error::Error;

use libghostty_vt::render::{CellIterator, RowIterator};
use libghostty_vt::{RenderState, Terminal};
use unicode_width::UnicodeWidthChar;

mod frame;
mod input;
mod pty;

pub use frame::{Frame, FrameCell, FrameColors, FrameCursor, FrameRow};
pub use input::KeyInput;
pub use pty::{ExitInfo, PollResult, Session};

/// 按键类型与修饰键（libghostty-vt 的编码输入）。
pub use libghostty_vt::key::{Key, Mods};

/// 终端颜色类型（libghostty-vt 的 `RgbColor`），供视图层使用。
pub use libghostty_vt::style::RgbColor as FrameColor;

pub type Result<T, E = Box<dyn Error + Send + Sync>> = std::result::Result<T, E>;

/// 终端尺寸：以字符单元为单位。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct GridSize {
    pub cols: u16,
    pub rows: u16,
}

/// 一个终端的 VT 状态与可复用的渲染游标。
pub struct TerminalCore {
    terminal: Terminal<'static, 'static>,
    render_state: RenderState<'static>,
    rows: RowIterator<'static>,
    cells: CellIterator<'static>,
    frame: Frame,
    size: GridSize,
}

impl TerminalCore {
    pub fn new(size: GridSize) -> Result<Self> {
        Ok(Self {
            terminal: Terminal::new(size.cols, size.rows)?,
            render_state: RenderState::new()?,
            rows: RowIterator::new()?,
            cells: CellIterator::new()?,
            frame: Frame::new(size),
            size,
        })
    }

    pub fn size(&self) -> GridSize {
        self.size
    }

    /// 把 PTY 输出的字节喂进 VT 解析器。
    pub fn feed(&mut self, bytes: &[u8]) {
        self.terminal.vt_write(bytes);
    }

    /// 调整网格；像素尺寸由调用方从字体度量给出（0 表示未知）。
    pub fn resize(
        &mut self,
        size: GridSize,
        cell_width_px: u32,
        cell_height_px: u32,
    ) -> Result<()> {
        self.terminal
            .resize(size.cols, size.rows, cell_width_px, cell_height_px)?;
        self.size = size;
        Ok(())
    }

    /// 刷新渲染帧；返回是否需要重绘（`false` 表示屏幕自上次以来没有变化）。
    pub fn update_frame(&mut self) -> Result<bool> {
        let Self {
            terminal,
            render_state,
            rows,
            cells,
            frame,
            size,
        } = self;
        let snapshot = render_state.update(terminal)?;
        frame.update(&snapshot, rows, cells, *size)
    }

    /// 最近一次 [`Self::update_frame`] 的结果。
    pub fn frame(&self) -> &Frame {
        &self.frame
    }

    /// 供同 crate 的输入编码同步终端模式。
    pub(crate) fn terminal(&self) -> &Terminal<'static, 'static> {
        &self.terminal
    }

    /// 当前视口的纯文本（每行去掉尾部空白），用于测试、复制与调试。
    pub fn viewport_text(&mut self) -> Result<Vec<String>> {
        let snapshot = self.render_state.update(&self.terminal)?;
        let mut lines = Vec::with_capacity(self.size.rows as usize);
        let mut row_iter = self.rows.update(&snapshot)?;
        while let Some(row) = row_iter.next() {
            let mut line = String::new();
            // 双宽字符占两个 cell，尾格没有 grapheme；跳过后才能拼回原文。
            let mut skip_tail = false;
            let mut cell_iter = self.cells.update(row)?;
            while let Some(cell) = cell_iter.next() {
                if skip_tail {
                    skip_tail = false;
                    continue;
                }
                let graphemes = cell.graphemes()?;
                match graphemes.first() {
                    Some(&base) => {
                        line.extend(graphemes);
                        skip_tail = UnicodeWidthChar::width(base).unwrap_or(1) > 1;
                    }
                    None => line.push(' '),
                }
            }
            lines.push(line.trim_end().to_string());
        }
        Ok(lines)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn size(cols: u16, rows: u16) -> GridSize {
        GridSize { cols, rows }
    }

    #[test]
    fn renders_plain_and_styled_text() {
        let mut core = TerminalCore::new(size(20, 3)).unwrap();
        core.feed(b"Hello, \x1b[1;32mworld\x1b[0m!\r\n");
        let lines = core.viewport_text().unwrap();
        assert_eq!(lines[0], "Hello, world!");
        assert!(lines[1].is_empty());
    }

    #[test]
    fn handles_cursor_motion_and_erase() {
        let mut core = TerminalCore::new(size(10, 2)).unwrap();
        core.feed(b"abcdef");
        assert_eq!(core.viewport_text().unwrap()[0], "abcdef");

        // 回到第 1 行并擦除整行。
        core.feed(b"\x1b[1;1H\x1b[2K");
        assert!(core.viewport_text().unwrap()[0].is_empty());
    }

    #[test]
    fn handles_wide_cells() {
        let mut core = TerminalCore::new(size(10, 2)).unwrap();
        core.feed("中文😀\r\n".as_bytes());
        let lines = core.viewport_text().unwrap();
        assert_eq!(lines[0], "中文😀");
    }

    #[test]
    fn reflow_after_resize_keeps_text() {
        let mut core = TerminalCore::new(size(20, 3)).unwrap();
        core.feed(b"one two three four\r\n");
        core.resize(size(10, 3), 0, 0).unwrap();
        // resize 后按新宽度重排；拼回去必须还是原文本。
        let text = core.viewport_text().unwrap().concat();
        assert_eq!(text, "one two three four");
    }
}
