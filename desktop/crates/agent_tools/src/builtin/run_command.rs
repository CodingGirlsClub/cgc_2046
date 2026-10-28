use std::{
    io::Read,
    process::{Command, Stdio},
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

use futures::{channel::oneshot, future::BoxFuture};
#[cfg(unix)]
use std::os::unix::process::CommandExt as _;

use crate::{
    approval::Approval,
    error::ToolError,
    policy::{CommandDecision, CommandPolicy},
    sandbox::{CommandSandbox, SandboxPolicy},
    tool::{Tool, ToolContext, ToolResult},
};

const DEFAULT_TIMEOUT: Duration = Duration::from_secs(30);
const MAX_TIMEOUT: Duration = Duration::from_secs(120);
const MAX_OUTPUT_BYTES: usize = 32 * 1024;

/// 在工作区内执行一条 shell 命令；默认需要用户确认，危险命令直接拒绝。
#[derive(Default)]
pub struct RunCommandTool {
    policy: CommandPolicy,
}

impl RunCommandTool {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with_policy(policy: CommandPolicy) -> Self {
        Self { policy }
    }
}

impl Tool for RunCommandTool {
    fn name(&self) -> &'static str {
        "run_command"
    }

    fn description(&self) -> &'static str {
        "Run a shell command inside the workspace. Requires approval. Output is truncated."
    }

    fn schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "properties": {
                "command": { "type": "string", "description": "Shell command to run" },
                "cwd": { "type": "string", "description": "Workspace-relative working directory; defaults to ." },
                "timeout_secs": { "type": "integer", "minimum": 1, "maximum": 120 }
            },
            "required": ["command"]
        })
    }

    fn approval(&self, args: &serde_json::Value) -> Approval {
        let Some(command) = args.get("command").and_then(|value| value.as_str()) else {
            return Approval::Ask;
        };
        match self.policy.classify(command) {
            CommandDecision::Deny(reason) => Approval::Deny(reason),
            CommandDecision::Ask => Approval::Ask,
        }
    }

    fn run(
        &self,
        args: serde_json::Value,
        context: ToolContext,
    ) -> BoxFuture<'static, Result<ToolResult, ToolError>> {
        let command = args.get("command").and_then(|value| value.as_str());
        let cwd = args
            .get("cwd")
            .and_then(|value| value.as_str())
            .unwrap_or(".")
            .to_string();
        let timeout = args
            .get("timeout_secs")
            .and_then(|value| value.as_u64())
            .map(Duration::from_secs)
            .unwrap_or(DEFAULT_TIMEOUT)
            .min(MAX_TIMEOUT);
        let Some(command) = command.map(|value| value.to_string()) else {
            return Box::pin(async { Err(ToolError::InvalidArgs("missing command".to_string())) });
        };

        Box::pin(async move {
            let cwd = context.resolve(&cwd)?;
            let sandbox = context.sandbox().cloned();
            let cancelled = context.cancel_probe();
            let (sender, receiver) = oneshot::channel();
            std::thread::Builder::new()
                .name("cgc-agent-run-command".to_string())
                .spawn(move || {
                    let result = execute(command, cwd, timeout, sandbox, cancelled);
                    let _ = sender.send(result);
                })
                .map_err(|error| ToolError::Io(format!("spawn command thread: {error}")))?;
            receiver
                .await
                .map_err(|_| ToolError::Io("command thread dropped".to_string()))?
        })
    }
}

fn execute(
    command: String,
    cwd: std::path::PathBuf,
    timeout: Duration,
    sandbox: Option<SandboxPolicy>,
    cancelled: Option<crate::tool::CancelProbe>,
) -> Result<ToolResult, ToolError> {
    let mut process = match sandbox {
        Some(policy) => CommandSandbox::detect().wrap(&command, &cwd, &policy),
        None => {
            let mut process = shell_command(&command);
            process.current_dir(&cwd);
            process
        }
    };
    // 独立进程组：超时/取消时能连同 shell 派生的子进程一起终止，避免 turn 结束后
    // 仍有后台命令继续改文件。
    #[cfg(unix)]
    process.process_group(0);
    let mut child = process
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| ToolError::Io(format!("spawn command: {error}")))?;
    let process_group = child.id();

    let stdout = child.stdout.take().map(read_async);
    let stderr = child.stderr.take().map(read_async);

    let started = Instant::now();
    let mut timed_out = false;
    let mut aborted = false;
    let status = loop {
        match child.try_wait()? {
            Some(status) => break Some(status),
            // Stop 优先于 timeout：用户停止后不再等命令自己跑完。
            None if cancelled.as_ref().is_some_and(|probe| probe()) => {
                aborted = true;
                terminate(&mut child, process_group);
                break child.wait().ok();
            }
            None if started.elapsed() >= timeout => {
                timed_out = true;
                terminate(&mut child, process_group);
                break child.wait().ok();
            }
            None => std::thread::sleep(Duration::from_millis(25)),
        }
    };

    let stdout = join_output(stdout);
    let stderr = join_output(stderr);
    let exit_code = status.and_then(|status| status.code());
    let mut content = String::new();
    if timed_out {
        content.push_str(&format!("timed out after {}s\n", timeout.as_secs()));
    }
    if aborted {
        content.push_str("cancelled by user\n");
    }
    content.push_str(&format!(
        "exit_code: {}\n--- stdout ---\n{}\n--- stderr ---\n{}",
        exit_code
            .map(|code| code.to_string())
            .unwrap_or_else(|| "killed".to_string()),
        truncate(&stdout),
        truncate(&stderr)
    ));
    Ok(ToolResult {
        content,
        is_error: timed_out || aborted || exit_code != Some(0),
    })
}

/// 终止命令及其派生进程；Unix 上按进程组发送 SIGKILL，其他平台退化为只杀 shell。
///
/// 用系统 `kill` 而不是引入新的 FFI 依赖：负 pid 表示整个进程组。失败时仍退回
/// 单进程 kill，保证至少有终止动作。
// Windows 下没有进程组概念，`process_group` 只用于上面的 `kill -KILL -<pgid>`。
#[cfg_attr(not(unix), allow(unused_variables))]
fn terminate(child: &mut std::process::Child, process_group: u32) {
    #[cfg(unix)]
    {
        let _ = std::process::Command::new("kill")
            .arg("-KILL")
            .arg(format!("-{process_group}"))
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
    }
    let _ = child.kill();
}

fn shell_command(command: &str) -> Command {
    #[cfg(windows)]
    {
        let mut process = Command::new("cmd");
        process.arg("/C").arg(command);
        process
    }
    #[cfg(not(windows))]
    {
        let mut process = Command::new("sh");
        process.arg("-c").arg(command);
        process
    }
}

fn read_async(mut reader: impl Read + Send + 'static) -> Arc<Mutex<Vec<u8>>> {
    let buffer = Arc::new(Mutex::new(Vec::new()));
    let target = Arc::clone(&buffer);
    std::thread::spawn(move || {
        let mut chunk = [0u8; 8192];
        loop {
            match reader.read(&mut chunk) {
                Ok(0) => break,
                Ok(read) => {
                    let mut target = target.lock().expect("output buffer");
                    if target.len() < MAX_OUTPUT_BYTES {
                        target.extend_from_slice(&chunk[..read]);
                    }
                }
                Err(_) => break,
            }
        }
    });
    buffer
}

fn join_output(buffer: Option<Arc<Mutex<Vec<u8>>>>) -> String {
    match buffer {
        Some(buffer) => String::from_utf8_lossy(&buffer.lock().expect("output buffer")).to_string(),
        None => String::new(),
    }
}

fn truncate(text: &str) -> String {
    if text.len() <= MAX_OUTPUT_BYTES {
        return text.to_string();
    }
    let mut end = MAX_OUTPUT_BYTES;
    while end > 0 && !text.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}…(truncated)", &text[..end])
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_workspace(tag: &str) -> std::path::PathBuf {
        use std::sync::atomic::{AtomicU64, Ordering};
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let serial = COUNTER.fetch_add(1, Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!(
            "cgc-agent-tools-run-{}-{tag}-{serial}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("workspace");
        dir
    }

    #[test]
    fn runs_echo_and_reports_exit_code() {
        let workspace = temp_workspace("echo");
        let context = ToolContext::new(&workspace);
        let result = futures::executor::block_on(
            RunCommandTool::new().run(serde_json::json!({"command": "echo hello"}), context),
        )
        .expect("run");
        assert!(result.content.contains("hello"));
        assert!(!result.is_error);
        let _ = std::fs::remove_dir_all(&workspace);
    }

    /// 超时必须回收整棵进程树：后台孙子进程不能在 turn 结束后继续写文件。
    #[cfg(unix)]
    #[test]
    fn timeout_kills_descendant_processes() {
        let workspace = temp_workspace("tree");
        let marker = workspace.join("survivor.txt");
        let context = ToolContext::new(&workspace);
        let command = format!(
            "sh -c 'sleep 2; echo survived > {}' & wait",
            marker.display()
        );
        let result = futures::executor::block_on(RunCommandTool::new().run(
            serde_json::json!({"command": command, "timeout_secs": 1}),
            context,
        ))
        .expect("run");
        assert!(result.is_error, "超时必须标记为失败");
        assert!(result.content.contains("timed out"), "{}", result.content);
        // 给被杀进程足够时间：若进程组未被终止，这里会看到 survivor.txt。
        std::thread::sleep(std::time::Duration::from_millis(2500));
        assert!(
            !marker.exists(),
            "派生进程必须随执行超时一起终止，文件: {}",
            marker.display()
        );
        let _ = std::fs::remove_dir_all(&workspace);
    }

    #[test]
    fn non_zero_exit_marks_error() {
        let workspace = temp_workspace("false");
        let context = ToolContext::new(&workspace);
        let result = futures::executor::block_on(
            RunCommandTool::new().run(serde_json::json!({"command": "exit 3"}), context),
        )
        .expect("run");
        assert!(result.is_error);
        assert!(result.content.contains("exit_code: 3"));
        let _ = std::fs::remove_dir_all(&workspace);
    }

    #[test]
    fn timeout_kills_process() {
        let workspace = temp_workspace("timeout");
        let context = ToolContext::new(&workspace);
        let result = futures::executor::block_on(RunCommandTool::new().run(
            serde_json::json!({"command": "sleep 5", "timeout_secs": 1}),
            context,
        ))
        .expect("run");
        assert!(result.is_error);
        assert!(result.content.contains("timed out"));
        let _ = std::fs::remove_dir_all(&workspace);
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn sandboxed_command_runs_in_workspace() {
        let workspace = temp_workspace("sandbox");
        let context = ToolContext::new(&workspace).with_sandbox(SandboxPolicy::new(&workspace));
        let result = futures::executor::block_on(
            RunCommandTool::new().run(serde_json::json!({"command": "echo sandbox-ok"}), context),
        )
        .expect("run");
        assert!(result.content.contains("sandbox-ok"));
        assert!(!result.is_error);
        let _ = std::fs::remove_dir_all(&workspace);
    }

    #[test]
    fn run_requires_approval() {
        assert_eq!(
            RunCommandTool::new().approval(&serde_json::json!({})),
            Approval::Ask
        );
    }

    #[test]
    fn destructive_command_is_denied_before_approval() {
        let approval = RunCommandTool::new().approval(&serde_json::json!({
            "command": "rm -rf / --no-preserve-root"
        }));
        assert!(matches!(approval, Approval::Deny(_)));
    }

    #[test]
    fn normal_command_still_asks() {
        let approval = RunCommandTool::new().approval(&serde_json::json!({
            "command": "cargo test"
        }));
        assert_eq!(approval, Approval::Ask);
    }

    #[test]
    fn rejects_cwd_escape() {
        let workspace = temp_workspace("escape");
        let context = ToolContext::new(&workspace);
        let error = futures::executor::block_on(RunCommandTool::new().run(
            serde_json::json!({"command": "pwd", "cwd": "../outside"}),
            context,
        ))
        .unwrap_err();
        assert!(matches!(error, ToolError::PathEscape(_)));
        let _ = std::fs::remove_dir_all(&workspace);
    }
}

#[cfg(test)]
mod cancel_tests {
    use super::*;
    use std::sync::atomic::{AtomicBool, Ordering};

    /// Stop 必须在自身 timeout 之前终止命令，而不是让用户等到 30s。
    #[cfg(unix)]
    #[test]
    fn cancel_probe_stops_long_command_without_waiting_for_timeout() {
        let workspace = std::env::temp_dir().join(format!("cgc-run-cancel-{}", std::process::id()));
        std::fs::create_dir_all(&workspace).unwrap();
        let flag = Arc::new(AtomicBool::new(false));
        let probe: crate::tool::CancelProbe = {
            let flag = Arc::clone(&flag);
            Arc::new(move || flag.load(Ordering::SeqCst))
        };
        // 10s 的 sleep，但 timeout 给 120s：只有取消能把它提前结束。
        std::thread::spawn({
            let flag = Arc::clone(&flag);
            move || {
                std::thread::sleep(Duration::from_millis(300));
                flag.store(true, Ordering::SeqCst);
            }
        });
        let started = Instant::now();
        let result = futures::executor::block_on(RunCommandTool::new().run(
            serde_json::json!({"command": "sleep 10", "timeout_secs": 120}),
            ToolContext::new(&workspace).with_cancel(probe),
        ))
        .expect("run");
        assert!(result.is_error, "取消必须标记为失败");
        assert!(
            result.content.contains("cancelled by user"),
            "{}",
            result.content
        );
        assert!(
            started.elapsed() < Duration::from_secs(5),
            "取消后应立即返回，实际 {:?}",
            started.elapsed()
        );
        let _ = std::fs::remove_dir_all(&workspace);
    }

    /// 没有探针时保持原行为：命令正常跑完。
    #[test]
    fn without_probe_commands_complete_normally() {
        let workspace =
            std::env::temp_dir().join(format!("cgc-run-noprobe-{}", std::process::id()));
        std::fs::create_dir_all(&workspace).unwrap();
        let result = futures::executor::block_on(RunCommandTool::new().run(
            serde_json::json!({"command": "echo done"}),
            ToolContext::new(&workspace),
        ))
        .expect("run");
        assert!(!result.is_error, "{}", result.content);
        assert!(result.content.contains("done"));
        let _ = std::fs::remove_dir_all(&workspace);
    }
}
