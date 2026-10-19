# CGC Desktop

学员端原生桌面客户端（GPUI + gpui-kit，Rust）。组织方式对齐 Zed：**每个子系统一个 crate
平铺在 `crates/` 下，`app` 是唯一 binary crate（组合根）**。架构与不变量见
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
cargo test --workspace           # 路由注册表与各 crate 单测
cargo fmt --check
cargo clippy --workspace --all-targets -- -D warnings
```

## 目录与依赖方向（脊柱 AD-1）

```text
crates/
  app/          入口、窗口、导航壳、路由聚合（唯一 binary crate / 组合根）
  account/      登录注册、工作台、设置
  events/       场次、报名、支付、核销码
  courses/      课程目录、学习页、正文渲染
  agent_chat/   学习搭子对话、agent 选择
  platform/     端口 trait（api / session / agent / registry / update / telemetry）
  platform-macos/   macOS 的 OS 适配器（通知/深链/单实例/托盘/keychain/进程）
  platform-windows/ Windows 的 OS 适配器
  platform-linux/   Linux 的 OS 适配器
```

`app → 各 domain crate → platform`，`platform-{macos,windows,linux} → platform`；禁止 `platform → platform-*`，
禁止 domain crate 之间互相依赖。加功能的默认落点是已有 domain crate 的 module；
只有「独立依赖面 / 被两个以上 crate 复用 / 需要并行隔离或独立发布」之一才新建 crate。
CI 在 1.13 建立后由依赖边界检查兜底。
