# cgc-host（CGC 本机 Host）

学员电脑上常驻的 CGC 本机 Host：课程学习页经本机 WebSocket 连到它，它替页面经 ACP 驱动学员自己的 OMP（`omp acp`）。TypeScript 写成，由学员本机的 Bun 运行，测试也用 Bun；依赖由 pnpm 管理（独立的 pnpm 项目，锁文件就是本目录的 `pnpm-lock.yaml`，不加入 `web/` 的 workspace）。决策与否决的路线见 `docs/adr/0022-course-page-local-agent-host.md`。

## 安全红线

- **只绑定 `127.0.0.1`**：Bun 默认绑定 `0.0.0.0`，会把能驱动 agent 的接口暴露到局域网，监听处必须显式指定回环地址。
- **可信来源只来自构建配置**：站点来源与平台 API 地址只在 `src/config.ts` 定义，发布构建经 `bun build --define` 注入；任何 RPC、环境变量或页面传来的值都改不了它们。
- **凭证与浏览器密钥不进日志、argv 与响应体。**
- **协议改动先改 `protocol.json`**：它是页面 ↔ Host 的方法名、协议版本与端口的单一事实源，web 与 Host 两侧的测试都对它断言。
- **本目录的改动由人合并**：`cgc-host/**`（含依赖与 `pnpm-lock.yaml`）在根 `AGENTS.md` 的人工合并范围内；新依赖同样过根 `AGENTS.md` 的 License 硬门禁。

## 固定端口

`protocol.json` 的 `port` 取 47823：

- 低于 macOS 的临时端口段（49152 起），系统不会把它随机分给出站连接；
- 不与本仓库的开发端口（3000、4000 等）冲突，也不在浏览器禁止访问的端口表里（Fetch 标准的 bad port）。

网站 CSP 与页面都写这个字面量地址，所以改端口就是改协议：先改 `protocol.json`，再同步 web 侧。

## 测试与许可扫描

在 `cgc-host/` 内执行（CI 的 `host` job 跑同一组命令，暂非必过检查）：

| 目的 | 命令 |
| --- | --- |
| 按锁文件安装依赖 | `pnpm install --frozen-lockfile` |
| 测试 | `bun test` |
| 依赖许可扫描（复用 `web/scripts/check-licenses.mjs`，扫本包的全依赖树） | `pnpm check:licenses` |
