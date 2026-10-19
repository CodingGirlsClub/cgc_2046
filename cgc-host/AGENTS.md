# cgc-host（CGC 本机 Host）

学员电脑上常驻的 CGC 本机 Host：课程学习页经本机 WebSocket 连到它，它替页面经 ACP 驱动学员自己的本机 agent（当前两种：OMP 的 `omp acp`、Codex 的 `codex-acp`）。TypeScript 写成，由学员本机的 Bun 运行，测试也用 Bun；依赖由 pnpm 管理（独立的 pnpm 项目，锁文件就是本目录的 `pnpm-lock.yaml`，不加入 `web/` 的 workspace）。决策与否决的路线见 `docs/adr/0022-course-page-local-agent-host.md`。

## 安全红线

- **只绑定 `127.0.0.1`**：Bun 默认绑定 `0.0.0.0`，会把能驱动 agent 的接口暴露到局域网，监听处必须显式指定回环地址。
- **可信来源只来自构建配置**：站点来源与平台 API 地址只在 `src/config.ts` 定义，发布构建经 `bun build --define` 注入；任何 RPC、环境变量或页面传来的值都改不了它们。
- **凭证与浏览器密钥不进日志、argv 与 HTTP 响应体**；浏览器密钥只在 `pair.result` 里交给发起这次配对的那一个连接，不发给其他连接。学习凭证只经 ACP 的 `mcpServers` 交给 OMP（U6 核验：OMP 的数据目录里没有 `cgch_`）。
- **对话内容只在内存里（R25）**：事件缓冲不写盘；日志只记事件类型与错误消息，不记消息、思考、工具的输入输出；OMP 的 stderr 直接丢弃。
- **不替学员审批**：卡片在无人作答时只会以取消结束，从不按允许；不注入 `--approval-mode`、不调 session/set_mode——审批沿用学员自己的 OMP 配置（KTD5、R18）。
- **确认弹窗的文字只走 argv**：按系统挑原装弹窗（`src/platform-dialog.ts`）——macOS 的 `osascript` 跑固定的 `DIALOG_SCRIPT`，账号等文字在 `--` 之后；Windows 的 `cscript` 跑固定的 `WINDOWS_SCRIPT`（运行时写入临时文件、用完即删，文字走 `WScript.Arguments`），弹窗默认按钮是「否」；Ubuntu 用 `zenity --question --default-cancel`。三者都绝不把文字拼进脚本源码，默认按钮/关闭/超时都不算「允许」。
- **协议改动先改 `protocol.json`**：它是页面 ↔ Host 的方法名、协议版本与端口的单一事实源，web 与 Host 两侧的测试都对它断言。
- **本目录的改动由人合并**：`cgc-host/**`（含依赖与 `pnpm-lock.yaml`）在根 `AGENTS.md` 的人工合并范围内；新依赖同样过根 `AGENTS.md` 的 License 硬门禁。

## 固定端口

`protocol.json` 的 `port` 取 47823：

- 低于 macOS 的临时端口段（49152 起），系统不会把它随机分给出站连接；
- 不与本仓库的开发端口（3000、4000 等）冲突，也不在浏览器禁止访问的端口表里（Fetch 标准的 bad port）。

网站 CSP 与页面都写这个字面量地址，所以改端口就是改协议：先改 `protocol.json`，再同步 web 侧。

## 页面 ↔ Host 帧信封

HTTP 只有 `GET /health`（`{version, ompPresent, paired, agents}`；`agents` 是 `[{kind, present, envError?, sources?}]`，`ompPresent` 是它里 OMP 那条的派生值，留给只认它的旧页面）；WebSocket 在根路径 `/`。两者都先过关口：`Host` 必须是 `127.0.0.1:<端口>` 或 `localhost:<端口>`，`Origin` 必须精确等于 `SITE_ORIGIN`，否则 403、无响应体。`sources` 是只读探测出的「可复用来源」（目前在 Codex 上给）：`[{source, version}]`，`source` ∈ `managed` / `codex-acp` / `chatgpt-app` / `codex-cli`，版本取不到为 `null`；**只上报，不改变安装与启动优先级**（#1154 / #1155；ChatGPT App 内置路径目前只探测 macOS）。

WS 上一个文本帧一个 JSON 对象，两个方向同一个信封：

```json
{"method": "<protocol.json 里的方法名>", "id": "<可选，字符串>", "params": {}}
```

- 回复带上请求的 `id`；Host 主动推送的消息不带 `id`。
- 页面 → Host 只认 `pageToHost` 白名单；未知方法、坏帧都回 `error`，不产生任何副作用。
- 未授权的连接只能调用 `hello`、`pair.request`、`pair.cancel`；其余方法须先 `hello`，出示与已配对账号相符的浏览器密钥。密钥一换（重新配对、换发、清掉），已 `hello` 的连接随之失效，课程持有权一并释放；待答卡片进入无人持有的宽限期，新连接重新 `hello` 并 `chat.attach` 后可恢复持有权。
- `status` 不是页面可调的方法：Host 在连接建立时与配对变化时推送；`hello` 的回复也是 `status`。

| 请求 | 回复 |
| --- | --- |
| `hello {userId, browserKey}` | `status`：密钥与账号相符即 `ready`；每个连接首次 `hello` 时向平台核实一次凭证，401 / 429 则清掉本机配对、回 `unpaired`，5xx 与网络错误照常 `ready` |
| `pair.request {token?, locale?}` | `pair.result {allowed: true, browserKey}` 或 `{allowed: false}`；没走到弹窗就结束的回 `error` |
| `pair.cancel` | 无；本连接进行中的 `pair.request` 以 `pair.result {allowed: false}` 结束 |
| `pair.forget` | 无；Host 向所有连接推送未配对的 `status` |
| `chat.attach` / `chat.send` / `chat.stop` / `chat.new` / `chat.sessions` / `chat.open` / `chat.set_setting` / `chat.authenticate` / `card.answer`（`{courseId, agent?, …}`） | 见下方「对话的载荷契约」；被另一个连接接管的连接收到 `chat.evicted {courseId}` |

`agent` 是对话方法的可选参数（`omp` 等注册表里的 kind）。**只有 `chat.attach` / `chat.send` / `chat.new` / `chat.open` 用它选择/切换会话**：带哪个就驱动哪个，缺省恒为 `omp`，与状态文件里的记忆值无关——回滚期的旧页面不可能带这个字段，不能让它被改道到别的 agent（记忆值只作为页面的初选，见 `history` 的 `agent` 字段）；也只有这四个方法会写「上次显式选择」。`chat.stop` / `card.answer` / `chat.sessions` / `chat.set_setting` / `chat.authenticate` 作用在课程**当前** agent 上，忽略该字段（缺省值不会把课程切走）。取值不在注册表里一律 `bad_request`。

`status.params`：`state`（`unpaired` / `paired` / `ready`，`ready` 指这个连接已授权）、`pairedUserId`、`deviceName`、`tokenId`（仅已 `hello` 的连接非空）、`agents`（本机各 agent 的 `{kind, present, envError?, sources?}`，`sources` 含义同 `/health`）、`ompPresent`、`version`、`protocolVersion`；解析学员登录 shell 的环境失败时另有 `ompEnvError`（`timeout` / `failed`，此时 Host 退回 launchd 的最小环境，多半找不到 omp 或模型凭证）。`ompPresent` 与 `ompEnvError` 是 `agents` 里 OMP 那条的派生值，留给只认它们的旧页面，移除条件是下一个 Host 大版本。某个 agent 的 `present` 为 false 时，Host 每次被读到都会在后台重新查找（至多 10 秒一次），学员装上它的入口后不必重启 Host；页面可轮询 `/health`。残余风险：`pairedUserId` 与 `deviceName` 在 `hello` 之前也会随 `status` 下发（页面配对流程要用它们判断「本机已配对到别的账号」并给凭证备注），二者是伪匿名标识，已评估接受；凭证、对话内容与卡片不在其中。

`error.params.code`：

| code | 含义 |
| --- | --- |
| `auth_required` | 这个 agent 要求学员先登录（ACP `-32000`）：回包另带 `methods: [{id, name}]`（它握手时播报的登录方式），页面的登录卡据此渲染；`chat.authenticate` 完成后即可重试 |
| `auth_failed` | `chat.authenticate` 没成功（适配器报错、超时）；详情只在 Host 日志里 |
| `bad_request` | 坏帧或参数不合法（含 `courseId` 不是 UUID、`agent` 不在本机注册表里、`token` 不以 `cgch_` 开头、`chat.send` 的 `text` 为空或 `context` 不合法、`card.answer` 的作答不合法或卡片已收起、`chat.set_setting` 的 `configId` 不在白名单或 `value` 为空、超长、被 agent 拒绝） |
| `unknown_method` | 不在 `pageToHost` 白名单里 |
| `unauthorized` | 没有 `hello`，或浏览器密钥、账号不符 |
| `not_paired` | 不带凭证的 `pair.request`，但本机没有配对 |
| `busy` | 已有一次配对在进行，或刚关弹窗、还在冷却；对话方法里指这门课已有一轮在跑（`chat.send`、`chat.new`、`chat.open`、`chat.set_setting`），或本机刚换了账号 / 换了 agent、上一轮正在取消（任一对话方法；稍后重试即接上新的那段对话） |
| `invalid_token` | 平台对这枚凭证回 401 / 429，或它的 kind 不是 `learning_host` |
| `platform_unavailable` | 平台连不上、回 5xx 或应答不合约 |
| `not_holder` | 这门课已被另一个连接接管 |
| `session_unavailable` | `chat.open` 的目标会话加载失败；持久指针不动、原会话不受影响 |
| `chat_unavailable` | 这个 agent 的入口找不到（例如没装 OMP）、拉不起进程，或 ACP 握手、加载会话失败；`chat.set_setting` 在当前没有已加载会话时也回它；详情只在 Host 日志里 |
| `internal` | Host 内部出错，详情只在 Host 日志里 |

`pair.request` 以 `error` 结束时，Host 没有动这枚凭证，页面用登录态补撤销；以 `pair.result {allowed: false}` 结束时，Host 已经用它自撤销（尽力而为）。

## 对话的载荷契约（`src/acp/`、`src/agents/`）

每门课对应**每个 agent 各一条** ACP 会话，指针存在状态文件的 `sessions`（courseId → `{<agent kind>: sessionId}`；多 agent 之前的旧形状是 courseId → sessionId，读时按缺省 agent 迁移并落盘）。**每个 agent kind 一个进程**：第一次需要时才拉起（`chat.attach`——回放历史，或没有指针时建一条会话好把设置随 `history` 下发；以及 `chat.send`、`chat.new`）；没有页面连着、也没有在跑的回合超过 10 分钟就回收，下次需要时再拉起并 session/load（另外，一轮从发出 prompt 起最多 30 分钟，到点 Host 本地按 `error` 收尾，不再等 agent；常量 `TURN_TIMEOUT_MS` / `CANCEL_ACK_TIMEOUT_MS` 有默认值断言）——attach 建的空会话只留指针，进程照常按 KTD13 回收。会话的工作目录是 `~/cgc2046_workspace/courses/<userId>/<courseId>`（`src/state.ts` 的 `workDir`，与终端插件的工作区同一棵树、隔一层 `courses/`）；session/new 与每次 session/load 都下发含当前学习凭证的 `cgc-2046` MCP 服务器，指针指向的会话不在当前课程目录下（例如换了账号）就不加载、清掉指针。此外状态文件为每条会话记归属账号（`sessionOwners`，账号短哈希）：记录与当前账号不符的指针不加载、`chat.sessions` 不列出、`chat.open` 回 `bad_request`（不依赖适配器自报的 cwd）；旧状态没有归属记录时退回 cwd 校验（兼容）。换 agent 就是换一段会话：旧 agent 在跑的回合先按取消收尾、本次回 `busy`，页面重试才切换；切换后缓冲、设置与待答卡片都清空。

下面的消息都带 `courseId`，表里省略。

| 页面 → Host | 其余 params | 回复与之后的推送 |
| --- | --- | --- |
| `chat.attach` | `agent?` | `history`（没有会话指针时先建一条空会话，回包因此带设置）；之后把未答的卡片逐张以 `turn.card` 重发 |
| `chat.send` | `text`（非空字符串）、`context` | 回 `turn.delta {kind: "user", text}` 表示接下了；之后推 `turn.delta` / `turn.card` / `turn.card.closed`，最后 `turn.end` |
| `chat.stop` | — | 不回复；在跑的一轮：待答卡片 `turn.card.closed {reason: "cancelled"}`，没跑完的工具步骤以 `status: "stopped"` 推一次 `turn.delta`，随后 `turn.end {stopReason: "cancelled"}`。agent 在 15 秒内不应答取消时，Host 本地按 cancelled 收尾并推 `turn.end`（迟到的应答被忽略）。停止前已提交到平台的结果照常生效 |
| `chat.new` | — | `history`（空）：此后的消息进一条新会话，agent 不带之前的上下文；学习进度不受影响 |
| `chat.sessions` | `cursor?`（分页游标，原样透传 ACP） | `sessions {sessions: [{sessionId, title, updatedAt, messageCount}], current, nextCursor}`（`title` 缺省为 `null`，agent 差异）：本课程工作目录下的会话；只读，有回合在跑也可查；元数据缺省为 `null`（OMP 差异），页面降级展示。Host 不信任适配器的 cwd 过滤：每个条目都按 `SessionInfo.cwd` 与课程工作目录二次比对 |
| `chat.open` | `sessionId` | `history`：切换到指定会话；目标必须同时满足 id 命中与 cwd 归属本课程目录（否则 `bad_request`）；加载失败 `session_unavailable` 且持久指针不动（原会话不受影响）；有回合在跑 `busy`；成功才推进指针，切当前会话不重复加载 |
| `chat.authenticate` | `methodId`（取自 `auth_required` 回包的 `methods`，如 `chat-gpt`） | `chat.authenticated {agent}`：登录成功（浏览器由适配器自己开）；`auth_failed` 失败、`busy` 登录期间进程被换掉（页面重试即可）、`bad_request` 参数不合法；`chat-gpt` 这类由适配器在本机开浏览器，不进课程队列 |
| `chat.set_setting` | `configId`（`model` / `thinking` / `reasoning_effort`）、`value`（非空字符串） | `chat.settings {settings}`：改当前会话的设置，回复带这个 agent 的完整回包；有回合在跑 `busy`；当前没有已加载会话 `chat_unavailable`；值不被 agent 接受 `bad_request`（ACP 原文只进 Host 日志） |
| `card.answer` | `cardId`，加审批的 `{optionId}` 或提问的 `{action, content?}` | `turn.card.closed {cardId, reason: "answered"}` |
| `agent.install` | `kind`（可安装的只有 `codex`，见 `installable`） | `agent.install.started {started: true}`；随后推 `agent.install.progress {kind, phase: "installing"}` 与 `agent.done {kind, ok: true, version, reused?}` / `{kind, ok: false, code}`（`install_failed` / `version_mismatch` / `timeout`）。`reused: true` 表示本次装的是「只装适配器、复用学员已有 Codex engine」的变体（#1154）；缺省/旧 Host 不报。同一时刻只允许一个安装（`busy`）；没声明安装能力或 kind 不可安装时 `unsupported`；参数不合法 `bad_request`。**已装着钉住的版本时幂等短路**：不再下载，直接回 done |
| `agent.done` 之后 | — | Host 重解析定位器并给每个已授权连接推 `status`：页面不必等下一轮 `/health` |

会话设置（`chat.set_setting`、`chat.settings`、`history` 的 `settings`）：Host 把 agent 的会话设置（ACP 的 config options）收窄成 `model`（模型）与思考/推理强度两项——OMP 的 id 是 `thinking`，Codex 的 id 是 `reasoning_effort`，两项的 category 都是 `thought_level`；`mode`（plan）不透出。`settings` 是 `[{id, name, category, currentValue, options: [{value, name, description?}]}]`，`history`（`chat.attach` / `chat.new` / `chat.open`）带当前值；`chat.attach` 在没有会话指针时会先建一条空会话，所以第一次打开面板就能拿到设置（进程仍按 KTD13 回收）。空数组表示这个 agent 没给可选项（旧版本或 id 不同名）——页面据此不渲染入口。改动只作用于当前会话：不写学员的 agent 配置、不影响终端；agent 自己改了设置（`config_option_update`）时 Host 推 `chat.settings`。切模型可能连带改动另一项（OMP 实测：不支持思考的模型会把思考等级重置为 `off`…

**能力协商**：Host 在 ACP `initialize` 时记录 agent 的协议版本、`loadSession`、`sessionCapabilities.list`、`mcpCapabilities.http`。协议版本不一致或明确不支持 HTTP MCP：本次对话回 `chat_unavailable`（详情只在 Host 日志）；明确不支持 session/load、或无法用 session/list 核实会话归属：清掉会话指针、从新对话开始（日志记录原因）；明确不支持 session/list：`chat.sessions` 回空列表；`chat.open` 在目标无法核实归属或缺少 session/load 时回 `chat_unavailable`。字段缺失一律按支持处理（旧适配器兼容）。能力门都在 `await run.agent()`（握手）之后判定，冷进程上不以默认值预先放行；进程代被回收时清空该 agent 的能力缓存。

`status` 与 `/health` 都带 `capabilities: string[]`（期 2 起含 `"agent.install"`）：页面只在声明了它时给「安装 Codex 支持」入口，旧 Host（0.2.0）不声明、页面继续只给手动命令。**不改 `protocolVersion`**——加方法靠能力探测，不靠版本门逼学员重装。

`agent.install` **要求先配对**（与 `chat.*` 同一道授权）：否则任意能连上本机 Host 的站点来源页都能静默触发约 337MB 的下载，幂等短路只挡重复、挡不住第一次。页面在无 agent 时先给「连接这台电脑」，配对完成后才出现安装入口。其余边界：只接受官方站点 Origin 的连接（`isAllowedRequest`），kind 限于 `installable`，版本/URL/落位都在 Host 包内钉死——没有任意的下载地址、版本或路径参数；已装着钉住版本时幂等短路。它不碰凭证、不驱动 agent。

`context`（KTD8）：`{workspaceId, courseVersion, unitId, locale}`。`workspaceId` 是 UUID；`courseVersion` 是页面显示的课程版本号（正整数）或 `null`；`unitId` 是学员正在看的单元 id（只认 `^[A-Za-z0-9_.-]{1,64}$`），`null` 表示课程总览；`locale` 是 `zh-CN` 或 `en`。每条 `chat.send` 都带，Host 只在会话的首条消息和它变化时（例如切换单元）把它附给 agent，只带这些标识——课程、单元标题这类 tutor 撰写的文本不进提示。

事件（`turn.delta` 的载荷，也是 `history.events` 的条目）：

| `kind` | 字段 | 说明 |
| --- | --- | --- |
| `user` | `text`, `messageId?` | 学员的消息 |
| `message` | `text`, `messageId?` | agent 回复的增量 |
| `thought` | `text`, `messageId?` | 思考的增量，默认折叠 |
| `tool` | `toolCallId`, `title`, `toolKind`, `status`, `input?`, `output?` | 一次工具调用合并后的整段步骤，页面按 `toolCallId` 替换；`status` 是 `pending` / `in_progress` / `completed` / `failed` / `stopped`；`input` 是参数的 JSON，`output` 是输出文字，各截到 16000 字符 |
| `usage` | `used`, `size`, `cost?: {amount, currency}` | 上下文已用与总量（token），以及本会话累计费用 |
| `end` | `stopReason`, `modelError?` | 只出现在 `history` 里：一轮的结束，字段同 `turn.end` |

- 文字事件的拼接规则：与上一条事件 `kind` 相同、`messageId` 相同（都没有也算相同）就接在后面，否则另起一段。`history` 里的条目已经按这条规则拼好。
- `history {running, events, settings, agent}`：`running` 表示有一轮正在跑；`agent` 是这门课**上次显式选过**的 agent kind（`null` 表示没记过），只供页面做初选——Host 的路由缺省恒为 `omp`，不看它。缓冲在 Host 内存里，只留最近 500 条，不写盘；Host 重启或 agent 进程被回收后从它的会话存储回放，回放出的历史没有 `usage`、`end` 与模型错误归类。同一会话的最后一条 `usage` 由 Host 按会话另存，`history.events` 末尾补回（Host 进程重启后不再有）。

卡片（`turn.card`）：

- 审批：`{cardId, kind: "permission", toolCallId, title, toolKind, input?, options: [{optionId, name, kind}]}`。选项原样来自学员的 OMP，与终端里一致：`kind` 是 `allow_once` / `allow_always` / `reject_once` / `reject_always`，OMP 18.10.4 的 `name` 是 Allow once / Always allow / Reject / Always reject。作答 `{cardId, optionId}`。
- 「始终允许」只活在 OMP 进程内存里、只对这条会话有效，按工具种类记（命令类即这条对话里之后的所有命令），不写进学员的 OMP 配置；OMP 重启（空闲回收、Host 或电脑重启）后失效（U6 真机核验）。卡片文案建议：「本次对话中不再询问此类操作（重启后需重新确认）」。
- 提问：`{cardId, kind: "question", message, schema}`。`schema` 是表单的 JSON Schema（object，`properties` 里是 string（`oneOf` / `enum` 为选项）、number / integer、boolean、array（`items.anyOf` / `items.enum` 为多选））。OMP 的 `ask` 工具：`q0` 是单选，`q0__other` 是自由输入。作答 `{cardId, action: "accept", content: {字段: 值}}`（值是字符串、数字、布尔或字符串数组，键必须在 `properties` 里），或 `{cardId, action: "decline" | "cancel"}`。只接受 form 模式，其余模式 Host 直接拒绝，不出卡片。
- 审批与提问要求请求的 `sessionId` 等于课程**当前会话**且当前有回合在跑；没有回合时直接以取消/拒绝应答，不出卡（Codex 的后台任务也会在回合后发审批）。注意 ACP 不携带 turn id，守卫粒度是「当前会话 + 当前回合在跑」——若上一轮被 Host 看门狗本地强制收尾而 agent 仍在执行，Host 会先隔离该会话、拒绝新回合，直到旧 session/prompt 真正 settle（或 `chat.new` / 进程换代）。
- `turn.card.closed {cardId, reason}`：`answered` 是持有者答了；`cancelled` 是回合结束、停止、OMP 撤回请求或退出，或没有页面持有这门课、卡片又等了超过 5 分钟（KTD13：本轮随之取消）——都以取消作答，从不替学员选允许。

`turn.end {stopReason, usage?, modelError?}`：

- `stopReason`：ACP 的 `end_turn` / `max_tokens` / `max_turn_requests` / `refusal` / `cancelled`，以及 Host 的 `error`（OMP 退出或本轮请求失败）。
- `usage`：本轮计费用量 `{inputTokens, outputTokens, totalTokens, cachedReadTokens?, cachedWriteTokens?, thoughtTokens?}`。
- `modelError`（R27）：`auth`（密钥无效、认证失败）或 `quota`（额度用尽、限流）时，这一轮 agent 的文字其实是模型报错——页面改为显示看得懂的说明，并指引学员去 OMP 检查模型配置，原文可折叠在说明里；`unknown` 时照常显示原文，附一句「可能是模型配置问题」。判定口径与局限见 `src/acp/events.ts` 的 `classifyModelError`。

KTD14：页面在 `turn.end`、`turn.card`、`history`（进入可对话状态）时重取学习详情。

## 安装、卸载与分发

安装与更新是同一条命令，重复执行即更新到最新版本，结果与装一次相同：

```bash
curl -fsSL https://api.codingirlsclub.com/ext/cgc-host/install.sh | bash
```

`install.sh` 依次：把清单和 Host 包下载到临时目录并校验 sha256，失败清理退出、不安装 Bun 或修改已有 Host/自启项 → 校验成功后查找 Bun，没有则用官方安装器装到 `~/.bun` → 停掉旧的 → 落位、写当前系统的登录自启项 → 启动。支持 macOS（Terminal）、Ubuntu 桌面（Terminal）与 Windows（Git Bash；命令同样一条，Bun 用官方 PowerShell 安装器）。Ubuntu 分支硬依赖 `zenity`（缺了就地报错 `sudo apt install zenity`）；Windows 分支硬依赖 Git Bash 的 `cygpath` 与系统自带 `powershell.exe`。

页面里的一键安装（期 2）：Host 把随包发布的 `src/agents/codex-acp.package.json` 与 `src/agents/codex-acp.lock`（Bun 的 text lock，每个包带 sha512）写进 `~/.cgc2046/agents/.tmp-*`，用**自己的 Bun** 跑 `bun install --frozen-lockfile --production --ignore-scripts`——不需要学员机器上有 npm/node，锁对不上或内容被篡改会被 Bun 拒绝，第三方依赖的 postinstall 也不会在学员机器上执行。装完校验版本、rename 原子就位，失败只删临时目录；上次被 SIGKILL 留下的 `.tmp-*` / `.old-*` 在**下一次安装开头**清理（Host 平时不碰这个目录）。托管安装的**入口从包 manifest 的 `bin["codex-acp"]` 解析**（Windows 上 Bun 只有 `.exe`/`.bunx`，不能拼无扩展名路径）；托管副本的版本必须与 Host 钉住的 `CODEX_ACP_VERSION` 一致才会被采用——Host 升级后旧副本自动让位，页面重新给出安装入口。换适配器版本 = `bun scripts/gen-agent-lock.mjs <版本>` 重算两份锁与常量（随 Host 发版）；CI 的 `scripts/check-agent-lock.mjs` 校验钉住的版本仍可获取、registry 的 integrity 与锁一致，以及复用变体锁的约束。锁文件用 `import ... with { type: "text" }` 内联进单包（deploy 的 `bun build` 之后包里没有额外文件）。

**复用变体（#1154）**：检测到学员已有可复用的 Codex engine（ChatGPT App 内置 / PATH 上的 `codex`，见 `agents/sources.ts`）时，优先装 `codex-acp-reuse.*`：用 `overrides` 把 `@openai/codex` 指向 Host 写进临时目录的本地 stub，只装适配器（约 18MB 落盘 / 2MB 下载），装完做一次 ACP `initialize` 探针（不发 prompt、不建会话、不消耗额度）确认 engine 兼容；探针失败自动回退全量安装。安装目录里 `variant.json` 记录变体；运行期 `codex.ts` 对 reuse 变体重新探测 engine 并注入 `CODEX_PATH`，engine 消失则 `present=false`、页面重新给安装入口。

学员电脑上的文件：

| 路径 | 内容 | 卸载时 |
| --- | --- | --- |
| `~/.cgc2046/host/cgc-host.js` | 包 | 删 |
| `~/.cgc2046/host/state.json` | 状态（含学习凭证，见 `src/state.ts`） | 先用凭证自撤销，再删 |
| `~/.cgc2046/agents/codex-acp/` | 页面里点「安装 Codex 支持」装上的适配器（`node_modules/` + 钉住的 `package.json`/`bun.lock`，约 337MB；`src/agents/install.ts`） | 删 |
| `~/.codex/` | 学员自己的 Codex 配置与登录 | **不碰**（安装也不碰） |
| 登录自启项 | macOS：`~/Library/LaunchAgents/com.codingirlsclub.cgc-host.plist`（`ProgramArguments` 是 Bun 与包的绝对路径加 `serve`；`RunAtLoad`；`KeepAlive {SuccessfulExit: false}`；`ThrottleInterval` 30；0644）。Ubuntu：`~/.config/systemd/user/com.codingirlsclub.cgc-host.service`（`ExecStart` 同上；`Restart=on-failure`；日志 append）。Windows：`%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\CGC Host.cmd`（经系统自带 PowerShell `Start-Process -WindowStyle Hidden` 隐藏拉起）。**三者都不含任何环境变量**（OMP 的环境由 Host 运行时解析，KTD12） | 删 |
| 日志 | macOS：`~/Library/Logs/cgc-host.log`。Ubuntu：`~/.local/state/cgc-host.log`。Windows：`%LOCALAPPDATA%\CGC\cgc-host.log` 与 `cgc-host.error.log`（stdout / stderr 分写） | 删 |
| `~/.bun/` | 学员原本没有 Bun 时由官方安装器装的 | 不删：Bun 可能已被学员别处使用 |
| `~/cgc2046_workspace/` | 学员的 CGC 工作区：终端插件与 Host 的 OMP 进程都在这儿，作业在 `~/cgc2046_workspace/courses/<userId>/<courseId>/` | **不碰**（安装也不碰） |

两处路径一一对应：`install.sh` 写哪儿，`src/uninstall.ts` 就删哪儿，改一边就改另一边。

卸载是包的 `uninstall` 子命令，只在本机执行、不下载任何东西，平台连不上也能卸。`install.sh` 结束时打印带实际 Bun 路径的这条命令，默认是：

```bash
~/.bun/bin/bun ~/.cgc2046/host/cgc-host.js uninstall
```

它依次：停掉自启的 Host（macOS `launchctl bootout` / Ubuntu `systemctl --user disable --now` / Windows 按命令行找到 `serve` 进程后 `Stop-Process`，三平台全部尽力尝试，本机不存在的命令或路径都是无声的 no-op）→ 用状态文件里的学习凭证自撤销（`revokeToken`，凭证不进 argv 与输出）→ 删除自启项、`~/.cgc2046/host/`（包与状态）、`~/.cgc2046/agents/`（页面里装的 agent）、日志，`~/.cgc2046` 空了也删（cgc-play 的 socket 也在里面）。撤销失败（平台不可达、状态文件读不出）时照样删完，并提示学员到课程学习页对话栏的「已配对的电脑」撤销这台电脑。

### 产物与部署

`deploy.yml` 的 backend job 在扩展产物之后构建 Host 产物，写进部署时生成的 backend/priv/static/ext/cgc-host/ 目录（gitignored），随 backend 镜像在 `/ext/cgc-host/*` 服务；`changes` 过滤里 `cgc-host/*` 也触发 backend 部署：

| 产物 | 来源 |
| --- | --- |
| `cgc-host.js` | `bun build src/main.ts --target=bun`，Bun 钉在 1.4.3、依赖 `pnpm install --frozen-lockfile` |
| `install.sh` | 原样拷贝 |
| `cgc-host.json` | `{version, download_path: "/ext/cgc-host/cgc-host.js", sha256}`：version 取 `package.json`，sha256 是包的 |

生产常量经 `--define` 写入（KTD4）：`CGC_SITE_ORIGIN` 是 GitHub production 环境变量 `NEXT_PUBLIC_WEB_BASE_URL` 的 origin——与 web 判定规范来源的 `web/lib/host-connection.ts` 同源，只认 https；`CGC_API_BASE` 是 `https://api.codingirlsclub.com`（与扩展分发、MCP 同一主机）。产物缺失、清单畸形、包里出现 `http://localhost`、`http://127.0.0.1` 这类本机来源（即常量没写入），部署都失败。

### 版本纪律（KTD15）

`scripts/check-version-bump.ts` 比较线上清单与本次构建的包：sha256 变了而 `package.json` 的 version 没变，部署失败。包是单个 JS 文件、构建确定（同一份源码与锁文件构建出相同的字节，换个目录构建也一样），所以 sha256 就是内容指纹；线上清单只有明确 404 按首次发布放行；不可达、超时、其他非 2xx 或畸形时失败，不能放行。生产常量也在包里：换了站点来源或 Bun 版本，同样要提高版本号。

- **改了包就提高 `package.json` 的 version**；要让已装旧版的学员必须更新，同时提高 `web/lib/host-version.ts` 的 `MIN_HOST_VERSION`——页面低于它就提示重装。
- **`install.sh` 不计入门禁**：它每次安装、更新都现下载，改动对下一次执行立即生效；version 描述的是 `/health` 报告的那份包。若 `install.sh` 的改动要已装的学员重装才生效（例如 plist 变了），按上一条手动提高两个版本号。

## 测试与许可扫描

在 `cgc-host/` 内执行（CI 的 `host` job 跑同一组命令，暂非必过检查）：

| 目的 | 命令 |
| --- | --- |
| 按锁文件安装依赖 | `pnpm install --frozen-lockfile` |
| 测试 | `bun test` |
| 安装、卸载与版本门禁（临时 HOME，`launchctl` 用垫片，不碰本机 launchd） | `bash test/install.test.sh` |
| 锁里每个 registry 条目的版本/integrity 仍与 registry 一致，且许可按 §2 白名单（需要网络；CI 的 host job 同一命令） | `bun scripts/check-agent-lock.mjs` |
| 依赖许可扫描（复用 `web/scripts/check-licenses.mjs`，扫本包的全依赖树） | `pnpm check:licenses` |

单元测试覆盖不了 launchd 的环境与开机自启：改了 `install.sh` 或 plist，要在真机上装一次、重启一次，确认不手动启动也能从页面连上并完成一次模型对话。
