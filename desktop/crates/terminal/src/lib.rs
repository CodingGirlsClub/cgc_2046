//! 终端核心：libghostty-vt（VT 解析 / 屏幕状态 / 渲染快照）+ PTY 会话。
//!
//! libghostty-vt 的句柄全部是 `!Send + !Sync`（C API 不承诺线程安全），
//! 因此本 crate 的类型必须在同一线程创建、使用和释放；PTY 读线程只通过
//! channel 把字节送进来，不能共享终端。
//!
//! 这一层不依赖 GPUI；渲染与面板集成在 `terminal_view`。

use std::cell::RefCell;
use std::error::Error;
use std::rc::Rc;

use libghostty_vt::render::{CellIterator, RowIterator};
use libghostty_vt::screen::CellWide;
use libghostty_vt::selection::{FormatOptions, Selection};
use libghostty_vt::terminal::{Point, PointCoordinate};
use libghostty_vt::{RenderState, Terminal};

mod frame;
mod input;
mod mouse_input;
mod pty;
mod terminal_theme;

pub use frame::{Frame, FrameCell, FrameColors, FrameCursor, FrameRow};
pub use input::KeyInput;
pub use mouse_input::{MouseAction, MouseButton, MouseEvent, MouseInput};
pub use pty::{ExitInfo, PollResult, Session};
pub use terminal_theme::{parse_hex, TerminalTheme};

/// 按键类型与修饰键（libghostty-vt 的编码输入）。
pub use libghostty_vt::key::{Key, Mods};

/// 光标形状（block / bar / underline / hollow）。
pub use libghostty_vt::render::CursorVisualStyle;

/// 终端颜色类型（libghostty-vt 的 `RgbColor`），供视图层使用。
pub use libghostty_vt::style::RgbColor as FrameColor;

pub type Result<T, E = Box<dyn Error + Send + Sync>> = std::result::Result<T, E>;

/// scrollback 保留的最大行数（超出后丢最旧的）。
const SCROLLBACK_MAX_LINES: usize = 10_000;

/// 终端在解析输出时上报的副作用事件。
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CoreEvent {
    /// 程序通过 OSC 设置了窗口标题。
    Title(String),
    /// 程序通过 OSC 7/9/1337 上报了工作目录。
    Pwd(String),
    /// 收到 BEL。
    Bell,
}

/// 终端尺寸：以字符单元为单位。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct GridSize {
    pub cols: u16,
    pub rows: u16,
}

/// 搜索一次的结果。
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SearchOutcome {
    pub total: usize,
    pub index: Option<usize>,
}

/// 一个终端的 VT 状态与可复用的渲染游标。
pub struct TerminalCore {
    terminal: Terminal<'static, 'static>,
    render_state: RenderState<'static>,
    rows: RowIterator<'static>,
    cells: CellIterator<'static>,
    frame: Frame,
    size: GridSize,
    events: Rc<RefCell<Vec<CoreEvent>>>,
    search: Option<libghostty_vt::search::Search<'static, 'static>>,
    /// 搜索匹配的复用缓冲，避免每帧重新分配。
    match_buffer: libghostty_vt::search::MatchBuffer,
}

impl TerminalCore {
    pub fn new(size: GridSize) -> Result<Self> {
        let mut terminal = Terminal::new(size.cols, size.rows)?;
        let events: Rc<RefCell<Vec<CoreEvent>>> = Rc::new(RefCell::new(Vec::new()));

        let title_events = Rc::clone(&events);
        terminal.on_title_changed(move |term| {
            if let Ok(bytes) = term.title() {
                if let Ok(text) = std::str::from_utf8(bytes) {
                    title_events
                        .borrow_mut()
                        .push(CoreEvent::Title(text.to_string()));
                }
            }
        })?;

        let pwd_events = Rc::clone(&events);
        terminal.on_pwd_changed(move |term| {
            if let Ok(bytes) = term.pwd() {
                if let Ok(text) = std::str::from_utf8(bytes) {
                    pwd_events
                        .borrow_mut()
                        .push(CoreEvent::Pwd(text.to_string()));
                }
            }
        })?;

        let bell_events = Rc::clone(&events);
        terminal.on_bell(move |_term| {
            bell_events.borrow_mut().push(CoreEvent::Bell);
        })?;

        // 回看上限：`seq 1 100000` 这类输出不应无限吃内存。
        terminal.set_scrollback_max_lines(Some(SCROLLBACK_MAX_LINES))?;

        Ok(Self {
            terminal,
            render_state: RenderState::new()?,
            rows: RowIterator::new()?,
            cells: CellIterator::new()?,
            frame: Frame::new(size),
            size,
            events,
            search: None,
            match_buffer: libghostty_vt::search::MatchBuffer::new(),
        })
    }

    /// 取走解析过程中累积的事件（标题 / cwd / bell）。
    pub fn take_events(&mut self) -> Vec<CoreEvent> {
        std::mem::take(&mut *self.events.borrow_mut())
    }

    pub fn size(&self) -> GridSize {
        self.size
    }

    /// 把 PTY 输出的字节喂进 VT 解析器。
    pub fn feed(&mut self, bytes: &[u8]) {
        self.terminal.vt_write(bytes);
    }

    /// 把剪贴板文本编码成 PTY 输入；返回 `None` 表示需要用户确认。
    ///
    /// 终端开启 bracketed paste（DECSET 2004）时用 `ESC[200~`/`ESC[201~` 包裹，
    /// 换行在包裹内是安全的；未开启时换行会被换成回车，**每行立即执行**。
    /// 因此未开启且 `paste::is_safe` 判定内容可执行命令（含换行、ESC 等）时，
    /// 只有 `allow_unsafe` 才真正编码——由宿主先向用户确认。
    /// 两种模式都会剔除可注入命令的控制字节（ESC、DEL 等）。
    pub fn encode_paste(&self, text: &str, allow_unsafe: bool) -> Result<Option<Vec<u8>>> {
        if text.is_empty() {
            return Ok(Some(Vec::new()));
        }
        let bracketed = self
            .terminal
            .mode(libghostty_vt::terminal::Mode::BRACKETED_PASTE)?;
        if !bracketed && !allow_unsafe && !libghostty_vt::paste::is_safe(text) {
            return Ok(None);
        }
        let mut data = text.as_bytes().to_vec();
        let mut out = vec![0u8; data.len() + 16];
        let written = match libghostty_vt::paste::encode(&mut data, bracketed, &mut out) {
            Ok(written) => written,
            Err(libghostty_vt::error::Error::OutOfSpace { required }) => {
                out.resize(required, 0);
                libghostty_vt::paste::encode(&mut data, bracketed, &mut out)?
            }
            Err(error) => return Err(error.into()),
        };
        out.truncate(written);
        Ok(Some(out))
    }

    /// 应用主题配色：默认前景/背景/光标与 ANSI 0–15。
    ///
    /// 调色板变化后 libghostty 会重解析已显示的 cell，历史输出也跟着换色；
    /// 下一次 [`Self::update_frame`] 会返回 `true`，宿主据此重绘。
    pub fn set_theme(&mut self, theme: &TerminalTheme) -> Result<()> {
        self.terminal.set_default_fg_color(Some(theme.foreground))?;
        self.terminal.set_default_bg_color(Some(theme.background))?;
        self.terminal.set_default_cursor_color(Some(theme.cursor))?;
        let mut palette = self.terminal.default_color_palette()?;
        for (index, color) in TerminalTheme::INDICES.into_iter().zip(theme.ansi) {
            palette.set(index, color);
        }
        self.terminal.set_default_color_palette(Some(palette))?;
        Ok(())
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
            ..
        } = self;
        let snapshot = render_state.update(terminal)?;
        frame.update(&snapshot, rows, cells, *size)
    }

    /// 最近一次 [`Self::update_frame`] 的结果。
    pub fn frame(&self) -> &Frame {
        &self.frame
    }

    /// 在 scrollback 中滚动；负值向上（历史），正值向下（回到活动区）。
    pub fn scroll(&mut self, delta: isize) {
        self.terminal
            .scroll_viewport(libghostty_vt::terminal::ScrollViewport::Delta(delta));
    }

    /// 当前是否在 alternate screen（vim / less 等全屏程序）。
    pub fn is_alternate_screen(&self) -> Result<bool> {
        Ok(matches!(
            self.terminal.active_screen()?,
            libghostty_vt::screen::Screen::Alternate
        ))
    }

    /// 当前滚动条状态：总行数、视口偏移与可见行数。
    pub fn scrollbar(&self) -> Result<libghostty_vt::terminal::Scrollbar> {
        self.terminal.scrollbar().map_err(Into::into)
    }

    /// 跳转到 scrollback 的绝对行偏移（滚动条拖动/点击用）。
    pub fn scroll_to(&mut self, offset: usize) {
        self.terminal
            .scroll_viewport(libghostty_vt::terminal::ScrollViewport::Row(offset));
    }

    /// 设置选区（视口坐标，含两端）。
    pub fn set_selection(&mut self, start: (u16, u16), end: (u16, u16)) -> Result<()> {
        let start_ref = self.terminal.grid_ref(Point::Viewport(PointCoordinate {
            x: start.0,
            y: u32::from(start.1),
        }))?;
        let end_ref = self.terminal.grid_ref(Point::Viewport(PointCoordinate {
            x: end.0,
            y: u32::from(end.1),
        }))?;
        let selection = Selection::new(start_ref, end_ref, false);
        self.terminal.set_selection(Some(&selection))?;
        Ok(())
    }

    pub fn clear_selection(&mut self) {
        let _ = self.terminal.set_selection(None);
    }

    /// 选中某个 cell 所在单词（双击）。
    pub fn select_word(&mut self, cell: (u16, u16)) -> Result<()> {
        let grid_ref = self.terminal.grid_ref(Point::Viewport(PointCoordinate {
            x: cell.0,
            y: u32::from(cell.1),
        }))?;
        let options = libghostty_vt::selection::SelectWordOptions::new(grid_ref);
        let _ = self.terminal.select_word(options)?;
        Ok(())
    }

    /// 选中某个 cell 所在行（三击）。
    pub fn select_line(&mut self, cell: (u16, u16)) -> Result<()> {
        let grid_ref = self.terminal.grid_ref(Point::Viewport(PointCoordinate {
            x: cell.0,
            y: u32::from(cell.1),
        }))?;
        let options = libghostty_vt::selection::SelectLineOptions::new(grid_ref);
        let _ = self.terminal.select_line(options)?;
        Ok(())
    }

    /// 在终端（含 scrollback）中搜索；`forward` 决定下一个还是上一个匹配。
    pub fn search(&mut self, needle: &str, forward: bool) -> Result<SearchOutcome> {
        let Self {
            terminal, search, ..
        } = self;
        if search.is_none() {
            *search = Some(libghostty_vt::search::Search::new(terminal)?);
        }
        let search = search.as_mut().expect("search initialized");
        search.set_needle(terminal, needle.as_bytes())?;
        search.run(terminal)?;
        let total = search.total_matches()?;
        if total == 0 {
            return Ok(SearchOutcome { total, index: None });
        }
        if forward {
            search.select_next(terminal)?;
        } else {
            search.select_prev(terminal)?;
        }
        let index = search.selected_index()?;
        Ok(SearchOutcome { total, index })
    }

    /// 当前搜索在视口内的匹配区间：`(row, start_col, end_col)`，列含两端。
    ///
    /// 跨行匹配展开成多段，视口外的部分裁掉。没有搜索时返回空。
    pub fn search_highlights(&mut self, viewport_rows: u16) -> Result<Vec<(u16, u16, u16)>> {
        let Some(mut search) = self.search.take() else {
            return Ok(Vec::new());
        };
        let result = self.collect_highlights(&mut search, viewport_rows);
        self.search = Some(search);
        result
    }

    fn collect_highlights(
        &mut self,
        search: &mut libghostty_vt::search::Search<'static, 'static>,
        viewport_rows: u16,
    ) -> Result<Vec<(u16, u16, u16)>> {
        let mut out = Vec::new();
        let space = libghostty_vt::terminal::PointSpace::Viewport;
        let snapshot = search.snapshot(&mut self.terminal)?;
        let terminal = snapshot.terminal();
        for item in snapshot.viewport_matches(&mut self.match_buffer)? {
            let start = terminal.point_from_grid_ref(&item.start(), space)?;
            let end = terminal.point_from_grid_ref(&item.end(), space)?;
            let (Some(start), Some(end)) = (start, end) else {
                continue;
            };
            let start_row = u16::try_from(start.y).unwrap_or(u16::MAX);
            let end_row = u16::try_from(end.y).unwrap_or(u16::MAX);
            if start_row >= viewport_rows {
                continue;
            }
            if start_row == end_row {
                out.push((start_row, start.x, end.x));
                continue;
            }
            out.push((start_row, start.x, u16::MAX));
            for row in start_row + 1..end_row.min(viewport_rows) {
                out.push((row, 0, u16::MAX));
            }
            if end_row < viewport_rows {
                out.push((end_row, 0, end.x));
            }
        }
        // 按 (row, start, end) 排序，渲染层可用游标按行切片，避免每格线性扫描。
        out.sort_unstable();
        Ok(out)
    }

    /// 某个视口 cell 上的超链接 URI（OSC 8）；没有链接时 `None`。
    pub fn hyperlink_at(&self, cell: (u16, u16)) -> Result<Option<String>> {
        let grid_ref = self.terminal.grid_ref(Point::Viewport(PointCoordinate {
            x: cell.0,
            y: u32::from(cell.1),
        }))?;
        // OSC 8 的 URI 可能很长，按后端返回的 required 逐步扩容。
        let mut buffer = vec![0u8; 256];
        loop {
            match grid_ref.hyperlink_uri(&mut buffer) {
                Ok(0) => return Ok(None),
                Ok(len) => {
                    return Ok(Some(String::from_utf8_lossy(&buffer[..len]).into_owned()));
                }
                Err(libghostty_vt::error::Error::OutOfSpace { required }) => {
                    buffer.resize(required.max(buffer.len() * 2), 0);
                }
                Err(error) => return Err(error.into()),
            }
        }
    }

    /// 当前选区的纯文本（无选区时返回 `None`）。
    pub fn selection_text(&self) -> Result<Option<String>> {
        let bytes = self
            .terminal
            .format_selection_alloc(None, FormatOptions::new())?;
        Ok(bytes.map(|bytes| String::from_utf8_lossy(bytes.as_ref()).into_owned()))
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
            let mut cell_iter = self.cells.update(row)?;
            while let Some(cell) = cell_iter.next() {
                let wide = cell.raw_cell()?.wide()?;
                if matches!(wide, CellWide::SpacerTail | CellWide::SpacerHead) {
                    continue;
                }
                let graphemes = cell.graphemes()?;
                if graphemes.is_empty() {
                    line.push(' ');
                } else {
                    line.extend(graphemes);
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

    #[test]
    fn reads_hyperlink_uri_from_cells() {
        let mut core = TerminalCore::new(size(20, 2)).unwrap();
        core.feed(b"\x1b]8;;https://example.com\x1b\\link\x1b]8;;\x1b\\ plain");

        assert_eq!(
            core.hyperlink_at((0, 0)).unwrap().as_deref(),
            Some("https://example.com"),
            "链接首格"
        );
        assert_eq!(
            core.hyperlink_at((3, 0)).unwrap().as_deref(),
            Some("https://example.com"),
            "链接末格"
        );
        assert_eq!(core.hyperlink_at((5, 0)).unwrap(), None, "链接后的普通文本");
    }

    #[test]
    fn reports_search_highlight_rows() {
        let mut core = TerminalCore::new(size(20, 4)).unwrap();
        core.feed(b"foo bar foo\r\nbaz foo\r\n");
        core.update_frame().unwrap();
        core.search("foo", true).unwrap();

        let rows = core.search_highlights(4).unwrap();
        assert!(rows.contains(&(0, 0, 2)), "第一行第一个 foo：{rows:?}");
        assert!(rows.contains(&(0, 8, 10)), "第一行第二个 foo：{rows:?}");
        assert!(rows.contains(&(1, 4, 6)), "第二行 foo：{rows:?}");
    }

    #[test]
    fn caps_scrollback_growth() {
        let core = TerminalCore::new(size(40, 10)).unwrap();
        assert_eq!(
            core.terminal.scrollback_max_lines().unwrap(),
            Some(SCROLLBACK_MAX_LINES),
            "回看区必须配置上限，否则长输出会无限吃内存"
        );
    }

    #[test]
    fn detects_alternate_screen() {
        let mut core = TerminalCore::new(size(40, 6)).unwrap();
        assert!(!core.is_alternate_screen().unwrap(), "默认在主屏");

        core.feed(b"\x1b[?1049h");
        assert!(core.is_alternate_screen().unwrap(), "进入 alternate screen");

        core.feed(b"\x1b[?1049l");
        assert!(!core.is_alternate_screen().unwrap(), "回到主屏");
    }

    #[test]
    fn paste_is_framed_only_when_bracketed_paste_is_on() {
        let mut core = TerminalCore::new(size(40, 4)).unwrap();

        // 未开启且含换行：可执行命令，必须先向用户确认（返回 None）。
        assert_eq!(
            core.encode_paste("a\nb", false).unwrap(),
            None,
            "未开启 bracketed paste 时多行粘贴需要确认"
        );
        // 确认后才编码：换行转回车，不带 bracketed 前缀。
        assert_eq!(
            core.encode_paste("a\nb", true)
                .unwrap()
                .expect("确认后编码"),
            b"a\rb"
        );
        // 单行内容无需确认。
        assert_eq!(
            core.encode_paste("single", false).unwrap().expect("单行"),
            b"single"
        );

        // 开启 DECSET 2004 后：整段被包裹，换行保持原样，且无需确认。
        core.feed(b"\x1b[?2004h");
        let framed = core
            .encode_paste("a\nb", false)
            .unwrap()
            .expect("bracketed 模式");
        assert_eq!(framed, b"\x1b[200~a\nb\x1b[201~");
    }

    #[test]
    fn paste_strips_command_injection_bytes() {
        let mut core = TerminalCore::new(size(40, 4)).unwrap();
        core.feed(b"\x1b[?2004h");

        // 夹带 `ESC[201~` 试图提前结束 bracketed paste：ESC 必须被中和。
        let framed = core
            .encode_paste("a\x1b[201~rm -rf /\x1b[201~", false)
            .unwrap()
            .expect("bracketed 模式");
        let text = String::from_utf8_lossy(&framed);
        assert_eq!(text.matches("\x1b[201~").count(), 1, "只有结尾的合法终止符");
    }

    #[test]
    fn theme_change_recolors_existing_cells() {
        let mut core = TerminalCore::new(size(6, 2)).unwrap();
        core.feed(b"\x1b[31mX");
        core.update_frame().unwrap();
        let before = core.frame().rows()[0].cells[0].fg.expect("red fg");

        let mut ansi = [crate::FrameColor {
            r: 0x10,
            g: 0x10,
            b: 0x10,
        }; 16];
        ansi[1] = crate::FrameColor {
            r: 0x00,
            g: 0x00,
            b: 0xFF,
        };
        let theme = TerminalTheme {
            foreground: crate::FrameColor {
                r: 0xEE,
                g: 0xEE,
                b: 0xEE,
            },
            background: crate::FrameColor {
                r: 0x11,
                g: 0x11,
                b: 0x11,
            },
            cursor: crate::FrameColor {
                r: 0xFF,
                g: 0x99,
                b: 0x40,
            },
            ansi,
        };
        core.set_theme(&theme).unwrap();

        assert!(core.update_frame().unwrap(), "theme change must redraw");
        let colors = core.frame().colors();
        assert_eq!(colors.palette[1], ansi[1], "ANSI red follows the theme");
        assert_eq!(colors.background, theme.background);
        assert_eq!(colors.cursor, Some(theme.cursor));

        let after = core.frame().rows()[0].cells[0].fg.expect("red fg");
        assert_ne!(before, after, "existing cells re-resolve the new palette");
        assert_eq!(after, ansi[1]);
    }

    #[test]
    fn theme_palette_leaves_the_256_color_cube_alone() {
        let mut core = TerminalCore::new(size(4, 2)).unwrap();
        let standard = core.terminal.default_color_palette().unwrap();

        let mut ansi = [crate::FrameColor::default(); 16];
        ansi[0] = crate::FrameColor { r: 1, g: 2, b: 3 };
        core.set_theme(&TerminalTheme {
            foreground: crate::FrameColor::default(),
            background: crate::FrameColor::default(),
            cursor: crate::FrameColor::default(),
            ansi,
        })
        .unwrap();

        let themed = core.terminal.default_color_palette().unwrap();
        for index in 16..256 {
            assert_eq!(
                standard.0[index], themed.0[index],
                "index {index} is a standard 256-color entry"
            );
        }
    }
}
