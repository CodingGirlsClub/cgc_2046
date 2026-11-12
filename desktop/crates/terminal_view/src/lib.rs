//! 终端视图：把 [`cgc_terminal::Frame`] 画成 GPUI 元素。
//!
//! 这一层只读 [`TerminalView`] 的状态；终端模拟与进程归 `cgc-terminal`，
//! 宿主（pane / agent panel）归 `cgc-desktop-app`。

use std::ops::Range;
use std::panic;

use cgc_terminal::{
    CoreEvent, CursorVisualStyle, Frame, FrameCell, FrameColors, GridSize, Key, KeyInput, Mods,
    MouseAction as TermMouseAction, MouseButton as TermMouseButton, MouseEvent as TermMouseEvent,
    MouseInput, Session,
};
use gpui_kit::component::input::{Input, InputEvent, InputState};
use gpui_kit::*;

mod links;

use links::{file_url, link_in_line, resolve_path, LinkKind};

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
    /// 搜索匹配的背景色（半透明；选区与光标会覆盖它）。
    pub match_highlight: Hsla,
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
            match_highlight: Hsla {
                h: 0.12,
                s: 0.9,
                l: 0.55,
                a: 0.35,
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
    /// 搜索输入框：Cmd+F 打开后获得焦点，走 Input 组件（支持 IME）。
    search_input: gpui_kit::Entity<InputState>,
    search_status: String,
    /// 当前搜索在视口内的匹配区间 `(row, start_col, end_col)`，供渲染高亮。
    pub(crate) search_highlights: Vec<(u16, u16, u16)>,
    /// 输入框订阅：View 存活期间保持订阅，字段本身不读取。
    #[allow(dead_code)]
    search_subscription: Option<Subscription>,
    /// 收到 BEL 后保持标记，直到用户下一次按键。
    bell_pending: bool,
    /// 等待用户确认的不安全粘贴内容（非 bracketed 且含换行）。
    pending_paste: Option<String>,
    /// 子进程退出码（历史侧栏回填用）。
    exit_code: Option<u32>,
    /// IME 预编辑（marked）文本：只用于回显，不写入 PTY。
    ime_marked: Option<String>,
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
        let search_input = cx.new(|cx| InputState::new(window, cx).placeholder("搜索"));
        let search_subscription = cx.subscribe(
            &search_input,
            |this, _input, event: &InputEvent, cx| match event {
                InputEvent::Change => this.search_changed(cx),
                // Enter 下一个、Shift+Enter 上一个（与 Zed 的搜索条一致）。
                InputEvent::PressEnter { shift, .. } => this.search_step(!*shift, cx),
                _ => {}
            },
        );
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
            search_input,
            search_status: String::new(),
            search_highlights: Vec::new(),
            search_subscription: Some(search_subscription),
            bell_pending: false,
            pending_paste: None,
            exit_code: None,
            ime_marked: None,
        }
    }

    pub fn focus(&self, window: &mut Window, cx: &mut App) {
        self.focus_handle.focus(window, cx);
    }

    fn handle_key(&mut self, event: &KeyDownEvent, window: &mut Window, cx: &mut Context<Self>) {
        let keystroke = &event.keystroke;

        // 搜索模式：字符与 Enter 由输入框处理；只有未被消费的 Esc 冒泡到这里。
        if self.search_open {
            if keystroke.key == "escape" {
                self.close_search(window, cx);
            }
            cx.stop_propagation();
            return;
        }

        // 用户真正敲键后清除响铃标记（纯修饰键不算）。
        if self.bell_pending && clears_bell(&keystroke.key) {
            self.bell_pending = false;
            cx.notify();
        }

        // Cmd+F：打开搜索条并把焦点交给输入框。
        if keystroke.modifiers.platform && keystroke.key == "f" {
            self.search_open = true;
            self.session.clear_selection();
            let handle = self.search_input.read(cx).focus_handle(cx).clone();
            window.focus(&handle, cx);
            cx.notify();
            cx.stop_propagation();
            return;
        }

        // Cmd+V：按终端模式编码粘贴（bracketed paste / 换行转换 / 控制字节过滤）。
        if keystroke.modifiers.platform && keystroke.key == "v" {
            if let Some(text) = cx.read_from_clipboard().and_then(|item| item.text()) {
                self.paste(&text, cx);
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

        // 普通按键表示放弃那次待确认的粘贴。
        if self.pending_paste.is_some() {
            self.pending_paste = None;
            cx.notify();
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

    /// 视口内容或尺寸变化后重算搜索高亮（滚动、新输出、resize）。
    fn refresh_search_highlights(&mut self, cx: &mut Context<Self>) {
        let query = self.search_input.read(cx).value().to_string();
        if !needs_highlight_refresh(self.search_open, &query) {
            self.search_highlights.clear();
            return;
        }
        let rows = self.frame().size().rows;
        self.search_highlights = match self.session.core_mut().search_highlights(rows) {
            Ok(ranges) => ranges,
            Err(error) => {
                log::warn!(target: "terminal", "搜索高亮失败：{error}");
                Vec::new()
            }
        };
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
                    self.bell_pending = true;
                    changed = true;
                }
            }
        }
        if let Some(exit) = result.exit {
            self.exit_code = Some(exit.code);
            if self.exit_notice.is_none() {
                self.exit_notice = Some(format!(
                    "进程已退出（code {}），关闭终端可重新打开",
                    exit.code
                ));
                changed = true;
            }
        }
        if changed {
            self.refresh_search_highlights(cx);
            cx.notify();
        }
    }

    /// 程序通过 OSC 设置的窗口标题（未设置时为空串）。
    pub fn title(&self) -> &str {
        &self.title
    }

    /// 子进程退出码；仍在运行时为 `None`。
    pub fn exit_code(&self) -> Option<u32> {
        self.exit_code
    }

    /// 预编辑（IME marked）文本：只用于回显，不写入 PTY。
    pub(crate) fn set_ime_marked(&mut self, text: String, cx: &mut Context<Self>) {
        let next = (!text.is_empty()).then_some(text);
        if self.ime_marked != next {
            self.ime_marked = next;
            cx.notify();
        }
    }

    /// 光标格的窗口矩形：IME 候选窗据此贴着光标弹出。
    pub(crate) fn cursor_bounds(&self) -> Option<Bounds<Pixels>> {
        let bounds = self.bounds?;
        let cursor = self.frame().cursor()?;
        Some(cursor_rect(
            bounds.origin,
            (cursor.x, cursor.y),
            self.cell_width,
            self.style.line_height,
            self.style.padding,
        ))
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
            self.refresh_search_highlights(cx);
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

    /// Cmd+V：粘贴走终端的编码规则，而不是把原始字节直接灌进 PTY。
    pub fn paste(&mut self, text: &str, cx: &mut Context<Self>) {
        if text.is_empty() {
            return;
        }
        // 粘贴也是用户动作：清掉响铃标记。
        self.bell_pending = false;
        // 第二次粘贴同一内容视为用户确认（内容可能含换行，会立即执行）。
        let confirmed = self.pending_paste.as_deref() == Some(text);
        match self.session.paste(text, confirmed) {
            Ok(true) => {
                self.pending_paste = None;
                cx.notify();
            }
            Ok(false) => {
                self.pending_paste = Some(text.to_string());
                cx.notify();
            }
            Err(error) => {
                log::warn!(target: "terminal", "粘贴失败：{error}");
            }
        }
    }

    /// IME 提交的文本直接写入 PTY（预编辑阶段不落字）。
    pub fn send_text(&mut self, text: &str, cx: &mut Context<Self>) {
        if text.is_empty() {
            return;
        }
        // 提交即结束组合，清掉回显。
        self.ime_marked = None;
        if self.session.write(text.as_bytes()).is_ok() {
            cx.notify();
        }
    }

    /// 滚轮：alternate screen（vim / less）里转成方向键；否则滚动 scrollback。
    ///
    /// 全屏程序没有 scrollback，滚轮事件必须变成按键它们才能响应。
    pub fn scroll(&mut self, lines: isize, cx: &mut Context<Self>) {
        if lines == 0 {
            return;
        }
        if self.session.core().is_alternate_screen().unwrap_or(false) {
            if let Some((key, count)) = alternate_scroll_key(lines) {
                for _ in 0..count {
                    if let Ok(bytes) =
                        self.key_input
                            .encode(self.session.core(), key, Mods::empty(), None)
                    {
                        let bytes = bytes.to_vec();
                        if !bytes.is_empty() {
                            let _ = self.session.write(&bytes);
                        }
                    }
                }
            }
            cx.notify();
            return;
        }
        self.session.scroll(lines);
        let _ = self.session.core_mut().update_frame();
        self.refresh_search_highlights(cx);
        cx.notify();
    }

    /// 滚动条跳转：移动视口并刷新搜索高亮。
    pub fn scroll_to_offset(&mut self, offset: usize, cx: &mut Context<Self>) {
        self.session.scroll_to(offset);
        let _ = self.session.core_mut().update_frame();
        self.refresh_search_highlights(cx);
        cx.notify();
    }

    /// 记录 element 布局，供鼠标坐标换算（不触发重绘）。
    pub fn set_bounds(&mut self, bounds: Bounds<Pixels>) {
        self.bounds = Some(bounds);
    }

    /// Cmd+单击：OSC 8 链接优先，其次识别输出文本里的 URL / 文件路径。
    fn open_link_at(&mut self, position: Point<Pixels>, cx: &mut Context<Self>) -> bool {
        let Some(cell) = self.cell_at(position) else {
            return false;
        };
        if let Ok(Some(uri)) = self.session.core().hyperlink_at(cell) {
            // OSC 8 的 URI 与可见文本无关：只放行 http(s)，其它 scheme
            // （file / smb / 自定义）不拉起，避免被输出诱骗打开本地目标。
            if is_safe_link(&uri) {
                cx.open_url(&uri);
            }
            return true;
        }
        let Some((target, kind)) = self.text_link_at(cell) else {
            return false;
        };
        match kind {
            LinkKind::Url => cx.open_url(&target),
            LinkKind::Path => {
                let Some(path) = resolve_path(&target, self.cwd.as_deref()) else {
                    return false;
                };
                if !path.exists() {
                    return false;
                }
                cx.open_url(&file_url(&path));
            }
        }
        true
    }

    /// 行文本里与 `cell` 重叠的链接（文本由 cell 拼出，列 → 字节偏移同步记录）。
    fn text_link_at(&self, cell: (u16, u16)) -> Option<(String, LinkKind)> {
        let row = self.frame().rows().get(cell.1 as usize)?;
        let mut text = String::new();
        let mut offsets = Vec::with_capacity(row.cells.len());
        for frame_cell in &row.cells {
            offsets.push(text.len());
            if frame_cell.spacer_tail {
                continue;
            }
            if frame_cell.text.is_empty() {
                text.push(' ');
            } else {
                text.push_str(&frame_cell.text);
            }
        }
        let byte_index = *offsets.get(cell.0 as usize)?;
        let span = link_in_line(&text, byte_index)?;
        Some((text[span.start..span.end].to_string(), span.kind))
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

    /// 关闭搜索条：清空查询、清选区、焦点还给终端。
    fn close_search(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.search_open = false;
        self.search_status.clear();
        self.search_highlights.clear();
        self.search_input
            .update(cx, |state, cx| state.set_value("", window, cx));
        self.session.clear_selection();
        let _ = self.session.core_mut().update_frame();
        self.focus(window, cx);
        cx.notify();
    }

    /// 输入框内容变化：空查询清状态，其余实时跳到下一个匹配。
    fn search_changed(&mut self, cx: &mut Context<Self>) {
        let query = self.search_input.read(cx).value().to_string();
        if query.is_empty() {
            self.search_status.clear();
            self.search_highlights.clear();
            self.session.clear_selection();
            let _ = self.session.core_mut().update_frame();
            cx.notify();
            return;
        }
        self.search(&query, true, cx);
    }

    /// 上/下一个匹配（Enter、Shift+Enter 与箭头按钮共用）。
    fn search_step(&mut self, forward: bool, cx: &mut Context<Self>) {
        let query = self.search_input.read(cx).value().to_string();
        if query.is_empty() {
            return;
        }
        self.search(&query, forward, cx);
    }

    fn search(&mut self, query: &str, forward: bool, cx: &mut Context<Self>) {
        match self.session.search(query, forward) {
            Ok(outcome) => {
                self.search_status = search_status_text(outcome.index, outcome.total);
                let rows = self.frame().size().rows;
                self.search_highlights = match self.session.core_mut().search_highlights(rows) {
                    Ok(ranges) => ranges,
                    Err(error) => {
                        log::warn!(target: "terminal", "搜索高亮失败：{error}");
                        Vec::new()
                    }
                };
                let _ = self.session.core_mut().update_frame();
            }
            Err(error) => {
                self.search_status = format!("搜索失败：{error}");
                self.search_highlights.clear();
            }
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
            let muted = Hsla { a: 0.18, ..color };
            div()
                .flex()
                .flex_row()
                .items_center()
                .gap(px(4.0))
                .px(px(6.0))
                .py(px(3.0))
                .border_b_1()
                .border_color(muted)
                .child(
                    div()
                        .flex_1()
                        .child(Input::new(&self.search_input).w_full()),
                )
                .child(search_nav_button(
                    "terminal-search-prev",
                    gpui_kit::assets::IconName::ChevronLeft,
                    color,
                    cx.listener(|this, _, _, cx| this.search_step(false, cx)),
                ))
                .child(search_nav_button(
                    "terminal-search-next",
                    gpui_kit::assets::IconName::ChevronRight,
                    color,
                    cx.listener(|this, _, _, cx| this.search_step(true, cx)),
                ))
                .child(
                    div()
                        .min_w(px(36.0))
                        .text_size(px(10.0))
                        .text_color(color)
                        .child(self.search_status.clone()),
                )
        });
        let bell_bar = self.bell_pending.then(|| {
            div()
                .px(px(8.0))
                .py(px(4.0))
                .text_size(px(11.0))
                .text_color(self.style.foreground)
                .child("终端响铃 · 按任意键清除")
        });
        let paste_bar = self.pending_paste.as_ref().map(|_| {
            div()
                .px(px(8.0))
                .py(px(4.0))
                .text_size(px(11.0))
                .text_color(self.style.foreground)
                .child("粘贴内容含换行，可能立即执行命令 · 再按一次 Cmd+V 确认")
        });
        let ime_bar = self.ime_marked.as_ref().map(|text| {
            div()
                .px(px(8.0))
                .py(px(4.0))
                .text_size(px(11.0))
                .text_color(self.style.foreground)
                .child(format!("预编辑：{text}"))
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
                                this.scroll_to_offset((ratio * max) as usize, cx);
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
            .on_key_down(cx.listener(|this, event: &KeyDownEvent, window, cx| {
                this.handle_key(event, window, cx)
            }))
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
                    // Cmd+单击优先打开链接（OSC 8，或输出里的 URL/路径）。
                    if event.modifiers.platform && this.open_link_at(event.position, cx) {
                        cx.stop_propagation();
                        return;
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
            .on_mouse_down(
                MouseButton::Right,
                cx.listener(|this, event: &MouseDownEvent, _, cx| {
                    if this.forward_mouse(
                        TermMouseAction::Press,
                        Some(TermMouseButton::Right),
                        &event.modifiers,
                        event.position,
                        cx,
                    ) {
                        cx.stop_propagation();
                    }
                }),
            )
            .on_mouse_up(
                MouseButton::Right,
                cx.listener(|this, event: &MouseUpEvent, _, cx| {
                    if this.forward_mouse(
                        TermMouseAction::Release,
                        Some(TermMouseButton::Right),
                        &event.modifiers,
                        event.position,
                        cx,
                    ) {
                        cx.stop_propagation();
                    }
                }),
            )
            .on_mouse_down(
                MouseButton::Middle,
                cx.listener(|this, event: &MouseDownEvent, _, cx| {
                    if this.forward_mouse(
                        TermMouseAction::Press,
                        Some(TermMouseButton::Middle),
                        &event.modifiers,
                        event.position,
                        cx,
                    ) {
                        cx.stop_propagation();
                    }
                }),
            )
            .on_mouse_up(
                MouseButton::Middle,
                cx.listener(|this, event: &MouseUpEvent, _, cx| {
                    if this.forward_mouse(
                        TermMouseAction::Release,
                        Some(TermMouseButton::Middle),
                        &event.modifiers,
                        event.position,
                        cx,
                    ) {
                        cx.stop_propagation();
                    }
                }),
            )
            .children(search_bar)
            .children(bell_bar)
            .children(paste_bar)
            .children(ime_bar)
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
            build_plan(
                view.frame(),
                &self.style,
                self.cell_width,
                bounds,
                &view.search_highlights,
            )
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
                // `ShapedLine::paint` 把 origin 当作**行顶**，内部自己加
                // `padding_top + ascent` 算基线。这里再补一次半行与 ascent，
                // 整行文字会被推下约半个行高，而光标块留在行顶 —— 表现就是
                // “光标位置偏上”。origin 只给行顶，垂直居中交给 paint。
                let origin = Point {
                    x: plan.origin.x,
                    y: row.y,
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
    highlights: &[(u16, u16, u16)],
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

    let mut highlight_cursor = 0usize;
    for (row_index, row) in frame.rows().iter().enumerate() {
        let row_index_u16 = row_index as u16;
        while highlight_cursor < highlights.len() && highlights[highlight_cursor].0 < row_index_u16
        {
            highlight_cursor += 1;
        }
        let row_start = highlight_cursor;
        let mut row_end = row_start;
        while row_end < highlights.len() && highlights[row_end].0 == row_index_u16 {
            row_end += 1;
        }
        // 本行的匹配区间：后续每格只在这一小段里查找。
        let row_highlights = &highlights[row_start..row_end];
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
            // 搜索匹配先铺底，选区和光标会依次覆盖。
            if is_highlighted(row_highlights, column as u16) {
                bg = Some(style.match_highlight);
            }
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

    fn marked_text_range(&mut self, _window: &mut Window, cx: &mut App) -> Option<Range<usize>> {
        self.view
            .read(cx)
            .ime_marked
            .as_ref()
            .map(|text| 0..text.encode_utf16().count())
    }

    fn text_for_range(
        &mut self,
        _range_utf16: Range<usize>,
        _adjusted_range: &mut Option<Range<usize>>,
        _window: &mut Window,
        cx: &mut App,
    ) -> Option<String> {
        Some(self.view.read(cx).ime_marked.clone().unwrap_or_default())
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
        new_text: &str,
        _new_selected_range: Option<Range<usize>>,
        _window: &mut Window,
        cx: &mut App,
    ) {
        let text = new_text.to_string();
        self.view
            .update(cx, |view, cx| view.set_ime_marked(text, cx));
    }

    fn unmark_text(&mut self, _window: &mut Window, cx: &mut App) {
        self.view
            .update(cx, |view, cx| view.set_ime_marked(String::new(), cx));
    }

    /// 组合型输入法（中文等）激活时，字母先给 IME 组合；ABC 等直排布局
    /// 由平台侧 `is_ime_input_source_active` 过滤，英文输入不受影响。
    fn prefers_ime_for_printable_keys(&mut self, _window: &mut Window, _cx: &mut App) -> bool {
        true
    }

    fn bounds_for_range(
        &mut self,
        _range_utf16: Range<usize>,
        _window: &mut Window,
        cx: &mut App,
    ) -> Option<Bounds<Pixels>> {
        self.view.read(cx).cursor_bounds()
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

/// 光标格在窗口中的矩形（IME 候选窗定位用）。
fn cursor_rect(
    origin: Point<Pixels>,
    cursor: (u16, u16),
    cell_width: Pixels,
    line_height: Pixels,
    padding: Pixels,
) -> Bounds<Pixels> {
    Bounds::new(
        Point {
            x: origin.x + padding + cell_width * cursor.0 as f32,
            y: origin.y + padding + line_height * cursor.1 as f32,
        },
        Size {
            width: cell_width,
            height: line_height,
        },
    )
}

/// 搜索状态文案：`3/7`；没有匹配时 `无匹配`。
fn search_status_text(index: Option<usize>, total: usize) -> String {
    if total == 0 {
        return "无匹配".to_string();
    }
    match index {
        Some(index) => format!("{}/{}", index + 1, total),
        None => format!("-/{total}"),
    }
}

/// 搜索条上的上一个/下一个按钮（Zed 用 ChevronLeft/Right 的图标按钮）。
fn search_nav_button(
    id: &'static str,
    icon: gpui_kit::assets::IconName,
    color: Hsla,
    on_click: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static,
) -> AnyElement {
    div()
        .id(id)
        .flex()
        .items_center()
        .justify_center()
        .w(px(18.0))
        .h(px(18.0))
        .rounded(px(3.0))
        .cursor_pointer()
        .hover(|style| style.bg(Hsla { a: 0.08, ..color }))
        .child(
            svg()
                .path(icon.path())
                .w(px(12.0))
                .h(px(12.0))
                .text_color(color),
        )
        .on_click(on_click)
        .into_any_element()
}

/// 这次按键是否算「用户已经看到响铃」——纯修饰键不清除。
fn clears_bell(key: &str) -> bool {
    !matches!(
        key,
        "shift" | "control" | "alt" | "platform" | "function" | "capslock"
    )
}

/// alternate screen 里滚轮对应的方向键与次数。
///
/// 单次事件最多发 10 个按键，避免一次大幅滚动灌进过多输入。
fn alternate_scroll_key(lines: isize) -> Option<(Key, usize)> {
    match lines.cmp(&0) {
        std::cmp::Ordering::Less => Some((Key::ArrowUp, lines.unsigned_abs().min(10))),
        std::cmp::Ordering::Greater => Some((Key::ArrowDown, lines.unsigned_abs().min(10))),
        std::cmp::Ordering::Equal => None,
    }
}

/// 只放行 http(s) 链接：OSC 8 的 URI 与可见文本无关，其它 scheme 可以拉起
/// 本地应用或网络挂载，与 `agent_ui::safe_markdown` 的链接策略保持一致。
fn is_safe_link(target: &str) -> bool {
    let lower = target.trim().to_ascii_lowercase();
    lower.starts_with("https://") || lower.starts_with("http://")
}

/// 是否需要重算搜索高亮：搜索条打开且查询非空。
fn needs_highlight_refresh(search_open: bool, query: &str) -> bool {
    search_open && !query.is_empty()
}

/// 某一行的 `column` 是否落在本行任一匹配区间内（列含两端）。
fn is_highlighted(row_ranges: &[(u16, u16, u16)], column: u16) -> bool {
    row_ranges
        .iter()
        .any(|&(_, start, end)| column >= start && column <= end)
}

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

#[cfg(test)]
mod tests {
    // 只做显式导入：父模块的 `use gpui_kit::*` 会引入 gpui 的 test 宏，
    // 遮蔽 std 的 `#[test]` 并触发递归展开。
    use super::{
        alternate_scroll_key, clears_bell, cursor_rect, is_highlighted, is_safe_link,
        needs_highlight_refresh, search_status_text, thumb_geometry,
    };
    use cgc_terminal::Key;
    use gpui_kit::{px, Point};

    #[test]
    fn ime_candidate_bounds_follow_the_cursor() {
        let rect = cursor_rect(
            Point {
                x: px(100.0),
                y: px(50.0),
            },
            (3, 2),
            px(8.0),
            px(18.0),
            px(8.0),
        );
        assert_eq!(f32::from(rect.origin.x), 132.0, "padding + 3 列");
        assert_eq!(f32::from(rect.origin.y), 94.0, "padding + 2 行");
        assert_eq!(f32::from(rect.size.width), 8.0);
        assert_eq!(f32::from(rect.size.height), 18.0);
    }

    #[test]
    fn links_are_limited_to_http_schemes() {
        assert!(is_safe_link("https://example.com"));
        assert!(is_safe_link("HTTP://EXAMPLE.COM"));
        assert!(!is_safe_link("file:///etc/passwd"));
        assert!(!is_safe_link("smb://attacker/share"));
        assert!(!is_safe_link("javascript:alert(1)"));
        assert!(!is_safe_link(""));
    }

    #[test]
    fn highlight_refresh_only_while_searching() {
        assert!(needs_highlight_refresh(true, "foo"));
        assert!(!needs_highlight_refresh(true, ""));
        assert!(!needs_highlight_refresh(false, "foo"));
        assert!(!needs_highlight_refresh(false, ""));
    }

    #[test]
    fn highlights_cover_inclusive_columns() {
        let row = [(0u16, 2u16, 5u16)];
        assert!(is_highlighted(&row, 2), "起始列包含");
        assert!(is_highlighted(&row, 5), "结束列包含");
        assert!(!is_highlighted(&row, 6));

        let full_row = [(3u16, 0u16, u16::MAX)];
        assert!(is_highlighted(&full_row, 9999), "整行高亮");
        assert!(!is_highlighted(&[], 0));
    }

    #[test]
    fn alternate_scroll_maps_wheel_to_arrows() {
        assert_eq!(alternate_scroll_key(-3), Some((Key::ArrowUp, 3)));
        assert_eq!(alternate_scroll_key(5), Some((Key::ArrowDown, 5)));
        assert_eq!(alternate_scroll_key(0), None);
        assert_eq!(
            alternate_scroll_key(-100),
            Some((Key::ArrowUp, 10)),
            "单次事件最多 10 个按键"
        );
    }

    #[test]
    fn search_status_reports_position_and_total() {
        assert_eq!(search_status_text(Some(0), 7), "1/7");
        assert_eq!(search_status_text(Some(6), 7), "7/7");
        assert_eq!(search_status_text(None, 7), "-/7");
        assert_eq!(search_status_text(None, 0), "无匹配");
    }

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
    fn only_real_keys_clear_the_bell() {
        assert!(clears_bell("a"));
        assert!(clears_bell("escape"));
        assert!(clears_bell("enter"));
        assert!(!clears_bell("shift"));
        assert!(!clears_bell("control"));
        assert!(!clears_bell("alt"));
        assert!(!clears_bell("platform"));
    }
}
