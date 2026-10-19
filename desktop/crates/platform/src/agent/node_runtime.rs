//! 客户端管理的 Node.js 24 LTS runtime（story 5.9）。
//!
//! 固定版本 + 平台产物 checksum（nodejs.org SHASUMS256）；下载 → SHA-256 校验 → 解压到
//! 客户端数据目录。Codex / Claude Code 的 npx 适配器只从这里启动，不用用户 PATH 的 node。
//! 无网络/校验失败时 fail-closed，不执行未校验的归档。

use std::path::{Path, PathBuf};

use crate::registry::checksum::{sha256_hex, verify_sha256};

pub const NODE_VERSION: &str = "24.22.0";
pub const NODE_BASE_URL: &str = "https://nodejs.org/dist";

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NodeArtifact {
    pub file_name: String,
    pub sha256: String,
}

impl NodeArtifact {
    pub fn url(&self) -> String {
        format!("{NODE_BASE_URL}/v{NODE_VERSION}/{}", self.file_name)
    }
}

/// 当前平台的固定产物与 checksum（取自 nodejs.org SHASUMS256）。
pub fn current_artifact() -> Option<NodeArtifact> {
    let (file_name, sha256) = if cfg!(target_os = "macos") && cfg!(target_arch = "aarch64") {
        (
            "node-v24.22.0-darwin-arm64.tar.xz",
            "75ddfb875bbd868ebe57536f4442225f54dd10f6d2178dd439de869a5c648dc3",
        )
    } else if cfg!(target_os = "macos") && cfg!(target_arch = "x86_64") {
        (
            "node-v24.22.0-darwin-x64.tar.xz",
            "b890d687983ddc811641f6739c3ce99d2912c58f9e44b68aa25944037b425305",
        )
    } else if cfg!(target_os = "linux") && cfg!(target_arch = "x86_64") {
        (
            "node-v24.22.0-linux-x64.tar.xz",
            "cc2f601cee82d9a5a233302fe307abc600727035fd7d2c3a3571755989e95008",
        )
    } else if cfg!(target_os = "linux") && cfg!(target_arch = "aarch64") {
        (
            "node-v24.22.0-linux-arm64.tar.xz",
            "fef00bb4d36e1c50104a9775a10359beee98f162b4104dd12472c75065c6a143",
        )
    } else if cfg!(target_os = "windows") && cfg!(target_arch = "x86_64") {
        (
            "node-v24.22.0-win-x64.zip",
            "f9683a19877e12a9b167305c8db71040d812876359de21f0d2e97c3f321f80c3",
        )
    } else {
        return None;
    };
    Some(NodeArtifact {
        file_name: file_name.to_string(),
        sha256: sha256.to_string(),
    })
}

/// runtime 根目录：`<data>/node24`，其下含 `bin/node`、`bin/npx`。
pub fn default_root() -> PathBuf {
    let base = if cfg!(target_os = "macos") {
        std::env::var_os("HOME")
            .map(|home| PathBuf::from(home).join("Library/Application Support/cgc-desktop"))
    } else if cfg!(target_os = "windows") {
        std::env::var_os("APPDATA").map(|base| PathBuf::from(base).join("cgc-desktop"))
    } else {
        std::env::var_os("XDG_DATA_HOME")
            .map(PathBuf::from)
            .or_else(|| {
                std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".local/share"))
            })
            .map(|base| base.join("cgc-desktop"))
    };
    base.unwrap_or_else(std::env::temp_dir).join("node24")
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RuntimeStatus {
    Missing,
    Installed { version: String },
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RuntimeError {
    UnsupportedPlatform,
    Download(String),
    ChecksumMismatch { expected: String, actual: String },
    Extract(String),
    Io(String),
}

impl std::fmt::Display for RuntimeError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RuntimeError::UnsupportedPlatform => {
                formatter.write_str("unsupported platform for managed node runtime")
            }
            RuntimeError::Download(reason) => write!(formatter, "download failed: {reason}"),
            RuntimeError::ChecksumMismatch { expected, actual } => {
                write!(
                    formatter,
                    "node checksum mismatch: expected {expected}, got {actual}"
                )
            }
            RuntimeError::Extract(reason) => write!(formatter, "extract failed: {reason}"),
            RuntimeError::Io(reason) => write!(formatter, "io error: {reason}"),
        }
    }
}

impl std::error::Error for RuntimeError {}

pub trait Downloader {
    fn fetch(&self, url: &str) -> Result<Vec<u8>, String>;
}

pub struct HttpDownloader;

impl Downloader for HttpDownloader {
    /// 用系统 curl 下载：天然继承系统代理设置（企业 Clash 等）与 TLS 信任；
    /// 大小上限由 curl `--max-filesize` 约束，checksum 在调用方校验。
    fn fetch(&self, url: &str) -> Result<Vec<u8>, String> {
        let output = std::process::Command::new("curl")
            .args([
                "-fsSL",
                "--max-time",
                "300",
                "--max-filesize",
                "268435456",
                url,
            ])
            .output()
            .map_err(|error| format!("cannot run curl: {error}"))?;
        if !output.status.success() {
            return Err(format!(
                "curl exited with {}: {}",
                output.status,
                String::from_utf8_lossy(&output.stderr).trim()
            ));
        }
        Ok(output.stdout)
    }
}

pub struct NodeRuntimeManager {
    pub root: PathBuf,
    pub artifact: Option<NodeArtifact>,
}

impl NodeRuntimeManager {
    pub fn default_manager() -> Self {
        Self {
            root: default_root(),
            artifact: current_artifact(),
        }
    }

    pub fn status(&self) -> RuntimeStatus {
        let node = self.root.join("bin/node");
        let npx = self.root.join("bin/npx");
        if node.is_file() && npx.is_file() {
            RuntimeStatus::Installed {
                version: NODE_VERSION.to_string(),
            }
        } else {
            RuntimeStatus::Missing
        }
    }

    /// 已安装则返回启动计划可消费的 runtime。
    pub fn installed_runtime(&self) -> Option<crate::agent::launch::NodeRuntime> {
        matches!(self.status(), RuntimeStatus::Installed { .. })
            .then(|| crate::agent::launch::NodeRuntime::new(&self.root))
    }

    /// 下载 + 校验 + 解压；全程不执行归档内任何脚本，解压后仅保留 runtime 目录。
    pub fn install(&self, downloader: &dyn Downloader) -> Result<(), RuntimeError> {
        let artifact = self
            .artifact
            .as_ref()
            .ok_or(RuntimeError::UnsupportedPlatform)?;
        let bytes = downloader
            .fetch(&artifact.url())
            .map_err(RuntimeError::Download)?;
        let actual = sha256_hex(&bytes);
        if !verify_sha256(&bytes, &artifact.sha256) {
            return Err(RuntimeError::ChecksumMismatch {
                expected: artifact.sha256.clone(),
                actual,
            });
        }
        self.install_verified_archive(&bytes, &artifact.file_name)
    }

    fn install_verified_archive(&self, bytes: &[u8], file_name: &str) -> Result<(), RuntimeError> {
        let parent = self
            .root
            .parent()
            .map(Path::to_path_buf)
            .unwrap_or_else(std::env::temp_dir);
        std::fs::create_dir_all(&parent).map_err(|error| RuntimeError::Io(error.to_string()))?;
        let staging = parent.join(format!(
            ".node-staging-{}-{}",
            std::process::id(),
            file_name.replace('.', "-")
        ));
        let _ = std::fs::remove_dir_all(&staging);
        std::fs::create_dir_all(&staging).map_err(|error| RuntimeError::Io(error.to_string()))?;
        let archive = staging.join(file_name);
        std::fs::write(&archive, bytes).map_err(|error| RuntimeError::Io(error.to_string()))?;

        let status = if file_name.ends_with(".zip") {
            std::process::Command::new("tar")
                .args([
                    "-xf",
                    &archive.to_string_lossy(),
                    "-C",
                    &staging.to_string_lossy(),
                ])
                .status()
        } else {
            std::process::Command::new("tar")
                .args([
                    "-xJf",
                    &archive.to_string_lossy(),
                    "-C",
                    &staging.to_string_lossy(),
                ])
                .status()
        }
        .map_err(|error| RuntimeError::Extract(error.to_string()))?;
        if !status.success() {
            let _ = std::fs::remove_dir_all(&staging);
            return Err(RuntimeError::Extract(format!("tar exited with {status}")));
        }

        let extracted = std::fs::read_dir(&staging)
            .map_err(|error| RuntimeError::Io(error.to_string()))?
            .filter_map(Result::ok)
            .map(|entry| entry.path())
            .find(|path| path.is_dir())
            .ok_or_else(|| RuntimeError::Extract("no extracted directory".to_string()))?;
        let _ = std::fs::remove_dir_all(&self.root);
        std::fs::rename(&extracted, &self.root)
            .map_err(|error| RuntimeError::Io(error.to_string()))?;
        let _ = std::fs::remove_dir_all(&staging);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct FakeDownloader {
        bytes: Vec<u8>,
        fail: bool,
    }

    impl Downloader for FakeDownloader {
        fn fetch(&self, _url: &str) -> Result<Vec<u8>, String> {
            if self.fail {
                return Err("offline".to_string());
            }
            Ok(self.bytes.clone())
        }
    }

    struct ArchiveDownloader {
        bytes: Vec<u8>,
    }

    impl Downloader for ArchiveDownloader {
        fn fetch(&self, _url: &str) -> Result<Vec<u8>, String> {
            Ok(self.bytes.clone())
        }
    }

    fn manager(dir: &Path) -> NodeRuntimeManager {
        NodeRuntimeManager {
            root: dir.join("node24"),
            artifact: Some(NodeArtifact {
                file_name: "fake.tar.xz".to_string(),
                sha256: sha256_hex(b"expected"),
            }),
        }
    }

    #[test]
    fn pinned_artifact_matches_platform() {
        let artifact = current_artifact().expect("supported platform in test");
        assert!(artifact.file_name.contains(NODE_VERSION));
        assert_eq!(artifact.sha256.len(), 64);
        assert!(artifact.url().starts_with("https://nodejs.org/dist/v24."));
    }

    #[test]
    fn checksum_mismatch_fails_closed_without_writing_runtime() {
        let dir = std::env::temp_dir().join(format!("cgc-node-test-{}", std::process::id()));
        let manager = manager(&dir);
        let downloader = FakeDownloader {
            bytes: b"tampered".to_vec(),
            fail: false,
        };
        let error = manager.install(&downloader).unwrap_err();
        assert!(matches!(error, RuntimeError::ChecksumMismatch { .. }));
        assert_eq!(manager.status(), RuntimeStatus::Missing);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn download_failure_is_reported() {
        let dir = std::env::temp_dir().join(format!("cgc-node-offline-{}", std::process::id()));
        let manager = manager(&dir);
        let downloader = FakeDownloader {
            bytes: Vec::new(),
            fail: true,
        };
        assert!(matches!(
            manager.install(&downloader).unwrap_err(),
            RuntimeError::Download(_)
        ));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn verified_tar_xz_is_extracted_into_root() {
        let dir = std::env::temp_dir().join(format!("cgc-node-ok-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("mkdir");
        // 先构造一个最小 tar.xz：node-vX/bin/node、bin/npx。
        let source = dir.join("source");
        std::fs::create_dir_all(source.join("node-v24.22.0-test/bin")).expect("src");
        std::fs::write(source.join("node-v24.22.0-test/bin/node"), b"#!/bin/sh\n").expect("node");
        std::fs::write(source.join("node-v24.22.0-test/bin/npx"), b"#!/bin/sh\n").expect("npx");
        let tar_path = dir.join("fake.tar");
        let status = std::process::Command::new("tar")
            .args([
                "-cf",
                &tar_path.to_string_lossy(),
                "-C",
                &source.to_string_lossy(),
                "node-v24.22.0-test",
            ])
            .status()
            .expect("tar");
        assert!(status.success());
        let xz_path = dir.join("fake.tar.xz");
        let status = std::process::Command::new("xz")
            .args(["-c", &tar_path.to_string_lossy()])
            .output()
            .expect("xz");
        std::fs::write(&xz_path, status.stdout).expect("xz write");
        let bytes = std::fs::read(&xz_path).expect("read");
        let manager = NodeRuntimeManager {
            root: dir.join("node24"),
            artifact: Some(NodeArtifact {
                file_name: "fake.tar.xz".to_string(),
                sha256: sha256_hex(&bytes),
            }),
        };
        manager
            .install(&ArchiveDownloader { bytes })
            .expect("install");
        assert_eq!(
            manager.status(),
            RuntimeStatus::Installed {
                version: NODE_VERSION.to_string()
            }
        );
        assert!(manager.installed_runtime().is_some());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
