---
status: accepted
date: 2026-10-19
---

# ADR-0026：Agent 与 MCP 的分发走注册表路线

> 日期：2026-10-19 ｜ 状态：**已接受（Accepted）** ｜ 决策者：用户（product owner）
> 关联：架构脊柱 `_bmad-output/initiative-desktop/architecture-desktop/architecture-desktop.md`（AD-6）、ADR-0025

## 背景（Context）

桌面客户端需要让用户装上自己的 agent（OMP / Codex）并自动接入 cgc-2046 MCP。候选机制有两种：

1. **WASM 扩展框架**（Zed 早期路线）：扩展是 Git 仓库 + `extension.toml` + Rust 编译到 `wasm32-wasip2`，跑在宿主沙箱里，返回启动外部进程的命令。
2. **注册表**：一份标准化的元数据目录，声明 agent / MCP server 的发行方式（npm / PyPI / GitHub Releases / 远程 URL）与启动方式，客户端下载、校验、安装并拉起。

Zed 已把 ACP 扩展在 v1.5.0 弃用，改为 ACP Registry（2026-01-28 上线）；MCP server 扩展也计划让位给官方 MCP Registry。注册表已成为 agent / MCP 分发的行业方向。

## 决策（Decision）

1. **v1 只走注册表路线，不做 WASM / QuickJS 扩展框架。** 内置清单上架 OMP、Codex（`codex-acp` 2.2.2）、Claude Code（`claude-agent-acp` 0.93.0）三条；后两者的发行信息与版本可对齐 ACP Registry 的 npx 分发形态。
2. **内置签名清单**：客户端随包发布 `registry.json`，只上架审过的 OMP / Codex 与必要的 MCP server；条目声明发行方式、固定版本、checksum、启动参数。
3. **消费官方 registry**：P1 起对接 ACP Registry（`https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json`）与官方 MCP Registry 做发现；安装仍走本地校验与白名单，不自动安装第三方条目。
4. **信任模型**：固定版本 + checksum + 清单签名 + 用户确认；官方 registry 只作发现层（实测 MCP registry 元数据不含 checksum 与签名），版本固定与 checksum 校验由内置签名清单承担；agent 自身登录与模型额度归用户（BYO），客户端只展示登录状态。
5. **扩展框架延后**：只有出现「app 内第三方插件」的真实需求（课程小组件、主题、本地工具面板）且生态存在供给时再评估 WASM 运行时。

## 否决的替代

- **现在就做 WASM 扩展框架**：工期 +2–3 个月，需要自建市场、审核与签名体系；对「装 agent / 配 MCP」这一唯一真实需求是多余中间层。
- **完全不做注册表抽象**：v1 硬编码 OMP / Codex 也可行，但接第二个 agent 或第二个 MCP server 时就要改代码，不符合已确认的「消费官方 registry」方向。

## 后果（Consequences）

- **正面**：接入官方生态、无自建市场成本；agent 版本跟进由 registry 承担；安装与校验逻辑只有一处。
- **代价/风险**：外部 registry 的供应链与元数据质量不在我们控制内，必须本地白名单 + checksum；Windows / Linux 的 npm / GitHub Release 安装路径需要分别验收；未来若做 WASM 扩展框架，清单形状可复用本 ADR 的条目结构。
- **回滚**：停用外部 registry 来源，退回内置清单即可；不影响已安装 agent。

## 参考

- ACP Registry：https://agentclientprotocol.com/get-started/registry
- Zed ACP Registry 公告：https://zed.dev/blog/acp-registry
- 官方 MCP Registry：https://registry.modelcontextprotocol.io
- 架构脊柱：`_bmad-output/initiative-desktop/architecture-desktop/architecture-desktop.md`
