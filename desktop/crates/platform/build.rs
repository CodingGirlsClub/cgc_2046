//! 发布构建的编译期默认值（内测包默认连真实后端）。
//!
//! 打包时由构建命令传入：
//! - `CGC_DEFAULT_API_URL`：默认 GraphQL 端点，进 `runtime::BUILD_DEFAULT_API_URL`
//! - `CGC_DEFAULT_ENV`：默认运行环境（`prod`），进 `runtime::BUILD_DEFAULT_ENV`
//!
//! 未注入时两者都是 `None`，行为与历史一致（本机开发端点 + dev 数据根）。
//! 这里只登记 rerun 触发条件：不登记的话改环境变量不会触发重编，包里的默认值会是旧的。

fn main() {
    for key in ["CGC_DEFAULT_API_URL", "CGC_DEFAULT_ENV"] {
        println!("cargo:rerun-if-env-changed={key}");
    }
}
