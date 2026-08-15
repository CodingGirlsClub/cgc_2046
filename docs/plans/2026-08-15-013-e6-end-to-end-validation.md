# E-6 端到端验收：Event/Course → Enrollment → Approval → Signal → 衍生、赞助两级、Speaker 邀请

> 日期:2026-08-15 · 来源:issue #51 + parent issue #22 + Slice E 整合计划 `docs/plans/2026-08-13-001-slice-e-integration-plan.md` · 状态:验收计划
> 基线:develop `8d520f4`（E-5 PR #163 已合并，#50 已关闭）
> 目标:用真实 GraphQL/网页入口完成一条可复现的 Slice E 手工闭环；不新增未拍板的领域语义。

## 1. 目标与范围

issue #51 的验收条件是：

> 手工走查：报名→审批→Enrollment→衍生；赞助两级；邀请链路可演示。

本计划把这句话拆成五条可观察链路：

1. **公开发现与报名**：匿名浏览 `Event`/`Course` 公开发现页和详情页；登录 Learner 走 `request` 报名；Owner/Admin 在审批中心通过；Enrollment 变成 `confirmed`。
2. **异步衍生**：`enrollment.completed` 通过事务内 outbox + `SignalPublishWorker` 投递；有已发布 learning `WorkflowDefinition` 时，`LearningInstantiator` 幂等创建并启动 `WorkflowRun`；网页工作台可读到 run 状态/产出。
3. **赞助两级**：Event 级意向提交→审批→`active`→履约账本；Workspace 级意向提交→Owner 审批→`active`。Event 结束后 Event 级赞助变 `ended`，Workspace 级不受影响。
4. **Speaker 邀请**：Owner/Admin 创建邀请→一次性 token 着陆页→Speaker 登录后接受/婉拒→接受后提交材料→完成邀请；无效/复用 token 统一失败。
5. **负向边界**：匿名/非成员不能访问 workspace-only offering；非成员不能经 API 报名 workspace-only offering；重复报名和重复审批不产生第二条有效状态；无关账号不能接受定向 Speaker 邀请或提交材料。

### 不在本计划内

- 支付或真实收款；
- 新增成员级可见性轴、改变 `visibility`/`enrollment_policy` 语义；
- 新建 workflow 执行引擎或网站 Agent 对话页；
- 自动删除 E-5 发现的 4 条历史非成员 workspace-only Enrollment；只记录现状；
- 为 Workspace 级赞助另造未经拍板的公开 URL。父 spec 的主接缝是 GraphQL；当前 Event 级有公开表单，Workspace 级使用已有 authenticated GraphQL mutation 作为可审计演示入口。

## 2. 当前状态证据

| 链路 | 当前实现 | 证据 |
|---|---|---|
| 公开 Event/Course 发现 | `/events`、`/events/[slug]`、`/courses`、`/courses/[slug]` 薄壳复用公开组件；公开查询只消费 `open + public` 白名单 | `web/app/events/page.tsx:1-4`; `web/app/events/[slug]/page.tsx:1-4`; `web/components/public-offerings.tsx:3-9`; `web/components/public-offering-detail.tsx:3-13`; `web/lib/public-offerings.ts:13-18` |
| Workspace offering 与成员报名 | 成员可进入 `/w/[slug]/events/[id]`；`open` offering 且本人无既有 Enrollment 时显示报名入口；复用 `createEnrollment` | `web/app/w/[slug]/events/[id]/page.tsx:1-15`; `web/components/offering-pages.tsx:415-447,587-627` |
| Enrollment 状态/权限 | `request` 创建 `pending`；Owner/Admin 批准占位并转 `confirmed`；GraphQL mutation 与 read policy 已存在；唯一索引防有效重复 | `backend/lib/cgc_2046/events/enrollment.ex:100-145,147-183,216-249`; `backend/lib/cgc_2046/events/enrollment.ex:393-437`; `backend/test/cgc_2046/events/enrollment_test.exs:10-177`; `backend/test/cgc_2046_web/graphql_create_enrollment_test.exs:12-134` |
| Approval UI | `/approvals` 拉取 `myPendingApprovals`，按 `enrollment`/`sponsorship`/`join_request` dispatch approve/reject；过期只读 | `web/app/approvals/page.tsx:3-12,55-137,177-270` |
| Enrollment → async Signal | create/confirm action 声明 `submitted`、`approved`、`completed` SignalEmitter；outbox 与 Oban worker 保证提交后异步投递；消费方按策略幂等 | `backend/lib/cgc_2046/events/enrollment.ex:110-167`; `backend/lib/cgc_2046/workers/signal_publish_worker.ex:3-10,16-45`; `backend/lib/cgc_2046/workflows/signal_subscriber.ex:27-40,75-115` |
| Enrollment → learning run | `LearningInstantiator` 订阅 `enrollment.completed`，校验 Enrollment confirmed + 已发布 learning definition，再 `find_or_create_and_start`；无定义时 best-effort skip，交给对账 | `backend/lib/cgc_2046/workflows/learning_instantiator.ex:22-24,36-60,63-135,179-203`; `backend/lib/cgc_2046/application.ex:29-37`; `backend/test/cgc_2046/workflows/learning_flow_test.exs:196-445`; `web/app/w/[slug]/workflows/page.tsx:3-9,62-91` |
| Event 级赞助 | 公开 Event 详情在 `sponsorshipEnabled && tiers` 时显示意向表单；提交后 `pending`；审批中心支持 approve/reject；激活物化 Delivery | `web/components/public-offering-detail.tsx:83-91,234-289`; `web/components/sponsorship-intent-form.tsx:3-10,43-110`; `backend/lib/cgc_2046/events/sponsorship.ex:1-18,157-212`; `backend/test/cgc_2046_web/graphql_sponsorship_test.exs:15-158` |
| Workspace 级赞助 | 后端 GraphQL `createSponsorship(level: workspace, targetWorkspaceId)`、Owner 审批与列表/履约账本已有；Web Workspace 页面目前是 Owner/Admin 管理面，不是非成员意向表单 | `web/lib/graphql/sponsorship.ts:8-12,145-176`; `web/app/w/[slug]/settings/sponsorship/page.tsx:3-10,23-64`; `backend/test/cgc_2046/events/sponsorship_flow_test.exs:29-489`; `backend/test/cgc_2046_web/graphql_sponsorship_test.exs:160-207` |
| Event ended 级联 | `event.ended` 经 outbox/worker，`SponsorshipEndedSubscriber` 只结束 Event 级 active sponsorship | `backend/lib/cgc_2046/events/sponsorship_ended_subscriber.ex:1-14,21-59`; `backend/lib/cgc_2046/workers/event_lifecycle_worker.ex:1-13,26-71`; `backend/test/cgc_2046/events/sponsorship_flow_test.exs:379-428` |
| Speaker 邀请 | Owner/Admin 在 Workspace Event 详情页创建邀请；一次性 token 着陆页接受/婉拒；材料写入 run facts 后完成 | `web/components/offering-pages.tsx:719-726`; `web/components/speaker-invitation-panel.tsx:18-24,68-273`; `web/app/events/[slug]/speaker-invite/[token]/page.tsx:3-10,86-108,165-233`; `backend/lib/cgc_2046/events/speaker_invitation.ex:1-23,177-270`; `backend/test/cgc_2046/events/speaker_flow_test.exs:33-626`; `backend/test/cgc_2046_web/graphql_speaker_invitation_test.exs:66-359` |
| 对账/死信可见性 | E-10 已合并；`/admin/reconciliation` 展示孤儿规则结果，`/admin/audit` 有 signal/workflow 只读面 | `web/app/admin/reconciliation/page.tsx:3-7,21-52`; `web/app/admin/audit/page.tsx:29-35,75-150`; `backend/lib/cgc_2046/reconciliation/finding.ex:23-27`; `backend/lib/cgc_2046/workers/reconciliation_scan_worker.ex:24-27,64-67` |

## 3. 锁定验收决策

| 编号 | 决策 |
|---|---|
| D1 | 以 GraphQL 为前后端唯一契约面；浏览器验证公开发现、详情、成员报名、审批、Event 级赞助、Speaker token 页面，Workspace 级赞助和 Speaker 材料完成使用真实 authenticated GraphQL mutation 验证，不引入未经设计的 UI 路由。 |
| D2 | 报名主链路使用 `request` 策略，必须观察 `pending → confirmed`；另用 `open` 策略验证公开详情直接报名/已报名去重，`invite_only` 仅验证邀请码/权限负向，不扩大主走查。 |
| D3 | 异步衍生的“成功”定义为：outbox job 已入队并被消费，若 fixture 有已 published learning definition，则页面或 GraphQL 读到唯一 `WorkflowRun`；没有 definition 的合法 skip 只能作为显式风险，不能冒充成功。 |
| D4 | 赞助两级分别使用不同 sponsor 账号和同一 Workspace：Event 级须从公开 Event 详情表单进入；Workspace 级使用 `createSponsorship(level=workspace,targetWorkspaceId)`，随后只允许 Owner approve，Admin approve 必须拒绝。 |
| D5 | Speaker 主走接受链路，另建第二邀请走拒绝链路；token 复用、无关账号接受、材料写入权限至少验证一项负向。材料提交通过已有 GraphQL seam，不伪造页面能力。 |
| D6 | 每条浏览器断言优先确定性证据：URL/文案/角色/状态类名/GraphQL 返回和几何；截图只作为感知层证据，不替代数值或交互断言。所有测试数据使用临时账号、Workspace、Event、Course、邀请、赞助和 Enrollment，结束后清理。 |
| D7 | 发现工作区级赞助没有面向非成员的公开意向 UI，记录为产品 backlog 观察项，不在 E-6 中私自新增路由；它不阻塞 GraphQL 主接缝的端到端验收。 |

## 4. 验收矩阵

### A. 公开发现与 Enrollment

| 步骤 | 入口/动作 | 必须观察 |
|---|---|---|
| A1 | 匿名 `/events`、`/courses` | 只出现 `open + public`；workspace-only、draft、closed、cancelled 不出现 |
| A2 | 匿名打开 public slug | 详情和白名单字段可读；无报名提交能力；workspace-only slug 返回统一不可访问/404 语义 |
| A3 | Learner 打开 `request` Event 详情或 Workspace 详情 | 报名策略、截止时间、报名入口显示；点击后页面显示“申请已提交/等待审批”，后端行 `pending` 带 deadline |
| A4 | Owner/Admin `/approvals` | 出现“活动报名”行、requester/context/deadline；点击“通过”后 Enrollment `confirmed`，待审批行消失 |
| A5 | Learner 刷新 Workspace Event 详情 | 已报名状态显示，不再出现第二个报名动作；数据库有效唯一性保持 1 |
| A6 | open Event 直接报名、重复点击/重复提交 | 首次 `confirmed`；第二次被唯一性/已报名状态拒绝，confirmed_count 不重复增加 |
| A7 | 非成员对 workspace-only 目标直接 GraphQL createEnrollment | 统一 not-found/closed 语义；不泄露该 offering 是否存在；成员路径仍可报名 |

### B. 异步衍生

| 步骤 | 入口/动作 | 必须观察 |
|---|---|---|
| B1 | A4 通过后检查 Oban/SignalLog | `enrollment.approved` 与 `enrollment.completed` job/signal 已入队并消费；不以 UI toast 代替后端证据 |
| B2 | 准备同 Workspace 已发布 learning definition | `enrollment.completed` 触发唯一 learning `WorkflowRun`，状态进入 `running`；重复投递不产生第二 run |
| B3 | Workspace `/w/[slug]/workflows` 或 GraphQL 查询 | 读到该 run；若有 facts，结构化展示；run key 与 Enrollment 对应 |
| B4 | 无 published learning definition 的对照样本 | 记录合法 best-effort skip 与 E-10 finding/日志，不将其计作 B2 通过 |

### C. Sponsorship 两级

| 步骤 | 入口/动作 | 必须观察 |
|---|---|---|
| C1 | Owner 为 Event 配 tiers 并启用 sponsorship；匿名/登录 sponsor 打开 Event public detail | tiers、权益、独占位展示；登录后表单提交成功，状态 `pending` |
| C2 | Owner `/approvals` approve Event sponsorship | 状态 `active`；对应 `SponsorshipDelivery` 按 tier benefits 物化；Event 管理面能看到未核销交付 |
| C3 | Owner 核销一条 delivery | `fulfilled_at`/`proof_note` 写入；重复核销被拒 |
| C4 | sponsor 通过 authenticated GraphQL 提交 Workspace sponsorship | `level=workspace`、目标 workspace 正确、状态 `pending`；不因 sponsor 非成员而错误加入 Workspace |
| C5 | Admin 尝试 approve Workspace sponsorship；Owner approve | Admin 被 policy 拒绝；Owner 成功后状态 `active`，workspace 级 delivery 可读 |
| C6 | Event close/cancel 后处理 `event.ended` | Event 级 sponsorship → `ended`；Workspace 级仍 `active`；重复 signal 幂等 |

### D. Speaker 邀请

| 步骤 | 入口/动作 | 必须观察 |
|---|---|---|
| D1 | Owner/Admin Workspace Event 详情创建邀请 | 返回一次性 plain token；邀请列表显示 invited；库中仅 token hash |
| D2 | Speaker 打开 `/events/[slug]/speaker-invite/[token]` | Event/title/topic/time 卡片；未登录引导登录并保留 next；登录后可接受/婉拒 |
| D3 | Speaker 接受主邀请 | 状态 `accepted`；`speaker.accepted`；decision run 门控继续；token 再用统一失败 |
| D4 | Speaker 用 GraphQL 保存材料并完成 | run facts 写入材料；邀请 `completed`；`speaker.completed`；run `succeeded` |
| D5 | 第二邀请走婉拒 | 状态 `declined`、run failed；该 token 不能再次决策 |
| D6 | 无关账号尝试接受/保存材料 | 返回 forbidden/统一失败；邀请与 run 状态不变 |

## 5. 实施与验证阶段

### Phase 0 — 环境与 fixture

- 复用项目现有本地 Dev server、认证和 GraphQL endpoint；优先连接既有登录浏览器，不能修改真实用户凭证。
- 为本次走查创建临时 platform admin、Owner、Admin、Learner、Sponsor、Speaker、非成员账号及一个 Workspace；创建 Event/Course、三种 enrollment policy 样本、已发布 learning definition、tiers、邀请和审批数据。
- 将 fixture id、账号角色和清理顺序写入 `/tmp/cgc-2046-e6-evidence.md`，禁止把 token、密码或个人数据提交 Git。

### Phase 1 — Enrollment/Signal

- 先运行现有后端契约测试和 web 组件/GraphQL 测试；若失败，按失败根因修复，不通过删断言或跳过。
- 按 A1-A7 浏览器/GraphQL 走查。
- 记录每个状态转移的 API response、数据库状态、Oban/SignalLog 证据和最终清理结果。

### Phase 2 — Sponsorship

- 按 C1-C6 走查 Event + Workspace 两级、审批、账本和 ended 级联。
- 以现有 `SponsorshipIntentForm`、`/approvals`、Workspace/Event 管理面为 UI 入口；Workspace sponsor submission 通过真实 GraphQL mutation。
- 复核 D7：不把“缺少 Workspace 级公开表单”误报为代码故障，单独记录产品 backlog。

### Phase 3 — Speaker

- 按 D1-D6 走查创建、token 着陆、接受/婉拒、材料 GraphQL mutation、完成和越权。
- 浏览器断言使用 `snapshot -i` + refs 交互；数值项用 DOM/computed style/geometry 断言，截图仅做感知复核。

### Phase 4 — 全套验证与收尾

- Backend: `cd backend && mix format --check-formatted && mix compile --warnings-as-errors && MIX_ENV=test mix test`；再用第二个 seed 复跑，至少覆盖本计划列出的 E-6 tests。
- Web: `cd web && pnpm typecheck && pnpm lint && pnpm test && pnpm build`。
- License: `mix cgc2046.check_licenses` 与 `pnpm check:licenses`。
- E2E:按 AGENTS.md 的确定性分层执行结构/样式断言、交互走通、必要时视觉截图；记录真实命令和输出。
- 清理临时数据；确认 `git status --short --branch` 仅有计划文件，提交 plan 后进入 advisor review。

## 6. 风险、阻塞与回滚

- **R1 学习定义缺失**：`LearningInstantiator` 合法 skip；Phase 0 必须显式创建 published learning definition，否则 B2 不可判 PASS。
- **R2 异步时序**：SignalPublishWorker/订阅方是 eventually consistent；使用 Oban testing/可观察 job 状态和 bounded wait，禁止固定 sleep 代替证据。
- **R3 Workspace sponsorship UI 缺口**：当前没有非成员 public intent form；本计划锁定 GraphQL seam，不新增未经拍板的路由；后续若产品要求 click-only，另立 issue/plan。
- **R4 Speaker 材料页面缺口**：当前 landing page 只承载决策；材料完成使用 GraphQL 已有 contract，UI 端到端验收不声称不存在的页面。
- **R5 私有数据**：所有 fixture 为临时本地数据；不读取/改写生产或真实用户数据，不在报告中输出 token/password。
- **回滚**：本计划默认只新增验证证据，不改业务代码；若为修复真实阻塞产生代码，单独提交可 revert 的修复 commit，并重新走 writer→advisor gate。

## 7. Signoff 标准

- A1-A7、B1-B3、C1-C6、D1-D6 均有真实入口和证据；B4 仅作为合法 skip/对账风险记录。
- Backend/web/license 命令真实运行并通过；e2e 结构/交互断言通过；临时数据清理完成。
- 端到端验收报告列出：commit、环境、测试命令与输出、每条矩阵结果、未覆盖项、R3/R4 产品观察项、回滚路径。
- advisor 独立复核 `STATUS / FILES / TESTS / RISKS / NEXT`，PASS + hard stops 0 后才允许 push/合并；若仅验证报告无代码，可将报告作为 issue #51 关闭依据。

## 8. 人类决策记录

- 2026-08-15：E-5 #50 已通过 advisor PASS、4/4 CI 并合并 PR #163；解除 #51 的显式 blocker。
- 2026-08-15：E-6 采用 GraphQL 主接缝；Event 级赞助用现有公开表单，Workspace 级赞助不新增未拍板公开路由，使用真实 GraphQL mutation 验收并把 UI 缺口单列。
