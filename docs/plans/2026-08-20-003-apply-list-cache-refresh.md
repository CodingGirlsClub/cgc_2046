# Plan 2026-08-20-003 · 修复 #205：/apply 提交后「我的申请」列表不自动刷新

## 背景

**issue 描述的根因已过时**：`await loadMyApps()` 自 b7dca18（2026-08-11）起就在 `handleSubmit` 成功分支（`web/app/[locale]/apply/page.tsx:63`），早于 issue 创建（2026-08-18）。

真实根因（scout 2026-08-20 HEAD 取证）= **Apollo cache 竞态**：

- `fetchMyApplications()`（`web/lib/admin.ts:134-141`）默认 cache-first；
- `createApplication()`（`admin.ts:145-158`）带 `refetchQueries` 但非 await；
- 提交成功 → `loadMyApps()` → cache-first 先命中挂载时缓存的旧空列表 → `setMyApps([])`；后台 refetch 后落盘但 UI 已停。

与 P3 已修复的同构 bug 完全一致（commit 1eaab58：`fetchApplications` 改 network-only + 移除失效 refetchQueries）。

## 决策

**network-only + 删 refetchQueries**（P3 惯例照搬，零新决策）。

拒绝「本地追加新行」：不符合项目模式（admin applications 页 approve/reject 后 `await load(status)`、approvals 页 `await refetch()`，全走 refetch）。

## 实施单元（web，单 PR）

### U1 `web/lib/admin.ts`

1. `fetchMyApplications()`（:134-141）加 `fetchPolicy: "network-only"`（对齐 `fetchApplications` :120-131 的 P3 惯例），附注释 `// #205：提交后 loadMyApps 必须绕过 cache-first 命中旧缓存（P3 同款）`。
2. `createApplication()`（:148-153）移除 `refetchQueries: [{ query: MY_WORKSPACE_APPLICATIONS }]`——非 await 与 network-only 冲突且冗余。

### U2 测试（`web/lib/admin.test.ts`）

- `fetchMyApplications` 现有测试（:153-161，仅断言 opName）补 `fetchPolicy: "network-only"` 断言（镜像 :146-151 的 fetchApplications network-only 测试）。
- 可选加固：`page.test.tsx` R7a（:103-146）加「提交后 fetchMyApplications 被再次调用」断言——注意该测试 mock 了 `@/lib/admin`，捕获的是调用路径而非缓存竞态；若实现成本高可留 PR body 记录。

## 验收标准

1. `pnpm typecheck / lint / test / build` 全绿（web 目录）。
2. admin.test.ts 的 fetchPolicy 断言通过。
3. 手动路径推演：mutation 成功 → loadMyApps → network-only 直查后端 → 必然新数据（无本地缓存命中可能）。

## 非目标

- 不改 `apply/page.tsx`（现状 `await loadMyApps()` 正确）。
- 不动 messages（apply 命名空间 key 齐全，无新文案）。
- 不改其他 fetch 函数的 fetchPolicy。

## 风险

| 风险 | 缓解 |
|---|---|
| network-only 后每次进 /apply 强制网络请求 | 数据量小（本人申请）；与 P3 后 fetchApplications 行为一致 |
| 移除 refetchQueries 后其他页面依赖该 cache 刷新 | scout 已核实全库仅 apply 页 + admin.ts 使用 MY_WORKSPACE_APPLICATIONS，无 useQuery 订阅者 |
| issue #205 根因描述与实际不符 | PR/issue 关闭评论同步真实根因（cache 竞态），防后续误判 |

## 关联

- Issue #205（本 plan 关闭目标）
- Scout 报告：`agent://Scout205`（2026-08-20，HEAD 取证）
- 前史：P3 commit 1eaab58（fetchApplications 同款修复）
