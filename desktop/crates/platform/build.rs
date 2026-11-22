//! 发布构建的编译期默认值与版本标识（内测包默认连真实后端）。
//!
//! 打包时由构建命令传入：
//! - `CGC_DEFAULT_API_URL`：默认 GraphQL 端点，进 `runtime::BUILD_DEFAULT_API_URL`
//! - `CGC_DEFAULT_ENV`：默认运行环境（`prod`），进 `runtime::BUILD_DEFAULT_ENV`
//! - `CGC_BUILD_VERSION`：客户端 SemVer 版本号（未传入时回退 `CARGO_PKG_VERSION`），进
//!   `runtime::client_version()`，与 `app::build_info::VERSION` 同源。
//!
//! 这里登记 rerun 与 `rustc-env`：不登记的话改环境变量不会触发重编。

fn main() {
    for key in [
        "CGC_DEFAULT_API_URL",
        "CGC_DEFAULT_ENV",
        "CGC_BUILD_VERSION",
    ] {
        println!("cargo:rerun-if-env-changed={key}");
    }
    let version = std::env::var("CGC_BUILD_VERSION")
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .or_else(|| {
            std::env::var("CARGO_PKG_VERSION")
                .ok()
                .map(|value| value.trim().to_string())
                .filter(|value| !value.is_empty())
        })
        .unwrap_or_else(|| "0.0.0".to_string());
    let target_os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_else(|_| "unknown".to_string());
    let target_arch =
        std::env::var("CARGO_CFG_TARGET_ARCH").unwrap_or_else(|_| "unknown".to_string());
    println!("cargo:rustc-env=CGC_BUILD_VERSION={version}");
    println!("cargo:rustc-env=CGC_CLIENT_PLATFORM={target_os}-{target_arch}");
}
