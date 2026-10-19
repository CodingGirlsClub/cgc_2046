# CGC Desktop

学员端原生桌面客户端（GPUI + gpui-kit，Rust）。架构与不变量见
`_bmad-output/initiative-desktop/architecture-desktop/architecture-desktop.md`（脊柱 AD-1 至 AD-24）
与 `docs/adr/0024-0027`。

## 本机前置

- Rust **1.92+**（`rust-toolchain.toml` 锁 1.92.0；本机可用已安装的更新版本，如 `RUSTUP_TOOLCHAIN=stable`）
- macOS 15+ / Windows 10+（MSVC + CMake 在 PATH）/ Ubuntu 24.04（Wayland 或 X11 会话 + Vulkan 驱动）
- Linux 额外依赖见 gpui-kit 安装文档

## 运行

```bash
cd desktop
cargo run -p cgc-desktop-app     # 打开主窗口（空态页）
cargo test -p cgc-desktop-app    # 路由注册表单测
cargo fmt --check
cargo clippy --workspace --all-targets -- -D warnings
```

## 目录与依赖方向（脊柱 AD-1）

```text
app/          入口、窗口、导航壳、路由聚合（唯一组合根）
features/     account / events / courses / companion；彼此零依赖
platform/     端口 trait（api / session / agent / registry / update / telemetry）
platform-os/  OS 适配器实现端口（通知 / 深链 / 单实例 / keychain / 进程）
```

`app → features → platform`，`platform-os → platform`；禁止 `platform → platform-os`，
禁止 feature 之间互相依赖。CI 在 1.13 建立后由依赖边界检查兜底。
