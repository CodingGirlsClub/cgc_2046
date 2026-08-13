---
title: Slice E 整合计划 — 决策签核包
type: signoff
date: 2026-08-13
status: approved
reference: docs/plans/2026-08-13-001-slice-e-integration-plan.md
topic: course-event-slice-e
---

# 签核记录

- 2026-08-13 用户签核（逐字引用）：「**全部同意。但是 signal_idempotency migration 已经在 PR 了 pr://121**」
- 结论：D1-D8 全部批准（推荐方案）；signal_idempotency 表由 PR #121 承载，不再作为 Phase 1 新建项。
- 登记结果：新增 #122（E-7 学习设计）、#123（E-8 审批控制台）、#124（E-9 生命周期级联）、#125（E-10 对账扫描）；修订 #46/#47/#48/#50 body（实体自序贯口径 + D5 履约账本 + D2/D3/D4 决策）。

---

# 签核包：Slice E 整合计划 8 项决策

**状态：`approved`**（2026-08-13 用户签核，见签核记录）。D1-D8 全部按推荐方案批准。

## Executive Summary

ideation Idea 1（判据 + 报名最小接线）已合并（PR #119），slice E 骨架 #46-51 全 OPEN 且唯一阻塞 #39 已关闭。本包把 Idea 2-7 定稿为「地基（E-9 级联）→ 公开面（E-5）→ 审批（E-8）→ 三 workflow（E-3/E-4/E-2）→ 学习设计（E-7）→ 对账（E-10）→ 端到端（E-6）」的执行序列。8 项决策已全部批准。

## Evidence

- 计划全文与证据路径：`docs/plans/2026-08-13-001-slice-e-integration-plan.md`（现状证据表含行号）。
- Idea 1 已合并：PR #119（ADR-0005 + enrollment 信号 + 48h 提醒扫盲 + GraphQL createEnrollment）。
- signal_idempotency 表：PR #121（OPEN）——E-9/E-2/E-3 去重基座。
- 赞助/邀请设计定稿零实现；Event/Course 死枚举（`event.ex:30`）；WorkflowRun 已含 expired 终态。

## Roster（计划阶段）

- roster.json：`/tmp/sop-roster-e.json`（4 found, 1 healthy）。
- orchestrator: claude（anthropic, frontier, 本会话活体）。
- sole-writer: claude 本会话（anthropic, frontier；tie-break 后唯一活体验证者）。
- reviewer: codex（openai, frontier, 跨厂商 ✓, background recipe ready）。
- scouts: 会话 scout 子代理（fast）；pi/gemini probe 失败被跳过。
- gates: 计划审批（已通过）/ D2 安全变更（已批准，实施时守白名单）/ D1 issue 登记（已执行）/ 部署与重启（届时另行签核）。

## 决策清单（8 项 — 全部批准）

### D1 · 新工作登记方式 — ✅ 批准（y）

新增 4 个 slice E issue：**#122 E-7 学习设计 / #123 E-8 审批控制台 / #124 E-9 生命周期级联 / #125 E-10 对账扫描**；修订 #46（移除 ash_jido 表述）、#47（生产者已建，剩订阅方）、#48（补 D5 履约账本 + #124 依赖）、#50（流程展示页只服务 run 化 workflow + D2/D3 决策）。已执行（2026-08-13）。

### D2 · 公开字段白名单（安全语义变更）— ✅ 批准（y）

读策略翻转：`status=open` ⇒ 匿名可读。公开：title、slug、描述、registration_deadline、status、enrollment_policy、sponsorship_enabled + 赞助档位展示名。**不公开：capacity、confirmed_count**。写入路径不变（仍走 partition 鉴权）。实施时 deny-by-default 写法。

### D3 · GO/NO-GO readiness 语义 — ✅ 批准（y）

launch 时校验清单，缺项 → warning 日志 + readiness 查询暴露后台，不阻塞 launch。清单 v1：registration_deadline 已设（null=无截止合法，仅提示）、sponsorship_enabled 时 tiers 已配置、published research 定义存在。

### D4 · 生命周期级联触发时点 — ✅ 批准（y）

`close`（open→closed）手动 + Oban cron 到点自动；`cancel` 手动；两动作发 `event.ended`/`course.ended`。不新增 `end_at` 字段，closed/cancelled 即「结束」语义。订阅方：教研 run 回收（总纲:171）、赞助 Event 级自动 ended（总纲:105）、报名窗锁定。

### D5 · 赞助履约账本（范围变更）— ✅ 批准（y）

`SponsorshipDelivery`（sponsorship_id、benefit、due_date、fulfilled_at、proof_note + 独占位标记）：激活时从 `tier.benefits` 物化交付行，后台核销，独占位条件 UPDATE 防双重预定。makegood 不做（二期）。修订赞助设计 doc（v1.3）。

### D6 · 学习 workflow 三语义 — ✅ 批准（y, N=7）

1. **variance**：`save_step_output` 载荷加可选 `reason` 字段，随 facts 落账本；
2. **completion/discharge**：定义末步完成 ⇒ run succeeded，产出即工件；
3. **停滞升级**：对账扫描停滞规则 + 48h 提醒模式复用（N=7 天无 step 输出）。

### D7 · 审批控制台形状 — ✅ 批准（y）

kind-agnostic 行 + per-kind dispatch；**v1 不含 WorkflowRun-waiting**（StepAuthorization 双重语义）。

### D8 · 对账规则与消费纪律 — ✅ 批准（y）

v1 四条规则（confirmed 无 learning run / pending 无 approval_deadline / sponsorship active 无 sponsorship.active signal_log / open event 无 published research 定义）；平台级 Oban job + 报告进 `web/app/admin` 对账页。

## 实施影响

- 全序列无数据库破坏性迁移（signal_idempotency 由 PR #121 提供、SponsorshipDelivery 为新增表）；无服务重启风险；无新外部依赖。
- D2 已批准（匿名读范围扩大），实施时按白名单逐字段放行。
- issue 登记已执行；实施直接按 #124 → #50 → #123 → #48/#49/#47 → #122 → #125 → #51 推进。

## 风险与回滚

- 读策略翻转回滚 = 恢复读策略过滤（单处策略变更，可即时回退）。
- 级联 cron 若误 close：close 仅 open→closed，加守卫 + 幂等；回滚 = 停 cron + 手动状态修复。
- 履约账本 = 纯新增，无既有数据迁移。

## Open decisions

- 无。D3 的「阻塞升级」时点、D6 的 N 值调整可在实施中提出，不阻塞开工。

---

# 二次签核记录（2026-08-13 · E-11 与可见性轴）

- 用户签核（逐字引用）：「**新增 issue（E-11 workspace 活动管理面）， 普通成员也在 workspace 内看到活动列表**」
- 用户签核（逐字引用，成员级可见性取舍）：「**a 就可以了**」（对应选项 A：不引入第四轴；「私享会」= `visibility=workspace + enrollment_policy=invite_only`）
- D9 定稿：`visibility: public | workspace` 字段；读策略修订为 `open + visibility=public` ⇒ 匿名可读（D2 条件化）；成员见 workspace 全量活动。
- **按推荐采纳（非显式签核，可推翻）**：默认 `public`；执行顺序 E-11（#127）先行、E-5（#50）后行。（open 后不可改推荐已被用户推翻，见下条。）
- 用户签核（逐字引用，可改性）：「**允许默认值后续可以切换呀， 既允许 plublic --> workspace, and also allow open --> 其他的。**」→ visibility 可随时双向切换（含 open 后）；「open 后不可改」推荐被推翻。
- 登记：#127（E-11）；修订 #50（E-5 只消费 open+public，Blocked by #127）；整合计划拓扑重排（Phase 2=E-11，Phase 3=E-5）。
