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

1. **v1 只走注册表路线，不做 WASM / QuickJS 扩展框架。** 内置清单（`desktop/crates/platform/resources/registry.json`）当前上架 4 条第一方审过的外部 ACP agent：OMP、Codex（`@agentclientprotocol/codex-acp` `2.2.2`）、Claude Code（`@agentclientprotocol/claude-agent-acp` `0.94.0`）、DeepSeek Harness（`@openma/deepseek-harness-acp` `0.4.41`）。
2. **内置签名清单**：客户端随包发布 `registry.json` 与 Ed25519 签名 `registry.sig`，二进制内嵌验证公钥 `BUILTIN_PUBLIC_KEY`（开发期使用 dev key，正式对外发版 GA 前轮换为 CI Secret `CGC_REGISTRY_PRIVATE_KEY` 对应的生产密钥，见 #1324）。
3. **官方 ACP / MCP Registry 发现层延后（2026-11-22 修订）**：由于 v1 仅开放内置签名清单中的 4 个 agent、且不开放第三方或用户自定义 MCP server（ADR-0028 决策 6），早期未接线的官方 registry 发现模块（`registry/discovery.rs`）已按 YAGNI 移除；待后续真正开放第三方 agent / 自定义 MCP 安装入口时再按需引入。
4. **信任模型（2026-11-22 与实现对齐）**：
   - **清单层**：Ed25519 签名校验覆盖 `registry.json` 原始字节，篡改或版本漂移 fail-closed；
   - **受管运行时层**：客户端受管 Node.js 24 LTS（`agent/node_runtime.rs`）下载官方归档后强制执行内置 SHA-256（`registry/checksum.rs`）校验，不匹配的归档绝不解压执行；
   - **npm 适配器层**：npx 分发的适配器由已验签的 `registry.json` 锁定精确包名与版本号，经受管 Node 24 从 HTTPS npm registry 安装并在安装后核验已安装 `package.json` 版本号（不为 npm 包额外维护独立 tarball checksum）；
   - **凭据归属**：agent 自身登录与模型额度归用户（BYO），客户端只展示登录状态或从本机钥匙串按需注入子进程环境。
5. **扩展框架延后**：只有出现「app 内第三方插件」的真实需求（课程小组件、主题、本地工具面板）且生态存在供给时再评估 WASM 运行时。

## 否决的替代

- **现在就做 WASM 扩展框架**：工期 +2–3 个月，需要自建市场、审核与签名体系；对「装 agent / 配 MCP」这一唯一真实需求是多余中间层。
- **完全不做注册表抽象**：v1 硬编码 OMP / Codex 也可行，但接第二个 agent 或第二个 MCP server 时就要改代码，不符合已确认的「消费官方 registry」方向。

## 后果（Consequences）

- **正面**：接入官方生态、无自建市场成本；agent 版本跟进由 registry 承担；安装与校验逻辑只有一处。
- **代价/风险**：外部 registry 的供应链与元数据质量不在我们控制内，必须本地白名单 + checksum；Windows / Linux 的 npm / GitHub Release 安装路径需要分别验收；未来若做 WASM 扩展框架，清单形状可复用本 ADR 的条目结构。
- **回滚**：停用外部 registry 来源，退回内置清单即可；不影响已安装 agent。

## 现状补记（2026-11-22）

1. **内置清单结构（决策 1 / 2）**：`desktop/crates/platform/resources/registry.json`（由 `desktop/crates/platform/src/registry/manifest.rs` 解析）当前收录 **4** 个外部 ACP Agent（`omp`、`codex 2.2.2`、`claude_code 0.94.0`、`deepseek 0.4.41`，见 ADR-0031）及 `node_runtime.required`；清单内不包含 MCP server 条目（CGC 学习 MCP server 由 `desktop/crates/platform/src/mcp/inject.rs` 直接注入）；生产签名公钥 `BUILTIN_PUBLIC_KEY` 轮换跟踪于 #1324。
2. **官方 Registry 在线发现（决策 3）**：早期未接线的 `desktop/crates/platform/src/registry/discovery.rs` 与 `examples/registry_discovery.rs` 已按 YAGNI 移除，UI 仅渲染内置签名清单；待后续开放第三方安装时再按需引入。
3. **校验分层（决策 4）**：SHA-256 哈希校验（`desktop/crates/platform/src/registry/checksum.rs`）用于托管 Node.js 24 运行时归档（`desktop/crates/platform/src/agent/node_runtime.rs`）；npm 适配器包通过 `registry.sig`（Ed25519 签名）、`npm install --save-exact` 与安装后版本核对（`desktop/crates/platform/src/registry/install.rs`）保证完整性。

## 参考

- ACP Registry：https://agentclientprotocol.com/get-started/registry
- Zed ACP Registry 公告：https://zed.dev/blog/acp-registry
- 官方 MCP Registry：https://registry.modelcontextprotocol.io
- 架构脊柱：`_bmad-output/initiative-desktop/architecture-desktop/architecture-desktop.md`（本地规划产物，`.git/info/exclude` 忽略）
- 现存源码：`desktop/crates/platform/resources/registry.json`、`desktop/crates/platform/src/registry/manifest.rs`、`desktop/crates/platform/src/registry/install.rs`、`desktop/crates/platform/src/registry/checksum.rs`
