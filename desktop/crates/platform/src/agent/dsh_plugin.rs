//! DSH plugin 形态探测（ADR-0031 D1 修订）：有 DSH Desktop 时优先
//! `dsh --profile acp`，adapter 作为 profile 插件运行，从而复用用户
//! `~/.dsh/profiles/acp` 的 providers（magpie/GLM/Kimi…）与会话/凭据。
//!
//! 探测只读文件系统：`dsh` CLI 可执行、`$DSH_HOME/profiles/acp/package.json`
//! 声明了 `@openma/deepseek-harness-acp`。不启动进程，不读凭据。

use std::path::{Path, PathBuf};

use serde_json::Value;

use crate::paths::local_dsh_home;

pub const DSH_PLUGIN_PACKAGE: &str = "@openma/deepseek-harness-acp";
pub const DSH_PLUGIN_PROFILE: &str = "acp";

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DshPlugin {
    /// `dsh` CLI 路径（plugin 形态的启动入口）。
    pub dsh: PathBuf,
    /// 用户的 DSH 数据根（`DSH_HOME` > `~/.dsh`）。
    pub home: PathBuf,
    /// profile 里声明的 adapter 版本。
    pub version: String,
}

pub fn profile_dir(home: &Path) -> PathBuf {
    home.join("profiles").join(DSH_PLUGIN_PROFILE)
}

/// 读取 profile 声明的 adapter 版本；缺失/格式错误一律 None。
pub fn read_profile_version(home: &Path, package: &str) -> Option<String> {
    let raw = std::fs::read_to_string(profile_dir(home).join("package.json")).ok()?;
    let value: Value = serde_json::from_str(&raw).ok()?;
    value
        .get("dependencies")?
        .get(package)?
        .as_str()
        .map(str::to_string)
}

/// `dsh` CLI：`DSH_CLI` > PATH 上的 dsh > `~/.local/bin/dsh`。
pub fn find_dsh(env: impl Fn(&str) -> Option<PathBuf>) -> Option<PathBuf> {
    if let Some(path) = env("DSH_CLI").filter(|path| is_executable(path)) {
        return Some(path);
    }
    if let Some(path) = env("PATH").and_then(|path| {
        std::env::split_paths(&path)
            .map(|dir| dir.join("dsh"))
            .find(|candidate| is_executable(candidate))
    }) {
        return Some(path);
    }
    env("HOME")
        .map(|home| home.join(".local/bin/dsh"))
        .filter(|path| is_executable(path))
}

fn is_executable(path: &Path) -> bool {
    let Ok(metadata) = std::fs::metadata(path) else {
        return false;
    };
    if !metadata.is_file() {
        return false;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        metadata.permissions().mode() & 0o111 != 0
    }
    #[cfg(not(unix))]
    true
}

/// 探测 plugin 形态；三项缺一不可（本地 DSH 目录、dsh CLI、profile 安装）。
pub fn probe_with(env: impl Fn(&str) -> Option<PathBuf>) -> Option<DshPlugin> {
    let home = local_dsh_home(&env)?;
    let dsh = find_dsh(&env)?;
    let version = read_profile_version(&home, DSH_PLUGIN_PACKAGE)?;
    Some(DshPlugin { dsh, home, version })
}

pub fn probe() -> Option<DshPlugin> {
    probe_with(|key| std::env::var_os(key).map(PathBuf::from))
}

/// ACP bundle 默认禁用 LLM 标题；安装后追加启用 patch。
/// 已有显式条目时原样保留；解析错误不能含源文片段（profile 可能含凭据）。
pub fn ensure_title_plugin_enabled(plugin: &DshPlugin) -> Result<bool, String> {
    use serde_saphyr::granit_parser::{Event, Parser, StructureStyle};
    use std::io::Write;

    let path = profile_dir(&plugin.home).join("cordis.patch.yml");
    let mut existing = match std::fs::read_to_string(&path) {
        Ok(existing) => existing,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => String::new(),
        Err(error) => return Err(format!("cannot read {}: {error}", path.display())),
    };
    let invalid = || format!("invalid DSH ACP profile patch at {}", path.display());
    let patches: Option<Vec<Value>> = serde_saphyr::from_str(&existing).map_err(|_| invalid())?;
    if patches.as_ref().is_some_and(|patches| {
        patches
            .iter()
            .any(|patch| patch.get("id").and_then(Value::as_str) == Some("session-title-llm"))
    }) {
        return Ok(false);
    }
    // DSH 默认模板是 []；按序列边界插入，保留注释、格式与其它配置原文。
    let (mut offset, mut end) = (existing.len(), existing.len());
    let (mut depth, mut indent, mut value_end) = (0, 0, 0);
    let mut flow = false;
    for parsed in Parser::new_from_str(&existing) {
        let (event, span) = parsed.map_err(|_| invalid())?;
        match event {
            Event::SequenceStart(style, ..) => {
                if depth == 0 {
                    flow = style == StructureStyle::Flow;
                    indent = span.start.col();
                }
                depth += 1;
            }
            Event::SequenceEnd => {
                depth -= 1;
                if depth == 0 {
                    offset = span.start.byte_offset().ok_or_else(invalid)?;
                    end = offset;
                    break;
                }
            }
            Event::Scalar(..) if depth == 0 => {
                offset = span
                    .tag_start()
                    .unwrap_or(span.start)
                    .byte_offset()
                    .ok_or_else(invalid)?;
                end = span.end.byte_offset().ok_or_else(invalid)?;
                break;
            }
            _ => {}
        }
        if !matches!(event, Event::Comment(..)) {
            value_end = span.end.byte_offset().ok_or_else(invalid)?;
        }
    }
    let patch = if flow {
        let comma = patches.as_ref().is_some_and(|patches| !patches.is_empty())
            && !existing[value_end..offset].trim_start().starts_with(',');
        format!(
            "{}{{ id: session-title-llm, disabled: false }}",
            if comma { ", " } else { "" }
        )
    } else {
        format!(
            "\n{0}- id: session-title-llm\n{0}  disabled: false\n",
            " ".repeat(indent)
        )
    };
    existing.replace_range(offset..end, &patch);
    let _: Vec<Value> = serde_saphyr::from_str(&existing).map_err(|_| invalid())?;
    let mut file = tempfile::NamedTempFile::new_in(profile_dir(&plugin.home))
        .map_err(|error| format!("cannot stage {}: {error}", path.display()))?;
    if let Ok(metadata) = std::fs::metadata(&path) {
        file.as_file()
            .set_permissions(metadata.permissions())
            .map_err(|error| {
                format!(
                    "cannot preserve permissions for {}: {error}",
                    path.display()
                )
            })?;
    }
    file.write_all(existing.as_bytes())
        .map_err(|error| format!("cannot write {}: {error}", path.display()))?;
    file.persist(&path)
        .map_err(|error| format!("cannot replace {}: {error}", path.display()))?;
    Ok(true)
}

/// plugin 形态下 adapter 的凭据 gate 按 `<PROVIDER>_API_KEY` 推导名字，
/// 而 DSH 自定义 provider 使用 `apiKeyEnv`（例如 `MAGPIE_GATEWAY_KEY`）。
/// 这里从 `$DSH_HOME/.credentials.yaml` 的 `refs` 读取一次并映射成 adapter
/// 期望的名字，只注入子进程环境；不写盘、不记录值。
pub fn credential_env(plugin: &DshPlugin) -> std::collections::BTreeMap<String, String> {
    let path = plugin.home.join(".credentials.yaml");
    let Some(refs) = read_credential_refs(&path) else {
        return std::collections::BTreeMap::new();
    };
    let value = refs
        .get("MAGPIE_API_KEY")
        .or_else(|| refs.get("MAGPIE_GATEWAY_KEY"))
        .cloned();
    let Some(value) = value else {
        return std::collections::BTreeMap::new();
    };
    [
        "MAGPIE_API_KEY",
        "MAGPIE_RESPONSES_API_KEY",
        "MAGPIE_ANTHROPIC_API_KEY",
    ]
    .into_iter()
    .map(|name| (name.to_string(), value.clone()))
    .collect()
}

/// 只接受 owner-only 可读的凭据文件（mode 600/400），并只解析 `refs` 段。
pub fn read_credential_refs(path: &Path) -> Option<std::collections::BTreeMap<String, String>> {
    let metadata = std::fs::metadata(path).ok()?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if metadata.permissions().mode() & 0o077 != 0 {
            return None;
        }
    }
    let text = std::fs::read_to_string(path).ok()?;
    parse_credential_refs(&text)
}

fn parse_credential_refs(text: &str) -> Option<std::collections::BTreeMap<String, String>> {
    let mut refs = std::collections::BTreeMap::new();
    let mut in_refs = false;
    for line in text.lines() {
        if !(line.starts_with(' ') || line.starts_with('\t')) {
            in_refs = line.trim_end() == "refs:";
            continue;
        }
        if !in_refs {
            continue;
        }
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }
        let Some((key, value)) = trimmed.split_once(':') else {
            continue;
        };
        let key = key.trim();
        let value = value.trim().trim_matches(|ch| ch == '"' || ch == '\'');
        if key.is_empty() || value.is_empty() {
            continue;
        }
        refs.insert(key.to_string(), value.to_string());
    }
    (!refs.is_empty()).then_some(refs)
}

#[cfg(test)]
mod tests;
