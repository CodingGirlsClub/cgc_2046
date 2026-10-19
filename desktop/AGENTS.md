# desktop/（CGC Desktop 客户端）

GPUI + gpui-kit 的原生桌面客户端。架构不变量见仓库 `_bmad-output/initiative-desktop/architecture-desktop/architecture-desktop.md`（AD-1 至 AD-24）与 `docs/adr/0024-0027`；根 `AGENTS.md` 的许可、安全与人工合并规则同样适用。

## 硬约束

- **依赖方向（AD-1）**：`app → features → platform`、`platform-os → platform`；feature 之间零依赖。新增 crate 前先确认边。
- **工具链与版本**：Rust 1.92+；`gpui-kit` 0.7.3、`gpui-pre` 由 kit 钉死；**禁止直接依赖 crates.io 的 `gpui`**（会引入两份 GPUI）。
- **许可门禁**：新增依赖须与 AGPL-3.0 兼容；GPL-3.0 类先开 issue 人裁（`docs/开源合规/依赖引入规则.md`）。
- **敏感值**：token、对话内容、核销码、用户手机号不进日志/遥测/崩溃报告（AD-13/AD-16）。
- **人工合并**：`.github/**`、依赖锁文件（`Cargo.lock` 首次引入后）、根 `AGENTS.md` 的改动由人合并。

## 验收

- 每个 story 必须有自动化检查（单测 / 快照 / CI）；纯 GUI 行为在 macOS/Windows 真机与 epic-7 汇总回归里补。
- 本机命令：`cargo fmt --check`、`cargo clippy --workspace --all-targets -- -D warnings`、`cargo test --workspace`。
