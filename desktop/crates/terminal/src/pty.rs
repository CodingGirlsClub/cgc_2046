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
}

impl Session {
    /// 用用户默认 shell 开一个交互会话。
    pub fn spawn_default(size: GridSize) -> Result<Self> {
        Self::spawn_command(CommandBuilder::new_default_prog(), size)
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

        let (tx, output) = mpsc::channel();
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
        })
    }

    /// 排空已到达的输出并喂给 VT 解析器，再检查子进程是否退出。
    ///
    /// 非阻塞；UI 每帧调用一次即可。
    pub fn poll(&mut self) -> Result<PollResult> {
        let mut fed_bytes = 0;
        if !self.output_closed {
            loop {
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

    /// 搜索（含 scrollback）。
    pub fn search(&mut self, needle: &str, forward: bool) -> Result<crate::SearchOutcome> {
        self.core.search(needle, forward)
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

fn pump(mut reader: Box<dyn Read + Send>, tx: mpsc::Sender<Vec<u8>>) {
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
}
