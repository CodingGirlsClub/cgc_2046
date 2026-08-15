# Plan 021 · 切片E 收尾（组2：#124 关闭 + #123 补差 + #122 补差）

- 日期：2026-08-15
- 状态：待评审
- 决策依据：Scout021 取证；用户拍板组2
- 关闭目标：#124（判定已落地可关闭）、#123（补 expired 重提入口）、#122（补 E-10 停滞 finding）

## 1. 取证判定汇总

| Issue | 判定 | 依据 |
|---|---|---|
| #124 生命周期级联 | **已落地，直接关闭** | 四条 AC 全绿：close/cancel CAS 状态机（`event.ex:371-447`/`course.ex:333-410`）、事务内 ended outbox（`signal_emitter.ex:1-83`）+ 幂等投递（`signal_subscriber.ex:150-205`）、research run 回收（`research_run_reaper.ex:1-74`）、deadline 自动 close（`event_lifecycle_worker.ex:1-83`）、报名窗锁定（`enrollment.ex:482-516` SQL open+deadline 守卫） |
| #123 审批控制台 | **差一项** | kind-agnostic 三类 dispatch/操作/48h 视觉/测试全在（`approvals/page.tsx:1-274`）；缺 expired 行「重提入口」AC（:245-263 仅文案）。另有 deadline 时序边界风险 |
| #122 学习 workflow | **差一项** | 协议/幂等实例化/授权账本/末步 discharge/7d 提醒全在（`learning_instantiator.ex`、`save_step_output.ex:1-120`、`learning_progress_worker.ex:74-180`）；缺「停滞规则入 E-10 对账扫描」AC——`reconciliation_scan_worker.ex:83-122` 仅六规则，`learning_progress_worker.ex:20-30` moduledoc 自认不在 E-10 v1 |

**#124 残余（非 AC，记录后另立）**：close/cancel 后既有 pending/confirmed enrollment 不级联、无 ended 通知学员——产品决策项，本 plan 只在关闭评论记录，不默默扩范围。

## 2. High-Level Technical Design

### U1 #123 补差：expired 重提入口
1. 前端 `web/app/approvals/page.tsx` expired 区（:245-263）：每行按 kind 加重提链接——
   - enrollment：→ `/participations`（014 已建我的报名页，可重新发起报名）；
   - join_request：→ `/join?workspace=<slug>`（申请者可重新提交）；
   - sponsorship：→ 目标活动公开页（`/events/<id>` 或 workspace 公开赞助入口——writer 按 sponsorship 行携带的 context 字段定落点，无公开入口则链到 workspace 概览）。
   文案「已过期 · 申请者可重新提交」+ 链接可点。
2. **deadline 时序边界修复**：pending 行的按钮渲染条件加「deadline 未过」（行级 `approvalDeadline > now` 派生，与 ApprovalChip 同源）——消除 ApprovalExpiryWorker 落库前的短窗口假按钮（后端 `enrollment.ex:608-610` claim 守卫已拒，前端对齐）。后端不改（`pending_approvals.ex:128-158` 保持 status 口径，KTD8 先例：展示含过期、行为按 deadline 守卫）。
3. 测试：expired 三 kind 链接断言；deadline 已过 pending 行无操作按钮断言。

### U2 #122 补差：E-10 停滞 finding
1. `reconciliation_scan_worker.ex` 新增第七规则 `learning_run_stalled`：扫描 `status=running ∧ definition.type=learning ∧ facts 未更新 > 7d`（阈值复用 `learning_progress_worker` 的停滞口径，同源常量抽出）；产出 ReconciliationFinding 行（severity/详情按既有六规则形状）。
2. 与 `learning_progress_worker` 的 7d 提醒分工：worker 负责提醒学员；E-10 finding 负责对账可见（/admin 或 findings 消费面按既有规则展示路径，无专属 UI 则随 findings 列表）。
3. 幂等：同 run 未消解 finding 不重复建（对齐既有规则 claim 语义）。
4. 测试：停滞 run 产 finding、活跃 run 不产、7d 边界、重复扫描幂等。

### U3 #124 关闭（零代码）
关闭评论：四条 AC 对照表 + 已落地证据 file:line + 残余两项（enrollment 级联处置、ended 学员通知）明确为「需产品另拍板的新范围，未纳入 #124」。

## 3. 文件清单

- `web/app/approvals/page.tsx`（U1.1/1.2）+ `web/app/approvals/page.test.tsx`（如无则新建）
- `backend/lib/cgc_2046/workers/reconciliation_scan_worker.ex`（U2.1）
- `backend/lib/cgc_2046/workers/learning_progress_worker.ex`（U2.1 常量同源，仅引用不改逻辑）
- `backend/test/cgc_2046/workers/reconciliation_scan_worker_test.exs`（U2.4 扩展）

## 4. 验收标准

1. expired 三 kind 行有可点重提链接；deadline 已过 pending 行无操作按钮（单测钉住）。
2. E-10 第七规则：停滞 learning run 产 finding，幂等，边界准确；既有六规则回归全绿。
3. #124/#123/#122 全部关闭，评论含对照与残余记录。
4. backend ×2 seeds + web 全套绿。

## 5. 实施顺序

U1 → U2 → 自查 → commit 不 push → `/tmp/cgc_2046-writer21-report.md`；U3 由 orchestrator 在 PR 合并后执行。

## 6. Assumptions（writer 验证，冲突即停）

1. sponsorship 行 context 含目标活动可链信息（`pending_approvals.ex:75-220` 行形状）；不足则降级链 workspace 概览并注明。
2. `reconciliation_findings` 表结构支持新规则码（既有六规则同表）；规则码命名对齐既有风格。
3. approvals 页面测试文件现状以 HEAD 为准（015-A4 曾加 count 测试，扩展不覆盖既有断言）。
