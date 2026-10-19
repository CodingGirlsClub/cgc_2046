# CGC Desktop

学员端原生桌面客户端（GPUI + gpui-kit，Rust）。组织方式对齐 Zed：**每个子系统一个 crate
平铺在 `crates/` 下，`app` 是唯一 binary crate（组合根）**。架构与不变量见
`_bmad-output/initiative-desktop/architecture-desktop/architecture-desktop.md`（脊柱 AD-1 至 AD-24）
与 `docs/adr/0024-0027`。

## 本机前置

- Rust **1.98+**（`rust-toolchain.toml` 锁 1.98.1；本机可用已安装的更新版本，如 `RUSTUP_TOOLCHAIN=stable`）
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

## CI 与打包（story 1.13）

- CI：`.github/workflows/ci.yml` 的 `desktop` job，三平台 matrix（`macos-15` / `windows-2022` / `ubuntu-24.04`），跑 `fmt` / `clippy -D warnings` / `test` / release build / cargo-packager。
- 打包格式：macOS `dmg`，Windows `wix`（产物 `.msi`），Linux `deb,appimage`；产物在 `desktop/dist/`。
- 本地复现：

```bash
cd desktop
cargo install cargo-packager --locked --version =0.11.8
cargo packager -p cgc-desktop-app --release -f dmg     # macOS；Windows 用 -f wix，Linux 用 -f deb,appimage
bash scripts/verify-package.sh                          # Windows: pwsh scripts/verify-package.ps1
```

- 产物未签名：证书暂无（ADR-0027 决策 2/3），签名、公证与自动更新归 epic-6（`epic-distribution-integration`）。
- macOS 产物为 runner 原生架构（arm64）；x86_64 与 universal 留给 epic-6/7。
