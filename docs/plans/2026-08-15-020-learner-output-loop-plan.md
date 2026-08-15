# Plan 020 · Learner 产出闭环（组1：#149 + #150 + #92 + #93）

- 日期：2026-08-15
- 状态：待评审
- 决策依据：双 scout 取证（Scout020a/020b）；用户拍板组1 为 019 后首轨
- 关闭目标：#149（B1）、#150（C1 最小版）、#92、#93
- 非目标：Agent/Skill 资源与真实 `get_agent_instruction`（#150 明示 roadmap，本 plan 只做「平台操作引导」最小版并留接口语义）；#83 Hub 重构（边界互斥，不碰概览 hero/管理卡结构）

## 1. 问题

J-F 学员旅程「连接 → 有指令 → 去执行 → 看产出」四环全断：
1. **连接入口三层深**：`/w/[slug]/settings → 集成 → Agents → OpenClacky`（`integrations-agents-tabs.tsx:4-35`），无用户级页面；OpenClacky 页是内联三步卡（`openclacky/page.tsx:25-118`）不可复用。
2. **指令缺失**：`/workflows` 页只渲染 run status/facts（`workflows/page.tsx:62-90`）；GraphQL 无 definition/Step 查询面；`get_agent_instruction` 代码零命中（`mcp/server.ex:4-37` 工具表无）。
3. **无 CTA**：waiting 步骤旁无「在 OpenClacky 中执行」入口（#92 原文验收）；依赖 #39 已解除（PR #91 合并）。
4. **产物裸渲染**：FactsTree 递归原始 map（`workflows/page.tsx:22-60`），无 schema 契约——`output_schema` 字段、读取面、渲染器三件全缺（#93）。

## 2. 已验证事实（scout，file:line 以 HEAD 为准）

- MCP token 数据层完整可复用：`web/lib/graphql/mcp-token.ts:18-88`（myMcpTokens/create/revoke）、`web/lib/mcp.ts:19-70`；后端 `mcp/token.ex:31-297`（user-scoped、hash-only、一次性明文、上限 10）。
- 全局 settings 仅剩旧 profile 兜底重定向（`web/app/settings/account/profile/page.tsx:6-20`）——`/settings/connections` 落点干净。
- 概览页卡位：`web/app/w/[slug]/page.tsx:79-199`（info/管理/Workflow·活动·课程三卡组），无 BYO 卡。
- Step 字段全集：`step.ex:38-113`——`step_key/title/type/action/agent_id/sub_definition_id/input_schema`，**无 instruction/output_schema**；node_def 仅拓扑（`workflow_definition.ex:5-13`，`jido_adapter.ex:68-109` 只读 id/type/action/next/condition）。
- run 持有 `definition_id + version`；`myLearningRuns` 内部加载 node_def/steps 但只投影进度（`graphql_schema.ex:1769-1870`）——读取面有内部先例可循。
- facts 按 step_key 聚合（`workflow_run.ex:94-105`）；`save_step_output` 浅合并不校验（`save_step_output.ex:42-100`）——#93 保持写入语义不变，只加展示契约。
- 平台侧无 OpenClacky URL/连接状态记录（`mcp_tokens` 表无 URL 列，`20260808120000_create_mcp_tables.exs:8-20`）；连接状态只在本地扩展可读（`openclacky-ext/.../mcp_config.rb:154-169`）——**不做假的连接状态展示**。

## 3. High-Level Technical Design

### U1 BYO 入口提级（#149）
1. 新路由 `web/app/settings/connections/page.tsx`：用户级「连接与令牌」页——MCP token 管理（复用 `mcp.ts` 数据层 + mcp 页的列表/签发/一次性明文/撤销交互，抽共享组件或复用页面块）+ OpenClacky 三步引导（从 workspace 页抽 `OpenclackyGuide` 共享组件，两处消费）。
2. 全局入口：品牌菜单（`workspace-switcher-menu.tsx:103-116`）加「连接与令牌」项；旧全局 settings 兜底重定向页旁挂入口。
3. 概览引导卡：`/w/[slug]` 卡组加「在 OpenClacky 中工作」卡（Link 到 `/settings/connections`），文案不声称连接已验证。
4. workspace 三层链保留（不删），页面顶部互链。
5. 导航/路由守卫：`/settings/connections` 需登录（复用 AdminGuard 模式的 authed 检查）。

### U2 步骤引导读取面 + workflows 页升级（#150 最小版）
1. 后端：`listWorkflowRuns`/`getWorkflowRun` 扩展返回 `definition { type }` + `steps { stepKey title type }`（按 run 绑定 version 读取，不读最新 definition）；或独立 `workflowRunSteps(runId)` 查询——writer 按 SDL 面最小代价选型。授权复用 WorkflowRun 读 policy（成员可读，draft visibility 语义同 016）。
2. 前端：RunCard 增加步骤条（title/type 序列 + 当前待办高亮——由 facts 已有 step_key 推导已完成集）；waiting/manual 待办步骤旁渲染**平台操作引导**文本：「请在 OpenClacky 中完成「<title>」，通过 MCP save_step_output 写回」。明确标注为平台引导，不伪装 Agent 指令。
3. `get_agent_instruction` 接口语义预留注释（Agent 资源存在后接 MCP 工具），本期不实现。

### U3 OpenClackyCta（#92）
1. 新组件 `web/components/openclacky-cta.tsx`：waiting/manual 待办旁渲染，主链接 → `/w/[slug]/settings/integrations/agents/openclacky`（保持 workspace 引导页为执行向落点），副链接 → `/settings/connections`。
2. 双主题用现有 CSS 变量；无执行控件（形态 X 不变：不在网站发起 workflow/调用 Agent/提交产出）。
3. research 类型 run 不显示 CTA（U2.1 definition.type 已下发，前端过滤）。

### U4 产物 schema 渲染（#93）
1. 契约：`node_def.steps[].output_schema`（字段：name/type/label/optional，宽松校验，旧 node_def 无字段全兼容——JidoAdapter unknown extras ignored 已证安全 `jido_adapter.ex:89-109`）。
2. 读取面：U2 的 steps 查询一并返回 `output_schema`（run 绑定版本）。
3. 前端 `SchemaOutputList`：按 schema 顺序渲染 label/type/value；可选缺失隐藏；schema 缺失/非法/未知字段回退现有 FactsTree。React 文本节点渲染，无 dangerouslySetInnerHTML。
4. 写入路径不动：`save_step_output` 保持原始 map 浅合并。

### U5 测试 + e2e
- 后端：读取面授权测试（成员可读/跨租户拒/版本绑定——历史 run 用旧版 steps）；SDL 重生成。
- web：connections 页（token 交互复用测试模式）、步骤条/引导文本/CTA 条件（waiting 显示·终态不显示·research 过滤）、SchemaOutputList（有序/缺失回退/可选隐藏）单测。
- e2e（结构断言）：登录 → `/settings/connections` 可达且三步引导在 → 概览卡链接正确 → learning run 卡显示当前步骤引导 + CTA → 带假 schema 的 run 按 schema 渲染。

## 4. 风险

| 风险 | 预案 |
|---|---|
| definition version 漂移（历史 run 读错版本步骤） | 读取面强制按 run.version 过滤 definition 快照；测试钉住 |
| 通用引导文本被误解为 Agent 指令 | UI 标注「平台操作引导」；CONTEXT.md 记录语义边界 |
| facts 与 schema 不一致导致渲染崩 | 全路径回退 FactsTree；未知字段安全降级；属性测试（乱序/深层/空） |
| mcp token 一次性明文在两处页面的交互漂移 | 抽共享组件单一实现 |
| 概览卡与 #83 未来 Hub 重构冲突 | 卡片独立组件化，只追加不重构现有卡组 |

## 5. 验收标准

1. `/settings/connections` 用户级可达：token 管理 + OpenClacky 引导 + 双向互链；品牌菜单与概览卡入口在。
2. `/workflows` run 卡：步骤序列 + 当前待办高亮 + 平台引导文本 + CTA（waiting/manual only，learning only）。
3. 带 `output_schema` 的 steps 按 schema 渲染；缺失回退 FactsTree；`save_step_output` 语义零变化。
4. backend ×2 seeds + `cgc2046.gen_rbac_contract --check` + SDL 同步 + web 全套全绿；e2e 五组结构断言过。
5. #149/#150/#92/#93 关闭评论各自注明落地范围与 roadmap 边界（Agent 指令真源留接口语义）。

## 6. 实施顺序

U1（入口）→ U2（读取面+步骤条）→ U3（CTA）→ U4（schema）→ U5 → 自查 → commit 不 push → `/tmp/cgc_2046-writer20-report.md`。

## 7. Assumptions（writer 验证，冲突即停）

1. `listWorkflowRuns` 扩展字段不破坏既有消费方（`workflows/page.tsx` 唯一消费 + `myLearningRuns` 独立投影）。
2. node_def map 字段扩展无需迁移（jsonb）。
3. OpenClacky 引导页内容可抽共享组件（现为内联卡片，无外部状态依赖）。
4. `/settings/connections` 无 workspace 上下文，token 数据层 user-scoped 无需 workspaceId——已核实（`mcp/token.ex` user_id 归属）。
