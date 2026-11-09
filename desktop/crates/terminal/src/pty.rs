//! PTY 会话：子进程 + 读线程 + 字节通道。
//!
//! [`TerminalCore`] 是 `!Send`（libghostty-vt 的 C API 不承诺线程安全），所以它永远
//! 留在创建会话的线程（桌面端是 GPUI 主线程）。读线程只把 PTY 字节搬进 channel；
//! [`Session::poll`] 在 owner 线程把字节喂给 VT 解析器，不跨线程共享终端状态。

use std::io::{ErrorKind, Read, Write};
use std::sync::mpsc::{self, Receiver, TryRecvError};
use std::thread;

use portable_pty::{native_pty_system, Child, CommandBuilder, MasterPty, PtySize};

use crate::{GridSize, Result, TerminalCore};

/// 单次 [`Session::poll`] 最多喂给 VT 解析器的字节数。
const MAX_BYTES_PER_POLL: usize = 2 * 1024 * 1024;

/// PTY 输出队列的容量（块数，每块 ≤ 8 KiB）。填满后读线程阻塞，形成背压。
const OUTPUT_QUEUE_CHUNKS: usize = 64;

/// 单次 [`Session::poll`] 最多写回的终端响应字节数。
const MAX_RESPONSE_BYTES: usize = 64 * 1024;

/// 写回失败时待写队列的上限；超过就丢弃，避免无界增长。
const MAX_PENDING_RESPONSE_BYTES: usize = 1024 * 1024;

/// 用户默认 shell 的命令行；`cwd` 为 `Some` 时在该目录启动。
fn default_command(cwd: Option<&std::path::Path>) -> CommandBuilder {
    let mut cmd = CommandBuilder::new_default_prog();
    if let Some(dir) = cwd {
        cmd.cwd(dir);
    }
    cmd
}

/// 子进程退出信息（不把 portable-pty 的类型泄漏出去）。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ExitInfo {
    pub success: bool,
    pub code: u32,
}

/// 一次 [`Session::poll`] 的结果。
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct PollResult {
    /// 本次喂给 VT 解析器的字节数。
    pub fed_bytes: usize,
    /// PTY 输出端已关闭（子进程退出或主动关闭了 stdout）。
    pub output_closed: bool,
    /// 子进程退出信息；未退出时为 `None`。每次 poll 都返回当前已知状态。
    pub exit: Option<ExitInfo>,
}

/// 一个交互终端会话。
pub struct Session {
    core: TerminalCore,
    master: Box<dyn MasterPty + Send>,
    writer: Box<dyn Write + Send>,
    output: Receiver<Vec<u8>>,
    child: Box<dyn Child + Send + Sync>,
    output_closed: bool,
    exit: Option<ExitInfo>,
    /// 终端生成但尚未写回 PTY 的响应（写不完时分帧续写）。
    pending_responses: Vec<u8>,
}

impl Session {
    /// 用用户默认 shell 开一个交互会话。
    pub fn spawn_default(size: GridSize) -> Result<Self> {
        Self::spawn_default_in(size, None)
    }

    /// 用用户默认 shell 开一个会话，`cwd` 为 `Some` 时在该目录启动。
    pub fn spawn_default_in(size: GridSize, cwd: Option<&std::path::Path>) -> Result<Self> {
        Self::spawn_command(default_command(cwd), size)
    }

    /// 用给定命令开一个会话（「在终端运行任务」与测试用）。
    pub fn spawn_command(mut cmd: CommandBuilder, size: GridSize) -> Result<Self> {
        configure_env(&mut cmd);

        let pty_system = native_pty_system();
        let pair = pty_system.openpty(to_pty_size(size))?;
        let child = pair.slave.spawn_command(cmd)?;
        // slave 端必须在这里关掉：否则子进程退出后，读线程等不到 EOF。
        drop(pair.slave);

        let reader = pair.master.try_clone_reader()?;
        let writer = pair.master.take_writer()?;
        let core = TerminalCore::new(size)?;

        // 有界队列做背压：64 × 8 KiB = 512 KiB 上限。UI 每帧最多排 2 MiB，
        // 但读线程不能无限堆积（`yes` 类输出会把内存撑爆）；塞满后读线程阻塞，
        // 反压到 PTY 缓冲，子进程的 write 随之阻塞。
        let (tx, output) = mpsc::sync_channel(OUTPUT_QUEUE_CHUNKS);
        thread::Builder::new()
            .name("cgc-terminal-pty".to_string())
            .spawn(move || pump(reader, tx))?;

        Ok(Self {
            core,
            master: pair.master,
            writer,
            output,
            child,
            output_closed: false,
            exit: None,
            pending_responses: Vec::new(),
        })
    }

    /// 排空已到达的输出并喂给 VT 解析器，再检查子进程是否退出。
    ///
    /// 非阻塞；UI 每帧调用一次即可。
    pub fn poll(&mut self) -> Result<PollResult> {
        let mut fed_bytes = 0;
        if !self.output_closed {
            // 单次最多解析 2 MiB：进程狂输出（`yes`、大文件 cat）时保证一帧
            // 的解析时间可控，剩余数据留在 channel 里下一帧继续。
            while fed_bytes < MAX_BYTES_PER_POLL {
                match self.output.try_recv() {
                    Ok(chunk) => {
                        fed_bytes += chunk.len();
                        self.core.feed(&chunk);
                    }
                    Err(TryRecvError::Empty) => break,
                    Err(TryRecvError::Disconnected) => {
                        self.output_closed = true;
                        break;
                    }
                }
            }
        }

        // 把终端对查询的答复（OSC 11 颜色、DA、DSR）写回子进程；不接这条，
        // TUI 判断不出终端明暗（典型：OMP 用深色 UI）。每帧限量写，
        // 写不完的留在 pending 里下一帧继续，避免超长响应被截断丢弃。
        self.pending_responses
            .extend_from_slice(&self.core.take_responses());
        if !self.pending_responses.is_empty() {
            let chunk = drain_response_chunk(&mut self.pending_responses, MAX_RESPONSE_BYTES);
            if self.write(&chunk).is_err() {
                // PTY 已关闭时写不进去：回填保留，但设上限防止无界增长。
                self.pending_responses.splice(0..0, chunk);
                if self.pending_responses.len() > MAX_PENDING_RESPONSE_BYTES {
                    self.pending_responses.clear();
                }
            }
        }

        if self.exit.is_none() {
            if let Some(status) = self.child.try_wait()? {
                self.exit = Some(ExitInfo {
                    success: status.success(),
                    code: status.exit_code(),
                });
            }
        }

        Ok(PollResult {
            fed_bytes,
            output_closed: self.output_closed,
            exit: self.exit,
        })
    }

    /// 把键盘/粘贴字节写给子进程。
    pub fn write(&mut self, bytes: &[u8]) -> Result<()> {
        self.writer.write_all(bytes)?;
        self.writer.flush()?;
        Ok(())
    }

    /// 同步调整 PTY 与 VT 网格（子进程会收到 SIGWINCH）。
    pub fn resize(&mut self, size: GridSize) -> Result<()> {
        self.master.resize(to_pty_size(size))?;
        self.core.resize(size, 0, 0)?;
        Ok(())
    }

    /// 在 scrollback 中滚动（滚轮）。
    pub fn scroll(&mut self, delta: isize) {
        self.core.scroll(delta);
    }

    /// 当前滚动条状态。
    pub fn scrollbar(&self) -> Result<libghostty_vt::terminal::Scrollbar> {
        self.core.scrollbar()
    }

    /// 跳转到 scrollback 的绝对行偏移。
    pub fn scroll_to(&mut self, offset: usize) {
        self.core.scroll_to(offset);
    }

    pub fn set_selection(&mut self, start: (u16, u16), end: (u16, u16)) -> Result<()> {
        self.core.set_selection(start, end)
    }

    pub fn clear_selection(&mut self) {
        self.core.clear_selection();
    }

    pub fn select_word(&mut self, cell: (u16, u16)) -> Result<()> {
        self.core.select_word(cell)
    }

    pub fn select_line(&mut self, cell: (u16, u16)) -> Result<()> {
        self.core.select_line(cell)
    }

    pub fn selection_text(&self) -> Result<Option<String>> {
        self.core.selection_text()
    }

    /// 搜索(含 scrollback)。
    pub fn search(&mut self, needle: &str, forward: bool) -> Result<crate::SearchOutcome> {
        self.core.search(needle, forward)
    }

    /// 按终端当前模式粘贴文本；返回 `false` 表示需要用户确认。
    pub fn paste(&mut self, text: &str, allow_unsafe: bool) -> Result<bool> {
        let Some(bytes) = self.core.encode_paste(text, allow_unsafe)? else {
            return Ok(false);
        };
        if bytes.is_empty() {
            return Ok(true);
        }
        self.write(&bytes)?;
        Ok(true)
    }

    /// 应用主题配色(见 [`crate::TerminalCore::set_theme`])。
    pub fn set_theme(&mut self, theme: &crate::TerminalTheme) -> Result<()> {
        self.core.set_theme(theme)
    }

    pub fn core(&self) -> &TerminalCore {
        &self.core
    }

    pub fn core_mut(&mut self) -> &mut TerminalCore {
        &mut self.core
    }

    /// 当前视口文本，见 [`TerminalCore::viewport_text`]。
    pub fn screen_text(&mut self) -> Result<Vec<String>> {
        self.core.viewport_text()
    }

    pub fn exit(&self) -> Option<ExitInfo> {
        self.exit
    }

    /// 还活着：输出端未关闭且未观察到退出。
    pub fn is_running(&self) -> bool {
        !self.output_closed && self.exit.is_none()
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        if self.exit.is_none() {
            let _ = self.child.kill();
            let _ = self.child.try_wait();
        }
    }
}

/// 从待写队列取出最多 `max` 字节（FIFO），供 [`Session::poll`] 分帧写回。
fn drain_response_chunk(pending: &mut Vec<u8>, max: usize) -> Vec<u8> {
    let take = pending.len().min(max);
    pending.drain(..take).collect()
}

fn pump(mut reader: Box<dyn Read + Send>, tx: mpsc::SyncSender<Vec<u8>>) {
    let mut buf = [0u8; 8192];
    loop {
        match reader.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => {
                if tx.send(buf[..n].to_vec()).is_err() {
                    break;
                }
            }
            Err(error) if error.kind() == ErrorKind::Interrupted => continue,
            Err(_) => break,
        }
    }
}

fn configure_env(cmd: &mut CommandBuilder) {
    cmd.env("TERM", "xterm-256color");
    cmd.env("COLORTERM", "truecolor");
    cmd.env("TERM_PROGRAM", "cgc-desktop");
}

fn to_pty_size(size: GridSize) -> PtySize {
    PtySize {
        rows: size.rows,
        cols: size.cols,
        pixel_width: 0,
        pixel_height: 0,
    }
}

#[cfg(test)]
mod tests {
    use std::time::{Duration, Instant};

    use super::*;

    fn grid(cols: u16, rows: u16) -> GridSize {
        GridSize { cols, rows }
    }

    /// 轮询直到屏幕出现 `needle` 或超时；返回最后一次屏幕文本。
    fn wait_for(session: &mut Session, needle: &str, timeout: Duration) -> String {
        let deadline = Instant::now() + timeout;
        let mut text = String::new();
        while Instant::now() < deadline {
            session.poll().expect("poll");
            text = session.screen_text().expect("screen").join("\n");
            if text.contains(needle) {
                return text;
            }
            thread::sleep(Duration::from_millis(10));
        }
        text
    }

    fn wait_exit(session: &mut Session, timeout: Duration) -> Option<ExitInfo> {
        let deadline = Instant::now() + timeout;
        while Instant::now() < deadline {
            if let Some(exit) = session.poll().expect("poll").exit {
                return Some(exit);
            }
            thread::sleep(Duration::from_millis(10));
        }
        None
    }

    #[cfg(unix)]
    #[test]
    fn captures_output_and_exit_code() {
        let mut cmd = CommandBuilder::new("/bin/sh");
        cmd.args(["-c", "printf 'hello-pty\\n'; exit 3"]);
        let mut session = Session::spawn_command(cmd, grid(40, 6)).expect("spawn");

        let text = wait_for(&mut session, "hello-pty", Duration::from_secs(5));
        assert!(text.contains("hello-pty"), "screen: {text:?}");

        let exit = wait_exit(&mut session, Duration::from_secs(5)).expect("child did not exit");
        assert_eq!(exit.code, 3);
        assert!(!exit.success);
        assert!(!session.is_running());
    }

    #[cfg(unix)]
    #[test]
    fn answers_osc11_query_from_the_child() {
        let mut cmd = CommandBuilder::new("/bin/sh");
        // 延迟查询，给测试先注入主题；先切 raw（否则 canonical 模式等换行，
        // OSC 11 响应没有换行会被卡住），dd 读回响应，od 转十六进制。
        cmd.args([
            "-c",
            "sleep 0.2; stty raw -echo; printf '\\033]11;?\\007'; dd bs=1 count=24 2>/dev/null | od -An -tx1 | tr -d ' \\r\\n'",
        ]);
        let mut session = Session::spawn_command(cmd, grid(60, 6)).expect("spawn");
        session
            .set_theme(&crate::TerminalTheme {
                foreground: crate::FrameColor {
                    r: 0x5C,
                    g: 0x61,
                    b: 0x66,
                },
                background: crate::FrameColor {
                    r: 0xFC,
                    g: 0xFC,
                    b: 0xFC,
                },
                cursor: crate::FrameColor {
                    r: 0xFF,
                    g: 0x99,
                    b: 0x40,
                },
                ansi: [crate::FrameColor { r: 0, g: 0, b: 0 }; 16],
            })
            .expect("theme");

        // `fcfc` 的十六进制是 66636663；终端必须把 OSC 11 响应写回子进程。
        let text = wait_for(&mut session, "66636663", Duration::from_secs(5));
        assert!(text.contains("66636663"), "screen: {text:?}");
    }

    #[cfg(unix)]
    #[test]
    fn ctrl_c_interrupts_the_foreground_process() {
        let mut cmd = CommandBuilder::new("/bin/sh");
        cmd.args(["-c", "sleep 30"]);
        let mut session = Session::spawn_command(cmd, grid(40, 6)).expect("spawn");
        thread::sleep(Duration::from_millis(300));
        session.write(b"\x03").expect("write");

        let exit = wait_exit(&mut session, Duration::from_secs(3));
        assert!(exit.is_some(), "Ctrl+C 应终止前台进程（SIGINT 未送达？）");
    }

    #[cfg(unix)]
    #[test]
    fn writes_reach_the_child() {
        let mut cmd = CommandBuilder::new("/bin/sh");
        cmd.args(["-c", "read line; printf 'got:%s\\n' \"$line\""]);
        let mut session = Session::spawn_command(cmd, grid(40, 6)).expect("spawn");

        // 给 shell 一点时间进入 read，避免字节丢在启动前。
        thread::sleep(Duration::from_millis(150));
        session.write(b"ping\n").expect("write");

        let text = wait_for(&mut session, "got:ping", Duration::from_secs(5));
        assert!(text.contains("got:ping"), "screen: {text:?}");
    }

    #[cfg(unix)]
    #[test]
    fn resize_propagates_to_the_child() {
        // stty 读取的是 PTY 内核窗口尺寸，能直接证明 resize 到了子进程。
        let mut cmd = CommandBuilder::new("/bin/sh");
        cmd.args(["-c", "read _; stty size"]);
        let mut session = Session::spawn_command(cmd, grid(40, 6)).expect("spawn");

        session.resize(grid(20, 4)).expect("resize");
        thread::sleep(Duration::from_millis(150));
        session.write(b"\n").expect("write");

        let text = wait_for(&mut session, "4 20", Duration::from_secs(5));
        assert!(text.contains("4 20"), "screen: {text:?}");
    }

    #[cfg(windows)]
    #[test]
    fn captures_output_windows() {
        let mut cmd = CommandBuilder::new("cmd.exe");
        cmd.args(["/C", "echo hello-pty"]);
        let mut session = Session::spawn_command(cmd, grid(40, 6)).expect("spawn");

        let text = wait_for(&mut session, "hello-pty", Duration::from_secs(10));
        assert!(text.contains("hello-pty"), "screen: {text:?}");
    }

    #[cfg(unix)]
    #[test]
    fn spawn_in_directory_starts_there() {
        let dir = std::env::temp_dir().join(format!("cgc-cwd-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("temp dir");
        let expected = dir.canonicalize().unwrap_or_else(|_| dir.clone());

        // 配置层：默认 shell 的命令行带上了工作目录。
        let cmd = default_command(Some(&dir));
        assert_eq!(cmd.get_cwd(), Some(&dir.as_os_str().to_os_string()));

        // 端到端：用不读用户配置的 /bin/sh 验证 PTY 确实在目录内启动。
        let mut shell = CommandBuilder::new("/bin/sh");
        shell.args(["-c", "pwd"]);
        shell.cwd(&dir);
        let mut session = Session::spawn_command(shell, grid(60, 4)).expect("spawn");
        // 等进程退出（输出已全部读入），避免路径折行干扰文本等待。
        let exit = wait_exit(&mut session, Duration::from_secs(5)).expect("pwd 应退出");
        assert_eq!(exit.code, 0);
        let text = session.screen_text().expect("screen").join("\n");
        let _ = std::fs::remove_dir_all(&dir);
        // 路径可能被按列宽折行，把屏幕拉平后比较完整路径。
        let flat: String = text.chars().filter(|c| !c.is_whitespace()).collect();
        let expected = expected.display().to_string();
        let needle = expected
            .chars()
            .filter(|c| !c.is_whitespace())
            .collect::<String>();
        assert!(flat.contains(&needle), "screen: {text:?}，期望 {expected}");
    }

    #[test]
    fn response_writeback_drains_in_bounded_chunks() {
        let mut pending = vec![7u8; MAX_RESPONSE_BYTES * 2 + 10];
        let first = drain_response_chunk(&mut pending, MAX_RESPONSE_BYTES);
        assert_eq!(first.len(), MAX_RESPONSE_BYTES, "第一帧应写满上限");
        let second = drain_response_chunk(&mut pending, MAX_RESPONSE_BYTES);
        assert_eq!(second.len(), MAX_RESPONSE_BYTES, "第二帧继续写满上限");
        let last = drain_response_chunk(&mut pending, MAX_RESPONSE_BYTES);
        assert_eq!(last.len(), 10, "第三帧只写剩余字节");
        assert!(pending.is_empty(), "队列应被完全排空");
        assert!(
            drain_response_chunk(&mut pending, MAX_RESPONSE_BYTES).is_empty(),
            "空队列不应产出数据"
        );
    }
}
