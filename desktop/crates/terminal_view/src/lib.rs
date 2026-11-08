//! 终端视图：把 [`cgc_terminal::Frame`] 画成 GPUI 元素。
//!
//! 这一层只读 [`TerminalView`] 的状态；终端模拟与进程归 `cgc-terminal`，
//! 宿主（pane / agent panel）归 `cgc-desktop-app`。

use std::ops::Range;
use std::panic;
use std::time::{Duration, Instant};

use cgc_terminal::{
    CoreEvent, CursorVisualStyle, Frame, FrameCell, FrameColors, GridSize, Key, KeyInput, Mods,
    MouseAction as TermMouseAction, MouseButton as TermMouseButton, MouseEvent as TermMouseEvent,
    MouseInput, Session,
};
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
    /// 选中区域的背景色（半透明）。
    pub selection: Hsla,
    /// 内容与 pane 边缘的内边距（Zed 的终端也不贴边）。
    pub padding: Pixels,
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
            selection: Hsla {
                h: 0.58,
                s: 0.6,
                l: 0.55,
                a: 0.3,
            },
            padding: px(8.0),
        }
    }
}

/// 终端视图：持有 PTY 会话，渲染当前帧。
pub struct TerminalView {
    session: Session,
    style: TerminalStyle,
    cell_width: Pixels,
    focus_handle: FocusHandle,
    key_input: KeyInput,
    /// 最近一次布局的 element bounds（鼠标坐标换算用）。
    bounds: Option<Bounds<Pixels>>,
    /// 鼠标上报编码器：终端程序开启 DECSET 1000+ 时使用。
    mouse_input: Option<MouseInput>,
    selection_start: Option<(u16, u16)>,
    selecting: bool,
    title: String,
    cwd: Option<String>,
    exit_notice: Option<String>,
    search_open: bool,
    search_query: String,
    search_status: String,
    /// 收到 BEL 后的提示截止时间；`None` 表示当前没有提示。
    bell_until: Option<Instant>,
}

impl TerminalView {
    pub fn new(
        session: Session,
        style: TerminalStyle,
        key_input: KeyInput,
        window: &mut Window,
        cx: &mut Context<Self>,
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
            focus_handle: cx.focus_handle(),
            key_input,
            bounds: None,
            mouse_input: MouseInput::new().ok(),
            selection_start: None,
            selecting: false,
            title: String::new(),
            cwd: None,
            exit_notice: None,
            search_open: false,
            search_query: String::new(),
            search_status: String::new(),
            bell_until: None,
        }
    }

    pub fn focus(&self, window: &mut Window, cx: &mut App) {
        self.focus_handle.focus(window, cx);
    }

    fn handle_key(&mut self, event: &KeyDownEvent, cx: &mut Context<Self>) {
        let keystroke = &event.keystroke;

        // 搜索模式：按键只编辑查询，不发给 PTY。
        if self.search_open {
            self.handle_search_key(keystroke, cx);
            cx.stop_propagation();
            return;
        }

        // Cmd+F：打开搜索条。
        if keystroke.modifiers.platform && keystroke.key == "f" {
            self.search_open = true;
            self.search_query.clear();
            self.search_status.clear();
            cx.notify();
            cx.stop_propagation();
            return;
        }

        // Cmd+V：把剪贴板文本直接写进 PTY（也用于验证 IME 的文本通道）。
        if keystroke.modifiers.platform && keystroke.key == "v" {
            if let Some(text) = cx.read_from_clipboard().and_then(|item| item.text()) {
                self.send_text(&text, cx);
            }
            cx.stop_propagation();
            return;
        }

        // Cmd+C：复制当前选区。
        if keystroke.modifiers.platform && keystroke.key == "c" {
            self.copy_selection(cx);
            cx.stop_propagation();
            return;
        }

        let key = key_from_str(&keystroke.key);
        let mods = mods_from(&keystroke.modifiers);
        // 空格没有单字符 key 名，必须显式给编码器文本，否则会被当成纯修饰键丢掉。
        let text: Option<&str> = if keystroke.key == "space" {
            Some(" ")
        } else if keystroke.key.chars().count() == 1 {
            Some(keystroke.key.as_str())
        } else {
            None
        };

        if let Ok(bytes) = self.key_input.encode(self.session.core(), key, mods, text) {
            let bytes = bytes.to_vec();
            if !bytes.is_empty() {
                let _ = self.session.write(&bytes);
                cx.notify();
            }
        }
        cx.stop_propagation();
    }

    /// 排空 PTY 输出并刷新渲染帧；有变化时通知 GPUI 重绘。
    pub fn poll(&mut self, cx: &mut Context<Self>) {
        let Ok(result) = self.session.poll() else {
            return;
        };
        let mut changed = false;
        if result.fed_bytes > 0 {
            changed |= self.session.core_mut().update_frame().unwrap_or(false);
        }
        for event in self.session.core_mut().take_events() {
            match event {
                CoreEvent::Title(title) => {
                    self.title = title;
                    changed = true;
                }
                CoreEvent::Pwd(pwd) => {
                    self.cwd = Some(pwd);
                    changed = true;
                }
                CoreEvent::Bell => {
                    self.bell_until = Some(Instant::now() + BELL_PROMPT);
                    changed = true;
                }
            }
        }
        if let Some(exit) = result.exit {
            if self.exit_notice.is_none() {
                self.exit_notice = Some(format!(
                    "进程已退出（code {}），关闭终端可重新打开",
                    exit.code
                ));
                changed = true;
            }
        }
        // 响铃提示显示期间保持重绘，让它到点自然消失。
        if bell_prompt_visible(self.bell_until, Instant::now()) {
            changed = true;
        } else {
            self.bell_until = None;
        }
        if changed {
            cx.notify();
        }
    }

    /// 程序通过 OSC 设置的窗口标题（未设置时为空串）。
    pub fn title(&self) -> &str {
        &self.title
    }

    /// 程序上报的工作目录（OSC 7/9/1337）。
    pub fn cwd(&self) -> Option<&str> {
        self.cwd.as_deref()
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

    /// 应用新的主题样式与终端配色。
    ///
    /// 配色交给 libghostty 后，已显示的 cell 会按新调色板重新解析，
    /// 因此历史输出也会换色；随后强制刷新一帧并请求重绘。
    pub fn apply_theme(
        &mut self,
        style: TerminalStyle,
        theme: &cgc_terminal::TerminalTheme,
        cx: &mut Context<Self>,
    ) -> cgc_terminal::Result<()> {
        self.style = style;
        self.session.set_theme(theme)?;
        self.session.core_mut().update_frame()?;
        cx.notify();
        Ok(())
    }

    pub fn cell_width(&self) -> Pixels {
        self.cell_width
    }

    /// 按容器尺寸重排终端网格（PTY 与 VT 同步 resize）。
    pub fn resize(&mut self, cols: u16, rows: u16, cx: &mut Context<Self>) {
        let size = GridSize { cols, rows };
        if self.frame().size() == size {
            return;
        }
        if self.session.resize(size).is_ok() {
            let _ = self.session.core_mut().update_frame();
            cx.notify();
        }
    }

    /// 终端内容区尺寸（cols × rows 个 cell）。
    pub fn content_size(&self) -> Size<Pixels> {
        let size = self.frame().size();
        Size {
            width: self.cell_width * size.cols as f32,
            height: self.style.line_height * size.rows as f32,
        }
    }

    /// IME 提交的文本直接写入 PTY（预编辑阶段不落字）。
    pub fn send_text(&mut self, text: &str, cx: &mut Context<Self>) {
        if text.is_empty() {
            return;
        }
        if self.session.write(text.as_bytes()).is_ok() {
            cx.notify();
        }
    }

    /// 滚轮：正 delta 向下（回活动区），负 delta 向上（看历史）。
    pub fn scroll(&mut self, lines: isize, cx: &mut Context<Self>) {
        if lines == 0 {
            return;
        }
        self.session.scroll(lines);
        let _ = self.session.core_mut().update_frame();
        cx.notify();
    }

    /// 记录 element 布局，供鼠标坐标换算（不触发重绘）。
    pub fn set_bounds(&mut self, bounds: Bounds<Pixels>) {
        self.bounds = Some(bounds);
    }

    /// 鼠标指向的 cell 上的超链接（OSC 8）。
    fn link_at(&self, position: Point<Pixels>) -> Option<String> {
        let cell = self.cell_at(position)?;
        self.session.core().hyperlink_at(cell).ok().flatten()
    }

    /// 终端程序开启鼠标上报时，把事件写给 PTY；返回是否已消费。
    ///
    /// Shift 是终端惯例的“强制本地选择”修饰键，调用方在 Shift 按下时应跳过本方法。
    fn forward_mouse(
        &mut self,
        action: TermMouseAction,
        button: Option<TermMouseButton>,
        modifiers: &Modifiers,
        position: Point<Pixels>,
        cx: &mut Context<Self>,
    ) -> bool {
        let Some(bounds) = self.bounds else {
            return false;
        };
        let cell_height = f32::from(self.style.line_height).max(1.0);
        let Some(input) = self.mouse_input.as_mut() else {
            return false;
        };
        input.set_geometry(
            f32::from(bounds.size.width).max(1.0) as u32,
            f32::from(bounds.size.height).max(1.0) as u32,
            f32::from(self.cell_width).max(1.0) as u32,
            cell_height as u32,
            f32::from(self.style.padding).max(0.0) as u32,
        );
        let event = TermMouseEvent {
            action,
            button,
            mods: mods_from(modifiers),
            x: f32::from(position.x) - f32::from(bounds.origin.x),
            y: f32::from(position.y) - f32::from(bounds.origin.y),
        };
        let bytes = input
            .encode(self.session.core(), event)
            .ok()
            .flatten()
            .map(<[u8]>::to_vec);
        let Some(bytes) = bytes else {
            return false;
        };
        let _ = self.session.write(&bytes);
        cx.notify();
        true
    }

    fn cell_at(&self, position: Point<Pixels>) -> Option<(u16, u16)> {
        let bounds = self.bounds?;
        let x = f32::from(position.x) - f32::from(bounds.origin.x) - f32::from(self.style.padding);
        let y = f32::from(position.y) - f32::from(bounds.origin.y) - f32::from(self.style.padding);
        if x < 0.0 || y < 0.0 {
            return None;
        }
        let size = self.frame().size();
        let col = (x / f32::from(self.cell_width)).floor() as u16;
        let row = (y / f32::from(self.style.line_height)).floor() as u16;
        Some((
            col.min(size.cols.saturating_sub(1)),
            row.min(size.rows.saturating_sub(1)),
        ))
    }

    fn mouse_down(&mut self, position: Point<Pixels>, click_count: usize, cx: &mut Context<Self>) {
        let Some(cell) = self.cell_at(position) else {
            return;
        };
        if click_count >= 3 {
            let _ = self.session.select_line(cell);
            let _ = self.session.core_mut().update_frame();
            cx.notify();
            return;
        }
        if click_count == 2 {
            let _ = self.session.select_word(cell);
            let _ = self.session.core_mut().update_frame();
            cx.notify();
            return;
        }
        self.selection_start = Some(cell);
        self.selecting = true;
        let _ = self.session.set_selection(cell, cell);
        let _ = self.session.core_mut().update_frame();
        cx.notify();
    }

    fn mouse_move(&mut self, position: Point<Pixels>, cx: &mut Context<Self>) {
        if !self.selecting {
            return;
        }
        let (Some(start), Some(end)) = (self.selection_start, self.cell_at(position)) else {
            return;
        };
        let _ = self.session.set_selection(start, end);
        let _ = self.session.core_mut().update_frame();
        cx.notify();
    }

    fn mouse_up(&mut self) {
        self.selecting = false;
    }

    /// Cmd+C：把选区文本写入系统剪贴板。
    pub fn copy_selection(&mut self, cx: &mut App) {
        if let Ok(Some(text)) = self.session.selection_text() {
            if !text.is_empty() {
                cx.write_to_clipboard(ClipboardItem::new_string(text));
            }
        }
    }

    fn handle_search_key(&mut self, keystroke: &Keystroke, cx: &mut Context<Self>) {
        match keystroke.key.as_str() {
            "escape" => {
                self.search_open = false;
                self.search_query.clear();
                self.search_status.clear();
                self.session.clear_selection();
                let _ = self.session.core_mut().update_frame();
                cx.notify();
            }
            "enter" => self.run_search(!keystroke.modifiers.shift, cx),
            "backspace" => {
                self.search_query.pop();
                cx.notify();
            }
            key if key.chars().count() == 1 => {
                self.search_query.push_str(key);
                cx.notify();
            }
            _ => {}
        }
    }

    fn run_search(&mut self, forward: bool, cx: &mut Context<Self>) {
        if self.search_query.is_empty() {
            return;
        }
        match self.session.search(&self.search_query, forward) {
            Ok(outcome) => {
                self.search_status = if outcome.total == 0 {
                    "无匹配".to_string()
                } else {
                    format!(
                        "{}/{}",
                        outcome.index.map_or(0, |index| index + 1),
                        outcome.total
                    )
                };
                let _ = self.session.core_mut().update_frame();
            }
            Err(error) => self.search_status = format!("搜索失败：{error}"),
        }
        cx.notify();
    }
}

impl Render for TerminalView {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let exit_notice = self.exit_notice.clone();
        let notice_color = Hsla {
            a: self.style.foreground.a * 0.65,
            ..self.style.foreground
        };
        let search_bar = self.search_open.then(|| {
            let color = self.style.foreground;
            div()
                .flex()
                .flex_row()
                .items_center()
                .gap(px(6.0))
                .px(px(8.0))
                .py(px(4.0))
                .text_size(px(11.0))
                .text_color(color)
                .child(format!("搜索：{}", self.search_query))
                .child(div().flex_1())
                .child(self.search_status.clone())
        });
        let bell_bar = bell_prompt_visible(self.bell_until, Instant::now()).then(|| {
            div()
                .px(px(8.0))
                .py(px(4.0))
                .text_size(px(11.0))
                .text_color(self.style.foreground)
                .child("终端响铃（bell）")
        });
        let handle_color = Hsla {
            a: 0.32,
            ..self.style.foreground
        };
        let padding = f32::from(self.style.padding);
        let track_height = self.bounds.map_or(0.0, |bounds| {
            (f32::from(bounds.size.height) - padding * 2.0).max(0.0)
        });
        let scrollbar_el = self
            .session
            .scrollbar()
            .ok()
            .and_then(|bar| thumb_geometry(bar.total, bar.offset, bar.len).map(|geo| (bar, geo)))
            .and_then(|(bar, (top, height))| {
                if track_height <= 0.0 {
                    return None;
                }
                let total = bar.total;
                let len = bar.len;
                let thumb_top = track_height * top;
                let thumb_height = (track_height * height).max(8.0);
                Some(
                    div()
                        .id("terminal-scrollbar")
                        .absolute()
                        .top(px(padding))
                        .right(px(0.0))
                        .bottom(px(padding))
                        .w(px(10.0))
                        .child(
                            div()
                                .absolute()
                                .right(px(2.0))
                                .top(px(thumb_top))
                                .w(px(6.0))
                                .h(px(thumb_height))
                                .rounded(px(3.0))
                                .bg(handle_color),
                        )
                        .on_mouse_down(
                            MouseButton::Left,
                            cx.listener(move |this, event: &MouseDownEvent, _, cx| {
                                let Some(bounds) = this.bounds else {
                                    return;
                                };
                                let height =
                                    (f32::from(bounds.size.height) - padding * 2.0).max(1.0);
                                let ratio = ((f32::from(event.position.y)
                                    - f32::from(bounds.origin.y)
                                    - padding)
                                    / height)
                                    .clamp(0.0, 1.0);
                                let max = total.saturating_sub(len) as f32;
                                this.session.scroll_to((ratio * max) as usize);
                                let _ = this.session.core_mut().update_frame();
                                cx.notify();
                                cx.stop_propagation();
                            }),
                        ),
                )
            });
        div()
            .id("terminal-view")
            .size_full()
            .flex()
            .flex_col()
            .track_focus(&self.focus_handle)
            .on_click(cx.listener(|this, _, window, cx| this.focus(window, cx)))
            .on_key_down(
                cx.listener(|this, event: &KeyDownEvent, _, cx| this.handle_key(event, cx)),
            )
            .on_scroll(cx.listener(|this, event: &ScrollEvent, window, cx| {
                let modifiers = window.modifiers();
                let delta_y: f32 = match event.delta {
                    ScrollDelta::Lines(point) => point.y,
                    ScrollDelta::Pixels(point) => f32::from(point.y),
                };
                // 终端程序开启鼠标上报时，滚轮作为按键 4/5 发给 PTY；
                // Shift+滚轮保留给本地 scrollback（终端惯例）。
                let wheel = if delta_y > 0.0 {
                    Some(TermMouseButton::WheelDown)
                } else if delta_y < 0.0 {
                    Some(TermMouseButton::WheelUp)
                } else {
                    None
                };
                if !modifiers.shift {
                    if let Some(button) = wheel {
                        if this.forward_mouse(
                            TermMouseAction::Press,
                            Some(button),
                            &modifiers,
                            event.position,
                            cx,
                        ) {
                            cx.stop_propagation();
                            return;
                        }
                    }
                }
                let lines = match event.delta {
                    ScrollDelta::Lines(point) => point.y.round() as isize,
                    ScrollDelta::Pixels(point) => {
                        let line_height = f32::from(this.style.line_height).max(1.0);
                        (f32::from(point.y) / line_height).round() as isize
                    }
                };
                this.scroll(lines, cx);
                cx.stop_propagation();
            }))
            .on_mouse_down(
                MouseButton::Left,
                cx.listener(|this, event: &MouseDownEvent, window, cx| {
                    this.focus(window, cx);
                    // Cmd+单击优先打开 OSC 8 链接（与 Zed 一致）。
                    if event.modifiers.platform {
                        if let Some(uri) = this.link_at(event.position) {
                            cx.open_url(&uri);
                            cx.stop_propagation();
                            return;
                        }
                    }
                    if !event.modifiers.shift
                        && this.forward_mouse(
                            TermMouseAction::Press,
                            Some(TermMouseButton::Left),
                            &event.modifiers,
                            event.position,
                            cx,
                        )
                    {
                        cx.stop_propagation();
                        return;
                    }
                    this.mouse_down(event.position, event.click_count, cx);
                }),
            )
            .on_mouse_move(cx.listener(|this, event: &MouseMoveEvent, _, cx| {
                if this.forward_mouse(
                    TermMouseAction::Motion,
                    None,
                    &event.modifiers,
                    event.position,
                    cx,
                ) {
                    return;
                }
                this.mouse_move(event.position, cx)
            }))
            .on_mouse_up(
                MouseButton::Left,
                cx.listener(|this, event: &MouseUpEvent, _, cx| {
                    // 本地选择（Shift 按下或正在拖选）时不向终端发孤立的 Release。
                    if !this.selecting
                        && !event.modifiers.shift
                        && this.forward_mouse(
                            TermMouseAction::Release,
                            Some(TermMouseButton::Left),
                            &event.modifiers,
                            event.position,
                            cx,
                        )
                    {
                        cx.stop_propagation();
                        return;
                    }
                    this.mouse_up();
                    cx.notify();
                }),
            )
            .children(search_bar)
            .children(bell_bar)
            .child(
                div()
                    .flex_1()
                    .min_h(px(0.0))
                    .relative()
                    .child(TerminalElement {
                        view: cx.entity(),
                        style: self.style.clone(),
                        cell_width: self.cell_width,
                    })
                    .children(scrollbar_el),
            )
            .children(exit_notice.map(|notice| {
                div()
                    .px(px(8.0))
                    .pb(px(6.0))
                    .text_size(px(11.0))
                    .text_color(notice_color)
                    .child(notice)
            }))
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
        // 与 Zed 一致：终端撑满可用区域，行列数由 prepaint 按实际尺寸换算。
        let mut style = Style::default();
        style.size.width = relative(1.0).into();
        style.size.height = relative(1.0).into();
        (window.request_layout(style, [], cx), ())
    }

    fn prepaint(
        &mut self,
        _id: Option<&GlobalElementId>,
        _inspector_id: Option<&InspectorElementId>,
        bounds: Bounds<Pixels>,
        _request_layout: &mut Self::RequestLayoutState,
        _window: &mut Window,
        cx: &mut App,
    ) -> Self::PrepaintState {
        let padding = f32::from(self.style.padding);
        let cols = ((f32::from(bounds.size.width) - padding * 2.0) / f32::from(self.cell_width))
            .floor()
            .max(1.0) as u16;
        let rows = ((f32::from(bounds.size.height) - padding * 2.0)
            / f32::from(self.style.line_height))
        .floor()
        .max(1.0) as u16;
        let current = {
            let view = self.view.read(cx);
            view.frame().size()
        };
        if current.cols != cols || current.rows != rows {
            self.view.update(cx, |view, cx| {
                view.resize(cols, rows, cx);
            });
        }
        let known_bounds = {
            let view = self.view.read(cx);
            view.bounds
        };
        if known_bounds != Some(bounds) {
            self.view.update(cx, |view, _| view.set_bounds(bounds));
        }
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

        // IME：macOS 的输入法通过 InputHandler 提交文本，直接写进 PTY。
        let focus = self.view.read(cx).focus_handle.clone();
        window.handle_input(
            &focus,
            TerminalInputHandler {
                view: self.view.clone(),
            },
            cx,
        );
        // 与 Zed 的 TerminalElement 一样，把整帧放进 element 的内容遮罩里：
        // glyph 绘制依赖 content mask。
        window.with_content_mask(Some(ContentMask { bounds }), |window| {
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
                    x: plan.origin.x,
                    y: row.y + (plan.line_height - plan.font_size) / 2.0 + line.ascent,
                };
                let _ = line.paint(origin, plan.line_height, TextAlign::Left, None, window, cx);
            }
        });
    }
}

struct CursorPlan {
    x: u16,
    y: u16,
    color: Hsla,
    style: CursorVisualStyle,
    at_wide_tail: bool,
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
    origin: Point<Pixels>,
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
    let origin = Point {
        x: bounds.origin.x + style.padding,
        y: bounds.origin.y + style.padding,
    };

    let cursor_plan = frame.cursor().map(|cursor| CursorPlan {
        x: cursor.x,
        y: cursor.y,
        color: colors.cursor.map(to_hsla).unwrap_or(style.cursor),
        style: cursor.style,
        at_wide_tail: cursor.at_wide_tail,
    });

    let mut backgrounds = Vec::new();
    let mut rows = Vec::new();

    for (row_index, row) in frame.rows().iter().enumerate() {
        let y = origin.y + style.line_height * row_index as f32;
        let selected_range = row.selected;
        let mut text = String::new();
        let mut runs: Vec<TextRun> = Vec::new();
        let mut column = 0usize;

        while column < row.cells.len() {
            let cell = &row.cells[column];
            if cell.spacer_tail {
                column += 1;
                continue;
            }
            let (mut fg, mut bg) = cell_colors(cell, colors, foreground);
            if let Some((start, end)) = selected_range {
                if column >= start && column <= end {
                    bg = Some(style.selection);
                }
            }
            if let Some(cursor) = &cursor_plan {
                if cursor.style == CursorVisualStyle::Block
                    && row_index as u16 == cursor.y
                    && (column as u16 == cursor.x
                        || (cursor.at_wide_tail && column as u16 + 1 == cursor.x))
                {
                    // Block 光标：该格反色（zed 的做法），文字用背景色画在光标块上。
                    fg = style.background;
                    bg = Some(cursor.color);
                }
            }
            let font = cell_font(cell, style);

            if let Some(bg) = bg {
                let x = origin.x + cell_width * column as f32;
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
            column += 1;
        }

        if !text.trim().is_empty() {
            rows.push(RowPlan { text, runs, y });
        }
    }

    let cursor = cursor_plan.map(|cursor| {
        let x = origin.x + cell_width * cursor.x as f32;
        let y = origin.y + style.line_height * cursor.y as f32;
        let quad = match cursor.style {
            CursorVisualStyle::Bar => Bounds::new(
                Point { x, y },
                Size {
                    width: px(2.0),
                    height: style.line_height,
                },
            ),
            CursorVisualStyle::Underline => Bounds::new(
                Point {
                    x,
                    y: y + style.line_height - px(2.0),
                },
                Size {
                    width: cell_width,
                    height: px(2.0),
                },
            ),
            // Block / Hollow / 未来新增样式都先按整格块画。
            _ => Bounds::new(
                Point { x, y },
                Size {
                    width: cell_width,
                    height: style.line_height,
                },
            ),
        };
        (quad, cursor.color)
    });

    PaintPlan {
        background: style.background,
        backgrounds,
        rows,
        cursor,
        origin,
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

fn mods_from(modifiers: &Modifiers) -> Mods {
    let mut mods = Mods::empty();
    if modifiers.shift {
        mods |= Mods::SHIFT;
    }
    if modifiers.control {
        mods |= Mods::CTRL;
    }
    if modifiers.alt {
        mods |= Mods::ALT;
    }
    if modifiers.platform {
        mods |= Mods::SUPER;
    }
    mods
}

/// GPUI 的按键名 → libghostty-vt 的 [`Key`]。
fn key_from_str(key: &str) -> Key {
    match key {
        "a" => Key::A,
        "b" => Key::B,
        "c" => Key::C,
        "d" => Key::D,
        "e" => Key::E,
        "f" => Key::F,
        "g" => Key::G,
        "h" => Key::H,
        "i" => Key::I,
        "j" => Key::J,
        "k" => Key::K,
        "l" => Key::L,
        "m" => Key::M,
        "n" => Key::N,
        "o" => Key::O,
        "p" => Key::P,
        "q" => Key::Q,
        "r" => Key::R,
        "s" => Key::S,
        "t" => Key::T,
        "u" => Key::U,
        "v" => Key::V,
        "w" => Key::W,
        "x" => Key::X,
        "y" => Key::Y,
        "z" => Key::Z,
        "0" => Key::Digit0,
        "1" => Key::Digit1,
        "2" => Key::Digit2,
        "3" => Key::Digit3,
        "4" => Key::Digit4,
        "5" => Key::Digit5,
        "6" => Key::Digit6,
        "7" => Key::Digit7,
        "8" => Key::Digit8,
        "9" => Key::Digit9,
        "-" => Key::Minus,
        "=" => Key::Equal,
        "[" => Key::BracketLeft,
        "]" => Key::BracketRight,
        "\\" => Key::Backslash,
        ";" => Key::Semicolon,
        "'" => Key::Quote,
        "," => Key::Comma,
        "." => Key::Period,
        "/" => Key::Slash,
        "`" => Key::Backquote,
        "enter" => Key::Enter,
        "backspace" => Key::Backspace,
        "tab" => Key::Tab,
        "space" => Key::Space,
        "escape" => Key::Escape,
        "delete" => Key::Delete,
        "home" => Key::Home,
        "end" => Key::End,
        "pageup" => Key::PageUp,
        "pagedown" => Key::PageDown,
        "insert" => Key::Insert,
        "up" => Key::ArrowUp,
        "down" => Key::ArrowDown,
        "left" => Key::ArrowLeft,
        "right" => Key::ArrowRight,
        "f1" => Key::F1,
        "f2" => Key::F2,
        "f3" => Key::F3,
        "f4" => Key::F4,
        "f5" => Key::F5,
        "f6" => Key::F6,
        "f7" => Key::F7,
        "f8" => Key::F8,
        "f9" => Key::F9,
        "f10" => Key::F10,
        "f11" => Key::F11,
        "f12" => Key::F12,
        _ => Key::Unidentified,
    }
}

/// IME 桥：把输入法提交的文本写进 PTY。
///
/// 预编辑（marked text）阶段不落字——macOS 在用户选词后调用
/// `replace_text_in_range` 提交最终文本；若在 marked 阶段就发送，
/// 组合过程中会重复写入。
struct TerminalInputHandler {
    view: Entity<TerminalView>,
}

impl InputHandler for TerminalInputHandler {
    fn selected_text_range(
        &mut self,
        _ignore_disabled_input: bool,
        _window: &mut Window,
        _cx: &mut App,
    ) -> Option<UTF16Selection> {
        Some(UTF16Selection {
            range: 0..0,
            reversed: false,
        })
    }

    fn marked_text_range(&mut self, _window: &mut Window, _cx: &mut App) -> Option<Range<usize>> {
        None
    }

    fn text_for_range(
        &mut self,
        _range_utf16: Range<usize>,
        _adjusted_range: &mut Option<Range<usize>>,
        _window: &mut Window,
        _cx: &mut App,
    ) -> Option<String> {
        Some(String::new())
    }

    fn replace_text_in_range(
        &mut self,
        _replacement_range: Option<Range<usize>>,
        text: &str,
        _window: &mut Window,
        cx: &mut App,
    ) {
        self.view.update(cx, |view, cx| view.send_text(text, cx));
    }

    fn replace_and_mark_text_in_range(
        &mut self,
        _range_utf16: Option<Range<usize>>,
        _new_text: &str,
        _new_selected_range: Option<Range<usize>>,
        _window: &mut Window,
        _cx: &mut App,
    ) {
    }

    fn unmark_text(&mut self, _window: &mut Window, _cx: &mut App) {}

    fn bounds_for_range(
        &mut self,
        _range_utf16: Range<usize>,
        _window: &mut Window,
        _cx: &mut App,
    ) -> Option<Bounds<Pixels>> {
        // 候选窗定位依赖 element bounds；当前未保存，先返回 None。
        None
    }

    fn character_index_for_point(
        &mut self,
        _point: Point<Pixels>,
        _window: &mut Window,
        _cx: &mut App,
    ) -> Option<usize> {
        None
    }
}

/// 响铃提示的显示时长。
const BELL_PROMPT: Duration = Duration::from_millis(1200);

/// 滚动条拇指的 `(top, height)`，单位是轨道比例；不需要滚动时返回 `None`。
fn thumb_geometry(total: u64, offset: u64, len: u64) -> Option<(f32, f32)> {
    // 极小屏也要留出可拖动的拇指。
    const MIN_THUMB: f32 = 0.04;
    if len == 0 || total <= len {
        return None;
    }
    let height = (len as f32 / total as f32).clamp(MIN_THUMB, 1.0);
    let max_top = 1.0 - height;
    let scrollable = (total - len) as f32;
    let progress = (offset as f32 / scrollable).clamp(0.0, 1.0);
    Some((progress * max_top, height))
}

/// 响铃提示在 `now` 时刻是否可见。
fn bell_prompt_visible(until: Option<Instant>, now: Instant) -> bool {
    until.is_some_and(|deadline| now < deadline)
}

#[cfg(test)]
mod tests {
    // 只做显式导入：父模块的 `use gpui_kit::*` 会引入 gpui 的 test 宏，
    // 遮蔽 std 的 `#[test]` 并触发递归展开。
    use super::{bell_prompt_visible, thumb_geometry};
    use std::time::{Duration, Instant};

    #[test]
    fn scrollbar_thumb_tracks_offset_and_length() {
        let close = |a: f32, b: f32| (a - b).abs() < 1e-6;

        let (top, height) = thumb_geometry(100, 0, 20).expect("需要滚动条");
        assert!(close(top, 0.0));
        assert!(close(height, 0.2));

        let (top, _) = thumb_geometry(100, 80, 20).expect("需要滚动条");
        assert!(close(top, 0.8), "滚到底部时拇指贴底");

        let (top, _) = thumb_geometry(100, 40, 20).expect("需要滚动条");
        assert!(close(top, 0.4));
    }

    #[test]
    fn scrollbar_hidden_when_everything_fits() {
        assert_eq!(thumb_geometry(20, 0, 20), None);
        assert_eq!(thumb_geometry(10, 0, 19), None);
        assert_eq!(thumb_geometry(0, 0, 0), None);
    }

    #[test]
    fn bell_prompt_expires_at_its_deadline() {
        let now = Instant::now();
        assert!(!bell_prompt_visible(None, now));
        assert!(bell_prompt_visible(
            Some(now + Duration::from_millis(1)),
            now
        ));
        assert!(!bell_prompt_visible(Some(now), now));
        assert!(!bell_prompt_visible(
            Some(now - Duration::from_millis(1)),
            now
        ));
    }
}
