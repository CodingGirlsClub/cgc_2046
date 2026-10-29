//! 本地文件日志：`<data_root>/logs/app.log`。
//!
//! 为什么需要：用户双击 `.app` 启动时 stderr 无处可看，内测反馈只有「打不开」；
//! 内测包必须能从文件取证。日志只写本地文件与 stderr——不联网、不上报，
//! 每条写入前统一过 `telemetry::redact_sensitive`（AD-13/AD-16：凭证、手机号、
//! 邮箱、对话内容不进日志）。
//!
//! - 路径：`<data_root>/logs/app.log`，例如
//!   `~/Library/Application Support/cgc-desktop/logs/app.log`
//! - 轮转：单文件超过 [`MAX_LOG_BYTES`] 时改名为 `app.log.1`（只保留一份历史）
//! - 级别：`CGC_LOG=error|warn|info|debug|trace`，默认 `info`
//! - 调用方：`main` 启动时 [`init`] + [`install_panic_hook`]，其余模块用 `log::*!`

use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};

use log::{Level, LevelFilter, Log, Metadata, Record};

use crate::telemetry::redact_sensitive;

/// 单文件上限；超过即轮转，避免长期内测把磁盘写满。
pub const MAX_LOG_BYTES: u64 = 5 * 1024 * 1024;

const LOG_DIR: &str = "logs";
const LOG_FILE: &str = "app.log";

static LOGGER: OnceLock<FileLogger> = OnceLock::new();

/// 日志文件路径（`<data_root>/logs/app.log`）。
pub fn log_file_path(data_root: &Path) -> PathBuf {
    data_root.join(LOG_DIR).join(LOG_FILE)
}

/// 初始化文件日志；返回日志路径（失败时返回 `None`，不阻塞启动）。
///
/// 重复调用沿用第一次的 logger（测试与多入口防重）。
pub fn init(data_root: &Path) -> Option<PathBuf> {
    let path = log_file_path(data_root);
    if LOGGER.get().is_none() {
        let logger = match FileLogger::open(path.clone(), MAX_LOG_BYTES) {
            Ok(logger) => logger,
            Err(error) => {
                eprintln!("[log] disabled: {error}");
                return None;
            }
        };
        let _ = LOGGER.set(logger);
    }
    log::set_max_level(level_from(std::env::var("CGC_LOG").ok().as_deref()));
    if let Some(logger) = LOGGER.get() {
        if log::set_logger(logger).is_err() {
            // 已有别的 logger（例如测试里装过）：沿用即可，不视为失败。
            return Some(path);
        }
    }
    Some(path)
}

/// 把 panic 写进日志文件（本地、脱敏、不联网），随后交回原 hook。
pub fn install_panic_hook() {
    let previous = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        let location = info
            .location()
            .map(|location| format!("{}:{}", location.file(), location.line()))
            .unwrap_or_else(|| "unknown".to_string());
        let message = info
            .payload()
            .downcast_ref::<String>()
            .map(String::as_str)
            .or_else(|| info.payload().downcast_ref::<&str>().copied())
            .unwrap_or("panic");
        log::error!(target: "panic", "{location}: {message}");
        previous(info);
    }));
}

/// 纯解析日志级别；非法/缺省为 `info`。
pub fn level_from(value: Option<&str>) -> LevelFilter {
    match value.map(str::trim) {
        Some(value) if value.eq_ignore_ascii_case("error") => LevelFilter::Error,
        Some(value) if value.eq_ignore_ascii_case("warn") => LevelFilter::Warn,
        Some(value) if value.eq_ignore_ascii_case("debug") => LevelFilter::Debug,
        Some(value) if value.eq_ignore_ascii_case("trace") => LevelFilter::Trace,
        _ => LevelFilter::Info,
    }
}

/// 渲染一行日志；`message` 写前脱敏。任何入口都走这里，避免漏脱敏。
fn render_line(level: Level, target: &str, message: &str, at: &str) -> String {
    format!("{at} {level:<5} {target}: {}\n", redact_sensitive(message))
}

fn timestamp() -> String {
    chrono::Local::now()
        .format("%Y-%m-%dT%H:%M:%S%.3f%:z")
        .to_string()
}

fn open_append(path: &Path) -> Result<File, String> {
    OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .map_err(|error| format!("open {}: {error}", path.display()))
}

struct FileLogger {
    path: PathBuf,
    limit: u64,
    state: Mutex<State>,
}

struct State {
    file: Option<File>,
    written: u64,
}

impl FileLogger {
    fn open(path: PathBuf, limit: u64) -> Result<Self, String> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)
                .map_err(|error| format!("create log dir {}: {error}", parent.display()))?;
        }
        let file = open_append(&path)?;
        let written = file.metadata().map(|meta| meta.len()).unwrap_or(0);
        Ok(Self {
            path,
            limit,
            state: Mutex::new(State {
                file: Some(file),
                written,
            }),
        })
    }

    fn append(&self, line: &str) {
        let Ok(mut state) = self.state.lock() else {
            return;
        };
        let len = line.len() as u64;
        if state.written > 0 && state.written + len > self.limit {
            state.file = None;
            if let Err(error) = rotate(&self.path) {
                eprintln!("[log] rotate failed: {error}");
            }
            state.written = 0;
        }
        if state.file.is_none() {
            match open_append(&self.path) {
                Ok(file) => state.file = Some(file),
                Err(error) => {
                    eprintln!("[log] reopen failed: {error}");
                    return;
                }
            }
        }
        if let Some(file) = state.file.as_mut() {
            if let Err(error) = file.write_all(line.as_bytes()) {
                eprintln!("[log] write failed: {error}");
                state.file = None;
                return;
            }
            state.written += len;
        }
    }
}

/// 把当前文件改名为 `app.log.1`（覆盖上一条历史）。
fn rotate(path: &Path) -> Result<(), String> {
    let previous = path.with_extension("log.1");
    let _ = fs::remove_file(&previous);
    fs::rename(path, &previous).map_err(|error| format!("rotate {}: {error}", path.display()))
}

impl Log for FileLogger {
    fn enabled(&self, metadata: &Metadata) -> bool {
        metadata.level() <= log::max_level()
    }

    fn log(&self, record: &Record) {
        if !self.enabled(record.metadata()) {
            return;
        }
        let line = render_line(
            record.level(),
            record.target(),
            &record.args().to_string(),
            &timestamp(),
        );
        eprint!("{line}");
        self.append(&line);
    }

    fn flush(&self) {
        if let Ok(mut state) = self.state.lock() {
            if let Some(file) = state.file.as_mut() {
                let _ = file.flush();
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "cgc-log-{name}-{}-{}",
            std::process::id(),
            timestamp().replace([':', '.', '+'], "")
        ));
        let _ = fs::remove_dir_all(&dir);
        dir
    }

    #[test]
    fn log_file_lives_under_logs_dir() {
        assert_eq!(
            log_file_path(Path::new("/tmp/data")),
            PathBuf::from("/tmp/data/logs/app.log")
        );
    }

    #[test]
    fn level_parsing_defaults_to_info() {
        assert_eq!(level_from(None), LevelFilter::Info);
        assert_eq!(level_from(Some("")), LevelFilter::Info);
        assert_eq!(level_from(Some("bogus")), LevelFilter::Info);
        assert_eq!(level_from(Some("ERROR")), LevelFilter::Error);
        assert_eq!(level_from(Some(" warn ")), LevelFilter::Warn);
        assert_eq!(level_from(Some("debug")), LevelFilter::Debug);
        assert_eq!(level_from(Some("trace")), LevelFilter::Trace);
    }

    #[test]
    fn rendered_lines_are_redacted() {
        let line = render_line(
            Level::Error,
            "cgc::test",
            "auth Bearer abc.def.ghi token cgch_secret phone 13800138000 email demo@example.com",
            "2026-10-28T00:00:00.000+08:00",
        );
        assert!(line.ends_with('\n'), "每行以换行结尾：{line:?}");
        assert!(line.contains("ERROR"));
        assert!(line.contains("cgc::test"));
        assert!(!line.contains("cgch_"), "token 必须脱敏：{line}");
        assert!(!line.contains("demo@example.com"), "邮箱必须脱敏：{line}");
        assert!(!line.contains("13800138000"), "手机号必须脱敏：{line}");
        assert!(line.contains("<redacted>"));
    }

    #[test]
    fn append_writes_lines_to_file() {
        let dir = temp_dir("append");
        let logger = FileLogger::open(log_file_path(&dir), MAX_LOG_BYTES).expect("open");
        logger.append("first\n");
        logger.append("second\n");
        let text = fs::read_to_string(log_file_path(&dir)).expect("read log");
        assert_eq!(text, "first\nsecond\n");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn rotates_and_keeps_one_history_file() {
        let dir = temp_dir("rotate");
        let logger = FileLogger::open(log_file_path(&dir), 40).expect("open");
        logger.append(&format!("{}\n", "a".repeat(20)));
        logger.append(&format!("{}\n", "b".repeat(20)));
        logger.append(&format!("{}\n", "c".repeat(20)));
        let history = log_file_path(&dir).with_extension("log.1");
        assert!(history.exists(), "超过上限必须轮转到 app.log.1");
        let current = fs::read_to_string(log_file_path(&dir)).expect("read log");
        assert!(current.contains('c'), "当前文件保留最新一行：{current:?}");
        assert!(
            current.len() as u64 <= 40,
            "当前文件不超过上限：{current:?}"
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn continues_writing_after_rotation() {
        let dir = temp_dir("rotate-continue");
        let logger = FileLogger::open(log_file_path(&dir), 40).expect("open");
        for index in 0..6 {
            logger.append(&format!("{}\n", index.to_string().repeat(20)));
        }
        let current = fs::read_to_string(log_file_path(&dir)).expect("read log");
        assert!(current.contains('5'), "轮转后必须继续写入：{current:?}");
        let _ = fs::remove_dir_all(&dir);
    }
}
