//! DSH plugin 形态探测（ADR-0030 D1 修订）：有 DSH Desktop 时优先
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
    if let Some(path) = env("DSH_CLI").filter(|path| path.is_file()) {
        return Some(path);
    }
    if let Some(path) = env("PATH").and_then(|path| {
        std::env::split_paths(&path)
            .map(|dir| dir.join("dsh"))
            .find(|candidate| candidate.is_file())
    }) {
        return Some(path);
    }
    env("HOME")
        .map(|home| home.join(".local/bin/dsh"))
        .filter(|path| path.is_file())
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn temp_dir(tag: &str) -> PathBuf {
        use std::sync::atomic::{AtomicU64, Ordering};
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let dir = std::env::temp_dir().join(format!(
            "cgc-dsh-plugin-{}-{tag}-{}",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("temp dir");
        dir
    }

    fn write_profile(home: &Path, version: &str) {
        let profile = profile_dir(home);
        std::fs::create_dir_all(&profile).expect("profile dir");
        std::fs::write(
            profile.join("package.json"),
            format!(
                r#"{{"name":"dsh-profile-acp","dependencies":{{"{DSH_PLUGIN_PACKAGE}":"{version}"}}}}"#
            ),
        )
        .expect("package.json");
    }

    fn env_with(pairs: &[(&str, PathBuf)]) -> HashMap<String, PathBuf> {
        pairs
            .iter()
            .map(|(key, value)| (key.to_string(), value.clone()))
            .collect()
    }

    #[test]
    fn probe_requires_dsh_cli_and_installed_profile() {
        let root = temp_dir("probe");
        let home = root.join("dsh-home");
        let dsh = root.join("bin").join("dsh");
        std::fs::create_dir_all(dsh.parent().unwrap()).unwrap();
        std::fs::write(&dsh, b"#!/bin/sh\n").unwrap();
        let env = env_with(&[("DSH_HOME", home.clone()), ("DSH_CLI", dsh.clone())]);

        let read = |key: &str| env.get(key).cloned();
        assert_eq!(probe_with(read), None, "profile 未安装时不能算 plugin 可用");

        write_profile(&home, "0.4.41");
        assert_eq!(
            probe_with(read),
            Some(DshPlugin {
                dsh,
                home,
                version: "0.4.41".to_string(),
            })
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn probe_falls_back_to_local_bin_and_home_dot_dsh() {
        let root = temp_dir("fallback");
        let home = root.join("user");
        let dsh = home.join(".local").join("bin").join("dsh");
        std::fs::create_dir_all(dsh.parent().unwrap()).unwrap();
        std::fs::write(&dsh, b"#!/bin/sh\n").unwrap();
        write_profile(&home.join(".dsh"), "0.4.41");
        let env = env_with(&[("HOME", home.clone())]);
        let read = |key: &str| env.get(key).cloned();

        let plugin = probe_with(read).expect("plugin via ~/.local/bin/dsh");
        assert_eq!(plugin.dsh, dsh);
        assert_eq!(plugin.home, home.join(".dsh"));
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn malformed_profile_fails_closed() {
        let root = temp_dir("malformed");
        let home = root.join("dsh-home");
        let dsh = root.join("dsh");
        std::fs::write(&dsh, b"#!/bin/sh\n").unwrap();
        std::fs::create_dir_all(profile_dir(&home)).unwrap();
        std::fs::write(profile_dir(&home).join("package.json"), "{not json").unwrap();
        let env = env_with(&[("DSH_HOME", home), ("DSH_CLI", dsh)]);
        let read = |key: &str| env.get(key).cloned();
        assert_eq!(probe_with(read), None);
        let _ = std::fs::remove_dir_all(&root);
    }
}
