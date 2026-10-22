use std::{
    io::Read,
    process::{Command, Stdio},
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

use futures::{channel::oneshot, future::BoxFuture};

use crate::{
    approval::Approval,
    error::ToolError,
    sandbox::{CommandSandbox, SandboxPolicy},
    tool::{Tool, ToolContext, ToolResult},
};

const DEFAULT_TIMEOUT: Duration = Duration::from_secs(30);
const MAX_TIMEOUT: Duration = Duration::from_secs(120);
const MAX_OUTPUT_BYTES: usize = 32 * 1024;

/// 在工作区内执行一条 shell 命令；默认需要用户确认。
pub struct RunCommandTool;

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

    fn approval(&self, _args: &serde_json::Value) -> Approval {
        Approval::Ask
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
            let (sender, receiver) = oneshot::channel();
            std::thread::Builder::new()
                .name("cgc-agent-run-command".to_string())
                .spawn(move || {
                    let result = execute(command, cwd, timeout, sandbox);
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
) -> Result<ToolResult, ToolError> {
    let mut process = match sandbox {
        Some(policy) => CommandSandbox::detect().wrap(&command, &cwd, &policy),
        None => {
            let mut process = shell_command(&command);
            process.current_dir(&cwd);
            process
        }
    };
    let mut child = process
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| ToolError::Io(format!("spawn command: {error}")))?;

    let stdout = child.stdout.take().map(read_async);
    let stderr = child.stderr.take().map(read_async);

    let started = Instant::now();
    let mut timed_out = false;
    let status = loop {
        match child.try_wait()? {
            Some(status) => break Some(status),
            None if started.elapsed() >= timeout => {
                timed_out = true;
                let _ = child.kill();
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
        is_error: timed_out || exit_code != Some(0),
    })
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
            RunCommandTool.run(serde_json::json!({"command": "echo hello"}), context),
        )
        .expect("run");
        assert!(result.content.contains("hello"));
        assert!(!result.is_error);
        let _ = std::fs::remove_dir_all(&workspace);
    }

    #[test]
    fn non_zero_exit_marks_error() {
        let workspace = temp_workspace("false");
        let context = ToolContext::new(&workspace);
        let result = futures::executor::block_on(
            RunCommandTool.run(serde_json::json!({"command": "exit 3"}), context),
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
        let result = futures::executor::block_on(RunCommandTool.run(
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
            RunCommandTool.run(serde_json::json!({"command": "echo sandbox-ok"}), context),
        )
        .expect("run");
        assert!(result.content.contains("sandbox-ok"));
        assert!(!result.is_error);
        let _ = std::fs::remove_dir_all(&workspace);
    }

    #[test]
    fn run_requires_approval() {
        assert_eq!(
            RunCommandTool.approval(&serde_json::json!({})),
            Approval::Ask
        );
    }

    #[test]
    fn rejects_cwd_escape() {
        let workspace = temp_workspace("escape");
        let context = ToolContext::new(&workspace);
        let error = futures::executor::block_on(RunCommandTool.run(
            serde_json::json!({"command": "pwd", "cwd": "../outside"}),
            context,
        ))
        .unwrap_err();
        assert!(matches!(error, ToolError::PathEscape(_)));
        let _ = std::fs::remove_dir_all(&workspace);
    }
}
