# desktop/（CGC Desktop 客户端）

GPUI + gpui-kit 的原生桌面客户端。组织方式对齐 Zed：`crates/` 下每个子系统一个 crate，
`app` 是唯一 binary crate（组合根）。架构不变量见仓库
`_bmad-output/initiative-desktop/architecture-desktop/architecture-desktop.md`（AD-1 至 AD-24）与
`docs/adr/0024-0027`；根 `AGENTS.md` 的许可、安全与人工合并规则同样适用。

## 硬约束

- **依赖方向（AD-1）**：`app → 各 domain crate → platform`、`platform-{macos,windows,linux} → platform`；domain crate 之间零依赖。OS 集成按 Zed 的 `gpui_platform` + `gpui_macos/linux/windows` 同构拆分，按 target 选择。
- **加功能规则**：默认加进已有 domain crate 的 module；只有「独立依赖面 / 被两个以上 crate 复用 / 需要并行隔离或独立发布」之一才新建 crate（Zed 的 `agent` 裂成 `agent_ui`/`agent_servers` 即此标准）。不要按功能清单建 crate。
- **工具链与版本**：Rust 1.92+；`gpui-kit` 0.7.3、`gpui-pre` 由 kit 钉死；**禁止直接依赖 crates.io 的 `gpui`**（会引入两份 GPUI）。
- **许可门禁**：新增依赖须与 AGPL-3.0 兼容；GPL-3.0 类先开 issue 人裁（`docs/开源合规/依赖引入规则.md`）。
- **敏感值**：token、对话内容、核销码、用户手机号不进日志/遥测/崩溃报告（AD-13/AD-16）。
- **人工合并**：`.github/**`、依赖锁文件（`Cargo.lock`）、根 `AGENTS.md` 的改动由人合并。

## 验收

- 每个 story 必须有自动化检查（单测 / 快照 / CI）；纯 GUI 行为在 macOS/Windows 真机与 epic-7 汇总回归里补。
- 本机命令：`cargo fmt --check`、`cargo clippy --workspace --all-targets -- -D warnings`、`cargo test --workspace`。
