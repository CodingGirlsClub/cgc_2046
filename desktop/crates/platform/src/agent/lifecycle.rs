//! agent 进程生命周期（story 5.4）：优雅退出、超时强杀、崩溃重启上限。
//!
//! 重启策略是纯逻辑，便于测试；进程回收在 `AgentProcess` 中实现。
//! 崩溃或退出后由调用方（Host runtime）按 `RestartPolicy` 决定是否重启，
//! v1 不自动无限重启。

use std::process::{Child, Command, ExitStatus};
use std::time::{Duration, Instant};

use super::launch::LaunchPlan;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RestartPolicy {
    pub max_attempts: u32,
    pub base_delay: Duration,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RestartDecision {
    RestartAfter(Duration),
    GiveUp,
}

impl Default for RestartPolicy {
    fn default() -> Self {
        Self {
            max_attempts: 3,
            base_delay: Duration::from_millis(500),
        }
    }
}

impl RestartPolicy {
    /// `attempt` 从 1 开始；超过上限即 GiveUp，延迟指数退避（0.5s/1s/2s）。
    pub fn decision(&self, attempt: u32) -> RestartDecision {
        if attempt == 0 || attempt > self.max_attempts {
            return RestartDecision::GiveUp;
        }
        RestartDecision::RestartAfter(self.base_delay * 2u32.saturating_pow(attempt - 1))
    }
}

pub struct AgentProcess {
    child: Child,
    label: String,
}

impl AgentProcess {
    pub fn spawn(plan: &LaunchPlan) -> std::io::Result<Self> {
        let mut command = Command::new(&plan.program);
        command
            .args(&plan.args)
            .current_dir(&plan.cwd)
            .env_clear()
            .envs(&plan.env)
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped());
        let child = command.spawn()?;
        Ok(Self {
            child,
            label: plan.program.to_string_lossy().to_string(),
        })
    }

    pub fn id(&self) -> u32 {
        self.child.id()
    }

    pub fn is_running(&mut self) -> std::io::Result<bool> {
        Ok(self.child.try_wait()?.is_none())
    }

    pub fn wait(&mut self) -> std::io::Result<ExitStatus> {
        self.child.wait()
    }

    /// 优雅终止：Unix 先 SIGTERM，Windows 先 taskkill；超时后强杀。
    pub fn terminate(&mut self, grace: Duration) -> std::io::Result<ExitStatus> {
        if self.child.try_wait()?.is_some() {
            return self.child.wait();
        }
        graceful_signal(self.child.id());
        let started = Instant::now();
        while started.elapsed() < grace {
            if let Some(status) = self.child.try_wait()? {
                return Ok(status);
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        let _ = self.child.kill();
        self.child.wait()
    }

    pub fn label(&self) -> &str {
        &self.label
    }
}

impl Drop for AgentProcess {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[cfg(unix)]
fn graceful_signal(pid: u32) {
    let _ = Command::new("kill")
        .arg("-TERM")
        .arg(pid.to_string())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status();
}

#[cfg(windows)]
fn graceful_signal(pid: u32) {
    let _ = Command::new("taskkill")
        .args(["/PID", &pid.to_string(), "/T"])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status();
}

#[cfg(not(any(unix, windows)))]
fn graceful_signal(_pid: u32) {}

/// 测试辅助：用 sh 起一个可被 TERM 结束的进程计划（仅 Unix）。
#[cfg(all(test, unix))]
fn shell_plan(script: &str) -> LaunchPlan {
    LaunchPlan {
        program: std::path::PathBuf::from("sh"),
        args: vec!["-c".to_string(), script.to_string()],
        env: std::collections::BTreeMap::new(),
        cwd: std::env::temp_dir(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn restart_policy_is_bounded_and_backs_off() {
        let policy = RestartPolicy::default();
        assert_eq!(
            policy.decision(1),
            RestartDecision::RestartAfter(Duration::from_millis(500))
        );
        assert_eq!(
            policy.decision(2),
            RestartDecision::RestartAfter(Duration::from_secs(1))
        );
        assert_eq!(
            policy.decision(3),
            RestartDecision::RestartAfter(Duration::from_secs(2))
        );
        assert_eq!(policy.decision(4), RestartDecision::GiveUp);
        assert_eq!(policy.decision(0), RestartDecision::GiveUp);
    }

    #[cfg(unix)]
    #[test]
    fn process_terminates_after_grace() {
        let plan = shell_plan("sleep 10");
        let mut process = AgentProcess::spawn(&plan).expect("spawn");
        assert!(process.is_running().expect("running"));
        let status = process
            .terminate(Duration::from_millis(200))
            .expect("terminate");
        assert!(!status.success() || status.code() == Some(143));
        assert!(!process.is_running().unwrap_or(false));
    }

    #[cfg(unix)]
    #[test]
    fn exited_process_is_reaped() {
        let plan = shell_plan("exit 0");
        let mut process = AgentProcess::spawn(&plan).expect("spawn");
        let status = process.wait().expect("wait");
        assert!(status.success());
        assert!(!process.is_running().expect("running"));
    }
}
