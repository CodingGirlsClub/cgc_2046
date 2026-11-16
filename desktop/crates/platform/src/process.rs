//! 子进程启动的平台差异。
//!
//! Windows GUI 子系统（`#![windows_subsystem = "windows"]`）的进程没有 console；
//! 未设 `CREATE_NO_WINDOW` 时，每个 console 子进程都会由系统分配一个新控制台，
//! 用户看到的就是闪一下的黑窗。所有 spawn 前统一调用 [`hide_console_window`]。

use std::process::Command;

/// `CREATE_NO_WINDOW`：新进程是控制台程序，但没有控制台窗口。
#[cfg(windows)]
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

/// 隐藏子进程的控制台窗口；非 Windows 平台无操作。
pub fn hide_console_window(command: &mut Command) {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt as _;
        command.creation_flags(CREATE_NO_WINDOW);
    }
    #[cfg(not(windows))]
    let _ = command;
}
