---
status: superseded
superseded_by: ADR-0028
date: 2026-10-19
---

# ADR-0025：桌面客户端内化本机 Host（Rust + ACP）

> **Superseded（2026-10-26）：Web 端学习搭子与 `cgc-host` 已移除；桌面客户端内化 ACP Host 的架构已演进并被 ADR-0028（内置 Native Agent + 外部 ACP Agent 双轨模型）承接。**

> 日期：2026-10-19 ｜ 状态：**已取代（Superseded，2026-10-26；桌面内化 ACP Host 架构由 ADR-0028 双轨模型承接）** ｜ 决策者：用户（product owner）
> 关联：ADR-0022、ADR-0023、ADR-0028、架构脊柱 `_bmad-output/initiative-desktop/architecture-desktop/architecture-desktop.md`（AD-3、AD-4、AD-5、AD-8；本地规划产物，`.git/info/exclude` 忽略）

## 背景（Context）

ADR-0022 让课程学习页经 CGC 本机 Host（`cgc-host/`，Bun + TypeScript，回环 WebSocket，Origin 钉死）驱动学员自己的 agent；ADR-0023 把驱动方扩展为 agent 注册表（OMP / Codex）。这套桥接是浏览器时代的产物：学员需要单独安装 Host、可能装 Bun、本机配对弹窗，且 Safari 因 https 页面无法访问回环而不可用。

桌面客户端是原生进程，没有浏览器沙箱，可以直接以 ACP 标准协议驱动 agent 进程。把 Host 角色内化进客户端，可以删掉回环端口、Origin 校验、配对弹窗与三套登录自启脚本，同时兑现「用户只装一个东西」的产品承诺。

## 决策（Decision）

1. **客户端自己就是 Host**：Rust 经 ACP stdio 驱动用户本机 agent（`agent-client-protocol` 3.4.0，Apache-2.0）；不监听回环端口，不引入页面 ↔ Host 的 WebSocket 协议。**v1 支持 OMP（原生 `omp acp`）、Codex（`codex-acp` 2.2.2）、Claude Code（`claude-agent-acp` 0.93.0）**；后两者按 ACP Registry 的 npx 分发形态启动，由客户端管理的 Node.js 24 LTS runtime 执行（MIT、独立进程、用户无需安装 Node/Bun）；runtime 与适配器包从可信源获取并校验 checksum。agent 登录由用户在系统浏览器显式触发，适配器进程处理回调。
2. **凭证**：登录后由后端签发第一方 Bearer token 与 `learning_host` 连接凭证（平台只放行学习循环的 5 个工具）；凭证只存 OS keychain。学习凭证由 session 服务唯一签发与撤销，agent 侧只持有绑定「账号/工作台/课程」的 lease；登出与换账号按「服务端撤销 → 终止 agent 会话 → 释放 lease → 清 keychain」顺序执行（脊柱 AD-15）。
3. **MCP 注入而非配置**：在 ACP `session/new` 的 `mcpServers` 里注入 cgc-2046 MCP（OMP 用名 `cgc-2046`，Codex 用名 `cgc-2046-learning`）；不写用户 `mcp.json`；退出登录或换账号即作废（AD-5）。
4. **保留 ADR-0022 的行为不变量**：对话内容不落盘、不替学员审批、每课每 agent 一条会话指针、45 秒准备与 60 秒页面超时预算、进程回收。
5. **agent 仍属 BYO**：客户端不打包 agent；缺失时按 ACP Registry 方式引导安装（见 ADR-0026）。
6. **浏览器路径不变**：`cgc-host/` 继续服务 web 与旧路径；两条路径共享同一组行为不变量，`cgc-host/**` 的改动仍属人工合并范围。

## 否决的替代

- **打包现有 JS Host（Bun sidecar）**：每平台多约 90 MB；Bun 的 JavaScriptCore 为 LGPL-2 且静态链接，需按依赖规则第 6 节人裁；且仍保留回环端口与配对复杂度。
- **把 Host 改写成 Rust 但保留回环协议**：删不掉 Origin 校验与端口暴露，收益不足。
- **只在 web 端继续用 Host**：无法兑现零额外安装，且 Safari 限制仍在。

## 后果（Consequences）

- **正面**：安装即用；无端口暴露；对话与凭证都在本地；原生应用可直接管理 agent 生命周期。
- **代价/风险**：安全敏感逻辑（凭证、进程回收、超时、审批）在 Rust 重写，需以 ADR-0022 的测试矩阵回归；`cgc-host/**` 属人工合并，两条路径可能产生行为漂移（由共享不变量与回归清单约束）；桌面端的威胁模型需要单独评审（本地进程、提权、日志）。
- **回滚**：删除内化 Host 功能、回到浏览器 `cgc-host` 路径；不影响后端与 web。

## 现状补记（2026-11-22）

1. **内置 ACP 适配器清单（决策 1）**：`desktop/crates/platform/resources/registry.json` 现内置 **4** 项外部 ACP Agent——`omp`、`codex`（`2.2.2`）、`claude_code`（`0.94.0`）、`deepseek`（`0.4.41`，见 ADR-0031）。
2. **安装校验机制（决策 1）**：SHA-256 checksum 校验（`desktop/crates/platform/src/registry/checksum.rs`）用于托管 Node.js 24 运行时归档（`desktop/crates/platform/src/agent/node_runtime.rs`）；npm 适配器包依赖 `registry.sig`（Ed25519 签名校验 `registry.json`）、`npm install --save-exact` 与安装后 `package.json` 版本号核对（`desktop/crates/platform/src/registry/install.rs`）。
3. **会话持久化、全局 Agent 面板与超时预算（决策 3 / 4）**：经 ADR-0028 与 Stage 3.5a 演进，桌面端已引入本地 SQLite 持久化（`desktop/crates/agent_store/`：Native 线程存 `threads.db`，外部 ACP 聊天记录存 `conversations.db`）；所有外部 ACP Agent 统一注入 `cgc-2046-learning`（`desktop/crates/platform/src/mcp/inject.rs`）；UI 收敛为全局 Agent Panel 并共享统一工作目录 `~/cgc2046_workspace/assistant/<userId>`（`desktop/crates/app/src/agent_scope.rs`）；`session/prompt` 采用基于活跃流式输出的空闲超时预算（`desktop/crates/platform/src/acp/connection/turn.rs`）。
4. **历史路径说明（决策 6 / 参考）**：`cgc-host/` 及 `cgc-host/protocol.json` 已于 2026-10-26 删除；`_bmad-output/*` 为本地规划产物（`.git/info/exclude` 忽略，不入库）。

## 参考

- 架构脊柱：`_bmad-output/initiative-desktop/architecture-desktop/architecture-desktop.md`（本地规划产物，`.git/info/exclude` 忽略）
- `docs/adr/0022-course-page-local-agent-host.md`
- `docs/adr/0023-multiple-local-agents.md`
- `docs/adr/0028-desktop-native-agent-dual-track.md`
- 现存源码：`desktop/crates/platform/src/acp/connection.rs`、`desktop/crates/platform/src/mcp/credential.rs`、`desktop/crates/platform/src/mcp/inject.rs`、`desktop/crates/agent_store/src/lib.rs`、`desktop/crates/app/src/agent_scope.rs`
- `cgc-host/protocol.json`（已于 2026-10-26 删除，仅作历史引用）
