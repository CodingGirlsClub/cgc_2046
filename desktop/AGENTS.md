# desktop/（CGC Desktop 客户端）

GPUI + gpui-kit 的原生桌面客户端。组织方式对齐 Zed：`crates/` 下每个子系统一个 crate，
`app` 是唯一 binary crate（组合根）。架构不变量见仓库
`_bmad-output/initiative-desktop/architecture-desktop/architecture-desktop.md`（AD-1 至 AD-24）与
`docs/adr/0024-0028`；根 `AGENTS.md` 的许可、安全与人工合并规则同样适用。

> 状态提示（2026-10-25）：ADR-0028 已转 **Accepted**，决策 2/3/6/11 同日修订（双轨长期、
> 共享客户端会话模型与 `agent_ui`、MCP 客户端资产 + v1 平台租赁、Git 仅 checkpoint 前提）。
> 架构脊柱 `_bmad-output/.../architecture-desktop.md` 的 AD-4/AD-5/AD-15/AD-16/AD-17 仍按
> 「仅 ACP」描述，且该目录被本地 git exclude，修订需人工同步。分析见
> `docs/plans/2026-10-25-1305-zed-agent-architecture-reference.md`。

## 硬约束

- **依赖方向（AD-1）**：`app → 各 domain crate → platform`、`platform-{macos,windows,linux} → platform`；domain crate 之间零依赖。OS 集成按 Zed 的 `gpui_platform` + `gpui_macos/linux/windows` 同构拆分，按 target 选择。
- **加功能规则**：默认加进已有 domain crate 的 module；只有「独立依赖面 / 被两个以上 crate 复用 / 需要并行隔离或独立发布」之一才新建 crate（Zed 的 `agent` 裂成 `agent_ui`/`agent_servers` 即此标准）。不要按功能清单建 crate。
- **工具链与版本**：Rust 1.98+；`gpui-kit` 0.8.0、`gpui-pre` 由 kit 钉死；**禁止直接依赖 crates.io 的 `gpui`**（会引入两份 GPUI）。
- **许可门禁**：新增依赖须与 AGPL-3.0 兼容；GPL-3.0 类先开 issue 人裁（`docs/开源合规/依赖引入规则.md`）。
- **敏感值**：token、对话内容、核销码、用户手机号不进日志/遥测/崩溃报告（AD-13/AD-16）。
- **人工合并**：`.github/**`、依赖锁文件（`Cargo.lock`）、根 `AGENTS.md` 的改动由人合并。

## 验收

- 每个 story 必须有自动化检查（单测 / 快照 / CI）；纯 GUI 行为在 macOS/Windows 真机与 epic-7 汇总回归里补。
- 本机命令：`cargo fmt --check`、`cargo clippy --workspace --all-targets -- -D warnings`、`cargo test --workspace`。

## 模块地图（对齐 Zed）

| 位置 | Zed 对应 | 职责 |
| --- | --- | --- |
| `crates/agent_ui` | `agent_ui` 的子集 | 课程页对话面板、会话视图、审批卡、历史、每 agent 设置（当前仍多为 doc 桩） |
| `crates/platform/src/acp` | `acp_thread` | 协议/连接/会话/审批桥 |
| `crates/platform/src/agent` | `agent_servers` | 探测、启动、进程生命周期 |
| `crates/platform/src/registry` | `agent_servers` 的安装部分 | 清单、checksum、安装 |
| `crates/platform/src/mcp` | `context_server`（简化） | MCP 注入与 lease |
| `crates/agent_provider` / `agent_core` / `agent_tools` / `agent_store` / `agent_checkpoint` / `agent_host` | `agent`（native 运行时） | 第一方 native agent：provider、turn loop、工具与审批、会话/偏好存储、Git checkpoint、事件归约 |
| `crates/app/src/native_agent_view.rs` | `agent_ui`（native 面板） | native 对话面板；与 ACP 面板共用 `agent_ui::message_flow` 的消息流判定 |

双轨形态（ADR-0028）：native 是默认学习 agent，external ACP agent 保留为高级模式；`provider`/`tools`/沙箱/checkpoint
存储归 native，MCP/registry/安装引导归 ACP，**不要为「统一」合并这些运行时能力**。
两套对话 UI 允许保留，但消息操作栏/复制/滚动定位等**行为判定必须共用 `agent_ui::message_flow`**，
纯文本转换共用 `agent_ui::markdown_text`，不要在任一视图里另写一份。
拆 crate 的门槛：出现第二个消费者（如全局助手）、独立依赖面、或需要并行隔离时才拆；否则先在 crate 内加 module。
