//! 托管命令的共同执行边界：环境白名单、超时和并行排空输出。

use std::collections::VecDeque;
use std::io;
use std::process::{Command, Stdio};
use std::task::Poll;
use std::time::{Duration, Instant};

use super::launch::LaunchPlan;

pub(crate) fn run_output(plan: &LaunchPlan, timeout: Duration) -> Result<String, String> {
    let mut command = Command::new(&plan.program);
    command
        .args(&plan.args)
        .current_dir(&plan.cwd)
        .env_clear()
        .envs(&plan.env)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    configure_process_group(&mut command);
    #[cfg(unix)]
    let mut child = async_process::Command::from(command)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .map_err(|error| error.to_string())?;
    #[cfg(windows)]
    let mut child = command.spawn().map_err(|error| error.to_string())?;
    let mut stdout = child.stdout.take().expect("piped stdout");
    let mut stderr = child.stderr.take().expect("piped stderr");
    let mut output = VecDeque::new();
    let mut errors = VecDeque::new();
    let mut stdout_done = false;
    let mut stderr_done = false;
    let mut group_terminated = false;
    let mut buffer = [0; 8192];
    let started = Instant::now();
    let result = (|| {
        let mut status = None;
        loop {
            if status.is_none() {
                #[cfg(unix)]
                let current = child.try_status();
                #[cfg(windows)]
                let current = child.try_wait();
                status = current.map_err(|error| error.to_string())?;
                if status.is_some() {
                    terminate_process_group(child.id());
                    group_terminated = true;
                }
            }
            let mut progressed = false;
            if !stdout_done {
                progressed |= retain_output(
                    poll_pipe(&mut stdout, &mut buffer),
                    &buffer,
                    &mut output,
                    &mut stdout_done,
                )?;
            }
            if !stderr_done {
                progressed |= retain_output(
                    poll_pipe(&mut stderr, &mut buffer),
                    &buffer,
                    &mut errors,
                    &mut stderr_done,
                )?;
            }
            if stdout_done && stderr_done {
                if let Some(status) = status {
                    break Ok(status);
                }
            }
            let remaining = timeout.saturating_sub(started.elapsed());
            if remaining.is_zero() {
                break Err("command timed out".to_string());
            }
            if !progressed {
                std::thread::sleep(Duration::from_millis(20).min(remaining));
            }
        }
    })();
    if !group_terminated {
        terminate_process_group(child.id());
    }
    if result.is_err() {
        let _ = child.kill();
    }
    let status = result?;
    let stdout = String::from_utf8_lossy(output.make_contiguous());
    let stderr = String::from_utf8_lossy(errors.make_contiguous());
    let mut combined = String::with_capacity(stdout.len() + stderr.len());
    if status.success() {
        combined.push_str(&stdout);
        combined.push_str(&stderr);
        Ok(combined)
    } else {
        combined.push_str(&stderr);
        combined.push_str(&stdout);
        Err(combined)
    }
}

fn retain_output(
    read: Poll<io::Result<usize>>,
    buffer: &[u8],
    output: &mut VecDeque<u8>,
    done: &mut bool,
) -> Result<bool, String> {
    const LIMIT: usize = 64 * 1024;
    match read {
        Poll::Pending => Ok(false),
        Poll::Ready(Ok(0)) => {
            *done = true;
            Ok(false)
        }
        Poll::Ready(Ok(count)) => {
            let overflow = (output.len() + count).saturating_sub(LIMIT);
            output.drain(..overflow);
            output.extend(&buffer[..count]);
            Ok(true)
        }
        Poll::Ready(Err(error)) => Err(error.to_string()),
    }
}

#[cfg(unix)]
fn poll_pipe(
    reader: &mut (impl futures::io::AsyncRead + Unpin),
    buffer: &mut [u8],
) -> Poll<io::Result<usize>> {
    let mut context = std::task::Context::from_waker(std::task::Waker::noop());
    std::pin::Pin::new(reader).poll_read(&mut context, buffer)
}

#[cfg(windows)]
fn poll_pipe(
    reader: &mut (impl io::Read + std::os::windows::io::AsRawHandle),
    buffer: &mut [u8],
) -> Poll<io::Result<usize>> {
    use windows::Win32::Foundation::{ERROR_BROKEN_PIPE, ERROR_PIPE_NOT_CONNECTED, HANDLE};
    use windows::Win32::System::Pipes::PeekNamedPipe;

    let mut available = 0;
    // This is the sole reader; only read bytes already buffered in the pipe.
    // async-process uses blocking reader threads on Windows, which cannot be
    // cancelled while a detached descendant retains the write handle.
    let result = unsafe {
        PeekNamedPipe(
            HANDLE(reader.as_raw_handle()),
            None,
            0,
            None,
            Some(&mut available),
            None,
        )
    };
    match result {
        Ok(()) if available == 0 => Poll::Pending,
        Ok(()) => {
            let count = buffer.len().min(available as usize);
            Poll::Ready(reader.read(&mut buffer[..count]))
        }
        Err(error)
            if error.code() == ERROR_BROKEN_PIPE.to_hresult()
                || error.code() == ERROR_PIPE_NOT_CONNECTED.to_hresult() =>
        {
            Poll::Ready(Ok(0))
        }
        Err(error) => Poll::Ready(Err(io::Error::other(error))),
    }
}

pub(crate) fn configure_process_group(command: &mut Command) {
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt as _;
        command.process_group(0);
    }
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt as _;
        const CREATE_NO_WINDOW: u32 = 0x08000000;
        command.creation_flags(CREATE_NO_WINDOW);
    }
}

pub(crate) fn terminate_process_group(pid: u32) {
    #[cfg(unix)]
    let mut command = {
        let mut command = Command::new("/bin/kill");
        command.args(["-KILL", &format!("-{pid}")]);
        command
    };
    #[cfg(windows)]
    let mut command = {
        let mut command = Command::new("taskkill");
        command.args(["/PID", &pid.to_string(), "/T", "/F"]);
        command
    };
    #[cfg(any(unix, windows))]
    let _ = command
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
}
