//! 终端视图：把 [`cgc_terminal::Frame`] 画成 GPUI 元素。
//!
//! 这一层只读 [`TerminalView`] 的状态；终端模拟与进程归 `cgc-terminal`，
//! 宿主（pane / agent panel）归 `cgc-desktop-app`。

use std::panic;

use cgc_terminal::{Frame, FrameCell, FrameColors, Session};
use gpui_kit::*;

/// 终端绘制样式。颜色覆盖 `Frame` 自带的默认色（主题跟随宿主）。
#[derive(Clone)]
pub struct TerminalStyle {
    pub font: Font,
    pub font_size: Pixels,
    pub line_height: Pixels,
    pub background: Hsla,
    pub foreground: Hsla,
    pub cursor: Hsla,
}

impl TerminalStyle {
    pub fn new(font: Font, font_size: Pixels) -> Self {
        Self {
            font,
            font_size,
            line_height: font_size * 1.4,
            background: rgb(0x1e1e1e).into(),
            foreground: rgb(0xd4d4d4).into(),
            cursor: rgb(0xffffff).into(),
        }
    }
}

/// 终端视图：持有 PTY 会话，渲染当前帧。
pub struct TerminalView {
    session: Session,
    style: TerminalStyle,
    cell_width: Pixels,
}

impl TerminalView {
    pub fn new(
        session: Session,
        style: TerminalStyle,
        window: &mut Window,
        _cx: &mut Context<Self>,
    ) -> Self {
        let font_id = window.text_system().resolve_font(&style.font);
        let cell_width = window
            .text_system()
            .ch_width(font_id, style.font_size)
            .unwrap_or_else(|_| px(8.0));
        Self {
            session,
            style,
            cell_width,
        }
    }

    /// 排空 PTY 输出并刷新渲染帧；有变化时通知 GPUI 重绘。
    pub fn poll(&mut self, cx: &mut Context<Self>) {
        let Ok(result) = self.session.poll() else {
            return;
        };
        if result.fed_bytes > 0 {
            let _ = self.session.core_mut().update_frame();
            cx.notify();
        }
        if result.exit.is_some() {
            cx.notify();
        }
    }

    pub fn frame(&self) -> &Frame {
        self.session.core().frame()
    }

    pub fn session_mut(&mut self) -> &mut Session {
        &mut self.session
    }

    pub fn style(&self) -> &TerminalStyle {
        &self.style
    }

    pub fn cell_width(&self) -> Pixels {
        self.cell_width
    }

    /// 终端内容区尺寸（cols × rows 个 cell）。
    pub fn content_size(&self) -> Size<Pixels> {
        let size = self.frame().size();
        Size {
            width: self.cell_width * size.cols as f32,
            height: self.style.line_height * size.rows as f32,
        }
    }
}

impl Render for TerminalView {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        TerminalElement {
            view: cx.entity(),
            style: self.style.clone(),
            cell_width: self.cell_width,
        }
    }
}

struct TerminalElement {
    view: Entity<TerminalView>,
    style: TerminalStyle,
    cell_width: Pixels,
}

impl IntoElement for TerminalElement {
    type Element = Self;

    fn into_element(self) -> Self::Element {
        self
    }
}

impl Element for TerminalElement {
    type RequestLayoutState = ();
    type PrepaintState = ();

    fn id(&self) -> Option<ElementId> {
        None
    }

    fn source_location(&self) -> Option<&'static panic::Location<'static>> {
        None
    }

    fn request_layout(
        &mut self,
        _id: Option<&GlobalElementId>,
        _inspector_id: Option<&InspectorElementId>,
        window: &mut Window,
        cx: &mut App,
    ) -> (LayoutId, Self::RequestLayoutState) {
        let (cols, rows) = {
            let view = self.view.read(cx);
            let size = view.frame().size();
            (size.cols, size.rows)
        };
        let mut style = Style::default();
        style.size.width = (self.cell_width * cols as f32).into();
        style.size.height = (self.style.line_height * rows as f32).into();
        (window.request_layout(style, [], cx), ())
    }

    fn prepaint(
        &mut self,
        _id: Option<&GlobalElementId>,
        _inspector_id: Option<&InspectorElementId>,
        _bounds: Bounds<Pixels>,
        _request_layout: &mut Self::RequestLayoutState,
        _window: &mut Window,
        _cx: &mut App,
    ) -> Self::PrepaintState {
    }

    fn paint(
        &mut self,
        _id: Option<&GlobalElementId>,
        _inspector_id: Option<&InspectorElementId>,
        bounds: Bounds<Pixels>,
        _request_layout: &mut Self::RequestLayoutState,
        _prepaint: &mut Self::PrepaintState,
        window: &mut Window,
        cx: &mut App,
    ) {
        // 先在只读借用里把绘制计划取成 owned 数据，之后才能可变借用 cx 去画文字。
        let plan = {
            let view = self.view.read(cx);
            build_plan(view.frame(), &self.style, self.cell_width, bounds)
        };

        window.paint_quad(fill(bounds, plan.background));
        for (quad, color) in &plan.backgrounds {
            window.paint_quad(fill(*quad, *color));
        }
        if let Some((quad, color)) = plan.cursor {
            window.paint_quad(fill(quad, color));
        }

        for row in &plan.rows {
            let line = window.text_system().shape_line(
                row.text.clone().into(),
                plan.font_size,
                &row.runs,
                None,
            );
            let origin = Point {
                x: bounds.origin.x,
                y: row.y + (plan.line_height - plan.font_size) / 2.0 + line.ascent,
            };
            let _ = line.paint(origin, plan.line_height, TextAlign::Left, None, window, cx);
        }
    }
}

struct RowPlan {
    text: String,
    runs: Vec<TextRun>,
    y: Pixels,
}

struct PaintPlan {
    background: Hsla,
    backgrounds: Vec<(Bounds<Pixels>, Hsla)>,
    rows: Vec<RowPlan>,
    cursor: Option<(Bounds<Pixels>, Hsla)>,
    font_size: Pixels,
    line_height: Pixels,
}

fn build_plan(
    frame: &Frame,
    style: &TerminalStyle,
    cell_width: Pixels,
    bounds: Bounds<Pixels>,
) -> PaintPlan {
    let colors = frame.colors();
    let foreground = style.foreground;

    let mut backgrounds = Vec::new();
    let mut rows = Vec::new();

    for (row_index, row) in frame.rows().iter().enumerate() {
        let y = bounds.origin.y + style.line_height * row_index as f32;
        let mut text = String::new();
        let mut runs: Vec<TextRun> = Vec::new();
        let mut column = 0usize;

        while column < row.cells.len() {
            let cell = &row.cells[column];
            let (fg, bg) = cell_colors(cell, colors, foreground);
            let font = cell_font(cell, style);

            if let Some(bg) = bg {
                let x = bounds.origin.x + cell_width * column as f32;
                backgrounds.push((
                    Bounds::new(
                        Point { x, y },
                        Size {
                            width: cell_width,
                            height: style.line_height,
                        },
                    ),
                    bg,
                ));
            }

            let piece: &str = if cell.text.is_empty() {
                " "
            } else {
                &cell.text
            };
            let len = piece.len();
            let underline = cell.underline.then(|| UnderlineStyle {
                color: Some(fg),
                thickness: px(1.0),
                wavy: false,
            });
            let strikethrough = cell.strikethrough.then(|| StrikethroughStyle {
                color: Some(fg),
                thickness: px(1.0),
            });

            let merge = runs.last().is_some_and(|last| {
                last.color == fg
                    && last.font.weight == font.weight
                    && last.font.style == font.style
                    && last.underline == underline
                    && last.strikethrough == strikethrough
            });

            if merge {
                if let Some(last) = runs.last_mut() {
                    last.len += len;
                }
            } else {
                runs.push(TextRun {
                    len,
                    font,
                    color: fg,
                    background_color: None,
                    underline,
                    strikethrough,
                });
            }

            text.push_str(piece);
            column += if cell.wide { 2 } else { 1 };
        }

        if !text.trim().is_empty() {
            rows.push(RowPlan { text, runs, y });
        }
    }

    let cursor = frame.cursor().map(|cursor| {
        let color = colors.cursor.map(to_hsla).unwrap_or(style.cursor);
        let x = bounds.origin.x + cell_width * cursor.x as f32;
        let y = bounds.origin.y + style.line_height * cursor.y as f32;
        let quad = Bounds::new(
            Point { x, y },
            Size {
                width: cell_width,
                height: style.line_height,
            },
        );
        (quad, color)
    });

    PaintPlan {
        background: style.background,
        backgrounds,
        rows,
        cursor,
        font_size: style.font_size,
        line_height: style.line_height,
    }
}

fn cell_colors(cell: &FrameCell, colors: &FrameColors, foreground: Hsla) -> (Hsla, Option<Hsla>) {
    let mut fg = cell.fg.map(to_hsla).unwrap_or(foreground);
    let mut bg = cell.bg.map(to_hsla);
    if cell.inverse {
        let inverted_bg = fg;
        fg = bg.unwrap_or(to_hsla(colors.background));
        bg = Some(inverted_bg);
    }
    if cell.faint {
        fg.a *= 0.7;
    }
    (fg, bg)
}

fn cell_font(cell: &FrameCell, style: &TerminalStyle) -> Font {
    let mut font = style.font.clone();
    if cell.bold {
        font.weight = FontWeight::BOLD;
    }
    if cell.italic {
        font.style = FontStyle::Italic;
    }
    font
}

fn to_hsla(color: cgc_terminal::FrameColor) -> Hsla {
    Rgba {
        r: color.r as f32 / 255.0,
        g: color.g as f32 / 255.0,
        b: color.b as f32 / 255.0,
        a: 1.0,
    }
    .into()
}
