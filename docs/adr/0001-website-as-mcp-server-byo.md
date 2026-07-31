# ADR-0001：网站作为 MCP server 的 BYO 架构

> 状态：**已接受（hard-to-reverse）**
> 日期：2026-08-01
> 决策来源：`docs/grill-决策记录-2026-08-01.md`（D1–D14，grill-with-docs 交互式决策，14 条全量敲定）
> 关联文档：`CONTEXT.md`（术语表）｜ `docs/领域模型定稿.md`（领域模型）｜ `docs/用户旅程与Web功能清单.md`（页面清单）｜ `docs/技术调研与实施计划.md`（原技术方案）
> 逆向后继：如推翻本 ADR，需同时修订领域模型（Agent/AgentRun 重定义）、删除连接器扩展、重写网站对话页

---

## 1. 背景（Context）

CGC 平台最初的技术方案是**网站自研 AI Agent**：后端用 `ash_ai` 跑 LLM/ToolLoop，网站提供对话/执行页，由平台统一承担 Agent 执行。

在 grill 决策会上，这一前提被推翻。核心动因：

1. **成本与运维不可持续**：平台自跑 LLM 意味着每一用户、每一次对话都消耗平台推理成本，且平台要运维执行环境、模型账号、Token 计费。
2. **执行环境错位**：用户的专业任务（读写本地文件、操作浏览器、调用本地 API）发生在**用户自己的电脑**上，平台云端执行体够不着用户本地资产。
3. **产品形态错位**：平台的价值主张是"业务中枢 + 协作流程"（Workflow/Step/角色/审计），不是聊天界面；自建对话页是重复造轮子。
4. **决定性事实（D12）**：OpenClacky 的 MCP client 是 **server 级全局长连接**（`@clients = {name => Client}`，进程级共享），不能依赖服务端会话状态——任何"当前工作区"若存服务端都会跨会话串扰。

## 2. 决策（Decision）

**网站不再自行运行 LLM/Agent，改为"业务中枢 + MCP server"；用户自带 OpenClacky 作为 Agent 执行环境（BYO，自带模型）。** 具体包含 14 条子决策：

| # | 决策要点 |
|---|---|
| D1 | 删除 `ash_ai`；网站不做 AI Agent（不跑 LLM/ToolLoop） |
| D2 | 领域模型重定义：**Agent = 授权/配置登记**（`type / allowed_roles / owner` + `openclacky_profile / model / system_prompt / skills`）；**AgentRun = 领域操作聚合记录**（v1 就做） |
| D3 | BYO 粒度 = 每用户强制安装 OpenClacky；平台零 AI 成本；连接方向 = 用户侧主动连（出站、无隧道）；用户离线则该用户 Agent 任务不可用（接受） |
| D4 | 网站 UI = 形态 X（无对话/执行页）：工作台、成员/角色、Workflow 产出展示、审批、审计查看；聊天全在用户自己的 OpenClacky |
| D5 | 通道：**B 通道（网站 MCP server）为主干**；A 通道（网站派活）消失 |
| D6 | 连接模型：**单 MCP server**（anubis_mcp，Elixir/Phoenix）+ **每用户连接 token**（绑用户、可多 Workspace、按目标资源判定租户）+ RBAC 强制（Agent 权限 = 用户权限，越权被拒）；原则：工具 = 形状、租户 = 过滤器、每次工具调用 = 审计记录 |
| D7 | MCP 工具集：读 + 写 + **管理类全进**（低风险直做；高风险走确认流） |
| D8 | 确认流 = 方案二（原生 `request_user_feedback`）：pending 记录 → `needs_confirmation` → 用户点选 → `confirm(id)` 落库；**无 confirm 不落库** |
| D9 | AgentRun = 领域操作聚合：网站自动记录每次 MCP 工具调用（谁/工具/参数/结果/确认/时间），按 Step 聚合；**不做用户侧上报** |
| D10 | 公共 Agent 分发 = **任务指令模式**：Agent 定义存网站，MCP 提供 `get_agent_instruction(workspace_id, agent_id)`；不做运行时下发文件，不做纯静态打包 |
| D11 | 工作区 Skill 同步到本地：Skill 定义存网站，经连接器扩展同步到 `~/.clacky/skills/`（`SkillLoader#create_skill / delete_skill` 运行时写文件 + 立即注册）；角色过滤在网站侧 |
| D12 | 多工作区 Scope = **无状态 workspace_id**：所有 MCP 工具必填 `workspace_id`（每调用鉴权 + 审计）；"当前工作区"= 对话上下文由 CGC 助手维护；Skill 本地同步加前缀 `cgc2046-<ws>-<skill>`；不做"每工作区一个 MCP server" |
| D13 | Onboarding = 一次性三步（装 OpenClacky → 粘贴 mcp.json 片段 + 生成连接 token → `openclacky ext install`）；**单一配置点 = mcp.json**（扩展自动读 cgc 条目）；不做"一条命令全自动" |
| D14 | 连接器扩展命名 = `cgc-2046`（扩展 id / MCP server 条目名 / 本地技能前缀统一） |

**技术要点**：

- 网站暴露**一个** MCP server（技术选型 anubis_mcp）。
- 连接 token 与网站登录 Token 分离：登录 Token 是 httpOnly cookie（网站 UI 用）；连接 token 是 `Authorization: Bearer <token>`（MCP 用，绑用户不绑工作区）。
- 确认流完整链路：高风险工具调用 → 网站**不落库**建 pending → 返回 `needs_confirmation: {id, 摘要}` → Agent 调 `request_user_feedback(question, options: ["确认写入", "继续讨论"])` → WebUI 弹可点击卡片、Agent 停下 → 用户点选 → 文本回传 Agent → Agent 调 `confirm(id)` → 网站落库 + 审计。
- 已知风险：auto_approve 模式 10s 倒计时自动决策（二期可加冷却期）。

## 3. 理由（Rationale）

1. **成本结构**：平台零 AI 成本（D3）。LLM 推理由用户自己的 OpenClacky 承担——BYO 即自带模型，平台不为对话付费。
2. **执行环境对齐**：用户的专业任务在本地（读写文件、跑命令、操作浏览器），BYO 让执行发生在数据所在处，无需平台做本地代理/隧道。
3. **安全边界清晰**：平台侧只暴露"形状 + 过滤器"（D6），每次调用实时鉴权 + 审计；确认流（D8）保证高风险写操作永远有用户显式确认，**无 confirm 不落库**。
4. **协议成熟**：MCP 已是 Agent 工具调用的事实标准；`request_user_feedback` 是 OpenClacky 原生原语，确认流（方案二）比自建 UI 通道更稳、更快落地。
5. **审计可验证**：AgentRun 由网站自动生成（D9），不依赖用户侧上报——上报不可靠、可篡改，且连接器扩展工作量大。每次工具调用即审计记录，天然防抵赖。
6. **多租户正确性**：MCP client 全局长连接使服务端会话状态不可行（D12），无状态 `workspace_id` 每调用鉴权是唯一正确解；工具合并命名冲突使"每工作区一个 MCP server"不可行。
7. **公共 Agent 动态性**：任务指令模式（D10）让 Agent 定义存网站、运行时拉取，天然支持动态创建公共 Agent；不做热加载下发文件（工程风险高）也不做纯静态打包（不支持动态）。
8. **配置极简**：单一配置点 mcp.json（D13），扩展自动读 URL + token，加入新工作区无需重新配置——token 通用、scope 靠 workspace_id。

## 4. 后果（Consequences）

### 正面（Positive）

- 平台不再承担任何 LLM 成本、模型账号、执行环境运维。
- 安全边界收敛到一处：MCP server 网关 = 认证 + RBAC + 审计，网站 UI 与 MCP 调用走同一套授权链。
- 每一次用户可见的操作都有审计 + 确认记录，可回溯、可问责。
- 产品聚焦业务中枢（形态 X），不做重复的聊天 UI；聊天体验交给成熟的 OpenClacky。
- 多租户隔离在调用级强制执行，跨租户写入被结构性地杜绝。

### 负面（Negative）

- **用户离线则不可用**：用户本地 OpenClacky 离线时，该用户的 Agent 任务不可用（D3，接受）。
- **安装门槛前置**：每个用户必须安装 OpenClacky + 扩展 + 配置 mcp.json——onboarding 变成硬门槛（D13 已设计为一次性三步）。
- **执行详情不可见**：用户侧 OpenClacky 对话/token 等执行详情不进 AgentRun（D9），平台只能看到工具调用聚合，看不到完整对话内容。
- **依赖第三方客户端**：平台的能力可用性取决于 OpenClacky 的 MCP client 行为（如全局长连接、`request_user_feedback` 语义），存在上游变更风险。
- **web 形态受限**：网站无对话/执行页，纯业务中枢——若未来需要站内 AI 交互，需重新引入执行能力（逆向后继成本高）。

### Trade-off（权衡明细）

| 权衡维度 | 选择 | 放弃 | 理由 |
|---|---|---|---|
| AI 执行位置 | 用户本地 OpenClacky | 平台云端自跑 | 零 AI 成本 + 执行环境对齐本地资产 |
| 通道方向 | B 通道（用户出站连网站 MCP） | A 通道（网站派活） | 出站无隧道、无 NAT/防火墙问题；网站不维护连接 |
| 会话状态 | 无状态 workspace_id（每调用传） | 服务端"当前工作区"状态 | MCP client 全局长连接，服务端状态必串 |
| 审计来源 | 网站自动记录工具调用 | 用户侧上报执行详情 | 上报不可靠/可篡改；换取"执行细节不可见" |
| 公共 Agent 分发 | 任务指令模式（定义存网站） | 运行时下发文件 / 静态打包 | 热加载未验证、静态不支持动态；换取每次调用多一次拉取 |
| Skill 同步 | 本地写文件 + 立即注册 | 每工作区独立 MCP server | 源码已验证可行、避免工具合并冲突；换取本地文件被改的风险 |
| 高风险操作 | 确认流（pending→confirm） | 直接执行 | 换取用户显式确认；auto_approve 有 10s 倒计时风险（二期加冷却期） |
| 配置方式 | mcp.json 单一配置点 | 一条命令全自动 | 避免扩展代写 mcp.json 被覆盖；换取用户手动粘贴一次 |

## 5. 为什么这是 hard-to-reverse 决策

1. **产品形态不可逆**：从"平台执行 Agent"转向"用户自带执行"改变了产品对用户的价值承诺（D3/D4）。一旦上线，用户已按 BYO 安装 OpenClacky、依赖本地执行，回退意味着要求用户卸载本地环境、平台重新承担 LLM 成本与执行运维。
2. **领域模型已重定义**：Agent 从"执行体"变成"授权/配置登记"，AgentRun 从"对话历史"变成"领域操作聚合"（D2）。数据模型、API 契约、页面清单全部随之变更，反向迁移要重写资源语义。
3. **基础设施删除**：`ash_ai` 被移除（D1）；若回退需重引入 LLM 执行栈（ash_ai/ash_oban/Oban worker/SSE 对话流），不是加一行依赖的事。
4. **生态依赖**：连接器扩展 `cgc-2046`（D14）、mcp.json 配置（D13）、确认流协议（D8）构成用户侧资产；回退会破坏已安装用户的本地配置。
5. **网络架构锁定**：出站连接、无隧道（D3）决定了平台没有入站通道；未来若需要平台侧主动推送，需要新增基础设施（隧道/长连接），属于结构性变更。

**结论**：本决策属于"接受了就要长期承担后果"的架构级决策。回退成本高、波及面广（领域模型 + 产品形态 + 基础设施 + 用户侧资产），因此必须显式记录为 ADR，后续任何变更都应以本 ADR 为基准评估。

## 6. 落盘与实施影响

- 领域模型修订：`docs/领域模型定稿.md`（Agent/AgentRun 重定义、MCP 工具、确认流、scope）——由领域建模工程师跟进。
- 页面清单修订：`docs/用户旅程与Web功能清单.md`（删对话/执行页，加连接引导页、审计查看页）。
- 实施计划修订：`docs/技术调研与实施计划.md` M2 大改（删 ash_ai，加 MCP server/连接器扩展）。
- 术语一致性：本 ADR 使用的词汇均以 `CONTEXT.md` 为准。
