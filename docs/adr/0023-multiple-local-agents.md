---
status: proposed
date: 2026-10-17
---

# ADR-0023：课程学习页对话栏支持多个本机 agent（先接 Codex）

> 日期：2026-10-17 ｜ 状态：**提议中（Proposed）**——实施 PR 落地后转 accepted

ADR-0022 让课程学习页经 CGC 本机 Host 驱动学员自己的 agent，接的只是 OMP（`omp acp`）。但学员的 agent 不止一种：已经有人用 Codex、Claude Code，把各自的模型额度、审批习惯与会话历史留在那边。ADR-0022 否决「Host 与 OMP 之间用私有 RPC」时的理由正是「ACP 是标准协议，之后其他 agent 可以从同一接缝接入」——本 ADR 兑现那条理由：Host 里写死的 OMP 变成 agent 注册表，先接入 Codex。完整设计、需求与验收见 `docs/plans/2026-10-17-1139-feat-multi-local-agent-selection-plan.md`，下文的 KTD 编号均指该计划。

决定：

- **驱动哪个 agent 是 Host 注册表里的一条记录，协议只做增量。** `AgentKind` 先有 `omp` 与 `codex` 两种；`status` 上报 `agents: [{kind, present}]`，`chat.*` 收一个可选 `agent`（缺省 `omp`），新增 `chat.authenticate`。`protocolVersion` 不升：这些改动对旧页面无害，旧 Host 对新方法回 `unknown_method`；`ompPresent` 保留到下一个 Host 大版本，只作为 web 回滚期的桥。每门课每个 agent 各记一条会话指针（`state.sessions[courseId][agentKind]`），旧形状读时当作 `{ omp: 旧值 }` 迁移。
- **Codex 经它自己的 ACP 适配器接入，不自建 ACP 服务端、不碰 Codex 私有 app-server 协议。** 学员自己装 `@agentclientprotocol/codex-acp`（Apache-2.0，实测基线 2.2.2：ACP `protocolVersion 1`、`loadSession: true`、`session/list`、`mcpCapabilities {http: true}`），Host 只经 stdio 与它讲 ACP。本期只做探测（BYO）：装了就出现，没装就给安装指引；Host 替学员下载安装留到期 2（另开 issue）。
- **登录在页面里发起，凭证不经过页面。** 未登录时适配器对 `session/new` / `prompt` 回 ACP `auth_required(-32000)`，Host 把它连同 `authMethods` 报给页面；学员点「用 ChatGPT 登录」，由适配器在学员本机打开浏览器完成 OAuth（`chat-gpt`），或改用 API Key。页面只是发起者，不接触 token。
- **「换 agent」在语义上是「换一段对话」。** 上下文无法跨 agent 迁移，所以历史列表按 agent 分组呈现（默认当前 agent，选中另一 agent 的对话即一步完成「切 agent + 载入」），不做合并列表；切换有回合在跑时先按既有收尾逻辑（卡片按取消作答）结束本轮。
- **启动语按 agent 各自的原生通道注入。** OMP 沿用 `--append-system-prompt`；Codex 写课程工作目录的 `AGENTS.md`（幂等、带托管标记）——适配器的 `_meta.jetbrains.air.customInstructions` 只在 `session/new` 生效，`session/load` 不带，`AGENTS.md` 是唯一同时覆盖两者的通道。两处文本来自同一常量，措辞与具体 agent 的工具命名解耦。
- **下发给 Codex 的 CGC MCP 服务器改名 `cgc-2046-learning`。** 适配器会整条跳过「Codex 配置里已存在的同名服务器」，同名会让带学习凭证的那份被学员终端配置里那份顶掉。OMP 侧维持原名不变。
- **强制更新一次：`web/lib/host-version.ts` 的 `MIN_HOST_VERSION` 抬到 `0.2.0`。** 与 #1145（模型/思考等级）选择「不强制、靠能力探测」不同：那是增量小功能，这是入口级新能力，静默降级会让绝大多数存量学员永远看不到 Codex 入口。代价是部署当天全员要重跑一次安装命令，缓解见「残余风险」。
- **Codex 侧的审批沿用适配器的默认模式，Host 不注入、不切换。** 适配器默认模式是 `Agent`（Auto review：on-request + 自动复核 + workspace-write），它会盖过学员 `~/.codex/config.toml` 里的审批设置——因此 ADR-0022 的 R18「工具、审批模式和模型都与学员在终端里一致」对 Codex 只部分成立，须在 ADR-0022 的修订里改成「OMP 侧与终端一致；Codex 侧由适配器默认模式决定」。

否决的路线：

- **只做 Codex、把 OMP 那条路改成通用写法之外的私接**：同一个接缝必须对两种 agent 一视同仁，否则第三个 agent 还要再改一遍路由与会话指针。
- **用 Codex 的 app-server 私有协议直连**：等于自己维护一份 ACP 适配器，版本跟踪与协议漂移都落到本仓库。
- **历史合并成一列（跨 agent 混排）**：上下文不可迁移，混排会让学员以为同一条对话跨 agent 延续。
- **把 agent 选择做成全局偏好或按课程/教研下发**：学员的 agent 是「我这台电脑上装了什么」的事实，不是课程属性；同理不做「平台记录学员用了哪个 agent」。
- **期 1 直接做 Host 一键安装**：安装面（下载、完整性校验、装/卸清理、进度 UI）与供应链责任值得单独一期，先把接缝与真实需求验证掉。
- **不抬 `MIN_HOST_VERSION`、靠能力探测静默降级**：见上，入口级能力的可见性优先于「不打断存量学员」。

残余风险：

- **学习凭证可能落进 Codex 自己的会话存储。** 适配器把 `mcp_servers`（含 `authorization` 头）交给 Codex，Codex 的线程存储是否原样落盘未验证。真机按 ADR-0022 U6 的做法做只读扫描（只看文件名与凭证前缀是否出现）；若落盘，如实记入本 ADR 并给出轮换口径，不得静默放过。
- **强制更新打断正在学习的存量学员。** 部署当天，所有 0.1.5 的 Host 都会让对话栏进入「Host 需要更新」直到重跑一次安装命令。缓解：更新前先跑完 OMP 路径的真机回归（新 Host 的 OMP 路径行为不变）；页面文案与 CHANGELOG 都带那一条命令；web 回滚时旧页面靠保留的 `ompPresent` 继续可用。
- **学员 Codex 配置里预置了同名 MCP 服务器。** 已用改名规避，但「同名去重」的行为随适配器版本变化，升级适配器时要重跑变异用例。
- **适配器默认审批模式与学员终端习惯不一致。** 学员在终端里设成「免审批」时，页面里的 Codex 可能仍弹审批卡（反向也可能）。这不算越权（沙箱仍是 workspace-write），但需要在页面文案与文档里说清。
- **`codex-acp` 的 node 入口要在 Bun 下运行，且 `SIGKILL` 会留孤儿。** 入口已实测通过（2026-10-17，macOS arm64，Bun 1.4.3 + `codex-acp` 2.2.2：`initialize` 握手成功、`authMethods = [api-key, chat-gpt]`、Bun 成功拉起 `codex.js` 与原生 `codex app-server`），Windows / Ubuntu 未测、适配器升级后须重跑探针。同一轮实测量到：`SIGKILL` 适配器会让 Codex app-server 变成孤儿，正常关 stdin 才会连带退出——回收必须优雅优先（计划 KTD9）。
- **Claude Code 未取证。** `@agentclientprotocol/claude-code-acp` 与 Codex 适配器同族，但本 ADR 只对 Codex 做过包内核对；接入前要重做一遍同等取证。

回滚：按 PR 还原（Host 与 web 同一次部署）。协议改动是纯增量的，回滚 web 不影响新 Host 上的旧页面（`ompPresent` 仍在）；只回滚 Host、不跑数据迁移时，新版 `state.json` 的会话分桶形状对旧 Host 不可用——旧 `ensureSession` 拿对象形状的指针去 `session/list` 里比对必然匹配不到，于是判为「指针不在这门课的工作目录下」：删掉这条指针，`chat.send` 落回 `session/new`、`chat.attach` 回空历史，即 KTD6 既有的「丢了就从新对话开始」口径（旧 Host 写回状态文件时也保留 `agents` 这类它不认识的键）。学员不会卡住，也不会拿到更宽的权限。学员侧的 `codex-acp` 与 `~/.codex` 不由 CGC 安装、卸载也不碰它们。
