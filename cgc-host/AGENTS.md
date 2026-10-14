# cgc-host（CGC 本机 Host）

学员电脑上常驻的 CGC 本机 Host：课程学习页经本机 WebSocket 连到它，它替页面经 ACP 驱动学员自己的 OMP（`omp acp`）。TypeScript 写成，由学员本机的 Bun 运行，测试也用 Bun；依赖由 pnpm 管理（独立的 pnpm 项目，锁文件就是本目录的 `pnpm-lock.yaml`，不加入 `web/` 的 workspace）。决策与否决的路线见 `docs/adr/0022-course-page-local-agent-host.md`。

## 安全红线

- **只绑定 `127.0.0.1`**：Bun 默认绑定 `0.0.0.0`，会把能驱动 agent 的接口暴露到局域网，监听处必须显式指定回环地址。
- **可信来源只来自构建配置**：站点来源与平台 API 地址只在 `src/config.ts` 定义，发布构建经 `bun build --define` 注入；任何 RPC、环境变量或页面传来的值都改不了它们。
- **凭证与浏览器密钥不进日志、argv 与 HTTP 响应体**；浏览器密钥只在 `pair.result` 里交给发起这次配对的那一个连接，不发给其他连接。
- **确认弹窗的文字只走 argv**：`osascript` 跑 `src/pairing.ts` 里固定的 `DIALOG_SCRIPT`，账号等文字作为 `--` 之后的参数传入，绝不拼进脚本源码；第一个按钮「拒绝」是默认按钮，限时不答按拒绝处理。
- **协议改动先改 `protocol.json`**：它是页面 ↔ Host 的方法名、协议版本与端口的单一事实源，web 与 Host 两侧的测试都对它断言。
- **本目录的改动由人合并**：`cgc-host/**`（含依赖与 `pnpm-lock.yaml`）在根 `AGENTS.md` 的人工合并范围内；新依赖同样过根 `AGENTS.md` 的 License 硬门禁。

## 固定端口

`protocol.json` 的 `port` 取 47823：

- 低于 macOS 的临时端口段（49152 起），系统不会把它随机分给出站连接；
- 不与本仓库的开发端口（3000、4000 等）冲突，也不在浏览器禁止访问的端口表里（Fetch 标准的 bad port）。

网站 CSP 与页面都写这个字面量地址，所以改端口就是改协议：先改 `protocol.json`，再同步 web 侧。

## 页面 ↔ Host 帧信封

HTTP 只有 `GET /health`（`{version, ompPresent, paired}`）；WebSocket 在根路径 `/`。两者都先过关口：`Host` 必须是 `127.0.0.1:<端口>` 或 `localhost:<端口>`，`Origin` 必须精确等于 `SITE_ORIGIN`，否则 403、无响应体。

WS 上一个文本帧一个 JSON 对象，两个方向同一个信封：

```json
{"method": "<protocol.json 里的方法名>", "id": "<可选，字符串>", "params": {}}
```

- 回复带上请求的 `id`；Host 主动推送的消息不带 `id`。
- 页面 → Host 只认 `pageToHost` 白名单；未知方法、坏帧都回 `error`，不产生任何副作用。
- 未授权的连接只能调用 `hello`、`pair.request`、`pair.cancel`；其余方法须先 `hello`，出示与已配对账号相符的浏览器密钥。密钥一换（重新配对、换发、清掉），已 `hello` 的连接随之失效。
- `status` 不是页面可调的方法：Host 在连接建立时与配对变化时推送；`hello` 的回复也是 `status`。

| 请求 | 回复 |
| --- | --- |
| `hello {userId, browserKey}` | `status`：密钥与账号相符即 `ready`；每个连接首次 `hello` 时向平台核实一次凭证，401 / 429 则清掉本机配对、回 `unpaired`，5xx 与网络错误照常 `ready` |
| `pair.request {token?, locale?}` | `pair.result {allowed: true, browserKey}` 或 `{allowed: false}`；没走到弹窗就结束的回 `error` |
| `pair.cancel` | 无；本连接进行中的 `pair.request` 以 `pair.result {allowed: false}` 结束 |
| `pair.forget` | 无；Host 向所有连接推送未配对的 `status` |
| `chat.attach` / `chat.send` / `chat.stop` / `chat.new` / `card.answer`（`{courseId, …}`） | 由对话处理器（U6）回复；被另一个连接接管的连接收到 `chat.evicted {courseId}` |

`status.params`：`state`（`unpaired` / `paired` / `ready`，`ready` 指这个连接已授权）、`pairedUserId`、`pairedDisplayName`、`deviceName`、`tokenId`、`ompPresent`、`version`、`protocolVersion`。

`error.params.code`：

| code | 含义 |
| --- | --- |
| `bad_request` | 坏帧或参数不合法（含 `courseId` 不是 UUID、`token` 不以 `cgch_` 开头） |
| `unknown_method` | 不在 `pageToHost` 白名单里 |
| `unauthorized` | 没有 `hello`，或浏览器密钥、账号不符 |
| `not_paired` | 不带凭证的 `pair.request`，但本机没有配对 |
| `busy` | 已有一次配对在进行，或刚关弹窗、还在冷却 |
| `invalid_token` | 平台对这枚凭证回 401 / 429，或它的 kind 不是 `learning_host` |
| `platform_unavailable` | 平台连不上、回 5xx 或应答不合约 |
| `not_holder` | 这门课已被另一个连接接管 |
| `chat_unavailable` | U6 接上 ACP 之前，对话方法一律回它 |
| `internal` | Host 内部出错，详情只在 Host 日志里 |

`pair.request` 以 `error` 结束时，Host 没有动这枚凭证，页面用登录态补撤销；以 `pair.result {allowed: false}` 结束时，Host 已经用它自撤销（尽力而为）。

## 测试与许可扫描

在 `cgc-host/` 内执行（CI 的 `host` job 跑同一组命令，暂非必过检查）：

| 目的 | 命令 |
| --- | --- |
| 按锁文件安装依赖 | `pnpm install --frozen-lockfile` |
| 测试 | `bun test` |
| 依赖许可扫描（复用 `web/scripts/check-licenses.mjs`，扫本包的全依赖树） | `pnpm check:licenses` |
