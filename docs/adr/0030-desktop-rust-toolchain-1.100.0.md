---
status: accepted
date: 2026-11-15
---

# ADR-0030：桌面客户端工具链升到 Rust 1.100.0（MSRV 不变）

> 日期：2026-11-15 ｜ 状态：**已接受（Accepted）** ｜ 决策者：用户（product owner）
> 关联：ADR-0024（桌面技术栈，工具链 1.98.1 的选型依据）

## 背景（Context）

ADR-0024 以实测为依据把工具链固定在 1.98.1：`gpui-pre 0.3.9` 用到 `slice_as_array`（1.94 稳定）与 `cold_path`（1.95 稳定），1.92 / 1.94 上分别以 E0658 失败。该结论只在 1.98.1 上做过 fmt / clippy / test / 打包四关验证。

Rust **1.100.0** 于 2026-11-09 发布，成为 stable 通道当前版本（本机 stable 通道从 1.98.1 直跳 1.100.0，1.99 为过站）。继续钉 1.98.1 的代价是本地与 CI 落后两个 stable 周期，且 `rustup` 每次进入其他项目都会被提示更新，容易诱发非受控升级。

本 ADR 只解决**工具链版本**；gpui-kit / gpui-pre 快照升级是独立决策（见"后续"）。

## 决策（Decision）

1. `desktop/rust-toolchain.toml` 的 `channel` 由 `1.98.1` 改为 **`1.100.0`**；`.github/workflows/ci.yml`、`.github/workflows/desktop-release.yml` 的 `toolchain` 输入、`desktop/scripts/smoke.sh` 的默认 `RUSTUP_TOOLCHAIN`、`desktop/README.md` 的版本说明同步更新。
2. **`desktop/Cargo.toml` 的 `rust-version = "1.98"` 保持不变**。工具链升级不等于抬 MSRV：该字段参与 cargo resolver 的依赖版本筛选，抬高它会静默放宽可解析依赖的 MSRV，需单独的兼容性评估。
3. **gpui-kit 保持 `=0.9.0`**（gpui-pre 0.3.11）。本次不混入任何依赖升级，保证失败可归因。（**2026-11-22 补记**：工具链升级合入后，后续独立分支已完成 `gpui-kit 0.9.0 → =0.9.1` 升级，底层 `gpui-pre 0.3.12`，见 `desktop/Cargo.toml`。）
4. 本地前置不变：`cargo` 经 mbx 路由，按 `rust-toolchain.toml` 选 toolchain；`RUSTUP_TOOLCHAIN` 未设时 rustup 用 `default`（本机 1.98.1），进入本仓库即被 pin 覆盖为 1.100.0。

## 依据

- `gpui-pre 0.3.11` 无 `#![feature]`，纯 stable；其用到的最高稳定项是 `std::hint::cold_path`（1.95），未使用 1.99 / 1.100 才稳定的 API（`!` never type、`DropGuard`、`conjure_zst` 等）。Rust 保证向后兼容，1.100.0 满足其下限。
- gpui-kit 上游未声明 MSRV（crates.io `rust_version` 为空、仓库无 `rust-toolchain.toml`、workspace 无 `rust-version`），其 CI 使用未指定版本的 `setup-rust-toolchain`，即 runner 的最新 stable——1.100.0 属其日常测试面。

## 验证（本 ADR 落地的门槛）

在 `chore/rust-1.100.0` 分支、macOS arm64、1.100.0 上依次通过：

| 关卡 | 命令 | 结果 |
|---|---|---|
| fmt | `cargo fmt --all -- --check` | **通过**（rustfmt 1.11.0-stable，无 diff） |
| clippy | `cargo clippy --workspace --all-targets -- -D warnings` | **通过**：0 errors；13 条警告全部是 Cargo 1.100 新增的 `unused-dependencies`，不是 clippy lint，`-D warnings` 不作用于 Cargo lint |
| test | `cargo test --workspace` | **通过**：82 个 test binary 全绿。首次运行有 1 个偶发失败（`restart_recovery_tests::instance_lock_rejects_a_second_holder`，断言"释放后可以接管"），单线程连跑 5 次全过、全量复跑全过 → 判定为 macOS 文件锁时序 flaky，与 1.100 无关（该测试由 `eaae57ae` 新引入，仓库已有 #1247 消除 flaky 门禁噪音的先例） |
| 打包 | `cargo packager -p cgc-desktop-app --release -f dmg` | **通过**（已随 Desktop Release workflow 与 `desktop-v0.1.0-dev.*` 内测发布验证） |

三平台（macOS universal / Windows wix / Linux deb）由 CI 的 `desktop` job 覆盖。

## 1.100 带来的、需要在升级时一并确认的行为

1. **never type fallback 变了**：1.100 把 2015/2018/2021 的 fallback 从 `()` 改为 `!`（2024 本来如此）。本项目 workspace 是 `edition = "2021"`，所以**升级编译器即受影响，不必改 edition**。风险形态是泛型参数在"丢弃发散表达式结果"处的推断变化；`dependency_on_unit_never_type_fallback` lint 已在 1.100 移除，allow 它无效。全 workspace 的 fmt/clippy/test 是这一项的验证手段。
2. **Cargo 报未使用依赖**（`cargo::unused_dependencies`，默认 `warn`）：本仓库首次构建出现 13 条，集中在 `Cargo.toml` 的 workspace 依赖表与 `platform-{macos,windows,linux}` 对 `cgc-platform` 的引用。本仓库没有 `[lints]` 段，因此不会升级为 error、不阻塞 CI；是否清理列为后续（清理 workspace 依赖表会影响后续新增 crate 的引用方式，需单独评估）。
3. **Cargo build-dir 布局 V2**：1.100 把构建中间产物按 build step 组织并把配置 hash 移到父目录，官方说明可能破坏依赖旧布局的构建流程。本机经 mbx 路由，mbx 1.29.2 的 CHANGELOG 已记录「support Cargo 1.100's build layout」，无兼容问题；建议同时升到 1.30.0（见下）。
4. **`Infallible` 成为 `!` 的别名**、`Vec::into_parts`/`Box::into_non_null` 等稳定：均向后兼容，本仓库未使用相关形态。
5. **Cargo `min-publish-age`**（新可选）：可通过 `.cargo/config.toml` 的 `[registry] global-min-publish-age = "3 days"` 开启依赖冷却。属供应链加固选项，本 ADR 不默认开启，避免改变 `cargo update` 的解析行为。

### 该升级但不在本分支的项

- **mbx 1.29.2 → 1.30.0**（2026-11-09）：修 macOS/noatime 下按真实使用排序淘汰（本机 doctor 的 atime 警告问题）、Cargo 新版「emptied output directories」下的 workspace crate 增量恢复、以及 GC 保留运行中 target。属工具升级，与本分支的版本号改动互不依赖。
- **`Swatinem/rust-cache@v2`**：无需改动。`v2` 浮动 tag 已于 2026-10-20 指向 2.9.3，其中 2.9.2 起支持 Cargo V2 build-dir 布局。若追求可复现，可钉 `@v2.9.3`。
- **`cargo-packager` 0.11.8**：发布于 2025-11，早于 Cargo 1.100；但它只读 `cargo metadata` 的 `target_directory` 与 uplift 后的产物（`target/<profile>/`），不解析 build-dir，预期不受布局变化影响。仍需一次真实 dmg 打包验证。

## 影响与回退

- 升级的主要失败面是我们自己的代码：1.100 的 rustfmt 输出变化会让 `fmt --check` 变红；clippy 新增 lint 会让 `-D warnings` 变红。两类问题都在本仓库内修复，不涉及依赖。
- 回退成本一行：把 `rust-toolchain.toml` 与两个 workflow 的版本号改回 `1.98.1` 即可，无需改 `Cargo.lock`。
- 本机已设 `RUSTUP_AUTO_INSTALL=0`：进入 pin 了未安装版本的项目会报错而非静默下载，安装是显式动作。

## 后续（不在本 ADR 范围）

- **gpui-kit 0.9.0 → 0.9.1**：patch 级，但默认 backend 由 gpui-pre 0.3.11 换到 0.3.12（源码差 14 个文件，taffy 仍 0.15.0）。`desktop/Cargo.toml` 的注释要求补丁版升级也做三平台真机回归，需单独分支与窗口。（**2026-11-22 补记**：已落地，`desktop/Cargo.toml` 现钉死 `gpui-kit = "=0.9.1"`，`desktop/Cargo.lock` 已切至 `gpui-pre 0.3.12`。）
- **MSRV 是否抬到 1.100**：等确认没有需要回到 1.98 的场景后再评估。
