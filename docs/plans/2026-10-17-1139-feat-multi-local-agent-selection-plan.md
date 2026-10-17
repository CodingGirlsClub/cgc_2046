---
title: "课程页本机 Agent 选择（先接 Codex）- Plan"
type: feat
date: 2026-10-17
topic: multi-local-agent-selection
artifact_contract: ce-unified-plan/v1
product_contract_source: session-2026-10-17
execution: code
---

# 课程页本机 Agent 选择（先接 Codex）- Plan

## Goal Capsule

- **Objective：** 已经在自己电脑上装了别的 coding agent（先支持 Codex）的学员，也能在课程学习页用它学完一个学习目标——自己选 agent、自己选历史对话，学习进度与课程作业目录两边共用。
- **Means：** 把 `cgc-host` 里写死的 OMP 抽成 agent 注册表（ADR-0022 否决私有 RPC 时就留下了 ACP 这条接缝），Codex 经 `@agentclientprotocol/codex-acp` 接入；页面在对话栏里给出 agent 选择与按 agent 分组的历史对话。
- **Authority：** 2026-10-17 会话中用户确认的两条产品决策：① 期 1 先做 BYO 探测（学员自己装 `codex-acp`），期 2 再做 Host 一键安装；② 抬高 `MIN_HOST_VERSION` 强制更新。ADR-0023 记录方向性决定并修订 ADR-0022 的适用范围。
- **Execution profile：** 两阶段：A Host 接缝（U1–U4）→ B 网页（U5、U6）→ C 真机验收（U7）。`cgc-host/**` 与 `web/lib/host-version.ts` 在根 `AGENTS.md` 的人工合并范围内，实施 PR 由人合并。
- **Stop conditions：** 出现以下任一条即停下重议：
  - 适配器升级后 node 入口在 Bun 下跑不起来，回退路线（`CODEX_PATH` 指原生二进制、仍由 Bun 跑适配器）也不成立——「Host 侧不新增 node 依赖」的前提不成立（macOS arm64 已在 2.2.2 上实测通过，见 Dependencies）。
  - 学习凭证出现在 Codex 自己的会话存储里，而处置口径无法接受——R12 不成立。
  - 学员 Codex 配置里的同名 MCP 服务器无法用改名避开（去重行为随适配器版本变化）——R9 不成立。
- **Who finishes：** 本计划执行到 U7 的验收与变更记录。`develop → main` 发布、`MIN_HOST_VERSION` 的抬高随发布一起发生，由人执行。

---

## Product Contract

### Summary

课程学习页的对话栏现在只驱动学员自己的 OMP。学员里已经有人在用 Codex（以及 Claude Code）：他们的模型额度、审批习惯、会话历史都在那个 agent 里。这一期让 Host 把「驱动哪个本机 agent」变成一张注册表，先接入 Codex；页面让学员自己选，历史对话按 agent 分组，学习进度与作业目录不受影响。

### Problem Frame

- 对话栏目前写死 `omp acp`：`cgc-host/src/omp.ts` 只找 `omp`，`src/main.ts` 只组装一个进程，`state.json` 每门课只记一个 `sessionId`（ADR-0022 KTD6）。
- 学员的 agent 选择是一种「我这台电脑上装了什么」的事实，而 ACP 是通用协议：`@agentclientprotocol/codex-acp` 已实现 `session/new`、`session/load`、`session/list`、`session/request_permission`，客户端 MCP 下发支持 HTTP + headers——与 Host 现在依赖的方法面重合。
- 页面今天的状态机把「找不到 OMP」（`noOmp`）当成唯一的「没有 agent」状态；多 agent 之后它要分裂成「一个都没有」与「这个 agent 起不来」。
- 上下文无法在 agent 之间迁移（各家的会话存储与提示格式都不同），所以「换 agent」在语义上等于「换一段对话」——历史与选择器的形态必须如实反映这一点。

### Actors

- A1. 学员：在自己电脑上装了 OMP 或 Codex，用自己的模型额度学习。
- A2. 学员的本机 agent：OMP（经 `omp acp`）或 Codex（经 `codex-acp`），沿用学员自己的配置与登录。
- A3. CGC 本机 Host（`cgc-host`）：页面与 agent 之间的桥，负责任务路由、会话指针、启动语、卡片。
- A4. 课程学习页的对话栏。

### Key Decisions

- **接缝是 ACP 的 agent 注册表，不是某个 agent 的专用通路。** (session-settled: user-directed — 用户要求「支持更多本机 agent，先从 Codex 开始」；ADR-0022 已否决 Host 与 OMP 之间的私有 RPC，理由正是「之后其他 agent 可以从同一接缝接入」。) Governs R1, R5, R10.
- **Codex 经官方适配器接入，不自建 ACP 服务端。** `@agentclientprotocol/codex-acp`（Apache-2.0）是一个独立进程，Host 与它的边界只有 ACP stdio；不直连 Codex 的 app-server 私有协议。 Governs R5, R6.
- **期 1 只做 BYO 探测，一键安装留到期 2。** (session-settled: user-directed — chosen over 期 1 直接做 Host 一键安装：先把接缝与真实需求验证掉，下载、完整性校验、装/卸与供应链责任单独一期。) Governs R5, R6.
- **历史按 agent 分组，不合并成一列。** 上下文不可迁移；合并列表会让「同一条对话」在学员眼里跨 agent 延续。 Governs R8.
- **强制更新一次：`MIN_HOST_VERSION` 抬到 `0.2.0`。** (session-settled: user-directed — chosen over 靠能力探测静默降级：入口级新能力需要可见性，绝大多数存量学员不会主动重装。) 代价与缓解见 Risks。 Governs R13.
- **协议改动全部是纯增量的，`protocolVersion` 不升。** 与 #1145 同一纪律：新增字段与方法对旧页面无害，旧 Host 对新方法回 `unknown_method`；强制更新由版本门承担，不由协议版本承担。 Governs R13.

### Requirements

**Agent 就绪与选择**

- R1. 对话栏在本机有 ≥2 个可用 agent 时给出选择控件；只有 1 个时只显示当前 agent 的静态标签；一个都没有时显示「本机未安装可用的 agent」，并列给出各 agent 的安装指引。
- R2. 默认选中的 agent 依次取：这门课上次用过的 → 这台电脑上次用过的 → 唯一可用的 → OMP。
- R3. 切换 agent 只切换这段对话的驱动者：不迁移上下文；每门课每个 agent 各保留自己的当前对话，切回时回到它自己的那条。
- R4. 有回合正在跑时不切换（提示先停止）；切换完成后，页面上的设置项（模型、思考等级，见 #1145）整体换成新 agent 的值。

**Codex 就绪**

- R5. 学员电脑上装好 `codex-acp` 即被探测到，不需要学员在 CGC 页面里做任何配置；检测结果随 `/health` 与 `status` 一起上报。
- R6. Codex 未登录时，对话栏给出登录入口：学员点一下，在他自己电脑的浏览器里完成 ChatGPT 登录（或改用 API Key），全程不打开终端；登录成功后原地回到可对话。
- R7. Codex 侧的审批沿用适配器自己的默认模式（Auto review），Host 不注入审批模式、不调 `session/set_mode`（与 ADR-0022 KTD5 同一纪律）；学员自己的 Codex 配置与终端使用不受影响。

**历史对话**

- R8. 历史对话列表按 agent 呈现：默认列出当前 agent 在这门课工作目录下的对话（时间 + 消息数）；选中另一个 agent 的对话，即一次完成「切 agent + 载入那条对话」。
- R9. 下发给 Codex 会话的 CGC MCP 服务器使用与终端配置不同的名字，学员自己配置里已存在的同名服务器不会顶掉带学习凭证的那一份。
- R10. 「新开对话」只对当前 agent 生效，不影响其他 agent 的当前对话。

**发起、恢复与安全**

- R11. 学习模式启动语在两种 agent 上都生效：OMP 经 `--append-system-prompt`，Codex 经课程工作目录里的 `AGENTS.md`。
- R12. 学习凭证只经 ACP 的 `mcpServers` 下发（与 ADR-0022 相同）；Host 的日志、argv、HTTP 响应体里不出现凭证，Codex 自己的会话存储里也不出现。
- R13. 旧 Host（0.1.5）连新页面时进入「Host 需要更新」并给出更新命令；新 Host 连旧页面（回滚期）时 OMP 路径照常可用。

### Key Flows

- F1. 首次用 Codex 学习
  - **Trigger：** 学员电脑上装了 `codex-acp`、但没登录（或已登录）的学员打开课程学习页。
  - **Steps：** 对话栏出现 agent 选择器 → 学员选 Codex → 未登录则出现登录卡，点一下在本机浏览器完成登录 → 学员发第一条消息 → agent 读学习状态、讲解与练习 → 正式评价 → 课程页掌握状态即时更新。
  - **Outcome：** 学员没打开终端就从「装了 Codex」走到「掌握了一个目标」。
  - **Covered by：** R1, R5, R6, R11
- F2. 平日学习：选 agent 与翻历史
  - **Steps：** 学员隔天打开同一门课 → 对话栏按上次的选择直接接上那个 agent 的对话 → 在历史下拉里翻当前 agent 的旧对话 → 想看另一台 agent 的对话时点它的行（切 agent 并载入）→ 切回原 agent 时回到它自己那条。
  - **Covered by：** R2, R3, R8, R10
- F3. 降级
  - **Steps：** 只有一个 agent 时没有选择器；一个都没有时给安装指引；某个 agent 起不来（路径存在但握手失败）时提示该 agent 不可用并指向另一个可用的。
  - **Covered by：** R1, R13
- F4. 回滚期
  - **Steps：** web 回滚、Host 仍是新版：旧页面（不带 `agent` 参数）照常走 OMP（R13 后半）。
  - **Covered by：** R13

### Acceptance Examples

- AE1. 本机装了 `codex-acp` 且未登录：选 Codex → 出现登录卡 → 点「用 ChatGPT 登录」→ 本机浏览器完成登录 → 页面回到可对话 → 一条消息正常完成回合，并调用到 CGC 学习工具。**Covers R5, R6, R11。**
- AE2. OMP 与 Codex 各有对话：历史下拉逐条列出两个 agent 的对话；选中 Codex 的某条 → 页面切到 Codex 并载入那条；再选 OMP 的某条 → 切回 OMP 且原来的对话仍在原处。**Covers R3, R8。**
- AE3. 只有 OMP 的学员：对话栏没有选择器，只有「由 OMP 驱动」的静态标签，行为与上线前逐项一致。**Covers R1, R2。**
- AE4. 一个 agent 都没有：出现「本机未安装可用的 agent」，并列给出 OMP 与 Codex 两条指引。**Covers R1。**
- AE5. 装 0.1.5 的 Host 打开新页面：进入「Host 需要更新」并给出更新命令；按提示更新后恢复可对话，并能选到 Codex。**Covers R13。**

### Scope Boundaries

**Not building（本期）**

- Claude Code 接入：注册表留位置，取证与接入另开 issue。
- Host 一键安装 `codex-acp`（下载、完整性校验、安装/卸载清理、安装进度 UI）：期 2 另开 issue。
- agent 之间的上下文迁移、跨设备历史、按课程/教研强制指定 agent。
- 后端与平台侧改动：凭证、工具收窄、审计一律不变。
- 学员 Codex 配置的读写：Host 只做探测与启动。

**Deferred / open（不阻塞本期）**

- Codex 侧的额度类错误归类（#1145 之外的 R27 口径）：先落 `unknown`。
- 平台侧「学员用了哪个 agent」的统计：不做，Host 不上报这类信息。

### Dependencies / Assumptions

- 学员机器上由学员自己装好 `codex-acp`（取证基线：`@agentclientprotocol/codex-acp` 2.2.2，Apache-2.0；ACP `protocolVersion 1`，`loadSession: true`，`sessionCapabilities {list, close, delete, fork}`，`mcpCapabilities {http: true}`）。适配器升级后，本计划假定的能力面需重新核对。
- 适配器默认用 `require.resolve("@openai/codex/bin/codex.js")` + `process.execPath` 拉起 Codex；Host 由 Bun 运行，因此 `process.execPath` 就是 Bun。**已实测（2026-10-17，macOS arm64，Bun 1.4.3，`@agentclientprotocol/codex-acp` 2.2.2）：Bun 跑通适配器入口并完成 ACP `initialize` 握手**——`protocolVersion 1`、`agentInfo.title = Codex`、`loadSession: true`、`sessionCapabilities {resume, list, close, delete, fork, additionalDirectories, subagents}`、`mcpCapabilities {http: true}`、`authMethods = [api-key, chat-gpt]`（device-code 需要 url elicitation，Host 不声明故不出现），并由 Bun 拉起 `@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex app-server`。Windows / Ubuntu 未测，适配器升级后须重跑探针（回退路线见 Risks）。
- 学员的 ChatGPT / OpenAI 账号与模型额度归学员自己（BYO，ADR-0001 不变）；平台不运行模型。
- #1145（模型与思考等级）与本期的耦合：`history.settings` 随所选 agent 的会话返回，切 agent 即整体重取。

### Sources / Research

- `docs/adr/0022-course-page-local-agent-host.md`：KTD5（ACP 接缝、不注入审批模式）、KTD6（会话指针与工作目录）、KTD12（登录 shell 环境）、KTD13（按需拉起与回收）、KTD15（版本门）。
- `docs/plans/2026-10-14-1446-feat-course-page-local-agent-chat-plan.md`：R7–R29 的对话栏契约与状态机。
- #1145：模型/思考等级（`history.settings`、`chat.set_setting`、不升 protocolVersion 的纪律）。
- `@agentclientprotocol/codex-acp@2.2.2` 发布包 `dist/index.js` 本地解包核对：`initialize` 响应、`newSession`/`loadSessionOnce`、`listSessions`（按 cwd 过滤）、`createSessionConfig`（`mcp_servers` + 同名去重）、`CodexAuthMethod.ts`（`api-key` / `chat-gpt` / `chat-gpt-device-code`）、`authenticateWithChatGpt`（`open` 开浏览器）、`AirExtension.ts`（`customInstructions`）、`DEFAULT_AGENT_MODE = Agent`。
- 2026-10-17 本机 stdio 握手探针（macOS arm64、Bun 1.4.3、`bun add @agentclientprotocol/codex-acp@2.2.2` 装进 `/tmp/codex-probe`）：ACP `initialize` 成功，回 `protocolVersion 1` / `loadSession: true` / `sessionCapabilities {resume, list, close, delete, fork, additionalDirectories, subagents}` / `mcpCapabilities {http: true}` / `authMethods = [api-key, chat-gpt]`；`process.execPath`（Bun）成功拉起 `codex.js` 与原生 `codex app-server`；**`SIGKILL` 适配器后 app-server 变孤儿，正常关 stdin 后 5 秒内两者都退出**（KTD9 的来源）。

---

## Planning Contract

### Key Technical Decisions

- KTD1. **agent 注册表 + 每 agent 一个进程代。** `AgentKind = "omp" | "codex"`，每条记录提供「定位、环境、启动、启动语注入、能力标记」；`acp/runtime.ts` 的进程代抽象按 kind 各建一个实例，空闲回收沿用 KTD13。
- KTD2. **会话指针按 (course, agent) 存，旧形状读时迁移。** `state.json` 的 `sessions` 变 `courseId → { <kind>: sessionId }`，另加 `agents: courseId → kind`（这门课的默认 agent）；读到旧形状（`courseId → sessionId`）时当作 `{ omp: 旧值 }` 并落盘一次。指针是「上次聊到哪儿」，不是唯一真相——丢了就从新对话开始（KTD6 既有口径）。
- KTD3. **协议纯增量：`status.params.agents: [{kind, present, envError?}]`、`/health.agents`、`chat.*` 的可选 `agent`（缺省 `omp`）、新方法 `chat.authenticate`。** 保留 `ompPresent` / `ompEnvError` 作为回滚桥（新 Host + 回滚后的旧页面），移除条件是下一个 Host 大版本。
- KTD4. **Codex 的登录走 ACP `authenticate`，不在页面里搬凭证。** ACP 错误 `-32000 auth_required` 映射成 `error {code: "auth_required", methods}`；`chat.authenticate {courseId, agent, methodId}` 转发给适配器，`chat-gpt` 方法由适配器在学员本机打开浏览器并等待回调。
- KTD5. **Codex 的启动语写课程工作目录的 `AGENTS.md`。** OMP 用进程级 `--append-system-prompt`；适配器的 `_meta.jetbrains.air.customInstructions` 只在 `session/new` 生效、`session/load` 不带，`AGENTS.md` 是唯一同时覆盖两者的通道。写入幂等（内容不变则不重写），只落在 `~/cgc2046_workspace/courses/<userId>/<courseId>/`。
- KTD6. **Codex 会话下发的 MCP 服务器名是 `cgc-2046-learning`。** 适配器会把「学员 Codex 配置里已存在的同名服务器」整条跳过（`shouldDeduplicateMcpConflicts`），同名会让带学习凭证的那份被学员的终端配置顶掉。
- KTD7. **能力差异如实降级，不做假控件。** Codex 没有 form elicitation（提问卡片不出现），上下文用量/费用未验证（不显示时不占位）；审批卡片与停止照常。页面按「字段存在与否」探测，不做版本号比较（与 #1145 同一纪律）。
- KTD8. **切换 agent 的收尾沿用既有路径。** 切 agent 时该课程在旧 agent 上正在跑的回合按「本机换了账号」那条既有收尾逻辑处理：待答卡片以取消作答、回合以 `cancelled` 结束，收尾期间的事件不再发给页面。
- KTD9. **Codex 的回收优雅优先，不直接 `SIGKILL`。** 实测（macOS arm64）：`SIGKILL` 适配器进程后，它拉起的 Codex app-server 仍存活（孤儿）；正常关 stdin 后两者都退出。所以 agent 记录的关闭分两步——先关 stdin / 走协议关闭，宽限期内没退再 `SIGKILL`；Windows 上 Bun 的 `kill` 不连带子进程，兜底用 `taskkill /T` 收整棵树（该分支以真机实测为准）。性质由 U4 的断言钉住：关闭后本机不残留 Codex 进程。

### High-Level Technical Design

```text
课程学习页（web）
  │  WS 127.0.0.1:47823
  ▼
CGC 本机 Host（cgc-host，Bun）
  ├── 协议层（server.ts）：status.agents / chat.* {agent} / chat.authenticate
  ├── 路由层（acp/session.ts）：Course → (agent, sessionId)，每 agent 一个 runtime
  └── agent 注册表（agents/）
        ├── omp   → omp acp  + --append-system-prompt     → ~/.omp
        └── codex → codex-acp（学员自己装）→ Codex        → ~/.codex
```

### Output Structure

```text
cgc-host/
  src/agents/registry.ts      # AgentKind 注册表：定位、启动、启动语、能力标记
  src/agents/omp.ts           # OMP 记录（由 src/omp.ts 迁移）
  src/agents/codex.ts         # Codex 记录：探测、登录、AGENTS.md、MCP 改名
  src/shell-env.ts            # 登录 shell 环境解析（KTD12，两种 agent 共用）
  src/acp/session.ts          # 按 (course, agent) 路由；切 agent 的收尾
  src/state.ts                # sessions 按 agent 分桶 + agents 默认值 + 旧形状迁移
web/components/learning/
  use-host-chat.ts            # agents / agent 选择 / 三种新状态
  host-chat-panel.tsx         # 选择器、登录卡、添加 agent
  host-chat-history.tsx       # 历史下拉的 agent 分组
```

### Risks & Dependencies

| 风险 | 影响 | 处理 |
|---|---|---|
| 适配器升级后入口不再能在 Bun 下运行 | 期 1 的 Codex 路径整体不成立 | 已在 macOS arm64 实测通过（见 Dependencies / Sources）；`cgc-host/scripts/probe-codex-acp.ts` 把这条握手固化成可重跑的探针，**每次升适配器版本跑一次**。真跑不动时回退 `CODEX_PATH` 直指 `@openai/codex-<平台>/vendor/<target>/bin/codex`（仍由 Bun 跑适配器），再不行按 Stop conditions 停下重议 |
| `SIGKILL` 适配器会留下孤儿 Codex 进程 | 学员机器上残留进程、白占内存 | 实测：`SIGKILL` 适配器后 app-server 子进程仍存活；正常关 stdin 后 5 秒内两者都退出。所以 Codex 的回收走「优雅优先」（KTD9），U4 用「关闭后不留孤儿」的断言钉住 |
| 学习凭证落进 `~/.codex` 的会话存储 | 凭证在本机多一处静态副本 | U7 做只读磁盘扫描（沿用 ADR-0022 U6 做法）；落盘则记入残余风险并给出轮换口径，不得静默放过 |
| 强制更新打断存量学员 | 部署当天全员进入「Host 需要更新」 | 强制更新前先完成 OMP 路径回归；CHANGELOG 与页面文案都带那一条更新命令；回滚桥保留 `ompPresent` |
| 适配器默认审批模式盖过学员 Codex 配置 | R7 的「沿用适配器默认」需如实说明 | 真机实测后把口径写进 ADR-0022 的修订与 `cgc-host/AGENTS.md`；不接受「页面里看起来一致」的自证 |
| 历史下拉要按需拉起另一个 agent 的进程 | 首次翻历史有秒级延迟 | 列表默认只查当前 agent；另一 agent 的进程只在切过去时拉起（与 KTD13 一致） |
| 同名去重规则随适配器版本变化 | R9 的规避失效 | U7 的变异验证（学员配置里预置 `cgc-2046` 时学习凭证那份仍被挂载）+ 适配器版本升级时重跑 |

---

## Implementation Units

| U-ID | 标题 | 主要文件 | 依赖 |
|---|---|---|---|
| U1 | agent 注册表与进程编排 | `cgc-host/src/agents/*`、`src/shell-env.ts`、`src/main.ts` | — |
| U2 | 协议与状态 | `cgc-host/protocol.json`、`src/server.ts`、`src/state.ts` | U1 |
| U3 | 对话层多 agent 路由 | `cgc-host/src/acp/session.ts` | U1、U2 |
| U4 | Codex 接入与登录 | `cgc-host/src/agents/codex.ts`、`test/fixtures/*` | U3 |
| U5 | 页面：选择器、历史、登录卡 | `web/components/learning/*`、`web/lib/host-version.ts`、`web/messages/*` | U2、U4 |
| U6 | 文档与门禁 | `docs/adr/0023-*`、`docs/adr/0022-*`、`cgc-host/AGENTS.md`、`GLOSSARY.md`、`CHANGELOG.md` | U1–U5 |
| U7 | 真机验收与记录 | 验收记录（PR 正文） | U1–U6 |

### U1. agent 注册表与进程编排

- **Goal：** Host 能把「驱动哪个 agent」当作注册表里的一条记录来处理，OMP 的行为零变化。
- **Requirements：** R5, R11
- **Files：** `cgc-host/src/agents/registry.ts`（新）、`cgc-host/src/agents/omp.ts`（由 `src/omp.ts` 迁移）、`cgc-host/src/shell-env.ts`（新，拆出登录 shell 环境解析）、`cgc-host/src/main.ts`、`cgc-host/scripts/probe-codex-acp.ts`（新，可重跑的握手探针）、`cgc-host/test/{omp,agent-registry}.test.ts`
- **Approach：**
  1. 记录形状：`{ id, label, locate(): Promise<{ path: string | null; env; envError }>, spawn(app, cwd, signal): Agent, prepare(cwd): Promise<void>, capabilities }`。
  2. `acp/runtime.ts` 不改抽象，按 kind 各建一个实例；`main.ts` 只做组装与组装后的 `status` 上报。
  3. Bun 拉 `codex-acp` 已在 macOS arm64 实测通过（见 Dependencies / Sources）；这条握手固化成 `cgc-host/scripts/probe-codex-acp.ts`（手动跑、不进 CI 必过门禁；升级适配器版本时跑一次），之后再做 U2–U4。
  4. 探针脚本只做 `initialize` 与一次会话握手，不携带任何凭证（与 R12 的纪律一致）。
- **Test scenarios：** 两种 kind 的 `locate` 命中/未命中；未命中时该 kind 在上报里 `present: false`；一个 kind 的进程崩溃不影响另一个 kind 的进程代（fake agent 各一）。
- **Verification：** `cd cgc-host && bun test`；现有 `omp.test.ts` / `session.test.ts` 断言不改即通过。

### U2. 协议与状态

- **Goal：** 页面能读到「本机有哪些 agent」，能按 agent 发指令；老对话不因形状变化丢失。
- **Requirements：** R1, R5, R13
- **Files：** `cgc-host/protocol.json`、`cgc-host/src/server.ts`、`cgc-host/src/state.ts`、`cgc-host/test/{protocol,state,server}.test.ts`
- **Approach：**
  1. `status.params` 增 `agents`，OMP 那条仍附旧字段 `ompPresent` / `ompEnvError`；`/health` 增 `agents`。
  2. `chat.*` 收可选 `agent`（缺省 `omp`；不在注册表 → `bad_request`）；`chat.authenticate` 进 `pageToHost` 白名单。
  3. 错误码增 `agent_unavailable`、`auth_required`（带可选 `methods`）、`auth_failed`。
  4. `state.ts`：`sessions` 分桶 + `agents` 默认值 + 旧形状迁移（一次性落盘）；文件权限不变（0700/0600）。
- **Test scenarios：** 旧形状状态文件 → 读出旧对话、迁移后写回新形状；未知 agent → `bad_request`；不带 `agent` 的调用走 OMP（回滚桥）；协议契约测试两侧对齐 `protocol.json`。
- **Verification：** `bun test`；`bun test test/protocol.test.ts` 与 web 侧 `pnpm test web/lib/host-connection.test.ts`。

### U3. 对话层多 agent 路由

- **Goal：** 同一门课上，两个 agent 的对话互不串；切换有明确的收尾与指针语义。
- **Requirements：** R2, R3, R4, R8, R10
- **Files：** `cgc-host/src/acp/session.ts`、`cgc-host/test/{session,agents}.test.ts`、`cgc-host/test/helpers.ts`
- **Approach：**
  1. `Course` 记录当前 `agent`；`attach` / `send` / `new` / `sessions` / `open` / `stop` / `card.answer` 按 (courseId, agent) 找 runtime 与指针。
  2. 切 agent 时对旧 agent 的在跑回合走 KTD8 的收尾；`chat.sessions` 只列所选 agent 在课程目录下的会话；`history` 的 `settings`（#1145）随该 agent 的会话返回。
  3. 页面首次打开时的默认 agent：若请求未带 `agent`，用 `state.agents[courseId]`。
- **Test scenarios：** 双 kind 各跑一轮、事件不串（fake agent 两个实例，同一 courseId）；切 agent 时旧回合收尾且卡片按取消作答；`chat.sessions` 不混两个 agent 的会话；`chat.new` 只动当前 agent 的指针。
- **Verification：** `bun test test/session.test.ts test/agents.test.ts`。

### U4. Codex 接入与登录

- **Goal：** 装了 `codex-acp` 的学员能从页面登录 Codex 并完成一轮真实学习对话。
- **Requirements：** R5, R6, R7, R9, R11, R12
- **Files：** `cgc-host/src/agents/codex.ts`、`cgc-host/src/acp/session.ts`（错误映射与启动语注入点）、`cgc-host/test/codex.test.ts`、`cgc-host/test/fixtures/*`
- **Approach：**
  1. 定位：登录 shell 的 PATH 上找 `codex-acp`（找不到则该 kind `present: false`）；启动时带上学员的环境。
  2. 登录：`initialize` 后读 `authMethods`；把 ACP `-32000` 映射成 `auth_required`；`chat.authenticate` 转发 `authenticate`，`chat-gpt` 由适配器开浏览器；成功后页面重新 attach。
  3. 会话：`session/new` / `session/load` 下发 `mcpServers`（`cgc-2046-learning` + `authorization` 头）；`prepare(cwd)` 写 `AGENTS.md`（幂等，带托管标记）。
  4. 启动语文本与 OMP 侧**同一常量**（与 agent 无关的措辞，不写死某家的工具命名）。
  5. 关闭按 KTD9：先关 stdin 让适配器连同 app-server 一起退出，宽限期内没退再 `SIGKILL`（Windows 分支用 `taskkill /T` 收整棵树）。
- **Test scenarios：** 未登录 → `auth_required` 带方法列表，且方法只有 `api-key` 与 `chat-gpt`（device-code 需要 url elicitation，Host 不声明故不出现）；`authenticate` 成功后同一课程可跑回合；`AGENTS.md` 幂等（二次调用不改内容）；下发的服务器名不是 `cgc-2046`；凭证不出现在 Host 日志与响应体（fixture 断言 `cgch_` 不出现）；按 KTD9 关闭后不留孤儿（真机以 `pgrep` 归零断言）。
- **Verification：** `bun test`；真机：选 Codex → 登录 → 一轮对话（调用 `get_role_playbook`）→ 一次评价 → 徽章变化。

### U5. 页面：选择器、历史与登录卡

- **Goal：** 学员能看见自己在用哪个 agent、切换它、翻每个 agent 的历史，并在需要时登录。
- **Requirements：** R1, R2, R3, R4, R6, R8, R10, R13
- **Files：** `web/components/learning/{use-host-chat.ts,host-chat-panel.tsx,host-chat-history.tsx}`、`web/lib/host-version.ts`、`web/messages/{zh-CN,en}.json`、对应测试文件
- **Approach：**
  1. `use-host-chat`：读 `status.agents`；新增 `noAgent` / `agentNeedsAuth` / `agentUnavailable` 三态；`agent` 选择一处状态源，历史下拉的 chips 与标题行选择器共用它。
  2. `host-chat-panel`：≥2 个 agent 时出现选择器，否则静态标签；登录卡调用 `chat.authenticate`；「添加 agent」入口列出支持的 agent 与状态（期 1 给安装指引与复制按钮）。
  3. `host-version.ts`：`MIN_HOST_VERSION = "0.2.0"`；`host-connection.test.ts` 与 `protocol.json` 的契约断言同步。
  4. 切 agent 后整体重取 `history` 与 `settings`（与 #1145 的耦合）。
- **Test scenarios：** 单 agent 无选择器；双 agent 选择器出现且默认上次；切 agent 后 `settings` 重取；`auth_required` 显示登录卡，成功后进入可对话；旧 Host（无 `agents`）被版本门拦住并给出命令；zh-CN 与 en 键集合一致。
- **Verification：** `pnpm test`、`pnpm typecheck`、`pnpm lint`、`pnpm build`、`pnpm check:licenses`；ego-browser 量取几何后断言（选择器仅在 ≥2 agent 出现、切换后标题与设置项变化）。

### U6. 文档与门禁

- **Goal：** 方向、协议与纪律落成可查的记录。
- **Files：** `docs/adr/0023-multiple-local-agents.md`（proposed → accepted）、`docs/adr/0022-course-page-local-agent-host.md`（补 Codex 侧口径与残余风险）、`cgc-host/AGENTS.md`（协议表、每 agent 一个进程、两种启动语注入、版本纪律）、`GLOSSARY.md`、`CHANGELOG.md`
- **Approach：** 实现落地后 ADR-0023 转 accepted；`cgc-host/AGENTS.md` 的协议表加 `agent` 参数、`chat.authenticate`、新错误码与 `status.agents`；CHANGELOG 的 `[Unreleased]` 记一条（端标签按既有约定）。
- **Test scenarios：** `node scripts/check-agent-docs.mjs` 通过；术语表新词条与 ADR 一致。
- **Verification：** 上述命令 + `bun test`、`pnpm test` 全绿。

### U7. 真机验收与记录

- **Goal：** 用可复查的证据证明 AE1–AE5 与两条安全性质成立。
- **Requirements：** 全部 R 与 AE
- **Approach：**
  1. 逐条跑 AE1–AE5，留截图、命令输出与 ACP 侧事件片段；同时跑一遍 OMP 老路径回归（只装 OMP 的机器）。
  2. 只读磁盘扫描 `~/.codex`：不出现学习凭证（按 ADR-0022 U6 的做法，只看文件名与是否命中凭证前缀）。
  3. 变异验证两条：把 `status.agents` 拿掉 → 页面断言变红；把下发的 MCP 名改回 `cgc-2046` → 去重用例变红（fake agent 模拟「学员配置里已有同名」）。
  4. 刷新 `CHANGELOG.md` 的 `[Unreleased]`。
- **Test expectation：** none — 本单元产出验收记录与变更日志。
- **Verification：** PR 正文里 AE1–AE5、磁盘扫描与两条变异验证都有结论与证据。

---

## Verification Contract

| 范围 | 命令 / 方式 | 单元 | 通过信号 |
|---|---|---|---|
| Host 测试 | `cd cgc-host && bun test` | U1–U4 | 全绿，OMP 既有断言未改 |
| Host 许可扫描 | `cd cgc-host && pnpm check:licenses` | U1–U4 | 全绿（新增依赖只有学员本机侧，不进本仓树） |
| 协议契约 | `cgc-host/test/protocol.test.ts` + `web/lib/host-connection.test.ts` | U2, U5 | 两侧对 `protocol.json` 的断言一致 |
| web | `cd web && pnpm test && pnpm typecheck && pnpm lint && pnpm build && pnpm check:licenses` | U5 | 全绿 |
| 界面 | ego-browser 驱动 Chrome，先量取计算样式与几何，再做断言 | U5 | 选择器出现条件、切 agent 后的标题与设置项、登录卡与三态都符合预期 |
| 文档引用 | `node scripts/check-agent-docs.mjs` | U6 | 通过 |
| 真机全链 | macOS + Chrome 跑 AE1–AE5 与 OMP 回归 | U7 | 全部有结论与证据 |
| 安全性质 | 只读扫描 `~/.codex`（不见 `cgch_`）；Host 日志/argv/响应体断言 | U4, U7 | 无凭证落盘 |
| 变异验证 | U7 的两条（去掉 `status.agents`、MCP 名改回 `cgc-2046`） | U5, U7 | 改坏后断言变红，还原后变绿，两步输出留在同一会话 |

## Definition of Done

- DoD1. Verification Contract 中适用的门禁全部通过，输出留在 PR 里。
- DoD2. 装了 `codex-acp` 的学员在真机上完成 AE1：页面内登录 → 一轮学习对话（含一次 CGC 学习工具调用）→ 一次评价 → 不刷新页面看到掌握徽章变化。
- DoD3. AE2 成立：两个 agent 的历史各自可见、一步切换、切回后原对话在原处。
- DoD4. AE3 成立：只装 OMP 的学员看到的行为与上线前一致（回归用例 + 真机）。
- DoD5. AE4 成立：没有 agent 时给两条安装指引，而不是只提 OMP。
- DoD6. AE5 成立：0.1.5 的 Host 打开新页面进入「Host 需要更新」并给出命令；新 Host 在回滚后的旧页面上仍能跑 OMP。
- DoD7. 安全性质成立：`~/.codex` 的只读扫描不见学习凭证；凭证不出现在 Host 日志、argv、HTTP 响应体。
- DoD8. 两条变异验证都做坏 → 红、还原 → 绿，输出留在会话里。
- DoD9. 临时的探针目录与实验代码都已删除，diff 里只留下方案本身需要的文件。
