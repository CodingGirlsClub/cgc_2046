//! 固定版本 npm agent 的持久安装路径与真实入口校验。

use std::path::{Component, PathBuf};

use crate::agent::launch::NodeRuntime;
use crate::registry::manifest::{AgentEntry, Distribution};

pub(crate) fn install_dir(entry: &AgentEntry, runtime: &NodeRuntime) -> PathBuf {
    runtime
        .root
        .parent()
        .unwrap_or(&runtime.root)
        .join("agents")
        .join(&entry.id)
        .join(match &entry.distribution {
            Distribution::Npx { version, .. } => version,
            Distribution::Native { .. } => &entry.minimum_version,
        })
}

pub(crate) fn executable_in(
    entry: &AgentEntry,
    directory: &std::path::Path,
) -> Result<PathBuf, String> {
    let Distribution::Npx {
        package, version, ..
    } = &entry.distribution
    else {
        return Err("native agent has no npm package".to_string());
    };
    let package_dir = directory.join("node_modules").join(package);
    let metadata: serde_json::Value = serde_json::from_slice(
        &std::fs::read(package_dir.join("package.json")).map_err(|error| error.to_string())?,
    )
    .map_err(|error| error.to_string())?;
    if metadata["name"].as_str() != Some(package) || metadata["version"].as_str() != Some(version) {
        return Err(format!(
            "installed {package} does not match pinned version {version}"
        ));
    }
    let bin = &metadata["bin"];
    let executable = bin
        .as_str()
        .or_else(|| {
            let entries = bin.as_object()?;
            entries
                .get(package.rsplit('/').next()?)
                .and_then(|value| value.as_str())
                .or_else(|| {
                    (entries.len() == 1)
                        .then(|| entries.values().next()?.as_str())
                        .flatten()
                })
        })
        .ok_or_else(|| format!("{package} has no unambiguous executable"))?;
    let relative = std::path::Path::new(executable);
    if relative.components().any(|part| {
        matches!(
            part,
            Component::ParentDir | Component::RootDir | Component::Prefix(_)
        )
    }) {
        return Err(format!("{package} executable escapes its package"));
    }
    let executable = package_dir
        .join(relative)
        .canonicalize()
        .map_err(|error| error.to_string())?;
    let package_dir = package_dir
        .canonicalize()
        .map_err(|error| error.to_string())?;
    if !executable.starts_with(&package_dir) || !executable.is_file() {
        return Err(format!(
            "{package} executable is missing or outside its package"
        ));
    }
    Ok(executable)
}

pub(crate) fn executable(entry: &AgentEntry, runtime: &NodeRuntime) -> Result<PathBuf, String> {
    executable_in(entry, &install_dir(entry, runtime))
}
