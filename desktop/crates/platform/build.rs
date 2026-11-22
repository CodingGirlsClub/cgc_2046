//! 发布构建的编译期默认值（内测包默认连真实后端）与版本元信息（ADR-0027）。
//!
//! 打包时由构建命令传入：
//! - `CGC_DEFAULT_API_URL`：默认 GraphQL 端点，进 `runtime::BUILD_DEFAULT_API_URL`
//! - `CGC_DEFAULT_ENV`：默认运行环境（`prod`），进 `runtime::BUILD_DEFAULT_ENV`
//! - `CGC_BUILD_VERSION`：客户端版本号（未注入时回退 `CARGO_PKG_VERSION`），进 `runtime::BUILD_VERSION`
//! - `CGC_BUILD_COMMIT`：源码 commit（未注入时回退 `git rev-parse --short HEAD`），进 `runtime::BUILD_COMMIT`
//!
//! 这里登记 rerun 触发条件：不登记的话改环境变量不会触发重编，包里的默认值会是旧的。

use std::env;
use std::path::Path;

fn non_empty_env(key: &str) -> Option<String> {
    env::var(key)
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

fn build_version() -> String {
    non_empty_env("CGC_BUILD_VERSION")
        .or_else(|| non_empty_env("CARGO_PKG_VERSION"))
        .unwrap_or_else(|| "0.0.0".to_string())
}

fn build_commit(manifest_dir: &str) -> String {
    if let Some(commit) = non_empty_env("CGC_BUILD_COMMIT") {
        return commit;
    }
    let repo = Path::new(manifest_dir).join("../../..");
    let output = std::process::Command::new("git")
        .args([
            "-C",
            &repo.to_string_lossy(),
            "rev-parse",
            "--short",
            "HEAD",
        ])
        .output();
    match output {
        Ok(output) if output.status.success() => {
            String::from_utf8_lossy(&output.stdout).trim().to_string()
        }
        _ => "unknown".to_string(),
    }
}

fn main() {
    for key in [
        "CGC_DEFAULT_API_URL",
        "CGC_DEFAULT_ENV",
        "CGC_BUILD_VERSION",
        "CGC_BUILD_COMMIT",
    ] {
        println!("cargo:rerun-if-env-changed={key}");
    }
    let manifest_dir = env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR");
    println!("cargo:rustc-env=CGC_BUILD_VERSION={}", build_version());
    println!(
        "cargo:rustc-env=CGC_BUILD_COMMIT={}",
        build_commit(&manifest_dir)
    );
}
