# L1 领域模型漂移取证底稿（图 ↔ codebase）

> 取证：L1DomainScout（2026-08-16）· 基准：`.worktrees/docs/diagram-taxonomy`（develop@72c5924）
> 汇总判定见 [DRIFT-REPORT.md](../DRIFT-REPORT.md) §5.2；本文件为证据底稿。

## 1. Ash 资源全集（32 个模块 → 表，按 Ash.Domain 分组）

**Cgc2046.GlobalApi「Accounts & Tenancy」15 个**（注册清单 `backend/lib/cgc_2046/global_api.ex:37-73`）

| 模块 | 表 | 关键枚举/UK |
|---|---|---|
| Accounts.User | users | email 可空（小程序手机号用户，user.ex:47-51）+ phone 部分唯一（:347）+ display_name |
| Accounts.Token | tokens | AshAuthentication TokenResource（jti/subject/purpose，无 user_id 列，token.ex:1-8）|
| Accounts.UserIdentity | user_identities | provider: wechat\|tt\|xhs（:29）；unique (provider,uid)（:69）|
| Accounts.Workspace | workspaces | join_policy open\|request\|invite_only（:47）；sponsorship_tiers 内嵌 json（:59）；UK slug（:432）|
| Accounts.WorkspaceMembership | workspace_memberships | UK (workspace_id,user_id)（:150）|
| Accounts.MembershipRole | membership_roles | UK (membership_id,role_id)（:54）|
| Accounts.Role | roles | name: owner/admin/tutor/volunteer/learner + 退役 member（role.ex:29,41）；UK (workspace_id,name)（:118）|
| Accounts.PortfolioItem | portfolio_items | icon: document\|book\|guide（:72）|
| Accounts.WorkspaceProfile | workspace_profiles | visibility public\|workspace\|only_me（:85）；UK (workspace_id,user_id)（:212）|
| Accounts.JoinRequest | join_requests | status pending\|approved\|rejected\|**expired**（:48）|
| Accounts.Invitation | invitations | status active\|used\|revoked\|**expired**（:77）；UK token_hash（:182）；preauthorized_role_names（:63）|
| Accounts.WorkspaceApplication | workspace_applications | status pending\|approved\|rejected\|expired（:62）；全局资源（无 tenant）|
| Accounts.AdminActionLog | admin_action_logs | action: workspace_create/application_approve/…（:37-39）；target_type（:53）|
| Miniprogram.Code | miniprogram_codes | platform wechat\|tt\|xhs（:18）；UK (invitation_id,platform) + scene（:44-45）|
| Miniprogram.NotificationConsent | mp_notification_consents | UK (user_id,platform,template_key)（:30）|

**Cgc2046.Api「Workflows & Events」14 个**（注册清单 `backend/lib/cgc_2046/api.ex:29-52`）

| 模块 | 表 | 关键枚举/UK |
|---|---|---|
| Workflows.WorkflowDefinition | workflow_definitions | type 6 值与图一致（:40-47）；status draft\|published\|archived（:48）；version **integer**（:59-65）；UK (workspace_id,name,version)（:258）|
| Workflows.Step | workflow_steps | type **:sub_workflow**（:29，图写 subworkflow）；UK (definition_id,step_key)（:148）|
| Workflows.StepRole | workflow_step_roles | UK (step_id,role_id)（:82）|
| Workflows.WorkflowRun | workflow_runs | status **+expired**（:59）；partition_id=workspace_id（:112-117）；definition_version 快照（:80）+ 乐观锁 version（:120）|
| Workflows.SignalLog | signal_logs | run_id 无 FK（审计保留，:111-115）|
| Workflows.SignalIdempotency | signal_idempotency | UK (signal_type,idempotency_key)（:66）|
| Reconciliation.Finding | reconciliation_findings | rule 七值（:46-54）；UK (rule,entity_type,entity_id)（:122）|
| Events.Event | events | status/enrollment_policy 与图一致；**无 materials_review_required**；+slug/visibility/research_*/confirmed_count/sponsorship_tiers（event.ex:29-163）|
| Events.Course | courses | 同 Event；无 sponsorship 字段（与图一致）（course.ex:35-130）|
| Events.InviteBatch | invite_batches | UK invite_code（:75）；status active\|disabled（:53）|
| Events.Enrollment | enrollments | status **+expired**（:58）；partial UK (event_id/user_id) where status∈{pending,confirmed}（:249-252）|
| Events.Sponsorship | sponsorships | status **+expired**（:84）；partial UK per event/workspace（:322-325）；tier_id 指向内嵌档位 id（:66-69）|
| Events.SponsorshipDelivery | sponsorship_deliveries | benefit/due_date/fulfilled_at/proof_note/exclusive（:28-52）|
| Events.SpeakerInvitation | speaker_invitations | status 与图一致（:117-120）；UK token_hash（:174）|

**Cgc2046.Mcp 3 个**（`backend/lib/cgc_2046/mcp.ex:34-38`）

| 模块 | 表 | 关键枚举 |
|---|---|---|
| Mcp.Token | mcp_tokens | token_hash/name/last_used_at/revoked_at（:30-60）|
| Mcp.ToolCallLog | mcp_tool_call_logs | result_status **ok\|error\|needs_confirmation\|forbidden**（:45）；pending_operation_id（:63）|
| Mcp.PendingOperation | mcp_pending_operations | status **pending\|confirmed\|cancelled**（:52）；expires_at/resolved_at |

非 Ash 但持久的表：`oban_jobs`（20260808125000_add_oban_jobs.exs）、`jido_checkpoints`/`jido_thread_meta`（jido_storage_postgres.ex:63,253 raw SQL）——后者即图上 AgentRun 持久语义的真实替代。
**payments 域在本基线不存在**（`lib/cgc_2046/payments` 无此路径；迁移目录亦无 payment 表）。

## 2. 图断言 vs 码现实差异表

判定四态：一致 / 图旧（图内容过时）/ 悬空（图有码无）/ 图漏（码有图无，良性演进）。

### 实体存在性

| 图断言 | 码现实 | 判定 | 备注 |
|---|---|---|---|
| User(id/email/is_platform_admin) | users 表，email 可空 + phone + display_name | 一致(+扩展) | user.ex:47-83 |
| Identity(user_id/provider) | UserIdentity + uid/unionid | 一致 | user_identity.ex:29 |
| Token(user_id FK) | AshAuthentication tokens（subject 非 user_id 列） | 图旧 | accounts/token.ex:1-8 |
| Workspace(slug UK/join_policy/sponsorship_enabled) | 全部命中，另内嵌 sponsorship_tiers/sponsorship_deadline | 一致(+扩展) | workspace.ex:42-70,432 |
| WorkspaceMembership / MembershipRole / Role | 三者齐备，UK 齐备 | 一致 | :150/:54/:118 |
| Profile(membership_id FK, avatar/intro/portfolio) | WorkspaceProfile 键=（workspace_id,user_id）；portfolio 拆出 PortfolioItem 独立资源 | 图旧 | workspace_profile.ex:212；ADR-0004 |
| Invitation(status: active\|used\|revoked) | +:expired、+preauthorized_role_names/accepted_by | 图漏(枚举) | invitation.ex:63-79 |
| JoinRequest(status: pending\|approved\|rejected) | +:expired | 图漏(枚举) | join_request.ex:48 |
| WorkflowDefinition(type 6 枚举/status/version: string/node_def: Runic.Workflow) | type/status 一致；version=**integer**；node_def=:map；+approval_timeout | 图旧(3 处) | workflow_definition.ex:40-110 |
| WorkflowRun(status 六值/partition_id/started/finished) | +:expired、+definition_version 快照、+乐观锁 version | 图漏(枚举+字段) | workflow_run.ex:59,80,120 |
| Step(type: …\|subworkflow) | :sub_workflow；+step_key/action/input_schema | 图旧(命名) | step.ex:29 |
| StepRole | 齐备 | 一致 | step_role.ex:82 |
| SignalLog(run_id/signal_type/payload/actor_id/received_at) | 齐备（run_id 无 FK 属实现细节） | 一致 | signal_log.ex:34-72 |
| **Agent**(type/owner/openclacky_profile) | 无任何资源/表 | 悬空 | 全库 grep 无 Agent 资源 |
| **AgentRole** | 无 | 悬空 | 同上 |
| **AgentRun**(agent_id/step_id/operator_id/status) | 无持久资源；仅内存 RunAgent struct（Jido 载体）+ jido_checkpoints raw 表 | 悬空(有替代) | run_agent.ex:3-9；jido_storage_postgres.ex:63 |
| PendingOperation(actor_id/tool/params/summary/status/expires_at) | 存在；status=pending\|**confirmed\|cancelled**（无 rejected）；actor_id 实为 user_id；+resolved_at | 图旧(枚举/字段) | pending_operation.ex:26-71 |
| ToolCallLog(confirm_id/status: ok\|denied\|pending\|confirmed\|rejected) | confirm_id→**pending_operation_id**；status→result_status: ok\|error\|needs_confirmation\|forbidden | 图旧(枚举+字段) | tool_call_log.ex:38-65 |
| Event(materials_review_required) | **字段不存在**（全库 grep 0 命中）；另 +slug/visibility/research_enabled/research_requirements/confirmed_count/sponsorship_tiers | 悬空(字段)+图漏 | event.ex:29-163 |
| Course(materials_review_required) | 同上，字段不存在 | 悬空(字段) | course.ex:35-130 |
| Enrollment(status 四值/event\|course 二选一/invite_batch_id/approved_by…) | +:expired、+submission_payload/capacity_seq/approval_deadline；partial UK | 图漏(枚举+字段) | enrollment.ex:39-72,249-252 |
| InviteBatch(invite_code UK/quota/remaining_quota/status) | 全部命中 | 一致 | invite_batch.ex:33-75 |
| Sponsorship(level/tier_id/tier_name/status/amount/company…) | +:expired、+message/started_at/ended_at；partial UK | 图漏(枚举+字段) | sponsorship.ex:32-98,322-325 |
| **SponsorshipTier**(独立实体: name/amount_suggestion: decimal/benefits/limit/enabled) | **无表无资源**：档位=Event/Workspace.sponsorship_tiers 内嵌 json + 纯函数模块；amount_suggestion=integer；+exclusive（D5）；limit 从未实现 | 悬空(改内嵌) | sponsorship_tier.ex:3-21；workspace.ex:59；event.ex:124-128 |
| SpeakerInvitation(全部字段) | 全部命中；+topic/scheduled_at/note | 一致(+扩展) | speaker_invitation.ex:43-141 |
| **ResearchOutput**(key/kind/status/submitted_by/reviewed_by) | **无资源**：教研产出=WorkflowRun.facts（按 step_key 聚合）；instance key 语义保留在 ResearchInstantiator | 悬空 | workflow_run.ex:96-100；research_instantiator.ex:4-7 |

### 关系与基数

| 图断言 | 码现实 | 判定 | 备注 |
|---|---|---|---|
| USER/WORKSPACE ||--o{ WM；WM ||--o{ MR；ROLE ||--o{ MR | UK 对应 | 一致 | :150/:54 |
| WM ||--o\| PROFILE（membership_id） | WorkspaceProfile 直接挂 (workspace_id,user_id) | 图旧 | workspace_profile.ex:212 |
| WORKSPACE ||--o{ WFDEF/ROLE/EVENT/COURSE/INVITATION/JOINREQUEST/PENDING/TOOLCALL/SPONSORSHIP | 各资源 workspace_id + multitenancy attribute | 一致 | 各资源 multitenancy 块 |
| WFDEF ||--o{ STEP / WFRUN；STEP ||--o{ STEPROLE | definition_id 归属 + UK | 一致 | step.ex:104-115 |
| WFRUN ||--o{ SIGNALLOG | 存在（无 FK，run 删除后保留审计） | 一致 | signal_log.ex:111-115 |
| STEP }o--\|\| AGENT | Step.agent_id 存在但**无 Agent 目标资源** | 悬空 | step.ex:68-71 |
| WORKSPACE ||--o{ AGENT | 无 | 悬空 | — |
| TIER ||--o{ SPONSORSHIP（tier_id FK） | tier_id → 内嵌档位 map 的 id，无表 FK | 图旧 | sponsorship.ex:66-69 |
| WFRUN ||--o{ Enrollment/Sponsorship/SpeakerInvitation（workflow_run_id） | 三资源均有 workflow_run_id | 一致 | enrollment.ex:48 等 |
| WFRUN ||--o{ ResearchOutput | 无 | 悬空 | — |
| Event/Course ||--o{ Enrollment / InviteBatch（二选一 FK） | event_id+course_id + 校验 | 一致 | invite_batch.ex:84-95 |
| InviteBatch ||--o{ Enrollment | invite_batch_id 存在 | 一致 | enrollment.ex:49 |

### 码有图无（图漏，9 个新资源 + 2 张非 Ash 表）

| 资源/表 | 域 | 证据 |
|---|---|---|
| Events.SponsorshipDelivery（履约账本，Sponsorship 激活时从 tier.benefits 物化） | events | sponsorship_delivery.ex:2-9,28-52 |
| Workflows.SignalIdempotency（四业务 workflow 共用幂等登记） | workflows | signal_idempotency.ex:2-19 |
| Reconciliation.Finding（平台级孤儿对账，7 规则） | reconciliation（新域） | finding.ex:2-4,46-54 |
| Accounts.WorkspaceApplication（platform_admin 审批建台） | accounts | workspace_application.ex:1-14 |
| Accounts.AdminActionLog（admin 治理留痕） | accounts | admin_action_log.ex:19-23 |
| Accounts.PortfolioItem（作品集，自 Profile 拆出） | accounts | portfolio_item.ex:23-30 |
| Mcp.Token（MCP 连接 token，与登录 Token 分离） | mcp | mcp/token.ex:30-60 |
| Miniprogram.Code（小程序码缓存） | miniprogram（新域） | miniprogram/code.ex:1-19 |
| Miniprogram.NotificationConsent（订阅授权缓存） | miniprogram | notification_consent.ex:29-31 |
| oban_jobs / jido_checkpoints / jido_thread_meta（raw Ecto 表，非 Ash） | infra | 迁移 20260808125000；jido_storage_postgres.ex:63,253 |

**澄清**：Learning/CourseIssue 新实体——本基线不存在 CourseIssue（grep 0 命中）；Learning 域只有纯函数投影 LearningProgress + LearningProgressWorker + learning_instantiator，无新资源。

## 3. 结论

两张 L1 图的**骨架（引擎四件套 + 业务四聚合 + 身份租户核心）与代码高度对应**，但按四态统计：悬空 6 处（Agent/AgentRole/AgentRun/ResearchOutput/SponsorshipTier 独立表/materials_review_required 字段）、图旧 9 处（集中在枚举值过期与字段改名：expired 普遍缺位、PendingOperation/ToolCallLog 枚举整体过时、version:string→integer、subworkflow→sub_workflow、Profile 键迁移、Token user_id→subject）、图漏 9 资源 + 若干枚举扩展。建议老图按「删悬空、改枚举、补新域（reconciliation/miniprogram/delivery）」三步重绘。
