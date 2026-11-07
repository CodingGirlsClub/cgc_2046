//! 渲染帧：把 libghostty-vt 的 `RenderState` 快照转成拥有所有权的 cell 数据。
//!
//! 视图层（`terminal_view`）不应该接触 `RenderState` 及其生命周期，也不能反过来
//! 持有 `TerminalCore` 的内部借用。`Frame` 是两者之间唯一的稳定边界：
//! 每次 [`TerminalCore::update_frame`] 后，`frame()` 返回可安全遍历的纯数据。
//!
//! 缓冲复用：行与 cell 都原地复用（`String::clear`），稳态下每帧不分配。

use libghostty_vt::render::{CellIterator, CursorVisualStyle, Dirty, RowIterator, Snapshot};
use libghostty_vt::screen::CellWide;
use libghostty_vt::style::{RgbColor, Underline};

use crate::{GridSize, Result};

/// 一个 cell 的绘制数据。
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct FrameCell {
    /// 该 cell 的完整 grapheme cluster（宽字符的尾格为空）。
    pub text: String,
    /// 显式前景色；`None` 用 [`Frame::colors`] 的默认前景。
    pub fg: Option<RgbColor>,
    /// 显式背景色；`None` 用默认背景。
    pub bg: Option<RgbColor>,
    pub bold: bool,
    pub italic: bool,
    pub faint: bool,
    pub inverse: bool,
    pub strikethrough: bool,
    pub underline: bool,
    /// 占两列（CJK/emoji）。尾格留空，绘制时由首格跨列。
    pub wide: bool,
    /// 宽字符的尾格 / 软换行末尾的占位格：渲染时跳过，不占文本流的一列。
    pub spacer_tail: bool,
}

/// 一行 cell。
#[derive(Clone, Debug, Default)]
pub struct FrameRow {
    pub cells: Vec<FrameCell>,
}

/// 终端调色板与默认色。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FrameColors {
    pub foreground: RgbColor,
    pub background: RgbColor,
    pub cursor: Option<RgbColor>,
    pub palette: [RgbColor; 256],
}

impl Default for FrameColors {
    fn default() -> Self {
        Self {
            foreground: RgbColor {
                r: 255,
                g: 255,
                b: 255,
            },
            background: RgbColor { r: 0, g: 0, b: 0 },
            cursor: None,
            palette: [RgbColor::default(); 256],
        }
    }
}

/// 光标状态。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct FrameCursor {
    pub x: u16,
    pub y: u16,
    pub visible: bool,
    pub style: CursorVisualStyle,
    /// 光标落在宽字符的尾格上。
    pub at_wide_tail: bool,
}

/// 一帧的完整绘制数据。
#[derive(Debug)]
pub struct Frame {
    size: GridSize,
    rows: Vec<FrameRow>,
    colors: FrameColors,
    cursor: Option<FrameCursor>,
}

impl Frame {
    pub fn new(size: GridSize) -> Self {
        Self {
            size,
            rows: Vec::new(),
            colors: FrameColors::default(),
            cursor: None,
        }
    }

    pub fn size(&self) -> GridSize {
        self.size
    }

    pub fn rows(&self) -> &[FrameRow] {
        &self.rows
    }

    pub fn colors(&self) -> &FrameColors {
        &self.colors
    }

    pub fn cursor(&self) -> Option<FrameCursor> {
        self.cursor
    }

    /// 从快照刷新；返回是否需要重绘。
    pub(crate) fn update(
        &mut self,
        snapshot: &Snapshot<'static, '_>,
        rows: &mut RowIterator<'static>,
        cells: &mut CellIterator<'static>,
        size: GridSize,
    ) -> Result<bool> {
        let dirty = snapshot.dirty()?;
        let resized = self.size != size || self.rows.len() != size.rows as usize;
        if dirty == Dirty::Clean && !resized {
            return Ok(false);
        }
        if resized {
            self.size = size;
            self.rows = vec![FrameRow::default(); size.rows as usize];
        }

        let cols = size.cols as usize;
        for row in &mut self.rows {
            if row.cells.len() != cols {
                row.cells.resize_with(cols, FrameCell::default);
            }
        }

        let mut y = 0usize;
        let mut row_iter = rows.update(snapshot)?;
        while let Some(row) = row_iter.next() {
            if y >= self.rows.len() {
                break;
            }
            let mut x = 0usize;
            let mut cell_iter = cells.update(row)?;
            while let Some(cell) = cell_iter.next() {
                if x >= cols {
                    break;
                }
                let dst = &mut self.rows[y].cells[x];
                dst.text.clear();
                cell.graphemes_utf8(&mut dst.text)?;
                let style = cell.style()?;
                dst.bold = style.bold;
                dst.italic = style.italic;
                dst.faint = style.faint;
                dst.inverse = style.inverse;
                dst.strikethrough = style.strikethrough;
                dst.underline = style.underline != Underline::None;
                dst.fg = cell.fg_color()?;
                dst.bg = cell.bg_color()?;
                let wide = cell.raw_cell()?.wide()?;
                dst.wide = matches!(wide, CellWide::Wide);
                dst.spacer_tail = matches!(wide, CellWide::SpacerTail | CellWide::SpacerHead);
                x += 1;
            }
            y += 1;
        }

        let colors = snapshot.colors()?;
        self.colors = FrameColors {
            foreground: colors.foreground,
            background: colors.background,
            cursor: colors.cursor,
            palette: colors.palette,
        };

        let cursor_style = snapshot
            .cursor_visual_style()
            .unwrap_or(CursorVisualStyle::Block);
        self.cursor = if snapshot.cursor_visible()? {
            snapshot.cursor_viewport()?.map(|viewport| FrameCursor {
                x: viewport.x,
                y: viewport.y,
                visible: true,
                style: cursor_style,
                at_wide_tail: viewport.at_wide_tail,
            })
        } else {
            None
        };

        // 本帧数据已完整提取，可以消费 dirty 状态；下一帧没有变化时
        // `update_frame` 会返回 false，视图层据此跳过重绘。
        snapshot.clean()?;

        Ok(true)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::TerminalCore;

    fn grid(cols: u16, rows: u16) -> GridSize {
        GridSize { cols, rows }
    }

    #[test]
    fn exposes_text_styles_and_colors() {
        let mut core = TerminalCore::new(grid(10, 3)).unwrap();
        core.feed(b"\x1b[1;38;2;1;2;3mB\x1b[0m\x1b[4mU\x1b[0m");

        assert!(core.update_frame().unwrap());
        let frame = core.frame();
        let cells = &frame.rows()[0].cells;

        assert_eq!(cells[0].text, "B");
        assert!(cells[0].bold);
        assert_eq!(cells[0].fg, Some(RgbColor { r: 1, g: 2, b: 3 }));

        assert_eq!(cells[1].text, "U");
        assert!(cells[1].underline);
        assert!(!cells[1].bold);
        assert_eq!(cells[1].fg, None);
    }

    #[test]
    fn exposes_cursor_and_default_colors() {
        let mut core = TerminalCore::new(grid(10, 3)).unwrap();
        core.feed(b"ab");
        core.update_frame().unwrap();

        let frame = core.frame();
        let cursor = frame.cursor().expect("cursor visible");
        assert_eq!((cursor.x, cursor.y), (2, 0));
        assert_eq!(cursor.style, CursorVisualStyle::Block);
        assert!(frame.colors().foreground != frame.colors().background);
    }

    #[test]
    fn marks_wide_cells() {
        let mut core = TerminalCore::new(grid(10, 2)).unwrap();
        core.feed("中文".as_bytes());
        core.update_frame().unwrap();

        let cells = &core.frame().rows()[0].cells;
        assert!(cells[0].wide);
        assert_eq!(cells[0].text, "中");
        assert!(!cells[1].wide);
        assert!(cells[1].text.is_empty());
        assert!(cells[2].wide);
    }

    #[test]
    fn clean_frame_reports_no_redraw() {
        let mut core = TerminalCore::new(grid(10, 2)).unwrap();
        core.feed(b"x");
        assert!(core.update_frame().unwrap());
        assert!(!core.update_frame().unwrap(), "second update is clean");
    }
}
