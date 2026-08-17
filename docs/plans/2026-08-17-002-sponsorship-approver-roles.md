# 架构深化候选 F：赞助审批人规则单源（approver_roles）+ 待办读面行级过滤（修潜伏 bug）

> 日期：2026-08-17 · 来源：架构深化评审 2026-08-16 候选 F（`docs/reviews/architecture-review-2026-08-16.html`，git 2138b34；跟踪 issue #185）+ scout 只读取证（ApproverRolesScout，HEAD 7041888 重定位）· 状态：自治流水线批准（用户 2026-08-17 点名「候选 F 体量小建议优先」）
> 范围纪律：修 bug 的行为变更**仅限 admin 读面**（workspace 级赞助行从 list/count 消失）；提醒收件人面**零变化**（已正确分叉且被测试钉死）；写面行为不变；SDL/前端零改。

## 问题（HEAD 7041888 坐实）

「谁是审批人」规则（拍板 #4：Event 级 = Owner/Admin；Workspace 级 = 仅 Owner）三份陈述且读面与写面**实际不一致**：

| 面 | 位置 | 现状 |
|---|---|---|
| 写面 | `policies/sponsorship_approver.ex:22-34`（match? level 分叉；消费 = `sponsorship.ex:341-343` approve/reject policy） | 正确（唯一规则实现） |
| 提醒面 | `workers/approval_reminder_worker.ex:123-157`（per-workspace 预取 `:manage` 与 `{:roles,[:owner]}` 两套 + `is_nil(event_id)` 逐行分派） | **收件人已正确分叉**（`approval_reminder_worker_test.exs:480-556` 钉死「Workspace 级仅 Owner，Admin refute_enqueued」），但 selector 是规则第二份硬编码陈述 |
| 读面 | `events/pending_approvals.ex:73-82`（managed_workspace_ids 按 manage_role? 收窄且**丢弃角色**）+ `:145-148`/count 路径（Sponsorship 无 level 过滤） | **潜伏 bug**：admin 在 myPendingApprovals list 与 pendingApprovalsCount 都看到 workspace 级 pending 赞助（读 policy `WorkspaceActorIsOwnerOrAdmin` 放行），点审批被 SponsorshipApprover 拒——看得到点不动；当前错误行为无测试钉住 |

## 锁定决策

| # | 决策 |
|---|---|
| D1 | **唯一规则面**：`Cgc2046.Policies.SponsorshipApprover.approver_roles/1`——`approver_roles(:event) -> Role.manage_roles()`（同源，角色清单变更自动跟随）；`approver_roles(:workspace) -> [:owner]`。放 policy 模块（拍板 #4 规则既有归属地，纯函数薄壳，避免资源侧第二真源） |
| D2 | **写面委托**：match? 改 `Enum.any?(roles, &(&1 in approver_roles(level)))`——行为保持（:event 分支与 manage_role? 同集） |
| D3 | **提醒面消重复**：ARW select 补 `:level`；per-workspace 预取两套 selector 改按 `{:roles, approver_roles(level)}` 派生（两套预取形状不变——一工作台可同时含两级）；逐行分派 `is_nil(event_id)` 改按 `row.level`。**收件人零变化**（测试已钉，改后同测试必须原样绿） |
| D4 | **读面行级过滤**：`managed_workspace_ids/1` 改携带 per-workspace 角色名（`memberships_of_actor` 已 load roles，无 N+1）；对每 workspace 派生 `allowed_levels`（满足 `&(&1 in approver_roles(lvl))` 的 level 集）；以 Ash expr `level in ^allowed_levels` 下推到 sponsorship 的 **pending 与 expired 两条路径 + count 路径**（count 保持 SQL 聚合不物化行；expired 同规则过滤——否则 admin 仍见 workspace 级「已过期」行）。Enrollment/JoinRequest 路径零变 |
| D5 | **行为变更清单**（验收基线）：admin 读面 workspace 级赞助行消失（list+count+expired）；owner 两级都见（不变）；event 级两级都见（不变）；写面/提醒收件人/SDL/前端零变 |
| D6 | **测试**：`graphql_pending_approvals_test.exs` 增 list 回归（admin 无 workspace 级行 / owner 有 / event 级 admin+owner 都有）；`graphql_pending_approvals_count_test.exs` 增 count 回归（admin 排除 workspace 级、owner 两级都计）；新增 `test/cgc_2046/policies/sponsorship_approver_test.exs` 钉 approver_roles/1 纯函数（policies 目录同款专测先例）。既有测试零改动 |
| D7 | **文档**：CONTEXT.md 新增「赞助审批人（Sponsorship Approver Roles）」词条（规则唯一真源 approver_roles + 三消费面 + 拍板 #4 引用） |
| D8 | **不动**：NotificationFanout 本体（selector 机制现成）、sponsorship.ex policy 结构与读写 policy、`is_nil(event_id)` 不变量本体（仍成立，仅 ARW 不再作分派依据）、前端 web/、GraphQL SDL |

## 改动清单

- **改**：`backend/lib/cgc_2046/policies/sponsorship_approver.ex`（+approver_roles/1，match? 委托）· `backend/lib/cgc_2046/workers/approval_reminder_worker.ex`（select +:level；selector 派生；分派按 level）· `backend/lib/cgc_2046/events/pending_approvals.ex`（managed_workspace_ids 携带角色；sponsorship 三路径 level 过滤）· `backend/test/cgc_2046_web/graphql_pending_approvals_test.exs`（+回归）· `backend/test/cgc_2046_web/graphql_pending_approvals_count_test.exs`（+回归）· `CONTEXT.md`
- **新增**：`backend/test/cgc_2046/policies/sponsorship_approver_test.exs`
- **不动**：D8 清单 · 数据库/配置/前端/图：无

## 实施顺序与验收

1. approver_roles/1 + policy 纯函数测试 + match? 委托（sponsorship_flow_test 写面 197-216 原样绿）
2. ARW 派生改造（approval_reminder_worker_test 480-556 原样绿——收件人零变的证明）
3. PendingApprovals 读面过滤 + list/count/expired 回归
4. CONTEXT.md 词条
5. 验收：`mix format --check-formatted` + `mix compile --warnings-as-errors` + `MIX_ENV=test mix test` ×2 seeds 全绿；既有测试零改动；SDL 零变（如生成物检查可用）
