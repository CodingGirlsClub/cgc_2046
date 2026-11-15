//! DSH（DeepSeek Harness）运行时探测（ADR-0031 D1/D4）。
//!
//! 探测顺序固定为：显式配置 → DSH Desktop 安装路径 → PATH 上的独立 `dsh`。
//! 探测结果只用于 UI 展示；openma standalone 始终以适配器内置 `bundled` 运行时启动，
//! 客户端不会把外部 dsh 路径传给 `--dsh-path`。

use std::path::{Path, PathBuf};
use std::time::Duration;

use serde_json::Value;

use super::command::run_output;
use super::detect::parse_version;
use super::launch::{inherited_environment, LaunchPlan, NodeRuntime};
use crate::registry::manifest::{AgentEntry, Distribution};

/// 适配器声明的最低 dsh 版本（`engines.dsh`）。
pub const DSH_MIN_SUPPORTED: &str = "0.1.7";
/// openma 0.4.41 捆绑/测试过的 dsh 版本；更高版本只 warning，不阻断。
pub const DSH_TESTED_MAX: &str = "0.2.1";
/// 缺失 DSH Desktop 时的默认下载入口（registry 条目的 `download_hint` 可覆盖）。
pub const DSH_DOWNLOAD_URL: &str = "https://dshsuite.dev/";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RuntimeSource {
    Explicit,
    DshDesktop,
    Path,
    Bundled,
    /// DSH Desktop 的 `dsh --profile acp` 插件形态（ADR-0031 D1 修订）。
    Plugin,
    Missing,
}

impl RuntimeSource {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Explicit => "explicit",
            Self::DshDesktop => "dsh-desktop",
            Self::Path => "path",
            Self::Bundled => "bundled",
            Self::Plugin => "plugin",
            Self::Missing => "missing",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RuntimeProbe {
    pub found: bool,
    /// 探测到的 dsh 版本（`source` 指向的那个运行时）。
    pub version: Option<String>,
    pub source: RuntimeSource,
    /// 外部 dsh 可执行文件路径；bundled 由适配器内部解析，这里为 None。
    pub path: Option<PathBuf>,
    /// 适配器包内 `vendor/runtime.json` 的内置 dsh 版本；未安装适配器时 None。
    /// UI 用它在检测到外部 DSH Desktop 时同时展示“本次实际使用”的内置版本。
    pub bundled_version: Option<String>,
}

impl RuntimeProbe {
    pub fn missing() -> Self {
        Self {
            found: false,
            version: None,
            source: RuntimeSource::Missing,
            path: None,
            bundled_version: None,
        }
    }

    pub fn bundled(version: Option<String>) -> Self {
        Self {
            found: true,
            version: version.clone(),
            source: RuntimeSource::Bundled,
            path: None,
            bundled_version: version,
        }
    }

    /// plugin 形态：`version` 是 profile 里 adapter 的版本，`dsh` 是 CLI 路径。
    pub fn plugin(version: String, dsh: PathBuf) -> Self {
        Self {
            found: true,
            version: Some(version),
            source: RuntimeSource::Plugin,
            path: Some(dsh),
            bundled_version: None,
        }
    }

    /// 是否找到了外部安装（显式 / DSH Desktop / PATH / plugin）；bundled 不算外部。
    pub fn external_found(&self) -> bool {
        matches!(
            self.source,
            RuntimeSource::Explicit
                | RuntimeSource::DshDesktop
                | RuntimeSource::Path
                | RuntimeSource::Plugin
        )
    }

    /// 传给 `dsh-acp --dsh-path` 的值：openma 统一使用其内置运行时。
    ///
    /// DSH Desktop / PATH 的探测结果只用于 UI 展示（版本与来源），不参与启动；
    /// openma standalone adapter 无法从 Electron app.asar 加载 dsh。
    pub fn launch_arg(&self) -> Option<&str> {
        Some("bundled")
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DshVersionStatus {
    Supported,
    BelowMinimum,
    AboveTested,
    Unknown,
}

/// 版本矩阵判断：低于适配器下限 → 不兼容；高于 openma 0.4.41 测试过的上限 → warning。
pub fn dsh_version_status(version: &str) -> DshVersionStatus {
    let Some(normalized) = parse_version(version) else {
        return DshVersionStatus::Unknown;
    };
    if !super::detect::version_at_least(&normalized, DSH_MIN_SUPPORTED) {
        DshVersionStatus::BelowMinimum
    } else if version_greater(&normalized, DSH_TESTED_MAX) {
        DshVersionStatus::AboveTested
    } else {
        DshVersionStatus::Supported
    }
}

fn version_greater(found: &str, reference: &str) -> bool {
    super::detect::version_at_least(found, reference) && found != reference
}

/// 创建隔离的 `DSH_HOME`（ADR-0031 D3）：目录存在即复用；Unix 权限收紧到 0700。
pub fn ensure_dsh_home(path: &Path) -> std::io::Result<()> {
    std::fs::create_dir_all(path)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut permissions = std::fs::metadata(path)?.permissions();
        permissions.set_mode(0o700);
        std::fs::set_permissions(path, permissions)?;
    }
    Ok(())
}

/// 生产探测入口：读取进程环境与文件系统，产出 [`RuntimeProbe`]。
pub fn probe_dsh_runtime(entry: Option<&AgentEntry>, node: Option<&NodeRuntime>) -> RuntimeProbe {
    let explicit = explicit_dsh_path();
    let bundled = entry.and_then(|entry| bundled_runtime_version(entry, node));
    let probe = probe_dsh_runtime_with(
        explicit,
        dsh_desktop_candidates(),
        dsh_path_candidates(),
        bundled,
        version_of_executable,
    );
    if let Some(version) = probe.version.as_deref() {
        match dsh_version_status(version) {
            DshVersionStatus::AboveTested => log::warn!(
                "dsh runtime {version} is newer than tested {DSH_TESTED_MAX}; continue with warning (source={})",
                probe.source.as_str()
            ),
            DshVersionStatus::BelowMinimum => log::warn!(
                "dsh runtime {version} is below supported {DSH_MIN_SUPPORTED} (source={})",
                probe.source.as_str()
            ),
            _ => {}
        }
    }
    probe
}

/// 读取适配器包内 bundled 运行时版本（诊断与测试用）。
pub fn bundled_probe(entry: &AgentEntry, node: Option<&NodeRuntime>) -> RuntimeProbe {
    match bundled_runtime_version(entry, node) {
        Some(version) => RuntimeProbe::bundled(Some(version)),
        None => RuntimeProbe::missing(),
    }
}

/// 可注入核心：candidate 的版本读取器返回 Some 表示该候选可用。
pub fn probe_dsh_runtime_with(
    explicit: Option<PathBuf>,
    desktop_candidates: impl IntoIterator<Item = PathBuf>,
    path_candidates: impl IntoIterator<Item = PathBuf>,
    bundled_version: Option<String>,
    version_of: impl Fn(&Path) -> Option<String>,
) -> RuntimeProbe {
    if let Some(path) = explicit {
        if path == Path::new("bundled") {
            return bundled_probe_from(bundled_version);
        }
        if let Some(version) = version_of(&path) {
            return RuntimeProbe {
                found: true,
                version: Some(version),
                source: RuntimeSource::Explicit,
                path: Some(path),
                bundled_version,
            };
        }
    }
    for path in desktop_candidates {
        if let Some(version) = version_of(&path) {
            return RuntimeProbe {
                found: true,
                version: Some(version),
                source: RuntimeSource::DshDesktop,
                path: Some(path),
                bundled_version,
            };
        }
    }
    for path in path_candidates {
        if let Some(version) = version_of(&path) {
            return RuntimeProbe {
                found: true,
                version: Some(version),
                source: RuntimeSource::Path,
                path: Some(path),
                bundled_version,
            };
        }
    }
    bundled_probe_from(bundled_version)
}

fn bundled_probe_from(bundled_version: Option<String>) -> RuntimeProbe {
    match bundled_version {
        Some(version) => RuntimeProbe::bundled(Some(version)),
        None => RuntimeProbe::missing(),
    }
}

fn explicit_dsh_path() -> Option<PathBuf> {
    for key in ["CGC_DSH_PATH", "DSH_PATH"] {
        if let Some(value) = std::env::var_os(key) {
            let value = value.to_string_lossy();
            let value = value.trim();
            if !value.is_empty() {
                return Some(PathBuf::from(value));
            }
        }
    }
    None
}

fn dsh_desktop_candidates() -> Vec<PathBuf> {
    let mut candidates = Vec::new();
    let mut push = |path: PathBuf| {
        if !candidates.contains(&path) {
            candidates.push(path);
        }
    };
    if cfg!(target_os = "macos") {
        let mut bases = vec![PathBuf::from("/Applications")];
        if let Some(home) = std::env::var_os("HOME") {
            bases.push(PathBuf::from(home).join("Applications"));
        }
        for base in bases {
            for app in [
                "DeepSeek Harness.app",
                "DSH Desktop.app",
                "DeepSeek Harness Desktop.app",
            ] {
                push(
                    base.join(app)
                        .join("Contents/Resources/runtime/cli/bin/dsh"),
                );
            }
        }
    } else if cfg!(target_os = "windows") {
        let mut bases = Vec::new();
        if let Some(local) = std::env::var_os("LOCALAPPDATA") {
            bases.push(PathBuf::from(&local).join("Programs"));
            bases.push(PathBuf::from(local));
        }
        if let Some(program_files) = std::env::var_os("PROGRAMFILES") {
            bases.push(PathBuf::from(program_files));
        }
        for base in bases {
            for app in ["DeepSeek Harness", "DSH Desktop"] {
                for exe in ["dsh.cmd", "dsh.exe"] {
                    push(base.join(app).join("resources/runtime/cli/bin").join(exe));
                }
            }
        }
    } else {
        for path in [
            "/opt/DeepSeek Harness/resources/runtime/cli/bin/dsh",
            "/opt/DSH Desktop/resources/runtime/cli/bin/dsh",
            "/usr/lib/deepseek-harness/resources/runtime/cli/bin/dsh",
            "/usr/lib/dsh-desktop/resources/runtime/cli/bin/dsh",
        ] {
            push(PathBuf::from(path));
        }
    }
    candidates
}

fn dsh_path_candidates() -> Vec<PathBuf> {
    let Some(path) = std::env::var_os("PATH") else {
        return Vec::new();
    };
    let names: &[&str] = if cfg!(windows) {
        &["dsh.exe", "dsh.cmd", "dsh.bat", "dsh"]
    } else {
        &["dsh"]
    };
    let mut candidates = Vec::new();
    for dir in std::env::split_paths(&path) {
        for name in names {
            let candidate = dir.join(name);
            if !candidates.contains(&candidate) {
                candidates.push(candidate);
            }
        }
    }
    candidates
}

fn version_of_executable(path: &Path) -> Option<String> {
    if !path.is_file() {
        return None;
    }
    let plan = LaunchPlan {
        program: path.to_path_buf(),
        args: vec!["--version".to_string()],
        env: inherited_environment(|key| std::env::var(key).ok()),
        cwd: std::env::temp_dir(),
    };
    run_output(&plan, Duration::from_secs(5))
        .ok()
        .and_then(|output| parse_version(&output))
}

/// 读取适配器包内 `vendor/runtime.json` 的 dsh 版本；未安装/格式非法返回 None。
fn bundled_runtime_version(entry: &AgentEntry, node: Option<&NodeRuntime>) -> Option<String> {
    if !entry.uses_dsh_runtime() {
        return None;
    }
    let Distribution::Npx { package, .. } = &entry.distribution else {
        return None;
    };
    let node = node?;
    let directory = crate::registry::package::install_dir(entry, node)
        .join("node_modules")
        .join(package)
        .join("vendor/runtime.json");
    let raw = std::fs::read_to_string(directory).ok()?;
    let value: Value = serde_json::from_str(&raw).ok()?;
    value.get("dsh").and_then(Value::as_str).map(str::to_string)
}

#[cfg(test)]
#[path = "dsh_runtime_tests.rs"]
mod tests;
