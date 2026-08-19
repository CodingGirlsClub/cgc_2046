# Plan 2026-08-19-003 · 修复 #242：graphql_admin_queries_test listAdminActionLogs 稳定失败

## 根因（scout 2026-08-19 取证，HEAD 3f22af8）

**共享测试 DB 全局表 `admin_action_logs` 的持久污染 + 唯一无过滤查询的 `first:50` 截断**：

1. **污染源**：`enrollment_concurrency_test.exs:33-36,60-72` 与 `sponsorship_concurrency_test.exs:32-35` 用 `Sandbox.unboxed_run` 在沙箱外真实提交 `Fixtures.create_workspace(admin)`；Workspace create action 的 `LogAdminAction` change（`workspace.ex:242-248`）落 `admin_action_logs` 一行 `workspace_create`。两者 `cleanup_on_exit`（`:113-131` / `:84-116`）只删 membership_roles / workspace_memberships / events / workspaces / users——**不删 `admin_action_logs`**（该表无 FK，不级联，migration `20260811140533`）。每轮全量测试累积 ~3 行，永不清理。
2. **受害查询**：`graphql_admin_queries_test.exs:785-844`（#117 四个时间窗测试中**唯一无 workspaceId 过滤的全局查询**）：backdate 目标行到 `now-3d` → 查询窗口 `[now-4d, now-2d]` + `first: 50`。`paginate/3`（`graphql_schema.ex:2462-2467`）按 `inserted_at desc, id desc` 排序截断——当累积行在 `(now-3d, now-2d]` 带宽内 ≥50 行（比目标行更新），目标行被挤出首页 → `:824` `Enum.any?` 失败。
3. **稳定失败解释**：单文件 3 次 3 败 = DB 累积态不变（本文件 `async: false` shared sandbox，自身写全部回滚）；非文件内互染。过滤边界（`>=`/`<=` 含边界、utc_datetime）正确，非边界/时区 bug。
4. 对照组免疫证据：同文件 `listToolCallLogs:598` / `listSignalLogs:748` / `listWorkflowRuns:892` 均带 workspaceId 过滤，全部稳定绿——机制的最强结构证据。
5. `e1188e3` seam 重构非根因（`:785-844` 逻辑 blame 属 `1abeb34`）；但其把 `platform_admin` 改 action 化使 unboxed 多提交 `admin_promote` 留痕（type=user），属表增长副因。

## GraphqlInviteBatchTest（#242 验收第 2 项）

**同类脆弱模式、非同机制**：`graphql_invite_batch_test.exs:73`（`Ash.read!(InviteBatch) == []` 全局空断言）与 `:89`（全局 `length == 1`）同为「共享表 + 非隔离全局断言」。已知 unboxed InviteBatch 写入会被 workspace 级联清理（`on_delete: :delete_all`）不累积；批量 275/276 的具体触发源静态无法唯一钉死（候选：async 并发下沙箱外提交）。修法 = 断言隔离（C），不追查触发源。

## 实施单元（backend，单 PR）

### U1 止累积（根修）

`enrollment_concurrency_test.exs` 与 `sponsorship_concurrency_test.exs` 的 `cleanup_on_exit` 各加一条：

```elixir
Repo.delete_all(from(l in "admin_action_logs",
  where: l.target_type == "workspace" and l.target_id == ^workspace_id))
```

（按两文件 cleanup 既有 SQL 风格落笔；~4 行 ×2 文件。）

### U2 测试加固（确定性，即使 DB 有历史累积）

`graphql_admin_queries_test.exs`：

1. `:812-817` 查询 1 窗口收窄到 backdate 精确时刻 ±60s（`insertedAfter: now-3d-60s, insertedBefore: now-3d+60s`）——`admin_action_logs` 只有本测试 backdate 到 -3d，竞争行不落窄带 → `first:50` 恒够。负例查询 `[now-1d, ∞)` 保持。
2. backdate `query!` 后断言 `num_rows == 1`——收口「UPDATE 未命中」备选假设（scout 已按同构用法排除，断言作永久守卫）。

### U3 InviteBatch 断言隔离

`graphql_invite_batch_test.exs`：`:73` 改按本测试 event_id 过滤断言无批次；`:89` 改按本测试唯一 invite_code 过滤断言恰 1 条。（~4 行。）

## 验收标准（#242 原验收）

1. `:785` 用例稳定绿：单文件连跑 3 次 3 绿 + 全量 `--seed 1/2` 绿（该用例不失败）。
2. InviteBatch 用例：单跑 + web 树批量均绿。
3. `mix format --check-formatted` + `mix compile --warnings-as-errors` + 全量 ×2 seeds，除已知 wechat 动态编译竞态族（#246 第 2 项，本线非目标）外无新增失败。
4. 复跑 `enrollment_concurrency_test.exs` + `sponsorship_concurrency_test.exs` 全绿（cleanup 改动不破坏自身）。

## 非目标

- wechat 动态模块编译竞态（#246 第 2 项，独立 flaky）。
- InviteBatch 批量失败触发源的根因追查（静态无法钉死，断言隔离即修复）。
- `admin_action_logs` 生产侧行为、schema、任何 lib/ 代码——**纯测试文件改动**。

## 风险

| 风险 | 缓解 |
|---|---|
| U2 窗口收窄后目标行恰在边界外（时钟精度） | ±60s 带宽足够；backdate 与查询同用 `now` 变量 |
| U1 delete 误删并行测试的行 | cleanup_on_exit 已是 unboxed 串行段，target_id 精确匹配 |
| 历史累积行已 ≥50 且不重跑并发测试 | U2 窄带使 :785 免疫历史累积；U1 只防未来 |

## 关联

- Issue #242（本 plan 关闭目标）；#246 第 1 项随本线收编（修复后 #246 编辑为仅剩 wechat 项）
- Scout 报告：`agent://GraphqlFlakyScout`（2026-08-19）
- 前史：#117（时间窗测试引入）、e1188e3（seam 重构，非根因）
