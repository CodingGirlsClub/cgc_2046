# 架构深化候选 A+B：ApprovalClaim 收编原子抢占原语 + ApprovalDeadline 谓词端口

> 日期：2026-08-17 · 来源：架构深化评审 2026-08-16 Top recommendation（`docs/reviews/architecture-review-2026-08-16.html`，分支 docs/diagram-taxonomy@2138b34 未合入；跟踪 issue #185）+ scout 三切片只读取证（ClaimFamilyScout / PredicatePortScout / ConventionsScout，行号 HEAD 6282163 磁盘重定位）· 状态：自治流水线批准（用户 2026-08-17 点名「先做 A + B（一个 PR 内协同）」）
> 范围纪律：**行为不变铁律**——三套错误 taxonomy 现状保持、全部谓词边界（nil / ==now）逐点不变、D7 冻结面（@expiry_specs / 48h 窗口 / ARW·AEW·pending_approvals·reconciliation 的 Ash expr pushdown）不 re-open。只收 claim SQL 构造 + 执行 + num_rows 判读，不收错误映射 / 锁 / 组合序。

## 目标

1. **A**：抽 `Cgc2046.ApprovalClaim` 收编原子 claim 条件 UPDATE 家族——7 资源 / 14 条 SQL 语句（评审按 14 处拷贝计，HEAD 实测 17 个 SQL 变体中 14 条收编、其余保留，见 D4/D5）。资源 action 退化为：算好参数 → 一行 claim → 自己的错误映射 + force_change + after_action 效果。
2. **B**：`Cgc2046.ApprovalDeadline` 补齐谓词端口——新增 `not_expired?/2`，消 NotificationWorker 两处 inline 绕过；ApprovalClaim 的 deadline 守卫片段成为该谓词的 SQL 端口（一次深化、两处收敛）。
3. A+B 协同点：claim SQL 守卫 `(col IS NULL OR col > $now)` 与 `not_expired?/2` 是同一语义的 SQL/Elixir 双表达，测试对偶钉死。

## 锁定决策

| # | 决策 |
|---|---|
| D1 | **模块形态**：root 单文件函数模块 `lib/cgc_2046/approval_claim.ex`（`Cgc2046.ApprovalClaim`），非 Ash change 模块、非 Repo 方法。理由：横切写原语与 ApprovalDeadline（横切读面）/NotificationFanout 同级先例；claim 前后各有资源特定序（advisory lock → claim → 读回消歧 → force_change → after_action），声明式 change 装不下，函数式调用让组合序留在资源层 |
| D2 | **interface**：`claim(record, opts) :: {:ok, returned :: map()} \| {:error, :not_claimed}`（record 为资源 struct，取 id）。opts 轴：`table:`（编译期枚举 atoms，拒绝任意字符串）、`from:`（状态守卫数组，order.ex claim/4 同款）、`set:`（列 → 字面值 \| `{:arg, atom}`），`deadline: nil \| {col, :future \| :passed}`（`:future` → `(col IS NULL OR col > $N)`；`:passed` → `col IS NOT NULL AND col < $N`）、`extra_where: nil \| {sql_fragment, params}`、`returning: [atom]`。占位符全语句连续编号（sponsorship 42P18 纪律单点化）；不自己开事务/checkout（before_action 事务继承，savepoint 语义不变）；成功不 force_change（回写留资源层，与现状等价路径） |
| D3 | **错误映射留资源层**（对评审「统一错误 taxonomy」的显式修正）：ApprovalClaim 只返回 `:not_claimed`，各资源现有错误原子/消息/发生层（InvalidAttribute 字符串 ×3 资源、Splode PlatformAdminError code、域错误原子 ×3 资源）**原样保留**。理由：graphql 契约钉死 6 条精确字符串 + 2 组 code；invitation 预检（防枚举）vs speaker SQL 复验刻意不对称。sponsorship 读回消歧（approval_conflict/reject_conflict，SELECT status 4 路/2 路分派）留 sponsorship.ex——单资源使用，非扩散点 |
| D4 | **收编清单（14 条 SQL，7 文件）**：join_request.ex:188-194（approve）· workspace_application.ex:186-192（approve）· invitation.ex:435-441（accept；token_hash Elixir 预检留调用方）· enrollment.ex:789-793（claim_pending，confirm+reject 共用）· enrollment.ex:551-555（prepare_expire，:passed 方向）· enrollment.ex:827-830（claim_cancellable，多状态 IN + RETURNING）· enrollment.ex:809-820（claim_waive）· sponsorship.ex:572-580（approval_claim_sql；EXISTS/NOT EXISTS 经 extra_where 传入）· sponsorship.ex:695-698（reject claim）· sponsorship.ex:738-741（prepare_expire）· sponsorship.ex:765-766（prepare_end，level 守卫经 extra_where）· speaker_invitation.ex:569-573/581-584（claim_decision ×2，token_hash 复验经 extra_where）· speaker_invitation.ex:676-678（claim_complete，最简锚点） |
| D5 | **保留清单（deletion test 判定，PR body 记录）**：invitation.ex:489-495（accept_miniprogram——多表 JOIN+别名+双 deadline 列，1/17 使用率离群点，为其加 JOIN 轴不值）· user.ex:222-226（demote——count 子查询聚合不变量 ≠ 状态窗口 claim，Splode 错误 taxonomy）· enrollment.ex reserve/consume/release（counter 子族：数值守卫+动态表+RETURNING 值读回，另一原语）· validate_pending_status 快照守卫 ×2（join_request:270-288 / workspace_application:316-334 逐字 twin——非 claim UPDATE，本 plan 不动，留候选）· speaker_invitation:573/584 的 expires_at 守卫**跟随 D4 的 decide 收编**（经显式列名参数，不依赖 ApprovalDeadline struct 分派）· 其余非 approval deadline 守卫（enrollment:670/752 registration_deadline、:772 invite_batches、sponsorship:434/451/579 sponsorship_deadline + FOR SHARE）· Ash expr 全部（ARW:91-94/125-128 窗口 pushdown、AEW @expiry_specs、pending_approvals:68——D7 冻结 + pushdown 优化，内存化会退化为全表 load）· reconciliation 规2（方向相反：nil=发现项）· payments/order.ex 私有 claim/4（自成 seam、无 deadline 轴、低价值）· changes/transition.ex（内存快照守卫，第三套约定对照不收） |
| D6 | **锁序与附加守卫**：sponsorship approve 的 `Repo.acquire_lock!` 留调用方、在 claim 前取得（锁序敏感，后到者在赢家提交后重跑 NOT EXISTS）；EXISTS 目标检查 + 独占位 NOT EXISTS 作为 extra_where 片段传入，占位符由 ApprovalClaim 统一编号（消灭现手工连续编号） |
| D7（B） | **ApprovalDeadline 增 `not_expired?/2`**：`derive(record) -> nil -> true`（永不过期=放行）；否则 `DateTime.compare(deadline, now) == :gt`（严格 >）。与 `overdue?/2`（nil→false、严格 <）是**不对称对偶**（nil 侧相反），moduledoc 写明分工：`not_expired?` = 放行谓词（claim 守卫/投递守卫）；`overdue?` = 扫中谓词（过期扫描）。`overdue?`/`in_window?`/`derive` 语义零改动。**NotificationWorker stale_reminder? 两站点**（:60-64/:78-82）改调 `not_expired?/2`，逐边界不变：nil→投递、==now→skip、<now→skip、>now→投递（`overdue?` 不能代用——==now 侧翻转） |
| D8 | **deadline 守卫 SQL 片段由 ApprovalClaim 产出**（列名显式参数 `{col, dir}`），语义注释互链 ApprovalDeadline.not_expired?/overdue?；测试加对偶断言（同输入下 SQL 行为 ≡ Elixir 谓词）。不加 `deadline_column/1` struct 分派（调用点静态知道列名；WorkflowRun 是 :derived 无 SQL 列——ApprovalClaim 天然不可用于 WorkflowRun，现无该站点） |
| D9 | **测试**：新增 `test/cgc_2046/approval_claim_test.exs`（表驱动契约：from 数组/deadline 双方向/extra_where/returning/set arg 取值 + 边界 nil-deadline 放行、==now 双方向、并发 0 行；async: false 落库）+ `approval_deadline_test.exs` 增 `not_expired?/2` describe（四边界 + 与 overdue? 不对称断言）。**既有测试零改动**（只加不改）——8 处并发测试 + graphql 契约 = 安全网。grep 验收：收编后资源内 `(approval_deadline IS NULL OR`/`(expires_at IS NULL OR` 仅剩 D5 保留站点；NotificationWorker 无 inline DateTime.compare deadline 谓词 |
| D10 | **文档**：CONTEXT.md 新增「原子抢占（Approval Claim）」词条（唯一真源/interface/收编与保留边界）+ 修订「审批期限」词条（interface 列 `not_expired?/2` + 不对称对偶说明）。PR body 记录 plan 2026-08-15-010 D4「裸 SQL 本体不动」的 re-scope：claim 族是真同构（deletion test 失败=复杂度随资源数扩散），与 domain_error 族假同构（39 原子仅 1 共享）区分 |

## 当前状态证据（scout 2026-08-17，HEAD 6282163）

- 家族全量：7 资源 / 17 个 SQL 变体（方差矩阵 9 维度：表/SET/状态守卫/deadline 守卫/附加 WHERE/JOIN/tenant/RETURNING/错误映射）；全部 `WHERE id=$N + 状态守卫`、无 tenant 条件（row id 已从租户隔离读面解析——**ApprovalClaim 不得顺手加租户过滤**）、全部 before_action 内事务继承、成功路径依赖 Ash force_change 二次幂等写。
- 错误契约钉死面：`'Invitation has already been used'`（graphql_accept_invitation_test:131）/ `'invalid, expired or already used'`（speaker_flow_test:293-476 + graphql ×2）/ `'你已是该工作台成员'`（:112/:169）/ PlatformAdminError code `last_admin_denied`/`not_platform_admin` / `'Cannot expire invitation'` / transition `'cannot <verb> from status='` 逐字。弱钉（仅 %Ash.Error.Invalid{}，文案自由）：`'该申请已被处理'` 族——**本 plan 仍不改文案**（行为不变优先于归一）。
- B 侧四载体实测：SQL 守卫 17 处（15 future + 2 passed）+ NotificationWorker inline ×2 + Ash expr ×4 + reconciliation ×1；真源 approval_deadline.ex 四函数边界全被单测钉死。
- 现有 seam：`Cgc2046.Repo.acquire_lock!/2 + uuid!/1`（plan 010）；order.ex:980-1003 私有 claim/4 是泛化雏形。

## 改动清单

- **新增**：`backend/lib/cgc_2046/approval_claim.ex`（claim/2 + SQL 构造 + 占位符编号 + num_rows 判读）· `backend/test/cgc_2046/approval_claim_test.exs`
- **改**：`backend/lib/cgc_2046/approval_deadline.ex`（+not_expired?/2 + moduledoc 对偶说明）· `backend/test/cgc_2046/approval_deadline_test.exs`（+describe）· `accounts/join_request.ex` · `accounts/workspace_application.ex` · `accounts/invitation.ex`（仅 accept）· `events/enrollment.ex`（claim_pending/expire/cancel/waive 四组 prepare_* 内的 SQL）· `events/sponsorship.ex`（approval_claim_sql/reject/expire/end）· `events/speaker_invitation.ex`（claim_decision ×2/claim_complete）· `workers/notification_worker.ex`（stale_reminder? ×2 改调 not_expired?/2）· `CONTEXT.md`
- **不动**：D5 全清单 · reserve_capacity/consume/release · validate_pending_status ×2 · ARW/AEW/pending_approvals/reconciliation · transition.ex · payments/order.ex · user.ex · invitation accept_miniprogram
- 数据库 / 配置 / 前端 / 图：无

## 实施顺序与验收

1. ApprovalClaim module + 表驱动契约测试（先立安全网）
2. ApprovalDeadline +not_expired?/2 + 单测；NotificationWorker 接线（B 独立可验）
3. 逐资源收编（join_request/workspace_application twins → invitation → enrollment ×4 → speaker ×3 → sponsorship ×4，从最简到最复杂；每资源收编后跑该资源测试）
4. CONTEXT.md 词条 + PR body re-scope 记录
5. 验收：`mix format --check-formatted` + `mix compile --warnings-as-errors` + `MIX_ENV=test mix test` ×2 seeds 全绿、既有测试零改动、grep 残留清单核对、并发套件（enrollment/sponsorship concurrency）绿
