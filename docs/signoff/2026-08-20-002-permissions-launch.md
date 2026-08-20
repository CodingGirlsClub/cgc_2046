---
title: 权限上线签核包 — MCP 鉴权 / RBAC 契约 / 前端门控 / plan 语义补签
type: signoff
date: 2026-08-20
status: pending-signoff
reference: docs/plans/2026-08-20-009-permissions-signoff-packet.md
topic: permissions-launch
---

# 签核包：#219 权限上线

**状态：`pending-signoff`**（2026-08-20 起草，等待用户签收）。

## 阅读指引（三档）

- **第一档 · 必读（签收对象）**：§2 豁免/偏差清单确认（6 条）、§3 七份 plan 语义补签、§4 D7 工具面边界确认 + 确认流语义。每项配 checkbox，留空待签。
- **第二档 · 抽查**：§5 MCP 15 工具授权矩阵、§6 RBAC 8 能力矩阵。数据从代码/契约文件/测试转录，抽查若干行核对 file:line 溯源即可。
- **第三档 · 可略**：§7 前端门控清单（转录性内容，#261 合并后已由能力单源派生）。

**签收方式**：逐项勾选第一档 checkbox + 在「签核记录」段签名（引用本文件路径回复即可）→ agent 收尾 commit + 关 #219。异议走 #219 评论，不勾选。

## Executive Summary

- **审计来源**：2026-08-18 #208 权限审计线的四路 scout（MCP 工具鉴权 / RBAC 契约 / 前端门控 / plan 语义漂移）+ 后续收敛线（#209-#217 各 blocker issue）。
- **当前状态**：#208 审计派生的全部 blocker 已关闭——#209（SignalIdempotency 惯例）、#211（MCP 工具面边界三裁决）、#214（MCP 面加固：限流 + admin 豁免契约 + 工具执行测试）、#215（manage_events 能力化，PR #261）、#217（bypass 契约改写，PR #260）均 MERGED。
- **签收范围声明**：本包覆盖四块此前无人签收的语义变更——① MCP 工具面与鉴权/确认流现状；② RBAC 8 能力契约现状；③ 前端门控现状；④ 2026-08-15 批次七份 plan（017-023）的语义补签。签收 ≠ 背书历史决策，仅确认「现状已知、可上线」。

## 签核记录

-（待用户签收后由 agent 填写）

---

## §1 现状基线（数字与代码一致性）

| 项 | 值 | 溯源 |
|---|---|---|
| MCP 工具数 | 15 | `backend/lib/cgc_2046/mcp/server.ex:25-42`（component 注册清单）；`wrapper_gate_test.exs:69-76` 断言恰 15 |
| 派生门控豁免工具 | 6（2 × workspace_id: :optional + 4 × membership: :deferred） | `backend/test/cgc_2046/mcp/wrapper_gate_test.exs:23-25` 精确名单 |
| RBAC 能力数 | 8 | `backend/priv/rbac_contract.json:2-11`（abilities 列表） |
| RBAC 角色数 | 5（owner/admin/tutor/volunteer/learner） | `backend/priv/rbac_contract.json:83-89` |
| 确认流 TTL | 10 分钟 | `backend/lib/cgc_2046/mcp/pending_operation.ex:18`（@default_ttl_seconds 600） |
| MCP 连接 token 生命周期 | 滚动过期：连续 90 天未使用失效，无固定 TTL | `backend/lib/cgc_2046/mcp/token.ex:14,24,324-332` |

---

## §2 已知豁免 / 偏差清单（第一档 · 必读）

以下 6 条是审计定稿的已知偏差/取舍，**默认接受现状上线**。每条需确认或提出异议。

- [ ] **E1 · MCP membership 门不认 platform_admin**。非成员平台管理员调用 member-only 工具（list_members / get_workflow 等）一律 Forbidden——MCP 是自动化 agent 代理面，取最小授权；跨租户治理读走 GraphQL admin 查询，不经 agent 直连面。双面契约（MCP 门 vs policy/Rbac 面）刻意向不同答案收敛，单面放宽被禁止。证据：`backend/lib/cgc_2046/mcp/wrapper.ex:22-34`（双面契约段）、`wrapper.ex:143-147`（member-only 默认门）。
- [ ] **E2 · join_request_not_found 存在性探测 tradeoff**。`createJoinRequest` 对「工作台不存在 / open 直入 / invite_only 拒绝」三分支返回携带稳定 code 的 BusinessError（`join_request_open` / `join_request_invite_only` / `join_request_not_found`），换取 join 页可按 code 渲染 locale 文案；代价是 `not_found` 与其他 code 的区分可被用于工作台存在性探测。证据：PR #258（commit `6a8eb65`，Closes #206）；`backend/lib/cgc_2046/changes/validate_workspace_join_policy.ex`（三分支）。
- [ ] **E3 · token 闲置过期为客户端本地派生展示**。web 端 `mapMcpToken` 用 90 天常量本地派生 `idle_expired` 徽章（`web/lib/mcp.ts`，注释互指 `token.ex:23`；UTC 绝对毫秒差防时区漂移）。90 天常量在后端 `token.ex` 与前端 `mcp.ts` 各持一份（注释互指但无编译期联动）；极端情况下客户端时钟偏差可致徽章与后端拒绝判定短暂不一致——仅展示层偏差，鉴权以后端 `validate_token` 为准。证据：PR #257（commit `b6999e1`，Closes #226）；`token.ex:117-138`（active 上限口径同步）。
- [ ] **E4 · 连接 token 无固定 TTL（滚动过期）**。裁决理由：固定 TTL 与 D-A7 零配置接入冲突——静默到期会让 agent 断连且引导链路长，泄漏窗口收敛与滚动过期相当。仅手动撤销 + 每用户 active 上限 10 枚（闲置过期不计入上限）。证据：`token.ex:14-24`、`CONTEXT.md:112`（#222 / #211 裁决记录）；#222。
- [ ] **E5 · ToolCallLog 承担 MCP 审计，AgentRun 实体不落地**。#211 裁决 2/3：原 AgentRun 聚合锚（Agent 实体 / Step 主链路）先后被架构演进移除，审计义务由 ToolCallLog 事件账本承担（自动记录/防抵赖已兑现），AgentRun 语义 = ToolCallLog 之上的投影，可回填重建。审计落库失败不阻塞工具响应（审计可用性 < 工具可用性），记 error 日志留痕。证据：`CONTEXT.md:220-223`、`backend/lib/cgc_2046/mcp/wrapper.ex:151-182`（log_call）；#211。
- [ ] **E6 · resolver 旁路读取 14 处（#217 改写后的真实分布）**。`bypass_reads.ex` 不再断言「唯一原始 SQL 出口」，改为中央契约：14 处 resolver 旁路读取按处门禁纪律注释 + 原始 SQL 六类分布归类。纯文档/注释改动，零行为变更。证据：PR #260（commit `fdc5d88`，Closes #217）；`backend/lib/cgc_2046/accounts/bypass_reads.ex`（moduledoc 中央契约段）、`backend/lib/cgc_2046_web/graphql_schema.ex`（14 处就近注释）。

---

## §3 七份 plan 语义补签（第一档 · 必读）
2026-08-15 批次七份 plan 代码均已落地合并，语义变更此前无人签收。摘要基于各 plan 决策段重读（禁抄 issue 标题）。

- [ ] **P017 · member 角色退役（PR #171，commit `d2fabc5`）**。`member` 退出 Role 枚举，Role 只留五个差异标签；成员资格 = 存在 WorkspaceMembership 行，`/join open` 入座、注册自动入 2046、JoinRequest 默认审批全部改为**无标签入座**（能力经「成员基准」路径下发，行为与旧 member 完全同权）。存量 member MembershipRole 行经迁移全量退役（不回头）；权限映射页重做为「成员基准 + 差异标签」模型（B2/B6 根治）。plan：`docs/plans/2026-08-15-017-refactor-member-semantics-plan.md`。
- [ ] **P018 · PlatformAdmin 只读放行业务工作台（PR #173，commit `94d832e`）**。非成员平台管理员经 `/w/[slug]` 以只读访客身份进入任意业务工作台（`meWorkspaces` miss + isPlatformAdmin 双条件 fallback），页头挂只读标识；前端隐藏报名/join-policy 等写入口。后端把 Event/Course/Workflow/InviteBatch/普通 Invitation 等业务写的 PlatformAdmin bypass 收窄为拒绝，保留治理写（pending-owner 邀请、reassign_owner、Workspace create/update）；Invitation 拆分为「仅 owner 预授权邀请可经 admin 建/撤」条件 bypass。plan：`docs/plans/2026-08-15-018-feat-platform-admin-readonly-plan.md`。
- [ ] **P019 · 活动管理面验收加固（PR #175，commit `f3a8307`）**。#127 主体（Event/Course 五 mutation + Owner/Admin 权限面 + web 列表/详情/新建）此前已落地，本 plan 补三件：offering 页点击级调用链测试（新建/保存元数据/可见性双向切换/生命周期三链/失败分支）、close/cancel 不可逆操作加确认交互、错误文案友好化（不透传 GraphQL 原文）+ 非 manage 视角移除多余 pendingCount 请求。D-vis 裁决：visibility 维持 D9 随时双向切换。后端零改动。plan：`docs/plans/2026-08-15-019-activity-admin-hardening-plan.md`。
- [ ] **P020 · Agents 页与 learner 输出闭环（PR #176，commit `e85d786`）**。分层模型落定：连接凭据（token 签发/撤销）留 `设置→集成`，新增 workspace 级 `/w/[slug]/agents` 工作面——本人工具调用活动流（`myWorkspaceToolCalls`，仅本人 + 不返回 params，隐私最小面）、waiting 步骤交接 CTA（剪贴板交接文本含 workspace_id/run/step）、未连接引导三区。workflows 页补步骤条 + 按 run 版本绑定的 steps 读取面 + output_schema 渲染（缺失回退 FactsTree）。`get_agent_instruction` 只留接口语义不实现。多宿主（OpenClacky/opencode/omp）平级。plan：`docs/plans/2026-08-15-020-learner-output-loop-plan.md`。
- [ ] **P021 · 切片 E 收尾（PR #177，commit `b11454d`）**。#124 判定已落地直接关闭（CAS 状态机 + 事务内 ended outbox + research run 回收 + deadline 自动 close + 报名窗锁定）；#123 补 expired 行重提入口（三 kind 链接）+ deadline 时序边界修复（过期 pending 行不渲染操作按钮）；#122 补 E-10 第七规则 `learning_run_stalled`（>7d 无 step 输出产 ReconciliationFinding，与学习提醒 worker 分工：worker 提醒学员、E-10 对账可见）。plan：`docs/plans/2026-08-15-021-slice-e-closure-plan.md`。
- [ ] **P022 · 邮件基建 CD 就绪（PR #178，commit `af74d7f`）**。SendCloud 全链（自定义 Swoosh adapter + 密码重置 + runtime.exs prod 必填守卫）代码已就绪；#164 改以「就绪文档」交付——`docs/运维/邮件与CD环境注入.md` 五值注入契约（密钥进 Secrets、非敏感进 Variables）+ 前置检查单（DKIM/SPF、HTTPS、fire-and-forget 丢失风险记录）；不建无消费方的占位 workflow（死代码），真实 secret 创建推迟到部署目标确定。plan：`docs/plans/2026-08-15-022-email-infra-cd-readiness-plan.md`。
- [ ] **P023 · 小修批（PR #179，commit `5f03de0`）**。#86 邮箱枚举修复选方案 B：重复邮箱注册不再透传 `has already been taken` + fields，改返回与未知错误同码同形的 `registration_failed`；非邮箱类校验错误（格式等）保持结构化可指导。#84（面包屑 slug）判定已被 ADR-0004 路由迁移修复直接关闭；#87（join 卡片抽取）维持 ponytail defer。plan：`docs/plans/2026-08-15-023-small-batch-fixes-plan.md`。

---

## §4 D7 工具面边界确认 + 确认流语义（第一档 · 必读）

- [ ] **D7 工具面边界（#211 裁决 1/3）**：确认以下操作**不进 MCP**，维持现状——
  - `update_join_policy` / 删除类等低频管理操作：维持 web 面（GraphQL + 设置页）；真实 agent-first 需求出现时按「确认流 + RBAC 兜底」范式增量重开。
  - `create_agent` / `create_workflow` / `get_agent_instruction`：挂 Agent 资源 roadmap（上游实体/输入形状不存在，落地时机随 Agent 资源，与 AgentRun 重启条件同钩子）。
  - `reply_learner_question` / `get_learner_history`：已死亡除名（分别被 issue 卡 checklist 复盘 + `save_learning_records`、`get_learning_records` 取代）。
  - 证据：`CONTEXT.md:237-243`（MCP 工具集词条，#211 裁决 1/3）。

- [ ] **确认流语义（two-tool 模式，D8 / D-D3）**：确认以下四点现状——
  1. **TTL 10 分钟**：pending 操作默认 10 分钟确认窗口，过期读时派生 expired（`pending_operation.ex:9-10,18`）。
  2. **并发恰一次**：DB 条件更新，并发双确认后者得友好错误 `Operation is not pending (concurrent confirmation won)`（`confirmation.ex:116-118`）。
  3. **失败回滚**：effect 失败不留 confirmed-but-no-effect，回滚到 pending 可重试；pending 已过期则回滚后仍拒绝（`confirmation.ex:67-70`，MEDIUM-2/3）。
  4. **auto_approve 未实现**：代码零实现（backend/web 全库无 auto_approve 符号），当前全部走人工 confirm；ADR-0001 保留该模式的设计风险记录（10s 倒计时自动决策，二期若实现需加冷却期）。证据：`docs/adr/0001-website-as-mcp-server-byo.md:48,89`、`CONTEXT.md:252,494`。
  5. **无 confirm 不落库**：高风险工具调用先建 pending（业务不落库），用户确认后才执行 + 落库 + 审计（`pending_operation.ex:5-7`）。

---

## §5 MCP 15 工具授权矩阵（第二档 · 抽查）

鉴权立场随工具走：工具 meta 声明 + Wrapper 派生门控，**未声明 meta 的工具默认 member-only + workspace_id 必填（fail-closed）**。新工具漏声明、豁免被误删均直接红（`wrapper_gate_test.exs` 结构性守卫）。

矩阵转录自 `server.ex:25-42`（注册清单）+ `wrapper_gate_test.exs:23-25`（豁免精确名单）。全部 15 工具每次调用均经 Wrapper 落 ToolCallLog 审计（ok/error/forbidden + client_name/session_id 归因维度，#228）。

| # | 工具 | meta 声明 | 鉴权链 | 确认流 | 来源 |
|---|---|---|---|---|---|
| 1 | get_workspace_context | —（默认） | member-only + workspace_id 必填 | 否 | server.ex:25 |
| 2 | list_members | —（默认） | member-only + workspace_id 必填 | 否 | server.ex:26 |
| 3 | get_workflow | —（默认） | member-only + workspace_id 必填 | 否 | server.ex:27 |
| 4 | get_step_output | —（默认） | member-only + workspace_id 必填 | 否 | server.ex:28 |
| 5 | save_step_output | membership: :deferred | 工具层授权（学员判定）+ 资源层 policy 双重门禁 | 否 | server.ex:29；gate_test:24 |
| 6 | create_invitation | —（默认） | member-only + workspace_id 必填 | **是**（two-tool） | server.ex:30 |
| 7 | list_join_requests | —（默认） | member-only + workspace_id 必填 | 否 | server.ex:34（#240） |
| 8 | approve_join_request | —（默认） | member-only + workspace_id 必填 | **是**（two-tool） | server.ex:35（#240） |
| 9 | assign_roles | —（默认） | member-only + workspace_id 必填 | **是**（two-tool） | server.ex:36（#240） |
| 10 | confirm_operation | workspace_id: :optional | 鉴权在 Confirmation 内（pending 归属校验即授权） | 内置承载 | server.ex:37；gate_test:23 |
| 11 | cancel_operation | workspace_id: :optional | 鉴权在 Confirmation 内（pending 归属校验即授权） | 内置承载 | server.ex:37；gate_test:23 |
| 12 | get_course_content | membership: :deferred | 工具层授权（学员侧）+ 资源层 policy | 否 | server.ex:39（#180） |
| 13 | get_learning_records | membership: :deferred | 工具层授权（学员侧）+ 资源层 policy | 否 | server.ex:40（#180） |
| 14 | save_learning_records | membership: :deferred | 工具层授权（学员侧）+ 资源层 policy | 否 | server.ex:41（#180） |
| 15 | save_course_content | —（默认） | member-only + workspace_id 必填 | 否 | server.ex:42（#180） |

守卫测试：`backend/test/cgc_2046/mcp/wrapper_gate_test.exs`——豁免集合恰 6 个（无遗漏无多出）、member-only 不携带豁免 meta、注册数恰 15、fail-closed 默认门控消费、归因维度落库。

## §6 RBAC 8 能力矩阵（第二档 · 抽查）

转录自 `backend/priv/rbac_contract.json`（由 `mix cgc2046.gen_rbac_contract` 从 `rbac.ex` 单源生成）。**双端 golden-file 守卫**：CI `--check`（`.github/workflows/ci.yml:62`）+ 后端 `rbac_contract_test.exs` + web `permissions.contract.test.ts`。

| 能力 | owner | admin | tutor | volunteer | learner |
|---|---|---|---|---|---|
| view_workspace | ✓ | ✓ | ✓ | ✓ | ✓ |
| access_invite_only | ✓ | ✓ | ✓ | ✓ | ✓ |
| list_members | ✓ | ✓ | — | — | — |
| manage_members | ✓ | ✓ | — | — | — |
| assign_roles | ✓ | ✓ | — | — | — |
| update_join_policy | ✓ | ✓ | — | — | — |
| manage_events | ✓ | ✓ | — | — | — |
| create_workspace | — | — | — | — | — |

注：
- `manage_events` 为 #215 新增（PR #261，commit `a29fd7f`）：第七→第八能力，矩阵自动派生，前端 `canManageEvents` 从角色名推断切换为 `myAbilities` 消费（五处调用面迁移，后端 policy 兜底）。
- `update_join_policy` 对非成员 PlatformAdmin 的能力集豁免为 #78 历史决策（治理 API 面），P018 已确认后端保留、前端只读。
- member 退役后（P017）：view_workspace + access_invite_only 为「成员基准」能力，任意 membership 即有，不经角色判定；tutor/volunteer/learner 三标签当前能力等同（标签用于工作流步骤授权与分工）。
- `create_workspace` 全角色 false：平台级动作，走 WorkspaceApplication 审批（platform_admin 审批）而非能力门。

## §7 前端门控清单（第三档 · 可略）

转录自 web 代码现状（#261 合并后）。门控模型：**能力单源**——前端一律消费 `meWorkspaces.myAbilities`（后端 `Rbac.abilities_for/2` 单源派生），前端判定仅 UX 层，后端 policy 兜底拒绝。

| 门控点 | 消费面 | 证据 |
|---|---|---|
| canManageEvents | `myAbilities.includes("manage_events")`；五处调用面（offering 列表/详情/新建、定价、赞助页） | `web/lib/events.ts:40-41`；PR #261 |
| currentUserCanAssignRoles | `myAbilities.includes("assign_roles")`（成员页 assign/edit） | `web/lib/workspaces.ts:272` |
| currentUserCanUpdateJoinPolicy | `myAbilities.includes("update_join_policy")`（join-policy 页 save） | `web/lib/workspaces.ts:328` |
| settings 侧栏 nav 门控 | members/permissions = `list_members`；requests/invitations = `manage_members`（单文件集中声明，多处硬编码已收敛） | `web/components/workspace-nav.ts:85-139` |
| AdminGuard（/admin/*） | `isPlatformAdmin`（ME_PROFILE 独立查询；denied/未登录/失败保守 redirect，confirmed 前不渲染 children） | `web/components/admin-guard.tsx:1-33` |
| 只读访客（PlatformAdmin fallback） | `meWorkspaces` miss + isPlatformAdmin 双条件 → `readOnlyVisitor`（myRoleNames/myAbilities 皆空 → manage 类面板天然隐藏）；写入口（报名/join-policy）显式隐藏 | `web/lib/use-workspace-by-slug.ts:98-101`；P018 |
| 契约守卫 | `web/lib/permissions.contract.test.ts` 对 golden file 双向同步 | `web/lib/graphql/permissions.ts:12-14` |

---

## Evidence

- 本签名时点 CI：PR #261 checks 4/4 passed（backend/web/miniprogram/secrets）——https://github.com/CodingGirlsClub/cgc_2046/pull/261/checks ；PR #260 checks 4/4 passed——https://github.com/CodingGirlsClub/cgc_2046/pull/260/checks 。
- MCP 鉴权/门控/审计测试：`backend/test/cgc_2046/mcp/wrapper_gate_test.exs`（199 行：豁免精确名单 + fail-closed + 归因维度）；`backend/test/cgc_2046/mcp/`（confirmation / token / 各工具）。
- RBAC 契约守卫：`backend/test/cgc_2046/rbac_contract_test.exs`（golden）、`backend/test/cgc_2046/rbac_test.exs`、`backend/test/cgc_2046_web/graphql_rbac_test.exs`、`web/lib/permissions.contract.test.ts`。
- 前端门控测试：`web/lib/workspaces.test.ts`（能力接口三组）、`web/lib/permissions.test.ts`、`web/components/offering-pages.test.tsx`（点击级调用链，P019）。
- 转录一致性旁证：起草时点 `mix cgc2046.gen_rbac_contract --check` 通过（golden file 与 `rbac.ex` 单源一致）。
- 审计源：#208 body + 四路 scout（McpToolAuth 等）；#209/#211/#214/#215/#217 全 MERGED。

## Roster（签核阶段）

- orchestrator: omp 会话（zhipu-coding-plan/glm-5.3）。
- writer: writer09（本包起草，纯文档零代码改动）。
- reviewer: 待 advisor09 逐格核对（矩阵 vs 代码/契约文件）。
- gates: 用户签收（本包 checkbox + 签名）→ agent commit → 关 #219。

## 附：起草自查

- backend：`mix format --check-formatted` ✓、`mix compile --warnings-as-errors` ✓、`mix cgc2046.gen_rbac_contract --check` ✓（见 writer09 报告）。
- 本包零代码/零测试改动；15 工具 × 门控列矩阵完整无 TBD；六条豁免全带 file:line/PR 溯源。
